-- Candidate/baseline lifecycle foundation.
--
-- This migration adds the forward lifecycle vocabulary and enforces a linear,
-- append-only lifecycle per baseline plus series-level ACTIVE/candidate-like
-- cardinality. It intentionally does not add promotion APIs, import eligibility
-- requirements, review/governance behavior, or client grants.

set role s2t_fhir_owner;

-- -----------------------------------------------------------------------------
-- Deployment preconditions
-- -----------------------------------------------------------------------------

do $block$
declare
  migrator_count integer;
  lifecycle_domain_count integer;
  pending_count integer;
  active_count integer;
  retired_count integer;
  candidate_count integer;
  superseded_count integer;
begin
  select count(*)
    into migrator_count
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null;

  if migrator_count <> 1 then
    raise exception 'migration 022 requires exactly one enabled postgres-role/s2t_fhir_migrator principal; found %', migrator_count
      using errcode = '55000';
  end if;

  select count(*)
    into lifecycle_domain_count
  from s2t_fhir.reference_domain d
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and d.is_versioned = false;

  if lifecycle_domain_count <> 1 then
    raise exception 'migration 022 requires exactly one non-versioned BASELINE_LIFECYCLE_STATUS domain; found %', lifecycle_domain_count
      using errcode = '55000';
  end if;

  select
    count(*) filter (where v.value_code = 'PENDING_APPROVAL'),
    count(*) filter (where v.value_code = 'ACTIVE'),
    count(*) filter (where v.value_code = 'RETIRED'),
    count(*) filter (where v.value_code = 'CANDIDATE'),
    count(*) filter (where v.value_code = 'SUPERSEDED')
    into pending_count, active_count, retired_count, candidate_count, superseded_count
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS';

  if pending_count <> 1 or active_count <> 1 or retired_count <> 1 then
    raise exception 'migration 022 requires exactly one legacy PENDING_APPROVAL, ACTIVE, and RETIRED lifecycle value; found %, %, %',
      pending_count, active_count, retired_count
      using errcode = '55000';
  end if;

  if candidate_count <> 0 or superseded_count <> 0 then
    raise exception 'migration 022 requires CANDIDATE and SUPERSEDED lifecycle values to be absent; found %, %',
      candidate_count, superseded_count
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event e
    left join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    left join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where d.domain_code is distinct from 'BASELINE_LIFECYCLE_STATUS'
       or v.value_code not in ('PENDING_APPROVAL', 'ACTIVE', 'RETIRED')
  ) then
    raise exception 'migration 022 found a lifecycle event with an unexpected lifecycle reference value'
      using errcode = '55000';
  end if;
end
$block$;

do $block$
begin
  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event e
    where e.supersedes_event_id is null
    group by e.baseline_version_id
    having count(*) > 1
  ) then
    raise exception 'migration 022 found a baseline with more than one root lifecycle event'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event e
    where e.supersedes_event_id is not null
    group by e.supersedes_event_id
    having count(*) > 1
  ) then
    raise exception 'migration 022 found a lifecycle event with more than one successor'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event child
    join s2t_fhir.baseline_lifecycle_event parent
      on parent.baseline_lifecycle_event_id = child.supersedes_event_id
    where child.baseline_version_id <> parent.baseline_version_id
  ) then
    raise exception 'migration 022 found a cross-baseline lifecycle predecessor'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event child
    join s2t_fhir.baseline_lifecycle_event parent
      on parent.baseline_lifecycle_event_id = child.supersedes_event_id
    where child.occurred_at < parent.occurred_at
  ) then
    raise exception 'migration 022 found a lifecycle event earlier than its predecessor'
      using errcode = '55000';
  end if;

  if exists (
    with current_events as (
      select e.baseline_version_id
      from s2t_fhir.baseline_lifecycle_event e
      where not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      )
    )
    select 1
    from current_events e
    group by e.baseline_version_id
    having count(*) > 1
  ) then
    raise exception 'migration 022 found a baseline with more than one current lifecycle event'
      using errcode = '55000';
  end if;
end
$block$;

do $block$
begin
  if exists (
    with current_events as (
      select e.baseline_version_id, e.lifecycle_status_value_id
      from s2t_fhir.baseline_lifecycle_event e
      where not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      )
    ), series_state as (
      select bv.baseline_series_id, v.value_code
      from current_events e
      join s2t_fhir.baseline_version bv
        on bv.baseline_version_id = e.baseline_version_id
      join s2t_fhir.reference_value v
        on v.reference_value_id = e.lifecycle_status_value_id
      join s2t_fhir.reference_domain d
        on d.reference_domain_id = v.reference_domain_id
       and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    )
    select 1
    from series_state s
    group by s.baseline_series_id
    having count(*) filter (where s.value_code = 'ACTIVE') > 1
        or count(*) filter (where s.value_code in ('PENDING_APPROVAL')) > 1
  ) then
    raise exception 'migration 022 found a baseline series that violates current ACTIVE or candidate-like cardinality'
      using errcode = '55000';
  end if;

  if exists (
    with current_active as (
      select e.baseline_version_id
      from s2t_fhir.baseline_lifecycle_event e
      join s2t_fhir.reference_value v
        on v.reference_value_id = e.lifecycle_status_value_id
      join s2t_fhir.reference_domain d
        on d.reference_domain_id = v.reference_domain_id
       and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      where v.value_code = 'ACTIVE'
        and not exists (
          select 1
          from s2t_fhir.baseline_lifecycle_event successor
          where successor.supersedes_event_id = e.baseline_lifecycle_event_id
        )
    )
    select 1
    from current_active a
    where (
      select count(*)
      from s2t_fhir.baseline_artifact ba
      join s2t_fhir.reference_value role_value
        on role_value.reference_value_id = ba.artifact_role_value_id
      join s2t_fhir.reference_domain role_domain
        on role_domain.reference_domain_id = role_value.reference_domain_id
       and role_domain.domain_code = 'ARTIFACT_ROLE'
      where ba.baseline_version_id = a.baseline_version_id
        and role_value.value_code = 'AUTHORITATIVE_SOURCE'
    ) <> 1
       or not exists (
         select 1
         from s2t_fhir.current_release_gate_evaluation gate_evaluation
         join s2t_fhir.reference_value gate_outcome
           on gate_outcome.reference_value_id = gate_evaluation.gate_outcome_value_id
         join s2t_fhir.reference_domain gate_domain
           on gate_domain.reference_domain_id = gate_outcome.reference_domain_id
          and gate_domain.domain_code = 'RELEASE_GATE_OUTCOME'
         where gate_evaluation.baseline_version_id = a.baseline_version_id
           and gate_outcome.value_code = 'PASSED'
       )
  ) then
    raise exception 'migration 022 found a current ACTIVE baseline without the existing authoritative-artifact/current-PASSED-gate prerequisites'
      using errcode = '55000';
  end if;
end
$block$;

-- -----------------------------------------------------------------------------
-- Forward lifecycle vocabulary. Legacy values remain unchanged and effective.
-- -----------------------------------------------------------------------------

with migrator as (
  select p.principal_id
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null
), lifecycle_domain as (
  select d.reference_domain_id
  from s2t_fhir.reference_domain d
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and d.is_versioned = false
), seed(value_code, display_name, description) as (
  values
    ('CANDIDATE', 'Candidate',
     'Forward lifecycle state for a baseline version that may become ACTIVE or SUPERSEDED.'),
    ('SUPERSEDED', 'Superseded',
     'Forward terminal lifecycle state for a replaced or abandoned baseline version.')
)
insert into s2t_fhir.reference_value
  (reference_domain_id, value_code, version_number, display_name, description,
   effective_at, is_bootstrap_seed, created_by_principal_id)
select d.reference_domain_id, s.value_code, 1, s.display_name, s.description,
       transaction_timestamp(), false, m.principal_id
from seed s
cross join migrator m
cross join lifecycle_domain d;

-- A baseline has one chain root, and every history node has at most one successor.
create unique index baseline_lifecycle_root_once_uq
  on s2t_fhir.baseline_lifecycle_event (baseline_version_id)
  where supersedes_event_id is null;

create unique index baseline_lifecycle_superseded_once_uq
  on s2t_fhir.baseline_lifecycle_event (supersedes_event_id)
  where supersedes_event_id is not null;

-- PostgreSQL orders sibling triggers of the same timing/event by name. This
-- function therefore resolves every prerequisite needed for its lifecycle
-- decision itself; existing actor-pair and general reference checks remain
-- independently authoritative regardless of sibling-trigger order.
create function s2t_fhir.validate_baseline_lifecycle_insert()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  target_series_id uuid;
  target_status_code text;
  target_status_domain text;
  predecessor_baseline_id uuid;
  current_event_count integer;
  current_event_id uuid;
  current_status_code text;
  current_status_domain text;
  current_occurred_at timestamptz;
begin
  if new.baseline_version_id is null then
    raise exception 'baseline lifecycle event requires baseline_version_id'
      using errcode = '23502';
  end if;

  -- The protected invariant belongs to the series. Lock the actual series row
  -- before reading or validating lifecycle state; the lock lasts to transaction end.
  select bs.baseline_series_id
    into target_series_id
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  where bv.baseline_version_id = new.baseline_version_id
  for update of bs;

  if not found then
    raise exception 'baseline version % does not exist', new.baseline_version_id
      using errcode = '23503';
  end if;

  if new.lifecycle_status_value_id is null then
    raise exception 'baseline lifecycle event requires lifecycle_status_value_id'
      using errcode = '23502';
  end if;

  select v.value_code, d.domain_code
    into target_status_code, target_status_domain
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where v.reference_value_id = new.lifecycle_status_value_id;

  if not found then
    raise exception 'baseline lifecycle status reference % does not exist', new.lifecycle_status_value_id
      using errcode = '23503';
  end if;

  if target_status_domain <> 'BASELINE_LIFECYCLE_STATUS' then
    raise exception 'baseline lifecycle status reference % belongs to domain %, not BASELINE_LIFECYCLE_STATUS',
      new.lifecycle_status_value_id, target_status_domain
      using errcode = '23514';
  end if;

  if target_status_code not in ('CANDIDATE', 'ACTIVE', 'SUPERSEDED') then
    raise exception 'baseline lifecycle target must be CANDIDATE, ACTIVE, or SUPERSEDED'
      using errcode = '23514';
  end if;

  if target_status_code = 'SUPERSEDED'
     and nullif(btrim(new.reason), '') is null then
    raise exception 'SUPERSEDED lifecycle event requires a nonblank reason'
      using errcode = '23514';
  end if;

  if new.supersedes_event_id is not null then
    select predecessor.baseline_version_id
      into predecessor_baseline_id
    from s2t_fhir.baseline_lifecycle_event predecessor
    where predecessor.baseline_lifecycle_event_id = new.supersedes_event_id;

    if not found then
      raise exception 'baseline lifecycle predecessor % does not exist', new.supersedes_event_id
        using errcode = '23503';
    end if;

    if predecessor_baseline_id <> new.baseline_version_id then
      raise exception 'lifecycle predecessor % belongs to baseline %, not baseline %',
        new.supersedes_event_id, predecessor_baseline_id, new.baseline_version_id
        using errcode = '23514';
    end if;
  end if;

  select count(*)
    into current_event_count
  from s2t_fhir.baseline_lifecycle_event current_event
  where current_event.baseline_version_id = new.baseline_version_id
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = current_event.baseline_lifecycle_event_id
    );

  if current_event_count > 1 then
    raise exception 'baseline % has % current lifecycle events; expected at most one',
      new.baseline_version_id, current_event_count
      using errcode = '23514';
  end if;

  if current_event_count = 0 then
    if new.supersedes_event_id is not null then
      raise exception 'initial lifecycle event for baseline % cannot specify a predecessor', new.baseline_version_id
        using errcode = '23514';
    end if;

    if target_status_code <> 'CANDIDATE' then
      raise exception 'initial lifecycle status for baseline % must be CANDIDATE', new.baseline_version_id
        using errcode = '23514';
    end if;

    return new;
  end if;

  select current_event.baseline_lifecycle_event_id,
         current_status.value_code,
         current_domain.domain_code,
         current_event.occurred_at
    into current_event_id, current_status_code,
         current_status_domain, current_occurred_at
  from s2t_fhir.baseline_lifecycle_event current_event
  join s2t_fhir.reference_value current_status
    on current_status.reference_value_id = current_event.lifecycle_status_value_id
  join s2t_fhir.reference_domain current_domain
    on current_domain.reference_domain_id = current_status.reference_domain_id
  where current_event.baseline_version_id = new.baseline_version_id
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = current_event.baseline_lifecycle_event_id
    );

  if not found or current_status_domain <> 'BASELINE_LIFECYCLE_STATUS' then
    raise exception 'current lifecycle event for baseline % has an invalid lifecycle status reference', new.baseline_version_id
      using errcode = '23514';
  end if;

  if new.supersedes_event_id is distinct from current_event_id then
    raise exception 'lifecycle event for baseline % must supersede current event %',
      new.baseline_version_id, current_event_id
      using errcode = '23514';
  end if;

  if new.occurred_at < current_occurred_at then
    raise exception 'lifecycle occurred_at cannot precede predecessor event %', current_event_id
      using errcode = '23514';
  end if;

  if not (
    (current_status_code in ('CANDIDATE', 'PENDING_APPROVAL')
     and target_status_code in ('ACTIVE', 'SUPERSEDED'))
    or
    (current_status_code = 'ACTIVE' and target_status_code = 'SUPERSEDED')
  ) then
    raise exception 'baseline lifecycle transition from % to % is not permitted',
      current_status_code, target_status_code
      using errcode = '23514';
  end if;

  return new;
end
$function$;

create function s2t_fhir.assert_baseline_series_lifecycle(p_baseline_series_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  invalid_status_count integer;
  active_count integer;
  candidate_like_count integer;
begin
  -- Reacquiring a row lock already held by this transaction is harmless and makes
  -- this private assertion safe even if an owner invokes it outside its trigger.
  perform 1
  from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = p_baseline_series_id
  for update;

  if not found then
    raise exception 'baseline series % does not exist', p_baseline_series_id
      using errcode = '23503';
  end if;

  with current_events as (
    select e.lifecycle_status_value_id
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e
      on e.baseline_version_id = bv.baseline_version_id
    where bv.baseline_series_id = p_baseline_series_id
      and not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      )
  ), resolved as (
    select e.lifecycle_status_value_id,
           v.value_code,
           d.domain_code
    from current_events e
    left join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    left join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
  )
  select count(*) filter (
           where r.domain_code is distinct from 'BASELINE_LIFECYCLE_STATUS'
              or r.value_code not in (
                'PENDING_APPROVAL', 'ACTIVE', 'RETIRED',
                'CANDIDATE', 'SUPERSEDED'
              )
         ),
         count(*) filter (where r.value_code = 'ACTIVE'),
         count(*) filter (
           where r.value_code in ('CANDIDATE', 'PENDING_APPROVAL')
         )
    into invalid_status_count, active_count, candidate_like_count
  from resolved r;

  if invalid_status_count > 0 then
    raise exception 'baseline series % has % current events with invalid lifecycle status references',
      p_baseline_series_id, invalid_status_count
      using errcode = '23514';
  end if;

  if active_count > 1 then
    raise exception 'baseline series % has % current ACTIVE baselines; maximum is one',
      p_baseline_series_id, active_count
      using errcode = '23514';
  end if;

  if candidate_like_count > 1 then
    raise exception 'baseline series % has % current candidate-like baselines; maximum is one',
      p_baseline_series_id, candidate_like_count
      using errcode = '23514';
  end if;
end
$function$;

create function s2t_fhir.check_baseline_series_lifecycle()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  target_series_id uuid;
begin
  select bv.baseline_series_id
    into target_series_id
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = new.baseline_version_id;

  if not found then
    raise exception 'baseline version % does not exist', new.baseline_version_id
      using errcode = '23503';
  end if;

  perform s2t_fhir.assert_baseline_series_lifecycle(target_series_id);
  return null;
end
$function$;

create trigger baseline_lifecycle_transition_trg
before insert on s2t_fhir.baseline_lifecycle_event
for each row
execute function s2t_fhir.validate_baseline_lifecycle_insert();

create constraint trigger baseline_series_lifecycle_cardinality_trg
after insert on s2t_fhir.baseline_lifecycle_event
deferrable initially deferred
for each row
execute function s2t_fhir.check_baseline_series_lifecycle();

comment on function s2t_fhir.validate_baseline_lifecycle_insert() is
  'Validates and serializes lifecycle inserts by locking the owning baseline_series row; independent of sibling BEFORE-trigger order.';
comment on function s2t_fhir.assert_baseline_series_lifecycle(uuid) is
  'Asserts final per-series lifecycle cardinality: at most one ACTIVE and at most one CANDIDATE/PENDING_APPROVAL current baseline.';
comment on function s2t_fhir.check_baseline_series_lifecycle() is
  'Deferred constraint-trigger wrapper for final baseline-series lifecycle cardinality.';
comment on index s2t_fhir.baseline_lifecycle_root_once_uq is
  'Allows at most one root lifecycle event per baseline version.';
comment on index s2t_fhir.baseline_lifecycle_superseded_once_uq is
  'Allows at most one successor for each lifecycle event.';

revoke all on function s2t_fhir.validate_baseline_lifecycle_insert() from public;
revoke all on function s2t_fhir.assert_baseline_series_lifecycle(uuid) from public;
revoke all on function s2t_fhir.check_baseline_series_lifecycle() from public;

revoke all on function s2t_fhir.validate_baseline_lifecycle_insert()
  from s2t_fhir_importer, s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.assert_baseline_series_lifecycle(uuid)
  from s2t_fhir_importer, s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.check_baseline_series_lifecycle()
  from s2t_fhir_importer, s2t_fhir_api_reader, s2t_fhir_governance_reader;

do $block$
declare
  role_name text;
begin
  foreach role_name in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_catalog.pg_roles r where r.rolname = role_name) then
      execute pg_catalog.format(
        'revoke all on function s2t_fhir.validate_baseline_lifecycle_insert() from %I',
        role_name
      );
      execute pg_catalog.format(
        'revoke all on function s2t_fhir.assert_baseline_series_lifecycle(uuid) from %I',
        role_name
      );
      execute pg_catalog.format(
        'revoke all on function s2t_fhir.check_baseline_series_lifecycle() from %I',
        role_name
      );
    end if;
  end loop;
end
$block$;

-- Deliberately unchanged by 022:
--   * ACTIVE still uses the deployed authoritative-artifact and current-PASSED-
--     release-gate checks in s2t_fhir.check_authoritative_artifact().
--   * No COMMITTED import-run prerequisite is introduced.
--   * One ACTIVE per baseline_series does not guarantee one ACTIVE context per
--     source_system/FHIR resource when multiple baseline types exist.

reset role;

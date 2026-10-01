-- Append-only review workflow for the governed S2T mapping set.
-- Review status is deliberately independent of mapping decision status.
-- This migration does not modify get_active_medication_request_cato().

set role s2t_fhir_owner;

-- REVIEW_STATUS is governed reference data. The established migration service
-- principal owns these post-bootstrap values; the bootstrap seed window remains closed.
insert into s2t_fhir.reference_domain
  (domain_code, display_name, is_versioned, description)
values
  ('REVIEW_STATUS', 'Review status', false,
   'Operational review workflow status; independent of governed mapping decision status');

do $block$
begin
  if not exists (
    select 1 from s2t_fhir.principal p
    where p.external_issuer = 'postgres-role'
      and p.external_subject = 's2t_fhir_migrator'
      and p.disabled_at is null
  ) then
    raise exception 'enabled migration service principal is required to govern REVIEW_STATUS values';
  end if;
end
$block$;

with migrator as (
  select p.principal_id
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null
), seed(value_code, display_name) as (
  values
    ('NOT_REVIEWED', 'Not reviewed'),
    ('REVIEWED', 'Reviewed'),
    ('NEEDS_FOLLOW_UP', 'Needs follow-up')
)
insert into s2t_fhir.reference_value
  (reference_domain_id, value_code, version_number, display_name, effective_at,
   is_bootstrap_seed, created_by_principal_id)
select d.reference_domain_id, s.value_code, 1, s.display_name,
       transaction_timestamp(), false, m.principal_id
from seed s
cross join migrator m
join s2t_fhir.reference_domain d on d.domain_code = 'REVIEW_STATUS';

create table s2t_fhir.review_session (
  review_session_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null
    references s2t_fhir.baseline_version(baseline_version_id),
  session_name text not null,
  started_at timestamptz not null,
  ended_at timestamptz,
  ended_by_principal_id uuid
    references s2t_fhir.principal(principal_id),
  created_by_principal_id uuid not null
    references s2t_fhir.principal(principal_id),
  notes text,
  created_at timestamptz not null default transaction_timestamp(),
  constraint review_session_name_ck check (btrim(session_name) <> ''),
  constraint review_session_notes_ck check (notes is null or btrim(notes) <> ''),
  constraint review_session_end_ck check (ended_at is null or ended_at >= started_at),
  constraint review_session_end_actor_ck check (
    (ended_at is null) = (ended_by_principal_id is null)
  )
);

create table s2t_fhir.mapping_review_event (
  mapping_review_event_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null
    references s2t_fhir.baseline_version(baseline_version_id),
  mapping_record_id uuid not null
    references s2t_fhir.mapping_record(mapping_record_id),
  review_session_id uuid
    references s2t_fhir.review_session(review_session_id),
  review_status_value_id uuid not null
    references s2t_fhir.reference_value(reference_value_id),
  occurred_at timestamptz not null,
  actor_principal_id uuid not null
    references s2t_fhir.principal(principal_id),
  review_note text,
  supersedes_event_id uuid
    references s2t_fhir.mapping_review_event(mapping_review_event_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint mapping_review_event_supersedes_ck check (
    supersedes_event_id is null or supersedes_event_id <> mapping_review_event_id
  ),
  constraint mapping_review_event_note_ck check (
    review_note is null or btrim(review_note) <> ''
  )
);

-- A history node can be superseded once only. Together with the integrity
-- trigger this makes each baseline/mapping history a single append-only chain.
create unique index mapping_review_event_superseded_once_uq
  on s2t_fhir.mapping_review_event (supersedes_event_id)
  where supersedes_event_id is not null;

create index mapping_review_event_current_lookup_idx
  on s2t_fhir.mapping_review_event
  (baseline_version_id, mapping_record_id, occurred_at desc, created_at desc);

create index mapping_review_event_status_idx
  on s2t_fhir.mapping_review_event
  (baseline_version_id, review_status_value_id, mapping_record_id);

create index mapping_review_event_last_reviewed_idx
  on s2t_fhir.mapping_review_event
  (baseline_version_id, occurred_at desc, mapping_review_event_id desc);

create index review_session_baseline_idx
  on s2t_fhir.review_session
  (baseline_version_id, started_at desc, review_session_id);

create function s2t_fhir.protect_review_session_update()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if old.ended_at is not null then
    raise exception 'ended review sessions are immutable' using errcode = '55000';
  end if;

  if new.review_session_id is distinct from old.review_session_id
     or new.baseline_version_id is distinct from old.baseline_version_id
     or new.session_name is distinct from old.session_name
     or new.started_at is distinct from old.started_at
     or new.created_by_principal_id is distinct from old.created_by_principal_id
     or new.notes is distinct from old.notes
     or new.created_at is distinct from old.created_at then
    raise exception 'immutable review session fields cannot be changed' using errcode = '55000';
  end if;

  if new.ended_at is null or new.ended_by_principal_id is null then
    raise exception 'a review session update must set ended_at and its actor once'
      using errcode = '55000';
  end if;

  return new;
end
$function$;

create function s2t_fhir.check_mapping_review_event_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  mapping_baseline uuid;
  session_baseline uuid;
  prior_baseline uuid;
  prior_mapping uuid;
  current_event_id uuid;
  current_count integer;
begin
  -- Serialize the chain even for privileged direct inserts. Advisory lock
  -- collisions are harmless and last only for the transaction.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.baseline_version_id::text || ':' || new.mapping_record_id::text, 0)
  );

  select mr.baseline_version_id into mapping_baseline
  from s2t_fhir.mapping_record mr
  where mr.mapping_record_id = new.mapping_record_id;

  if mapping_baseline is distinct from new.baseline_version_id then
    raise exception 'review event baseline does not match mapping record baseline'
      using errcode = '23514';
  end if;

  if new.review_session_id is not null then
    select rs.baseline_version_id into session_baseline
    from s2t_fhir.review_session rs
    where rs.review_session_id = new.review_session_id;

    if session_baseline is distinct from new.baseline_version_id then
      raise exception 'review session baseline does not match review event baseline'
        using errcode = '23514';
    end if;
  end if;

  if new.supersedes_event_id is not null then
    select e.baseline_version_id, e.mapping_record_id
      into prior_baseline, prior_mapping
    from s2t_fhir.mapping_review_event e
    where e.mapping_review_event_id = new.supersedes_event_id;

    if prior_baseline is distinct from new.baseline_version_id
       or prior_mapping is distinct from new.mapping_record_id then
      raise exception 'superseded review event must belong to the same baseline and mapping'
        using errcode = '23514';
    end if;
  end if;

  select count(*)
    into current_count
  from s2t_fhir.mapping_review_event e
  where e.baseline_version_id = new.baseline_version_id
    and e.mapping_record_id = new.mapping_record_id
    and not exists (
      select 1
      from s2t_fhir.mapping_review_event newer
      where newer.supersedes_event_id = e.mapping_review_event_id
    );

  select e.mapping_review_event_id into current_event_id
  from s2t_fhir.mapping_review_event e
  where e.baseline_version_id = new.baseline_version_id
    and e.mapping_record_id = new.mapping_record_id
    and not exists (
      select 1
      from s2t_fhir.mapping_review_event newer
      where newer.supersedes_event_id = e.mapping_review_event_id
    )
  order by e.occurred_at desc, e.created_at desc, e.mapping_review_event_id desc
  limit 1;

  if current_count = 0 and new.supersedes_event_id is not null then
    raise exception 'first review event cannot supersede another event' using errcode = '23514';
  elsif current_count = 1 and new.supersedes_event_id is distinct from current_event_id then
    raise exception 'new review event must explicitly supersede the current event %', current_event_id
      using errcode = '23514';
  elsif current_count > 1 then
    raise exception 'review event history has multiple current events' using errcode = '23514';
  end if;

  return new;
end
$function$;

revoke all on function s2t_fhir.protect_review_session_update() from public;
revoke all on function s2t_fhir.check_mapping_review_event_integrity() from public;

create trigger review_session_protect_update_trg
before update on s2t_fhir.review_session
for each row execute function s2t_fhir.protect_review_session_update();

create trigger review_session_reject_delete_trg
before delete on s2t_fhir.review_session
for each row execute function s2t_fhir.reject_append_only_change();

create trigger mapping_review_event_integrity_trg
before insert on s2t_fhir.mapping_review_event
for each row execute function s2t_fhir.check_mapping_review_event_integrity();

create trigger mapping_review_event_reference_domain_trg
before insert or update on s2t_fhir.mapping_review_event
for each row execute function s2t_fhir.enforce_reference_domains(
  'review_status_value_id', 'REVIEW_STATUS'
);

create trigger mapping_review_event_append_only_trg
before update or delete on s2t_fhir.mapping_review_event
for each row execute function s2t_fhir.reject_append_only_change();

create view s2t_fhir.current_mapping_review
with (security_barrier = true)
as
with eligible as (
  select e.*
  from s2t_fhir.mapping_review_event e
  where not exists (
    select 1
    from s2t_fhir.mapping_review_event newer
    where newer.supersedes_event_id = e.mapping_review_event_id
  )
), ranked as (
  select e.*,
         row_number() over (
           partition by e.baseline_version_id, e.mapping_record_id
           order by e.occurred_at desc, e.created_at desc, e.mapping_review_event_id desc
         ) as projection_rank
  from eligible e
)
select
  r.mapping_review_event_id,
  r.baseline_version_id,
  r.mapping_record_id,
  rv.value_code as review_status,
  r.occurred_at,
  r.actor_principal_id,
  r.review_session_id,
  r.review_note,
  r.supersedes_event_id
from ranked r
join s2t_fhir.reference_value rv
  on rv.reference_value_id = r.review_status_value_id
join s2t_fhir.reference_domain rd
  on rd.reference_domain_id = rv.reference_domain_id
 and rd.domain_code = 'REVIEW_STATUS'
where r.projection_rank = 1;

revoke all on s2t_fhir.current_mapping_review from public;

-- Safe row-level projection. The private governed node view already applies
-- the ACTIVE/release-passed/committed/accepted eligibility rules and excludes row 77.
create view s2t_fhir_api.active_mapping_review_status
with (security_barrier = true)
as
select
  n.node_id,
  coalesce(cmr.review_status, 'NOT_REVIEWED') as review_status,
  cmr.occurred_at as reviewed_at,
  cmr.review_note,
  rs.session_name
from s2t_fhir_api._active_release_context ctx
join s2t_fhir_api._lovable_mapping_node n
  on n.baseline_code = ctx.baseline_code
join s2t_fhir.logical_mapping_identity lmi
  on lmi.logical_key = n.mapping_key
 and lmi.source_system = ctx.source_system
 and lmi.fhir_resource = ctx.fhir_resource
join s2t_fhir.mapping_record mr
  on mr.baseline_version_id = ctx.baseline_version_id
 and mr.logical_mapping_identity_id = lmi.logical_mapping_identity_id
left join s2t_fhir.current_mapping_review cmr
  on cmr.baseline_version_id = mr.baseline_version_id
 and cmr.mapping_record_id = mr.mapping_record_id
left join s2t_fhir.review_session rs
  on rs.review_session_id = cmr.review_session_id
where ctx.source_system = 'CATO'
  and ctx.fhir_resource = 'MedicationRequest';

revoke all on s2t_fhir_api.active_mapping_review_status from public;

create function s2t_fhir_api.get_active_medication_request_cato_review_progress()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
with context as (
  select c.baseline_code
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest'
), strict_context as (
  select min(c.baseline_code) as baseline_code
  from context c
  having count(*) = 1
), counts as (
  select
    count(*)::bigint as total,
    count(*) filter (where s.review_status = 'REVIEWED')::bigint as reviewed,
    count(*) filter (where s.review_status = 'NEEDS_FOLLOW_UP')::bigint as needs_follow_up
  from s2t_fhir_api.active_mapping_review_status s
), last_review as (
  select s.node_id, s.review_status, s.reviewed_at, s.session_name
  from s2t_fhir_api.active_mapping_review_status s
  where s.reviewed_at is not null
  order by s.reviewed_at desc, s.node_id
  limit 1
)
select jsonb_build_object(
  'baselineCode', sc.baseline_code,
  'total', c.total,
  'reviewed', c.reviewed,
  'notReviewed', c.total - c.reviewed - c.needs_follow_up,
  'needsFollowUp', c.needs_follow_up,
  -- Completion is current REVIEWED / total * 100, rounded to nearest integer.
  'completionPercent', case
    when c.total = 0 then 0
    else round(c.reviewed::numeric * 100 / c.total)::integer
  end,
  'lastReviewed', case
    when lr.node_id is null then null
    else jsonb_strip_nulls(jsonb_build_object(
      'nodeId', lr.node_id,
      'reviewStatus', lr.review_status,
      'occurredAt', lr.reviewed_at,
      'sessionName', lr.session_name
    ))
  end
)
from strict_context sc
cross join counts c
left join last_review lr on true;
$function$;

revoke all on function s2t_fhir_api.get_active_medication_request_cato_review_progress() from public;

-- Actor resolution is intentionally explicit. There is no governed auth.uid()
-- to principal mapping in migrations 001-016, so write RPCs accept only the
-- enabled postgres-role/s2t_fhir_importer principal and are granted only to
-- s2t_fhir_importer. Browser roles remain read-only until such a mapping exists.
create function s2t_fhir_api._assert_review_actor(p_actor_principal_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
begin
  if not exists (
    select 1
    from s2t_fhir.principal p
    where p.principal_id = p_actor_principal_id
      and p.external_issuer = 'postgres-role'
      and p.external_subject = 's2t_fhir_importer'
      and p.disabled_at is null
  ) then
    raise exception 'actor principal is not the enabled S2T FHIR importer principal'
      using errcode = '42501';
  end if;
end
$function$;

create function s2t_fhir_api.start_mapping_review_session(
  p_session_name text,
  p_actor_principal_id uuid,
  p_notes text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  baseline_id uuid;
  context_count integer;
  new_session_id uuid;
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);

  if nullif(btrim(p_session_name), '') is null then
    raise exception 'session name must be nonblank' using errcode = '22023';
  end if;
  if p_notes is not null and nullif(btrim(p_notes), '') is null then
    raise exception 'session notes must be nonblank when supplied' using errcode = '22023';
  end if;

  select count(*) into context_count
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  if context_count <> 1 then
    raise exception 'exactly one active governed CATO MedicationRequest baseline is required'
      using errcode = 'P0002';
  end if;

  select c.baseline_version_id into strict baseline_id
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  insert into s2t_fhir.review_session
    (baseline_version_id, session_name, started_at, created_by_principal_id, notes)
  values
    (baseline_id, btrim(p_session_name), transaction_timestamp(),
     p_actor_principal_id, p_notes)
  returning review_session_id into new_session_id;

  return new_session_id;
end
$function$;

create function s2t_fhir_api.end_mapping_review_session(
  p_session_id uuid,
  p_actor_principal_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  baseline_id uuid;
  context_count integer;
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);

  select count(*) into context_count
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  if context_count <> 1 then
    raise exception 'exactly one active governed CATO MedicationRequest baseline is required'
      using errcode = 'P0002';
  end if;

  select c.baseline_version_id into strict baseline_id
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  update s2t_fhir.review_session rs
  set ended_at = transaction_timestamp(),
      ended_by_principal_id = p_actor_principal_id
  where rs.review_session_id = p_session_id
    and rs.baseline_version_id = baseline_id
    and rs.ended_at is null;

  if not found then
    raise exception 'open review session not found in the active baseline'
      using errcode = 'P0002';
  end if;
end
$function$;

create function s2t_fhir_api._record_mapping_review(
  p_node_id text,
  p_review_status text,
  p_actor_principal_id uuid,
  p_session_id uuid default null,
  p_note text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  target_baseline_id uuid;
  target_mapping_record_id uuid;
  target_count integer;
  status_id uuid;
  previous_event_id uuid;
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);

  if p_note is not null and nullif(btrim(p_note), '') is null then
    raise exception 'review note must be nonblank when supplied' using errcode = '22023';
  end if;

  select count(*) into target_count
  from s2t_fhir_api._active_release_context ctx
  join s2t_fhir_api._lovable_mapping_node n
    on n.baseline_code = ctx.baseline_code
   and n.node_id = p_node_id
  join s2t_fhir.logical_mapping_identity lmi
    on lmi.logical_key = n.mapping_key
   and lmi.source_system = ctx.source_system
   and lmi.fhir_resource = ctx.fhir_resource
  join s2t_fhir.mapping_record mr
    on mr.baseline_version_id = ctx.baseline_version_id
   and mr.logical_mapping_identity_id = lmi.logical_mapping_identity_id
  where ctx.source_system = 'CATO'
    and ctx.fhir_resource = 'MedicationRequest';

  if target_count <> 1 then
    raise exception 'node ID does not resolve uniquely in the active accepted governed mapping set'
      using errcode = 'P0002';
  end if;

  select ctx.baseline_version_id, mr.mapping_record_id
    into strict target_baseline_id, target_mapping_record_id
  from s2t_fhir_api._active_release_context ctx
  join s2t_fhir_api._lovable_mapping_node n
    on n.baseline_code = ctx.baseline_code
   and n.node_id = p_node_id
  join s2t_fhir.logical_mapping_identity lmi
    on lmi.logical_key = n.mapping_key
   and lmi.source_system = ctx.source_system
   and lmi.fhir_resource = ctx.fhir_resource
  join s2t_fhir.mapping_record mr
    on mr.baseline_version_id = ctx.baseline_version_id
   and mr.logical_mapping_identity_id = lmi.logical_mapping_identity_id
  where ctx.source_system = 'CATO'
    and ctx.fhir_resource = 'MedicationRequest';

  -- Lock the immutable mapping row to serialize writers for this node.
  perform 1
  from s2t_fhir.mapping_record mr
  where mr.mapping_record_id = target_mapping_record_id
  for update;

  if p_session_id is not null and not exists (
    select 1
    from s2t_fhir.review_session rs
    where rs.review_session_id = p_session_id
      and rs.baseline_version_id = target_baseline_id
      and rs.ended_at is null
  ) then
    raise exception 'review session is not open in the active mapping baseline'
      using errcode = '23514';
  end if;

  select rv.reference_value_id into strict status_id
  from s2t_fhir.reference_value rv
  join s2t_fhir.reference_domain rd
    on rd.reference_domain_id = rv.reference_domain_id
  where rd.domain_code = 'REVIEW_STATUS'
    and rv.value_code = p_review_status
    and rv.effective_at <= transaction_timestamp()
    and (rv.retired_at is null or rv.retired_at > transaction_timestamp());

  select cmr.mapping_review_event_id into previous_event_id
  from s2t_fhir.current_mapping_review cmr
  where cmr.baseline_version_id = target_baseline_id
    and cmr.mapping_record_id = target_mapping_record_id;

  insert into s2t_fhir.mapping_review_event
    (baseline_version_id, mapping_record_id, review_session_id,
     review_status_value_id, occurred_at, actor_principal_id,
     review_note, supersedes_event_id)
  values
    (target_baseline_id, target_mapping_record_id, p_session_id,
     status_id, transaction_timestamp(), p_actor_principal_id,
     p_note, previous_event_id);
end
$function$;

create function s2t_fhir_api.mark_mapping_reviewed(
  p_node_id text,
  p_actor_principal_id uuid,
  p_session_id uuid default null,
  p_note text default null
)
returns void
language sql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
  select s2t_fhir_api._record_mapping_review(
    p_node_id, 'REVIEWED', p_actor_principal_id, p_session_id, p_note
  );
$function$;

create function s2t_fhir_api.mark_mapping_needs_follow_up(
  p_node_id text,
  p_actor_principal_id uuid,
  p_session_id uuid default null,
  p_note text default null
)
returns void
language sql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
  select s2t_fhir_api._record_mapping_review(
    p_node_id, 'NEEDS_FOLLOW_UP', p_actor_principal_id, p_session_id, p_note
  );
$function$;

create function s2t_fhir_api.clear_mapping_review(
  p_node_id text,
  p_actor_principal_id uuid,
  p_session_id uuid default null,
  p_note text default null
)
returns void
language sql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
  select s2t_fhir_api._record_mapping_review(
    p_node_id, 'NOT_REVIEWED', p_actor_principal_id, p_session_id, p_note
  );
$function$;

revoke all on function s2t_fhir_api._assert_review_actor(uuid) from public;
revoke all on function s2t_fhir_api._record_mapping_review(text, text, uuid, uuid, text) from public;
revoke all on function s2t_fhir_api.start_mapping_review_session(text, uuid, text) from public;
revoke all on function s2t_fhir_api.end_mapping_review_session(uuid, uuid) from public;
revoke all on function s2t_fhir_api.mark_mapping_reviewed(text, uuid, uuid, text) from public;
revoke all on function s2t_fhir_api.mark_mapping_needs_follow_up(text, uuid, uuid, text) from public;
revoke all on function s2t_fhir_api.clear_mapping_review(text, uuid, uuid, text) from public;

grant select on s2t_fhir_api.active_mapping_review_status to s2t_fhir_api_reader;
grant execute on function s2t_fhir_api.get_active_medication_request_cato_review_progress()
  to s2t_fhir_api_reader;

grant usage on schema s2t_fhir_api to s2t_fhir_importer;
grant execute on function s2t_fhir_api.start_mapping_review_session(text, uuid, text)
  to s2t_fhir_importer;
grant execute on function s2t_fhir_api.end_mapping_review_session(uuid, uuid)
  to s2t_fhir_importer;
grant execute on function s2t_fhir_api.mark_mapping_reviewed(text, uuid, uuid, text)
  to s2t_fhir_importer;
grant execute on function s2t_fhir_api.mark_mapping_needs_follow_up(text, uuid, uuid, text)
  to s2t_fhir_importer;
grant execute on function s2t_fhir_api.clear_mapping_review(text, uuid, uuid, text)
  to s2t_fhir_importer;

do $block$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant select on s2t_fhir_api.active_mapping_review_status to anon';
    execute 'grant execute on function s2t_fhir_api.get_active_medication_request_cato_review_progress() to anon';
    execute 'revoke all on function s2t_fhir_api.start_mapping_review_session(text, uuid, text) from anon';
    execute 'revoke all on function s2t_fhir_api.end_mapping_review_session(uuid, uuid) from anon';
    execute 'revoke all on function s2t_fhir_api.mark_mapping_reviewed(text, uuid, uuid, text) from anon';
    execute 'revoke all on function s2t_fhir_api.mark_mapping_needs_follow_up(text, uuid, uuid, text) from anon';
    execute 'revoke all on function s2t_fhir_api.clear_mapping_review(text, uuid, uuid, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on s2t_fhir_api.active_mapping_review_status to authenticated';
    execute 'grant execute on function s2t_fhir_api.get_active_medication_request_cato_review_progress() to authenticated';
    execute 'revoke all on function s2t_fhir_api.start_mapping_review_session(text, uuid, text) from authenticated';
    execute 'revoke all on function s2t_fhir_api.end_mapping_review_session(uuid, uuid) from authenticated';
    execute 'revoke all on function s2t_fhir_api.mark_mapping_reviewed(text, uuid, uuid, text) from authenticated';
    execute 'revoke all on function s2t_fhir_api.mark_mapping_needs_follow_up(text, uuid, uuid, text) from authenticated';
    execute 'revoke all on function s2t_fhir_api.clear_mapping_review(text, uuid, uuid, text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke all on s2t_fhir.review_session, s2t_fhir.mapping_review_event from service_role';
    execute 'revoke all on s2t_fhir_api.active_mapping_review_status from service_role';
    execute 'revoke all on function s2t_fhir_api.get_active_medication_request_cato_review_progress() from service_role';
    execute 'revoke all on function s2t_fhir_api.start_mapping_review_session(text, uuid, text) from service_role';
    execute 'revoke all on function s2t_fhir_api.end_mapping_review_session(uuid, uuid) from service_role';
    execute 'revoke all on function s2t_fhir_api.mark_mapping_reviewed(text, uuid, uuid, text) from service_role';
    execute 'revoke all on function s2t_fhir_api.mark_mapping_needs_follow_up(text, uuid, uuid, text) from service_role';
    execute 'revoke all on function s2t_fhir_api.clear_mapping_review(text, uuid, uuid, text) from service_role';
  end if;
end
$block$;

-- No direct base-table access is granted to anon/authenticated/importer.
revoke all on s2t_fhir.review_session, s2t_fhir.mapping_review_event from public;

reset role;

-- Verification queries (review/run separately; intentionally not executed here):
--
-- A. Exact REVIEW_STATUS values.
-- select array_agg(rv.value_code order by rv.value_code)
-- from s2t_fhir.reference_value rv
-- join s2t_fhir.reference_domain rd using (reference_domain_id)
-- where rd.domain_code = 'REVIEW_STATUS';
-- Expected: {NEEDS_FOLLOW_UP,NOT_REVIEWED,REVIEWED} and count(*) = 3.
--
-- B. Initial progress.
-- select s2t_fhir_api.get_active_medication_request_cato_review_progress();
-- Expected: total/reviewed/notReviewed/needsFollowUp/completionPercent = 292/0/292/0/0.
--
-- C. Initial row status.
-- select count(*), count(*) filter (where review_status = 'NOT_REVIEWED')
-- from s2t_fhir_api.active_mapping_review_status;
-- Expected: 292, 292.
--
-- D. Row 77 absent (join only for governance testing; API itself exposes no source row).
-- select count(*)
-- from s2t_fhir_api.active_mapping_review_status r
-- join s2t_fhir_api._lovable_mapping_node n on n.node_id = r.node_id
-- where n.source_sheet = 'S2T MedicationRequestCato' and n.source_row = 77;
-- Expected: 0.
--
-- E. Start a session as s2t_fhir_importer (capture returned UUID as :session_id).
-- select s2t_fhir_api.start_mapping_review_session(
--   'MedicationRequest DR #1',
--   (select principal_id from s2t_fhir.principal
--    where external_issuer = 'postgres-role' and external_subject = 's2t_fhir_importer'),
--   null
-- );
--
-- F. Mark one mapping REVIEWED (replace :node_1 and :session_id).
-- select s2t_fhir_api.mark_mapping_reviewed(
--   :node_1, :importer_principal_id, :session_id, 'Reviewed in DR #1'
-- );
--
-- G. Progress expected: reviewed = 1, notReviewed = 291.
-- select s2t_fhir_api.get_active_medication_request_cato_review_progress();
--
-- H. Mark a second mapping NEEDS_FOLLOW_UP.
-- select s2t_fhir_api.mark_mapping_needs_follow_up(
--   :node_2, :importer_principal_id, :session_id, 'Clarification required'
-- );
--
-- I. Progress expected: reviewed = 1, needsFollowUp = 1, notReviewed = 290.
-- select s2t_fhir_api.get_active_medication_request_cato_review_progress();
--
-- J. Change the follow-up row to REVIEWED and inspect its append-only chain.
-- select s2t_fhir_api.mark_mapping_reviewed(
--   :node_2, :importer_principal_id, :session_id, 'Clarified and reviewed'
-- );
-- select e.mapping_review_event_id, e.supersedes_event_id, rv.value_code, e.occurred_at
-- from s2t_fhir.mapping_review_event e
-- join s2t_fhir.reference_value rv on rv.reference_value_id = e.review_status_value_id
-- where e.mapping_record_id = (
--   select mr.mapping_record_id
--   from s2t_fhir.mapping_record mr
--   join s2t_fhir.logical_mapping_identity lmi using (logical_mapping_identity_id)
--   join s2t_fhir_api._lovable_mapping_node n on n.mapping_key = lmi.logical_key
--   where n.node_id = :node_2
-- ) order by e.created_at;
-- Expected: NEEDS_FOLLOW_UP then REVIEWED; current view returns REVIEWED only.
--
-- K. End session.
-- select s2t_fhir_api.end_mapping_review_session(:session_id, :importer_principal_id);
--
-- L. Cross-baseline mismatch: pass a session from another baseline to a mark RPC.
-- Expected SQLSTATE 23514.
--
-- M. Quarantined/nonexistent node ID.
-- select s2t_fhir_api.mark_mapping_reviewed(
--   'map-v1-' || repeat('0', 64), :importer_principal_id, null, null
-- );
-- Expected failure; row 77 cannot resolve through _lovable_mapping_node.
--
-- N. Append-only enforcement.
-- update s2t_fhir.mapping_review_event set review_note = 'changed'
-- where mapping_review_event_id = :event_id;
-- delete from s2t_fhir.mapping_review_event where mapping_review_event_id = :event_id;
-- Expected: both fail with SQLSTATE 55000. A second session end also fails.
--
-- O. Privileges.
-- select r.rolname,
--   has_table_privilege(r.rolname, 's2t_fhir.mapping_review_event', 'INSERT,UPDATE,DELETE') as direct_event_write,
--   has_table_privilege(r.rolname, 's2t_fhir.review_session', 'INSERT,UPDATE,DELETE') as direct_session_write,
--   has_table_privilege(r.rolname, 's2t_fhir_api.active_mapping_review_status', 'SELECT') as api_read,
--   has_function_privilege(r.rolname,
--     's2t_fhir_api.mark_mapping_reviewed(text,uuid,uuid,text)', 'EXECUTE') as write_rpc
-- from pg_roles r where r.rolname in ('public','anon','authenticated','service_role','s2t_fhir_importer');
-- Expected: no direct writes; anon/authenticated read only; importer write RPC only; PUBLIC blocked.
--
-- P. No internal identifier leakage.
-- select column_name from information_schema.columns
-- where table_schema = 's2t_fhir_api'
--   and table_name = 'active_mapping_review_status'
--   and (column_name like '%\_id' escape '\' or column_name in ('mapping_key','actor_principal_id'));
-- Expected: no rows. Inspect progress JSON for UUID patterns; expected none.
--
-- Q. Performance (run with EXPLAIN (ANALYZE, BUFFERS)).
-- select s2t_fhir_api.get_active_medication_request_cato_review_progress();
-- select * from s2t_fhir_api.active_mapping_review_status;
-- Expected: each comfortably below one second for BL-001.

-- Migration 023 -- governed candidate workflow.
--
-- CHECKPOINTS 1-4 (Sections 1-13):
--   * deployment preconditions;
--   * baseline upload/promotion authorization foundation;
--   * append-only candidate publication context;
--   * candidate context integrity;
--   * atomic candidate publication/replacement.
--
-- Checkpoint 2 adds explicit Candidate mapping reads and Candidate Review while
-- leaving the approved Checkpoint 1 behavior unchanged. Checkpoint 3 adds an
-- explicit Candidate governance-link path without changing ACTIVE governance.
-- Checkpoint 4 adds governed ACTIVE eligibility and atomic Promotion.
--
-- Deliberately not implemented at these checkpoints: diff/change detection,
-- review carry-forward or invalidation, governance blocking, UI behavior, or
-- the final migration-wide privilege/verification package.

begin;

set role s2t_fhir_owner;

-- -----------------------------------------------------------------------------
-- Section 1. Deployment preconditions
-- -----------------------------------------------------------------------------

do $preflight$
declare
  v_count integer;
  v_object_name text;
  v_owner text;
  v_security_definer boolean;
  v_volatile "char";
  v_config text[];
  v_migrator_principal_id uuid;
begin
  -- Required roles.
  foreach v_object_name in array array[
    's2t_fhir_owner', 's2t_fhir_importer', 'authenticated', 'anon', 'service_role'
  ] loop
    if not exists (select 1 from pg_catalog.pg_roles r where r.rolname = v_object_name) then
      raise exception '023 precondition: required role % is missing', v_object_name
        using errcode = '55000';
    end if;
  end loop;

  -- Required accepted relations.
  foreach v_object_name in array array[
    's2t_fhir.baseline_series',
    's2t_fhir.baseline_version',
    's2t_fhir.baseline_relationship',
    's2t_fhir.baseline_lifecycle_event',
    's2t_fhir.current_baseline_lifecycle_event',
    's2t_fhir.artifact',
    's2t_fhir.baseline_artifact',
    's2t_fhir.import_run',
    's2t_fhir.principal',
    's2t_fhir.reference_domain',
    's2t_fhir.reference_value',
    's2t_fhir.review_actor_authorization',
    's2t_fhir_api._active_release_context'
  ] loop
    if pg_catalog.to_regclass(v_object_name) is null then
      raise exception '023 precondition: required relation % is missing', v_object_name
        using errcode = '55000';
    end if;
  end loop;

  select p.principal_id
    into strict v_migrator_principal_id
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null;

  -- Columns used by Checkpoint 1. Any name drift fails closed.
  if exists (
    select 1
    from (values
      ('s2t_fhir.baseline_series', 'baseline_series_id'),
      ('s2t_fhir.baseline_version', 'baseline_version_id'),
      ('s2t_fhir.baseline_version', 'baseline_series_id'),
      ('s2t_fhir.baseline_lifecycle_event', 'baseline_lifecycle_event_id'),
      ('s2t_fhir.baseline_lifecycle_event', 'baseline_version_id'),
      ('s2t_fhir.baseline_lifecycle_event', 'lifecycle_status_value_id'),
      ('s2t_fhir.baseline_lifecycle_event', 'occurred_at'),
      ('s2t_fhir.baseline_lifecycle_event', 'actor_principal_id'),
      ('s2t_fhir.baseline_lifecycle_event', 'initiating_human_principal_id'),
      ('s2t_fhir.baseline_lifecycle_event', 'reason'),
      ('s2t_fhir.baseline_lifecycle_event', 'supersedes_event_id'),
      ('s2t_fhir.baseline_artifact', 'baseline_version_id'),
      ('s2t_fhir.baseline_artifact', 'artifact_id'),
      ('s2t_fhir.baseline_artifact', 'artifact_role_value_id'),
      ('s2t_fhir.import_run', 'import_run_id'),
      ('s2t_fhir.import_run', 'baseline_version_id'),
      ('s2t_fhir.import_run', 'artifact_id'),
      ('s2t_fhir.import_run', 'completed_at'),
      ('s2t_fhir.import_run', 'terminal_status_value_id'),
      ('s2t_fhir.baseline_relationship', 'from_baseline_version_id'),
      ('s2t_fhir.baseline_relationship', 'to_baseline_version_id'),
      ('s2t_fhir.baseline_relationship', 'relationship_type_value_id')
    ) required(relation_name, column_name)
    where not exists (
      select 1
      from pg_catalog.pg_attribute a
      where a.attrelid = pg_catalog.to_regclass(required.relation_name)
        and a.attname = required.column_name
        and a.attnum > 0
        and not a.attisdropped
    )
  ) then
    raise exception '023 precondition: one or more required Checkpoint 1 columns are missing'
      using errcode = '55000';
  end if;

  -- Migration 022 lifecycle vocabulary must be exact and non-versioned.
  select count(*) into v_count
  from s2t_fhir.reference_domain d
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and d.is_versioned = false;
  if v_count <> 1 then
    raise exception '023 precondition: expected exactly one non-versioned BASELINE_LIFECYCLE_STATUS domain; found %', v_count
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS';
  if v_count <> 5 then
    raise exception '023 precondition: expected exactly five approved lifecycle values; found %', v_count
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from (values
      ('PENDING_APPROVAL'), ('ACTIVE'), ('RETIRED'),
      ('CANDIDATE'), ('SUPERSEDED')
    ) expected(value_code)
    where (
      select count(*)
      from s2t_fhir.reference_value v
      join s2t_fhir.reference_domain d
        on d.reference_domain_id = v.reference_domain_id
      where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
        and v.value_code = expected.value_code
    ) <> 1
  ) then
    raise exception '023 precondition: required lifecycle reference values are missing or duplicated'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from s2t_fhir.reference_value v
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      and (
        (v.value_code in ('PENDING_APPROVAL', 'ACTIVE', 'RETIRED') and (
          v.version_number <> 1
          or not v.is_bootstrap_seed
          or v.retired_at is not null
          or v.created_by_principal_id is not null
        ))
        or
        (v.value_code in ('CANDIDATE', 'SUPERSEDED') and (
          v.version_number <> 1
          or v.is_bootstrap_seed
          or v.retired_at is not null
          or v.created_by_principal_id is distinct from v_migrator_principal_id
        ))
      )
  ) then
    raise exception '023 precondition: Migration 022 lifecycle reference metadata drift detected'
      using errcode = '55000';
  end if;

  foreach v_object_name in array array[
    'ARTIFACT_ROLE:AUTHORITATIVE_SOURCE',
    'IMPORT_RUN_STATUS:COMMITTED',
    'BASELINE_RELATIONSHIP_TYPE:SUPERSEDES'
  ] loop
    select count(*) into v_count
    from s2t_fhir.reference_value v
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where d.domain_code = pg_catalog.split_part(v_object_name, ':', 1)
      and v.value_code = pg_catalog.split_part(v_object_name, ':', 2);
    if v_count <> 1 then
      raise exception '023 precondition: expected exactly one reference value %; found %', v_object_name, v_count
        using errcode = '55000';
    end if;
  end loop;

  -- Migration 022 functions must retain their security contract.
  foreach v_object_name in array array[
    's2t_fhir.validate_baseline_lifecycle_insert()',
    's2t_fhir.assert_baseline_series_lifecycle(uuid)',
    's2t_fhir.check_baseline_series_lifecycle()'
  ] loop
    select r.rolname, p.prosecdef, p.provolatile, p.proconfig
      into v_owner, v_security_definer, v_volatile, v_config
    from pg_catalog.pg_proc p
    join pg_catalog.pg_roles r on r.oid = p.proowner
    where p.oid = pg_catalog.to_regprocedure(v_object_name);

    if not found
       or v_owner <> 's2t_fhir_owner'
       or not v_security_definer
       or v_volatile <> 'v'
       or not (coalesce(v_config, array[]::text[]) && array['search_path=', 'search_path=""']) then
      raise exception '023 precondition: Migration 022 function contract drift detected for %', v_object_name
        using errcode = '55000';
    end if;
  end loop;

  -- Exact 022 uniqueness and trigger properties.
  if not exists (
    select 1
    from pg_catalog.pg_class i
    join pg_catalog.pg_namespace n on n.oid = i.relnamespace
    join pg_catalog.pg_index x on x.indexrelid = i.oid
    join pg_catalog.pg_am am on am.oid = i.relam
    where n.nspname = 's2t_fhir'
      and i.relname = 'baseline_lifecycle_root_once_uq'
      and i.relkind = 'i'
      and am.amname = 'btree'
      and x.indrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
      and x.indisunique and x.indisvalid and x.indisready
      and x.indnkeyatts = 1 and x.indnatts = 1
      and pg_catalog.pg_get_indexdef(i.oid, 1, true) = 'baseline_version_id'
      and pg_catalog.pg_get_expr(x.indpred, x.indrelid) = '(supersedes_event_id IS NULL)'
  ) then
    raise exception '023 precondition: baseline_lifecycle_root_once_uq contract drift'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class i
    join pg_catalog.pg_namespace n on n.oid = i.relnamespace
    join pg_catalog.pg_index x on x.indexrelid = i.oid
    join pg_catalog.pg_am am on am.oid = i.relam
    where n.nspname = 's2t_fhir'
      and i.relname = 'baseline_lifecycle_superseded_once_uq'
      and i.relkind = 'i'
      and am.amname = 'btree'
      and x.indrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
      and x.indisunique and x.indisvalid and x.indisready
      and x.indnkeyatts = 1 and x.indnatts = 1
      and pg_catalog.pg_get_indexdef(i.oid, 1, true) = 'supersedes_event_id'
      and pg_catalog.pg_get_expr(x.indpred, x.indrelid) = '(supersedes_event_id IS NOT NULL)'
  ) then
    raise exception '023 precondition: baseline_lifecycle_superseded_once_uq contract drift'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_trigger t
    where t.tgrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
      and t.tgname = 'baseline_lifecycle_transition_trg'
      and not t.tgisinternal
      and t.tgtype = 7
      and not t.tgdeferrable
      and t.tgenabled <> 'D'
      and t.tgfoid = 's2t_fhir.validate_baseline_lifecycle_insert()'::regprocedure
  ) then
    raise exception '023 precondition: baseline_lifecycle_transition_trg contract drift'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_trigger t
    where t.tgrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
      and t.tgname = 'baseline_series_lifecycle_cardinality_trg'
      and not t.tgisinternal
      and t.tgtype = 5
      and t.tgdeferrable
      and t.tginitdeferred
      and t.tgenabled <> 'D'
      and t.tgfoid = 's2t_fhir.check_baseline_series_lifecycle()'::regprocedure
  ) then
    raise exception '023 precondition: baseline_series_lifecycle_cardinality_trg contract drift'
      using errcode = '55000';
  end if;

  -- Authenticated identity resolution used by the new wrapper must remain private
  -- and SECURITY DEFINER.
  select r.rolname, p.prosecdef, p.provolatile
    into v_owner, v_security_definer, v_volatile
  from pg_catalog.pg_proc p
  join pg_catalog.pg_roles r on r.oid = p.proowner
  where p.oid = pg_catalog.to_regprocedure('s2t_fhir_api._resolve_authenticated_principal()');
  if not found or v_owner <> 's2t_fhir_owner' or not v_security_definer or v_volatile <> 's' then
    raise exception '023 precondition: authenticated principal resolver contract drift'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_roles r on r.oid = p.proowner
    where p.oid = pg_catalog.to_regprocedure('s2t_fhir_api._assert_review_actor(uuid)')
      and r.rolname = 's2t_fhir_owner'
      and p.prosecdef
      and p.provolatile = 's'
  ) then
    raise exception '023 precondition: importer actor assertion contract drift'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_roles r on r.oid = p.proowner
    where p.oid = pg_catalog.to_regprocedure('s2t_fhir.check_actor_pair()')
      and r.rolname = 's2t_fhir_owner'
      and p.prosecdef
      and p.provolatile = 'v'
  ) or not exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_roles r on r.oid = p.proowner
    where p.oid = pg_catalog.to_regprocedure('s2t_fhir.reject_append_only_change()')
      and r.rolname = 's2t_fhir_owner'
      and not p.prosecdef
      and p.provolatile = 'v'
  ) then
    raise exception '023 precondition: accepted integrity helper contract drift'
      using errcode = '55000';
  end if;

  -- Existing lifecycle state must still meet the 022 final cardinality contract.
  if exists (
    with current_state as (
      select bv.baseline_series_id, v.value_code
      from s2t_fhir.baseline_version bv
      join s2t_fhir.baseline_lifecycle_event e
        on e.baseline_version_id = bv.baseline_version_id
      join s2t_fhir.reference_value v
        on v.reference_value_id = e.lifecycle_status_value_id
      where not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      )
    )
    select 1
    from current_state s
    group by s.baseline_series_id
    having count(*) filter (where s.value_code = 'ACTIVE') > 1
        or count(*) filter (where s.value_code in ('CANDIDATE', 'PENDING_APPROVAL')) > 1
  ) then
    raise exception '023 precondition: existing lifecycle cardinality violates Migration 022'
      using errcode = '55000';
  end if;

  -- Checkpoint 1 must be a first installation.
  if pg_catalog.to_regclass('s2t_fhir.baseline_action_authorization') is not null
     or pg_catalog.to_regclass('s2t_fhir.baseline_candidate_context') is not null
     or pg_catalog.to_regprocedure('s2t_fhir.protect_baseline_action_authorization_update()') is not null
     or pg_catalog.to_regprocedure('s2t_fhir_api._require_authenticated_baseline_capability(text)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir.grant_baseline_action(uuid,text,uuid)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir.revoke_baseline_action(uuid,text,uuid)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir.validate_baseline_candidate_context()') is not null
     or pg_catalog.to_regprocedure('s2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)') is not null then
    raise exception '023 precondition: one or more Checkpoint 1 objects already exist'
      using errcode = '55000';
  end if;
end
$preflight$;

-- -----------------------------------------------------------------------------
-- Section 2. Authorization foundation
-- -----------------------------------------------------------------------------

create table s2t_fhir.baseline_action_authorization (
  baseline_action_authorization_id uuid primary key default gen_random_uuid(),
  principal_id uuid not null references s2t_fhir.principal(principal_id),
  capability_code text not null,
  effective_at timestamptz not null default transaction_timestamp(),
  revoked_at timestamptz,
  granted_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  revoked_by_principal_id uuid references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint baseline_action_authorization_capability_ck check (
    capability_code in ('S2T_BASELINE_UPLOAD', 'S2T_BASELINE_PROMOTE')
  ),
  constraint baseline_action_authorization_revoke_pair_ck check (
    (revoked_at is null) = (revoked_by_principal_id is null)
  ),
  constraint baseline_action_authorization_time_ck check (
    revoked_at is null or revoked_at >= effective_at
  ),
  constraint baseline_action_authorization_created_ck check (
    created_at >= effective_at
  )
);

create unique index baseline_action_authorization_active_uq
  on s2t_fhir.baseline_action_authorization (principal_id, capability_code)
  where revoked_at is null;

create index baseline_action_authorization_lookup_idx
  on s2t_fhir.baseline_action_authorization
  (principal_id, capability_code, effective_at, revoked_at);

create function s2t_fhir.protect_baseline_action_authorization_update()
returns trigger
language plpgsql
volatile
set search_path = ''
as $function$
begin
  if old.revoked_at is not null then
    raise exception 'revoked baseline action authorization is immutable'
      using errcode = '55000';
  end if;

  if new.baseline_action_authorization_id is distinct from old.baseline_action_authorization_id
     or new.principal_id is distinct from old.principal_id
     or new.capability_code is distinct from old.capability_code
     or new.effective_at is distinct from old.effective_at
     or new.granted_by_principal_id is distinct from old.granted_by_principal_id
     or new.created_at is distinct from old.created_at then
    raise exception 'immutable baseline action authorization fields cannot be changed'
      using errcode = '55000';
  end if;

  if new.revoked_at is null or new.revoked_by_principal_id is null then
    raise exception 'a baseline action authorization update must revoke the grant once'
      using errcode = '55000';
  end if;

  return new;
end
$function$;

create trigger baseline_action_authorization_protect_update_trg
before update on s2t_fhir.baseline_action_authorization
for each row
execute function s2t_fhir.protect_baseline_action_authorization_update();

create trigger baseline_action_authorization_reject_delete_trg
before delete on s2t_fhir.baseline_action_authorization
for each row
execute function s2t_fhir.reject_append_only_change();

create function s2t_fhir_api._require_authenticated_baseline_capability(
  p_capability_code text
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_principal_id uuid;
  v_count integer;
begin
  if p_capability_code not in ('S2T_BASELINE_UPLOAD', 'S2T_BASELINE_PROMOTE') then
    raise exception 'unsupported baseline capability %', p_capability_code
      using errcode = '22023';
  end if;

  v_principal_id := s2t_fhir_api._resolve_authenticated_principal();

  select count(*) into v_count
  from s2t_fhir.baseline_action_authorization a
  where a.principal_id = v_principal_id
    and a.capability_code = p_capability_code
    and a.effective_at <= pg_catalog.transaction_timestamp()
    and a.revoked_at is null;

  if v_count = 0 then
    raise exception 'authenticated principal is not authorized for %', p_capability_code
      using errcode = '42501';
  elsif v_count <> 1 then
    raise exception 'authenticated principal authorization for % is ambiguous', p_capability_code
      using errcode = '42501';
  end if;

  return v_principal_id;
end
$function$;

create function s2t_fhir.grant_baseline_action(
  p_principal_id uuid,
  p_capability_code text,
  p_granted_by_principal_id uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_authorization_id uuid;
begin
  perform s2t_fhir_api._assert_review_actor(p_granted_by_principal_id);

  if p_capability_code not in ('S2T_BASELINE_UPLOAD', 'S2T_BASELINE_PROMOTE') then
    raise exception 'unsupported baseline capability %', p_capability_code
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from s2t_fhir.principal p
    where p.principal_id = p_principal_id
      and p.external_issuer = 'supabase-auth'
      and p.disabled_at is null
  ) then
    raise exception 'target must be an active Supabase-authenticated principal'
      using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from s2t_fhir.baseline_action_authorization a
    where a.principal_id = p_principal_id
      and a.capability_code = p_capability_code
      and a.revoked_at is null
  ) then
    raise exception 'principal already has active % authorization', p_capability_code
      using errcode = '23505';
  end if;

  insert into s2t_fhir.baseline_action_authorization
    (principal_id, capability_code, effective_at, granted_by_principal_id)
  values
    (p_principal_id, p_capability_code, pg_catalog.transaction_timestamp(),
     p_granted_by_principal_id)
  returning baseline_action_authorization_id into v_authorization_id;

  return v_authorization_id;
end
$function$;

create function s2t_fhir.revoke_baseline_action(
  p_principal_id uuid,
  p_capability_code text,
  p_revoked_by_principal_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  perform s2t_fhir_api._assert_review_actor(p_revoked_by_principal_id);

  if p_capability_code not in ('S2T_BASELINE_UPLOAD', 'S2T_BASELINE_PROMOTE') then
    raise exception 'unsupported baseline capability %', p_capability_code
      using errcode = '22023';
  end if;

  update s2t_fhir.baseline_action_authorization a
  set revoked_at = pg_catalog.transaction_timestamp(),
      revoked_by_principal_id = p_revoked_by_principal_id
  where a.principal_id = p_principal_id
    and a.capability_code = p_capability_code
    and a.revoked_at is null;

  if not found then
    raise exception 'active % authorization not found', p_capability_code
      using errcode = 'P0002';
  end if;
end
$function$;

-- -----------------------------------------------------------------------------
-- Section 3. Candidate publication context
-- -----------------------------------------------------------------------------

create table s2t_fhir.baseline_candidate_context (
  baseline_candidate_context_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null
    references s2t_fhir.baseline_version(baseline_version_id),
  candidate_lifecycle_event_id uuid not null
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id),
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  import_run_id uuid not null references s2t_fhir.import_run(import_run_id),
  effective_at timestamptz not null,
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint baseline_candidate_context_baseline_uq unique (baseline_version_id),
  constraint baseline_candidate_context_event_uq unique (candidate_lifecycle_event_id),
  constraint baseline_candidate_context_import_uq unique (import_run_id),
  constraint baseline_candidate_context_time_ck check (created_at >= effective_at)
);

create index baseline_candidate_context_artifact_idx
  on s2t_fhir.baseline_candidate_context (artifact_id);

create index baseline_candidate_context_created_idx
  on s2t_fhir.baseline_candidate_context (created_at, baseline_candidate_context_id);

-- -----------------------------------------------------------------------------
-- Section 4. Candidate context integrity and immutability
-- -----------------------------------------------------------------------------

create function s2t_fhir.validate_baseline_candidate_context()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_series_id uuid;
  v_event_baseline_id uuid;
  v_event_status text;
  v_event_domain text;
  v_event_occurred_at timestamptz;
  v_event_predecessor uuid;
  v_event_actor_id uuid;
  v_event_initiating_human_id uuid;
  v_authoritative_count integer;
  v_import_baseline_id uuid;
  v_import_artifact_id uuid;
  v_import_completed_at timestamptz;
  v_import_status text;
  v_import_status_domain text;
begin
  select bv.baseline_series_id
    into v_series_id
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = new.baseline_version_id;

  if not found then
    raise exception 'candidate context baseline % does not exist', new.baseline_version_id
      using errcode = '23503';
  end if;

  perform 1
  from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = v_series_id
  for update;

  select e.baseline_version_id, v.value_code, d.domain_code,
         e.occurred_at, e.supersedes_event_id,
         e.actor_principal_id, e.initiating_human_principal_id
    into v_event_baseline_id, v_event_status, v_event_domain,
         v_event_occurred_at, v_event_predecessor,
         v_event_actor_id, v_event_initiating_human_id
  from s2t_fhir.baseline_lifecycle_event e
  join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where e.baseline_lifecycle_event_id = new.candidate_lifecycle_event_id;

  if not found then
    raise exception 'candidate lifecycle event % does not exist', new.candidate_lifecycle_event_id
      using errcode = '23503';
  end if;

  if v_event_baseline_id <> new.baseline_version_id
     or v_event_domain <> 'BASELINE_LIFECYCLE_STATUS'
     or v_event_status <> 'CANDIDATE'
     or v_event_predecessor is not null then
    raise exception 'candidate context must reference the baseline root CANDIDATE event'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event successor
    where successor.supersedes_event_id = new.candidate_lifecycle_event_id
  ) then
    raise exception 'candidate context must be created while its CANDIDATE event is current'
      using errcode = '23514';
  end if;

  if new.effective_at is distinct from v_event_occurred_at then
    raise exception 'candidate context effective_at must equal its CANDIDATE event occurred_at'
      using errcode = '23514';
  end if;

  if new.actor_principal_id is distinct from v_event_actor_id
     or new.initiating_human_principal_id is distinct from v_event_initiating_human_id then
    raise exception 'candidate context actor provenance must match its CANDIDATE event'
      using errcode = '23514';
  end if;

  select count(*) into v_authoritative_count
  from s2t_fhir.baseline_artifact ba
  join s2t_fhir.reference_value v
    on v.reference_value_id = ba.artifact_role_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where ba.baseline_version_id = new.baseline_version_id
    and ba.artifact_id = new.artifact_id
    and d.domain_code = 'ARTIFACT_ROLE'
    and v.value_code = 'AUTHORITATIVE_SOURCE';

  if v_authoritative_count <> 1 then
    raise exception 'candidate context requires its exact authoritative artifact relationship'
      using errcode = '23514';
  end if;

  if (
    select count(*)
    from s2t_fhir.baseline_artifact ba
    join s2t_fhir.reference_value v
      on v.reference_value_id = ba.artifact_role_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where ba.baseline_version_id = new.baseline_version_id
      and d.domain_code = 'ARTIFACT_ROLE'
      and v.value_code = 'AUTHORITATIVE_SOURCE'
  ) <> 1 then
    raise exception 'candidate baseline % requires exactly one authoritative artifact', new.baseline_version_id
      using errcode = '23514';
  end if;

  select ir.baseline_version_id, ir.artifact_id, ir.completed_at,
         v.value_code, d.domain_code
    into v_import_baseline_id, v_import_artifact_id, v_import_completed_at,
         v_import_status, v_import_status_domain
  from s2t_fhir.import_run ir
  join s2t_fhir.reference_value v
    on v.reference_value_id = ir.terminal_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where ir.import_run_id = new.import_run_id;

  if not found then
    raise exception 'candidate context import run % does not exist or is not terminal', new.import_run_id
      using errcode = '23503';
  end if;

  if v_import_baseline_id <> new.baseline_version_id
     or v_import_artifact_id <> new.artifact_id
     or v_import_completed_at is null
     or v_import_status_domain <> 'IMPORT_RUN_STATUS'
     or v_import_status <> 'COMMITTED' then
    raise exception 'candidate context import must be COMMITTED for the same baseline and authoritative artifact'
      using errcode = '23514';
  end if;

  if new.effective_at < v_import_completed_at then
    raise exception 'candidate context effective_at cannot precede committed import completion'
      using errcode = '23514';
  end if;

  return new;
end
$function$;

create trigger baseline_candidate_context_integrity_trg
before insert on s2t_fhir.baseline_candidate_context
for each row
execute function s2t_fhir.validate_baseline_candidate_context();

create trigger baseline_candidate_context_actor_pair_trg
before insert on s2t_fhir.baseline_candidate_context
for each row
execute function s2t_fhir.check_actor_pair(
  'actor_principal_id', 'initiating_human_principal_id'
);

create trigger baseline_candidate_context_append_only_trg
before update or delete on s2t_fhir.baseline_candidate_context
for each row
execute function s2t_fhir.reject_append_only_change();

-- -----------------------------------------------------------------------------
-- Section 5. Candidate Replacement core and authenticated wrapper
-- -----------------------------------------------------------------------------

create function s2t_fhir.replace_current_candidate(
  p_new_baseline_version_id uuid,
  p_new_import_run_id uuid,
  p_expected_candidate_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_occurred_at timestamptz,
  p_replacement_reason text,
  p_actor_principal_id uuid,
  p_initiating_human_principal_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_series_id uuid;
  v_candidate_count integer;
  v_current_candidate_baseline_id uuid;
  v_current_candidate_event_id uuid;
  v_current_candidate_status text;
  v_current_candidate_occurred_at timestamptz;
  v_active_count_before integer;
  v_active_baseline_before uuid;
  v_active_event_before uuid;
  v_active_count_after integer;
  v_active_baseline_after uuid;
  v_active_event_after uuid;
  v_authoritative_count integer;
  v_artifact_id uuid;
  v_import_baseline_id uuid;
  v_import_artifact_id uuid;
  v_import_completed_at timestamptz;
  v_import_status text;
  v_import_status_domain text;
  v_candidate_status_id uuid;
  v_superseded_status_id uuid;
  v_supersedes_relationship_id uuid;
  v_old_superseded_event_id uuid;
  v_new_candidate_event_id uuid;
  v_context_id uuid;
  v_relationship_id uuid;
begin
  if p_new_baseline_version_id is null or p_new_import_run_id is null then
    raise exception 'new baseline version and import run are required'
      using errcode = '22023';
  end if;

  if (p_expected_candidate_baseline_version_id is null)
     <> (p_expected_candidate_lifecycle_event_id is null) then
    raise exception 'expected candidate baseline and lifecycle event must be both null or both non-null'
      using errcode = '22023';
  end if;

  if p_occurred_at is null then
    raise exception 'candidate publication occurred_at is required'
      using errcode = '22023';
  end if;

  if p_occurred_at > pg_catalog.transaction_timestamp() then
    raise exception 'candidate publication occurred_at cannot be in the future'
      using errcode = '22023';
  end if;

  if p_replacement_reason is not null
     and nullif(pg_catalog.btrim(p_replacement_reason), '') is null then
    raise exception 'replacement reason must be nonblank when supplied'
      using errcode = '22023';
  end if;

  -- Resolve immutable identity first, then lock the protected series row.
  select bv.baseline_series_id
    into v_series_id
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = p_new_baseline_version_id;

  if not found then
    raise exception 'new baseline version % does not exist', p_new_baseline_version_id
      using errcode = '23503';
  end if;

  perform 1
  from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = v_series_id
  for update;

  if not found then
    raise exception 'baseline series % does not exist', v_series_id
      using errcode = '23503';
  end if;

  -- Re-read candidate state only after the series lock.
  select count(*) into v_candidate_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event e
    on e.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where bv.baseline_series_id = v_series_id
    and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code in ('CANDIDATE', 'PENDING_APPROVAL')
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = e.baseline_lifecycle_event_id
    );

  if v_candidate_count > 1 then
    raise exception 'baseline series % has multiple current candidate-like baselines', v_series_id
      using errcode = '23514';
  end if;

  if v_candidate_count = 1 then
    select bv.baseline_version_id, e.baseline_lifecycle_event_id,
           v.value_code, e.occurred_at
      into strict v_current_candidate_baseline_id, v_current_candidate_event_id,
                  v_current_candidate_status, v_current_candidate_occurred_at
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e
      on e.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where bv.baseline_series_id = v_series_id
      and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      and v.value_code in ('CANDIDATE', 'PENDING_APPROVAL')
      and not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      )
    for update of e;
  end if;

  if p_expected_candidate_baseline_version_id is null then
    if v_candidate_count <> 0 then
      raise exception 'candidate state is stale: expected no current candidate, found baseline % event %',
        v_current_candidate_baseline_id, v_current_candidate_event_id
        using errcode = '40001';
    end if;
  elsif v_candidate_count <> 1
        or v_current_candidate_baseline_id is distinct from p_expected_candidate_baseline_version_id
        or v_current_candidate_event_id is distinct from p_expected_candidate_lifecycle_event_id then
    raise exception 'candidate state is stale: expected baseline % event %, current baseline % event %',
      p_expected_candidate_baseline_version_id,
      p_expected_candidate_lifecycle_event_id,
      v_current_candidate_baseline_id,
      v_current_candidate_event_id
      using errcode = '40001';
  end if;

  if v_candidate_count = 1
     and nullif(pg_catalog.btrim(p_replacement_reason), '') is null then
    raise exception 'replacing a current candidate requires a nonblank reason'
      using errcode = '22023';
  end if;

  if v_candidate_count = 1 and p_occurred_at < v_current_candidate_occurred_at then
    raise exception 'candidate replacement occurred_at cannot precede current candidate event %',
      v_current_candidate_event_id
      using errcode = '23514';
  end if;

  -- Snapshot ACTIVE after the same series lock. This operation never targets it.
  select count(*) into v_active_count_before
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event e
    on e.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where bv.baseline_series_id = v_series_id
    and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code = 'ACTIVE'
    and not exists (
      select 1 from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = e.baseline_lifecycle_event_id
    );

  if v_active_count_before > 1 then
    raise exception 'baseline series % has multiple current ACTIVE baselines', v_series_id
      using errcode = '23514';
  elsif v_active_count_before = 1 then
    select bv.baseline_version_id, e.baseline_lifecycle_event_id
      into strict v_active_baseline_before, v_active_event_before
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e
      on e.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where bv.baseline_series_id = v_series_id
      and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      and v.value_code = 'ACTIVE'
      and not exists (
        select 1 from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      )
    for update of e;
  end if;

  -- A newly published immutable baseline must not already have any lifecycle row.
  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event e
    where e.baseline_version_id = p_new_baseline_version_id
  ) then
    raise exception 'new candidate baseline % already has lifecycle history', p_new_baseline_version_id
      using errcode = '40001';
  end if;

  -- Resolve exactly one authoritative artifact for the new baseline.
  select count(*), (pg_catalog.array_agg(ba.artifact_id))[1]
    into v_authoritative_count, v_artifact_id
  from s2t_fhir.baseline_artifact ba
  join s2t_fhir.reference_value v
    on v.reference_value_id = ba.artifact_role_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where ba.baseline_version_id = p_new_baseline_version_id
    and d.domain_code = 'ARTIFACT_ROLE'
    and v.value_code = 'AUTHORITATIVE_SOURCE';

  if v_authoritative_count <> 1 then
    raise exception 'new candidate baseline % requires exactly one authoritative artifact; found %',
      p_new_baseline_version_id, v_authoritative_count
      using errcode = '23514';
  end if;

  -- The supplied import is the immutable mapping/evidence context for this candidate.
  select ir.baseline_version_id, ir.artifact_id, ir.completed_at,
         v.value_code, d.domain_code
    into v_import_baseline_id, v_import_artifact_id, v_import_completed_at,
         v_import_status, v_import_status_domain
  from s2t_fhir.import_run ir
  join s2t_fhir.reference_value v
    on v.reference_value_id = ir.terminal_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where ir.import_run_id = p_new_import_run_id;

  if not found then
    raise exception 'import run % does not exist or is not terminal', p_new_import_run_id
      using errcode = '23503';
  end if;

  if v_import_baseline_id <> p_new_baseline_version_id
     or v_import_artifact_id <> v_artifact_id
     or v_import_completed_at is null
     or v_import_status_domain <> 'IMPORT_RUN_STATUS'
     or v_import_status <> 'COMMITTED' then
    raise exception 'candidate publication requires a COMMITTED import for the new baseline authoritative artifact'
      using errcode = '23514';
  end if;

  if p_occurred_at < v_import_completed_at then
    raise exception 'candidate publication occurred_at cannot precede committed import completion'
      using errcode = '23514';
  end if;

  select v.reference_value_id into strict v_candidate_status_id
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code = 'CANDIDATE'
    and v.effective_at <= p_occurred_at
    and (v.retired_at is null or v.retired_at > p_occurred_at);

  select v.reference_value_id into strict v_superseded_status_id
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code = 'SUPERSEDED'
    and v.effective_at <= p_occurred_at
    and (v.retired_at is null or v.retired_at > p_occurred_at);

  select v.reference_value_id into strict v_supersedes_relationship_id
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where d.domain_code = 'BASELINE_RELATIONSHIP_TYPE'
    and v.value_code = 'SUPERSEDES'
    and v.effective_at <= pg_catalog.transaction_timestamp()
    and (v.retired_at is null or v.retired_at > pg_catalog.transaction_timestamp());

  -- Fixed order for deterministic evidence. The 022 final cardinality check is
  -- deferred, while this function also asserts the final state before return.
  if v_candidate_count = 1 then
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, initiating_human_principal_id,
       reason, supersedes_event_id)
    values
      (v_current_candidate_baseline_id, v_superseded_status_id, p_occurred_at,
       p_actor_principal_id, p_initiating_human_principal_id,
       pg_catalog.btrim(p_replacement_reason), v_current_candidate_event_id)
    returning baseline_lifecycle_event_id into v_old_superseded_event_id;
  end if;

  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, initiating_human_principal_id,
     reason, supersedes_event_id)
  values
    (p_new_baseline_version_id, v_candidate_status_id, p_occurred_at,
     p_actor_principal_id, p_initiating_human_principal_id,
     null, null)
  returning baseline_lifecycle_event_id into v_new_candidate_event_id;

  insert into s2t_fhir.baseline_candidate_context
    (baseline_version_id, candidate_lifecycle_event_id, artifact_id,
     import_run_id, effective_at, actor_principal_id,
     initiating_human_principal_id)
  values
    (p_new_baseline_version_id, v_new_candidate_event_id, v_artifact_id,
     p_new_import_run_id, p_occurred_at, p_actor_principal_id,
     p_initiating_human_principal_id)
  returning baseline_candidate_context_id into v_context_id;

  -- Existing schema semantics are directional: the new baseline is the subject
  -- (from) that SUPERSEDES the replaced baseline (to).
  if v_candidate_count = 1 then
    insert into s2t_fhir.baseline_relationship
      (from_baseline_version_id, to_baseline_version_id,
       relationship_type_value_id, reason, created_by_principal_id)
    values
      (p_new_baseline_version_id, v_current_candidate_baseline_id,
       v_supersedes_relationship_id, pg_catalog.btrim(p_replacement_reason),
       p_actor_principal_id)
    returning baseline_relationship_id into v_relationship_id;
  end if;

  perform s2t_fhir.assert_baseline_series_lifecycle(v_series_id);

  -- Prove that this operation did not alter the current ACTIVE leaf.
  select count(*) into v_active_count_after
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event e
    on e.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where bv.baseline_series_id = v_series_id
    and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code = 'ACTIVE'
    and not exists (
      select 1 from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = e.baseline_lifecycle_event_id
    );

  if v_active_count_after = 1 then
    select bv.baseline_version_id, e.baseline_lifecycle_event_id
      into strict v_active_baseline_after, v_active_event_after
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e
      on e.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where bv.baseline_series_id = v_series_id
      and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      and v.value_code = 'ACTIVE'
      and not exists (
        select 1 from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      );
  end if;

  if v_active_count_after is distinct from v_active_count_before
     or v_active_baseline_after is distinct from v_active_baseline_before
     or v_active_event_after is distinct from v_active_event_before then
    raise exception 'candidate publication attempted to change the current ACTIVE baseline'
      using errcode = '23514';
  end if;

  return pg_catalog.jsonb_build_object(
    'baselineSeriesId', v_series_id,
    'newCandidateBaselineVersionId', p_new_baseline_version_id,
    'newCandidateLifecycleEventId', v_new_candidate_event_id,
    'candidateContextId', v_context_id,
    'artifactId', v_artifact_id,
    'importRunId', p_new_import_run_id,
    'supersededCandidateBaselineVersionId', v_current_candidate_baseline_id,
    'supersededCandidateLifecycleEventId', v_old_superseded_event_id,
    'candidateRelationshipId', v_relationship_id,
    'unchangedActiveBaselineVersionId', v_active_baseline_before,
    'unchangedActiveLifecycleEventId', v_active_event_before,
    'effectiveAt', p_occurred_at
  );
end
$function$;

create function s2t_fhir_api.publish_candidate_baseline(
  p_new_baseline_version_id uuid,
  p_new_import_run_id uuid,
  p_expected_candidate_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_occurred_at timestamptz,
  p_replacement_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_principal_id uuid;
begin
  v_actor_principal_id :=
    s2t_fhir_api._require_authenticated_baseline_capability('S2T_BASELINE_UPLOAD');

  return s2t_fhir.replace_current_candidate(
    p_new_baseline_version_id,
    p_new_import_run_id,
    p_expected_candidate_baseline_version_id,
    p_expected_candidate_lifecycle_event_id,
    p_occurred_at,
    p_replacement_reason,
    v_actor_principal_id,
    v_actor_principal_id
  );
end
$function$;

-- -----------------------------------------------------------------------------
-- Section 6. Explicit candidate context and mapping resolver
-- -----------------------------------------------------------------------------

do $checkpoint2_preflight$
declare
  v_object_name text;
begin
  foreach v_object_name in array array[
    's2t_fhir.review_session',
    's2t_fhir.mapping_review_event',
    's2t_fhir.current_mapping_review',
    's2t_fhir.mapping_resource_registry',
    's2t_fhir.mapping_record',
    's2t_fhir.logical_mapping_identity',
    's2t_fhir.import_candidate_row',
    's2t_fhir.element_mapping',
    's2t_fhir.status_mapping_rule',
    's2t_fhir.governance_guidance',
    's2t_fhir.artifact_sheet_manifest'
  ] loop
    if pg_catalog.to_regclass(v_object_name) is null then
      raise exception '023 Checkpoint 2 precondition: required relation % is missing', v_object_name
        using errcode = '55000';
    end if;
  end loop;

  if pg_catalog.to_regprocedure(
       's2t_fhir_api._require_authenticated_review_principal()'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api._build_lovable_children_from_nodes(jsonb,text,text)'
     ) is null then
    raise exception '023 Checkpoint 2 precondition: required private ACTIVE Review helper is missing'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_attribute a
    where a.attrelid in (
      's2t_fhir.review_session'::regclass,
      's2t_fhir.mapping_review_event'::regclass
    )
      and a.attname = 'review_target_lifecycle_event_id'
      and a.attnum > 0
      and not a.attisdropped
  ) then
    raise exception '023 Checkpoint 2 precondition: lifecycle review provenance column already exists'
      using errcode = '55000';
  end if;

  if pg_catalog.to_regclass('s2t_fhir.candidate_review_session_state') is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir._require_current_candidate_context(uuid,uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir._lock_current_candidate_context(uuid,uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api._candidate_mapping_nodes(uuid,uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.get_candidate_medication_request_cato(uuid,uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.get_candidate_mapping_review_status(uuid,uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.get_candidate_mapping_review_progress(uuid,uuid)'
     ) is not null then
    raise exception '023 Checkpoint 2 precondition: one or more Checkpoint 2 objects already exist'
      using errcode = '55000';
  end if;
end
$checkpoint2_preflight$;

-- Read-only exact-state resolver. It never searches for an unspecified candidate.
create function s2t_fhir._require_current_candidate_context(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid
)
returns s2t_fhir.baseline_candidate_context
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_series_id uuid;
  v_current_count integer;
  v_current_baseline_id uuid;
  v_current_event_id uuid;
  v_context_count integer;
  v_context s2t_fhir.baseline_candidate_context%rowtype;
begin
  if p_baseline_version_id is null
     or p_expected_candidate_lifecycle_event_id is null then
    raise exception 'candidate baseline and expected lifecycle event are required'
      using errcode = '22023';
  end if;

  select bv.baseline_series_id
    into v_series_id
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = p_baseline_version_id;

  if not found then
    raise exception 'candidate baseline % does not exist', p_baseline_version_id
      using errcode = '23503';
  end if;

  select count(*)
    into v_current_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event e
    on e.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where bv.baseline_series_id = v_series_id
    and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code = 'CANDIDATE'
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = e.baseline_lifecycle_event_id
    );

  if v_current_count = 1 then
    select bv.baseline_version_id, e.baseline_lifecycle_event_id
      into strict v_current_baseline_id, v_current_event_id
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e
      on e.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where bv.baseline_series_id = v_series_id
      and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      and v.value_code = 'CANDIDATE'
      and not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      );
  end if;

  if v_current_count <> 1
     or v_current_baseline_id is distinct from p_baseline_version_id
     or v_current_event_id is distinct from p_expected_candidate_lifecycle_event_id then
    raise exception 'candidate state is stale: expected baseline % event %, current baseline % event %',
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id,
      v_current_baseline_id,
      v_current_event_id
      using errcode = '40001';
  end if;

  select count(*)
    into v_context_count
  from s2t_fhir.baseline_candidate_context c
  join s2t_fhir.import_run ir
    on ir.import_run_id = c.import_run_id
   and ir.baseline_version_id = c.baseline_version_id
   and ir.artifact_id = c.artifact_id
   and ir.completed_at is not null
  join s2t_fhir.reference_value import_status
    on import_status.reference_value_id = ir.terminal_status_value_id
  join s2t_fhir.reference_domain import_domain
    on import_domain.reference_domain_id = import_status.reference_domain_id
   and import_domain.domain_code = 'IMPORT_RUN_STATUS'
   and import_status.value_code = 'COMMITTED'
  join s2t_fhir.baseline_artifact ba
    on ba.baseline_version_id = c.baseline_version_id
   and ba.artifact_id = c.artifact_id
  join s2t_fhir.reference_value artifact_role
    on artifact_role.reference_value_id = ba.artifact_role_value_id
  join s2t_fhir.reference_domain artifact_domain
    on artifact_domain.reference_domain_id = artifact_role.reference_domain_id
   and artifact_domain.domain_code = 'ARTIFACT_ROLE'
   and artifact_role.value_code = 'AUTHORITATIVE_SOURCE'
  where c.baseline_version_id = p_baseline_version_id
    and c.candidate_lifecycle_event_id = p_expected_candidate_lifecycle_event_id;

  if v_context_count <> 1 then
    raise exception 'candidate publication context is missing or ambiguous for baseline % event %',
      p_baseline_version_id, p_expected_candidate_lifecycle_event_id
      using errcode = '23514';
  end if;

  select c.*
    into strict v_context
  from s2t_fhir.baseline_candidate_context c
  where c.baseline_version_id = p_baseline_version_id
    and c.candidate_lifecycle_event_id = p_expected_candidate_lifecycle_event_id;

  return v_context;
end
$function$;

-- Write-path resolver. Series and lifecycle locks are acquired before mutable
-- candidate state is re-read; callers then continue with session/mapping locks.
create function s2t_fhir._lock_current_candidate_context(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid
)
returns s2t_fhir.baseline_candidate_context
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_series_id uuid;
  v_current_count integer;
  v_current_baseline_id uuid;
  v_current_event_id uuid;
  v_context s2t_fhir.baseline_candidate_context%rowtype;
begin
  if p_baseline_version_id is null
     or p_expected_candidate_lifecycle_event_id is null then
    raise exception 'candidate baseline and expected lifecycle event are required'
      using errcode = '22023';
  end if;

  select bv.baseline_series_id
    into v_series_id
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = p_baseline_version_id;

  if not found then
    raise exception 'candidate baseline % does not exist', p_baseline_version_id
      using errcode = '23503';
  end if;

  perform 1
  from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = v_series_id
  for update;

  select count(*)
    into v_current_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event e
    on e.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where bv.baseline_series_id = v_series_id
    and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code = 'CANDIDATE'
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = e.baseline_lifecycle_event_id
    );

  if v_current_count = 1 then
    select bv.baseline_version_id, e.baseline_lifecycle_event_id
      into strict v_current_baseline_id, v_current_event_id
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e
      on e.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where bv.baseline_series_id = v_series_id
      and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      and v.value_code = 'CANDIDATE'
      and not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = e.baseline_lifecycle_event_id
      )
    for update of e;
  end if;

  if v_current_count <> 1
     or v_current_baseline_id is distinct from p_baseline_version_id
     or v_current_event_id is distinct from p_expected_candidate_lifecycle_event_id then
    raise exception 'candidate state is stale: expected baseline % event %, current baseline % event %',
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id,
      v_current_baseline_id,
      v_current_event_id
      using errcode = '40001';
  end if;

  v_context := s2t_fhir._require_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  return v_context;
end
$function$;

-- Generic candidate mapping resolver. It is parameterized by immutable baseline
-- and lifecycle identities and filters rows through the exact pinned import.
create function s2t_fhir_api._candidate_mapping_nodes(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid
)
returns table (
  baseline_version_id uuid,
  candidate_lifecycle_event_id uuid,
  import_run_id uuid,
  artifact_id uuid,
  mapping_record_id uuid,
  node_id text,
  mapping_key text,
  parent_mapping_key text,
  section_id text,
  sheet_order integer,
  source_row integer,
  source_cell_range text,
  mapping_kind text,
  comparison_path text,
  ui_profile text,
  ui_status text,
  decision_status text,
  target_valid boolean,
  payload jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_resource_count integer;
begin
  v_context := s2t_fhir._require_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  select count(*)
    into v_resource_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  join s2t_fhir.mapping_resource_registry registry
    on registry.source_system = bs.source_system
   and registry.fhir_resource = bs.fhir_resource
   and registry.is_enabled
  where bv.baseline_version_id = v_context.baseline_version_id;

  if v_resource_count <> 1 then
    raise exception 'candidate mapping resource context is missing or ambiguous for baseline %',
      p_baseline_version_id
      using errcode = '23514';
  end if;

  return query
  with candidate_context as (
    select
      bv.baseline_version_id,
      bv.baseline_code,
      bv.version_label,
      bs.source_system,
      bs.fhir_resource,
      registry.resource_config_id,
      v_context.candidate_lifecycle_event_id,
      v_context.import_run_id,
      v_context.artifact_id,
      a.physical_filename as workbook_filename,
      pg_catalog.encode(a.sha256_digest, 'hex') as workbook_sha256
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_series bs
      on bs.baseline_series_id = bv.baseline_series_id
    join s2t_fhir.artifact a
      on a.artifact_id = v_context.artifact_id
    join s2t_fhir.mapping_resource_registry registry
      on registry.source_system = bs.source_system
     and registry.fhir_resource = bs.fhir_resource
     and registry.is_enabled
    where bv.baseline_version_id = v_context.baseline_version_id
  ), mapped as (
    select
      ctx.*,
      mr.mapping_record_id,
      lmi.logical_key as mapping_key,
      mk.value_code as mapping_kind,
      ds.value_code as decision_status,
      icr.source_sheet_name as source_sheet,
      icr.source_row_number as source_row,
      icr.source_cell_range,
      manifest.sheet_order,
      em.source_system_raw,
      em.interface_type,
      em.interface_name,
      em.source_expression,
      coalesce(em.target_fhir_path, smr.target_fhir_path) as target_fhir_path,
      em.profile_context,
      em.fixed_value,
      em.transformation_rule,
      em.source_business_definition,
      em.cardinality_raw,
      em.valueset_binding,
      em.notes,
      smr.source_status_value,
      smr.target_status_value,
      smr.source_business_definition as status_source_business_definition,
      smr.transformation_rule as status_transformation_rule,
      smr.notes as status_notes,
      gs.value_code as guidance_scope,
      dt.value_code as decision_topic,
      gg.guidance_text,
      gg.target_fhir_path_or_scope_raw,
      gg.decision_topic_raw,
      gg.notes as guidance_notes
    from candidate_context ctx
    join s2t_fhir.mapping_record mr
      on mr.baseline_version_id = ctx.baseline_version_id
    join s2t_fhir.import_candidate_row icr
      on icr.import_candidate_row_id = mr.import_candidate_row_id
     and icr.import_run_id = ctx.import_run_id
     and icr.mapping_kind_value_id = mr.mapping_kind_value_id
    join s2t_fhir.reference_value disposition
      on disposition.reference_value_id = icr.candidate_disposition_value_id
    join s2t_fhir.reference_domain disposition_domain
      on disposition_domain.reference_domain_id = disposition.reference_domain_id
     and disposition_domain.domain_code = 'CANDIDATE_DISPOSITION'
     and disposition.value_code = 'ACCEPTED'
    join s2t_fhir.logical_mapping_identity lmi
      on lmi.logical_mapping_identity_id = mr.logical_mapping_identity_id
     and lmi.source_system = ctx.source_system
     and lmi.fhir_resource = ctx.fhir_resource
     and lmi.mapping_kind_value_id = mr.mapping_kind_value_id
    join s2t_fhir.reference_value mk
      on mk.reference_value_id = mr.mapping_kind_value_id
    join s2t_fhir.reference_domain mk_domain
      on mk_domain.reference_domain_id = mk.reference_domain_id
     and mk_domain.domain_code = 'MAPPING_KIND'
    join s2t_fhir.reference_value ds
      on ds.reference_value_id = mr.decision_status_value_id
    join s2t_fhir.reference_domain ds_domain
      on ds_domain.reference_domain_id = ds.reference_domain_id
     and ds_domain.domain_code = 'DECISION_STATUS'
    join s2t_fhir.artifact_sheet_manifest manifest
      on manifest.artifact_id = ctx.artifact_id
     and manifest.sheet_name = icr.source_sheet_name
    left join s2t_fhir.element_mapping em
      on em.mapping_record_id = mr.mapping_record_id
    left join s2t_fhir.status_mapping_rule smr
      on smr.mapping_record_id = mr.mapping_record_id
    left join s2t_fhir.governance_guidance gg
      on gg.mapping_record_id = mr.mapping_record_id
    left join s2t_fhir.reference_value gs
      on gs.reference_value_id = gg.guidance_scope_value_id
    left join s2t_fhir.reference_domain gs_domain
      on gs_domain.reference_domain_id = gs.reference_domain_id
     and gs_domain.domain_code = 'GUIDANCE_SCOPE'
    left join s2t_fhir.reference_value dt
      on dt.reference_value_id = gg.decision_topic_value_id
    left join s2t_fhir.reference_domain dt_domain
      on dt_domain.reference_domain_id = dt.reference_domain_id
     and dt_domain.domain_code = 'DECISION_TOPIC_CODE'
    where
      (mk.value_code = 'ELEMENT_MAPPING'
       and em.mapping_record_id is not null
       and smr.mapping_record_id is null
       and gg.mapping_record_id is null)
      or
      (mk.value_code = 'STATUS_MAPPING_RULE'
       and em.mapping_record_id is null
       and smr.mapping_record_id is not null
       and gg.mapping_record_id is null)
      or
      (mk.value_code = 'GOVERNANCE_GUIDANCE'
       and em.mapping_record_id is null
       and smr.mapping_record_id is null
       and gg.mapping_record_id is not null
       and gs_domain.domain_code = 'GUIDANCE_SCOPE'
       and dt_domain.domain_code = 'DECISION_TOPIC_CODE')
  ), normalized as (
    select
      m.*,
      case m.mapping_kind
        when 'ELEMENT_MAPPING' then m.resource_config_id || '--element-mapping'
        when 'STATUS_MAPPING_RULE' then m.resource_config_id || '--status-mapping-rule'
        when 'GOVERNANCE_GUIDANCE' then m.resource_config_id || '--governance-guidance'
      end as section_id,
      'map-v' || pg_catalog.substring(m.mapping_key, 'v([0-9]+):[0-9a-f]{64}$')
        || '-' || pg_catalog.substring(m.mapping_key, '([0-9a-f]{64})$') as node_id,
      pg_catalog.regexp_replace(pg_catalog.btrim(m.target_fhir_path), '\s+\[', '[', 'g')
        as comparison_path,
      case
        when m.profile_context = 'IL CORE' then 'IL CORE'
        when m.profile_context in ('HDP', 'Ext: Medication Regimen HDP') then 'HDP'
        when m.profile_context = 'LOCAL' then 'LOCAL'
        when m.mapping_kind in ('STATUS_MAPPING_RULE', 'GOVERNANCE_GUIDANCE') then 'LOCAL'
      end as ui_profile,
      case
        when m.decision_status = 'DO NOT MAP' then 'unmapped'
        when m.decision_status in ('OPEN', 'WIP') then 'pending'
        when m.decision_status = 'N/A' then 'structural'
        when m.decision_status = 'FINAL'
         and m.mapping_kind = 'ELEMENT_MAPPING'
         and nullif(pg_catalog.btrim(m.fixed_value), '') is not null then 'fixed'
        when m.decision_status = 'FINAL' then 'mapped'
      end as ui_status
    from mapped m
  ), parented as (
    select n.*, parent.mapping_key as parent_mapping_key
    from normalized n
    left join lateral (
      select candidate.mapping_key
      from normalized candidate
      where n.mapping_kind = 'ELEMENT_MAPPING'
        and candidate.mapping_kind = 'ELEMENT_MAPPING'
        and candidate.mapping_key <> n.mapping_key
        and (
          pg_catalog.left(n.comparison_path, pg_catalog.length(candidate.comparison_path) + 1)
            = candidate.comparison_path || '.'
          or pg_catalog.left(n.comparison_path, pg_catalog.length(candidate.comparison_path) + 1)
            = candidate.comparison_path || '['
        )
      order by pg_catalog.length(candidate.comparison_path) desc, candidate.mapping_key
      limit 1
    ) parent on true
  )
  select
    p.baseline_version_id,
    p.candidate_lifecycle_event_id,
    p.import_run_id,
    p.artifact_id,
    p.mapping_record_id,
    p.node_id,
    p.mapping_key,
    p.parent_mapping_key,
    p.section_id,
    p.sheet_order,
    p.source_row,
    p.source_cell_range,
    p.mapping_kind,
    p.comparison_path,
    p.ui_profile,
    p.ui_status,
    p.decision_status,
    case
      when p.mapping_kind in ('ELEMENT_MAPPING', 'STATUS_MAPPING_RULE') then
        p.target_fhir_path is not null
      when p.mapping_kind = 'GOVERNANCE_GUIDANCE' then
        nullif(pg_catalog.btrim(coalesce(
          p.target_fhir_path_or_scope_raw,
          p.guidance_scope
        )), '') is not null
      else false
    end as target_valid,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'id', p.node_id,
      'targetElement', case
        when p.mapping_kind in ('ELEMENT_MAPPING', 'STATUS_MAPPING_RULE') then p.target_fhir_path
        else coalesce(nullif(pg_catalog.btrim(p.target_fhir_path_or_scope_raw), ''), p.guidance_scope)
      end,
      'cardinality', case when p.mapping_kind = 'ELEMENT_MAPPING' then coalesce(p.cardinality_raw, '') else '' end,
      'profile', p.ui_profile,
      'sourceSystem', coalesce(nullif(pg_catalog.btrim(p.source_system_raw), ''), p.source_system),
      'sourceField', case
        when p.mapping_kind = 'ELEMENT_MAPPING' then p.source_expression
        when p.mapping_kind = 'STATUS_MAPPING_RULE' then p.source_status_value
        else coalesce(nullif(pg_catalog.btrim(p.decision_topic_raw), ''), p.decision_topic)
      end,
      'fixedValue', case
        when p.mapping_kind = 'ELEMENT_MAPPING' then p.fixed_value
        when p.mapping_kind = 'STATUS_MAPPING_RULE' then p.target_status_value
      end,
      'transformation', case
        when p.mapping_kind = 'ELEMENT_MAPPING' then p.transformation_rule
        when p.mapping_kind = 'STATUS_MAPPING_RULE' then p.status_transformation_rule
        else p.guidance_text
      end,
      'description', case
        when p.mapping_kind = 'ELEMENT_MAPPING' then p.source_business_definition
        when p.mapping_kind = 'STATUS_MAPPING_RULE' then p.status_source_business_definition
        else p.guidance_text
      end,
      'bindingValueSet', case when p.mapping_kind = 'ELEMENT_MAPPING' then p.valueset_binding end,
      'notes', case
        when p.mapping_kind = 'ELEMENT_MAPPING' then p.notes
        when p.mapping_kind = 'STATUS_MAPPING_RULE' then p.status_notes
        else p.guidance_notes
      end,
      'status', p.ui_status,
      'decisionStatus', p.decision_status,
      'provenance', pg_catalog.jsonb_build_object(
        'baselineCode', p.baseline_code,
        'versionLabel', p.version_label,
        'artifactFilename', p.workbook_filename,
        'artifactSha256', p.workbook_sha256,
        'sourceSheet', p.source_sheet,
        'sourceRow', p.source_row,
        'sourceCellRange', p.source_cell_range
      )
    )) as payload
  from parented p;
end
$function$;

-- -----------------------------------------------------------------------------
-- Section 7. Review schema compatibility and derived candidate session state
-- -----------------------------------------------------------------------------

alter table s2t_fhir.review_session
  add column review_target_lifecycle_event_id uuid,
  add constraint review_session_target_lifecycle_event_fk
    foreign key (review_target_lifecycle_event_id)
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id);

alter table s2t_fhir.mapping_review_event
  add column review_target_lifecycle_event_id uuid,
  add constraint mapping_review_event_target_lifecycle_event_fk
    foreign key (review_target_lifecycle_event_id)
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id);

create index review_session_target_lifecycle_idx
  on s2t_fhir.review_session
  (baseline_version_id, review_target_lifecycle_event_id, ended_at);

create index mapping_review_event_target_lifecycle_idx
  on s2t_fhir.mapping_review_event
  (baseline_version_id, review_target_lifecycle_event_id, mapping_record_id);

create function s2t_fhir.protect_review_lifecycle_provenance()
returns trigger
language plpgsql
volatile
set search_path = ''
as $function$
begin
  if new.review_target_lifecycle_event_id is distinct from old.review_target_lifecycle_event_id then
    raise exception 'review target lifecycle provenance is immutable'
      using errcode = '55000';
  end if;
  return new;
end
$function$;

create function s2t_fhir.validate_review_lifecycle_provenance()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_event_baseline_id uuid;
  v_event_status text;
  v_event_predecessor uuid;
  v_session_baseline_id uuid;
  v_session_event_id uuid;
  v_session_actor_id uuid;
begin
  if new.review_target_lifecycle_event_id is not null then
    select e.baseline_version_id, status.value_code, e.supersedes_event_id
      into v_event_baseline_id, v_event_status, v_event_predecessor
    from s2t_fhir.baseline_lifecycle_event e
    join s2t_fhir.reference_value status
      on status.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain domain
      on domain.reference_domain_id = status.reference_domain_id
     and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    where e.baseline_lifecycle_event_id = new.review_target_lifecycle_event_id;

    if not found
       or v_event_baseline_id is distinct from new.baseline_version_id
       or v_event_status <> 'CANDIDATE'
       or v_event_predecessor is not null then
      raise exception 'review lifecycle provenance must reference the baseline root CANDIDATE event'
        using errcode = '23514';
    end if;
  end if;

  if tg_table_name = 'mapping_review_event' and new.review_session_id is not null then
    select rs.baseline_version_id,
           rs.review_target_lifecycle_event_id,
           rs.created_by_principal_id
      into v_session_baseline_id, v_session_event_id, v_session_actor_id
    from s2t_fhir.review_session rs
    where rs.review_session_id = new.review_session_id;

    if not found
       or v_session_baseline_id is distinct from new.baseline_version_id
       or v_session_event_id is distinct from new.review_target_lifecycle_event_id then
      raise exception 'review session lifecycle provenance must match the review event'
        using errcode = '23514';
    end if;

    if new.review_target_lifecycle_event_id is not null
       and v_session_actor_id is distinct from new.actor_principal_id then
      raise exception 'candidate review event actor must own its review session'
        using errcode = '23514';
    end if;
  elsif tg_table_name = 'mapping_review_event'
        and new.review_target_lifecycle_event_id is not null then
    raise exception 'candidate review event requires a candidate review session'
      using errcode = '23514';
  end if;

  return new;
end
$function$;

create trigger review_session_lifecycle_provenance_insert_trg
before insert on s2t_fhir.review_session
for each row
execute function s2t_fhir.validate_review_lifecycle_provenance();

create trigger review_session_lifecycle_provenance_immutable_trg
before update on s2t_fhir.review_session
for each row
execute function s2t_fhir.protect_review_lifecycle_provenance();

create trigger mapping_review_event_lifecycle_provenance_insert_trg
before insert on s2t_fhir.mapping_review_event
for each row
execute function s2t_fhir.validate_review_lifecycle_provenance();

create trigger mapping_review_event_lifecycle_provenance_immutable_trg
before update on s2t_fhir.mapping_review_event
for each row
execute function s2t_fhir.protect_review_lifecycle_provenance();

create view s2t_fhir.candidate_review_session_state
with (security_barrier = true)
as
select
  rs.review_session_id,
  rs.baseline_version_id,
  rs.review_target_lifecycle_event_id,
  rs.session_name,
  rs.started_at,
  rs.ended_at,
  rs.created_by_principal_id,
  rs.ended_by_principal_id,
  case
    when rs.ended_at is not null then 'CLOSED'
    when exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event e
      join s2t_fhir.reference_value status
        on status.reference_value_id = e.lifecycle_status_value_id
      join s2t_fhir.reference_domain domain
        on domain.reference_domain_id = status.reference_domain_id
       and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      join s2t_fhir.baseline_candidate_context context
        on context.baseline_version_id = e.baseline_version_id
       and context.candidate_lifecycle_event_id = e.baseline_lifecycle_event_id
      where e.baseline_lifecycle_event_id = rs.review_target_lifecycle_event_id
        and e.baseline_version_id = rs.baseline_version_id
        and status.value_code = 'CANDIDATE'
        and not exists (
          select 1
          from s2t_fhir.baseline_lifecycle_event successor
          where successor.supersedes_event_id = e.baseline_lifecycle_event_id
        )
    ) then 'OPEN_CURRENT'
    else 'OPEN_FROZEN'
  end as session_state
from s2t_fhir.review_session rs
where rs.review_target_lifecycle_event_id is not null;

-- -----------------------------------------------------------------------------
-- Section 8. Candidate Review private session and event cores
-- -----------------------------------------------------------------------------

create function s2t_fhir_api._start_candidate_review_session(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_session_name text,
  p_actor_principal_id uuid,
  p_notes text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_session_id uuid;
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);

  if nullif(pg_catalog.btrim(p_session_name), '') is null then
    raise exception 'candidate review session name must be nonblank'
      using errcode = '22023';
  end if;
  if p_notes is not null and nullif(pg_catalog.btrim(p_notes), '') is null then
    raise exception 'candidate review session notes must be nonblank when supplied'
      using errcode = '22023';
  end if;

  v_context := s2t_fhir._lock_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  insert into s2t_fhir.review_session
    (baseline_version_id, review_target_lifecycle_event_id,
     session_name, started_at, created_by_principal_id, notes)
  values
    (v_context.baseline_version_id, v_context.candidate_lifecycle_event_id,
     pg_catalog.btrim(p_session_name), pg_catalog.transaction_timestamp(),
     p_actor_principal_id, p_notes)
  returning review_session_id into v_session_id;

  return v_session_id;
end
$function$;

create function s2t_fhir_api._end_candidate_review_session(
  p_baseline_version_id uuid,
  p_review_target_lifecycle_event_id uuid,
  p_session_id uuid,
  p_actor_principal_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_series_id uuid;
  v_event_baseline_id uuid;
  v_event_status text;
  v_event_predecessor uuid;
  v_session s2t_fhir.review_session%rowtype;
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);

  if p_baseline_version_id is null
     or p_review_target_lifecycle_event_id is null
     or p_session_id is null then
    raise exception 'candidate baseline, lifecycle event, and session are required'
      using errcode = '22023';
  end if;

  select bv.baseline_series_id
    into v_series_id
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = p_baseline_version_id;

  if not found then
    raise exception 'candidate review baseline % does not exist', p_baseline_version_id
      using errcode = '23503';
  end if;

  perform 1
  from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = v_series_id
  for update;

  select e.baseline_version_id, status.value_code, e.supersedes_event_id
    into v_event_baseline_id, v_event_status, v_event_predecessor
  from s2t_fhir.baseline_lifecycle_event e
  join s2t_fhir.reference_value status
    on status.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where e.baseline_lifecycle_event_id = p_review_target_lifecycle_event_id
  for update of e;

  if not found
     or v_event_baseline_id is distinct from p_baseline_version_id
     or v_event_status <> 'CANDIDATE'
     or v_event_predecessor is not null then
    raise exception 'candidate review session target is not the baseline root CANDIDATE event'
      using errcode = '23514';
  end if;

  select rs.*
    into v_session
  from s2t_fhir.review_session rs
  where rs.review_session_id = p_session_id
  for update;

  if not found
     or v_session.baseline_version_id is distinct from p_baseline_version_id
     or v_session.review_target_lifecycle_event_id is distinct from p_review_target_lifecycle_event_id
     or v_session.created_by_principal_id is distinct from p_actor_principal_id then
    raise exception 'candidate review session does not belong to this baseline, event, and actor'
      using errcode = '23514';
  end if;

  if v_session.ended_at is not null then
    raise exception 'candidate review session is already closed'
      using errcode = '55000';
  end if;

  update s2t_fhir.review_session rs
  set ended_at = pg_catalog.transaction_timestamp(),
      ended_by_principal_id = p_actor_principal_id
  where rs.review_session_id = p_session_id;
end
$function$;

create function s2t_fhir_api._record_candidate_mapping_review(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_node_id text,
  p_review_status text,
  p_actor_principal_id uuid,
  p_session_id uuid,
  p_note text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_session s2t_fhir.review_session%rowtype;
  v_target_count integer;
  v_mapping_record_id uuid;
  v_current_count integer;
  v_previous_event_id uuid;
  v_status_id uuid;
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);

  if p_session_id is null then
    raise exception 'candidate review session is required for review actions'
      using errcode = '22023';
  end if;
  if nullif(pg_catalog.btrim(p_node_id), '') is null then
    raise exception 'candidate mapping node ID is required'
      using errcode = '22023';
  end if;
  if p_review_status not in ('REVIEWED', 'NEEDS_FOLLOW_UP', 'NOT_REVIEWED') then
    raise exception 'unsupported candidate review status %', p_review_status
      using errcode = '22023';
  end if;
  if p_note is not null and nullif(pg_catalog.btrim(p_note), '') is null then
    raise exception 'candidate review note must be nonblank when supplied'
      using errcode = '22023';
  end if;

  v_context := s2t_fhir._lock_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  select rs.*
    into v_session
  from s2t_fhir.review_session rs
  where rs.review_session_id = p_session_id
  for update;

  if not found
     or v_session.baseline_version_id is distinct from v_context.baseline_version_id
     or v_session.review_target_lifecycle_event_id is distinct from v_context.candidate_lifecycle_event_id
     or v_session.created_by_principal_id is distinct from p_actor_principal_id
     or v_session.ended_at is not null then
    raise exception 'candidate review session is not OPEN_CURRENT for this baseline, event, and actor'
      using errcode = '23514';
  end if;

  select count(*), min(n.mapping_record_id::text)::uuid
    into v_target_count, v_mapping_record_id
  from s2t_fhir_api._candidate_mapping_nodes(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  ) n
  where n.node_id = p_node_id;

  if v_target_count <> 1 then
    raise exception 'node ID does not resolve uniquely in the candidate accepted governed mapping set'
      using errcode = 'P0002';
  end if;

  perform 1
  from s2t_fhir.mapping_record mr
  where mr.mapping_record_id = v_mapping_record_id
  for update;

  select count(*)
    into v_current_count
  from s2t_fhir.mapping_review_event e
  where e.baseline_version_id = p_baseline_version_id
    and e.mapping_record_id = v_mapping_record_id
    and not exists (
      select 1
      from s2t_fhir.mapping_review_event successor
      where successor.supersedes_event_id = e.mapping_review_event_id
    );

  if v_current_count > 1 then
    raise exception 'mapping review history has multiple current events'
      using errcode = '23514';
  elsif v_current_count = 1 then
    select e.mapping_review_event_id
      into strict v_previous_event_id
    from s2t_fhir.mapping_review_event e
    where e.baseline_version_id = p_baseline_version_id
      and e.mapping_record_id = v_mapping_record_id
      and not exists (
        select 1
        from s2t_fhir.mapping_review_event successor
        where successor.supersedes_event_id = e.mapping_review_event_id
      )
    for update of e;
  end if;

  select status.reference_value_id
    into strict v_status_id
  from s2t_fhir.reference_value status
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
  where domain.domain_code = 'REVIEW_STATUS'
    and status.value_code = p_review_status
    and status.effective_at <= pg_catalog.transaction_timestamp()
    and (status.retired_at is null or status.retired_at > pg_catalog.transaction_timestamp());

  insert into s2t_fhir.mapping_review_event
    (baseline_version_id, mapping_record_id, review_session_id,
     review_target_lifecycle_event_id, review_status_value_id,
     occurred_at, actor_principal_id, review_note, supersedes_event_id)
  values
    (p_baseline_version_id, v_mapping_record_id, p_session_id,
     p_expected_candidate_lifecycle_event_id, v_status_id,
     pg_catalog.transaction_timestamp(), p_actor_principal_id,
     p_note, v_previous_event_id);
end
$function$;

-- -----------------------------------------------------------------------------
-- Section 9. Authenticated Candidate Review read and write APIs
-- -----------------------------------------------------------------------------

create function s2t_fhir_api.get_candidate_medication_request_cato(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_baseline_code text;
  v_source_system text;
  v_fhir_resource text;
  v_nodes jsonb;
  v_node_count bigint;
  v_distinct_id_count bigint;
  v_invalid_count bigint;
  v_duplicate_path_count bigint;
  v_section_element jsonb;
  v_section_status jsonb;
  v_section_guidance jsonb;
  v_represented_count bigint;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();
  v_context := s2t_fhir._require_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  select bv.baseline_code, bs.source_system, bs.fhir_resource
    into v_baseline_code, v_source_system, v_fhir_resource
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  where bv.baseline_version_id = v_context.baseline_version_id;

  if v_source_system <> 'CATO' or v_fhir_resource <> 'MedicationRequest' then
    raise exception 'candidate baseline is not the CATO MedicationRequest mapping context'
      using errcode = '22023';
  end if;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    '_mappingKey', n.mapping_key,
    '_parentMappingKey', n.parent_mapping_key,
    '_sectionId', n.section_id,
    '_sheetOrder', n.sheet_order,
    '_sourceRow', n.source_row,
    '_sourceCellRange', n.source_cell_range,
    '_nodeId', n.node_id,
    '_mappingKind', n.mapping_kind,
    '_comparisonPath', n.comparison_path,
    '_profile', n.ui_profile,
    '_status', n.ui_status,
    '_decisionStatus', n.decision_status,
    '_targetValid', n.target_valid,
    '_payload', n.payload
  ) order by n.sheet_order, n.source_row, n.source_cell_range, n.node_id), '[]'::jsonb)
    into v_nodes
  from s2t_fhir_api._candidate_mapping_nodes(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  ) n;

  select
    count(*),
    count(distinct item.value ->> '_nodeId'),
    count(*) filter (where
      item.value ->> '_sectionId' is null
      or item.value ->> '_nodeId' is null
      or (item.value ->> '_nodeId') !~ '^map-v[0-9]+-[0-9a-f]{64}$'
      or item.value ->> '_profile' not in ('IL CORE', 'HDP', 'LOCAL')
      or item.value ->> '_status' not in ('mapped', 'fixed', 'pending', 'unmapped', 'structural')
      or item.value ->> '_decisionStatus' not in ('FINAL', 'WIP', 'OPEN', 'DO NOT MAP', 'N/A')
      or coalesce((item.value ->> '_targetValid')::boolean, false) is not true
      or not ((item.value -> '_payload') ?&
        array['id', 'targetElement', 'cardinality', 'profile', 'status', 'decisionStatus'])
      or (item.value #>> '{_payload,decisionStatus}') is distinct from
         (item.value ->> '_decisionStatus')
      or pg_catalog.jsonb_typeof(item.value #> '{_payload,provenance}') is distinct from 'object'
      or nullif(pg_catalog.btrim(item.value #>> '{_payload,provenance,baselineCode}'), '') is null
      or nullif(pg_catalog.btrim(item.value #>> '{_payload,provenance,versionLabel}'), '') is null
      or nullif(pg_catalog.btrim(item.value #>> '{_payload,provenance,artifactFilename}'), '') is null
      or coalesce(item.value #>> '{_payload,provenance,artifactSha256}', '') !~ '^[0-9a-fA-F]{64}$'
      or nullif(pg_catalog.btrim(item.value #>> '{_payload,provenance,sourceSheet}'), '') is null
      or case
           when pg_catalog.jsonb_typeof(item.value #> '{_payload,provenance,sourceRow}') = 'number'
             and (item.value #>> '{_payload,provenance,sourceRow}') ~ '^[0-9]+$'
           then (item.value #>> '{_payload,provenance,sourceRow}')::numeric <= 0
           else true
         end
      or nullif(pg_catalog.btrim(item.value #>> '{_payload,provenance,sourceCellRange}'), '') is null
    )
    into v_node_count, v_distinct_id_count, v_invalid_count
  from pg_catalog.jsonb_array_elements(v_nodes) item(value);

  select count(*)
    into v_duplicate_path_count
  from (
    select item.value ->> '_comparisonPath'
    from pg_catalog.jsonb_array_elements(v_nodes) item(value)
    where item.value ->> '_mappingKind' = 'ELEMENT_MAPPING'
    group by item.value ->> '_comparisonPath'
    having count(*) > 1
  ) duplicates;

  if v_node_count <> v_distinct_id_count
     or v_invalid_count <> 0
     or v_duplicate_path_count <> 0 then
    raise exception 'candidate governed mapping set failed UI contract validation'
      using errcode = '23514';
  end if;

  v_section_element := s2t_fhir_api._build_lovable_children_from_nodes(
    v_nodes, 'medication-request-cato--element-mapping', null
  );
  v_section_status := s2t_fhir_api._build_lovable_children_from_nodes(
    v_nodes, 'medication-request-cato--status-mapping-rule', null
  );
  v_section_guidance := s2t_fhir_api._build_lovable_children_from_nodes(
    v_nodes, 'medication-request-cato--governance-guidance', null
  );

  with recursive represented(node) as (
    select value
    from pg_catalog.jsonb_array_elements(
      v_section_element || v_section_status || v_section_guidance
    )
    union all
    select child.value
    from represented parent
    cross join lateral pg_catalog.jsonb_array_elements(
      coalesce(parent.node -> 'children', '[]'::jsonb)
    ) child(value)
  )
  select count(*) into v_represented_count from represented;

  if v_represented_count <> v_node_count then
    raise exception 'candidate governed mapping hierarchy is incomplete'
      using errcode = '23514';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', 'medication-request-cato',
    'label', 'CATO MedicationRequest',
    'description', 'Governed CANDIDATE CATO to FHIR MedicationRequest mapping',
    'icon', 'pill',
    'baselineVersionId', p_baseline_version_id,
    'candidateLifecycleEventId', p_expected_candidate_lifecycle_event_id,
    'sections', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', 'medication-request-cato--element-mapping',
        'label', 'Element mappings',
        'icon', 'list-tree',
        'description', 'Governed element mappings',
        'elements', v_section_element
      ),
      pg_catalog.jsonb_build_object(
        'id', 'medication-request-cato--status-mapping-rule',
        'label', 'Status mapping rules',
        'icon', 'workflow',
        'description', 'Governed status translation rules',
        'elements', v_section_status
      ),
      pg_catalog.jsonb_build_object(
        'id', 'medication-request-cato--governance-guidance',
        'label', 'Governance guidance',
        'icon', 'book-open',
        'description', 'Governed mapping guidance and decisions',
        'elements', v_section_guidance
      )
    ),
    'crossReferences', '[]'::jsonb
  );
end
$function$;

create function s2t_fhir_api.get_candidate_mapping_review_status(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid
)
returns table (
  node_id text,
  review_status text,
  reviewed_at timestamptz,
  review_note text,
  session_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();

  return query
  select
    n.node_id,
    coalesce(cmr.review_status, 'NOT_REVIEWED'),
    cmr.occurred_at,
    cmr.review_note,
    rs.session_name
  from s2t_fhir_api._candidate_mapping_nodes(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  ) n
  left join s2t_fhir.current_mapping_review cmr
    on cmr.baseline_version_id = n.baseline_version_id
   and cmr.mapping_record_id = n.mapping_record_id
  left join s2t_fhir.review_session rs
    on rs.review_session_id = cmr.review_session_id;
end
$function$;

create function s2t_fhir_api.get_candidate_mapping_review_progress(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
  v_baseline_code text;
  v_total bigint;
  v_reviewed bigint;
  v_needs_follow_up bigint;
  v_last_node_id text;
  v_last_status text;
  v_last_reviewed_at timestamptz;
  v_last_session_name text;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir._require_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  select bv.baseline_code into strict v_baseline_code
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = p_baseline_version_id;

  with status_rows as (
    select
      n.node_id,
      coalesce(cmr.review_status, 'NOT_REVIEWED') as review_status,
      cmr.occurred_at,
      rs.session_name
    from s2t_fhir_api._candidate_mapping_nodes(
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id
    ) n
    left join s2t_fhir.current_mapping_review cmr
      on cmr.baseline_version_id = n.baseline_version_id
     and cmr.mapping_record_id = n.mapping_record_id
    left join s2t_fhir.review_session rs
      on rs.review_session_id = cmr.review_session_id
  )
  select count(*),
         count(*) filter (where review_status = 'REVIEWED'),
         count(*) filter (where review_status = 'NEEDS_FOLLOW_UP')
    into v_total, v_reviewed, v_needs_follow_up
  from status_rows;

  select n.node_id, cmr.review_status, cmr.occurred_at, rs.session_name
    into v_last_node_id, v_last_status, v_last_reviewed_at, v_last_session_name
  from s2t_fhir_api._candidate_mapping_nodes(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  ) n
  join s2t_fhir.current_mapping_review cmr
    on cmr.baseline_version_id = n.baseline_version_id
   and cmr.mapping_record_id = n.mapping_record_id
  left join s2t_fhir.review_session rs
    on rs.review_session_id = cmr.review_session_id
  order by cmr.occurred_at desc, n.node_id
  limit 1;

  return pg_catalog.jsonb_build_object(
    'baselineCode', v_baseline_code,
    'baselineVersionId', p_baseline_version_id,
    'candidateLifecycleEventId', p_expected_candidate_lifecycle_event_id,
    'total', v_total,
    'reviewed', v_reviewed,
    'notReviewed', v_total - v_reviewed - v_needs_follow_up,
    'needsFollowUp', v_needs_follow_up,
    'completionPercent', case
      when v_total = 0 then 0
      else pg_catalog.round(v_reviewed::numeric * 100 / v_total)::integer
    end,
    'lastReviewed', case
      when v_last_node_id is null then null
      else pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'nodeId', v_last_node_id,
        'reviewStatus', v_last_status,
        'occurredAt', v_last_reviewed_at,
        'sessionName', v_last_session_name
      ))
    end
  );
end
$function$;

create function s2t_fhir_api.start_authenticated_candidate_review_session(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_session_name text,
  p_notes text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();
  return s2t_fhir_api._start_candidate_review_session(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id,
    p_session_name,
    v_actor_id,
    p_notes
  );
end
$function$;

create function s2t_fhir_api.end_authenticated_candidate_review_session(
  p_baseline_version_id uuid,
  p_review_target_lifecycle_event_id uuid,
  p_session_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._end_candidate_review_session(
    p_baseline_version_id,
    p_review_target_lifecycle_event_id,
    p_session_id,
    v_actor_id
  );
end
$function$;

create function s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_node_id text,
  p_session_id uuid,
  p_note text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._record_candidate_mapping_review(
    p_baseline_version_id, p_expected_candidate_lifecycle_event_id,
    p_node_id, 'REVIEWED', v_actor_id, p_session_id, p_note
  );
end
$function$;

create function s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_node_id text,
  p_session_id uuid,
  p_note text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._record_candidate_mapping_review(
    p_baseline_version_id, p_expected_candidate_lifecycle_event_id,
    p_node_id, 'NEEDS_FOLLOW_UP', v_actor_id, p_session_id, p_note
  );
end
$function$;

create function s2t_fhir_api.clear_authenticated_candidate_mapping_review(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_node_id text,
  p_session_id uuid,
  p_note text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid;
begin
  v_actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._record_candidate_mapping_review(
    p_baseline_version_id, p_expected_candidate_lifecycle_event_id,
    p_node_id, 'NOT_REVIEWED', v_actor_id, p_session_id, p_note
  );
end
$function$;

-- -----------------------------------------------------------------------------
-- Section 10. Candidate governance links
-- -----------------------------------------------------------------------------

do $checkpoint3_preflight$
declare
  v_object_name text;
begin
  foreach v_object_name in array array[
    's2t_governance.governance_question',
    's2t_governance.governance_mapping_link',
    's2t_governance.governance_event',
    's2t_fhir_api.governance_mapping_links'
  ] loop
    if pg_catalog.to_regclass(v_object_name) is null then
      raise exception '023 Checkpoint 3 precondition: required relation % is missing', v_object_name
        using errcode = '55000';
    end if;
  end loop;

  if pg_catalog.to_regprocedure(
       's2t_governance._current_reviewer_principal()'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_governance._lock_question(uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.gov_link_mapping(uuid,jsonb,timestamptz)'
     ) is null then
    raise exception '023 Checkpoint 3 precondition: required accepted governance function is missing'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_trigger t
    where t.tgrelid = 's2t_governance.governance_mapping_link'::regclass
      and t.tgname = 'no_update_delete'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  )
  or not exists (
    select 1
    from pg_catalog.pg_trigger t
    where t.tgrelid = 's2t_governance.governance_mapping_link'::regclass
      and t.tgname = 'no_truncate'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  ) then
    raise exception '023 Checkpoint 3 precondition: governance mapping-link append-only enforcement is missing or disabled'
      using errcode = '55000';
  end if;

  foreach v_object_name in array array[
    'baseline_version_id',
    'review_target_lifecycle_event_id',
    'lifecycle_status_at_link'
  ] loop
    if exists (
      select 1
      from pg_catalog.pg_attribute a
      where a.attrelid = 's2t_governance.governance_mapping_link'::regclass
        and a.attname = v_object_name
        and a.attnum > 0
        and not a.attisdropped
    ) then
      raise exception '023 Checkpoint 3 precondition: governance mapping-link column % already exists',
        v_object_name
        using errcode = '55000';
    end if;
  end loop;

  if pg_catalog.to_regprocedure(
       's2t_governance.validate_mapping_link_lifecycle_context()'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_governance._resolve_candidate_mapping_identity(uuid,uuid,text,text,text)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_governance._insert_candidate_mapping_link(uuid,uuid,uuid,jsonb,uuid,timestamptz)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.gov_link_candidate_mapping(uuid,uuid,uuid,jsonb,timestamptz)'
     ) is not null then
    raise exception '023 Checkpoint 3 precondition: one or more Checkpoint 3 functions already exist'
      using errcode = '55000';
  end if;
end
$checkpoint3_preflight$;

-- Historical ACTIVE links retain NULL lifecycle provenance. Candidate links
-- populate the complete immutable trio; partial provenance is never valid.
alter table s2t_governance.governance_mapping_link
  add column baseline_version_id uuid,
  add column review_target_lifecycle_event_id uuid,
  add column lifecycle_status_at_link text,
  add constraint governance_mapping_link_baseline_version_fk
    foreign key (baseline_version_id)
    references s2t_fhir.baseline_version(baseline_version_id),
  add constraint governance_mapping_link_lifecycle_event_fk
    foreign key (review_target_lifecycle_event_id)
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id),
  add constraint governance_mapping_link_lifecycle_context_ck check (
    (
      baseline_version_id is null
      and review_target_lifecycle_event_id is null
      and lifecycle_status_at_link is null
    )
    or
    (
      baseline_version_id is not null
      and review_target_lifecycle_event_id is not null
      and lifecycle_status_at_link is not null
      and lifecycle_status_at_link = 'CANDIDATE'
    )
  );

create index governance_mapping_link_candidate_context_idx
  on s2t_governance.governance_mapping_link
  (baseline_version_id, review_target_lifecycle_event_id, question_id)
  where baseline_version_id is not null;

-- This trigger validates immutable lifecycle provenance independently of the
-- candidate write core. Current-state serialization remains the core's job.
create function s2t_governance.validate_mapping_link_lifecycle_context()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_event_baseline_id uuid;
  v_event_status text;
  v_event_predecessor_id uuid;
begin
  if new.baseline_version_id is null
     and new.review_target_lifecycle_event_id is null
     and new.lifecycle_status_at_link is null then
    return new;
  end if;

  if new.baseline_version_id is null
     or new.review_target_lifecycle_event_id is null
     or new.lifecycle_status_at_link is distinct from 'CANDIDATE' then
    raise exception 'candidate governance lifecycle provenance must be complete and CANDIDATE'
      using errcode = '23514';
  end if;

  select e.baseline_version_id, status.value_code, e.supersedes_event_id
    into v_event_baseline_id, v_event_status, v_event_predecessor_id
  from s2t_fhir.baseline_lifecycle_event e
  join s2t_fhir.reference_value status
    on status.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where e.baseline_lifecycle_event_id = new.review_target_lifecycle_event_id;

  if not found
     or v_event_baseline_id is distinct from new.baseline_version_id
     or v_event_status <> 'CANDIDATE'
     or v_event_predecessor_id is not null then
    raise exception 'candidate governance lifecycle provenance must reference the baseline root CANDIDATE event'
      using errcode = '23514';
  end if;

  return new;
end
$function$;

create trigger lifecycle_context_validate
before insert on s2t_governance.governance_mapping_link
for each row
execute function s2t_governance.validate_mapping_link_lifecycle_context();

-- Candidate mapping identity is resolved only through the explicit Candidate
-- publication contract. It never reads _active_release_context or implicitly
-- selects a candidate.
create function s2t_governance._resolve_candidate_mapping_identity(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_resource_config_id text,
  p_baseline_code text,
  p_node_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_identity jsonb;
begin
  if p_baseline_version_id is null
     or p_expected_candidate_lifecycle_event_id is null
     or nullif(pg_catalog.btrim(p_resource_config_id), '') is null
     or nullif(pg_catalog.btrim(p_baseline_code), '') is null
     or nullif(pg_catalog.btrim(p_node_id), '') is null then
    raise exception 'candidate governance mapping identity is incomplete'
      using errcode = '22023';
  end if;

  with recursive nodes as materialized (
    select
      n.mapping_record_id,
      n.mapping_key,
      n.parent_mapping_key,
      n.node_id,
      n.mapping_kind,
      n.ui_profile,
      n.decision_status,
      n.source_row,
      n.source_cell_range,
      n.payload,
      bv.baseline_code,
      bv.version_label,
      bs.fhir_resource as fhir_resource_type,
      registry.resource_config_id,
      n.payload ->> 'targetElement' as target_element,
      n.payload #>> '{provenance,sourceSheet}' as source_sheet,
      n.payload #>> '{provenance,artifactSha256}' as artifact_sha256
    from s2t_fhir_api._candidate_mapping_nodes(
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id
    ) n
    join s2t_fhir.baseline_version bv
      on bv.baseline_version_id = n.baseline_version_id
    join s2t_fhir.baseline_series bs
      on bs.baseline_series_id = bv.baseline_series_id
    join s2t_fhir.mapping_resource_registry registry
      on registry.source_system = bs.source_system
     and registry.fhir_resource = bs.fhir_resource
     and registry.is_enabled
  ), target as (
    select n.*
    from nodes n
    where n.resource_config_id = p_resource_config_id
      and n.baseline_code = p_baseline_code
      and n.node_id = p_node_id
  ), walk as (
    select
      t.mapping_record_id as origin_id,
      t.mapping_key,
      t.parent_mapping_key as next_mapping_key,
      array[t.target_element]::text[] as path_rev,
      array[t.mapping_key]::text[] as visited,
      1 as depth,
      false as broken
    from target t
    where t.mapping_kind = 'ELEMENT_MAPPING'

    union all

    select
      w.origin_id,
      parent.mapping_key,
      parent.parent_mapping_key,
      w.path_rev || parent.target_element,
      w.visited || parent.mapping_key,
      w.depth + 1,
      parent.mapping_key = any(w.visited) or w.depth >= 64
    from walk w
    join nodes parent
      on parent.mapping_key = w.next_mapping_key
    where w.next_mapping_key is not null
      and not w.broken
  ), terminal as (
    select distinct on (w.origin_id)
      w.origin_id,
      case
        when w.next_mapping_key is null and not w.broken then
          array(
            select path_item
            from pg_catalog.unnest(w.path_rev) with ordinality path(path_item, ordinal_position)
            order by ordinal_position desc
          )
      end as element_path
    from walk w
    order by w.origin_id, w.depth desc
  )
  select pg_catalog.jsonb_build_object(
    'mapping_record_id', t.mapping_record_id,
    'resource_config_id', t.resource_config_id,
    'baseline_code', t.baseline_code,
    'node_id', t.node_id,
    'mapping_kind', t.mapping_kind,
    'fhir_resource_type', t.fhir_resource_type,
    'version_label', t.version_label,
    'target_element', t.target_element,
    'element_path', case t.mapping_kind
      when 'ELEMENT_MAPPING' then terminal.element_path
      when 'STATUS_MAPPING_RULE' then array[t.target_element]::text[]
      else null::text[]
    end,
    'profile_label', t.ui_profile,
    'decision_status', t.decision_status,
    'source_sheet', t.source_sheet,
    'source_row', t.source_row,
    'source_cell_range', t.source_cell_range,
    'artifact_sha256', t.artifact_sha256
  )
    into strict v_identity
  from target t
  left join terminal
    on terminal.origin_id = t.mapping_record_id;

  if v_identity ->> 'mapping_kind' = 'GOVERNANCE_GUIDANCE' then
    if pg_catalog.jsonb_typeof(v_identity -> 'element_path') <> 'null' then
      raise exception 'invalid candidate mapping identity: GOVERNANCE_GUIDANCE element_path must be NULL'
        using errcode = '23514';
    end if;
  elsif pg_catalog.jsonb_typeof(v_identity -> 'element_path') <> 'array' then
    raise exception 'invalid candidate mapping identity: non-guidance element_path must be an array'
      using errcode = '23514';
  end if;

  return v_identity;
exception
  when no_data_found then
    raise exception 'invalid candidate link: exact candidate mapping node was not found'
      using errcode = '23503';
  when too_many_rows then
    raise exception 'invalid candidate link: candidate mapping identity is not unique'
      using errcode = '21000';
end
$function$;

-- Lock order: baseline_series -> current root CANDIDATE lifecycle event ->
-- governance question advisory lock -> governance_question row -> mapping_record.
-- The advisory question lock is retained to serialize with the accepted ACTIVE
-- governance event path; it is acquired after lifecycle state and before rows
-- owned by the mapping layer.
create function s2t_governance._insert_candidate_mapping_link(
  p_question_id uuid,
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_link jsonb,
  p_principal_id uuid,
  p_effective_at timestamptz
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_identity jsonb;
  v_link_id uuid;
begin
  if p_question_id is null
     or p_principal_id is null
     or p_effective_at is null
     or p_link is null
     or pg_catalog.jsonb_typeof(p_link) <> 'object' then
    raise exception 'candidate governance question, actor, effective time, and link object are required'
      using errcode = '22023';
  end if;

  if nullif(pg_catalog.btrim(p_link ->> 'resource_config_id'), '') is null
     or nullif(pg_catalog.btrim(p_link ->> 'baseline_code'), '') is null
     or nullif(pg_catalog.btrim(p_link ->> 'node_id'), '') is null then
    raise exception 'candidate governance link requires resource_config_id, baseline_code, and node_id'
      using errcode = '22023';
  end if;

  v_context := s2t_fhir._lock_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  perform s2t_governance._lock_question(p_question_id);

  perform 1
  from s2t_governance.governance_question question
  where question.question_id = p_question_id
  for update;

  if not found then
    raise exception 'candidate governance question % does not exist', p_question_id
      using errcode = '23503';
  end if;

  v_identity := s2t_governance._resolve_candidate_mapping_identity(
    v_context.baseline_version_id,
    v_context.candidate_lifecycle_event_id,
    p_link ->> 'resource_config_id',
    p_link ->> 'baseline_code',
    p_link ->> 'node_id'
  );

  perform 1
  from s2t_fhir.mapping_record mapping
  where mapping.mapping_record_id = (v_identity ->> 'mapping_record_id')::uuid
    and mapping.baseline_version_id = v_context.baseline_version_id
  for update;

  if not found then
    raise exception 'candidate governance mapping record no longer matches the candidate context'
      using errcode = '40001';
  end if;

  insert into s2t_governance.governance_mapping_link (
    question_id,
    resource_config_id,
    baseline_code,
    node_id,
    mapping_kind,
    fhir_resource_type,
    version_label,
    target_element,
    element_path,
    profile_label,
    decision_status_at_link,
    source_sheet,
    source_row,
    source_cell_range,
    artifact_sha256,
    linked_by_principal,
    baseline_version_id,
    review_target_lifecycle_event_id,
    lifecycle_status_at_link
  ) values (
    p_question_id,
    v_identity ->> 'resource_config_id',
    v_identity ->> 'baseline_code',
    v_identity ->> 'node_id',
    v_identity ->> 'mapping_kind',
    v_identity ->> 'fhir_resource_type',
    v_identity ->> 'version_label',
    v_identity ->> 'target_element',
    case
      when v_identity -> 'element_path' is null
        or pg_catalog.jsonb_typeof(v_identity -> 'element_path') = 'null' then null
      when pg_catalog.jsonb_typeof(v_identity -> 'element_path') = 'array' then
        array(
          select pg_catalog.jsonb_array_elements_text(v_identity -> 'element_path')
        )
      else null
    end,
    v_identity ->> 'profile_label',
    v_identity ->> 'decision_status',
    v_identity ->> 'source_sheet',
    (v_identity ->> 'source_row')::integer,
    v_identity ->> 'source_cell_range',
    v_identity ->> 'artifact_sha256',
    p_principal_id,
    v_context.baseline_version_id,
    v_context.candidate_lifecycle_event_id,
    'CANDIDATE'
  )
  returning link_id into v_link_id;

  insert into s2t_governance.governance_event (
    question_id,
    event_type,
    effective_at,
    recorded_by_principal,
    link_id
  ) values (
    p_question_id,
    'MAPPING_LINKED',
    p_effective_at,
    p_principal_id,
    v_link_id
  );

  return v_link_id;
end
$function$;

create function s2t_fhir_api.gov_link_candidate_mapping(
  p_question_id uuid,
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_link jsonb,
  p_effective_at timestamptz
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_principal_id uuid;
begin
  v_actor_principal_id := s2t_governance._current_reviewer_principal();

  return s2t_governance._insert_candidate_mapping_link(
    p_question_id,
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id,
    p_link,
    v_actor_principal_id,
    p_effective_at
  );
end
$function$;

-- -----------------------------------------------------------------------------
-- Section 11. Governed ACTIVE eligibility invariant
-- -----------------------------------------------------------------------------

do $checkpoint4_preflight$
declare
  v_object_name text;
begin
  foreach v_object_name in array array[
    's2t_fhir.release_gate_evaluation',
    's2t_fhir.current_release_gate_evaluation',
    's2t_fhir.validation_run',
    's2t_fhir.current_mapping_review',
    's2t_fhir.mapping_resource_registry',
    's2t_fhir_api._active_release_context'
  ] loop
    if pg_catalog.to_regclass(v_object_name) is null then
      raise exception '023 Checkpoint 4 precondition: required relation % is missing', v_object_name
        using errcode = '55000';
    end if;
  end loop;

  if pg_catalog.to_regprocedure(
       's2t_fhir.assert_release_gate_evaluation_integrity(uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir.validate_baseline_lifecycle_insert()'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir.assert_baseline_series_lifecycle(uuid)'
     ) is null then
    raise exception '023 Checkpoint 4 precondition: required accepted integrity function is missing'
      using errcode = '55000';
  end if;

  if pg_catalog.to_regclass('s2t_fhir.baseline_activation_context') is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir.assert_candidate_activation_eligibility(uuid,uuid,uuid,uuid,timestamptz)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir.validate_baseline_activation_context()'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir.authorize_active_lifecycle_insert()'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir.assert_activated_baseline_eligibility(uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir.check_active_lifecycle_eligibility()'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir.check_governed_active_dependency()'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir.promote_current_candidate(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)'
     ) is not null then
    raise exception '023 Checkpoint 4 precondition: one or more Checkpoint 4 objects already exist'
      using errcode = '55000';
  end if;
end
$checkpoint4_preflight$;

-- The activation context is an immutable authorization/evidence record for one
-- governed CANDIDATE -> ACTIVE transition. Future-result event FKs are deferred
-- so the context can be inserted before the guarded lifecycle writes.
create table s2t_fhir.baseline_activation_context (
  baseline_activation_context_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null
    references s2t_fhir.baseline_version(baseline_version_id),
  candidate_lifecycle_event_id uuid not null unique
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id),
  active_lifecycle_event_id uuid not null unique,
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  import_run_id uuid not null references s2t_fhir.import_run(import_run_id),
  release_gate_evaluation_id uuid not null
    references s2t_fhir.release_gate_evaluation(release_gate_evaluation_id),
  prior_active_baseline_version_id uuid
    references s2t_fhir.baseline_version(baseline_version_id),
  prior_active_lifecycle_event_id uuid
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id),
  prior_active_superseded_event_id uuid,
  effective_at timestamptz not null,
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint baseline_activation_context_baseline_uq unique (baseline_version_id),
  constraint baseline_activation_context_import_uq unique (import_run_id),
  constraint baseline_activation_context_active_event_fk
    foreign key (active_lifecycle_event_id)
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id)
    deferrable initially deferred,
  constraint baseline_activation_context_prior_superseded_event_fk
    foreign key (prior_active_superseded_event_id)
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id)
    deferrable initially deferred,
  constraint baseline_activation_context_prior_active_shape_ck check (
    num_nonnulls(
      prior_active_baseline_version_id,
      prior_active_lifecycle_event_id,
      prior_active_superseded_event_id
    ) in (0, 3)
  ),
  constraint baseline_activation_context_event_identity_ck check (
    active_lifecycle_event_id <> candidate_lifecycle_event_id
    and (
      prior_active_superseded_event_id is null
      or prior_active_superseded_event_id not in (
        candidate_lifecycle_event_id,
        active_lifecycle_event_id
      )
    )
  ),
  constraint baseline_activation_context_time_ck check (
    created_at >= effective_at
  )
);

create index baseline_activation_context_gate_idx
  on s2t_fhir.baseline_activation_context
  (release_gate_evaluation_id, baseline_version_id);

create index baseline_activation_context_prior_active_idx
  on s2t_fhir.baseline_activation_context
  (prior_active_baseline_version_id, prior_active_lifecycle_event_id)
  where prior_active_baseline_version_id is not null;

-- Exact pre-activation eligibility. This deliberately uses the explicit
-- Candidate publication context rather than an ACTIVE projection.
create function s2t_fhir.assert_candidate_activation_eligibility(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_expected_import_run_id uuid,
  p_expected_release_gate_evaluation_id uuid,
  p_effective_at timestamptz
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_authoritative_count integer;
  v_import_completed_at timestamptz;
  v_gate_count integer;
  v_gate_id uuid;
  v_validation_run_id uuid;
  v_gate_import_run_id uuid;
  v_gate_evaluated_at timestamptz;
  v_gate_recorded_at timestamptz;
  v_mapping_count bigint;
  v_reviewed_count bigint;
  v_last_review_at timestamptz;
  v_closed_session_count integer;
  v_open_session_count integer;
  v_last_session_end timestamptz;
begin
  if p_expected_import_run_id is null
     or p_expected_release_gate_evaluation_id is null
     or p_effective_at is null then
    raise exception 'expected import, release-gate evaluation, and promotion effective time are required'
      using errcode = '22023';
  end if;

  v_context := s2t_fhir._require_current_candidate_context(
    p_baseline_version_id,
    p_expected_candidate_lifecycle_event_id
  );

  if v_context.import_run_id is distinct from p_expected_import_run_id then
    raise exception 'candidate import context is stale: expected %, current %',
      p_expected_import_run_id, v_context.import_run_id
      using errcode = '40001';
  end if;

  select count(*)
    into v_authoritative_count
  from s2t_fhir.baseline_artifact ba
  join s2t_fhir.reference_value role_value
    on role_value.reference_value_id = ba.artifact_role_value_id
  join s2t_fhir.reference_domain role_domain
    on role_domain.reference_domain_id = role_value.reference_domain_id
   and role_domain.domain_code = 'ARTIFACT_ROLE'
  where ba.baseline_version_id = v_context.baseline_version_id
    and ba.artifact_id = v_context.artifact_id
    and role_value.value_code = 'AUTHORITATIVE_SOURCE';

  if v_authoritative_count <> 1 or (
    select count(*)
    from s2t_fhir.baseline_artifact ba
    join s2t_fhir.reference_value role_value
      on role_value.reference_value_id = ba.artifact_role_value_id
    join s2t_fhir.reference_domain role_domain
      on role_domain.reference_domain_id = role_value.reference_domain_id
     and role_domain.domain_code = 'ARTIFACT_ROLE'
    where ba.baseline_version_id = v_context.baseline_version_id
      and role_value.value_code = 'AUTHORITATIVE_SOURCE'
  ) <> 1 then
    raise exception 'promotion requires exactly the Candidate publication authoritative artifact'
      using errcode = '23514';
  end if;

  select ir.completed_at
    into v_import_completed_at
  from s2t_fhir.import_run ir
  join s2t_fhir.reference_value status
    on status.reference_value_id = ir.terminal_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'IMPORT_RUN_STATUS'
  where ir.import_run_id = p_expected_import_run_id
    and ir.baseline_version_id = v_context.baseline_version_id
    and ir.artifact_id = v_context.artifact_id
    and ir.completed_at is not null
    and status.value_code = 'COMMITTED';

  if not found then
    raise exception 'promotion requires the exact Candidate COMMITTED import context'
      using errcode = '23514';
  end if;

  -- This is the same eligible evidence shape consumed by _active_release_context,
  -- but evaluated before the lifecycle becomes ACTIVE.
  select count(*),
         (pg_catalog.array_agg(gate.release_gate_evaluation_id))[1],
         (pg_catalog.array_agg(gate.validation_run_id))[1],
         (pg_catalog.array_agg(import_run.import_run_id))[1],
         min(gate.evaluated_at),
         min(gate.recorded_at)
    into v_gate_count, v_gate_id, v_validation_run_id,
         v_gate_import_run_id, v_gate_evaluated_at, v_gate_recorded_at
  from s2t_fhir.current_release_gate_evaluation gate
  join s2t_fhir.reference_value outcome
    on outcome.reference_value_id = gate.gate_outcome_value_id
  join s2t_fhir.reference_domain outcome_domain
    on outcome_domain.reference_domain_id = outcome.reference_domain_id
   and outcome_domain.domain_code = 'RELEASE_GATE_OUTCOME'
  join s2t_fhir.artifact artifact
    on artifact.artifact_id = gate.artifact_id
   and artifact.sha256_digest = gate.artifact_digest
  join s2t_fhir.validation_run validation
    on validation.validation_run_id = gate.validation_run_id
   and validation.validation_ruleset_id = gate.validation_ruleset_id
   and validation.artifact_id = gate.artifact_id
   and validation.artifact_digest = gate.artifact_digest
  join s2t_fhir.import_run import_run
    on import_run.import_run_id = validation.import_run_id
   and import_run.baseline_version_id = gate.baseline_version_id
   and import_run.artifact_id = gate.artifact_id
  join s2t_fhir.reference_value import_status
    on import_status.reference_value_id = import_run.terminal_status_value_id
  join s2t_fhir.reference_domain import_domain
    on import_domain.reference_domain_id = import_status.reference_domain_id
   and import_domain.domain_code = 'IMPORT_RUN_STATUS'
  where gate.baseline_version_id = v_context.baseline_version_id
    and gate.artifact_id = v_context.artifact_id
    and outcome.value_code = 'PASSED'
    and import_status.value_code = 'COMMITTED';

  if v_gate_count <> 1
     or v_gate_id is distinct from p_expected_release_gate_evaluation_id
     or v_gate_import_run_id is distinct from p_expected_import_run_id then
    raise exception 'release-gate context is stale or ambiguous: expected gate % import %, current gate % import %',
      p_expected_release_gate_evaluation_id, p_expected_import_run_id,
      v_gate_id, v_gate_import_run_id
      using errcode = '40001';
  end if;

  perform s2t_fhir.assert_release_gate_evaluation_integrity(v_gate_id);

  with candidate_nodes as (
    select n.mapping_record_id
    from s2t_fhir_api._candidate_mapping_nodes(
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id
    ) n
  )
  select count(*),
         count(*) filter (
           where current_review.review_status = 'REVIEWED'
             and review_event.review_target_lifecycle_event_id
                   = p_expected_candidate_lifecycle_event_id
         ),
         max(review_event.occurred_at)
    into v_mapping_count, v_reviewed_count, v_last_review_at
  from candidate_nodes node
  left join s2t_fhir.current_mapping_review current_review
    on current_review.baseline_version_id = p_baseline_version_id
   and current_review.mapping_record_id = node.mapping_record_id
  left join s2t_fhir.mapping_review_event review_event
    on review_event.mapping_review_event_id = current_review.mapping_review_event_id;

  if v_mapping_count = 0 or v_reviewed_count <> v_mapping_count then
    raise exception 'promotion requires every Candidate mapping to be REVIEWED in the exact Candidate lifecycle context'
      using errcode = '23514';
  end if;

  select count(*) filter (where session.ended_at is not null),
         count(*) filter (where session.ended_at is null),
         max(session.ended_at)
    into v_closed_session_count, v_open_session_count, v_last_session_end
  from s2t_fhir.review_session session
  where session.baseline_version_id = p_baseline_version_id
    and session.review_target_lifecycle_event_id = p_expected_candidate_lifecycle_event_id;

  if v_closed_session_count = 0 or v_open_session_count <> 0 then
    raise exception 'promotion requires at least one closed Candidate review session and no open Candidate review session'
      using errcode = '23514';
  end if;

  if p_effective_at < v_context.effective_at
     or p_effective_at < v_import_completed_at
     or p_effective_at < v_gate_evaluated_at
     or p_effective_at < v_gate_recorded_at
     or p_effective_at < v_last_review_at
     or p_effective_at < v_last_session_end then
    raise exception 'promotion effective time cannot precede Candidate, import, gate, or review evidence'
      using errcode = '23514';
  end if;
end
$function$;

create function s2t_fhir.validate_baseline_activation_context()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_series_id uuid;
  v_source_system text;
  v_fhir_resource text;
  v_active_count integer;
  v_active_baseline_id uuid;
  v_active_event_id uuid;
  v_active_occurred_at timestamptz;
  v_resource_count integer;
  v_other_active_context_count integer;
  v_validation_run_id uuid;
begin
  if new.baseline_version_id is null
     or new.candidate_lifecycle_event_id is null
     or new.active_lifecycle_event_id is null
     or new.artifact_id is null
     or new.import_run_id is null
     or new.release_gate_evaluation_id is null
     or new.effective_at is null then
    raise exception 'activation context requires complete Candidate, evidence, and result identities'
      using errcode = '23502';
  end if;

  if new.effective_at > pg_catalog.transaction_timestamp() then
    raise exception 'promotion effective time cannot be in the future'
      using errcode = '22023';
  end if;

  v_context := s2t_fhir._lock_current_candidate_context(
    new.baseline_version_id,
    new.candidate_lifecycle_event_id
  );

  if v_context.artifact_id is distinct from new.artifact_id
     or v_context.import_run_id is distinct from new.import_run_id then
    raise exception 'activation context does not match the exact Candidate publication context'
      using errcode = '40001';
  end if;

  select bv.baseline_series_id, bs.source_system, bs.fhir_resource
    into strict v_series_id, v_source_system, v_fhir_resource
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  where bv.baseline_version_id = new.baseline_version_id;

  perform 1
  from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = new.baseline_version_id
  for update;

  select count(*)
    into v_active_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event event
    on event.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where bv.baseline_series_id = v_series_id
    and status.value_code = 'ACTIVE'
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = event.baseline_lifecycle_event_id
    );

  if v_active_count > 1 then
    raise exception 'baseline series % has multiple current ACTIVE baselines', v_series_id
      using errcode = '23514';
  elsif v_active_count = 1 then
    select bv.baseline_version_id, event.baseline_lifecycle_event_id,
           event.occurred_at
      into strict v_active_baseline_id, v_active_event_id, v_active_occurred_at
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event event
      on event.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value status
      on status.reference_value_id = event.lifecycle_status_value_id
    join s2t_fhir.reference_domain domain
      on domain.reference_domain_id = status.reference_domain_id
     and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    where bv.baseline_series_id = v_series_id
      and status.value_code = 'ACTIVE'
      and not exists (
        select 1
        from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = event.baseline_lifecycle_event_id
      );

    perform 1
    from s2t_fhir.baseline_version bv
    where bv.baseline_version_id = v_active_baseline_id
    for update;

    perform 1
    from s2t_fhir.baseline_lifecycle_event event
    where event.baseline_lifecycle_event_id = v_active_event_id
    for update;
  end if;

  if v_active_count = 0 then
    if num_nonnulls(
      new.prior_active_baseline_version_id,
      new.prior_active_lifecycle_event_id,
      new.prior_active_superseded_event_id
    ) <> 0 then
      raise exception 'ACTIVE state is stale: expected an ACTIVE baseline but none exists'
        using errcode = '40001';
    end if;
  elsif new.prior_active_baseline_version_id is distinct from v_active_baseline_id
        or new.prior_active_lifecycle_event_id is distinct from v_active_event_id
        or new.prior_active_superseded_event_id is null then
    raise exception 'ACTIVE state is stale: expected baseline % event %, current baseline % event %',
      new.prior_active_baseline_version_id,
      new.prior_active_lifecycle_event_id,
      v_active_baseline_id,
      v_active_event_id
      using errcode = '40001';
  end if;

  if v_active_count = 1 and new.effective_at < v_active_occurred_at then
    raise exception 'promotion effective time cannot precede current ACTIVE event %', v_active_event_id
      using errcode = '23514';
  end if;

  select count(*)
    into v_resource_count
  from s2t_fhir.mapping_resource_registry registry
  where registry.source_system = v_source_system
    and registry.fhir_resource = v_fhir_resource
    and registry.is_enabled;

  if v_resource_count <> 1 then
    raise exception 'promotion requires one enabled mapping resource context for %/%',
      v_source_system, v_fhir_resource
      using errcode = '23514';
  end if;

  perform 1
  from s2t_fhir.mapping_resource_registry registry
  where registry.source_system = v_source_system
    and registry.fhir_resource = v_fhir_resource
    and registry.is_enabled
  for update;

  select count(*)
    into v_other_active_context_count
  from s2t_fhir_api._active_release_context active_context
  where active_context.source_system = v_source_system
    and active_context.fhir_resource = v_fhir_resource
    and active_context.baseline_version_id
          is distinct from new.prior_active_baseline_version_id;

  if v_other_active_context_count <> 0 then
    raise exception 'promotion would create an ambiguous ACTIVE API context for %/%',
      v_source_system, v_fhir_resource
      using errcode = '23514';
  end if;

  perform 1
  from s2t_fhir.baseline_candidate_context context
  where context.baseline_version_id = new.baseline_version_id
    and context.candidate_lifecycle_event_id = new.candidate_lifecycle_event_id
    and context.artifact_id = new.artifact_id
    and context.import_run_id = new.import_run_id
  for update;

  if not found then
    raise exception 'exact Candidate publication context is missing during promotion'
      using errcode = '40001';
  end if;

  perform 1
  from s2t_fhir.baseline_artifact ba
  where ba.baseline_version_id = new.baseline_version_id
    and ba.artifact_id = new.artifact_id
  for update;

  perform 1
  from s2t_fhir.artifact artifact
  where artifact.artifact_id = new.artifact_id
  for update;

  perform 1
  from s2t_fhir.import_run import_run
  where import_run.import_run_id = new.import_run_id
  for update;

  select gate.validation_run_id
    into v_validation_run_id
  from s2t_fhir.release_gate_evaluation gate
  where gate.release_gate_evaluation_id = new.release_gate_evaluation_id;

  if not found then
    raise exception 'release-gate evaluation % does not exist', new.release_gate_evaluation_id
      using errcode = '23503';
  end if;

  perform 1
  from s2t_fhir.validation_run validation
  where validation.validation_run_id = v_validation_run_id
  for update;

  perform 1
  from s2t_fhir.release_gate_evaluation gate
  where gate.release_gate_evaluation_id = new.release_gate_evaluation_id
  for update;

  perform s2t_fhir.assert_candidate_activation_eligibility(
    new.baseline_version_id,
    new.candidate_lifecycle_event_id,
    new.import_run_id,
    new.release_gate_evaluation_id,
    new.effective_at
  );

  if exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event event
    where event.baseline_lifecycle_event_id in (
      new.active_lifecycle_event_id,
      new.prior_active_superseded_event_id
    )
  ) then
    raise exception 'promotion result lifecycle event identity already exists'
      using errcode = '23505';
  end if;

  return new;
end
$function$;

create trigger baseline_activation_context_integrity_trg
before insert on s2t_fhir.baseline_activation_context
for each row
execute function s2t_fhir.validate_baseline_activation_context();

create trigger baseline_activation_context_actor_pair_trg
before insert on s2t_fhir.baseline_activation_context
for each row
execute function s2t_fhir.check_actor_pair(
  'actor_principal_id', 'initiating_human_principal_id'
);

create trigger baseline_activation_context_append_only_trg
before update or delete on s2t_fhir.baseline_activation_context
for each row
execute function s2t_fhir.reject_append_only_change();

-- Independent sibling-trigger guard: every new ACTIVE row must already have the
-- exact private activation context. It does not rely on trigger-name ordering.
create function s2t_fhir.authorize_active_lifecycle_insert()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_target_status text;
  v_target_domain text;
  v_context_count integer;
begin
  select status.value_code, domain.domain_code
    into v_target_status, v_target_domain
  from s2t_fhir.reference_value status
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
  where status.reference_value_id = new.lifecycle_status_value_id;

  if v_target_domain = 'BASELINE_LIFECYCLE_STATUS'
     and v_target_status = 'ACTIVE' then
    select count(*)
      into v_context_count
    from s2t_fhir.baseline_activation_context context
    where context.active_lifecycle_event_id = new.baseline_lifecycle_event_id
      and context.baseline_version_id = new.baseline_version_id
      and context.candidate_lifecycle_event_id = new.supersedes_event_id
      and context.effective_at = new.occurred_at
      and context.actor_principal_id = new.actor_principal_id
      and context.initiating_human_principal_id
            is not distinct from new.initiating_human_principal_id;

    if v_context_count <> 1 then
      raise exception 'direct ACTIVE lifecycle insertion is prohibited; exact governed activation context is required'
        using errcode = '42501';
    end if;
  end if;

  return new;
end
$function$;

create trigger baseline_active_lifecycle_authorization_trg
before insert on s2t_fhir.baseline_lifecycle_event
for each row
execute function s2t_fhir.authorize_active_lifecycle_insert();

create function s2t_fhir.assert_activated_baseline_eligibility(
  p_active_lifecycle_event_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_activation_context%rowtype;
  v_series_id uuid;
  v_source_system text;
  v_fhir_resource text;
  v_active_count integer;
  v_exact_context_count integer;
  v_resource_context_count integer;
  v_candidate_status text;
  v_candidate_predecessor uuid;
  v_active_status text;
  v_active_predecessor uuid;
  v_prior_status text;
  v_prior_predecessor uuid;
begin
  select context.*
    into v_context
  from s2t_fhir.baseline_activation_context context
  where context.active_lifecycle_event_id = p_active_lifecycle_event_id;

  if not found then
    raise exception 'ACTIVE lifecycle event % lacks governed activation context',
      p_active_lifecycle_event_id
      using errcode = '23514';
  end if;

  select status.value_code, event.supersedes_event_id
    into v_active_status, v_active_predecessor
  from s2t_fhir.baseline_lifecycle_event event
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where event.baseline_lifecycle_event_id = v_context.active_lifecycle_event_id
    and event.baseline_version_id = v_context.baseline_version_id;

  select status.value_code, event.supersedes_event_id
    into v_candidate_status, v_candidate_predecessor
  from s2t_fhir.baseline_lifecycle_event event
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where event.baseline_lifecycle_event_id = v_context.candidate_lifecycle_event_id
    and event.baseline_version_id = v_context.baseline_version_id;

  if v_active_status is distinct from 'ACTIVE'
     or v_active_predecessor is distinct from v_context.candidate_lifecycle_event_id
     or v_candidate_status is distinct from 'CANDIDATE'
     or v_candidate_predecessor is not null then
    raise exception 'activation context does not describe a root CANDIDATE -> ACTIVE chain'
      using errcode = '23514';
  end if;

  if v_context.prior_active_baseline_version_id is not null then
    select status.value_code, event.supersedes_event_id
      into v_prior_status, v_prior_predecessor
    from s2t_fhir.baseline_lifecycle_event event
    join s2t_fhir.reference_value status
      on status.reference_value_id = event.lifecycle_status_value_id
    join s2t_fhir.reference_domain domain
      on domain.reference_domain_id = status.reference_domain_id
     and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    where event.baseline_lifecycle_event_id
            = v_context.prior_active_superseded_event_id
      and event.baseline_version_id
            = v_context.prior_active_baseline_version_id;

    if v_prior_status is distinct from 'SUPERSEDED'
       or v_prior_predecessor is distinct from
            v_context.prior_active_lifecycle_event_id then
      raise exception 'promotion did not supersede the exact prior ACTIVE lifecycle event'
        using errcode = '23514';
    end if;
  end if;

  select bv.baseline_series_id, bs.source_system, bs.fhir_resource
    into strict v_series_id, v_source_system, v_fhir_resource
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  where bv.baseline_version_id = v_context.baseline_version_id;

  select count(*)
    into v_active_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event event
    on event.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where bv.baseline_series_id = v_series_id
    and status.value_code = 'ACTIVE'
    and event.baseline_lifecycle_event_id = v_context.active_lifecycle_event_id
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = event.baseline_lifecycle_event_id
    );

  if v_active_count <> 1 then
    raise exception 'promoted ACTIVE lifecycle event is not the exact current series ACTIVE'
      using errcode = '23514';
  end if;

  select count(*)
    into v_exact_context_count
  from s2t_fhir_api._active_release_context active_context
  where active_context.baseline_version_id = v_context.baseline_version_id
    and active_context.artifact_id = v_context.artifact_id
    and active_context.import_run_id = v_context.import_run_id
    and active_context.release_gate_evaluation_id
          = v_context.release_gate_evaluation_id;

  select count(*)
    into v_resource_context_count
  from s2t_fhir_api._active_release_context active_context
  where active_context.source_system = v_source_system
    and active_context.fhir_resource = v_fhir_resource;

  if v_exact_context_count <> 1 or v_resource_context_count <> 1 then
    raise exception 'promoted baseline is not uniquely servable through the governed ACTIVE read contract'
      using errcode = '23514';
  end if;

  perform s2t_fhir.assert_release_gate_evaluation_integrity(
    v_context.release_gate_evaluation_id
  );
end
$function$;

create function s2t_fhir.check_active_lifecycle_eligibility()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_status text;
begin
  select status.value_code
    into v_status
  from s2t_fhir.reference_value status
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where status.reference_value_id = new.lifecycle_status_value_id;

  if v_status = 'ACTIVE' then
    perform s2t_fhir.assert_activated_baseline_eligibility(
      new.baseline_lifecycle_event_id
    );
  end if;

  return null;
end
$function$;

create constraint trigger baseline_active_lifecycle_eligibility_trg
after insert on s2t_fhir.baseline_lifecycle_event
deferrable initially deferred
for each row
execute function s2t_fhir.check_active_lifecycle_eligibility();

-- Once a baseline has been activated through this contract, later gate or
-- validation evidence may not silently make it unservable. Legacy ACTIVE rows
-- without an activation context are deliberately left under their accepted
-- pre-023 contracts.
create function s2t_fhir.check_governed_active_dependency()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_baseline_version_id uuid;
  v_series_id uuid;
  v_source_system text;
  v_fhir_resource text;
  v_active_event_id uuid;
begin
  if tg_table_name = 'release_gate_evaluation' then
    v_baseline_version_id := new.baseline_version_id;
  elsif tg_table_name = 'validation_run' then
    select import_run.baseline_version_id
      into v_baseline_version_id
    from s2t_fhir.import_run import_run
    where import_run.import_run_id = new.import_run_id;
  else
    raise exception 'unsupported governed ACTIVE dependency table %', tg_table_name
      using errcode = '0A000';
  end if;

  select bv.baseline_series_id, bs.source_system, bs.fhir_resource
    into v_series_id, v_source_system, v_fhir_resource
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  where bv.baseline_version_id = v_baseline_version_id;

  if not found then
    return null;
  end if;

  perform 1
  from s2t_fhir.baseline_series series
  where series.baseline_series_id = v_series_id
  for update;

  perform 1
  from s2t_fhir.mapping_resource_registry registry
  where registry.source_system = v_source_system
    and registry.fhir_resource = v_fhir_resource
    and registry.is_enabled
  for update;

  select event.baseline_lifecycle_event_id
    into v_active_event_id
  from s2t_fhir.baseline_lifecycle_event event
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  join s2t_fhir.baseline_activation_context context
    on context.active_lifecycle_event_id = event.baseline_lifecycle_event_id
  where event.baseline_version_id = v_baseline_version_id
    and status.value_code = 'ACTIVE'
    and not exists (
      select 1
      from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = event.baseline_lifecycle_event_id
    );

  if found then
    perform s2t_fhir.assert_activated_baseline_eligibility(v_active_event_id);
  end if;

  return null;
end
$function$;

create constraint trigger governed_active_release_gate_dependency_trg
after insert on s2t_fhir.release_gate_evaluation
deferrable initially deferred
for each row
execute function s2t_fhir.check_governed_active_dependency();

create constraint trigger governed_active_validation_dependency_trg
after insert on s2t_fhir.validation_run
deferrable initially deferred
for each row
execute function s2t_fhir.check_governed_active_dependency();

-- -----------------------------------------------------------------------------
-- Section 12. Atomic Candidate Promotion core
-- -----------------------------------------------------------------------------

create function s2t_fhir.promote_current_candidate(
  p_candidate_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_expected_import_run_id uuid,
  p_expected_release_gate_evaluation_id uuid,
  p_expected_active_baseline_version_id uuid,
  p_expected_active_lifecycle_event_id uuid,
  p_occurred_at timestamptz,
  p_supersession_reason text,
  p_actor_principal_id uuid,
  p_initiating_human_principal_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_active_event_id uuid := pg_catalog.gen_random_uuid();
  v_prior_superseded_event_id uuid;
  v_activation_context_id uuid;
  v_active_status_id uuid;
  v_superseded_status_id uuid;
  v_supersedes_relationship_id uuid;
  v_relationship_id uuid;
begin
  if (p_expected_active_baseline_version_id is null)
     <> (p_expected_active_lifecycle_event_id is null) then
    raise exception 'expected ACTIVE baseline and lifecycle event must be both null or both non-null'
      using errcode = '22023';
  end if;

  if p_occurred_at is null then
    raise exception 'promotion occurred_at is required'
      using errcode = '22023';
  end if;

  if p_occurred_at > pg_catalog.transaction_timestamp() then
    raise exception 'promotion occurred_at cannot be in the future'
      using errcode = '22023';
  end if;

  if p_expected_active_baseline_version_id is not null
     and nullif(pg_catalog.btrim(p_supersession_reason), '') is null then
    raise exception 'replacing the current ACTIVE baseline requires a nonblank supersession reason'
      using errcode = '22023';
  end if;

  if p_expected_active_baseline_version_id is null
     and p_supersession_reason is not null
     and nullif(pg_catalog.btrim(p_supersession_reason), '') is null then
    raise exception 'supersession reason must be nonblank when supplied'
      using errcode = '22023';
  end if;

  if p_actor_principal_id is null then
    raise exception 'promotion actor is required'
      using errcode = '22023';
  end if;

  if p_expected_active_baseline_version_id is not null then
    v_prior_superseded_event_id := pg_catalog.gen_random_uuid();
  end if;

  -- The activation-context trigger acquires and validates every lock and stale
  -- assumption before either lifecycle chain is changed.
  insert into s2t_fhir.baseline_activation_context (
    baseline_version_id,
    candidate_lifecycle_event_id,
    active_lifecycle_event_id,
    artifact_id,
    import_run_id,
    release_gate_evaluation_id,
    prior_active_baseline_version_id,
    prior_active_lifecycle_event_id,
    prior_active_superseded_event_id,
    effective_at,
    actor_principal_id,
    initiating_human_principal_id
  )
  select
    context.baseline_version_id,
    context.candidate_lifecycle_event_id,
    v_active_event_id,
    context.artifact_id,
    context.import_run_id,
    p_expected_release_gate_evaluation_id,
    p_expected_active_baseline_version_id,
    p_expected_active_lifecycle_event_id,
    v_prior_superseded_event_id,
    p_occurred_at,
    p_actor_principal_id,
    p_initiating_human_principal_id
  from s2t_fhir.baseline_candidate_context context
  where context.baseline_version_id = p_candidate_baseline_version_id
    and context.candidate_lifecycle_event_id
          = p_expected_candidate_lifecycle_event_id
    and context.import_run_id = p_expected_import_run_id
  returning baseline_activation_context_id into v_activation_context_id;

  if not found then
    raise exception 'exact Candidate publication context is missing or stale'
      using errcode = '40001';
  end if;

  select status.reference_value_id
    into strict v_active_status_id
  from s2t_fhir.reference_value status
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
  where domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and status.value_code = 'ACTIVE'
    and status.effective_at <= p_occurred_at
    and (status.retired_at is null or status.retired_at > p_occurred_at);

  select status.reference_value_id
    into strict v_superseded_status_id
  from s2t_fhir.reference_value status
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
  where domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and status.value_code = 'SUPERSEDED'
    and status.effective_at <= p_occurred_at
    and (status.retired_at is null or status.retired_at > p_occurred_at);

  if p_expected_active_baseline_version_id is not null then
    insert into s2t_fhir.baseline_lifecycle_event (
      baseline_lifecycle_event_id,
      baseline_version_id,
      lifecycle_status_value_id,
      occurred_at,
      actor_principal_id,
      initiating_human_principal_id,
      reason,
      supersedes_event_id
    ) values (
      v_prior_superseded_event_id,
      p_expected_active_baseline_version_id,
      v_superseded_status_id,
      p_occurred_at,
      p_actor_principal_id,
      p_initiating_human_principal_id,
      pg_catalog.btrim(p_supersession_reason),
      p_expected_active_lifecycle_event_id
    );
  end if;

  insert into s2t_fhir.baseline_lifecycle_event (
    baseline_lifecycle_event_id,
    baseline_version_id,
    lifecycle_status_value_id,
    occurred_at,
    actor_principal_id,
    initiating_human_principal_id,
    reason,
    supersedes_event_id
  ) values (
    v_active_event_id,
    p_candidate_baseline_version_id,
    v_active_status_id,
    p_occurred_at,
    p_actor_principal_id,
    p_initiating_human_principal_id,
    null,
    p_expected_candidate_lifecycle_event_id
  );

  if p_expected_active_baseline_version_id is not null then
    select relationship.reference_value_id
      into strict v_supersedes_relationship_id
    from s2t_fhir.reference_value relationship
    join s2t_fhir.reference_domain domain
      on domain.reference_domain_id = relationship.reference_domain_id
    where domain.domain_code = 'BASELINE_RELATIONSHIP_TYPE'
      and relationship.value_code = 'SUPERSEDES'
      and relationship.effective_at <= pg_catalog.transaction_timestamp()
      and (
        relationship.retired_at is null
        or relationship.retired_at > pg_catalog.transaction_timestamp()
      );

    insert into s2t_fhir.baseline_relationship (
      from_baseline_version_id,
      to_baseline_version_id,
      relationship_type_value_id,
      reason,
      created_by_principal_id
    ) values (
      p_candidate_baseline_version_id,
      p_expected_active_baseline_version_id,
      v_supersedes_relationship_id,
      pg_catalog.btrim(p_supersession_reason),
      p_actor_principal_id
    )
    returning baseline_relationship_id into v_relationship_id;
  end if;

  perform s2t_fhir.assert_baseline_series_lifecycle(
    (
      select baseline.baseline_series_id
      from s2t_fhir.baseline_version baseline
      where baseline.baseline_version_id = p_candidate_baseline_version_id
    )
  );

  perform s2t_fhir.assert_activated_baseline_eligibility(v_active_event_id);

  return pg_catalog.jsonb_build_object(
    'baselineActivationContextId', v_activation_context_id,
    'promotedBaselineVersionId', p_candidate_baseline_version_id,
    'candidateLifecycleEventId', p_expected_candidate_lifecycle_event_id,
    'activeLifecycleEventId', v_active_event_id,
    'importRunId', p_expected_import_run_id,
    'releaseGateEvaluationId', p_expected_release_gate_evaluation_id,
    'supersededBaselineVersionId', p_expected_active_baseline_version_id,
    'supersededActiveLifecycleEventId', p_expected_active_lifecycle_event_id,
    'supersededLifecycleEventId', v_prior_superseded_event_id,
    'baselineRelationshipId', v_relationship_id,
    'effectiveAt', p_occurred_at
  );
end
$function$;

-- -----------------------------------------------------------------------------
-- Section 13. Authenticated Promotion wrapper
-- -----------------------------------------------------------------------------

create function s2t_fhir_api.promote_candidate_baseline(
  p_candidate_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_expected_import_run_id uuid,
  p_expected_release_gate_evaluation_id uuid,
  p_expected_active_baseline_version_id uuid,
  p_expected_active_lifecycle_event_id uuid,
  p_occurred_at timestamptz,
  p_supersession_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor_principal_id uuid;
begin
  v_actor_principal_id :=
    s2t_fhir_api._require_authenticated_baseline_capability(
      'S2T_BASELINE_PROMOTE'
    );

  return s2t_fhir.promote_current_candidate(
    p_candidate_baseline_version_id,
    p_expected_candidate_lifecycle_event_id,
    p_expected_import_run_id,
    p_expected_release_gate_evaluation_id,
    p_expected_active_baseline_version_id,
    p_expected_active_lifecycle_event_id,
    p_occurred_at,
    p_supersession_reason,
    v_actor_principal_id,
    v_actor_principal_id
  );
end
$function$;

-- Checkpoint-local security closure. The final migration-wide lockdown remains a
-- later checkpoint, but every object introduced here is closed at creation time.
revoke all on table s2t_fhir.baseline_action_authorization from public;
revoke all on table s2t_fhir.baseline_candidate_context from public;
revoke all on table s2t_fhir.baseline_activation_context from public;
revoke all on table s2t_fhir.candidate_review_session_state from public;
revoke all on table s2t_governance.governance_mapping_link from public;

revoke all on function s2t_fhir.protect_baseline_action_authorization_update() from public;
revoke all on function s2t_fhir_api._require_authenticated_baseline_capability(text) from public;
revoke all on function s2t_fhir.grant_baseline_action(uuid, text, uuid) from public;
revoke all on function s2t_fhir.revoke_baseline_action(uuid, text, uuid) from public;
revoke all on function s2t_fhir.validate_baseline_candidate_context() from public;
revoke all on function s2t_fhir.replace_current_candidate(uuid, uuid, uuid, uuid, timestamptz, text, uuid, uuid) from public;
revoke all on function s2t_fhir_api.publish_candidate_baseline(uuid, uuid, uuid, uuid, timestamptz, text) from public;
revoke all on function s2t_fhir._require_current_candidate_context(uuid, uuid) from public;
revoke all on function s2t_fhir._lock_current_candidate_context(uuid, uuid) from public;
revoke all on function s2t_fhir_api._candidate_mapping_nodes(uuid, uuid) from public;
revoke all on function s2t_fhir.protect_review_lifecycle_provenance() from public;
revoke all on function s2t_fhir.validate_review_lifecycle_provenance() from public;
revoke all on function s2t_fhir_api._start_candidate_review_session(uuid, uuid, text, uuid, text) from public;
revoke all on function s2t_fhir_api._end_candidate_review_session(uuid, uuid, uuid, uuid) from public;
revoke all on function s2t_fhir_api._record_candidate_mapping_review(uuid, uuid, text, text, uuid, uuid, text) from public;
revoke all on function s2t_fhir_api.get_candidate_medication_request_cato(uuid, uuid) from public;
revoke all on function s2t_fhir_api.get_candidate_mapping_review_status(uuid, uuid) from public;
revoke all on function s2t_fhir_api.get_candidate_mapping_review_progress(uuid, uuid) from public;
revoke all on function s2t_fhir_api.start_authenticated_candidate_review_session(uuid, uuid, text, text) from public;
revoke all on function s2t_fhir_api.end_authenticated_candidate_review_session(uuid, uuid, uuid) from public;
revoke all on function s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid, uuid, text, uuid, text) from public;
revoke all on function s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid, uuid, text, uuid, text) from public;
revoke all on function s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid, uuid, text, uuid, text) from public;
revoke all on function s2t_governance.validate_mapping_link_lifecycle_context() from public;
revoke all on function s2t_governance._resolve_candidate_mapping_identity(uuid, uuid, text, text, text) from public;
revoke all on function s2t_governance._insert_candidate_mapping_link(uuid, uuid, uuid, jsonb, uuid, timestamptz) from public;
revoke all on function s2t_fhir_api.gov_link_candidate_mapping(uuid, uuid, uuid, jsonb, timestamptz) from public;
revoke all on function s2t_fhir.assert_candidate_activation_eligibility(uuid, uuid, uuid, uuid, timestamptz) from public;
revoke all on function s2t_fhir.validate_baseline_activation_context() from public;
revoke all on function s2t_fhir.authorize_active_lifecycle_insert() from public;
revoke all on function s2t_fhir.assert_activated_baseline_eligibility(uuid) from public;
revoke all on function s2t_fhir.check_active_lifecycle_eligibility() from public;
revoke all on function s2t_fhir.check_governed_active_dependency() from public;
revoke all on function s2t_fhir.promote_current_candidate(uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, text, uuid, uuid) from public;
revoke all on function s2t_fhir_api.promote_candidate_baseline(uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, text) from public;

revoke all on table s2t_fhir.baseline_action_authorization
  from anon, authenticated, service_role, s2t_fhir_importer;
revoke all on table s2t_fhir.baseline_candidate_context
  from anon, authenticated, service_role, s2t_fhir_importer;
revoke all on table s2t_fhir.baseline_activation_context
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on table s2t_fhir.candidate_review_session_state
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on table s2t_governance.governance_mapping_link
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;

revoke all on function s2t_fhir_api._require_authenticated_baseline_capability(text)
  from anon, authenticated, service_role, s2t_fhir_importer;
revoke all on function s2t_fhir.replace_current_candidate(uuid, uuid, uuid, uuid, timestamptz, text, uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer;
revoke all on function s2t_fhir_api.publish_candidate_baseline(uuid, uuid, uuid, uuid, timestamptz, text)
  from anon, service_role, s2t_fhir_importer;
revoke all on function s2t_fhir.grant_baseline_action(uuid, text, uuid)
  from anon, authenticated, service_role;
revoke all on function s2t_fhir.revoke_baseline_action(uuid, text, uuid)
  from anon, authenticated, service_role;
revoke all on function s2t_fhir._require_current_candidate_context(uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir._lock_current_candidate_context(uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api._candidate_mapping_nodes(uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.protect_review_lifecycle_provenance()
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.validate_review_lifecycle_provenance()
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api._start_candidate_review_session(uuid, uuid, text, uuid, text)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api._end_candidate_review_session(uuid, uuid, uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api._record_candidate_mapping_review(uuid, uuid, text, text, uuid, uuid, text)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.get_candidate_medication_request_cato(uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.get_candidate_mapping_review_status(uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.get_candidate_mapping_review_progress(uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.start_authenticated_candidate_review_session(uuid, uuid, text, text)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.end_authenticated_candidate_review_session(uuid, uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid, uuid, text, uuid, text)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid, uuid, text, uuid, text)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid, uuid, text, uuid, text)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_governance.validate_mapping_link_lifecycle_context()
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_governance._resolve_candidate_mapping_identity(uuid, uuid, text, text, text)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_governance._insert_candidate_mapping_link(uuid, uuid, uuid, jsonb, uuid, timestamptz)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.gov_link_candidate_mapping(uuid, uuid, uuid, jsonb, timestamptz)
  from anon, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.assert_candidate_activation_eligibility(uuid, uuid, uuid, uuid, timestamptz)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.validate_baseline_activation_context()
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.authorize_active_lifecycle_insert()
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.assert_activated_baseline_eligibility(uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.check_active_lifecycle_eligibility()
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.check_governed_active_dependency()
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.promote_current_candidate(uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, text, uuid, uuid)
  from anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api.promote_candidate_baseline(uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, text)
  from anon, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;

grant execute on function s2t_fhir.grant_baseline_action(uuid, text, uuid)
  to s2t_fhir_importer;
grant execute on function s2t_fhir.revoke_baseline_action(uuid, text, uuid)
  to s2t_fhir_importer;
grant execute on function s2t_fhir_api.publish_candidate_baseline(uuid, uuid, uuid, uuid, timestamptz, text)
  to authenticated;
grant execute on function s2t_fhir_api.get_candidate_medication_request_cato(uuid, uuid)
  to authenticated;
grant execute on function s2t_fhir_api.get_candidate_mapping_review_status(uuid, uuid)
  to authenticated;
grant execute on function s2t_fhir_api.get_candidate_mapping_review_progress(uuid, uuid)
  to authenticated;
grant execute on function s2t_fhir_api.start_authenticated_candidate_review_session(uuid, uuid, text, text)
  to authenticated;
grant execute on function s2t_fhir_api.end_authenticated_candidate_review_session(uuid, uuid, uuid)
  to authenticated;
grant execute on function s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid, uuid, text, uuid, text)
  to authenticated;
grant execute on function s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid, uuid, text, uuid, text)
  to authenticated;
grant execute on function s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid, uuid, text, uuid, text)
  to authenticated;
grant execute on function s2t_fhir_api.gov_link_candidate_mapping(uuid, uuid, uuid, jsonb, timestamptz)
  to authenticated;
grant execute on function s2t_fhir_api.promote_candidate_baseline(uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, text)
  to authenticated;

comment on table s2t_fhir.baseline_action_authorization is
  'Append-only authorization history for baseline upload and promotion capabilities; Checkpoint 1 operationally uses upload only.';
comment on table s2t_fhir.baseline_candidate_context is
  'Immutable binding of a baseline root CANDIDATE event to its authoritative artifact and exact committed import.';
comment on function s2t_fhir.replace_current_candidate(uuid, uuid, uuid, uuid, timestamptz, text, uuid, uuid) is
  'Series-locked atomic candidate publication/replacement core. Never changes the current ACTIVE baseline.';
comment on function s2t_fhir_api.publish_candidate_baseline(uuid, uuid, uuid, uuid, timestamptz, text) is
  'Authenticated S2T_BASELINE_UPLOAD wrapper; actor identity is derived from trusted request context.';
comment on column s2t_fhir.review_session.review_target_lifecycle_event_id is
  'Nullable immutable lifecycle provenance. Candidate Review requires the baseline root CANDIDATE event; legacy ACTIVE sessions remain NULL.';
comment on column s2t_fhir.mapping_review_event.review_target_lifecycle_event_id is
  'Nullable immutable lifecycle provenance. Candidate Review requires the session-pinned root CANDIDATE event; legacy ACTIVE events remain NULL.';
comment on view s2t_fhir.candidate_review_session_state is
  'Derived Candidate Review session state: OPEN_CURRENT, OPEN_FROZEN, or CLOSED. No mutable status is stored.';
comment on function s2t_fhir_api._candidate_mapping_nodes(uuid, uuid) is
  'Private exact-candidate mapping resolver pinned to baseline, lifecycle event, committed import, and authoritative artifact.';
comment on function s2t_fhir_api.get_candidate_medication_request_cato(uuid, uuid) is
  'Authenticated S2T_REVIEW_WRITE read API for one explicit current CATO MedicationRequest CANDIDATE.';
comment on function s2t_fhir_api.get_candidate_mapping_review_status(uuid, uuid) is
  'Authenticated S2T_REVIEW_WRITE review-state projection for one explicit current CANDIDATE.';
comment on function s2t_fhir_api.get_candidate_mapping_review_progress(uuid, uuid) is
  'Authenticated S2T_REVIEW_WRITE progress summary for one explicit current CANDIDATE.';
comment on column s2t_governance.governance_mapping_link.baseline_version_id is
  'Nullable immutable baseline provenance. Candidate governance links populate the explicit baseline; historical ACTIVE links remain NULL.';
comment on column s2t_governance.governance_mapping_link.review_target_lifecycle_event_id is
  'Nullable immutable lifecycle provenance. Candidate governance links reference the baseline root CANDIDATE event.';
comment on column s2t_governance.governance_mapping_link.lifecycle_status_at_link is
  'Lifecycle snapshot for explicit lifecycle-aware governance links. Checkpoint 3 Candidate links record CANDIDATE; historical ACTIVE links remain NULL.';
comment on function s2t_governance._resolve_candidate_mapping_identity(uuid, uuid, text, text, text) is
  'Private exact-Candidate governance snapshot resolver. Uses explicit Candidate publication context and never the ACTIVE release context.';
comment on function s2t_governance._insert_candidate_mapping_link(uuid, uuid, uuid, jsonb, uuid, timestamptz) is
  'Private Candidate governance-link core with series/lifecycle/question/mapping serialization and immutable Candidate provenance.';
comment on function s2t_fhir_api.gov_link_candidate_mapping(uuid, uuid, uuid, jsonb, timestamptz) is
  'Authenticated S2T_REVIEW_WRITE API for linking one governance question to an exact current Candidate mapping node.';
comment on table s2t_fhir.baseline_activation_context is
  'Append-only governed evidence binding one exact reviewed Candidate/import/gate context to its ACTIVE event and optional prior-ACTIVE supersession.';
comment on function s2t_fhir.assert_candidate_activation_eligibility(uuid, uuid, uuid, uuid, timestamptz) is
  'Asserts exact current Candidate publication, completed Candidate Review, committed import, authoritative artifact, and unique current PASSED release-gate evidence before activation.';
comment on function s2t_fhir.authorize_active_lifecycle_insert() is
  'Rejects every new ACTIVE lifecycle event that is not pre-authorized by an exact private baseline_activation_context row.';
comment on function s2t_fhir.assert_activated_baseline_eligibility(uuid) is
  'Asserts the final promoted lifecycle chains and unique servability through the accepted governed ACTIVE read contract.';
comment on function s2t_fhir.promote_current_candidate(uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, text, uuid, uuid) is
  'Private series-serialized atomic Candidate Promotion core; supersedes the exact prior ACTIVE when present and activates the exact current Candidate.';
comment on function s2t_fhir_api.promote_candidate_baseline(uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, text) is
  'Authenticated S2T_BASELINE_PROMOTE wrapper with server-resolved actor identity and explicit Candidate, import, gate, and expected-ACTIVE provenance.';

reset role;

commit;

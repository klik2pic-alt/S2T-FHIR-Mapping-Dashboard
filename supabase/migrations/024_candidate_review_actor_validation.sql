-- Migration 024: Candidate Review actor-validation correction.
-- Incremental correction over deployed Migration 023. Migration 023 is immutable.

begin;

set role s2t_fhir_owner;

-- Fail closed unless the deployed definitions are the exact accepted 023
-- contract with the one known importer-only assertion still present.
do $precondition$
declare
  v record;
  v_role text;
  v_guard_pattern constant text :=
    'perform\s+s2t_fhir_api\._assert_review_actor\s*\(\s*p_actor_principal_id\s*\)\s*;';
begin
  for v in
    select expected.signature, expected.return_type, expected.post024_body_md5,
           proc.oid, owner.rolname as owner_name, proc.prosecdef,
           proc.provolatile, proc.proconfig, proc.prosrc,
           pg_catalog.pg_get_function_result(proc.oid) as actual_return_type
    from (values
      ('s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)',
       'uuid', 'fb2324ade872d878859aba075dbc8948'),
      ('s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)',
       'void', 'ab3517926eeea0f9ed9fdf6f48b732c3'),
      ('s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)',
       'void', '348c14ed64eb6d714337f9e82e11587a')
    ) expected(signature, return_type, post024_body_md5)
    left join pg_catalog.pg_proc proc
      on proc.oid = pg_catalog.to_regprocedure(expected.signature)
    left join pg_catalog.pg_roles owner on owner.oid = proc.proowner
  loop
    if v.oid is null then
      raise exception '024 precondition: required function % is absent', v.signature
        using errcode = '55000';
    end if;
    if v.owner_name <> 's2t_fhir_owner'
       or not v.prosecdef
       or v.provolatile <> 'v'
       or v.proconfig is distinct from array['search_path=""']
       or v.actual_return_type <> v.return_type then
      raise exception '024 precondition: metadata drift for %', v.signature
        using errcode = '55000';
    end if;
    if (select count(*) from pg_catalog.regexp_matches(v.prosrc, v_guard_pattern, 'gi')) <> 1 then
      raise exception '024 precondition: expected exactly one importer-only actor assertion in %', v.signature
        using errcode = '55000';
    end if;
    if pg_catalog.md5(pg_catalog.regexp_replace(
         pg_catalog.regexp_replace(v.prosrc, v_guard_pattern, '', 'gi'),
         '\s+', ' ', 'g')) <> v.post024_body_md5 then
      raise exception '024 precondition: unexpected definition drift for %', v.signature
        using errcode = '55000';
    end if;
    if exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        (select p.proacl from pg_catalog.pg_proc p where p.oid = v.oid),
        pg_catalog.acldefault('f',
          (select p.proowner from pg_catalog.pg_proc p where p.oid = v.oid)))) acl
      where acl.privilege_type = 'EXECUTE'
        and acl.grantee not in (
          select p.proowner from pg_catalog.pg_proc p where p.oid = v.oid
        )
    ) then
      raise exception '024 precondition: direct EXECUTE ACL drift for %', v.signature
        using errcode = '55000';
    end if;
    foreach v_role in array array[
      'authenticated','anon','service_role','s2t_fhir_importer',
      's2t_fhir_api_reader','s2t_fhir_governance_reader'
    ] loop
      if not exists (select 1 from pg_catalog.pg_roles where rolname = v_role) then
        raise exception '024 precondition: required role % is absent', v_role
          using errcode = '55000';
      end if;
      if pg_catalog.has_function_privilege(v_role, v.oid, 'EXECUTE') then
        raise exception '024 precondition: role % unexpectedly executes %', v_role, v.signature
          using errcode = '55000';
      end if;
    end loop;
  end loop;

  -- The historical importer guard and authenticated authorization chain are
  -- deliberately not replaced by this migration.
  if pg_catalog.to_regprocedure('s2t_fhir_api._assert_review_actor(uuid)') is null
     or pg_catalog.to_regprocedure('s2t_fhir_api._require_authenticated_review_principal()') is null
     or pg_catalog.to_regprocedure('s2t_fhir_api._resolve_authenticated_principal()') is null then
    raise exception '024 precondition: required authorization dependency is absent'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from (values
      ('s2t_fhir_api._assert_review_actor(uuid)'),
      ('s2t_fhir_api._require_authenticated_review_principal()'),
      ('s2t_fhir_api._resolve_authenticated_principal()')
    ) expected(signature)
    join pg_catalog.pg_proc p on p.oid=expected.signature::regprocedure
    join pg_catalog.pg_roles owner on owner.oid=p.proowner
    where owner.rolname<>'s2t_fhir_owner'
       or not p.prosecdef
       or p.provolatile<>'s'
       or p.proconfig is distinct from array['search_path=pg_catalog, s2t_fhir_api']
  ) then
    raise exception '024 precondition: authorization dependency metadata drift'
      using errcode = '55000';
  end if;

  if pg_catalog.md5(pg_catalog.regexp_replace(
       (select p.prosrc from pg_catalog.pg_proc p
        where p.oid = 's2t_fhir_api._assert_review_actor(uuid)'::regprocedure),
       '\s+', ' ', 'g')) <> 'fbd414965d0705cdcc0c1a5802c5a415'
     or pg_catalog.md5(pg_catalog.regexp_replace(
       (select p.prosrc from pg_catalog.pg_proc p
        where p.oid = 's2t_fhir_api._require_authenticated_review_principal()'::regprocedure),
       '\s+', ' ', 'g')) <> '25fe6d45595b4e6d6cef5dd74e50643c'
     or pg_catalog.md5(pg_catalog.regexp_replace(
       (select p.prosrc from pg_catalog.pg_proc p
        where p.oid = 's2t_fhir_api._resolve_authenticated_principal()'::regprocedure),
       '\s+', ' ', 'g')) <> '0fb059ee81137fac7b3c9ce6572f99c1' then
    raise exception '024 precondition: authorization dependency definition drift'
      using errcode = '55000';
  end if;

  for v in
    select expected.signature, expected.body_md5, proc.oid, proc.prosrc,
           proc.proargnames, owner.rolname as owner_name, proc.prosecdef,
           proc.provolatile, proc.proconfig, proc.proacl, proc.proowner
    from (values
      ('s2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)', 'a985f47e1e9cc45c4312fbba7c9035a0'),
      ('s2t_fhir_api.end_authenticated_candidate_review_session(uuid,uuid,uuid)', '8430a675bac72d8d1881ff78f8674f15'),
      ('s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)', 'b74ffa8b39f10a4ccb283dce3a5d0c9c'),
      ('s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid,uuid,text,uuid,text)', '806937be5df5f4c43291dbafe4e2ab6f'),
      ('s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid,uuid,text,uuid,text)', '8511baa88e31b29e46279486ab562115')
    ) expected(signature, body_md5)
    left join pg_catalog.pg_proc proc
      on proc.oid = pg_catalog.to_regprocedure(expected.signature)
    left join pg_catalog.pg_roles owner on owner.oid = proc.proowner
  loop
    if v.oid is null
       or pg_catalog.md5(pg_catalog.regexp_replace(v.prosrc, '\s+', ' ', 'g')) <> v.body_md5
       or v.owner_name <> 's2t_fhir_owner'
       or not v.prosecdef
       or v.provolatile <> 'v'
       or v.proconfig is distinct from array['search_path=""']
       or exists (
         select 1 from pg_catalog.unnest(coalesce(v.proargnames, array[]::text[])) name
         where name ~* '(actor|principal)'
       )
       or exists (
         select 1
         from pg_catalog.aclexplode(coalesce(
           v.proacl, pg_catalog.acldefault('f', v.proowner))) acl
         where acl.privilege_type = 'EXECUTE'
           and acl.grantee not in (
             v.proowner,
             (select r.oid from pg_catalog.pg_roles r
              where r.rolname = 'authenticated')
           )
       )
       or not pg_catalog.has_function_privilege('authenticated', v.oid, 'EXECUTE') then
      raise exception '024 precondition: authenticated wrapper contract drift for %', v.signature
        using errcode = '55000';
    end if;
    foreach v_role in array array[
      'anon','service_role','s2t_fhir_importer',
      's2t_fhir_api_reader','s2t_fhir_governance_reader'
    ] loop
      if pg_catalog.has_function_privilege(v_role, v.oid, 'EXECUTE') then
        raise exception '024 precondition: role % unexpectedly executes wrapper %', v_role, v.signature
          using errcode = '55000';
      end if;
    end loop;
  end loop;
end
$precondition$;

create or replace function s2t_fhir_api._start_candidate_review_session(
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

create or replace function s2t_fhir_api._end_candidate_review_session(
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

create or replace function s2t_fhir_api._record_candidate_mapping_review(
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

alter function s2t_fhir_api._start_candidate_review_session(uuid, uuid, text, uuid, text)
  owner to s2t_fhir_owner;
alter function s2t_fhir_api._end_candidate_review_session(uuid, uuid, uuid, uuid)
  owner to s2t_fhir_owner;
alter function s2t_fhir_api._record_candidate_mapping_review(uuid, uuid, text, text, uuid, uuid, text)
  owner to s2t_fhir_owner;

revoke all on function s2t_fhir_api._start_candidate_review_session(uuid, uuid, text, uuid, text)
  from public, authenticated, anon, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api._end_candidate_review_session(uuid, uuid, uuid, uuid)
  from public, authenticated, anon, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api._record_candidate_mapping_review(uuid, uuid, text, text, uuid, uuid, text)
  from public, authenticated, anon, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;

reset role;

commit;

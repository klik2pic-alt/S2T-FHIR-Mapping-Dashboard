-- Migration 027 read-only preflight.
-- SELECT statements only. Save every result set for postdeploy comparison.

with
expected(signature) as (
  values
    ('s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
    ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)')
),
helper_state as (
  select e.signature, p.oid, p.proowner, p.proacl, owner.rolname owner_name,
         p.prosecdef, p.provolatile, p.prokind, p.proconfig,
         pg_catalog.pg_get_function_result(p.oid) result_type
  from expected e
  left join pg_catalog.pg_proc p on p.oid = pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid = p.proowner
),
checks(check_no, check_name, result, detail) as (
  select 1, 'service_role exists',
    case when count(*) = 1 then 'PASS' else 'FAIL' end,
    pg_catalog.format('matching roles=%s', count(*))
  from pg_catalog.pg_roles where rolname = 'service_role'
  union all
  select 2, 's2t_fhir_api schema exists with expected owner',
    case when count(*) = 1 and min(owner.rolname) = 's2t_fhir_owner'
      then 'PASS' else 'FAIL' end,
    coalesce(pg_catalog.min(owner.rolname), 'ABSENT')
  from pg_catalog.pg_namespace n
  left join pg_catalog.pg_roles owner on owner.oid = n.nspowner
  where n.nspname = 's2t_fhir_api'
  union all
  select 3, 'five service helpers exist with exact security metadata',
    case when count(*) = 5 and bool_and(oid is not null
      and owner_name = 's2t_fhir_owner' and prosecdef and provolatile = 'v'
      and prokind = 'f' and proconfig is not distinct from array['search_path=""']
      and result_type = 'jsonb') then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/5 metadata exact', count(*) filter (where oid is not null
      and owner_name = 's2t_fhir_owner' and prosecdef and provolatile = 'v'
      and prokind = 'f' and proconfig is not distinct from array['search_path=""']
      and result_type = 'jsonb'))
  from helper_state
  union all
  select 4, 'service_role executes all five helpers',
    case when count(*) = 5 and bool_and(oid is not null
      and pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE'))
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/5 executable', count(*) filter (where oid is not null
      and pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')))
  from helper_state
  union all
  select 5, 'browser roles cannot execute service helpers',
    case when not exists (
      select 1 from helper_state h
      cross join (values ('anon'), ('authenticated')) r(role_name)
      where h.oid is null
        or pg_catalog.has_function_privilege(r.role_name, h.oid, 'EXECUTE')
    ) then 'PASS' else 'FAIL' end,
    'anon/authenticated denied on all five helpers'
  from (select 1) seed
  union all
  select 6, 'service_role has no direct private table privilege',
    case when count(*) = 0 then 'PASS' else 'FAIL' end,
    pg_catalog.format('privileged relations=%s', count(*))
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 's2t_fhir' and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and pg_catalog.has_table_privilege(
      'service_role', c.oid,
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
)
select check_no, check_name, result, detail from checks
union all
select 999, 'overall preflight result',
  case when bool_and(result = 'PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed', count(*) filter (where result = 'PASS'), count(*))
from checks
order by check_no;

-- Expected live defect before 027: service_role has EXECUTE=true but USAGE=false.
select 'service_role_schema_usage_before_027' as observation,
       pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'USAGE') as has_usage,
       pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'CREATE') as has_create;

with roles(role_name) as (values ('anon'), ('authenticated'), ('service_role')),
privileges as (
  select r.role_name,
         pg_catalog.has_schema_privilege(r.role_name, 's2t_fhir_api', 'USAGE') has_usage,
         pg_catalog.has_schema_privilege(r.role_name, 's2t_fhir_api', 'CREATE') has_create
  from roles r
)
select *, pg_catalog.md5(role_name || '|' || has_usage || '|' || has_create) privilege_fingerprint
from privileges order by role_name;

with
expected(signature) as (
  values
    ('s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
    ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)')
),
roles(role_name) as (values ('anon'), ('authenticated'), ('service_role')),
state as (
  select r.role_name, e.signature,
         pg_catalog.has_function_privilege(
           r.role_name, pg_catalog.to_regprocedure(e.signature), 'EXECUTE') has_execute
  from roles r cross join expected e
)
select role_name,
       pg_catalog.md5(pg_catalog.string_agg(
         signature || '=' || has_execute, E'\n' order by signature)) function_privilege_fingerprint,
       pg_catalog.string_agg(signature || '=' || has_execute, '; ' order by signature) detail
from state group by role_name order by role_name;

with components(component, row_count, content_md5) as (
  select 'candidate_import_request', count(*),
    pg_catalog.md5(coalesce(pg_catalog.string_agg(
      pg_catalog.row_to_json(r)::text, E'\n' order by r.candidate_import_request_id), ''))
  from s2t_fhir.candidate_import_request r
  union all
  select 'candidate_import_request_event', count(*),
    pg_catalog.md5(coalesce(pg_catalog.string_agg(
      pg_catalog.row_to_json(e)::text, E'\n'
      order by e.candidate_import_request_id, e.sequence_number), ''))
  from s2t_fhir.candidate_import_request_event e
  union all
  select 'candidate_import_staging_batch', count(*),
    pg_catalog.md5(coalesce(pg_catalog.string_agg(
      pg_catalog.row_to_json(b)::text, E'\n'
      order by b.candidate_import_request_id, b.validation_attempt_id, b.batch_number), ''))
  from s2t_fhir.candidate_import_staging_batch b
)
select 'candidate_import_data_before_027' as observation,
       pg_catalog.md5(pg_catalog.string_agg(
         component || '|' || row_count || '|' || content_md5,
         E'\n' order by component)) candidate_import_data_fingerprint,
       pg_catalog.string_agg(component || '=' || row_count, '; ' order by component) row_counts
from components;

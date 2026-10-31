-- Migration 027 read-only postdeployment verification.
-- Any FAIL is a deployment hard stop. Compare the final data fingerprint with
-- the saved 027 preflight fingerprint; they must be identical.

with
public_expected(signature) as (
  values
    ('s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)'),
    ('s2t_fhir_api.get_my_candidate_import(uuid)'),
    ('s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')
),
service_expected(signature) as (
  values
    ('s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
    ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)')
),
service_state as (
  select e.signature, p.oid, p.proowner, p.proacl
  from service_expected e
  left join pg_catalog.pg_proc p on p.oid = pg_catalog.to_regprocedure(e.signature)
),
checks(check_no, check_name, result, detail) as (
  select 1, 'service_role has USAGE-only on s2t_fhir_api',
    case when pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'USAGE')
      and not pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'CREATE')
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('usage=%s create=%s',
      pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'USAGE'),
      pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'CREATE'))
  from (select 1) seed
  union all
  select 2, 'service_role retains exactly five executable Candidate-import service helpers',
    case when count(*) = 5 and bool_and(oid is not null
      and pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE'))
      and not exists (
        select 1
        from pg_catalog.pg_proc other
        join pg_catalog.pg_namespace n on n.oid = other.pronamespace
        where n.nspname = 's2t_fhir_api'
          and pg_catalog.has_function_privilege('service_role', other.oid, 'EXECUTE')
          and other.oid not in (select oid from service_state where oid is not null)
      ) then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/5 intended; unexpected API functions=%s',
      count(*) filter (where oid is not null
        and pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')),
      (select count(*)
       from pg_catalog.pg_proc other
       join pg_catalog.pg_namespace n on n.oid = other.pronamespace
       where n.nspname = 's2t_fhir_api'
         and pg_catalog.has_function_privilege('service_role', other.oid, 'EXECUTE')
         and other.oid not in (select oid from service_state where oid is not null)))
  from service_state
  union all
  select 3, 'service helper direct ACL remains owner + service roles only',
    case when count(*) = 5 and not exists (
      select 1 from service_state s
      cross join lateral pg_catalog.aclexplode(coalesce(
        s.proacl, pg_catalog.acldefault('f', s.proowner))) acl
      where acl.privilege_type = 'EXECUTE'
        and acl.grantee not in (
          s.proowner,
          (select oid from pg_catalog.pg_roles where rolname = 'service_role'),
          (select oid from pg_catalog.pg_roles where rolname = 's2t_fhir_importer')
        )
    ) then 'PASS' else 'FAIL' end,
    'owner + service_role + s2t_fhir_importer only'
  from service_state
  union all
  select 4, 'service_role has no s2t_fhir table privilege',
    case when count(*) = 0 then 'PASS' else 'FAIL' end,
    pg_catalog.format('privileged relations=%s', count(*))
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 's2t_fhir' and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and pg_catalog.has_table_privilege(
      'service_role', c.oid,
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
  union all
  select 5, 'anon and authenticated Candidate-import function access did not broaden',
    case when pg_catalog.has_schema_privilege('anon', 's2t_fhir_api', 'USAGE')
      and not pg_catalog.has_schema_privilege('anon', 's2t_fhir_api', 'CREATE')
      and pg_catalog.has_schema_privilege('authenticated', 's2t_fhir_api', 'USAGE')
      and not pg_catalog.has_schema_privilege('authenticated', 's2t_fhir_api', 'CREATE')
      and not exists (
      select 1 from service_state s
      cross join (values ('anon'), ('authenticated')) r(role_name)
      where s.oid is null
        or pg_catalog.has_function_privilege(r.role_name, s.oid, 'EXECUTE')
    ) and not exists (
      select 1 from public_expected e
      where pg_catalog.to_regprocedure(e.signature) is null
        or not pg_catalog.has_function_privilege(
          'authenticated', pg_catalog.to_regprocedure(e.signature), 'EXECUTE')
        or pg_catalog.has_function_privilege(
          'anon', pg_catalog.to_regprocedure(e.signature), 'EXECUTE')
    ) then 'PASS' else 'FAIL' end,
    'schema USAGE-only retained; authenticated has three public RPCs; anon has none; both denied service helpers'
  from (select 1) seed
  union all
  select 6, 'PUBLIC has no s2t_fhir_api schema or Candidate-import function access',
    case when not exists (
      select 1
      from pg_catalog.pg_namespace n
      cross join lateral pg_catalog.aclexplode(coalesce(
        n.nspacl, pg_catalog.acldefault('n', n.nspowner))) acl
      where n.nspname = 's2t_fhir_api' and acl.grantee = 0
        and acl.privilege_type in ('USAGE', 'CREATE')
    ) and not exists (
      select 1
      from (
        select signature from public_expected
        union all select signature from service_expected
      ) e
      join pg_catalog.pg_proc p on p.oid = pg_catalog.to_regprocedure(e.signature)
      cross join lateral pg_catalog.aclexplode(coalesce(
        p.proacl, pg_catalog.acldefault('f', p.proowner))) acl
      where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
    ) then 'PASS' else 'FAIL' end,
    'PUBLIC denied schema and all eight Candidate-import functions'
  from (select 1) seed
)
select check_no, check_name, result, detail from checks
union all
select 999, 'overall postdeploy result',
  case when bool_and(result = 'PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed', count(*) filter (where result = 'PASS'), count(*))
from checks
order by check_no;

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
select 'candidate_import_data_after_027' as observation,
       pg_catalog.md5(pg_catalog.string_agg(
         component || '|' || row_count || '|' || content_md5,
         E'\n' order by component)) candidate_import_data_fingerprint,
       pg_catalog.string_agg(component || '=' || row_count, '; ' order by component) row_counts,
       'MUST EQUAL candidate_import_data_before_027' as required_comparison
from components;

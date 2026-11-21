-- Migration 030 read-only postdeploy verification.
with target as (
  select procedure.oid,
         pg_catalog.pg_get_userbyid(procedure.proowner) as owner_name,
         procedure.provolatile,
         procedure.prosecdef,
         procedure.proconfig,
         procedure.prosrc,
         procedure.proacl
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace
    on namespace.oid = procedure.pronamespace
  where namespace.nspname = 's2t_fhir_api'
    and procedure.proname = 'get_my_candidate_import'
    and pg_catalog.pg_get_function_identity_arguments(procedure.oid)
          = 'p_candidate_import_request_id uuid'
), checks as (
  select 1 as check_no,
         'get_my_candidate_import metadata exact'::text as check_name,
         count(*) = 1
           and bool_and(owner_name = 's2t_fhir_owner')
           and bool_and(provolatile = 's')
           and bool_and(prosecdef)
           and bool_and(proconfig is not distinct from array['search_path=""']) as passed,
         pg_catalog.format('%s matching routine(s)', count(*)) as detail
  from target
  union all
  select 2,
         'safe projection exposes server baseline identity',
         count(*) = 1 and bool_and(
           prosrc like '%''baselineVersionId'', v_request.baseline_version_id%'),
         pg_catalog.format('%s/1 source exact', count(*) filter (
           where prosrc like '%''baselineVersionId'', v_request.baseline_version_id%'))
  from target
  union all
  select 3,
         'uploader ownership remains enforced',
         count(*) = 1 and bool_and(
           prosrc like '%r.uploader_principal_id = v_actor%'),
         pg_catalog.format('%s/1 source exact', count(*) filter (
           where prosrc like '%r.uploader_principal_id = v_actor%'))
  from target
  union all
  select 4,
         'browser execute ACL remains narrow',
         pg_catalog.has_function_privilege(
           'authenticated', 's2t_fhir_api.get_my_candidate_import(uuid)', 'EXECUTE')
         and not pg_catalog.has_function_privilege(
           'anon', 's2t_fhir_api.get_my_candidate_import(uuid)', 'EXECUTE')
         and not pg_catalog.has_function_privilege(
           'service_role', 's2t_fhir_api.get_my_candidate_import(uuid)', 'EXECUTE')
         and not exists (
           select 1
           from target routine
           cross join lateral pg_catalog.aclexplode(routine.proacl) privilege
           where privilege.grantee = 0
             and privilege.privilege_type = 'EXECUTE'),
         'authenticated only'
)
select check_no, check_name,
       case when passed then 'PASS' else 'FAIL' end as result,
       detail
from checks
order by check_no;

select pg_catalog.count(*) as request_count,
       pg_catalog.max(updated_at) as latest_request_update
from s2t_fhir.candidate_import_request;

-- Migration 029 read-only preflight.
-- Run after accepted Migration 028 and before Migration 029.

with
expected_functions(signature) as (
  values
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)')
),
function_state as (
  select e.signature,p.oid,p.proowner,p.proacl,owner.rolname owner_name,
         p.prosecdef,p.provolatile,p.prokind,p.proconfig,
         pg_catalog.pg_get_function_result(p.oid) result_type
  from expected_functions e
  left join pg_catalog.pg_proc p
    on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
retained as (
  select r.*,
         pg_catalog.encode(a.sha256_digest,'hex') artifact_sha256,
         (select count(*) from s2t_fhir.artifact_sheet_manifest m
          where m.artifact_id=r.artifact_id) manifest_count,
         (select count(*) from s2t_fhir.candidate_import_staging_batch b
          where b.candidate_import_request_id=r.candidate_import_request_id) batch_count,
         (select coalesce(sum(b.row_count),0)
          from s2t_fhir.candidate_import_staging_batch b
          where b.candidate_import_request_id=r.candidate_import_request_id) staged_rows,
         (select count(*) from s2t_fhir.import_candidate_row c
          where c.import_run_id=r.import_run_id) candidate_count,
         (select count(*) from s2t_fhir.mapping_record m
          where m.baseline_version_id=r.baseline_version_id) mapping_count
  from s2t_fhir.candidate_import_request r
  left join s2t_fhir.artifact a on a.artifact_id=r.artifact_id
  where r.candidate_import_request_id='ef7d9ed5-08fa-46d8-90b8-44904e4ab2cd'::uuid
),
subtypes as (
  select count(e.mapping_record_id) element_count,
         count(s.mapping_record_id) status_count,
         count(g.mapping_record_id) guidance_count
  from retained r
  join s2t_fhir.mapping_record m on m.baseline_version_id=r.baseline_version_id
  left join s2t_fhir.element_mapping e using(mapping_record_id)
  left join s2t_fhir.status_mapping_rule s using(mapping_record_id)
  left join s2t_fhir.governance_guidance g using(mapping_record_id)
),
fingerprints as (
  select
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text,E'\n' order by x::text),''))
     from s2t_fhir.candidate_import_request x) request_md5,
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
       (x.candidate_import_staging_batch_id,x.candidate_import_request_id,
        x.validation_attempt_id,x.batch_number,x.batch_digest,x.row_count,
        x.encoded_byte_size,x.staged_at,x.service_actor_principal_id,
        x.correlation_id)::text,E'\n' order by x.candidate_import_staging_batch_id::text),''))
     from s2t_fhir.candidate_import_staging_batch x) batch_md5,
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text,E'\n' order by x::text),''))
     from s2t_fhir.artifact_sheet_manifest x) manifest_md5
),
checks(check_no,check_name,result,detail) as (
  select 1,'expected 026/028 helper signatures and metadata exact',
    case when count(*)=3 and bool_and(oid is not null and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile='v' and prokind='f'
      and proconfig is not distinct from array['search_path=""']
      and result_type='jsonb') then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/3 exact',count(*) filter (where oid is not null
      and owner_name='s2t_fhir_owner' and prosecdef and provolatile='v'
      and proconfig is not distinct from array['search_path=""']
      and result_type='jsonb'))
  from function_state
  union all
  select 2,'Migration 029 objects are absent',
    case when not exists(select 1 from pg_catalog.pg_attribute a
      where a.attrelid='s2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
        and a.attname='reused_from_staging_batch_id' and not a.attisdropped)
      and pg_catalog.to_regprocedure('s2t_fhir.validate_candidate_import_staging_batch_reuse()') is null
      and pg_catalog.to_regprocedure('s2t_fhir._assert_candidate_import_batch_materialization(uuid,jsonb)') is null
      and pg_catalog.to_regprocedure('s2t_fhir._assert_candidate_import_materialization_totals(uuid)') is null
      and pg_catalog.to_regprocedure('s2t_fhir._reconcile_candidate_import_artifact_manifest(uuid,jsonb)') is null
      then 'PASS' else 'FAIL' end,
    'column and four private helpers must not exist'
  union all
  select 3,'attempt-aware staging uniqueness exact',
    case when count(*)=1 and bool_and(c.contype='u' and c.convalidated)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 exact',count(*))
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
    and c.conname='candidate_import_staging_batch_business_uq'
  union all
  select 4,'staging batch append-only trigger exact',
    case when count(*)=1 and bool_and(t.tgenabled='O' and not t.tgisinternal
      and t.tgfoid=pg_catalog.to_regprocedure('s2t_fhir.reject_append_only_change()'))
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 exact',count(*))
  from pg_catalog.pg_trigger t
  where t.tgrelid='s2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
    and t.tgname='candidate_import_staging_batch_append_only_trg'
  union all
  select 5,'artifact manifest uniqueness remains exact',
    case when count(*)=2 and bool_and(c.contype='u' and c.convalidated)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/2 exact',count(*))
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.artifact_sheet_manifest'::pg_catalog.regclass
    and c.conname in ('artifact_sheet_name_uq','artifact_sheet_order_uq')
  union all
  select 6,'service helper ACLs remain narrow',
    case when count(*)=3 and bool_and(
      pg_catalog.has_function_privilege('service_role',oid,'EXECUTE')
      and pg_catalog.has_function_privilege('s2t_fhir_importer',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',oid,'EXECUTE'))
      then 'PASS' else 'FAIL' end,
    'service_role + importer only; browser roles denied'
  from function_state
  union all
  select 7,'private tables deny direct browser and service access',
    case when not pg_catalog.has_table_privilege('anon','s2t_fhir.candidate_import_staging_batch','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('authenticated','s2t_fhir.candidate_import_staging_batch','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('service_role','s2t_fhir.candidate_import_staging_batch','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('anon','s2t_fhir.artifact_sheet_manifest','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('authenticated','s2t_fhir.artifact_sheet_manifest','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('service_role','s2t_fhir.artifact_sheet_manifest','SELECT,INSERT,UPDATE,DELETE')
      then 'PASS' else 'FAIL' end,
    'no direct table privileges'
  union all
  select 8,'retained request is fully staged and incomplete',
    case when count(*)=1 and bool_and(current_state='VALIDATING'
      and validation_run_id is null and batch_count=2 and staged_rows=293
      and candidate_count=293 and mapping_count=293) then 'PASS' else 'FAIL' end,
    coalesce((select pg_catalog.format('state=%s batches=%s staged=%s candidates=%s mappings=%s',
      current_state,batch_count,staged_rows,candidate_count,mapping_count) from retained),'request absent')
  from retained
  union all
  select 9,'retained clean-fixture subtype counts exact',
    case when element_count=238 and status_count=9 and guidance_count=46
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('element=%s status=%s guidance=%s',element_count,status_count,guidance_count)
  from subtypes
  union all
  select 10,'retained artifact manifest collision condition visible',
    case when count(*)=1 and bool_and(
      artifact_sha256='766d1b1e31d00eb6931d70db1ed84ae87c58b554a3e02dabc319497c42696e05'
      and manifest_count=3) then 'PASS' else 'FAIL' end,
    coalesce((select pg_catalog.format('sha256=%s manifests=%s',artifact_sha256,manifest_count)
      from retained),'request absent')
  from retained
  union all
  select 11,'current business-data fingerprints captured','PASS',
    pg_catalog.format('request=%s batch=%s manifest=%s',request_md5,batch_md5,manifest_md5)
  from fingerprints
)
select check_no,check_name,result,detail from checks
union all
select 999,'overall preflight result',
  case when bool_and(result='PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',count(*) filter(where result='PASS'),count(*))
from checks
order by check_no;

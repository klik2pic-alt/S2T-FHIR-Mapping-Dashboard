-- Migration 029 read-only postdeployment verification.

with
expected_private(signature,volatility) as (
  values
    ('s2t_fhir.validate_candidate_import_staging_batch_reuse()','v'),
    ('s2t_fhir._assert_candidate_import_batch_materialization(uuid,jsonb)','v'),
    ('s2t_fhir._assert_candidate_import_materialization_totals(uuid)','v'),
    ('s2t_fhir._reconcile_candidate_import_artifact_manifest(uuid,jsonb)','v')
),
expected_service(signature) as (
  values
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)')
),
private_state as (
  select e.*,p.oid,p.proowner,p.proacl,p.prosrc,owner.rolname owner_name,
         p.prosecdef,p.provolatile,p.prokind,p.proconfig,
         pg_catalog.pg_get_function_result(p.oid) result_type
  from expected_private e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
service_state as (
  select e.signature,p.oid,p.proowner,p.proacl,p.prosrc,owner.rolname owner_name,
         p.prosecdef,p.provolatile,p.prokind,p.proconfig,
         pg_catalog.pg_get_function_result(p.oid) result_type
  from expected_service e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
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
     from s2t_fhir.candidate_import_staging_batch x) historical_batch_md5,
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text,E'\n' order by x::text),''))
     from s2t_fhir.artifact_sheet_manifest x) manifest_md5
),
checks(check_no,check_name,result,detail) as (
  select 1,'replay provenance column exact',
    case when count(*)=1 and bool_and(a.atttypid='uuid'::pg_catalog.regtype
      and not a.attnotnull and not a.attisdropped) then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 exact',count(*))
  from pg_catalog.pg_attribute a
  where a.attrelid='s2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
    and a.attname='reused_from_staging_batch_id'
  union all
  select 2,'replay FK and non-self CHECK exact',
    case when count(*)=2 and bool_and(c.convalidated and c.contype in ('f','c'))
      then 'PASS' else 'FAIL' end,
    pg_catalog.string_agg(c.conname||'='||pg_catalog.pg_get_constraintdef(c.oid),'; ' order by c.conname)
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
    and c.conname in ('candidate_import_staging_batch_reuse_fk',
                      'candidate_import_staging_batch_reuse_not_self_ck')
  union all
  select 3,'replay lookup index exact',
    case when count(*)=1 and bool_and(i.indisvalid and i.indisready and not i.indisunique)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 valid partial index',count(*))
  from pg_catalog.pg_index i
  join pg_catalog.pg_class c on c.oid=i.indexrelid
  where c.relname='candidate_import_staging_batch_reuse_idx'
    and i.indrelid='s2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
  union all
  select 4,'root-only replay validation trigger exact',
    case when count(*)=1 and bool_and(t.tgenabled='O' and not t.tgisinternal
      and t.tgfoid=pg_catalog.to_regprocedure(
        's2t_fhir.validate_candidate_import_staging_batch_reuse()'))
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 exact',count(*))
  from pg_catalog.pg_trigger t
  where t.tgrelid='s2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
    and t.tgname='candidate_import_staging_batch_reuse_validate_trg'
  union all
  select 5,'private helper metadata exact',
    case when count(*)=4 and bool_and(oid is not null and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile=volatility and prokind='f'
      and proconfig is not distinct from array['search_path=""'])
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/4 exact',count(*) filter(where oid is not null
      and owner_name='s2t_fhir_owner' and prosecdef and provolatile=volatility
      and proconfig is not distinct from array['search_path=""']))
  from private_state
  union all
  select 6,'service helper signatures and metadata preserved',
    case when count(*)=2 and bool_and(oid is not null and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile='v' and prokind='f'
      and proconfig is not distinct from array['search_path=""']
      and result_type='jsonb') then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/2 exact',count(*) filter(where oid is not null
      and owner_name='s2t_fhir_owner' and prosecdef and provolatile='v'
      and proconfig is not distinct from array['search_path=""']))
  from service_state
  union all
  select 7,'private helpers have no non-owner EXECUTE grants',
    case when count(*)=4 and bool_and(
      not pg_catalog.has_function_privilege('service_role',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('s2t_fhir_importer',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',oid,'EXECUTE'))
      then 'PASS' else 'FAIL' end,
    'owner-only private implementation helpers'
  from private_state
  union all
  select 8,'service helper ACL remains narrow',
    case when count(*)=2 and bool_and(
      pg_catalog.has_function_privilege('service_role',oid,'EXECUTE')
      and pg_catalog.has_function_privilege('s2t_fhir_importer',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',oid,'EXECUTE'))
      then 'PASS' else 'FAIL' end,
    'service_role + importer only; browser roles denied'
  from service_state
  union all
  select 9,'no direct private-table privilege expansion',
    case when not pg_catalog.has_table_privilege('anon','s2t_fhir.candidate_import_staging_batch','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('authenticated','s2t_fhir.candidate_import_staging_batch','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('service_role','s2t_fhir.candidate_import_staging_batch','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('anon','s2t_fhir.artifact_sheet_manifest','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('authenticated','s2t_fhir.artifact_sheet_manifest','SELECT,INSERT,UPDATE,DELETE')
      and not pg_catalog.has_table_privilege('service_role','s2t_fhir.artifact_sheet_manifest','SELECT,INSERT,UPDATE,DELETE')
      then 'PASS' else 'FAIL' end,
    'browser and service roles retain no table access'
  union all
  select 10,'root-only provenance semantics present',
    case when prosrc like '%v_root.reused_from_staging_batch_id is not null%'
      and prosrc like '%original equivalent materializing batch%'
      then 'PASS' else 'FAIL' end,
    'trigger enforces direct root reference'
  from private_state
  where signature='s2t_fhir.validate_candidate_import_staging_batch_reuse()'
  union all
  select 11,'staging replay algorithm structurally complete',
    case when prosrc like '%_assert_candidate_import_batch_materialization%'
      and prosrc like '%_assert_candidate_import_materialization_totals%'
      and prosrc like '%reused_from_staging_batch_id is null%'
      and prosrc like '%BATCH_DIGEST_MISMATCH:%'
      and prosrc like '%IMPORTED_ROW_REPLAY_MISMATCH:%'
      and prosrc like '%STAGING_REPLAY_MISMATCH:%'
      then 'PASS' else 'FAIL' end,
    'exact row verification + root replay + fixed codes'
  from service_state
  where signature like '%_service_stage_candidate_import_batch%'
  union all
  select 12,'completion algorithm structurally complete',
    case when prosrc like '%_reconcile_candidate_import_artifact_manifest%'
      and prosrc like '%v_batch_count <> v_distinct_batch_count%'
      and prosrc like '%v_batch_rows <> v_candidate_count%'
      and prosrc like '%COMPLETION_ALREADY_APPLIED:%'
      and prosrc like '%set constraints all immediate%'
      then 'PASS' else 'FAIL' end,
    'complete current-attempt batches + manifest reconciliation + terminal fail-closed'
  from service_state
  where signature like '%_service_complete_candidate_import_validation%'
  union all
  select 13,'historical batches were not rewritten',
    case when count(*) filter(where reused_from_staging_batch_id is not null)=0
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('historical=%s replay-linked=%s',count(*),
      count(*) filter(where reused_from_staging_batch_id is not null))
  from s2t_fhir.candidate_import_staging_batch
  union all
  select 14,'retained request remains fully staged and incomplete',
    case when count(*)=1 and bool_and(current_state='VALIDATING'
      and validation_run_id is null and batch_count=2 and staged_rows=293
      and candidate_count=293 and mapping_count=293 and manifest_count=3
      and artifact_sha256='766d1b1e31d00eb6931d70db1ed84ae87c58b554a3e02dabc319497c42696e05')
      then 'PASS' else 'FAIL' end,
    coalesce((select pg_catalog.format(
      'state=%s batches=%s rows=%s mappings=%s manifests=%s',
      current_state,batch_count,candidate_count,mapping_count,manifest_count)
      from retained),'request absent')
  from retained
  union all
  select 15,'retained clean-fixture subtype counts unchanged',
    case when element_count=238 and status_count=9 and guidance_count=46
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('element=%s status=%s guidance=%s',element_count,status_count,guidance_count)
  from subtypes
  union all
  select 16,'business-data fingerprints captured for pre/post comparison','PASS',
    pg_catalog.format('request=%s batch=%s manifest=%s',
      request_md5,historical_batch_md5,manifest_md5)
  from fingerprints
)
select check_no,check_name,result,detail from checks
union all
select 999,'overall postdeploy result',
  case when bool_and(result='PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',count(*) filter(where result='PASS'),count(*))
from checks
order by check_no;

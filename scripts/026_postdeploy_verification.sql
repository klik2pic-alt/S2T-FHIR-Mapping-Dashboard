-- Migration 026 read-only postdeployment verification.
-- SELECT statements only. Any FAIL is a deployment hard stop.

with
public_expected(signature,volatility) as (
  values
    ('s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)','v'),
    ('s2t_fhir_api.get_my_candidate_import(uuid)','s'),
    ('s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)','v')
),
service_expected(signature) as (
  values
    ('s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
    ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)')
),
private_expected(signature,volatility) as (
  values
    ('s2t_fhir.validate_candidate_import_request()','v'),
    ('s2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb)','v'),
    ('s2t_fhir._candidate_ui_upload_capability(uuid)','s')
),
all_expected as (
  select signature,volatility,'public'::text kind,'jsonb'::text expected_result
  from public_expected
  union all select signature,'v','service','jsonb' from service_expected
  union all
  select signature,volatility,'private',
    case when signature='s2t_fhir.validate_candidate_import_request()' then 'trigger'
         when signature='s2t_fhir._candidate_ui_upload_capability(uuid)' then 'boolean'
         else 'jsonb' end
  from private_expected
),
function_state as (
  select e.*,p.oid,p.proowner,p.proacl,p.prosecdef,p.provolatile,p.proconfig,
         p.prokind,owner.rolname owner_name,
         pg_catalog.pg_get_function_result(p.oid) result_type,p.prosrc
  from all_expected e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
expected_columns(relation_name,column_name,data_type,ordinal) as (
  values
    ('candidate_import_request','candidate_import_request_id','uuid',1),
    ('candidate_import_request','resource_config_id','text',2),
    ('candidate_import_request','baseline_series_id','uuid',3),
    ('candidate_import_request','uploader_principal_id','uuid',4),
    ('candidate_import_request','version_label','text',5),
    ('candidate_import_request','original_filename','text',6),
    ('candidate_import_request','declared_byte_size','bigint',7),
    ('candidate_import_request','idempotency_key','uuid',8),
    ('candidate_import_request','expected_candidate_baseline_version_id','uuid',9),
    ('candidate_import_request','expected_candidate_lifecycle_event_id','uuid',10),
    ('candidate_import_request','storage_object_key','text',11),
    ('candidate_import_request','current_state','text',12),
    ('candidate_import_request','artifact_id','uuid',13),
    ('candidate_import_request','baseline_version_id','uuid',14),
    ('candidate_import_request','import_run_id','uuid',15),
    ('candidate_import_request','validation_run_id','uuid',16),
    ('candidate_import_request','published_candidate_lifecycle_event_id','uuid',17),
    ('candidate_import_request','validation_attempt_id','uuid',18),
    ('candidate_import_request','validation_lease_expires_at','timestamp with time zone',19),
    ('candidate_import_request','last_error_code','text',20),
    ('candidate_import_request','last_error_reference','uuid',21),
    ('candidate_import_request','created_at','timestamp with time zone',22),
    ('candidate_import_request','updated_at','timestamp with time zone',23),
    ('candidate_import_request_event','candidate_import_request_event_id','uuid',1),
    ('candidate_import_request_event','candidate_import_request_id','uuid',2),
    ('candidate_import_request_event','sequence_number','integer',3),
    ('candidate_import_request_event','event_code','text',4),
    ('candidate_import_request_event','from_state','text',5),
    ('candidate_import_request_event','to_state','text',6),
    ('candidate_import_request_event','occurred_at','timestamp with time zone',7),
    ('candidate_import_request_event','recorded_at','timestamp with time zone',8),
    ('candidate_import_request_event','actor_principal_id','uuid',9),
    ('candidate_import_request_event','initiating_human_principal_id','uuid',10),
    ('candidate_import_request_event','correlation_id','uuid',11),
    ('candidate_import_request_event','reason','text',12),
    ('candidate_import_request_event','error_code','text',13),
    ('candidate_import_request_event','detail_schema_id','text',14),
    ('candidate_import_request_event','detail_schema_version','integer',15),
    ('candidate_import_request_event','detail_json','jsonb',16),
    ('candidate_import_staging_batch','candidate_import_staging_batch_id','uuid',1),
    ('candidate_import_staging_batch','candidate_import_request_id','uuid',2),
    ('candidate_import_staging_batch','validation_attempt_id','uuid',3),
    ('candidate_import_staging_batch','batch_number','integer',4),
    ('candidate_import_staging_batch','batch_digest','bytea',5),
    ('candidate_import_staging_batch','row_count','integer',6),
    ('candidate_import_staging_batch','encoded_byte_size','integer',7),
    ('candidate_import_staging_batch','staged_at','timestamp with time zone',8),
    ('candidate_import_staging_batch','service_actor_principal_id','uuid',9),
    ('candidate_import_staging_batch','correlation_id','uuid',10)
),
actual_columns as (
  select c.relname relation_name,a.attname column_name,
         pg_catalog.format_type(a.atttypid,a.atttypmod) data_type,a.attnum ordinal
  from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
  join pg_catalog.pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
  where n.nspname='s2t_fhir' and c.relname in (
    'candidate_import_request','candidate_import_request_event','candidate_import_staging_batch')
),
combined_source as (
  select pg_catalog.string_agg(coalesce(prosrc,''),E'\n') source_text
  from function_state
),
artifact_vocabulary as (
  select rd.domain_code,rv.value_code,rv.version_number,rv.display_name,
         rv.description,rv.effective_at,rv.retired_at,rv.is_bootstrap_seed
  from s2t_fhir.reference_domain rd
  join s2t_fhir.reference_value rv using(reference_domain_id)
  where (rd.domain_code,rv.value_code) in (
    ('ARTIFACT_KIND','WORKBOOK'),
    ('ARTIFACT_LOCATION_KIND','OBJECT_STORAGE')
  )
),
append_only_expected(relation_name,trigger_name) as (
  values
    ('candidate_import_request_event','candidate_import_request_event_append_only_trg'),
    ('candidate_import_staging_batch','candidate_import_staging_batch_append_only_trg')
),
append_only_state as (
  select e.relation_name,e.trigger_name,t.oid,t.tgisinternal,t.tgenabled,
         t.tgtype,t.tgfoid
  from append_only_expected e
  left join pg_catalog.pg_class c
    on c.oid=pg_catalog.to_regclass('s2t_fhir.'||e.relation_name)
  left join pg_catalog.pg_trigger t
    on t.tgrelid=c.oid and t.tgname=e.trigger_name
),
checks(check_no,check_name,result,detail) as (
  select 1,'three private tables exist with exact column shape',
    case when not exists ((select * from expected_columns except select * from actual_columns)
                          union all
                          (select * from actual_columns except select * from expected_columns))
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('expected=%s actual=%s',(select count(*) from expected_columns),
      (select count(*) from actual_columns))
  from (select 1) seed
  union all
  select 2,'eleven new function definitions exact',
    case when count(*)=11 and bool_and(oid is not null and owner_name='s2t_fhir_owner'
      and result_type=expected_result) then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/11 present',count(*) filter (where oid is not null))
  from function_state
  union all
  select 3,'function security metadata exact',
    case when count(*)=11 and bool_and(oid is not null and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile=volatility and prokind='f'
      and proconfig is not distinct from array['search_path=""'])
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/11 metadata exact',count(*) filter (where oid is not null
      and owner_name='s2t_fhir_owner' and prosecdef and provolatile=volatility
      and prokind='f' and proconfig is not distinct from array['search_path=""']))
  from function_state
  union all
  select 4,'public RPC ACL exact',
    case when not exists (
      select 1 from function_state f where kind='public' and (oid is null
        or not pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')
        or pg_catalog.has_function_privilege('anon',oid,'EXECUTE'))
    ) and not exists (
      select 1 from function_state f
      cross join lateral pg_catalog.aclexplode(coalesce(f.proacl,
        pg_catalog.acldefault('f',f.proowner))) acl
      where f.kind='public' and acl.privilege_type='EXECUTE'
        and acl.grantee not in (f.proowner,(select oid from pg_catalog.pg_roles where rolname='authenticated'))
    ) then 'PASS' else 'FAIL' end,
    'owner + authenticated only' from (select 1) seed
  union all
  select 5,'service helper ACL exact',
    case when not exists (
      select 1 from function_state f where kind='service' and (oid is null
        or pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')
        or pg_catalog.has_function_privilege('anon',oid,'EXECUTE')
        or not pg_catalog.has_function_privilege('service_role',oid,'EXECUTE')
        or not pg_catalog.has_function_privilege('s2t_fhir_importer',oid,'EXECUTE'))
    ) then 'PASS' else 'FAIL' end,
    'service_role + s2t_fhir_importer; browser roles denied' from (select 1) seed
  union all
  select 6,'private helpers owner-only',
    case when not exists (
      select 1 from function_state f
      cross join (values('authenticated'),('anon'),('service_role'),('s2t_fhir_importer')) r(role_name)
      where f.kind='private' and (f.oid is null
        or pg_catalog.has_function_privilege(r.role_name,f.oid,'EXECUTE'))
    ) then 'PASS' else 'FAIL' end,
    'all non-owner runtime roles denied' from (select 1) seed
  union all
  select 7,'private tables have no client or service DML',
    case when not exists (
      select 1 from (values
        ('s2t_fhir.candidate_import_request'),
        ('s2t_fhir.candidate_import_request_event'),
        ('s2t_fhir.candidate_import_staging_batch')) t(name)
      cross join (values('authenticated'),('anon'),('service_role'),('s2t_fhir_importer')) r(role_name)
      where pg_catalog.has_table_privilege(r.role_name,t.name,'SELECT,INSERT,UPDATE,DELETE')
    ) then 'PASS' else 'FAIL' end,
    'no direct runtime-role table privileges' from (select 1) seed
  union all
  select 8,'append-only triggers exact',
    case when count(*)=2 and bool_and(oid is not null
      and not tgisinternal
      and tgenabled='O'
      and (tgtype::integer & 1)<>0
      and (tgtype::integer & 2)<>0
      and (tgtype::integer & 8)<>0
      and (tgtype::integer & 16)<>0
      and (tgtype::integer & 4)=0
      and (tgtype::integer & 32)=0
      and tgfoid=pg_catalog.to_regprocedure('s2t_fhir.reject_append_only_change()')
    ) and not exists (
      select 1
      from pg_catalog.pg_trigger unexpected
      where unexpected.tgrelid in (
        pg_catalog.to_regclass('s2t_fhir.candidate_import_request_event'),
        pg_catalog.to_regclass('s2t_fhir.candidate_import_staging_batch'))
        and not unexpected.tgisinternal
        and ((unexpected.tgtype::integer & 8)<>0
             or (unexpected.tgtype::integer & 16)<>0)
        and unexpected.tgname not in (
          'candidate_import_request_event_append_only_trg',
          'candidate_import_staging_batch_append_only_trg')
    )
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/2 semantic trigger rows exact; unexpected mutable-path triggers=%s',
      count(*) filter (where oid is not null
        and not tgisinternal and tgenabled='O'
        and (tgtype::integer & 1)<>0 and (tgtype::integer & 2)<>0
        and (tgtype::integer & 8)<>0 and (tgtype::integer & 16)<>0
        and (tgtype::integer & 4)=0 and (tgtype::integer & 32)=0
        and tgfoid=pg_catalog.to_regprocedure('s2t_fhir.reject_append_only_change()')),
      (select count(*) from pg_catalog.pg_trigger unexpected
       where unexpected.tgrelid in (
         pg_catalog.to_regclass('s2t_fhir.candidate_import_request_event'),
         pg_catalog.to_regclass('s2t_fhir.candidate_import_staging_batch'))
         and not unexpected.tgisinternal
         and ((unexpected.tgtype::integer & 8)<>0
              or (unexpected.tgtype::integer & 16)<>0)
         and unexpected.tgname not in (
           'candidate_import_request_event_append_only_trg',
           'candidate_import_staging_batch_append_only_trg')))
  from append_only_state
  union all
  select 9,'state and idempotency constraints present',
    case when count(*)=8 then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/8 constraints present',count(*))
  from pg_catalog.pg_constraint c
  where c.conname in (
    'candidate_import_request_idempotency_uq','candidate_import_request_expected_pair_ck',
    'candidate_import_request_state_ck','candidate_import_request_lease_pair_ck',
    'candidate_import_request_link_shape_ck','candidate_import_request_event_sequence_uq',
    'candidate_import_staging_batch_business_uq','candidate_import_staging_batch_digest_ck')
  union all
  select 10,'live series/version reservation index exact',
    case when count(*)=1 and bool_and(i.indexdef like '%UNIQUE INDEX%'
      and i.indexdef like '%baseline_series_id, version_label%'
      and i.indexdef like '%READY_TO_PUBLISH%') then 'PASS' else 'FAIL' end,
    coalesce(pg_catalog.min(i.indexdef),'ABSENT')
  from pg_catalog.pg_indexes i
  where i.schemaname='s2t_fhir' and i.indexname='candidate_import_request_live_series_label_uq'
  union all
  select 11,'validation ruleset and nine rules exact',
    case when count(*)=9 and count(distinct rule_code)=9
      and min(rs.ruleset_code)='CATO-MEDICATIONREQUEST-XLSX'
      and min(rs.version_label)='v1' then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/9 rules',count(*))
  from s2t_fhir.validation_ruleset rs
  join s2t_fhir.validation_rule r using(validation_ruleset_id)
  where rs.ruleset_code='CATO-MEDICATIONREQUEST-XLSX' and rs.version_label='v1'
  union all
  select 12,'frozen relational identity strategy',
    case when bool_and(pg_catalog.pg_get_expr(d.adbin,d.adrelid)='gen_random_uuid()')
      and count(*)=3 then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/3 random UUID defaults',count(*))
  from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
  join pg_catalog.pg_attribute a on a.attrelid=c.oid and a.attname in (
    'candidate_import_request_id','candidate_import_request_event_id','candidate_import_staging_batch_id')
  join pg_catalog.pg_attrdef d on d.adrelid=c.oid and d.adnum=a.attnum
  where n.nspname='s2t_fhir' and c.relname in (
    'candidate_import_request','candidate_import_request_event','candidate_import_staging_batch')
  union all
  select 13,'no deterministic UUID implementation in Migration 026 functions',
    case when not exists (select 1 from function_state where prosrc~*'uuid_generate|uuid.?v5')
      then 'PASS' else 'FAIL' end,
    'no uuid-ossp, uuid_generate_v5, or custom UUIDv5 call' from (select 1) seed
  union all
  select 14,'CLEAN_IMPORT and Candidate delegation retained',
    case when p.prosrc like '%accepted_count > 0%'
      and p.prosrc like '%error_count = 0%'
      and p.prosrc like '%quarantined_count = 0%'
      and p.prosrc like '%replace_current_candidate(%'
      and p.prosrc like '%Candidate publication changed ACTIVE evidence%'
      then 'PASS' else 'FAIL' end,
    'clean evidence + shared publication + ACTIVE assertion'
  from pg_catalog.pg_proc p
  where p.oid=pg_catalog.to_regprocedure(
    's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')
  union all
  select 15,'Migration 025 signatures and capability keys preserved',
    case when count(*)=2 and bool_and(p.oid is not null and p.prosecdef
      and p.provolatile='s' and p.proconfig is not distinct from array['search_path=""'])
      and bool_and(case when e.signature like '%capabilities%'
        then p.prosrc like '%canReviewCandidate%' and p.prosrc like '%canPromoteCandidate%'
          and p.prosrc like '%canUploadCandidate%'
        else p.prosrc like '%_candidate_ui_snapshot%' end)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/2 compatible',count(*) filter (where p.oid is not null))
  from (values
    ('s2t_fhir_api.get_candidate_ui_context(text)'),
    ('s2t_fhir_api.get_my_candidate_ui_capabilities()')
  ) e(signature)
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  union all
  select 16,'structured error vocabulary and key SQLSTATEs present',
    case when source_text like all(array[
      '%FILE_TYPE_INVALID%','%FILE_SCHEMA_INVALID%','%FILE_TOO_LARGE%',
      '%DUPLICATE_ROW_IDENTITY%','%IMPORT_VALIDATION_FAILED%',
      '%ZERO_ACCEPTED_ROWS%','%CANDIDATE_CHANGED%','%CAPABILITY_REQUIRED%',
      '%IMPORT_CONFLICT%','%VERSION_LABEL_CONFLICT%','%INTERNAL_IMPORT_ERROR%'])
      and source_text like '%CANDIDATE_CHANGED%errcode = ''40001''%'
      and source_text like '%CAPABILITY_REQUIRED%errcode = ''42501''%'
      and source_text like '%IMPORT_CONFLICT%errcode = ''23505''%'
      and source_text like '%IMPORT_VALIDATION_FAILED%errcode = ''23514''%'
      then 'PASS' else 'FAIL' end,
    '11 stable classes; 40001/42501/23505/23514 mappings present'
  from combined_source
  union all
  select 17,'governed workbook and object-storage vocabulary exact',
    case when count(*)=2 and bool_and(
      version_number=1
      and display_name=case domain_code
        when 'ARTIFACT_KIND' then 'Workbook'
        when 'ARTIFACT_LOCATION_KIND' then 'Object storage'
      end
      and description is null
      and is_bootstrap_seed
      and effective_at<=pg_catalog.transaction_timestamp()
      and (retired_at is null or retired_at>pg_catalog.transaction_timestamp())
    ) and (select prosrc like '%ARTIFACT_KIND%WORKBOOK%'
                 and prosrc like '%ARTIFACT_LOCATION_KIND%OBJECT_STORAGE%'
           from pg_catalog.pg_proc
           where oid=pg_catalog.to_regprocedure(
             's2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'))
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/2 exact active bootstrap values',count(*))
  from artifact_vocabulary
)
select check_no,check_name,result,detail from checks
union all
select 999,'overall postdeploy result',
  case when bool_and(result='PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',count(*) filter (where result='PASS'),count(*))
from checks
order by check_no;

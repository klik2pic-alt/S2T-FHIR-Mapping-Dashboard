-- Migration 026 read-only preflight.
-- Run after accepted Migration 025 and before Migration 026.
-- SELECT statements only: no DDL, DML, temporary objects, or session mutation.

with
new_relations(relation_name) as (
  values
    ('s2t_fhir.candidate_import_request'),
    ('s2t_fhir.candidate_import_request_event'),
    ('s2t_fhir.candidate_import_staging_batch')
),
new_functions(signature) as (
  values
    ('s2t_fhir.validate_candidate_import_request()'),
    ('s2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb)'),
    ('s2t_fhir._candidate_ui_upload_capability(uuid)'),
    ('s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)'),
    ('s2t_fhir_api.get_my_candidate_import(uuid)'),
    ('s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)'),
    ('s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
    ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)')
),
required_functions(signature) as (
  values
    ('s2t_fhir_api._resolve_authenticated_principal()'),
    ('s2t_fhir_api._require_authenticated_baseline_capability(text)'),
    ('s2t_fhir_api._candidate_ui_capability_state(uuid)'),
    ('s2t_fhir_api._candidate_ui_snapshot(text)'),
    ('s2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamp with time zone,text,uuid,uuid)'),
    ('s2t_fhir.reject_append_only_change()')
),
required_relations(relation_name) as (
  values
    ('s2t_fhir.principal'),
    ('s2t_fhir.baseline_action_authorization'),
    ('s2t_fhir.mapping_resource_registry'),
    ('s2t_fhir.baseline_series'),
    ('s2t_fhir.baseline_version'),
    ('s2t_fhir.artifact'),
    ('s2t_fhir.artifact_location'),
    ('s2t_fhir.import_run'),
    ('s2t_fhir.import_candidate_row'),
    ('s2t_fhir.logical_mapping_identity'),
    ('s2t_fhir.mapping_record'),
    ('s2t_fhir.element_mapping'),
    ('s2t_fhir.status_mapping_rule'),
    ('s2t_fhir.governance_guidance'),
    ('s2t_fhir.validation_run'),
    ('s2t_fhir.validation_rule'),
    ('s2t_fhir.validation_ruleset'),
    ('s2t_fhir.baseline_candidate_context'),
    ('s2t_fhir.baseline_activation_context')
),
required_reference(domain_code,value_code) as (
  values
    ('BASELINE_TYPE','HUMAN_WORKING_DRAFT'),
    ('ARTIFACT_KIND','WORKBOOK'),
    ('ARTIFACT_LOCATION_KIND','OBJECT_STORAGE'),
    ('ARTIFACT_AVAILABILITY','AVAILABLE'),
    ('ARTIFACT_ROLE','AUTHORITATIVE_SOURCE'),
    ('IMPORT_RUN_STATUS','COMMITTED'),
    ('IMPORT_RUN_STATUS','FAILED'),
    ('VALIDATION_OUTCOME','PASS'),
    ('VALIDATION_OUTCOME','PASS_WITH_WARNINGS'),
    ('VALIDATION_OUTCOME','FAIL'),
    ('BASELINE_LIFECYCLE_STATUS','CANDIDATE'),
    ('BASELINE_LIFECYCLE_STATUS','ACTIVE')
),
checks(check_no,check_name,result,detail) as (
  select 1,'Migration 026 relations are unused',
    case when count(*) filter (where pg_catalog.to_regclass(relation_name) is not null)=0
      then 'PASS' else 'FAIL' end,
    coalesce(pg_catalog.string_agg(relation_name,', ') filter (
      where pg_catalog.to_regclass(relation_name) is not null),'none present')
  from new_relations
  union all
  select 2,'Migration 026 function signatures are unused',
    case when count(*) filter (where pg_catalog.to_regprocedure(signature) is not null)=0
      then 'PASS' else 'FAIL' end,
    coalesce(pg_catalog.string_agg(signature,', ') filter (
      where pg_catalog.to_regprocedure(signature) is not null),'none present')
  from new_functions
  union all
  select 3,'required function dependencies exist',
    case when count(*) filter (where pg_catalog.to_regprocedure(signature) is not null)=count(*)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/%s present',count(*) filter (
      where pg_catalog.to_regprocedure(signature) is not null),count(*))
  from required_functions
  union all
  select 4,'required relation dependencies exist',
    case when count(*) filter (where pg_catalog.to_regclass(relation_name) is not null)=count(*)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/%s present',count(*) filter (
      where pg_catalog.to_regclass(relation_name) is not null),count(*))
  from required_relations
  union all
  select 5,'required active reference values are singular',
    case when bool_and(actual_count=1 and active_count=1) then 'PASS' else 'FAIL' end,
    pg_catalog.string_agg(domain_code||'/'||value_code||
      '=total:'||actual_count||'/active:'||active_count,'; '
      order by domain_code,value_code)
  from (
    select e.domain_code,e.value_code,count(rv.reference_value_id) actual_count,
           count(rv.reference_value_id) filter (
             where rv.effective_at<=pg_catalog.transaction_timestamp()
               and (rv.retired_at is null
                    or rv.retired_at>pg_catalog.transaction_timestamp())) active_count
    from required_reference e
    left join s2t_fhir.reference_domain rd on rd.domain_code=e.domain_code
    left join s2t_fhir.reference_value rv
      on rv.reference_domain_id=rd.reference_domain_id and rv.value_code=e.value_code
    group by e.domain_code,e.value_code
  ) state
  union all
  select 6,'Migration 025 public signatures are singular',
    case when count(*)=2 and bool_and(p.oid is not null and owner.rolname='s2t_fhir_owner'
      and p.prosecdef and p.provolatile='s'
      and p.proconfig is not distinct from array['search_path=""'])
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/2 exact',count(*) filter (where p.oid is not null
      and owner.rolname='s2t_fhir_owner' and p.prosecdef and p.provolatile='s'
      and p.proconfig is not distinct from array['search_path=""']))
  from (values
    ('s2t_fhir_api.get_candidate_ui_context(text)'),
    ('s2t_fhir_api.get_my_candidate_ui_capabilities()')
  ) e(signature)
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
  union all
  select 7,'replace_current_candidate exact callable signature',
    case when p.oid is not null and pg_catalog.pg_get_function_result(p.oid)='jsonb'
      and owner.rolname='s2t_fhir_owner' and p.prosecdef and p.provolatile='v'
      and p.proconfig is not distinct from array['search_path=""']
      then 'PASS' else 'FAIL' end,
    coalesce(pg_catalog.pg_get_function_identity_arguments(p.oid),'ABSENT')
  from (select pg_catalog.to_regprocedure(
    's2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamp with time zone,text,uuid,uuid)') oid) expected
  left join pg_catalog.pg_proc p using(oid)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
  union all
  select 8,'migrator principal is singular',
    case when count(*)=1 then 'PASS' else 'FAIL' end,
    pg_catalog.format('active principals=%s',count(*))
  from s2t_fhir.principal
  where external_issuer='postgres-role' and external_subject='s2t_fhir_migrator'
    and disabled_at is null
  union all
  select 9,'validation ruleset identity is unused',
    case when count(*)=0 then 'PASS' else 'FAIL' end,
    pg_catalog.format('existing rows=%s',count(*))
  from s2t_fhir.validation_ruleset
  where ruleset_code='CATO-MEDICATIONREQUEST-XLSX' and version_label='v1'
  union all
  select 10,'canonical resource registry is singular and enabled',
    case when count(*)=1 and bool_and(source_system='CATO'
      and fhir_resource='MedicationRequest' and is_enabled) then 'PASS' else 'FAIL' end,
    pg_catalog.format('matching rows=%s',count(*))
  from s2t_fhir.mapping_resource_registry
  where resource_config_id='medication-request-cato'
)
select check_no,check_name,result,detail from checks
union all
select 999,'overall preflight result',
  case when bool_and(result='PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',count(*) filter (where result='PASS'),count(*))
from checks
order by check_no;

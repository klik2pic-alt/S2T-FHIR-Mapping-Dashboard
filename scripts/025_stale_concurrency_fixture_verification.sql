-- Migration 025 dedicated stale-read fixture verification.
-- READ ONLY. Valid both before A1 (READY_FOR_STALE_TEST) and after B1/A2
-- (RETAINED_STALE_EVIDENCE). It does not repair or delete retained evidence.

begin transaction read only;

-- Recovery/progress matrix. This remains useful at every retained R1 prefix.
with facts as (
  select
    (select count(*)=2 from s2t_fhir.principal where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001') and external_issuer='supabase-auth' and disabled_at is null
      and (principal_id,external_subject) in (('0255a000-0000-4000-8000-000000000001'::uuid,'0255a001-0000-4000-8000-000000000001'),('0255b000-0000-4000-8000-000000000001'::uuid,'0255b001-0000-4000-8000-000000000001')))
      and (select count(*)=4 from s2t_fhir.baseline_action_authorization where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001') and revoked_at is null)
      and (select count(*)=1 from s2t_fhir.review_actor_authorization where principal_id='0255a000-0000-4000-8000-000000000001' and capability_code='S2T_REVIEW_WRITE' and revoked_at is null)
      and (select count(*)=1 from s2t_fhir.baseline_series where baseline_series_id='02550000-0000-4000-8000-000000000001' and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest')
      and (select count(*)=1 from s2t_fhir.mapping_resource_registry where resource_config_id='t025-stale-20261016-r1-resource' and is_enabled) as sp01_exact,
    (select count(*)=1 from s2t_fhir.baseline_version where baseline_version_id='02550101-0000-4000-8000-000000000001' and baseline_series_id='02550000-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.artifact where artifact_id='02550102-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.baseline_artifact where baseline_version_id='02550101-0000-4000-8000-000000000001' and artifact_id='02550102-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.artifact_sheet_manifest where artifact_sheet_manifest_id='02550104-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.import_run ir join s2t_fhir.reference_value s on s.reference_value_id=ir.terminal_status_value_id where ir.import_run_id='02550103-0000-4000-8000-000000000001' and ir.completed_at is not null and s.value_code='COMMITTED')
      and (select count(*)=1 from s2t_fhir.import_candidate_row where import_candidate_row_id='02550105-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.logical_mapping_identity where logical_mapping_identity_id='02550106-0000-4000-8000-000000000001' and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest')
      and (select count(*)=1 from s2t_fhir.mapping_record where mapping_record_id='02550107-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.element_mapping where mapping_record_id='02550107-0000-4000-8000-000000000001') as sp02_exact,
    (select count(*)=1 from s2t_fhir.baseline_version where baseline_version_id='02550201-0000-4000-8000-000000000001' and baseline_series_id='02550000-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.artifact where artifact_id='02550202-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.baseline_artifact where baseline_version_id='02550201-0000-4000-8000-000000000001' and artifact_id='02550202-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.artifact_sheet_manifest where artifact_sheet_manifest_id='02550204-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.import_run ir join s2t_fhir.reference_value s on s.reference_value_id=ir.terminal_status_value_id where ir.import_run_id='02550203-0000-4000-8000-000000000001' and ir.completed_at is not null and s.value_code='COMMITTED')
      and (select count(*)=1 from s2t_fhir.import_candidate_row where import_candidate_row_id='02550205-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.logical_mapping_identity where logical_mapping_identity_id='02550206-0000-4000-8000-000000000001' and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest')
      and (select count(*)=1 from s2t_fhir.mapping_record where mapping_record_id='02550207-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.element_mapping where mapping_record_id='02550207-0000-4000-8000-000000000001') as sp03_exact,
    exists(select 1 from s2t_fhir.baseline_version where baseline_version_id='02550201-0000-4000-8000-000000000001')
      or exists(select 1 from s2t_fhir.artifact where artifact_id='02550202-0000-4000-8000-000000000001')
      or exists(select 1 from s2t_fhir.import_run where import_run_id='02550203-0000-4000-8000-000000000001') as sp03_any,
    (select count(*)=1 from s2t_fhir.baseline_version where baseline_version_id='02550301-0000-4000-8000-000000000001' and baseline_series_id='02550000-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.artifact where artifact_id='02550302-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.baseline_artifact where baseline_version_id='02550301-0000-4000-8000-000000000001' and artifact_id='02550302-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.import_run ir join s2t_fhir.reference_value s on s.reference_value_id=ir.terminal_status_value_id where ir.import_run_id='02550303-0000-4000-8000-000000000001' and ir.completed_at is not null and s.value_code='COMMITTED')
      and (select count(*)=0 from s2t_fhir.mapping_record where baseline_version_id='02550301-0000-4000-8000-000000000001') as sp04_exact,
    exists(select 1 from s2t_fhir.baseline_version where baseline_version_id='02550301-0000-4000-8000-000000000001')
      or exists(select 1 from s2t_fhir.artifact where artifact_id='02550302-0000-4000-8000-000000000001')
      or exists(select 1 from s2t_fhir.import_run where import_run_id='02550303-0000-4000-8000-000000000001') as sp04_any,
    (select count(*)=1 from s2t_fhir.baseline_candidate_context where baseline_version_id='02550101-0000-4000-8000-000000000001') as sp05_exact,
    (select count(*)=1 from s2t_fhir.review_session where session_name='T025-STALE-20261016-R1-V1-REVIEW' and ended_at is not null)
      and (select count(*)=1 from s2t_fhir.mapping_review_event where baseline_version_id='02550101-0000-4000-8000-000000000001') as sp06_exact,
    (select count(*)=1 from s2t_fhir.validation_run where validation_run_id='02550108-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550109-0000-4000-8000-000000000001') as sp07_exact,
    (select count(*)=1 from s2t_fhir.baseline_activation_context where baseline_version_id='02550101-0000-4000-8000-000000000001') as sp08_exact,
    (select count(*)=1 from s2t_fhir.baseline_candidate_context where baseline_version_id='02550201-0000-4000-8000-000000000001') as sp09_exact,
    (select count(*)=1 from s2t_fhir.review_session where session_name='T025-STALE-20261016-R1-V2-REVIEW' and ended_at is not null)
      and (select count(*)=1 from s2t_fhir.mapping_review_event where baseline_version_id='02550201-0000-4000-8000-000000000001') as sp10_exact,
    (select count(*)=1 from s2t_fhir.validation_run where validation_run_id='02550208-0000-4000-8000-000000000001')
      and (select count(*)=1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550209-0000-4000-8000-000000000001') as sp11_exact,
    (select count(*) from s2t_fhir.baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') as lifecycle_count,
    (select count(*) from s2t_fhir.baseline_candidate_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') as candidate_context_count,
    (select count(*) from s2t_fhir.baseline_activation_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') as activation_context_count,
    (select count(*) from s2t_fhir.baseline_relationship r join s2t_fhir.baseline_version b on b.baseline_version_id=r.from_baseline_version_id where b.baseline_series_id='02550000-0000-4000-8000-000000000001') as relationship_count,
    (select count(*) from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') as current_leaf_count,
    (select count(*)=1 from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id where b.baseline_version_id='02550101-0000-4000-8000-000000000001' and v.value_code='ACTIVE') as v1_current_active,
    (select count(*)=1 from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id where b.baseline_version_id='02550201-0000-4000-8000-000000000001' and v.value_code='CANDIDATE') as v2_current_candidate,
    (select count(*)=1 from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id where b.baseline_version_id='02550201-0000-4000-8000-000000000001' and v.value_code='SUPERSEDED') as v2_current_superseded,
    (select count(*)=1 from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id where b.baseline_version_id='02550301-0000-4000-8000-000000000001' and v.value_code='CANDIDATE') as v3_current_candidate
), progress as (
  select checkpoint,exact_state from facts cross join lateral (values
    ('SP01',sp01_exact),('SP02',sp02_exact),('SP03',sp03_exact),('SP04',sp04_exact),
    ('SP05',sp05_exact),('SP06',sp06_exact),('SP07',sp07_exact),('SP08',sp08_exact),
    ('SP09',sp09_exact),('SP10',sp10_exact),('SP11',sp11_exact)
  ) p(checkpoint,exact_state)
)
select checkpoint,case when exact_state then 'EXACT' else 'NOT_EXACT' end state
from progress
union all
select 'RECOVERY_STATE',case
  when sp01_exact and sp02_exact and not sp03_any and not sp04_any and not sp05_exact
    then 'EXPECTED_PREFIX_SP01_SP02_ONLY'
  when sp01_exact and sp02_exact and sp03_exact and not sp04_any and not sp05_exact
    then 'EXPECTED_PREFIX_THROUGH_SP03'
  when sp01_exact and sp02_exact and sp03_exact and sp04_exact and not sp05_exact
    then 'EXPECTED_PREFIX_THROUGH_SP04'
  when sp01_exact and sp02_exact and sp03_exact and sp04_exact
       and sp05_exact and sp06_exact and sp07_exact and sp08_exact
       and sp09_exact and sp10_exact and sp11_exact
       and lifecycle_count=5 and candidate_context_count=3
       and activation_context_count=1 and relationship_count=1
       and current_leaf_count=3 and v1_current_active
       and v2_current_superseded and v3_current_candidate
    then 'RETAINED_STALE_EVIDENCE'
  when sp01_exact and sp02_exact and sp03_exact and sp04_exact
       and sp05_exact and sp06_exact and sp07_exact and sp08_exact
       and sp09_exact and sp10_exact and sp11_exact
       and lifecycle_count=3 and candidate_context_count=2
       and activation_context_count=1 and relationship_count=0
       and current_leaf_count=2 and v1_current_active and v2_current_candidate
    then 'READY_FOR_STALE_TEST'
  else 'PARTIAL_OR_CONFLICTING_STATE'
end
from facts
order by checkpoint;

select check_name,
       case when ok then 'PASS' else 'FAIL' end result,
       detail
from (
  select 1 ord,'dedicated identities exact' check_name,
         (select count(*)=2 from s2t_fhir.principal where principal_id in
           ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001')
           and external_issuer='supabase-auth' and disabled_at is null)
         and (select count(*)=1 from s2t_fhir.baseline_series
           where baseline_series_id='02550000-0000-4000-8000-000000000001'
             and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest')
         and (select count(*)=1 from s2t_fhir.mapping_resource_registry
           where resource_config_id='t025-stale-20261016-r1-resource'
             and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest' and is_enabled) ok,
         pg_catalog.format('principals=%s series=%s registry=%s',
           (select count(*) from s2t_fhir.principal where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001')),
           (select count(*) from s2t_fhir.baseline_series where baseline_series_id='02550000-0000-4000-8000-000000000001'),
           (select count(*) from s2t_fhir.mapping_resource_registry where resource_config_id='t025-stale-20261016-r1-resource')) detail
  union all
  select 2,'fixture capabilities exact',
         (select count(*)=4 from s2t_fhir.baseline_action_authorization
          where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001')
            and capability_code in ('S2T_BASELINE_UPLOAD','S2T_BASELINE_PROMOTE') and revoked_at is null)
         and (select count(*)=1 from s2t_fhir.review_actor_authorization
          where principal_id='0255a000-0000-4000-8000-000000000001'
            and capability_code='S2T_REVIEW_WRITE' and revoked_at is null)
         and (select count(*)=0 from s2t_fhir.review_actor_authorization
          where principal_id='0255b000-0000-4000-8000-000000000001' and revoked_at is null),
         pg_catalog.format('baseline_actions=%s A_review=%s B_review=%s',
          (select count(*) from s2t_fhir.baseline_action_authorization where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001') and revoked_at is null),
          (select count(*) from s2t_fhir.review_actor_authorization where principal_id='0255a000-0000-4000-8000-000000000001' and revoked_at is null),
          (select count(*) from s2t_fhir.review_actor_authorization where principal_id='0255b000-0000-4000-8000-000000000001' and revoked_at is null))
  union all
  select 3,'V1/V2/V3 immutable provenance exact',
         (select count(*)=3 from s2t_fhir.baseline_version where baseline_version_id in
           ('02550101-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001')
           and baseline_series_id='02550000-0000-4000-8000-000000000001')
         and (select count(*)=3 from s2t_fhir.artifact where artifact_id in
           ('02550102-0000-4000-8000-000000000001','02550202-0000-4000-8000-000000000001','02550302-0000-4000-8000-000000000001'))
         and (select count(*)=3 from s2t_fhir.import_run where import_run_id in
           ('02550103-0000-4000-8000-000000000001','02550203-0000-4000-8000-000000000001','02550303-0000-4000-8000-000000000001') and completed_at is not null),
         pg_catalog.format('baselines=%s artifacts=%s committed_imports=%s',
           (select count(*) from s2t_fhir.baseline_version where baseline_series_id='02550000-0000-4000-8000-000000000001'),
           (select count(*) from s2t_fhir.artifact where artifact_id in ('02550102-0000-4000-8000-000000000001','02550202-0000-4000-8000-000000000001','02550302-0000-4000-8000-000000000001')),
           (select count(*) from s2t_fhir.import_run ir join s2t_fhir.reference_value v on v.reference_value_id=ir.terminal_status_value_id where ir.import_run_id in ('02550103-0000-4000-8000-000000000001','02550203-0000-4000-8000-000000000001','02550303-0000-4000-8000-000000000001') and v.value_code='COMMITTED'))
  union all
  select 4,'mapped V1/V2 and bare V3 exact',
         (select count(*)=1 from s2t_fhir.mapping_record where baseline_version_id='02550101-0000-4000-8000-000000000001')
         and (select count(*)=1 from s2t_fhir.mapping_record where baseline_version_id='02550201-0000-4000-8000-000000000001')
         and (select count(*)=0 from s2t_fhir.mapping_record where baseline_version_id='02550301-0000-4000-8000-000000000001'),
         pg_catalog.format('V1=%s V2=%s V3=%s',
           (select count(*) from s2t_fhir.mapping_record where baseline_version_id='02550101-0000-4000-8000-000000000001'),
           (select count(*) from s2t_fhir.mapping_record where baseline_version_id='02550201-0000-4000-8000-000000000001'),
           (select count(*) from s2t_fhir.mapping_record where baseline_version_id='02550301-0000-4000-8000-000000000001'))
  union all
  select 5,'V1/V2 governed readiness evidence exact',
         (select count(*)=2 from s2t_fhir.review_session where session_name in ('T025-STALE-20261016-R1-V1-REVIEW','T025-STALE-20261016-R1-V2-REVIEW') and ended_at is not null)
         and (select count(*)=2 from s2t_fhir.validation_run where validation_run_id in ('02550108-0000-4000-8000-000000000001','02550208-0000-4000-8000-000000000001'))
         and (select count(*)=2 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id in ('02550109-0000-4000-8000-000000000001','02550209-0000-4000-8000-000000000001')),
         pg_catalog.format('closed_reviews=%s validations=%s gates=%s',
           (select count(*) from s2t_fhir.review_session where session_name in ('T025-STALE-20261016-R1-V1-REVIEW','T025-STALE-20261016-R1-V2-REVIEW') and ended_at is not null),
           (select count(*) from s2t_fhir.validation_run where validation_run_id in ('02550108-0000-4000-8000-000000000001','02550208-0000-4000-8000-000000000001')),
           (select count(*) from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id in ('02550109-0000-4000-8000-000000000001','02550209-0000-4000-8000-000000000001')))
  union all
  select 6,'allowed retained lifecycle shape',
         ((select count(*) from s2t_fhir.baseline_candidate_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') in (2,3))
         and (select count(*)=1 from s2t_fhir.baseline_activation_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001')
         and (select count(*) from s2t_fhir.baseline_relationship r join s2t_fhir.baseline_version b on b.baseline_version_id=r.from_baseline_version_id where b.baseline_series_id='02550000-0000-4000-8000-000000000001') in (0,1)
         and (select count(*)=1 from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id where b.baseline_series_id='02550000-0000-4000-8000-000000000001' and v.value_code='ACTIVE' and b.baseline_version_id='02550101-0000-4000-8000-000000000001')
         and (select count(*)=1 from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id where b.baseline_series_id='02550000-0000-4000-8000-000000000001' and v.value_code='CANDIDATE' and b.baseline_version_id in ('02550201-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001')),
         pg_catalog.format('candidate_contexts=%s activation_contexts=%s relationships=%s lifecycle_events=%s',
           (select count(*) from s2t_fhir.baseline_candidate_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001'),
           (select count(*) from s2t_fhir.baseline_activation_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001'),
           (select count(*) from s2t_fhir.baseline_relationship r join s2t_fhir.baseline_version b on b.baseline_version_id=r.from_baseline_version_id where b.baseline_series_id='02550000-0000-4000-8000-000000000001'),
           (select count(*) from s2t_fhir.baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001'))
) checks
order by ord;

-- Public Migration 025 observation. Before B1 this must report ready=true and
-- Candidate V2. After B1 it reports Candidate V3 and ready=false, as intended.
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
with snapshot as materialized (
  select s2t_fhir_api.get_candidate_ui_context('t025-stale-20261016-r1-resource') value
), readiness as (
  select s2t_fhir_api.get_candidate_promotion_readiness(
    't025-stale-20261016-r1-resource',
    (value#>>'{candidate,baselineVersionId}')::uuid,
    (value#>>'{candidate,lifecycleEventId}')::uuid,
    (value#>>'{active,baselineVersionId}')::uuid,
    (value#>>'{active,lifecycleEventId}')::uuid,
    transaction_timestamp()) value
  from snapshot
)
select 'PUBLIC_CONTEXT' evidence_type,s.value evidence from snapshot s
union all
select 'PUBLIC_READINESS',r.value from readiness r;
reset role;

-- Final retained-evidence query. Exact cardinalities make any partial A2 write
-- visible. POST_STALE_RETAINED requires V2 SUPERSEDED, V3 CANDIDATE, V1 ACTIVE,
-- three publication contexts, one activation context, and one relationship.
with lifecycle as (
  select b.baseline_version_id,b.baseline_code,e.baseline_lifecycle_event_id,
         status.value_code lifecycle_status,e.occurred_at,e.supersedes_event_id,
         not exists(select 1 from s2t_fhir.baseline_lifecycle_event n where n.supersedes_event_id=e.baseline_lifecycle_event_id) is_current
  from s2t_fhir.baseline_version b
  join s2t_fhir.baseline_lifecycle_event e using(baseline_version_id)
  join s2t_fhir.reference_value status on status.reference_value_id=e.lifecycle_status_value_id
  where b.baseline_series_id='02550000-0000-4000-8000-000000000001'
), counts as (
  select
    (select count(*) from s2t_fhir.baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') lifecycle_count,
    (select count(*) from s2t_fhir.baseline_candidate_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') candidate_context_count,
    (select count(*) from s2t_fhir.baseline_activation_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') activation_context_count,
    (select count(*) from s2t_fhir.baseline_relationship r join s2t_fhir.baseline_version b on b.baseline_version_id=r.from_baseline_version_id where b.baseline_series_id='02550000-0000-4000-8000-000000000001') relationship_count
)
select case
         when (select count(*) from lifecycle where is_current and baseline_version_id='02550101-0000-4000-8000-000000000001' and lifecycle_status='ACTIVE')=1
          and (select count(*) from lifecycle where is_current and baseline_version_id='02550201-0000-4000-8000-000000000001' and lifecycle_status='CANDIDATE')=1
          and c.lifecycle_count=3 and c.candidate_context_count=2 and c.activation_context_count=1 and c.relationship_count=0
         then 'READY_FOR_STALE_TEST'
         when (select count(*) from lifecycle where is_current and baseline_version_id='02550101-0000-4000-8000-000000000001' and lifecycle_status='ACTIVE')=1
          and (select count(*) from lifecycle where is_current and baseline_version_id='02550201-0000-4000-8000-000000000001' and lifecycle_status='SUPERSEDED')=1
          and (select count(*) from lifecycle where is_current and baseline_version_id='02550301-0000-4000-8000-000000000001' and lifecycle_status='CANDIDATE')=1
          and c.lifecycle_count=5 and c.candidate_context_count=3 and c.activation_context_count=1 and c.relationship_count=1
         then 'RETAINED_STALE_EVIDENCE'
         else 'FAIL_UNEXPECTED_OR_PARTIAL_STATE'
       end fixture_state,
       c.*,
       (select jsonb_agg(to_jsonb(l) order by l.occurred_at,l.baseline_lifecycle_event_id) from lifecycle l) lifecycle_evidence,
       (select jsonb_agg(to_jsonb(r) order by r.baseline_relationship_id)
        from s2t_fhir.baseline_relationship r
        join s2t_fhir.baseline_version b on b.baseline_version_id=r.from_baseline_version_id
        where b.baseline_series_id='02550000-0000-4000-8000-000000000001') relationship_evidence
from counts c;

rollback;

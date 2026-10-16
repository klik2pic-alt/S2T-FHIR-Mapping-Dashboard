-- Migration 025 retained R1 recovery: SP04 only.
-- Run with direct psql in a NEW connection after SP03 has disconnected.
-- This transaction finalizes exactly one baseline/import (V3).
-- Never set/reset s2t_fhir.finalizing_baseline from fixture SQL.

begin;
set local role s2t_fhir_owner;
set constraints all deferred;

do $sp04_resume_guard$
declare
  v_status text;
begin
  -- SP03 must be exact, including its mapped finalized import.
  select status.value_code into v_status
  from s2t_fhir.import_run ir
  join s2t_fhir.reference_value status on status.reference_value_id=ir.terminal_status_value_id
  where ir.import_run_id='02550203-0000-4000-8000-000000000001'
    and ir.baseline_version_id='02550201-0000-4000-8000-000000000001'
    and ir.artifact_id='02550202-0000-4000-8000-000000000001'
    and ir.completed_at is not null;

  if (select count(*) from s2t_fhir.baseline_version
      where baseline_version_id='02550201-0000-4000-8000-000000000001'
        and baseline_series_id='02550000-0000-4000-8000-000000000001'
        and baseline_code='T025-STALE-20261016-R1-V2') <> 1
     or (select count(*) from s2t_fhir.artifact where artifact_id='02550202-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.baseline_artifact
         where baseline_version_id='02550201-0000-4000-8000-000000000001'
           and artifact_id='02550202-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.artifact_sheet_manifest
         where artifact_sheet_manifest_id='02550204-0000-4000-8000-000000000001'
           and artifact_id='02550202-0000-4000-8000-000000000001') <> 1
     or v_status is distinct from 'COMMITTED'
     or (select count(*) from s2t_fhir.import_candidate_row
         where import_candidate_row_id='02550205-0000-4000-8000-000000000001'
           and import_run_id='02550203-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.logical_mapping_identity
         where logical_mapping_identity_id='02550206-0000-4000-8000-000000000001'
           and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest') <> 1
     or (select count(*) from s2t_fhir.mapping_record
         where mapping_record_id='02550207-0000-4000-8000-000000000001'
           and baseline_version_id='02550201-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.element_mapping
         where mapping_record_id='02550207-0000-4000-8000-000000000001') <> 1 then
    raise exception 'SP04 resume: SP03 is not exact' using errcode='55000';
  end if;

  -- SP04 must be wholly absent, including any downstream lifecycle evidence.
  if exists(select 1 from s2t_fhir.baseline_version where baseline_version_id='02550301-0000-4000-8000-000000000001' or baseline_code='T025-STALE-20261016-R1-V3')
     or exists(select 1 from s2t_fhir.artifact where artifact_id='02550302-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_artifact where baseline_version_id='02550301-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.import_run where import_run_id='02550303-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_candidate_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.review_session where baseline_version_id in ('02550101-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id in ('02550108-0000-4000-8000-000000000001','02550208-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id in ('02550109-0000-4000-8000-000000000001','02550209-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.baseline_activation_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001') then
    raise exception 'SP04 resume: SP04 or downstream state is already/partially present' using errcode='55000';
  end if;
end
$sp04_resume_guard$;

insert into s2t_fhir.baseline_version
  (baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,
   import_specification_version,description,created_by_principal_id)
values
  ('02550301-0000-4000-8000-000000000001','02550000-0000-4000-8000-000000000001',
   'T025-STALE-20261016-R1-V3','T025-STALE-20261016-R1-V3',false,
   'T025-STALE-20261016-R1-v1','Dedicated stale fixture unpublished replacement',
   '0255b000-0000-4000-8000-000000000001');

insert into s2t_fhir.artifact
  (artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,
   physical_filename,captured_at,description,created_by_principal_id)
select '02550302-0000-4000-8000-000000000001',v.reference_value_id,
       decode(md5('T025-STALE-20261016-R1-V3-a1')||md5('T025-STALE-20261016-R1-V3-a2'),'hex'),
       1,'application/test','T025-STALE-20261016-R1-V3.xlsx',transaction_timestamp(),
       'T025 stale V3 artifact','0255b000-0000-4000-8000-000000000001'
from s2t_fhir.reference_value v
join s2t_fhir.reference_domain d using(reference_domain_id)
where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';

insert into s2t_fhir.baseline_artifact
  (baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id)
select '02550301-0000-4000-8000-000000000001','02550302-0000-4000-8000-000000000001',
       v.reference_value_id,'T025 stale V3 authoritative','0255b000-0000-4000-8000-000000000001'
from s2t_fhir.reference_value v
join s2t_fhir.reference_domain d using(reference_domain_id)
where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';

insert into s2t_fhir.import_run
  (import_run_id,baseline_version_id,artifact_id,import_policy_value_id,
   import_specification_version,importer_version,configuration_digest,
   started_at,completed_at,terminal_status_value_id,actor_principal_id)
select '02550303-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001',
       '02550302-0000-4000-8000-000000000001',p.reference_value_id,
       'T025-STALE-20261016-R1-v1','T025-STALE-20261016-R1-importer',
       decode(md5('T025-STALE-20261016-R1-V3-c1')||md5('T025-STALE-20261016-R1-V3-c2'),'hex'),
       transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',
       s.reference_value_id,'0255b000-0000-4000-8000-000000000001'
from s2t_fhir.reference_value p
join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id
cross join s2t_fhir.reference_value s
join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id
where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT'
  and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';

commit;

select 'SP04' checkpoint,'COMPLETE_DISCONNECT_NOW' state,
       '02550301-0000-4000-8000-000000000001'::uuid baseline_version_id,
       '02550303-0000-4000-8000-000000000001'::uuid import_run_id;

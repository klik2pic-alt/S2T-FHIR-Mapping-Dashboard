-- Migration 025 retained R1 recovery: SP03 only.
-- Run with direct psql in a NEW PostgreSQL connection, then disconnect.
-- This transaction finalizes exactly one baseline/import (V2).
-- Never set/reset s2t_fhir.finalizing_baseline from fixture SQL.

begin;
set local role s2t_fhir_owner;
set constraints all deferred;

do $sp03_resume_guard$
declare
  v_import_status text;
begin
  -- SP01 must be exact.
  if (select count(*) from s2t_fhir.principal
      where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001')
        and external_issuer='supabase-auth' and disabled_at is null
        and (principal_id,external_subject) in (
          ('0255a000-0000-4000-8000-000000000001'::uuid,'0255a001-0000-4000-8000-000000000001'),
          ('0255b000-0000-4000-8000-000000000001'::uuid,'0255b001-0000-4000-8000-000000000001')
        )) <> 2
     or (select count(*) from s2t_fhir.baseline_action_authorization
         where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001')
           and capability_code in ('S2T_BASELINE_UPLOAD','S2T_BASELINE_PROMOTE') and revoked_at is null) <> 4
     or (select count(*) from s2t_fhir.review_actor_authorization
         where principal_id='0255a000-0000-4000-8000-000000000001'
           and capability_code='S2T_REVIEW_WRITE' and revoked_at is null) <> 1
     or exists(select 1 from s2t_fhir.review_actor_authorization
         where principal_id='0255b000-0000-4000-8000-000000000001' and revoked_at is null)
     or (select count(*) from s2t_fhir.baseline_series
         where baseline_series_id='02550000-0000-4000-8000-000000000001'
           and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest') <> 1
     or (select count(*) from s2t_fhir.mapping_resource_registry
         where resource_config_id='t025-stale-20261016-r1-resource'
           and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest' and is_enabled) <> 1 then
    raise exception 'SP03 resume: SP01 is not exact' using errcode='55000';
  end if;

  -- SP02 must be exact and terminal COMMITTED.
  select status.value_code into v_import_status
  from s2t_fhir.import_run ir
  join s2t_fhir.reference_value status on status.reference_value_id=ir.terminal_status_value_id
  where ir.import_run_id='02550103-0000-4000-8000-000000000001'
    and ir.baseline_version_id='02550101-0000-4000-8000-000000000001'
    and ir.artifact_id='02550102-0000-4000-8000-000000000001'
    and ir.completed_at is not null;

  if (select count(*) from s2t_fhir.baseline_version
      where baseline_version_id='02550101-0000-4000-8000-000000000001'
        and baseline_series_id='02550000-0000-4000-8000-000000000001'
        and baseline_code='T025-STALE-20261016-R1-V1') <> 1
     or (select count(*) from s2t_fhir.artifact where artifact_id='02550102-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.baseline_artifact
         where baseline_version_id='02550101-0000-4000-8000-000000000001'
           and artifact_id='02550102-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.artifact_sheet_manifest
         where artifact_sheet_manifest_id='02550104-0000-4000-8000-000000000001'
           and artifact_id='02550102-0000-4000-8000-000000000001') <> 1
     or v_import_status is distinct from 'COMMITTED'
     or (select count(*) from s2t_fhir.import_candidate_row
         where import_candidate_row_id='02550105-0000-4000-8000-000000000001'
           and import_run_id='02550103-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.logical_mapping_identity
         where logical_mapping_identity_id='02550106-0000-4000-8000-000000000001'
           and source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest') <> 1
     or (select count(*) from s2t_fhir.mapping_record
         where mapping_record_id='02550107-0000-4000-8000-000000000001'
           and baseline_version_id='02550101-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.element_mapping
         where mapping_record_id='02550107-0000-4000-8000-000000000001') <> 1 then
    raise exception 'SP03 resume: SP02 is not exact' using errcode='55000';
  end if;

  -- SP03 must be wholly absent. Any deterministic object is a conflict.
  if exists(select 1 from s2t_fhir.baseline_version where baseline_version_id='02550201-0000-4000-8000-000000000001' or baseline_code='T025-STALE-20261016-R1-V2')
     or exists(select 1 from s2t_fhir.artifact where artifact_id='02550202-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_artifact where baseline_version_id='02550201-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.artifact_sheet_manifest where artifact_sheet_manifest_id='02550204-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.import_run where import_run_id='02550203-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.import_candidate_row where import_candidate_row_id='02550205-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.logical_mapping_identity where logical_mapping_identity_id='02550206-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.mapping_record where mapping_record_id='02550207-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.element_mapping where mapping_record_id='02550207-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id='02550301-0000-4000-8000-000000000001' or baseline_code='T025-STALE-20261016-R1-V3')
     or exists(select 1 from s2t_fhir.artifact where artifact_id='02550302-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.import_run where import_run_id='02550303-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.review_session where baseline_version_id in ('02550101-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id in ('02550108-0000-4000-8000-000000000001','02550208-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id in ('02550109-0000-4000-8000-000000000001','02550209-0000-4000-8000-000000000001')) then
    raise exception 'SP03 resume: SP03 or downstream state is already/partially present' using errcode='55000';
  end if;
end
$sp03_resume_guard$;

do $sp03_resume$
declare
  v_b constant uuid:='02550201-0000-4000-8000-000000000001';
  v_a constant uuid:='02550202-0000-4000-8000-000000000001';
  v_i constant uuid:='02550203-0000-4000-8000-000000000001';
  v_mf constant uuid:='02550204-0000-4000-8000-000000000001';
  v_row constant uuid:='02550205-0000-4000-8000-000000000001';
  v_li constant uuid:='02550206-0000-4000-8000-000000000001';
  v_m constant uuid:='02550207-0000-4000-8000-000000000001';
  v_hash text:=md5('T025-STALE-20261016-R1-V2-node-1')||md5('T025-STALE-20261016-R1-V2-node-2');
begin
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_b,'02550000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V2','T025-STALE-20261016-R1-V2',false,'T025-STALE-20261016-R1-v1','Dedicated stale fixture promotion-ready Candidate','0255a000-0000-4000-8000-000000000001');
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_a,v.reference_value_id,decode(md5('T025-STALE-20261016-R1-V2-a1')||md5('T025-STALE-20261016-R1-V2-a2'),'hex'),1,'application/test','T025-STALE-20261016-R1-V2.xlsx',transaction_timestamp(),'T025 stale V2 artifact','0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_b,v_a,v.reference_value_id,'T025 stale V2 authoritative','0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_mf,v_a,'T025-STALE-V2-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T025 stale V2 manifest','T025-STALE-manifest','1',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_i,v_b,v_a,p.reference_value_id,'T025-STALE-20261016-R1-v1','T025-STALE-20261016-R1-importer',decode(md5('T025-STALE-20261016-R1-V2-c1')||md5('T025-STALE-20261016-R1-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,'0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_i,mk.reference_value_id,'T025-STALE-V2-SHEET',2,'A2:Q2','T025-STALE-raw','1',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2'),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_li,v.reference_value_id,'T025-STALE-20261016-R1','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_m,v_b,v_row,v_li,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_m,'MedicationRequest.status','T025-STALE-20261016-R1','T025-STALE-20261016-R1.V2.source','LOCAL','T025 stale V2 mapping');
end
$sp03_resume$;

commit;

select 'SP03' checkpoint,'COMPLETE_DISCONNECT_NOW' state,
       '02550201-0000-4000-8000-000000000001'::uuid baseline_version_id,
       '02550203-0000-4000-8000-000000000001'::uuid import_run_id;

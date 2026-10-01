begin;
set role s2t_fhir_owner;

do $test$
declare
  service_principal uuid; baseline_type uuid; artifact_kind uuid; artifact_role uuid; import_policy uuid;
  element_kind uuid; accepted_disposition uuid; quarantined_disposition uuid; final_status uuid;
  metric_candidate uuid; error_severity uuid; warning_severity uuid; validation_pass uuid; validation_clean uuid; validation_fail uuid;
  finding_subject uuid; quarantine_opened uuid; gate_pending uuid; gate_passed uuid; requirement_passed uuid; requirement_failed uuid; lifecycle_active uuid;
  severity_reference_domain_id uuid; ruleset_id uuid; alternate_ruleset_id uuid := gen_random_uuid(); warning_rule_id uuid; error_rule_id uuid;
  gate_id uuid; gate_requirement_id uuid;
  baseline_series_id uuid := gen_random_uuid(); baseline_id uuid := gen_random_uuid();
  artifact_id uuid := gen_random_uuid(); second_artifact_id uuid := gen_random_uuid();
  import_id uuid := gen_random_uuid(); subtype_import_id uuid := gen_random_uuid(); clean_import_id uuid := gen_random_uuid(); accepted_candidate_id uuid := gen_random_uuid();
  accepted_identity_id uuid := gen_random_uuid(); accepted_mapping_id uuid := gen_random_uuid();
  mismatch_mapping_id uuid;
  accepted_validation_id uuid := gen_random_uuid(); accepted_warning_id uuid := gen_random_uuid();
  quarantine_import_id uuid := gen_random_uuid(); quarantined_candidate_id uuid := gen_random_uuid();
  quarantined_validation_id uuid := gen_random_uuid(); quarantine_finding_id uuid := gen_random_uuid();
  quarantine_case_id uuid := gen_random_uuid(); quarantine_identity_id uuid := gen_random_uuid();
  passed_evaluation_id uuid := gen_random_uuid();
  test_validation_id uuid;
begin
  select principal_id into strict service_principal from s2t_fhir.principal where external_issuer='postgres-role' and external_subject='s2t_fhir_importer';
  select rv.reference_value_id into strict baseline_type from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='BASELINE_TYPE' and rv.value_code='HUMAN_WORKING_DRAFT';
  select rv.reference_value_id into strict artifact_kind from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='ARTIFACT_KIND' and rv.value_code='WORKBOOK';
  select rv.reference_value_id into strict artifact_role from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='ARTIFACT_ROLE' and rv.value_code='AUTHORITATIVE_SOURCE';
  select rv.reference_value_id into strict import_policy from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='IMPORT_POLICY' and rv.value_code='CLEAN_IMPORT';
  select rv.reference_value_id into strict element_kind from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='MAPPING_KIND' and rv.value_code='ELEMENT_MAPPING';
  select rv.reference_value_id into strict accepted_disposition from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='CANDIDATE_DISPOSITION' and rv.value_code='ACCEPTED';
  select rv.reference_value_id into strict quarantined_disposition from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='CANDIDATE_DISPOSITION' and rv.value_code='QUARANTINED';
  select rv.reference_value_id into strict final_status from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='DECISION_STATUS' and rv.value_code='FINAL';
  select rv.reference_value_id into strict metric_candidate from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='METRIC_TYPE' and rv.value_code='CANDIDATE';
  select rv.reference_value_id into strict error_severity from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='SEVERITY' and rv.value_code='ERROR';
  select rv.reference_value_id into strict warning_severity from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='SEVERITY' and rv.value_code='WARNING';
  select rv.reference_value_id into strict validation_pass from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='VALIDATION_OUTCOME' and rv.value_code='PASS_WITH_WARNINGS';
  select rv.reference_value_id into strict validation_clean from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='VALIDATION_OUTCOME' and rv.value_code='PASS';
  select rv.reference_value_id into strict validation_fail from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='VALIDATION_OUTCOME' and rv.value_code='FAIL';
  select rv.reference_value_id into strict finding_subject from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='FINDING_ROW_ROLE' and rv.value_code='SUBJECT';
  select rv.reference_value_id into strict quarantine_opened from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='QUARANTINE_EVENT_TYPE' and rv.value_code='OPENED';
  select rv.reference_value_id into strict gate_pending from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='RELEASE_GATE_OUTCOME' and rv.value_code='PENDING';
  select rv.reference_value_id into strict gate_passed from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='RELEASE_GATE_OUTCOME' and rv.value_code='PASSED';
  select rv.reference_value_id into strict requirement_passed from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='REQUIREMENT_OUTCOME' and rv.value_code='PASSED';
  select rv.reference_value_id into strict requirement_failed from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='REQUIREMENT_OUTCOME' and rv.value_code='FAILED';
  select rv.reference_value_id into strict lifecycle_active from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='BASELINE_LIFECYCLE_STATUS' and rv.value_code='ACTIVE';
  select rd.reference_domain_id into strict severity_reference_domain_id from s2t_fhir.reference_domain rd where rd.domain_code='SEVERITY';
  select validation_ruleset_id into strict ruleset_id from s2t_fhir.validation_ruleset where ruleset_code='BASELINE_IMPORT' and version_label='v1';
  select validation_rule_id into strict warning_rule_id from s2t_fhir.validation_rule where validation_ruleset_id=ruleset_id and rule_code='APPROVED_CARDINALITY_EXCEPTION';
  select validation_rule_id into strict error_rule_id from s2t_fhir.validation_rule where validation_ruleset_id=ruleset_id and rule_code='DUPLICATE_SOURCE_ROW';
  select release_gate_definition_id into strict gate_id from s2t_fhir.release_gate_definition where gate_code='BASELINE_IMPORT' and version_label='v1';
  select release_gate_requirement_id into strict gate_requirement_id from s2t_fhir.release_gate_requirement where release_gate_definition_id=gate_id order by sequence_number limit 1;

  if (select array_agg(value_code order by value_code) from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id) where rd.domain_code='DECISION_STATUS') <> array['DO NOT MAP','FINAL','N/A','OPEN','WIP']::text[] then
    raise exception 'canonical decision-status bootstrap values are incorrect';
  end if;
  begin update s2t_fhir.reference_domain set display_name='forbidden' where domain_code='SEVERITY'; raise exception 'append-only UPDATE unexpectedly succeeded'; exception when sqlstate '55000' then null; end;
  begin delete from s2t_fhir.reference_domain where domain_code='SEVERITY'; raise exception 'append-only DELETE unexpectedly succeeded'; exception when sqlstate '55000' then null; end;
  if has_table_privilege('s2t_fhir_importer','s2t_fhir.reference_domain','TRUNCATE') then raise exception 'importer unexpectedly has TRUNCATE privilege'; end if;
  begin
    insert into s2t_fhir.reference_value(reference_domain_id,value_code,version_number,display_name,effective_at,is_bootstrap_seed,created_by_principal_id)
    values(severity_reference_domain_id,'ILLEGAL_BOOTSTRAP',99,'Illegal bootstrap',transaction_timestamp(),true,null);
    raise exception 'future creator-null bootstrap value unexpectedly succeeded';
  exception when sqlstate '23514' then null; end;

  insert into s2t_fhir.baseline_series(baseline_series_id,source_system,fhir_resource,baseline_type_value_id) values(baseline_series_id,'TEST_SOURCE','MedicationRequest',baseline_type);
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,created_by_principal_id) values(baseline_id,baseline_series_id,'TEST-BL-001','TEST-V1',false,'test-v1',service_principal);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,created_by_principal_id) values(artifact_id,artifact_kind,decode(repeat('aa',32),'hex'),1,'application/test','test.xlsx',transaction_timestamp(),service_principal);
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,created_by_principal_id) values(baseline_id,artifact_id,artifact_role,service_principal);
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,actor_principal_id) values(import_id,baseline_id,artifact_id,import_policy,'test-v1','test-importer',decode(repeat('ab',32),'hex'),transaction_timestamp(),service_principal);
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json)
  values(accepted_candidate_id,import_id,element_kind,'TEST',1,'A1:Q1','test-schema','1',jsonb_build_object('sheet','TEST','row',1,'range','A1:Q1','cells',jsonb_build_object()),decode(repeat('ac',32),'hex'),'v1','v1',accepted_disposition,'me:v1:'||repeat('a',64),jsonb_build_object('test','accepted'));
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) values(accepted_identity_id,element_kind,'TEST_SOURCE','MedicationRequest','v1','me:v1:'||repeat('a',64),jsonb_build_object('test','accepted'));
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) values(accepted_mapping_id,baseline_id,accepted_candidate_id,accepted_identity_id,element_kind,final_status);
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path) values(accepted_mapping_id,'MedicationRequest.test');
  insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id)
  values(accepted_validation_id,import_id,ruleset_id,artifact_id,decode(repeat('aa',32),'hex'),decode(repeat('ad',32),'hex'),transaction_timestamp(),transaction_timestamp(),1,1,1,0,0,validation_pass,service_principal);
  insert into s2t_fhir.validation_finding(validation_finding_id,validation_run_id,validation_rule_id,severity_value_id,finding_code,message,finding_fingerprint,evidence_schema_id,evidence_schema_version,evidence_json)
  values(accepted_warning_id,accepted_validation_id,warning_rule_id,warning_severity,'TEST_WARNING','Synthetic warning',decode(repeat('ae',32),'hex'),'test-evidence','1',jsonb_build_object('synthetic',true));
  insert into s2t_fhir.validation_finding_row(validation_finding_id,import_candidate_row_id,finding_row_role_value_id) values(accepted_warning_id,accepted_candidate_id,finding_subject);
  set constraints all immediate; set constraints all deferred;

  begin
    insert into s2t_fhir.validation_run(import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id)
    values(import_id,ruleset_id,artifact_id,decode(repeat('aa',32),'hex'),decode(repeat('a0',32),'hex'),transaction_timestamp(),transaction_timestamp(),1,1,1,0,0,validation_clean,service_principal)
    returning validation_run_id into test_validation_id;
    insert into s2t_fhir.validation_finding(validation_run_id,validation_rule_id,severity_value_id,finding_code,message,finding_fingerprint,evidence_schema_id,evidence_schema_version,evidence_json)
    values(test_validation_id,warning_rule_id,warning_severity,'TEST_WRONG_WARNING_OUTCOME','Synthetic warning with wrong outcome',decode(repeat('a4',32),'hex'),'test-evidence','1',jsonb_build_object('synthetic',true));
    set constraints all immediate; raise exception 'warning validation accepted a non-PASS_WITH_WARNINGS outcome';
  exception when check_violation then null; end;
  set constraints all deferred;

  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,actor_principal_id)
  values(clean_import_id,baseline_id,artifact_id,import_policy,'test-v1','test-importer',decode(repeat('a1',32),'hex'),transaction_timestamp() - interval '3 seconds',service_principal);
  begin
    insert into s2t_fhir.validation_run(import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id)
    values(clean_import_id,ruleset_id,artifact_id,decode(repeat('aa',32),'hex'),decode(repeat('a2',32),'hex'),transaction_timestamp() - interval '3 seconds',transaction_timestamp() - interval '3 seconds',0,0,0,0,0,validation_fail,service_principal);
    set constraints all immediate; raise exception 'zero-finding validation accepted a non-PASS outcome';
  exception when check_violation then null; end;
  set constraints all deferred;
  insert into s2t_fhir.validation_run(import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id)
  values(clean_import_id,ruleset_id,artifact_id,decode(repeat('aa',32),'hex'),decode(repeat('a3',32),'hex'),transaction_timestamp() - interval '3 seconds',transaction_timestamp() - interval '3 seconds',0,0,0,0,0,validation_clean,service_principal);
  set constraints all immediate; set constraints all deferred;

  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,actor_principal_id)
  values(subtype_import_id,baseline_id,artifact_id,import_policy,'test-v1','test-importer',decode(repeat('af',32),'hex'),transaction_timestamp(),service_principal);

  begin
    insert into s2t_fhir.import_candidate_row(import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json)
    values(subtype_import_id,element_kind,'TEST-S',9,'A9:Q9','test-schema','1',jsonb_build_object('sheet','TEST-S','row',10,'range','A9:Q9','cells',jsonb_build_object()),decode(repeat('b9',32),'hex'),'v1','v1',accepted_disposition,'me:v1:'||repeat('9',64),jsonb_build_object('test','bad-envelope'));
    raise exception 'raw evidence envelope mismatch unexpectedly succeeded';
  exception when check_violation then null; end;

  begin
    insert into s2t_fhir.import_candidate_row(import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json)
    values(subtype_import_id,element_kind,'TEST-S',1,'A1:Q1','test-schema','1',jsonb_build_object('sheet','TEST-S','row',1,'range','A1:Q1','cells',jsonb_build_object()),decode(repeat('ba',32),'hex'),'v1','v1',accepted_disposition,'me:v1:'||repeat('b',64),jsonb_build_object('test','missing-subtype'));
    insert into s2t_fhir.logical_mapping_identity(mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) values(element_kind,'TEST_SOURCE','MedicationRequest','v1','me:v1:'||repeat('b',64),jsonb_build_object('test','missing-subtype')) returning logical_mapping_identity_id into quarantine_identity_id;
    insert into s2t_fhir.mapping_record(baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select baseline_id,c.import_candidate_row_id,quarantine_identity_id,element_kind,final_status from s2t_fhir.import_candidate_row c where c.import_run_id=subtype_import_id and c.source_row_number=1;
    set constraints all immediate; raise exception 'mapping without subtype unexpectedly succeeded';
  exception when sqlstate '23514' then null; end;
  set constraints all deferred;
  if exists(select 1 from s2t_fhir.import_candidate_row where import_run_id=subtype_import_id) then raise exception 'failed subtype test did not roll back'; end if;

  begin
    insert into s2t_fhir.import_candidate_row(import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json)
    values(subtype_import_id,element_kind,'TEST-S',2,'A2:Q2','test-schema','1',jsonb_build_object('sheet','TEST-S','row',2,'range','A2:Q2','cells',jsonb_build_object()),decode(repeat('b2',32),'hex'),'v1','v1',accepted_disposition,'me:v1:'||repeat('2',64),jsonb_build_object('test','candidate-key'));
    insert into s2t_fhir.logical_mapping_identity(mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json)
    values(element_kind,'TEST_SOURCE','MedicationRequest','v1','me:v1:'||repeat('3',64),jsonb_build_object('test','identity-key')) returning logical_mapping_identity_id into quarantine_identity_id;
    insert into s2t_fhir.mapping_record(baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id)
    select baseline_id,c.import_candidate_row_id,quarantine_identity_id,element_kind,final_status from s2t_fhir.import_candidate_row c where c.import_run_id=subtype_import_id and c.source_row_number=2 returning mapping_record_id into mismatch_mapping_id;
    insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path) values(mismatch_mapping_id,'MedicationRequest.keyMismatch');
    set constraints all immediate; raise exception 'accepted logical-key mismatch unexpectedly succeeded';
  exception when check_violation then null; end;
  set constraints all deferred;
  if exists(select 1 from s2t_fhir.import_candidate_row where import_run_id=subtype_import_id) then raise exception 'failed logical-key test did not roll back'; end if;

  begin insert into s2t_fhir.logical_mapping_identity(mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) values(element_kind,'TEST_SOURCE','MedicationRequest','v1','me:v1:'||repeat('a',64),jsonb_build_object('test','accepted')); raise exception 'duplicate logical identity unexpectedly succeeded'; exception when unique_violation then null; end;

  begin
    insert into s2t_fhir.artifact as a(artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,created_by_principal_id) values(artifact_kind,decode(repeat('bb',32),'hex'),1,'application/test','second.xlsx',transaction_timestamp(),service_principal) returning a.artifact_id into second_artifact_id;
    insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,created_by_principal_id) values(baseline_id,second_artifact_id,artifact_role,service_principal);
    set constraints all immediate; raise exception 'second authoritative artifact unexpectedly succeeded';
  exception when unique_violation then null; end;
  set constraints all deferred;

  begin insert into s2t_fhir.quarantine_case(import_candidate_row_id,opening_validation_finding_id,opened_at,opened_by_principal_id) values(accepted_candidate_id,accepted_warning_id,transaction_timestamp(),service_principal); set constraints all immediate; raise exception 'accepted candidate entered quarantine'; exception when sqlstate '23514' then null; end;
  set constraints all deferred;

  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,actor_principal_id) values(quarantine_import_id,baseline_id,artifact_id,import_policy,'test-v1','test-importer',decode(repeat('bc',32),'hex'),transaction_timestamp(),service_principal);
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json)
  values(quarantined_candidate_id,quarantine_import_id,element_kind,'TEST-Q',1,'A1:Q1','test-schema','1',jsonb_build_object('sheet','TEST-Q','row',1,'range','A1:Q1','cells',jsonb_build_object()),decode(repeat('bd',32),'hex'),'v1','v1',quarantined_disposition,'me:v1:'||repeat('c',64),jsonb_build_object('test','quarantine'));
  insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id)
  values(quarantined_validation_id,quarantine_import_id,ruleset_id,artifact_id,decode(repeat('aa',32),'hex'),decode(repeat('be',32),'hex'),transaction_timestamp() - interval '1 second',transaction_timestamp() - interval '1 second',1,0,0,1,1,validation_fail,service_principal);
  insert into s2t_fhir.validation_finding(validation_finding_id,validation_run_id,validation_rule_id,severity_value_id,finding_code,message,finding_fingerprint,evidence_schema_id,evidence_schema_version,evidence_json)
  values(quarantine_finding_id,quarantined_validation_id,error_rule_id,error_severity,'TEST_ERROR','Synthetic error',decode(repeat('bf',32),'hex'),'test-evidence','1',jsonb_build_object('synthetic',true));
  insert into s2t_fhir.validation_finding_row(validation_finding_id,import_candidate_row_id,finding_row_role_value_id) values(quarantine_finding_id,quarantined_candidate_id,finding_subject);
  insert into s2t_fhir.quarantine_case(quarantine_case_id,import_candidate_row_id,opening_validation_finding_id,opened_at,opened_by_principal_id) values(quarantine_case_id,quarantined_candidate_id,quarantine_finding_id,transaction_timestamp(),service_principal);
  insert into s2t_fhir.quarantine_event(quarantine_case_id,event_type_value_id,occurred_at,actor_principal_id) values(quarantine_case_id,quarantine_opened,transaction_timestamp(),service_principal);
  set constraints all immediate; set constraints all deferred;

  begin
    insert into s2t_fhir.validation_run(import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id)
    values(quarantine_import_id,ruleset_id,artifact_id,decode(repeat('aa',32),'hex'),decode(repeat('c0',32),'hex'),transaction_timestamp(),transaction_timestamp(),1,0,0,1,1,validation_pass,service_principal)
    returning validation_run_id into test_validation_id;
    insert into s2t_fhir.validation_finding(validation_run_id,validation_rule_id,severity_value_id,finding_code,message,finding_fingerprint,evidence_schema_id,evidence_schema_version,evidence_json)
    values(test_validation_id,error_rule_id,error_severity,'TEST_WRONG_ERROR_OUTCOME','Synthetic error with wrong outcome',decode(repeat('c1',32),'hex'),'test-evidence','1',jsonb_build_object('synthetic',true));
    set constraints all immediate; raise exception 'error validation accepted a non-FAIL outcome';
  exception when check_violation then null; end;
  set constraints all deferred;

  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) values(quarantine_identity_id,element_kind,'TEST_SOURCE','MedicationRequest','v1','me:v1:'||repeat('c',64),jsonb_build_object('test','quarantine'));
  begin
    insert into s2t_fhir.mapping_record(baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) values(baseline_id,quarantined_candidate_id,quarantine_identity_id,element_kind,final_status);
    insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path) select mapping_record_id,'MedicationRequest.test' from s2t_fhir.mapping_record where import_candidate_row_id=quarantined_candidate_id;
    set constraints all immediate; raise exception 'quarantined candidate accepted a mapping';
  exception when sqlstate '23514' then null; end;
  set constraints all deferred;

  insert into s2t_fhir.import_run_metric(import_run_id,metric_type_value_id,metric_count) values(import_id,metric_candidate,1);
  begin insert into s2t_fhir.import_run_metric(import_run_id,metric_type_value_id,metric_count) values(import_id,metric_candidate,1); raise exception 'null-safe uniqueness allowed duplicate'; exception when unique_violation then null; end;

  begin
    insert into s2t_fhir.validation_run(import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id)
    values(import_id,ruleset_id,artifact_id,decode(repeat('aa',32),'hex'),decode(repeat('ca',32),'hex'),transaction_timestamp(),transaction_timestamp(),99,1,1,0,0,validation_fail,service_principal);
    set constraints all immediate; raise exception 'validation count mismatch unexpectedly succeeded';
  exception when sqlstate '23514' then null; end;
  set constraints all deferred;

  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,created_by_principal_id) values(second_artifact_id,artifact_kind,decode(repeat('cc',32),'hex'),1,'application/test','non-authoritative.xlsx',transaction_timestamp(),service_principal);
  begin
    insert into s2t_fhir.release_gate_evaluation(baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id)
    values(baseline_id,gate_id,second_artifact_id,decode(repeat('cc',32),'hex'),ruleset_id,accepted_validation_id,gate_pending,transaction_timestamp(),service_principal);
    set constraints all immediate; raise exception 'release mismatch unexpectedly succeeded';
  exception when sqlstate '23514' then null; end;
  set constraints all deferred;

  insert into s2t_fhir.validation_ruleset(validation_ruleset_id,ruleset_code,version_label,ruleset_digest,implementation_version,created_by_principal_id)
  values(alternate_ruleset_id,'TEST_ALTERNATE','v1',decode(repeat('cd',32),'hex'),'test-v1',service_principal);
  begin
    insert into s2t_fhir.release_gate_evaluation(baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id)
    values(baseline_id,gate_id,artifact_id,decode(repeat('aa',32),'hex'),alternate_ruleset_id,accepted_validation_id,gate_pending,transaction_timestamp(),service_principal);
    set constraints all immediate; raise exception 'release ruleset mismatch unexpectedly succeeded';
  exception when check_violation then null; end;
  set constraints all deferred;

  begin
    insert into s2t_fhir.baseline_lifecycle_event(baseline_version_id,lifecycle_status_value_id,occurred_at,actor_principal_id)
    values(baseline_id,lifecycle_active,transaction_timestamp(),service_principal);
    set constraints all immediate; raise exception 'baseline became ACTIVE without a current passed release gate';
  exception when check_violation then null; end;
  set constraints all deferred;

  begin
    insert into s2t_fhir.release_gate_evaluation(baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id)
    values(baseline_id,gate_id,artifact_id,decode(repeat('aa',32),'hex'),ruleset_id,accepted_validation_id,gate_passed,transaction_timestamp(),service_principal);
    set constraints all immediate; raise exception 'passed release gate accepted missing requirement results';
  exception when check_violation then null; end;
  set constraints all deferred;

  begin
    insert into s2t_fhir.release_gate_evaluation(baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id)
    values(baseline_id,gate_id,artifact_id,decode(repeat('aa',32),'hex'),ruleset_id,accepted_validation_id,gate_passed,transaction_timestamp(),service_principal)
    returning release_gate_evaluation_id into passed_evaluation_id;
    insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id)
    select passed_evaluation_id, requirement.release_gate_requirement_id,
           case when requirement.is_blocking and requirement.sequence_number = (
             select min(blocking.sequence_number) from s2t_fhir.release_gate_requirement blocking
             where blocking.release_gate_definition_id = gate_id and blocking.is_blocking
           ) then requirement_failed else requirement_passed end
    from s2t_fhir.release_gate_requirement requirement
    where requirement.release_gate_definition_id = gate_id;
    set constraints all immediate; raise exception 'passed release gate accepted a failed blocking requirement';
  exception when check_violation then null; end;
  set constraints all deferred;

  passed_evaluation_id := gen_random_uuid();
  insert into s2t_fhir.release_gate_evaluation(release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id)
  values(passed_evaluation_id,baseline_id,gate_id,artifact_id,decode(repeat('aa',32),'hex'),ruleset_id,accepted_validation_id,gate_passed,transaction_timestamp(),service_principal);
  insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id)
  select passed_evaluation_id,release_gate_requirement_id,requirement_passed
  from s2t_fhir.release_gate_requirement where release_gate_definition_id=gate_id;
  set constraints all immediate; set constraints all deferred;

  insert into s2t_fhir.baseline_lifecycle_event(baseline_version_id,lifecycle_status_value_id,occurred_at,actor_principal_id)
  values(baseline_id,lifecycle_active,transaction_timestamp(),service_principal);
  set constraints all immediate; set constraints all deferred;

  if not exists(select 1 from s2t_fhir.release_gate_requirement where release_gate_requirement_id=gate_requirement_id) or requirement_passed is null then raise exception 'configuration bootstrap is incomplete'; end if;
end
$test$;

reset role;
rollback;

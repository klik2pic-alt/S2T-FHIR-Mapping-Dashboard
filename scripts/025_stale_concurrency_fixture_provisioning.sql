-- Migration 025 dedicated stale-read concurrency fixture provisioning package.
-- DESIGN ONLY: DO NOT RUN until separately approved for S2T-FHIR-DDL-Test.
-- Execute with direct PostgreSQL/psql, never Supabase SQL Editor tabs.
--
-- Immutable retained fixture ID: T025-STALE-20261016-R1
-- HISTORICAL SOURCE: DO NOT execute this file end-to-end in one backend.
-- TEST has the exact committed SP01+SP02 prefix. Resume only with:
--   025_stale_concurrency_resume_sp03.sql      (fresh psql backend)
--   025_stale_concurrency_resume_sp04.sql      (another fresh psql backend)
--   025_stale_concurrency_resume_sp05_sp11.sql (another fresh psql backend)
-- The fresh SP03/SP04 boundaries are required because the transaction-local
-- s2t_fhir.finalizing_baseline custom GUC leaves a backend-scoped placeholder.
-- This fixture is append-only TEST evidence. There is intentionally no cleanup.
-- The original start-at-SP00 instructions below are retained for provenance and
-- are superseded by the three resume scripts for the live R1 fixture.
-- Run SP00 first. Run SP01-SP11 in order, stopping on any error. Each checkpoint
-- is fail-closed if its prerequisite is missing or its own state already exists.
-- If interrupted, run 025_stale_concurrency_fixture_verification.sql and resume
-- only at the first absent checkpoint; never repair retained rows in place.

-- SP00 (READ ONLY) - dependencies and collision guard.
do $sp00$
declare v_count integer;
begin
  if pg_catalog.to_regprocedure('s2t_fhir.grant_baseline_action(uuid,text,uuid)') is null
     or pg_catalog.to_regprocedure('s2t_fhir.grant_review_write(uuid,uuid)') is null
     or pg_catalog.to_regprocedure('s2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)') is null
     or pg_catalog.to_regprocedure('s2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)') is null
     or pg_catalog.to_regprocedure('s2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)') is null
     or pg_catalog.to_regprocedure('s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)') is null
     or pg_catalog.to_regprocedure('s2t_fhir_api.end_authenticated_candidate_review_session(uuid,uuid,uuid)') is null then
    raise exception 'SP00: required workflow routines are missing' using errcode='55000';
  end if;

  select count(*) into v_count from s2t_fhir.principal
  where external_issuer='postgres-role' and external_subject='s2t_fhir_importer' and disabled_at is null;
  if v_count <> 1 then
    raise exception 'SP00: expected one active importer principal; found %',v_count using errcode='55000';
  end if;

  if (select count(*) from s2t_fhir.validation_ruleset where ruleset_code='BASELINE_IMPORT' and version_label='v1') <> 1
     or (select count(*) from s2t_fhir.release_gate_definition where gate_code='BASELINE_IMPORT' and version_label='v1') <> 1 then
    raise exception 'SP00: BASELINE_IMPORT/v1 validation or gate configuration is not exact' using errcode='55000';
  end if;

  if exists (select 1 from s2t_fhir.principal where principal_id in
      ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001')
      or (external_issuer='supabase-auth' and external_subject in
      ('0255a001-0000-4000-8000-000000000001','0255b001-0000-4000-8000-000000000001')))
     or exists (select 1 from s2t_fhir.baseline_series where baseline_series_id='02550000-0000-4000-8000-000000000001'
      or (source_system='T025-STALE-20261016-R1' and fhir_resource='MedicationRequest'))
     or exists (select 1 from s2t_fhir.mapping_resource_registry where resource_config_id='t025-stale-20261016-r1-resource')
     or exists (select 1 from s2t_fhir.baseline_version where baseline_version_id in
      ('02550101-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001')
      or baseline_code like 'T025-STALE-20261016-R1-%')
     or exists (select 1 from s2t_fhir.artifact where artifact_id in
      ('02550102-0000-4000-8000-000000000001','02550202-0000-4000-8000-000000000001','02550302-0000-4000-8000-000000000001'))
     or exists (select 1 from s2t_fhir.import_run where import_run_id in
      ('02550103-0000-4000-8000-000000000001','02550203-0000-4000-8000-000000000001','02550303-0000-4000-8000-000000000001'))
     or exists (select 1 from s2t_fhir.review_session where session_name like 'T025-STALE-20261016-R1-%') then
    raise exception 'SP00: dedicated fixture is already or partially present; run the verifier and do not restart at SP01' using errcode='55000';
  end if;
end $sp00$;
select 'SP00' checkpoint,'NEW_FIXTURE' state,'T025-STALE-20261016-R1' fixture_id;

-- SP01 - isolated principals, series, registry, and least-required capabilities.
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $sp01$
begin
  if exists(select 1 from s2t_fhir.principal where principal_id in ('0255a000-0000-4000-8000-000000000001','0255b000-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.baseline_series where baseline_series_id='02550000-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.mapping_resource_registry where resource_config_id='t025-stale-20261016-r1-resource') then
    raise exception 'SP01: infrastructure already or partially exists' using errcode='55000';
  end if;
end $sp01$;
insert into s2t_fhir.principal(principal_id,principal_kind_value_id,external_issuer,external_subject,display_name)
select x.principal_id,k.reference_value_id,'supabase-auth',x.auth_subject,x.display_name
from (values
 ('0255a000-0000-4000-8000-000000000001'::uuid,'0255a001-0000-4000-8000-000000000001','T025-STALE-20261016-R1-SESSION-A'),
 ('0255b000-0000-4000-8000-000000000001'::uuid,'0255b001-0000-4000-8000-000000000001','T025-STALE-20261016-R1-SESSION-B')
) x(principal_id,auth_subject,display_name)
cross join lateral (select v.reference_value_id from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='PRINCIPAL_KIND' and v.value_code='HUMAN' and v.effective_at<=transaction_timestamp() and (v.retired_at is null or v.retired_at>transaction_timestamp())) k;
insert into s2t_fhir.baseline_series(baseline_series_id,source_system,fhir_resource,baseline_type_value_id,description)
select '02550000-0000-4000-8000-000000000001','T025-STALE-20261016-R1','MedicationRequest',v.reference_value_id,'Migration 025 retained stale-read fixture'
from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id)
where d.domain_code='BASELINE_TYPE' and v.value_code='HUMAN_WORKING_DRAFT';
insert into s2t_fhir.mapping_resource_registry(resource_config_id,source_system,fhir_resource,is_enabled)
values('t025-stale-20261016-r1-resource','T025-STALE-20261016-R1','MedicationRequest',true);
select s2t_fhir.grant_baseline_action(p,'S2T_BASELINE_UPLOAD',a.admin_id)
from (values('0255a000-0000-4000-8000-000000000001'::uuid),('0255b000-0000-4000-8000-000000000001'::uuid)) w(p)
cross join lateral(select principal_id admin_id from s2t_fhir.principal where external_issuer='postgres-role' and external_subject='s2t_fhir_importer' and disabled_at is null) a;
select s2t_fhir.grant_baseline_action(p,'S2T_BASELINE_PROMOTE',a.admin_id)
from (values('0255a000-0000-4000-8000-000000000001'::uuid),('0255b000-0000-4000-8000-000000000001'::uuid)) w(p)
cross join lateral(select principal_id admin_id from s2t_fhir.principal where external_issuer='postgres-role' and external_subject='s2t_fhir_importer' and disabled_at is null) a;
select s2t_fhir.grant_review_write('0255a000-0000-4000-8000-000000000001',principal_id)
from s2t_fhir.principal where external_issuer='postgres-role' and external_subject='s2t_fhir_importer' and disabled_at is null;
commit;
select 'SP01' checkpoint,'COMPLETE' state;

-- SP02/SP03 - mapped, finalized V1 and V2. Each transaction finalizes one import.
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $sp02$
declare
 v_b constant uuid:='02550101-0000-4000-8000-000000000001'; v_a constant uuid:='02550102-0000-4000-8000-000000000001';
 v_i constant uuid:='02550103-0000-4000-8000-000000000001'; v_mf constant uuid:='02550104-0000-4000-8000-000000000001';
 v_row constant uuid:='02550105-0000-4000-8000-000000000001'; v_li constant uuid:='02550106-0000-4000-8000-000000000001';
 v_m constant uuid:='02550107-0000-4000-8000-000000000001'; v_hash text:=md5('T025-STALE-20261016-R1-V1-node-1')||md5('T025-STALE-20261016-R1-V1-node-2');
begin
 if not exists(select 1 from s2t_fhir.baseline_series where baseline_series_id='02550000-0000-4000-8000-000000000001')
    or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_b)
    or exists(select 1 from s2t_fhir.artifact where artifact_id=v_a)
    or exists(select 1 from s2t_fhir.import_run where import_run_id=v_i) then raise exception 'SP02: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
 insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_b,'02550000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V1','T025-STALE-20261016-R1-V1',false,'T025-STALE-20261016-R1-v1','Dedicated stale fixture ACTIVE seed','0255a000-0000-4000-8000-000000000001');
 insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_a,v.reference_value_id,decode(md5('T025-STALE-20261016-R1-V1-a1')||md5('T025-STALE-20261016-R1-V1-a2'),'hex'),1,'application/test','T025-STALE-20261016-R1-V1.xlsx',transaction_timestamp(),'T025 stale V1 artifact','0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
 insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_b,v_a,v.reference_value_id,'T025 stale V1 authoritative','0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
 insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_mf,v_a,'T025-STALE-V1-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T025 stale V1 manifest','T025-STALE-manifest','1',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
 insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_i,v_b,v_a,p.reference_value_id,'T025-STALE-20261016-R1-v1','T025-STALE-20261016-R1-importer',decode(md5('T025-STALE-20261016-R1-V1-c1')||md5('T025-STALE-20261016-R1-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,'0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
 insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_i,mk.reference_value_id,'T025-STALE-V1-SHEET',2,'A2:Q2','T025-STALE-raw','1',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1'),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
 insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_li,v.reference_value_id,'T025-STALE-20261016-R1','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
 insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_m,v_b,v_row,v_li,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
 insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_m,'MedicationRequest.status','T025-STALE-20261016-R1','T025-STALE-20261016-R1.V1.source','LOCAL','T025 stale V1 mapping');
end $sp02$;
commit;
select 'SP02' checkpoint,'COMPLETE' state,'02550101-0000-4000-8000-000000000001'::uuid baseline_version_id;

begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $sp03$
declare
 v_b constant uuid:='02550201-0000-4000-8000-000000000001'; v_a constant uuid:='02550202-0000-4000-8000-000000000001';
 v_i constant uuid:='02550203-0000-4000-8000-000000000001'; v_mf constant uuid:='02550204-0000-4000-8000-000000000001';
 v_row constant uuid:='02550205-0000-4000-8000-000000000001'; v_li constant uuid:='02550206-0000-4000-8000-000000000001';
 v_m constant uuid:='02550207-0000-4000-8000-000000000001'; v_hash text:=md5('T025-STALE-20261016-R1-V2-node-1')||md5('T025-STALE-20261016-R1-V2-node-2');
begin
 if not exists(select 1 from s2t_fhir.import_run where import_run_id='02550103-0000-4000-8000-000000000001')
    or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_b)
    or exists(select 1 from s2t_fhir.artifact where artifact_id=v_a)
    or exists(select 1 from s2t_fhir.import_run where import_run_id=v_i) then raise exception 'SP03: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
 insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_b,'02550000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V2','T025-STALE-20261016-R1-V2',false,'T025-STALE-20261016-R1-v1','Dedicated stale fixture promotion-ready Candidate','0255a000-0000-4000-8000-000000000001');
 insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_a,v.reference_value_id,decode(md5('T025-STALE-20261016-R1-V2-a1')||md5('T025-STALE-20261016-R1-V2-a2'),'hex'),1,'application/test','T025-STALE-20261016-R1-V2.xlsx',transaction_timestamp(),'T025 stale V2 artifact','0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
 insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_b,v_a,v.reference_value_id,'T025 stale V2 authoritative','0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
 insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_mf,v_a,'T025-STALE-V2-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T025 stale V2 manifest','T025-STALE-manifest','1',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
 insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_i,v_b,v_a,p.reference_value_id,'T025-STALE-20261016-R1-v1','T025-STALE-20261016-R1-importer',decode(md5('T025-STALE-20261016-R1-V2-c1')||md5('T025-STALE-20261016-R1-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,'0255a000-0000-4000-8000-000000000001' from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
 insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_i,mk.reference_value_id,'T025-STALE-V2-SHEET',2,'A2:Q2','T025-STALE-raw','1',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2'),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
 insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_li,v.reference_value_id,'T025-STALE-20261016-R1','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
 insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_m,v_b,v_row,v_li,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
 insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_m,'MedicationRequest.status','T025-STALE-20261016-R1','T025-STALE-20261016-R1.V2.source','LOCAL','T025 stale V2 mapping');
end $sp03$;
commit;
select 'SP03' checkpoint,'COMPLETE' state,'02550201-0000-4000-8000-000000000001'::uuid baseline_version_id;

-- SP04 - finalized but unpublished V3 replacement (intentionally no mappings).
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $sp04$
begin
 if not exists(select 1 from s2t_fhir.import_run where import_run_id='02550203-0000-4000-8000-000000000001')
    or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id='02550301-0000-4000-8000-000000000001')
    or exists(select 1 from s2t_fhir.artifact where artifact_id='02550302-0000-4000-8000-000000000001')
    or exists(select 1 from s2t_fhir.import_run where import_run_id='02550303-0000-4000-8000-000000000001') then raise exception 'SP04: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
 insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values('02550301-0000-4000-8000-000000000001','02550000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V3','T025-STALE-20261016-R1-V3',false,'T025-STALE-20261016-R1-v1','Dedicated stale fixture unpublished replacement','0255b000-0000-4000-8000-000000000001');
 insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select '02550302-0000-4000-8000-000000000001',v.reference_value_id,decode(md5('T025-STALE-20261016-R1-V3-a1')||md5('T025-STALE-20261016-R1-V3-a2'),'hex'),1,'application/test','T025-STALE-20261016-R1-V3.xlsx',transaction_timestamp(),'T025 stale V3 artifact','0255b000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
 insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select '02550301-0000-4000-8000-000000000001','02550302-0000-4000-8000-000000000001',v.reference_value_id,'T025 stale V3 authoritative','0255b000-0000-4000-8000-000000000001' from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
 insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select '02550303-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001','02550302-0000-4000-8000-000000000001',p.reference_value_id,'T025-STALE-20261016-R1-v1','T025-STALE-20261016-R1-importer',decode(md5('T025-STALE-20261016-R1-V3-c1')||md5('T025-STALE-20261016-R1-V3-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,'0255b000-0000-4000-8000-000000000001' from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $sp04$;
commit;
select 'SP04' checkpoint,'COMPLETE' state,'02550301-0000-4000-8000-000000000001'::uuid baseline_version_id;

-- SP05 - publish V1 Candidate through the authenticated API.
begin;
do $sp05_guard$ begin if not exists(select 1 from s2t_fhir.import_run where import_run_id='02550303-0000-4000-8000-000000000001') or exists(select 1 from s2t_fhir.baseline_lifecycle_event where baseline_version_id='02550101-0000-4000-8000-000000000001') then raise exception 'SP05: prerequisite missing or lifecycle already present' using errcode='55000'; end if; end $sp05_guard$;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('02550101-0000-4000-8000-000000000001','02550103-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'SP05' checkpoint,'COMPLETE' state;

-- SP06 - complete V1 review through the governed authenticated workflow.
begin;
create temp table pg_temp.sp06_context(baseline_version_id uuid primary key,candidate_lifecycle_event_id uuid not null,review_session_id uuid) on commit drop;
insert into pg_temp.sp06_context(baseline_version_id,candidate_lifecycle_event_id)
select baseline_version_id,candidate_lifecycle_event_id from s2t_fhir.baseline_candidate_context where baseline_version_id='02550101-0000-4000-8000-000000000001';
do $sp06_guard$ begin if (select count(*) from pg_temp.sp06_context)<>1 or exists(select 1 from s2t_fhir.review_session where session_name='T025-STALE-20261016-R1-V1-REVIEW') then raise exception 'SP06: Candidate context missing/ambiguous or review already exists' using errcode='55000'; end if; end $sp06_guard$;
grant select,update(review_session_id) on pg_temp.sp06_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
update pg_temp.sp06_context set review_session_id=s2t_fhir_api.start_authenticated_candidate_review_session(baseline_version_id,candidate_lifecycle_event_id,'T025-STALE-20261016-R1-V1-REVIEW','Complete retained fixture V1 review');
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed('02550101-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp06_context),'map-v1-'||md5('T025-STALE-20261016-R1-V1-node-1')||md5('T025-STALE-20261016-R1-V1-node-2'),(select review_session_id from pg_temp.sp06_context),'T025 stale V1 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session('02550101-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp06_context),(select review_session_id from pg_temp.sp06_context));
reset role;
commit;
select 'SP06' checkpoint,'COMPLETE' state;

-- SP07 - passing V1 validation and gate evidence.
begin;
set local role s2t_fhir_owner;
do $sp07_guard$ begin if not exists(select 1 from s2t_fhir.review_session where session_name='T025-STALE-20261016-R1-V1-REVIEW' and ended_at is not null) or exists(select 1 from s2t_fhir.validation_run where validation_run_id='02550108-0000-4000-8000-000000000001') or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550109-0000-4000-8000-000000000001') then raise exception 'SP07: prerequisite missing or evidence already/partially exists' using errcode='55000'; end if; end $sp07_guard$;
insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '02550108-0000-4000-8000-000000000001','02550103-0000-4000-8000-000000000001',r.validation_ruleset_id,'02550102-0000-4000-8000-000000000001',a.sha256_digest,decode(md5('T025-STALE-20261016-R1-V1-validation-1')||md5('T025-STALE-20261016-R1-V1-validation-2'),'hex'),transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,o.reference_value_id,'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1') from s2t_fhir.validation_ruleset r join s2t_fhir.artifact a on a.artifact_id='02550102-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASS' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='VALIDATION_OUTCOME' where r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1';
insert into s2t_fhir.release_gate_evaluation(release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,initiating_human_principal_id,summary)
select '02550109-0000-4000-8000-000000000001','02550101-0000-4000-8000-000000000001',g.release_gate_definition_id,'02550102-0000-4000-8000-000000000001',a.sha256_digest,r.validation_ruleset_id,'02550108-0000-4000-8000-000000000001',o.reference_value_id,transaction_timestamp(),'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V1 PASSED' from s2t_fhir.release_gate_definition g join s2t_fhir.validation_ruleset r on r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1' join s2t_fhir.artifact a on a.artifact_id='02550102-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '02550109-0000-4000-8000-000000000001',req.release_gate_requirement_id,o.reference_value_id,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1','requirement',req.requirement_code),'T025 stale V1 '||req.requirement_code from s2t_fhir.release_gate_requirement req join s2t_fhir.release_gate_definition g using(release_gate_definition_id) join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
commit;
select 'SP07' checkpoint,'COMPLETE' state;

-- SP08 - promote V1 to ACTIVE through the authenticated API.
begin;
create temp table pg_temp.sp08_context(candidate_lifecycle_event_id uuid not null) on commit drop;
insert into pg_temp.sp08_context select candidate_lifecycle_event_id from s2t_fhir.baseline_candidate_context where baseline_version_id='02550101-0000-4000-8000-000000000001';
do $sp08_guard$ begin if (select count(*) from pg_temp.sp08_context)<>1 or not exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550109-0000-4000-8000-000000000001') or exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='02550101-0000-4000-8000-000000000001') then raise exception 'SP08: prerequisite missing/ambiguous or activation exists' using errcode='55000'; end if; end $sp08_guard$;
grant select on pg_temp.sp08_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
select s2t_fhir_api.promote_candidate_baseline('02550101-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp08_context),'02550103-0000-4000-8000-000000000001','02550109-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'SP08' checkpoint,'COMPLETE' state;

-- SP09 - publish V2 as the promotion-ready Candidate.
begin;
do $sp09_guard$ begin if not exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='02550101-0000-4000-8000-000000000001') or exists(select 1 from s2t_fhir.baseline_lifecycle_event where baseline_version_id='02550201-0000-4000-8000-000000000001') then raise exception 'SP09: ACTIVE prerequisite missing or V2 lifecycle exists' using errcode='55000'; end if; end $sp09_guard$;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('02550201-0000-4000-8000-000000000001','02550203-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'SP09' checkpoint,'COMPLETE' state;

-- SP10 - complete V2 review through the governed authenticated workflow.
begin;
create temp table pg_temp.sp10_context(baseline_version_id uuid primary key,candidate_lifecycle_event_id uuid not null,review_session_id uuid) on commit drop;
insert into pg_temp.sp10_context(baseline_version_id,candidate_lifecycle_event_id) select baseline_version_id,candidate_lifecycle_event_id from s2t_fhir.baseline_candidate_context where baseline_version_id='02550201-0000-4000-8000-000000000001';
do $sp10_guard$ begin if (select count(*) from pg_temp.sp10_context)<>1 or exists(select 1 from s2t_fhir.review_session where session_name='T025-STALE-20261016-R1-V2-REVIEW') then raise exception 'SP10: Candidate context missing/ambiguous or review exists' using errcode='55000'; end if; end $sp10_guard$;
grant select,update(review_session_id) on pg_temp.sp10_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
update pg_temp.sp10_context set review_session_id=s2t_fhir_api.start_authenticated_candidate_review_session(baseline_version_id,candidate_lifecycle_event_id,'T025-STALE-20261016-R1-V2-REVIEW','Complete retained fixture V2 review');
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed('02550201-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp10_context),'map-v1-'||md5('T025-STALE-20261016-R1-V2-node-1')||md5('T025-STALE-20261016-R1-V2-node-2'),(select review_session_id from pg_temp.sp10_context),'T025 stale V2 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session('02550201-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp10_context),(select review_session_id from pg_temp.sp10_context));
reset role;
commit;
select 'SP10' checkpoint,'COMPLETE' state;

-- SP11 - passing V2 validation/gate evidence; this is the ready A1 state.
begin;
set local role s2t_fhir_owner;
do $sp11_guard$ begin if not exists(select 1 from s2t_fhir.review_session where session_name='T025-STALE-20261016-R1-V2-REVIEW' and ended_at is not null) or exists(select 1 from s2t_fhir.validation_run where validation_run_id='02550208-0000-4000-8000-000000000001') or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550209-0000-4000-8000-000000000001') then raise exception 'SP11: prerequisite missing or evidence already/partially exists' using errcode='55000'; end if; end $sp11_guard$;
insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '02550208-0000-4000-8000-000000000001','02550203-0000-4000-8000-000000000001',r.validation_ruleset_id,'02550202-0000-4000-8000-000000000001',a.sha256_digest,decode(md5('T025-STALE-20261016-R1-V2-validation-1')||md5('T025-STALE-20261016-R1-V2-validation-2'),'hex'),transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,o.reference_value_id,'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.validation_ruleset r join s2t_fhir.artifact a on a.artifact_id='02550202-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASS' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='VALIDATION_OUTCOME' where r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1';
insert into s2t_fhir.release_gate_evaluation(release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,initiating_human_principal_id,summary)
select '02550209-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001',g.release_gate_definition_id,'02550202-0000-4000-8000-000000000001',a.sha256_digest,r.validation_ruleset_id,'02550208-0000-4000-8000-000000000001',o.reference_value_id,transaction_timestamp(),'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V2 PASSED' from s2t_fhir.release_gate_definition g join s2t_fhir.validation_ruleset r on r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1' join s2t_fhir.artifact a on a.artifact_id='02550202-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '02550209-0000-4000-8000-000000000001',req.release_gate_requirement_id,o.reference_value_id,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2','requirement',req.requirement_code),'T025 stale V2 '||req.requirement_code from s2t_fhir.release_gate_requirement req join s2t_fhir.release_gate_definition g using(release_gate_definition_id) join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
commit;
select 'SP11' checkpoint,'COMPLETE_READY_FOR_A1' state,'T025-STALE-20261016-R1' fixture_id;

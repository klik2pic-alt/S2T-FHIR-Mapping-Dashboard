-- Migration 023 concurrency fixture verification package.
-- READ ONLY. This file contains SELECT statements only.
-- Immutable fixture pack ID: T023-CONC-PACK-20261009-R1
--
-- Run after any provisioning checkpoint and before every concurrency run.
-- Retain every result grid with the fixture evidence. Any FAIL,
-- PARTIAL_OR_AMBIGUOUS, or NONCONTIGUOUS result is a stop condition.

-- ---------------------------------------------------------------------------
-- V00 - immutable pack identity and required Migration 023 dependencies
-- ---------------------------------------------------------------------------
select
  'V00_PACK_IDENTITY' as verification,
  'T023-CONC-PACK-20261009-R1' as fixture_pack_id,
  case when
    pg_catalog.to_regprocedure('s2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)') is not null
    and pg_catalog.to_regprocedure('s2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)') is not null
    and pg_catalog.to_regprocedure('s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)') is not null
    and pg_catalog.to_regprocedure('s2t_fhir_api.gov_link_candidate_mapping(uuid,uuid,uuid,jsonb,timestamptz)') is not null
    and pg_catalog.to_regprocedure('s2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)') is not null
  then 'PASS' else 'FAIL' end as result;

-- ---------------------------------------------------------------------------
-- V01 - exact CP02-CP19 finalization checkpoint state
-- Each row represents exactly one baseline/import finalization transaction.
-- ---------------------------------------------------------------------------
with expected(checkpoint,case_id,series_id,baseline_id,baseline_code,artifact_id,import_id) as (
  values
    ('CP02','C01','023c0100-0000-4000-8000-000000000001'::uuid,'023c0101-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C01-A','023c0102-0000-4000-8000-000000000001'::uuid,'023c0103-0000-4000-8000-000000000001'::uuid),
    ('CP03','C01','023c0100-0000-4000-8000-000000000001'::uuid,'023c0111-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C01-B','023c0112-0000-4000-8000-000000000001'::uuid,'023c0113-0000-4000-8000-000000000001'::uuid),
    ('CP04','C02','023c0200-0000-4000-8000-000000000002'::uuid,'023c0201-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C02-V1','023c0202-0000-4000-8000-000000000001'::uuid,'023c0203-0000-4000-8000-000000000001'::uuid),
    ('CP05','C02','023c0200-0000-4000-8000-000000000002'::uuid,'023c0211-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C02-V2A','023c0212-0000-4000-8000-000000000001'::uuid,'023c0213-0000-4000-8000-000000000001'::uuid),
    ('CP06','C02','023c0200-0000-4000-8000-000000000002'::uuid,'023c0221-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C02-V2B','023c0222-0000-4000-8000-000000000001'::uuid,'023c0223-0000-4000-8000-000000000001'::uuid),
    ('CP07','C03','023c0300-0000-4000-8000-000000000003'::uuid,'023c0301-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C03-V1','023c0302-0000-4000-8000-000000000001'::uuid,'023c0303-0000-4000-8000-000000000001'::uuid),
    ('CP08','C03','023c0300-0000-4000-8000-000000000003'::uuid,'023c0311-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C03-V2','023c0312-0000-4000-8000-000000000001'::uuid,'023c0313-0000-4000-8000-000000000001'::uuid),
    ('CP09','C04','023c0400-0000-4000-8000-000000000004'::uuid,'023c0401-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C04-V1','023c0402-0000-4000-8000-000000000001'::uuid,'023c0403-0000-4000-8000-000000000001'::uuid),
    ('CP10','C04','023c0400-0000-4000-8000-000000000004'::uuid,'023c0411-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C04-V2','023c0412-0000-4000-8000-000000000001'::uuid,'023c0413-0000-4000-8000-000000000001'::uuid),
    ('CP11','C05','023c0500-0000-4000-8000-000000000005'::uuid,'023c0501-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V1','023c0502-0000-4000-8000-000000000001'::uuid,'023c0503-0000-4000-8000-000000000001'::uuid),
    ('CP12','C05','023c0500-0000-4000-8000-000000000005'::uuid,'023c0511-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V2','023c0512-0000-4000-8000-000000000001'::uuid,'023c0513-0000-4000-8000-000000000001'::uuid),
    ('CP13','C06','023c0600-0000-4000-8000-000000000006'::uuid,'023c0601-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V1','023c0602-0000-4000-8000-000000000001'::uuid,'023c0603-0000-4000-8000-000000000001'::uuid),
    ('CP14','C06','023c0600-0000-4000-8000-000000000006'::uuid,'023c0611-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V2','023c0612-0000-4000-8000-000000000001'::uuid,'023c0613-0000-4000-8000-000000000001'::uuid),
    ('CP15','C06','023c0600-0000-4000-8000-000000000006'::uuid,'023c0621-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V3','023c0622-0000-4000-8000-000000000001'::uuid,'023c0623-0000-4000-8000-000000000001'::uuid),
    ('CP16','C07-A','023c0700-0000-4000-8000-000000000071'::uuid,'023c0701-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-A-V1','023c0702-0000-4000-8000-000000000001'::uuid,'023c0703-0000-4000-8000-000000000001'::uuid),
    ('CP17','C07-A','023c0700-0000-4000-8000-000000000071'::uuid,'023c0711-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-A-V2','023c0712-0000-4000-8000-000000000001'::uuid,'023c0713-0000-4000-8000-000000000001'::uuid),
    ('CP18','C07-B','023c0700-0000-4000-8000-000000000072'::uuid,'023c0781-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-B-V1','023c0782-0000-4000-8000-000000000001'::uuid,'023c0783-0000-4000-8000-000000000001'::uuid),
    ('CP19','C07-B','023c0700-0000-4000-8000-000000000072'::uuid,'023c0791-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-B-V2','023c0792-0000-4000-8000-000000000001'::uuid,'023c0793-0000-4000-8000-000000000001'::uuid)
), observed as (
  select e.*,
    (select count(*) from s2t_fhir.baseline_version b where b.baseline_version_id=e.baseline_id) as baseline_count,
    (select count(*) from s2t_fhir.artifact a where a.artifact_id=e.artifact_id) as artifact_count,
    (select count(*) from s2t_fhir.import_run i where i.import_run_id=e.import_id) as import_count,
    (select count(*) from s2t_fhir.baseline_artifact ba where ba.baseline_version_id=e.baseline_id and ba.artifact_id=e.artifact_id) as baseline_artifact_count,
    (select count(*) from s2t_fhir.import_run i
      join s2t_fhir.reference_value v on v.reference_value_id=i.terminal_status_value_id
      join s2t_fhir.reference_domain d on d.reference_domain_id=v.reference_domain_id and d.domain_code='IMPORT_RUN_STATUS'
      where i.import_run_id=e.import_id and i.baseline_version_id=e.baseline_id and i.artifact_id=e.artifact_id and v.value_code='COMMITTED') as committed_exact_count,
    (select count(*) from s2t_fhir.baseline_version b where b.baseline_version_id=e.baseline_id and b.baseline_series_id=e.series_id and b.baseline_code=e.baseline_code) as identity_exact_count
  from expected e
)
select checkpoint,case_id,baseline_id,artifact_id,import_id,
  case
    when baseline_count+artifact_count+import_count+baseline_artifact_count=0 then 'NOT_STARTED'
    when baseline_count=1 and artifact_count=1 and import_count=1 and baseline_artifact_count=1
      and committed_exact_count=1 and identity_exact_count=1 then 'COMPLETE'
    else 'PARTIAL_OR_AMBIGUOUS'
  end as checkpoint_state
from observed
order by checkpoint;

-- Exact contiguous-prefix recovery decision across CP01-CP26.
with workers(principal_id,auth_subject,display_name) as (
  values
    ('023c01a0-0000-4000-8000-000000000001'::uuid,'023c01a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C01-WORKER-A'),
    ('023c01b0-0000-4000-8000-000000000001'::uuid,'023c01b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C01-WORKER-B'),
    ('023c02a0-0000-4000-8000-000000000001'::uuid,'023c02a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C02-WORKER-A'),
    ('023c02b0-0000-4000-8000-000000000001'::uuid,'023c02b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C02-WORKER-B'),
    ('023c03a0-0000-4000-8000-000000000001'::uuid,'023c03a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C03-WORKER-A'),
    ('023c03b0-0000-4000-8000-000000000001'::uuid,'023c03b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C03-WORKER-B'),
    ('023c04a0-0000-4000-8000-000000000001'::uuid,'023c04a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C04-WORKER-A'),
    ('023c04b0-0000-4000-8000-000000000001'::uuid,'023c04b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C04-WORKER-B'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'023c05a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C05-WORKER-A'),
    ('023c05b0-0000-4000-8000-000000000001'::uuid,'023c05b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C05-WORKER-B'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'023c06a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C06-WORKER-A'),
    ('023c06b0-0000-4000-8000-000000000001'::uuid,'023c06b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C06-WORKER-B'),
    ('023c07a0-0000-4000-8000-000000000001'::uuid,'023c07a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C07-WORKER-A'),
    ('023c07b0-0000-4000-8000-000000000001'::uuid,'023c07b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C07-WORKER-B')
), expected_capability(principal_id,capability_code) as (
  values
    ('023c01a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c01b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c02a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c02b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c03a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c03b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c04a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c04b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),('023c05b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),('023c06b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c06b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c07a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c07b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD')
), actual_capability as (
  select a.principal_id,a.capability_code
  from s2t_fhir.baseline_action_authorization a join workers w using(principal_id)
  where a.revoked_at is null and a.effective_at <= transaction_timestamp()
  union all
  select a.principal_id,a.capability_code
  from s2t_fhir.review_actor_authorization a join workers w using(principal_id)
  where a.revoked_at is null and a.effective_at <= transaction_timestamp()
), cp01_evaluation as (
  select
    (select count(*) from workers w join s2t_fhir.principal p using(principal_id)
      where p.external_issuer='supabase-auth' and p.external_subject=w.auth_subject
        and p.display_name=w.display_name and p.disabled_at is null) as principal_count,
    (select count(*) from s2t_fhir.baseline_series where baseline_series_id in (
      '023c0100-0000-4000-8000-000000000001','023c0200-0000-4000-8000-000000000002','023c0300-0000-4000-8000-000000000003','023c0400-0000-4000-8000-000000000004',
      '023c0500-0000-4000-8000-000000000005','023c0600-0000-4000-8000-000000000006','023c0700-0000-4000-8000-000000000071','023c0700-0000-4000-8000-000000000072')) as series_count,
    (select count(*) from s2t_fhir.mapping_resource_registry where resource_config_id in (
      't023-conc-pack-20261009-r1-c03-resource','t023-conc-pack-20261009-r1-c04-resource','t023-conc-pack-20261009-r1-c05-resource','t023-conc-pack-20261009-r1-c06-resource')) as registry_count,
    (select count(*) from actual_capability) as actual_capability_count,
    not exists(select * from expected_capability except select * from actual_capability)
      and not exists(select * from actual_capability except select * from expected_capability) as capabilities_exact
), raw(checkpoint,ordinal,observed_count,expected_count) as (
  select 'CP01',1,
    case
      when principal_count=0 and series_count=0 and registry_count=0 and actual_capability_count=0 then 0
      when principal_count=14 and series_count=8 and registry_count=4
        and actual_capability_count=19 and capabilities_exact then 45
      else -1
    end,
    45
  from cp01_evaluation
  union all
  select 'CP'||lpad(n::text,2,'0'),n,
    (select count(*) from s2t_fhir.baseline_version b where b.baseline_version_id=(array[
      '023c0101-0000-4000-8000-000000000001','023c0111-0000-4000-8000-000000000001','023c0201-0000-4000-8000-000000000001','023c0211-0000-4000-8000-000000000001','023c0221-0000-4000-8000-000000000001',
      '023c0301-0000-4000-8000-000000000001','023c0311-0000-4000-8000-000000000001','023c0401-0000-4000-8000-000000000001','023c0411-0000-4000-8000-000000000001','023c0501-0000-4000-8000-000000000001',
      '023c0511-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001','023c0611-0000-4000-8000-000000000001','023c0621-0000-4000-8000-000000000001','023c0701-0000-4000-8000-000000000001',
      '023c0711-0000-4000-8000-000000000001','023c0781-0000-4000-8000-000000000001','023c0791-0000-4000-8000-000000000001']::uuid[])[n-1])
    +(select count(*) from s2t_fhir.artifact a where a.artifact_id=(array[
      '023c0102-0000-4000-8000-000000000001','023c0112-0000-4000-8000-000000000001','023c0202-0000-4000-8000-000000000001','023c0212-0000-4000-8000-000000000001','023c0222-0000-4000-8000-000000000001',
      '023c0302-0000-4000-8000-000000000001','023c0312-0000-4000-8000-000000000001','023c0402-0000-4000-8000-000000000001','023c0412-0000-4000-8000-000000000001','023c0502-0000-4000-8000-000000000001',
      '023c0512-0000-4000-8000-000000000001','023c0602-0000-4000-8000-000000000001','023c0612-0000-4000-8000-000000000001','023c0622-0000-4000-8000-000000000001','023c0702-0000-4000-8000-000000000001',
      '023c0712-0000-4000-8000-000000000001','023c0782-0000-4000-8000-000000000001','023c0792-0000-4000-8000-000000000001']::uuid[])[n-1])
    +(select count(*) from s2t_fhir.import_run i where i.import_run_id=(array[
      '023c0103-0000-4000-8000-000000000001','023c0113-0000-4000-8000-000000000001','023c0203-0000-4000-8000-000000000001','023c0213-0000-4000-8000-000000000001','023c0223-0000-4000-8000-000000000001',
      '023c0303-0000-4000-8000-000000000001','023c0313-0000-4000-8000-000000000001','023c0403-0000-4000-8000-000000000001','023c0413-0000-4000-8000-000000000001','023c0503-0000-4000-8000-000000000001',
      '023c0513-0000-4000-8000-000000000001','023c0603-0000-4000-8000-000000000001','023c0613-0000-4000-8000-000000000001','023c0623-0000-4000-8000-000000000001','023c0703-0000-4000-8000-000000000001',
      '023c0713-0000-4000-8000-000000000001','023c0783-0000-4000-8000-000000000001','023c0793-0000-4000-8000-000000000001']::uuid[])[n-1]),3
  from generate_series(2,19) n
  union all
  select 'CP20',200,(select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id in (
    '023c0201-0000-4000-8000-000000000001','023c0301-0000-4000-8000-000000000001','023c0401-0000-4000-8000-000000000001','023c0501-0000-4000-8000-000000000001',
    '023c0601-0000-4000-8000-000000000001','023c0701-0000-4000-8000-000000000001','023c0781-0000-4000-8000-000000000001')),7
  union all
  select 'CP21',210,
    (select count(*) from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT')
    +(select count(*) from s2t_governance.governance_question where title='T023-CONC-PACK-20261009-R1-C04-QUESTION')
    +(select count(*) from s2t_governance.governance_event e join s2t_governance.governance_question q using(question_id) where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION' and e.event_type='QUESTION_CREATED'),3
  union all
  select 'CP22A',220,
    (select count(*) from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V1-REVIEW')
    +(select count(*) from s2t_fhir.mapping_review_event where baseline_version_id='023c0501-0000-4000-8000-000000000001'),2
  union all
  select 'CP22B',221,
    (select count(*) from s2t_fhir.validation_run where validation_run_id='023c0508-0000-4000-8000-000000000001')
    +(select count(*) from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0509-0000-4000-8000-000000000001'),2
  union all
  select 'CP22C',222,(select count(*) from s2t_fhir.baseline_activation_context where baseline_version_id='023c0501-0000-4000-8000-000000000001'),1
  union all
  select 'CP23A',230,(select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id='023c0511-0000-4000-8000-000000000001'),1
  union all
  select 'CP23B',231,
    (select count(*) from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V2-REVIEW')
    +(select count(*) from s2t_fhir.mapping_review_event where baseline_version_id='023c0511-0000-4000-8000-000000000001'),2
  union all
  select 'CP23C',232,
    (select count(*) from s2t_fhir.validation_run where validation_run_id='023c0518-0000-4000-8000-000000000001')
    +(select count(*) from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0519-0000-4000-8000-000000000001'),2
  union all
  select 'CP24A',240,
    (select count(*) from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V1-REVIEW')
    +(select count(*) from s2t_fhir.mapping_review_event where baseline_version_id='023c0601-0000-4000-8000-000000000001'),2
  union all
  select 'CP24B',241,
    (select count(*) from s2t_fhir.validation_run where validation_run_id='023c0608-0000-4000-8000-000000000001')
    +(select count(*) from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0609-0000-4000-8000-000000000001'),2
  union all
  select 'CP24C',242,(select count(*) from s2t_fhir.baseline_activation_context where baseline_version_id='023c0601-0000-4000-8000-000000000001'),1
  union all
  select 'CP25A',250,(select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id='023c0611-0000-4000-8000-000000000001'),1
  union all
  select 'CP25B',251,
    (select count(*) from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V2-REVIEW')
    +(select count(*) from s2t_fhir.mapping_review_event where baseline_version_id='023c0611-0000-4000-8000-000000000001'),2
  union all
  select 'CP25C',252,
    (select count(*) from s2t_fhir.validation_run where validation_run_id='023c0618-0000-4000-8000-000000000001')
    +(select count(*) from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0619-0000-4000-8000-000000000001'),2
), states as (
  select *,case when observed_count=0 then 'NOT_STARTED' when observed_count=expected_count then 'COMPLETE' else 'PARTIAL_OR_AMBIGUOUS' end as state from raw
), prefix as (
  select *,bool_and(state='COMPLETE') over(order by ordinal rows between unbounded preceding and current row) as contiguous_complete from states
), summary as (
  select
    max(checkpoint) filter(where contiguous_complete) as last_completed_checkpoint,
    min(checkpoint) filter(where state='NOT_STARTED' and ordinal=(select min(ordinal) from states where state<>'COMPLETE')) as exact_next_checkpoint,
    count(*) filter(where state='PARTIAL_OR_AMBIGUOUS') as partial_count,
    count(*) filter(where state='COMPLETE' and ordinal>(select min(ordinal) from states where state<>'COMPLETE')) as completed_after_gap
  from prefix
)
select 'V01_RECOVERY' as verification,
  case when partial_count>0 then 'STOP_PARTIAL_OR_AMBIGUOUS'
       when completed_after_gap>0 then 'STOP_NONCONTIGUOUS'
       when exact_next_checkpoint is null then 'COMPLETE_CP26_READ_ONLY_NEXT'
       else 'READY_FOR_EXACT_NEXT_CHECKPOINT' end as recovery_state,
  last_completed_checkpoint,exact_next_checkpoint
from summary;

-- ---------------------------------------------------------------------------
-- V02 - exact worker principals and exact active capabilities
-- No worker may have an unlisted active capability.
-- ---------------------------------------------------------------------------
with workers(principal_id,auth_subject,display_name) as (
  values
    ('023c01a0-0000-4000-8000-000000000001'::uuid,'023c01a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C01-WORKER-A'),
    ('023c01b0-0000-4000-8000-000000000001'::uuid,'023c01b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C01-WORKER-B'),
    ('023c02a0-0000-4000-8000-000000000001'::uuid,'023c02a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C02-WORKER-A'),
    ('023c02b0-0000-4000-8000-000000000001'::uuid,'023c02b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C02-WORKER-B'),
    ('023c03a0-0000-4000-8000-000000000001'::uuid,'023c03a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C03-WORKER-A'),
    ('023c03b0-0000-4000-8000-000000000001'::uuid,'023c03b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C03-WORKER-B'),
    ('023c04a0-0000-4000-8000-000000000001'::uuid,'023c04a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C04-WORKER-A'),
    ('023c04b0-0000-4000-8000-000000000001'::uuid,'023c04b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C04-WORKER-B'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'023c05a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C05-WORKER-A'),
    ('023c05b0-0000-4000-8000-000000000001'::uuid,'023c05b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C05-WORKER-B'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'023c06a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C06-WORKER-A'),
    ('023c06b0-0000-4000-8000-000000000001'::uuid,'023c06b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C06-WORKER-B'),
    ('023c07a0-0000-4000-8000-000000000001'::uuid,'023c07a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C07-WORKER-A'),
    ('023c07b0-0000-4000-8000-000000000001'::uuid,'023c07b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C07-WORKER-B')
), expected_capability(principal_id,capability_code) as (
  values
    ('023c01a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c01b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c02a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c02b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c03a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c03b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c04a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c04b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),('023c05b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),('023c06b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c06b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c07a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),('023c07b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD')
), actual_capability as (
  select a.principal_id,a.capability_code
  from s2t_fhir.baseline_action_authorization a join workers w using(principal_id)
  where a.revoked_at is null and a.effective_at <= transaction_timestamp()
  union all
  select a.principal_id,a.capability_code
  from s2t_fhir.review_actor_authorization a join workers w using(principal_id)
  where a.revoked_at is null and a.effective_at <= transaction_timestamp()
)
select 'V02_WORKERS_AND_CAPABILITIES' as verification,
  case when
    (select count(*) from workers w join s2t_fhir.principal p using(principal_id)
      where p.external_issuer='supabase-auth' and p.external_subject=w.auth_subject
        and p.display_name=w.display_name and p.disabled_at is null)=14
    and not exists(select * from expected_capability except select * from actual_capability)
    and not exists(select * from actual_capability except select * from expected_capability)
  then 'PASS' else 'FAIL' end as result,
  (select count(*) from expected_capability) as expected_active_capability_count,
  (select count(*) from actual_capability) as actual_active_capability_count;

-- ---------------------------------------------------------------------------
-- V03 - exact mapped object identities; no duplicate or ambiguous objects
-- ---------------------------------------------------------------------------
with expected(case_id,baseline_id,manifest_id,row_id,identity_id,mapping_id,node_id) as (
  values
    ('C03','023c0301-0000-4000-8000-000000000001'::uuid,'023c0304-0000-4000-8000-000000000001'::uuid,'023c0305-0000-4000-8000-000000000001'::uuid,'023c0306-0000-4000-8000-000000000001'::uuid,'023c0307-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C03-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C03-V1-node-2')),
    ('C04','023c0401-0000-4000-8000-000000000001'::uuid,'023c0404-0000-4000-8000-000000000001'::uuid,'023c0405-0000-4000-8000-000000000001'::uuid,'023c0406-0000-4000-8000-000000000001'::uuid,'023c0407-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C04-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C04-V1-node-2')),
    ('C05-V1','023c0501-0000-4000-8000-000000000001'::uuid,'023c0504-0000-4000-8000-000000000001'::uuid,'023c0505-0000-4000-8000-000000000001'::uuid,'023c0506-0000-4000-8000-000000000001'::uuid,'023c0507-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C05-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V1-node-2')),
    ('C05-V2','023c0511-0000-4000-8000-000000000001'::uuid,'023c0514-0000-4000-8000-000000000001'::uuid,'023c0515-0000-4000-8000-000000000001'::uuid,'023c0516-0000-4000-8000-000000000001'::uuid,'023c0517-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C05-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V2-node-2')),
    ('C06-V1','023c0601-0000-4000-8000-000000000001'::uuid,'023c0604-0000-4000-8000-000000000001'::uuid,'023c0605-0000-4000-8000-000000000001'::uuid,'023c0606-0000-4000-8000-000000000001'::uuid,'023c0607-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C06-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V1-node-2')),
    ('C06-V2','023c0611-0000-4000-8000-000000000001'::uuid,'023c0614-0000-4000-8000-000000000001'::uuid,'023c0615-0000-4000-8000-000000000001'::uuid,'023c0616-0000-4000-8000-000000000001'::uuid,'023c0617-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C06-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V2-node-2'))
)
select e.case_id,e.baseline_id,e.mapping_id,e.node_id,
  case when
    (select count(*) from s2t_fhir.artifact_sheet_manifest x where x.artifact_sheet_manifest_id=e.manifest_id)=1
    and (select count(*) from s2t_fhir.import_candidate_row x where x.import_candidate_row_id=e.row_id)=1
    and (select count(*) from s2t_fhir.logical_mapping_identity x where x.logical_mapping_identity_id=e.identity_id)=1
    and (select count(*) from s2t_fhir.mapping_record x where x.mapping_record_id=e.mapping_id and x.baseline_version_id=e.baseline_id and x.import_candidate_row_id=e.row_id and x.logical_mapping_identity_id=e.identity_id)=1
    and (select count(*) from s2t_fhir.element_mapping x where x.mapping_record_id=e.mapping_id)=1
  then 'PASS' else 'FAIL' end as result
from expected e order by e.case_id;

-- ---------------------------------------------------------------------------
-- V04 - C01-C07 lifecycle, context, review, governance, and relationship state
-- ---------------------------------------------------------------------------
with case_baselines(case_id,baseline_id) as (
  values
    ('C01','023c0101-0000-4000-8000-000000000001'::uuid),('C01','023c0111-0000-4000-8000-000000000001'::uuid),
    ('C02','023c0201-0000-4000-8000-000000000001'::uuid),('C02','023c0211-0000-4000-8000-000000000001'::uuid),('C02','023c0221-0000-4000-8000-000000000001'::uuid),
    ('C03','023c0301-0000-4000-8000-000000000001'::uuid),('C03','023c0311-0000-4000-8000-000000000001'::uuid),
    ('C04','023c0401-0000-4000-8000-000000000001'::uuid),('C04','023c0411-0000-4000-8000-000000000001'::uuid),
    ('C05','023c0501-0000-4000-8000-000000000001'::uuid),('C05','023c0511-0000-4000-8000-000000000001'::uuid),
    ('C06','023c0601-0000-4000-8000-000000000001'::uuid),('C06','023c0611-0000-4000-8000-000000000001'::uuid),('C06','023c0621-0000-4000-8000-000000000001'::uuid),
    ('C07','023c0701-0000-4000-8000-000000000001'::uuid),('C07','023c0711-0000-4000-8000-000000000001'::uuid),('C07','023c0781-0000-4000-8000-000000000001'::uuid),('C07','023c0791-0000-4000-8000-000000000001'::uuid)
), lifecycle as (
  select cb.case_id,count(e.*) as lifecycle_count,
    count(*) filter(where v.value_code='CANDIDATE' and not exists(select 1 from s2t_fhir.baseline_lifecycle_event n where n.supersedes_event_id=e.baseline_lifecycle_event_id)) as current_candidate_count,
    count(*) filter(where v.value_code='ACTIVE' and not exists(select 1 from s2t_fhir.baseline_lifecycle_event n where n.supersedes_event_id=e.baseline_lifecycle_event_id)) as current_active_count
  from case_baselines cb left join s2t_fhir.baseline_lifecycle_event e on e.baseline_version_id=cb.baseline_id
  left join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id
  group by cb.case_id
), context_counts as (
  select cb.case_id,count(distinct cc.baseline_candidate_context_id) as candidate_context_count,
    count(distinct ac.baseline_activation_context_id) as activation_context_count
  from case_baselines cb
  left join s2t_fhir.baseline_candidate_context cc on cc.baseline_version_id=cb.baseline_id
  left join s2t_fhir.baseline_activation_context ac on ac.baseline_version_id=cb.baseline_id
  group by cb.case_id
), relationship_counts as (
  select cb.case_id,count(distinct r.baseline_relationship_id) as relationship_count
  from case_baselines cb left join s2t_fhir.baseline_relationship r
    on r.from_baseline_version_id=cb.baseline_id or r.to_baseline_version_id=cb.baseline_id
  group by cb.case_id
), expected(case_id,lifecycle_count,current_candidate_count,current_active_count,candidate_context_count,activation_context_count,relationship_count) as (
  values
    ('C01',0::bigint,0::bigint,0::bigint,0::bigint,0::bigint,0::bigint),
    ('C02',1,1,0,1,0,0),('C03',1,1,0,1,0,0),('C04',1,1,0,1,0,0),
    ('C05',3,1,1,2,1,0),('C06',3,1,1,2,1,0),('C07',2,2,0,2,0,0)
)
select e.case_id,
  case when (l.lifecycle_count,l.current_candidate_count,l.current_active_count,
             c.candidate_context_count,c.activation_context_count,r.relationship_count)
          =(e.lifecycle_count,e.current_candidate_count,e.current_active_count,
            e.candidate_context_count,e.activation_context_count,e.relationship_count)
       then 'PASS' else 'FAIL' end as result,
  l.lifecycle_count,l.current_candidate_count,l.current_active_count,
  c.candidate_context_count,c.activation_context_count,r.relationship_count
from expected e join lifecycle l using(case_id) join context_counts c using(case_id)
join relationship_counts r using(case_id) order by e.case_id;

-- C03 must remain OPEN_CURRENT with no test review mutation.
select 'V04_C03_REVIEW' as verification,
  case when
    (select count(*) from s2t_fhir.candidate_review_session_state s
      where s.session_name='T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT' and s.session_state='OPEN_CURRENT')=1
    and (select count(*) from s2t_fhir.mapping_review_event e where e.baseline_version_id='023c0301-0000-4000-8000-000000000001')=0
  then 'PASS' else 'FAIL' end as result;

-- C04 must have one open question, only QUESTION_CREATED evidence, and no link.
select 'V04_C04_GOVERNANCE' as verification,
  case when
    (select count(*) from s2t_governance.governance_question q where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION')=1
    and (select count(*) from s2t_governance.governance_event e join s2t_governance.governance_question q using(question_id)
      where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION' and e.event_type='QUESTION_CREATED')=1
    and (select count(*) from s2t_governance.governance_event e join s2t_governance.governance_question q using(question_id)
      where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION' and e.event_type<>'QUESTION_CREATED')=0
    and (select count(*) from s2t_governance.governance_mapping_link l join s2t_governance.governance_question q using(question_id)
      where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION')=0
  then 'PASS' else 'FAIL' end as result;

-- C07 series must share no governed object identifiers.
select 'V04_C07_INDEPENDENCE' as verification,
  case when
    (select count(distinct b.baseline_series_id) from s2t_fhir.baseline_version b where b.baseline_version_id in (
      '023c0701-0000-4000-8000-000000000001','023c0711-0000-4000-8000-000000000001','023c0781-0000-4000-8000-000000000001','023c0791-0000-4000-8000-000000000001'))=2
    and not exists(
      select 1 from s2t_fhir.baseline_artifact a join s2t_fhir.baseline_artifact b using(artifact_id)
      where a.baseline_version_id in ('023c0701-0000-4000-8000-000000000001','023c0711-0000-4000-8000-000000000001')
        and b.baseline_version_id in ('023c0781-0000-4000-8000-000000000001','023c0791-0000-4000-8000-000000000001'))
  then 'PASS' else 'FAIL' end as result;

-- ---------------------------------------------------------------------------
-- V05 - C05/C06 validation, review, gate, and Promotion readiness
-- ---------------------------------------------------------------------------
with expected(case_version,baseline_id,import_id,artifact_id,validation_id,gate_id,mapping_id,session_name,expected_leaf) as (
  values
    ('C05-V1','023c0501-0000-4000-8000-000000000001'::uuid,'023c0503-0000-4000-8000-000000000001'::uuid,'023c0502-0000-4000-8000-000000000001'::uuid,'023c0508-0000-4000-8000-000000000001'::uuid,'023c0509-0000-4000-8000-000000000001'::uuid,'023c0507-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V1-REVIEW','ACTIVE'),
    ('C05-V2','023c0511-0000-4000-8000-000000000001'::uuid,'023c0513-0000-4000-8000-000000000001'::uuid,'023c0512-0000-4000-8000-000000000001'::uuid,'023c0518-0000-4000-8000-000000000001'::uuid,'023c0519-0000-4000-8000-000000000001'::uuid,'023c0517-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V2-REVIEW','CANDIDATE'),
    ('C06-V1','023c0601-0000-4000-8000-000000000001'::uuid,'023c0603-0000-4000-8000-000000000001'::uuid,'023c0602-0000-4000-8000-000000000001'::uuid,'023c0608-0000-4000-8000-000000000001'::uuid,'023c0609-0000-4000-8000-000000000001'::uuid,'023c0607-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V1-REVIEW','ACTIVE'),
    ('C06-V2','023c0611-0000-4000-8000-000000000001'::uuid,'023c0613-0000-4000-8000-000000000001'::uuid,'023c0612-0000-4000-8000-000000000001'::uuid,'023c0618-0000-4000-8000-000000000001'::uuid,'023c0619-0000-4000-8000-000000000001'::uuid,'023c0617-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V2-REVIEW','CANDIDATE')
)
select e.case_version,
  case when
    (select count(*) from s2t_fhir.validation_run v join s2t_fhir.reference_value o on o.reference_value_id=v.outcome_value_id
      where v.validation_run_id=e.validation_id and v.import_run_id=e.import_id and v.artifact_id=e.artifact_id and o.value_code='PASS'
        and v.candidate_count=1 and v.accepted_count=1 and v.error_count=0 and v.quarantined_count=0)=1
    and (select count(*) from s2t_fhir.release_gate_evaluation g join s2t_fhir.reference_value o on o.reference_value_id=g.gate_outcome_value_id
      where g.release_gate_evaluation_id=e.gate_id and g.baseline_version_id=e.baseline_id and g.validation_run_id=e.validation_id and o.value_code='PASSED')=1
    and (select count(*) from s2t_fhir.release_gate_result r where r.release_gate_evaluation_id=e.gate_id)
        =(select count(*) from s2t_fhir.release_gate_requirement r join s2t_fhir.release_gate_definition g using(release_gate_definition_id) where g.gate_code='BASELINE_IMPORT' and g.version_label='v1')
    and not exists(select 1 from s2t_fhir.release_gate_result r join s2t_fhir.reference_value o on o.reference_value_id=r.requirement_outcome_value_id where r.release_gate_evaluation_id=e.gate_id and o.value_code<>'PASSED')
    and (select count(*) from s2t_fhir.current_mapping_review r where r.baseline_version_id=e.baseline_id and r.mapping_record_id=e.mapping_id and r.review_status='REVIEWED')=1
    and (select count(*) from s2t_fhir.review_session s where s.session_name=e.session_name and s.baseline_version_id=e.baseline_id and s.ended_at is not null)=1
    and (select s.ended_at < v.started_at and v.started_at < v.completed_at and v.completed_at < g.evaluated_at
                and (e.expected_leaf<>'ACTIVE' or g.evaluated_at < a.effective_at)
         from s2t_fhir.review_session s
         join s2t_fhir.validation_run v on v.validation_run_id=e.validation_id
         join s2t_fhir.release_gate_evaluation g on g.release_gate_evaluation_id=e.gate_id
         left join s2t_fhir.baseline_activation_context a on a.baseline_version_id=e.baseline_id
         where s.session_name=e.session_name)=true
    and (select count(*) from s2t_fhir.baseline_lifecycle_event l join s2t_fhir.reference_value v on v.reference_value_id=l.lifecycle_status_value_id
      where l.baseline_version_id=e.baseline_id and v.value_code=e.expected_leaf
        and not exists(select 1 from s2t_fhir.baseline_lifecycle_event n where n.supersedes_event_id=l.baseline_lifecycle_event_id))=1
  then 'PASS' else 'FAIL' end as result
from expected e order by e.case_version;

-- ---------------------------------------------------------------------------
-- V06 - scoped per-case fingerprints for pre/post rollback comparison
-- ---------------------------------------------------------------------------
with case_series(case_id,series_id) as (
  values
    ('C01','023c0100-0000-4000-8000-000000000001'::uuid),('C02','023c0200-0000-4000-8000-000000000002'::uuid),
    ('C03','023c0300-0000-4000-8000-000000000003'::uuid),('C04','023c0400-0000-4000-8000-000000000004'::uuid),
    ('C05','023c0500-0000-4000-8000-000000000005'::uuid),('C06','023c0600-0000-4000-8000-000000000006'::uuid),
    ('C07','023c0700-0000-4000-8000-000000000071'::uuid),('C07','023c0700-0000-4000-8000-000000000072'::uuid)
), payload as (
  select cs.case_id,jsonb_build_object(
    'series',jsonb_agg(distinct cs.series_id order by cs.series_id),
    'baselines',(select jsonb_agg(jsonb_build_array(b.baseline_version_id,b.version_label) order by b.baseline_version_id) from s2t_fhir.baseline_version b join case_series x on x.series_id=b.baseline_series_id where x.case_id=cs.case_id),
    'lifecycle',(select jsonb_agg(jsonb_build_array(e.baseline_lifecycle_event_id,e.baseline_version_id,v.value_code,e.supersedes_event_id) order by e.baseline_lifecycle_event_id) from s2t_fhir.baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) join case_series x on x.series_id=b.baseline_series_id join s2t_fhir.reference_value v on v.reference_value_id=e.lifecycle_status_value_id where x.case_id=cs.case_id),
    'candidateContexts',(select jsonb_agg(jsonb_build_array(c.baseline_candidate_context_id,c.baseline_version_id,c.candidate_lifecycle_event_id,c.import_run_id) order by c.baseline_version_id) from s2t_fhir.baseline_candidate_context c join s2t_fhir.baseline_version b using(baseline_version_id) join case_series x on x.series_id=b.baseline_series_id where x.case_id=cs.case_id),
    'activationContexts',(select jsonb_agg(jsonb_build_array(a.baseline_activation_context_id,a.baseline_version_id,a.active_lifecycle_event_id,a.release_gate_evaluation_id) order by a.baseline_version_id) from s2t_fhir.baseline_activation_context a join s2t_fhir.baseline_version b using(baseline_version_id) join case_series x on x.series_id=b.baseline_series_id where x.case_id=cs.case_id),
    'relationships',(select jsonb_agg(jsonb_build_array(r.baseline_relationship_id,r.from_baseline_version_id,r.to_baseline_version_id) order by r.baseline_relationship_id) from s2t_fhir.baseline_relationship r where r.from_baseline_version_id in (select b.baseline_version_id from s2t_fhir.baseline_version b join case_series x on x.series_id=b.baseline_series_id where x.case_id=cs.case_id) or r.to_baseline_version_id in (select b.baseline_version_id from s2t_fhir.baseline_version b join case_series x on x.series_id=b.baseline_series_id where x.case_id=cs.case_id)),
    'reviewEvents',(select jsonb_agg(jsonb_build_array(r.mapping_review_event_id,r.baseline_version_id,r.mapping_record_id,r.supersedes_event_id) order by r.mapping_review_event_id) from s2t_fhir.mapping_review_event r join s2t_fhir.baseline_version b using(baseline_version_id) join case_series x on x.series_id=b.baseline_series_id where x.case_id=cs.case_id)
  ) as value
  from case_series cs group by cs.case_id
)
select case_id,md5(value::text) as scoped_fingerprint,value as fingerprint_payload
from payload order by case_id;

-- ---------------------------------------------------------------------------
-- V07 - final emitted manifest (exact IDs; never rediscover by broad matching)
-- ---------------------------------------------------------------------------
with manifest(case_id,series_id,source_system,resource_config_id,baseline_id,baseline_code,artifact_id,import_id,mapping_id,node_id,validation_id,gate_id,review_session_name) as (
  values
    ('C01-A','023c0100-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C01',null,'023c0101-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C01-A','023c0102-0000-4000-8000-000000000001'::uuid,'023c0103-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C01-B','023c0100-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C01',null,'023c0111-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C01-B','023c0112-0000-4000-8000-000000000001'::uuid,'023c0113-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C02-V1','023c0200-0000-4000-8000-000000000002'::uuid,'T023-CONC-PACK-20261009-R1-C02',null,'023c0201-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C02-V1','023c0202-0000-4000-8000-000000000001'::uuid,'023c0203-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C02-V2A','023c0200-0000-4000-8000-000000000002'::uuid,'T023-CONC-PACK-20261009-R1-C02',null,'023c0211-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C02-V2A','023c0212-0000-4000-8000-000000000001'::uuid,'023c0213-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C02-V2B','023c0200-0000-4000-8000-000000000002'::uuid,'T023-CONC-PACK-20261009-R1-C02',null,'023c0221-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C02-V2B','023c0222-0000-4000-8000-000000000001'::uuid,'023c0223-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C03-V1','023c0300-0000-4000-8000-000000000003'::uuid,'T023-CONC-PACK-20261009-R1-C03','t023-conc-pack-20261009-r1-c03-resource','023c0301-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C03-V1','023c0302-0000-4000-8000-000000000001'::uuid,'023c0303-0000-4000-8000-000000000001'::uuid,'023c0307-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C03-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C03-V1-node-2'),null::uuid,null::uuid,'T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT'),
    ('C03-V2','023c0300-0000-4000-8000-000000000003'::uuid,'T023-CONC-PACK-20261009-R1-C03','t023-conc-pack-20261009-r1-c03-resource','023c0311-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C03-V2','023c0312-0000-4000-8000-000000000001'::uuid,'023c0313-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C04-V1','023c0400-0000-4000-8000-000000000004'::uuid,'T023-CONC-PACK-20261009-R1-C04','t023-conc-pack-20261009-r1-c04-resource','023c0401-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C04-V1','023c0402-0000-4000-8000-000000000001'::uuid,'023c0403-0000-4000-8000-000000000001'::uuid,'023c0407-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C04-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C04-V1-node-2'),null::uuid,null::uuid,null),
    ('C04-V2','023c0400-0000-4000-8000-000000000004'::uuid,'T023-CONC-PACK-20261009-R1-C04','t023-conc-pack-20261009-r1-c04-resource','023c0411-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C04-V2','023c0412-0000-4000-8000-000000000001'::uuid,'023c0413-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C05-V1','023c0500-0000-4000-8000-000000000005'::uuid,'T023-CONC-PACK-20261009-R1-C05','t023-conc-pack-20261009-r1-c05-resource','023c0501-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V1','023c0502-0000-4000-8000-000000000001'::uuid,'023c0503-0000-4000-8000-000000000001'::uuid,'023c0507-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C05-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V1-node-2'),'023c0508-0000-4000-8000-000000000001'::uuid,'023c0509-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V1-REVIEW'),
    ('C05-V2','023c0500-0000-4000-8000-000000000005'::uuid,'T023-CONC-PACK-20261009-R1-C05','t023-conc-pack-20261009-r1-c05-resource','023c0511-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V2','023c0512-0000-4000-8000-000000000001'::uuid,'023c0513-0000-4000-8000-000000000001'::uuid,'023c0517-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C05-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V2-node-2'),'023c0518-0000-4000-8000-000000000001'::uuid,'023c0519-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C05-V2-REVIEW'),
    ('C06-V1','023c0600-0000-4000-8000-000000000006'::uuid,'T023-CONC-PACK-20261009-R1-C06','t023-conc-pack-20261009-r1-c06-resource','023c0601-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V1','023c0602-0000-4000-8000-000000000001'::uuid,'023c0603-0000-4000-8000-000000000001'::uuid,'023c0607-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C06-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V1-node-2'),'023c0608-0000-4000-8000-000000000001'::uuid,'023c0609-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V1-REVIEW'),
    ('C06-V2','023c0600-0000-4000-8000-000000000006'::uuid,'T023-CONC-PACK-20261009-R1-C06','t023-conc-pack-20261009-r1-c06-resource','023c0611-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V2','023c0612-0000-4000-8000-000000000001'::uuid,'023c0613-0000-4000-8000-000000000001'::uuid,'023c0617-0000-4000-8000-000000000001'::uuid,'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C06-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V2-node-2'),'023c0618-0000-4000-8000-000000000001'::uuid,'023c0619-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V2-REVIEW'),
    ('C06-V3','023c0600-0000-4000-8000-000000000006'::uuid,'T023-CONC-PACK-20261009-R1-C06','t023-conc-pack-20261009-r1-c06-resource','023c0621-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C06-V3','023c0622-0000-4000-8000-000000000001'::uuid,'023c0623-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C07-A-V1','023c0700-0000-4000-8000-000000000071'::uuid,'T023-CONC-PACK-20261009-R1-C07-A',null,'023c0701-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-A-V1','023c0702-0000-4000-8000-000000000001'::uuid,'023c0703-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C07-A-V2','023c0700-0000-4000-8000-000000000071'::uuid,'T023-CONC-PACK-20261009-R1-C07-A',null,'023c0711-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-A-V2','023c0712-0000-4000-8000-000000000001'::uuid,'023c0713-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C07-B-V1','023c0700-0000-4000-8000-000000000072'::uuid,'T023-CONC-PACK-20261009-R1-C07-B',null,'023c0781-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-B-V1','023c0782-0000-4000-8000-000000000001'::uuid,'023c0783-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null),
    ('C07-B-V2','023c0700-0000-4000-8000-000000000072'::uuid,'T023-CONC-PACK-20261009-R1-C07-B',null,'023c0791-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C07-B-V2','023c0792-0000-4000-8000-000000000001'::uuid,'023c0793-0000-4000-8000-000000000001'::uuid,null::uuid,null,null::uuid,null::uuid,null)
)
select
  'T023-CONC-PACK-20261009-R1' as fixture_pack_id,m.case_id,m.series_id,m.source_system,'MedicationRequest' as fhir_resource,
  m.resource_config_id,m.baseline_id,m.baseline_code,m.artifact_id,m.import_id,m.mapping_id,m.node_id,
  cc.baseline_candidate_context_id,cc.candidate_lifecycle_event_id,
  ac.baseline_activation_context_id,ac.active_lifecycle_event_id,
  rs.review_session_id,crs.session_state,m.validation_id,m.gate_id,
  case when m.case_id='C04-V1' then (select q.question_id from s2t_governance.governance_question q where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION') end as governance_question_id,
  b.created_at as baseline_created_at,a.captured_at as artifact_captured_at,i.started_at as import_started_at,i.completed_at as import_completed_at
from manifest m
left join s2t_fhir.baseline_version b on b.baseline_version_id=m.baseline_id
left join s2t_fhir.artifact a on a.artifact_id=m.artifact_id
left join s2t_fhir.import_run i on i.import_run_id=m.import_id
left join s2t_fhir.baseline_candidate_context cc on cc.baseline_version_id=m.baseline_id
left join s2t_fhir.baseline_activation_context ac on ac.baseline_version_id=m.baseline_id
left join s2t_fhir.review_session rs on rs.session_name=m.review_session_name and rs.baseline_version_id=m.baseline_id
left join s2t_fhir.candidate_review_session_state crs on crs.review_session_id=rs.review_session_id
order by m.case_id;

-- Worker-principal manifest with exact active capabilities.
select 'T023-CONC-PACK-20261009-R1' as fixture_pack_id,p.principal_id,p.external_issuer,p.external_subject,p.display_name,
  coalesce(array_agg(x.capability_code order by x.capability_code) filter(where x.capability_code is not null),'{}'::text[]) as active_capabilities
from s2t_fhir.principal p
left join lateral (
  select a.capability_code from s2t_fhir.baseline_action_authorization a where a.principal_id=p.principal_id and a.revoked_at is null and a.effective_at<=transaction_timestamp()
  union all
  select a.capability_code from s2t_fhir.review_actor_authorization a where a.principal_id=p.principal_id and a.revoked_at is null and a.effective_at<=transaction_timestamp()
) x on true
where p.principal_id in (
  '023c01a0-0000-4000-8000-000000000001','023c01b0-0000-4000-8000-000000000001','023c02a0-0000-4000-8000-000000000001','023c02b0-0000-4000-8000-000000000001',
  '023c03a0-0000-4000-8000-000000000001','023c03b0-0000-4000-8000-000000000001','023c04a0-0000-4000-8000-000000000001','023c04b0-0000-4000-8000-000000000001',
  '023c05a0-0000-4000-8000-000000000001','023c05b0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001','023c06b0-0000-4000-8000-000000000001',
  '023c07a0-0000-4000-8000-000000000001','023c07b0-0000-4000-8000-000000000001')
group by p.principal_id,p.external_issuer,p.external_subject,p.display_name
order by p.display_name;

-- End of read-only verification package.

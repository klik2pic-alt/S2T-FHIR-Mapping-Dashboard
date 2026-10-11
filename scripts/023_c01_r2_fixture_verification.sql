-- Read-only verification for T023-CONC-PACK-20261010-R2-C01.
-- No transaction control, temporary objects, DO blocks, or mutations.

with
ids as (
  select
    '023c0100-2026-4010-8000-000000000002'::uuid as series_id,
    array[
      '023c0101-2026-4010-8000-000000000002'::uuid,
      '023c0111-2026-4010-8000-000000000002'::uuid
    ] as baseline_ids,
    array[
      '023c0102-2026-4010-8000-000000000002'::uuid,
      '023c0112-2026-4010-8000-000000000002'::uuid
    ] as artifact_ids,
    array[
      '023c0104-2026-4010-8000-000000000002'::uuid,
      '023c0114-2026-4010-8000-000000000002'::uuid
    ] as baseline_artifact_ids,
    array[
      '023c0103-2026-4010-8000-000000000002'::uuid,
      '023c0113-2026-4010-8000-000000000002'::uuid
    ] as import_ids
),
state as (
  select
    (select count(*)
     from s2t_fhir.baseline_series s
     join s2t_fhir.reference_value bt
       on bt.reference_value_id = s.baseline_type_value_id
     join s2t_fhir.reference_domain d
       on d.reference_domain_id = bt.reference_domain_id
     cross join ids
     where s.baseline_series_id = ids.series_id
       and s.source_system = 'T023-CONC-PACK-20261010-R2-C01'
       and s.fhir_resource = 'MedicationRequest'
       and d.domain_code = 'BASELINE_TYPE'
       and bt.value_code = 'HUMAN_WORKING_DRAFT') as series_count,
    (select count(*) from s2t_fhir.baseline_version b, ids
     where b.baseline_series_id = ids.series_id) as series_baseline_count,
    (select count(*) from s2t_fhir.baseline_version b, ids
     where b.baseline_series_id = ids.series_id
       and not b.is_gold_standard
       and b.import_specification_version = 'T023-CONC-PACK-20261010-R2-C01-v1'
       and (b.baseline_version_id, b.baseline_code, b.version_label,
            b.created_by_principal_id) in (
         ('023c0101-2026-4010-8000-000000000002'::uuid,
          'T023-CONC-PACK-20261010-R2-C01-A',
          'T023-CONC-PACK-20261010-R2-C01-A',
          '023c01a0-0000-4000-8000-000000000001'::uuid),
         ('023c0111-2026-4010-8000-000000000002'::uuid,
          'T023-CONC-PACK-20261010-R2-C01-B',
          'T023-CONC-PACK-20261010-R2-C01-B',
          '023c01b0-0000-4000-8000-000000000001'::uuid)
       )) as exact_baseline_count,
    (select count(*)
     from s2t_fhir.artifact a
     where a.media_type = 'application/test'
       and a.byte_size = 1
       and (
         (a.artifact_id = '023c0102-2026-4010-8000-000000000002'
          and a.physical_filename = 'T023-CONC-PACK-20261010-R2-C01-A.xlsx'
          and a.created_by_principal_id = '023c01a0-0000-4000-8000-000000000001'
          and a.sha256_digest = decode(
            md5('T023-CONC-PACK-20261010-R2-C01-A-artifact-1') ||
            md5('T023-CONC-PACK-20261010-R2-C01-A-artifact-2'), 'hex'))
         or
         (a.artifact_id = '023c0112-2026-4010-8000-000000000002'
          and a.physical_filename = 'T023-CONC-PACK-20261010-R2-C01-B.xlsx'
          and a.created_by_principal_id = '023c01b0-0000-4000-8000-000000000001'
          and a.sha256_digest = decode(
            md5('T023-CONC-PACK-20261010-R2-C01-B-artifact-1') ||
            md5('T023-CONC-PACK-20261010-R2-C01-B-artifact-2'), 'hex'))
       )) as artifact_count,
    (select count(*)
     from s2t_fhir.baseline_artifact ba
     join s2t_fhir.reference_value role
       on role.reference_value_id = ba.artifact_role_value_id
     join s2t_fhir.reference_domain d
       on d.reference_domain_id = role.reference_domain_id
     cross join ids
     where (ba.baseline_artifact_id, ba.baseline_version_id, ba.artifact_id,
            ba.created_by_principal_id) in (
       ('023c0104-2026-4010-8000-000000000002'::uuid,
        '023c0101-2026-4010-8000-000000000002'::uuid,
        '023c0102-2026-4010-8000-000000000002'::uuid,
        '023c01a0-0000-4000-8000-000000000001'::uuid),
       ('023c0114-2026-4010-8000-000000000002'::uuid,
        '023c0111-2026-4010-8000-000000000002'::uuid,
        '023c0112-2026-4010-8000-000000000002'::uuid,
        '023c01b0-0000-4000-8000-000000000001'::uuid)
     )
       and d.domain_code = 'ARTIFACT_ROLE'
       and role.value_code = 'AUTHORITATIVE_SOURCE') as authoritative_artifact_count,
    (select count(*)
     from s2t_fhir.import_run i
     join s2t_fhir.reference_value status
       on status.reference_value_id = i.terminal_status_value_id
     join s2t_fhir.reference_domain d
       on d.reference_domain_id = status.reference_domain_id
     cross join ids
     where i.completed_at is not null
       and i.import_specification_version = 'T023-CONC-PACK-20261010-R2-C01-v1'
       and i.importer_version = 'T023-CONC-PACK-20261010-R2-C01-importer'
       and (
         (i.import_run_id = '023c0103-2026-4010-8000-000000000002'
          and i.baseline_version_id = '023c0101-2026-4010-8000-000000000002'
          and i.artifact_id = '023c0102-2026-4010-8000-000000000002'
          and i.actor_principal_id = '023c01a0-0000-4000-8000-000000000001'
          and i.configuration_digest = decode(
            md5('T023-CONC-PACK-20261010-R2-C01-A-config-1') ||
            md5('T023-CONC-PACK-20261010-R2-C01-A-config-2'), 'hex'))
         or
         (i.import_run_id = '023c0113-2026-4010-8000-000000000002'
          and i.baseline_version_id = '023c0111-2026-4010-8000-000000000002'
          and i.artifact_id = '023c0112-2026-4010-8000-000000000002'
          and i.actor_principal_id = '023c01b0-0000-4000-8000-000000000001'
          and i.configuration_digest = decode(
            md5('T023-CONC-PACK-20261010-R2-C01-B-config-1') ||
            md5('T023-CONC-PACK-20261010-R2-C01-B-config-2'), 'hex'))
       )
       and d.domain_code = 'IMPORT_RUN_STATUS'
       and status.value_code = 'COMMITTED') as committed_import_count,
    (select count(*) from s2t_fhir.principal p
     where (p.principal_id, p.external_subject) in (
       ('023c01a0-0000-4000-8000-000000000001'::uuid,'023c01a1-0000-4000-8000-000000000001'),
       ('023c01b0-0000-4000-8000-000000000001'::uuid,'023c01b1-0000-4000-8000-000000000001')
     ) and p.external_issuer = 'supabase-auth' and p.disabled_at is null) as worker_count,
    (select count(*) from s2t_fhir.baseline_action_authorization a
     where a.principal_id in (
       '023c01a0-0000-4000-8000-000000000001',
       '023c01b0-0000-4000-8000-000000000001'
     ) and a.capability_code = 'S2T_BASELINE_UPLOAD'
       and a.effective_at <= transaction_timestamp()
       and a.revoked_at is null) as upload_authorization_count,
    (select count(*) from s2t_fhir.baseline_lifecycle_event e, ids
     where e.baseline_version_id = any(ids.baseline_ids)) as lifecycle_event_count,
    (select count(*) from s2t_fhir.baseline_candidate_context c, ids
     where c.baseline_version_id = any(ids.baseline_ids)) as candidate_context_count,
    (select count(*) from s2t_fhir.baseline_activation_context a, ids
     where a.baseline_version_id = any(ids.baseline_ids)
        or a.prior_active_baseline_version_id = any(ids.baseline_ids)) as active_context_count,
    (select count(*) from s2t_fhir.baseline_relationship r, ids
     where r.from_baseline_version_id = any(ids.baseline_ids)
        or r.to_baseline_version_id = any(ids.baseline_ids)) as relationship_count,
    (select count(*) from s2t_fhir.review_session r, ids
     where r.baseline_version_id = any(ids.baseline_ids)) as review_session_count,
    (select count(*) from s2t_fhir.mapping_review_event r, ids
     where r.baseline_version_id = any(ids.baseline_ids)) as mapping_review_event_count,
    (select count(*) from s2t_fhir.mapping_record m, ids
     where m.baseline_version_id = any(ids.baseline_ids)) as mapping_record_count,
    (select count(*) from s2t_fhir.import_candidate_row r, ids
     where r.import_run_id = any(ids.import_ids)) as import_candidate_row_count,
    (select count(*) from s2t_fhir.validation_run v, ids
     where v.import_run_id = any(ids.import_ids)) as validation_run_count,
    (select count(*) from s2t_fhir.release_gate_evaluation g, ids
     where g.baseline_version_id = any(ids.baseline_ids)) as release_gate_count,
    (select count(*) from s2t_governance.governance_mapping_link l, ids
     where l.baseline_version_id = any(ids.baseline_ids)) as governance_link_count,
    (select count(*) from s2t_governance.governance_question q
     where q.title like 'T023-CONC-PACK-20261010-R2-C01%') as governance_question_count
),
fingerprint as (
  select md5(pg_catalog.concat_ws('|',
    series_count, series_baseline_count, exact_baseline_count, artifact_count,
    authoritative_artifact_count, committed_import_count, worker_count,
    upload_authorization_count, lifecycle_event_count, candidate_context_count,
    active_context_count, relationship_count, review_session_count,
    mapping_review_event_count, mapping_record_count, import_candidate_row_count,
    validation_run_count, release_gate_count, governance_link_count,
    governance_question_count,
    '023c0100-2026-4010-8000-000000000002',
    '023c0101-2026-4010-8000-000000000002',
    '023c0111-2026-4010-8000-000000000002',
    '023c0102-2026-4010-8000-000000000002',
    '023c0112-2026-4010-8000-000000000002',
    '023c0104-2026-4010-8000-000000000002',
    '023c0114-2026-4010-8000-000000000002',
    '023c0103-2026-4010-8000-000000000002',
    '023c0113-2026-4010-8000-000000000002'
  )) as fixture_fingerprint
  from state
),
checks(check_name, expected_count, actual_count) as (
  select 'exact series', 1, series_count from state union all
  select 'exactly two baselines in series', 2, series_baseline_count from state union all
  select 'two exact unpublished baselines', 2, exact_baseline_count from state union all
  select 'two exact artifacts', 2, artifact_count from state union all
  select 'one authoritative artifact per baseline', 2, authoritative_artifact_count from state union all
  select 'one committed import per baseline', 2, committed_import_count from state union all
  select 'existing active worker principals', 2, worker_count from state union all
  select 'existing active upload authorizations', 2, upload_authorization_count from state union all
  select 'lifecycle events', 0, lifecycle_event_count from state union all
  select 'Candidate contexts', 0, candidate_context_count from state union all
  select 'ACTIVE contexts', 0, active_context_count from state union all
  select 'baseline relationships', 0, relationship_count from state union all
  select 'review sessions', 0, review_session_count from state union all
  select 'mapping review events', 0, mapping_review_event_count from state union all
  select 'mapping records', 0, mapping_record_count from state union all
  select 'import candidate rows', 0, import_candidate_row_count from state union all
  select 'validation runs', 0, validation_run_count from state union all
  select 'release gates', 0, release_gate_count from state union all
  select 'governance links', 0, governance_link_count from state union all
  select 'tagged governance questions', 0, governance_question_count from state
)
select
  'C01_R2_SEED'::text as section,
  check_name,
  expected_count,
  actual_count,
  case when actual_count = expected_count then 'PASS' else 'FAIL' end as status,
  fingerprint.fixture_fingerprint
from checks
cross join fingerprint
order by check_name;

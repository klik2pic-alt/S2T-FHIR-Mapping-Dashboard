-- F4C.7 support/read-only diagnostic; this is not a migration.
-- Historical F4C.7 completion-conflict investigation tool.
-- Safe for TEST read-only diagnostics only.
-- Safe only for read-only diagnostics in TEST with a role that can read s2t_fhir.
-- This statement invokes no Candidate-import service helper.

with
diagnostic_target as (
  select
    'ef7d9ed5-08fa-46d8-90b8-44904e4ab2cd'::uuid
      as candidate_import_request_id,
    '54f0b83d-762a-4318-bff9-1eb682bfb70d'::uuid
      as expected_validation_attempt_id,
    '9fd413a1-2697-4101-b4ab-e8d293cb9db2'::uuid
      as expected_correlation_id,
    '766d1b1e31d00eb6931d70db1ed84ae87c58b554a3e02dabc319497c42696e05'::text
      as expected_artifact_sha256
),
request_context as (
  select
    target.*,
    request.current_state,
    request.artifact_id,
    request.baseline_series_id,
    request.baseline_version_id,
    request.import_run_id,
    request.validation_run_id,
    request.validation_attempt_id,
    request.validation_lease_expires_at,
    request.created_at as request_created_at,
    request.updated_at as request_updated_at,
    artifact.byte_size as artifact_byte_size,
    pg_catalog.encode(artifact.sha256_digest, 'hex') as artifact_sha256,
    baseline.baseline_series_id as linked_baseline_series_id,
    import_run.baseline_version_id as import_baseline_version_id,
    import_run.artifact_id as import_artifact_id,
    import_run.started_at as import_started_at,
    import_run.completed_at as import_completed_at,
    import_status.value_code as import_terminal_status
  from diagnostic_target target
  left join s2t_fhir.candidate_import_request request
    on request.candidate_import_request_id = target.candidate_import_request_id
  left join s2t_fhir.artifact artifact
    on artifact.artifact_id = request.artifact_id
  left join s2t_fhir.baseline_version baseline
    on baseline.baseline_version_id = request.baseline_version_id
  left join s2t_fhir.import_run import_run
    on import_run.import_run_id = request.import_run_id
  left join s2t_fhir.reference_value import_status
    on import_status.reference_value_id = import_run.terminal_status_value_id
),
batch_rollup as (
  select
    pg_catalog.count(*) as batch_count,
    pg_catalog.count(*) filter (
      where batch.validation_attempt_id = context.validation_attempt_id
    ) as current_attempt_batch_count,
    coalesce(pg_catalog.sum(batch.row_count) filter (
      where batch.validation_attempt_id = context.validation_attempt_id
    ), 0)::bigint as current_attempt_staged_rows,
    pg_catalog.min(batch.batch_number) filter (
      where batch.validation_attempt_id = context.validation_attempt_id
    ) as current_attempt_minimum_batch_number,
    pg_catalog.max(batch.batch_number) filter (
      where batch.validation_attempt_id = context.validation_attempt_id
    ) as current_attempt_maximum_batch_number,
    pg_catalog.max(batch.staged_at) filter (
      where batch.validation_attempt_id = context.validation_attempt_id
    ) as current_attempt_last_staged_at,
    pg_catalog.count(*) filter (
      where batch.validation_attempt_id = context.validation_attempt_id
        and batch.correlation_id = context.expected_correlation_id
    ) as expected_correlation_batch_count
  from request_context context
  left join s2t_fhir.candidate_import_staging_batch batch
    on batch.candidate_import_request_id = context.candidate_import_request_id
  group by context.validation_attempt_id, context.expected_correlation_id
),
row_rollup as (
  select
    pg_catalog.count(candidate.import_candidate_row_id) as candidate_count,
    pg_catalog.count(candidate.import_candidate_row_id) filter (
      where disposition.value_code = 'ACCEPTED'
    ) as accepted_count,
    pg_catalog.count(candidate.import_candidate_row_id) filter (
      where disposition.value_code = 'QUARANTINED'
    ) as quarantined_count
  from request_context context
  left join s2t_fhir.import_candidate_row candidate
    on candidate.import_run_id = context.import_run_id
  left join s2t_fhir.reference_value disposition
    on disposition.reference_value_id = candidate.candidate_disposition_value_id
),
mapping_rollup as (
  select
    pg_catalog.count(mapping.mapping_record_id) as mapping_count,
    pg_catalog.count(element.mapping_record_id) as element_mapping_count,
    pg_catalog.count(status.mapping_record_id) as status_mapping_rule_count,
    pg_catalog.count(guidance.mapping_record_id) as governance_guidance_count
  from request_context context
  left join s2t_fhir.mapping_record mapping
    on mapping.baseline_version_id = context.baseline_version_id
  left join s2t_fhir.element_mapping element
    on element.mapping_record_id = mapping.mapping_record_id
  left join s2t_fhir.status_mapping_rule status
    on status.mapping_record_id = mapping.mapping_record_id
  left join s2t_fhir.governance_guidance guidance
    on guidance.mapping_record_id = mapping.mapping_record_id
),
artifact_rollup as (
  select
    pg_catalog.count(distinct request.candidate_import_request_id) filter (
      where request.candidate_import_request_id
        <> context.candidate_import_request_id
    ) as other_requests_sharing_artifact,
    pg_catalog.count(distinct validation.import_run_id)
      as validation_runs_on_artifact,
    pg_catalog.count(distinct manifest.artifact_sheet_manifest_id)
      as existing_manifest_count,
    pg_catalog.count(distinct manifest.artifact_sheet_manifest_id) filter (
      where manifest.created_at < context.request_created_at
    ) as manifest_count_predating_request,
    coalesce(
      pg_catalog.jsonb_agg(
        distinct pg_catalog.jsonb_build_object(
          'sheetName', manifest.sheet_name,
          'sheetOrder', manifest.sheet_order,
          'candidateRowCount', manifest.candidate_row_count,
          'createdAt', manifest.created_at
        )
      ) filter (where manifest.artifact_sheet_manifest_id is not null),
      '[]'::jsonb
    ) as existing_manifests
  from request_context context
  left join s2t_fhir.candidate_import_request request
    on request.artifact_id = context.artifact_id
  left join s2t_fhir.artifact_sheet_manifest manifest
    on manifest.artifact_id = context.artifact_id
  left join s2t_fhir.validation_run validation
    on validation.artifact_id = context.artifact_id
  group by context.candidate_import_request_id, context.request_created_at
),
event_rollup as (
  select
    pg_catalog.count(*) filter (
      where event.event_code = 'ARTIFACT_REUSED'
    ) as artifact_reused_event_count,
    pg_catalog.count(*) filter (
      where event.event_code = 'VALIDATION_RECLAIMED'
        and event.correlation_id = context.expected_correlation_id
    ) as expected_reclaim_event_count,
    pg_catalog.count(*) filter (
      where event.event_code in ('VALIDATION_COMPLETED', 'VALIDATION_FAILED')
    ) as validation_terminal_event_count,
    coalesce(pg_catalog.max(event.sequence_number), 0) as maximum_event_sequence
  from request_context context
  left join s2t_fhir.candidate_import_request_event event
    on event.candidate_import_request_id = context.candidate_import_request_id
  group by context.expected_correlation_id
),
completion_object_rollup as (
  select
    pg_catalog.count(distinct validation.validation_run_id)
      as current_import_validation_run_count,
    pg_catalog.count(distinct metric.import_run_metric_id)
      as current_import_metric_count,
    pg_catalog.count(distinct finding.validation_finding_id)
      as current_import_finding_count,
    coalesce(
      pg_catalog.jsonb_agg(
        distinct pg_catalog.jsonb_build_object(
          'validationRunId', validation.validation_run_id,
          'executionFingerprint',
            pg_catalog.encode(validation.execution_fingerprint, 'hex'),
          'candidateCount', validation.candidate_count,
          'acceptedCount', validation.accepted_count,
          'warningCount', validation.warning_count,
          'errorCount', validation.error_count,
          'quarantinedCount', validation.quarantined_count,
          'completedAt', validation.completed_at
        )
      ) filter (where validation.validation_run_id is not null),
      '[]'::jsonb
    ) as current_import_validation_runs
  from request_context context
  left join s2t_fhir.validation_run validation
    on validation.import_run_id = context.import_run_id
  left join s2t_fhir.import_run_metric metric
    on metric.import_run_id = context.import_run_id
  left join s2t_fhir.validation_finding finding
    on finding.validation_run_id = validation.validation_run_id
),
reference_rollup as (
  select
    pg_catalog.count(*) filter (
      where domain.domain_code = 'VALIDATION_OUTCOME'
        and value.value_code in ('PASS', 'PASS_WITH_WARNINGS', 'FAIL')
    ) as validation_outcome_reference_count,
    (
      select pg_catalog.count(*)
      from s2t_fhir.validation_ruleset ruleset
      where ruleset.ruleset_code = 'CATO-MEDICATIONREQUEST-XLSX'
        and ruleset.version_label = 'v1'
    ) as expected_ruleset_count
  from s2t_fhir.reference_value value
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = value.reference_domain_id
),
assessment as (
  select
    context.*,
    batches.*,
    rows.*,
    mappings.*,
    artifacts.*,
    events.*,
    objects.*,
    expected_refs.expected_ruleset_count,
    expected_refs.validation_outcome_reference_count,
    case
      when context.current_state is null then 'REQUEST_NOT_FOUND'
      when context.artifact_sha256 is distinct from
           context.expected_artifact_sha256 then 'ARTIFACT_DIGEST_MISMATCH'
      when context.validation_attempt_id is distinct from
           context.expected_validation_attempt_id then 'ATTEMPT_MISMATCH'
      when context.current_state <> 'VALIDATING' then 'STATE_MISMATCH'
      when artifacts.existing_manifest_count > 0
       and events.artifact_reused_event_count > 0
       and objects.current_import_validation_run_count = 0
        then 'ARTIFACT_MANIFEST_UNIQUE_CONFLICT_SUPPORTED'
      when objects.current_import_validation_run_count > 0
        then 'VALIDATION_RUN_UNIQUE_CONFLICT_POSSIBLE'
      when context.validation_lease_expires_at
           <= batches.current_attempt_last_staged_at
        then 'LEASE_EXPIRED_BEFORE_STAGING_FINISHED'
      else 'EXACT_23505_SOURCE_NOT_PROVEN'
    end as conflict_assessment
  from request_context context
  cross join batch_rollup batches
  cross join row_rollup rows
  cross join mapping_rollup mappings
  cross join artifact_rollup artifacts
  cross join event_rollup events
  cross join completion_object_rollup objects
  cross join reference_rollup expected_refs
),
output_rows as (
  select
    1 as result_order,
    'completion_guard'::text as result_set,
    pg_catalog.jsonb_build_object(
      'requestId', candidate_import_request_id,
      'currentState', current_state,
      'expectedValidationAttemptId', expected_validation_attempt_id,
      'persistedValidationAttemptId', validation_attempt_id,
      'attemptMatches',
        validation_attempt_id is not distinct from expected_validation_attempt_id,
      'validationLeaseExpiresAt', validation_lease_expires_at,
      'lastCurrentAttemptBatchStagedAt', current_attempt_last_staged_at,
      'leaseWasActiveAtLastBatchCommit',
        validation_lease_expires_at > current_attempt_last_staged_at,
      'requestUpdatedAt', request_updated_at
    ) as detail
  from assessment

  union all

  select
    2,
    'request_links',
    pg_catalog.jsonb_build_object(
      'artifactId', artifact_id,
      'expectedArtifactSha256', expected_artifact_sha256,
      'persistedArtifactSha256', artifact_sha256,
      'artifactDigestMatches', artifact_sha256 = expected_artifact_sha256,
      'artifactByteSize', artifact_byte_size,
      'baselineSeriesId', baseline_series_id,
      'baselineVersionId', baseline_version_id,
      'baselineSeriesMatchesRequest',
        linked_baseline_series_id = baseline_series_id,
      'importRunId', import_run_id,
      'importBaselineMatchesRequest',
        import_baseline_version_id = baseline_version_id,
      'importArtifactMatchesRequest', import_artifact_id = artifact_id,
      'importStartedAt', import_started_at,
      'importCompletedAt', import_completed_at,
      'importTerminalStatus', import_terminal_status
    )
  from assessment

  union all

  select
    3,
    'staging_and_count_reconciliation',
    pg_catalog.jsonb_build_object(
      'batchCountAllAttempts', batch_count,
      'currentAttemptBatchCount', current_attempt_batch_count,
      'currentAttemptStagedRows', current_attempt_staged_rows,
      'currentAttemptMinimumBatchNumber', current_attempt_minimum_batch_number,
      'currentAttemptMaximumBatchNumber', current_attempt_maximum_batch_number,
      'expectedCorrelationBatchCount', expected_correlation_batch_count,
      'candidateCount', candidate_count,
      'acceptedCount', accepted_count,
      'quarantinedCount', quarantined_count,
      'mappingCount', mapping_count,
      'elementMappingCount', element_mapping_count,
      'statusMappingRuleCount', status_mapping_rule_count,
      'governanceGuidanceCount', governance_guidance_count,
      'candidateCountsReconcile',
        candidate_count = accepted_count + quarantined_count,
      'mappingCountReconciles', mapping_count = accepted_count
    )
  from assessment

  union all

  select
    4,
    'artifact_reuse_and_manifest_collision',
    pg_catalog.jsonb_build_object(
      'artifactReusedEventCount', artifact_reused_event_count,
      'otherRequestsSharingArtifact', other_requests_sharing_artifact,
      'validationRunsOnArtifact', validation_runs_on_artifact,
      'existingManifestCount', existing_manifest_count,
      'manifestCountPredatingRequest', manifest_count_predating_request,
      'existingManifests', existing_manifests,
      'completionInsertIsNotConflictSafe', true,
      'relevantUniqueConstraints', pg_catalog.jsonb_build_array(
        'artifact_sheet_name_uq (artifact_id, sheet_name)',
        'artifact_sheet_order_uq (artifact_id, sheet_order)'
      )
    )
  from assessment

  union all

  select
    5,
    'other_completion_conflict_evidence',
    pg_catalog.jsonb_build_object(
      'requestValidationRunId', validation_run_id,
      'currentImportValidationRunCount', current_import_validation_run_count,
      'currentImportValidationRuns', current_import_validation_runs,
      'currentImportFindingCount', current_import_finding_count,
      'currentImportMetricCount', current_import_metric_count,
      'validationTerminalEventCount', validation_terminal_event_count,
      'maximumEventSequence', maximum_event_sequence,
      'expectedReclaimEventCount', expected_reclaim_event_count,
      'expectedRulesetCount', expected_ruleset_count,
      'validationOutcomeReferenceCount', validation_outcome_reference_count
    )
  from assessment

  union all

  select
    6,
    'diagnostic_assessment',
    pg_catalog.jsonb_build_object(
      'assessment', conflict_assessment,
      'interpretation', case conflict_assessment
        when 'ARTIFACT_MANIFEST_UNIQUE_CONFLICT_SUPPORTED' then
          'The reused immutable artifact already has manifest rows; completion inserts them again and PostgreSQL raises 23505 before validation_run creation.'
        when 'VALIDATION_RUN_UNIQUE_CONFLICT_POSSIBLE' then
          'A validation_run already exists for this import; compare its execution fingerprint with the failed call if that fingerprint becomes available.'
        when 'LEASE_EXPIRED_BEFORE_STAGING_FINISHED' then
          'The persisted lease had expired no later than the final staging commit.'
        else
          'Persisted evidence does not identify one unique-violation source; retain the request and investigate without retrying validation.'
      end
    )
  from assessment
)
select result_set, detail
from output_rows
order by result_order;

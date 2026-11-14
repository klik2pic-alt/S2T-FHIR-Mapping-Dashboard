-- F4C.7 support/read-only diagnostic; this is not a migration.
-- Historical F4C.7 worker-crash investigation tool.
-- Safe for TEST read-only diagnostics only.
-- Safe only for read-only diagnostics in TEST with a role that can read s2t_fhir.
-- Returns all seven sections in one result grid so the SQL Editor cannot hide
-- an earlier result set.

with
diagnostic_target as (
  select
    'ef7d9ed5-08fa-46d8-90b8-44904e4ab2cd'::uuid
      as candidate_import_request_id,
    293::bigint as expected_row_count,
    293::bigint as expected_accepted_count,
    0::bigint as expected_quarantined_count,
    238::bigint as expected_element_mapping_count,
    9::bigint as expected_status_mapping_rule_count,
    46::bigint as expected_governance_guidance_count
),
request_data as (
  select
    target.*,
    request.resource_config_id,
    request.baseline_series_id,
    request.uploader_principal_id,
    request.version_label,
    request.original_filename,
    request.declared_byte_size,
    request.idempotency_key,
    request.expected_candidate_baseline_version_id,
    request.expected_candidate_lifecycle_event_id,
    request.current_state,
    request.artifact_id,
    request.baseline_version_id,
    request.import_run_id,
    request.validation_run_id,
    request.published_candidate_lifecycle_event_id,
    request.validation_attempt_id,
    request.validation_lease_expires_at,
    request.last_error_code,
    request.last_error_reference,
    request.created_at as request_created_at,
    request.updated_at as request_updated_at,
    baseline.baseline_code,
    baseline.version_label as baseline_version_label,
    baseline.import_specification_version as baseline_import_specification_version,
    baseline.created_at as baseline_created_at,
    series.source_system,
    series.fhir_resource,
    artifact.physical_filename as artifact_physical_filename,
    artifact.original_or_upload_name as artifact_original_or_upload_name,
    artifact.byte_size as artifact_byte_size,
    pg_catalog.encode(artifact.sha256_digest, 'hex') as artifact_sha256,
    import_run.started_at as import_started_at,
    import_run.completed_at as import_completed_at,
    import_status.value_code as import_terminal_status,
    import_run.failure_summary as import_failure_summary,
    validation.started_at as validation_started_at,
    validation.completed_at as validation_completed_at,
    validation.candidate_count as validation_candidate_count,
    validation.accepted_count as validation_accepted_count,
    validation.warning_count as validation_warning_count,
    validation.error_count as validation_error_count,
    validation.quarantined_count as validation_quarantined_count,
    validation_outcome.value_code as validation_outcome
  from diagnostic_target target
  left join s2t_fhir.candidate_import_request request
    on request.candidate_import_request_id = target.candidate_import_request_id
  left join s2t_fhir.baseline_version baseline
    on baseline.baseline_version_id = request.baseline_version_id
  left join s2t_fhir.baseline_series series
    on series.baseline_series_id = request.baseline_series_id
  left join s2t_fhir.artifact artifact
    on artifact.artifact_id = request.artifact_id
  left join s2t_fhir.import_run import_run
    on import_run.import_run_id = request.import_run_id
  left join s2t_fhir.reference_value import_status
    on import_status.reference_value_id = import_run.terminal_status_value_id
  left join s2t_fhir.validation_run validation
    on validation.validation_run_id = request.validation_run_id
  left join s2t_fhir.reference_value validation_outcome
    on validation_outcome.reference_value_id = validation.outcome_value_id
),
baseline_artifact_rollup as (
  select
    pg_catalog.count(*) as link_count,
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'baselineArtifactId', link.baseline_artifact_id,
          'artifactId', link.artifact_id,
          'artifactRole', role.value_code,
          'createdAt', link.created_at
        ) order by link.created_at, link.baseline_artifact_id
      ),
      '[]'::jsonb
    ) as links
  from request_data request
  join s2t_fhir.baseline_artifact link
    on link.baseline_version_id = request.baseline_version_id
  left join s2t_fhir.reference_value role
    on role.reference_value_id = link.artifact_role_value_id
),
event_rollup as (
  select
    pg_catalog.count(*) as event_count,
    pg_catalog.count(*) filter (
      where event.event_code = 'VALIDATION_STARTED'
    ) as validation_started_count,
    pg_catalog.count(*) filter (
      where event.event_code = 'VALIDATION_RECLAIMED'
    ) as validation_reclaimed_count,
    pg_catalog.count(*) filter (
      where event.event_code in (
        'VALIDATION_COMPLETED', 'VALIDATION_FAILED', 'REQUEST_FAILED'
      )
    ) as validation_terminal_event_count
  from diagnostic_target target
  join s2t_fhir.candidate_import_request_event event
    on event.candidate_import_request_id = target.candidate_import_request_id
),
batch_rollup as (
  select
    pg_catalog.count(batch.candidate_import_staging_batch_id) as batch_count,
    pg_catalog.count(distinct batch.validation_attempt_id) as batch_attempt_count,
    coalesce(pg_catalog.sum(batch.row_count), 0)::bigint
      as all_attempt_declared_rows,
    coalesce(pg_catalog.sum(batch.row_count) filter (
      where batch.validation_attempt_id = request.validation_attempt_id
    ), 0)::bigint as current_attempt_declared_rows
  from request_data request
  left join s2t_fhir.candidate_import_staging_batch batch
    on batch.candidate_import_request_id = request.candidate_import_request_id
),
batch_attempt_rollup as (
  select
    batch.validation_attempt_id,
    pg_catalog.count(*) as batch_count,
    pg_catalog.count(distinct batch.batch_number) as distinct_batch_number_count,
    pg_catalog.min(batch.batch_number) as minimum_batch_number,
    pg_catalog.max(batch.batch_number) as maximum_batch_number,
    pg_catalog.sum(batch.row_count)::bigint as declared_row_count
  from diagnostic_target target
  join s2t_fhir.candidate_import_staging_batch batch
    on batch.candidate_import_request_id = target.candidate_import_request_id
  group by batch.validation_attempt_id
),
batch_attempt_summary as (
  select
    coalesce(pg_catalog.max(attempt.declared_row_count), 0)::bigint
      as maximum_single_attempt_declared_rows,
    pg_catalog.count(*) filter (
      where attempt.declared_row_count = target.expected_row_count
        and attempt.minimum_batch_number = 0
        and attempt.maximum_batch_number = attempt.batch_count - 1
        and attempt.distinct_batch_number_count = attempt.batch_count
    ) as complete_contiguous_attempt_count,
    pg_catalog.count(*) filter (
      where attempt.declared_row_count between 1 and target.expected_row_count - 1
        and attempt.minimum_batch_number = 0
        and attempt.maximum_batch_number = attempt.batch_count - 1
        and attempt.distinct_batch_number_count = attempt.batch_count
    ) as partial_contiguous_attempt_count
  from diagnostic_target target
  left join batch_attempt_rollup attempt on true
  group by target.expected_row_count
),
imported_row_rollup as (
  select
    pg_catalog.count(candidate.import_candidate_row_id) as imported_row_count,
    pg_catalog.count(candidate.import_candidate_row_id) filter (
      where disposition.value_code = 'ACCEPTED'
    ) as accepted_row_count,
    pg_catalog.count(candidate.import_candidate_row_id) filter (
      where disposition.value_code = 'QUARANTINED'
    ) as quarantined_row_count
  from request_data request
  left join s2t_fhir.import_candidate_row candidate
    on candidate.import_run_id = request.import_run_id
  left join s2t_fhir.reference_value disposition
    on disposition.reference_value_id = candidate.candidate_disposition_value_id
),
sheet_counts as (
  select
    candidate.source_sheet_name,
    pg_catalog.count(*) as row_count
  from request_data request
  join s2t_fhir.import_candidate_row candidate
    on candidate.import_run_id = request.import_run_id
  group by candidate.source_sheet_name
),
mapping_rollup as (
  select
    pg_catalog.count(mapping.mapping_record_id) as mapping_record_count,
    pg_catalog.count(distinct identity.logical_mapping_identity_id)
      as referenced_logical_identity_count,
    pg_catalog.count(element.mapping_record_id) as element_mapping_count,
    pg_catalog.count(status.mapping_record_id) as status_mapping_rule_count,
    pg_catalog.count(guidance.mapping_record_id) as governance_guidance_count,
    pg_catalog.count(mapping.mapping_record_id) filter (
      where element.mapping_record_id is null
        and status.mapping_record_id is null
        and guidance.mapping_record_id is null
    ) as mapping_rows_without_subtype_count,
    pg_catalog.count(mapping.mapping_record_id) filter (
      where pg_catalog.num_nonnulls(
        element.mapping_record_id,
        status.mapping_record_id,
        guidance.mapping_record_id
      ) > 1
    ) as mapping_rows_with_multiple_subtypes_count
  from request_data request
  left join s2t_fhir.import_candidate_row candidate
    on candidate.import_run_id = request.import_run_id
  left join s2t_fhir.mapping_record mapping
    on mapping.import_candidate_row_id = candidate.import_candidate_row_id
  left join s2t_fhir.logical_mapping_identity identity
    on identity.logical_mapping_identity_id = mapping.logical_mapping_identity_id
  left join s2t_fhir.element_mapping element
    on element.mapping_record_id = mapping.mapping_record_id
  left join s2t_fhir.status_mapping_rule status
    on status.mapping_record_id = mapping.mapping_record_id
  left join s2t_fhir.governance_guidance guidance
    on guidance.mapping_record_id = mapping.mapping_record_id
),
diagnostic as (
  select
    request.*,
    events.*,
    batches.*,
    attempt_summary.*,
    imported.*,
    mappings.*,
    case
      when request.resource_config_id is null then 'INCONCLUSIVE'
      when request.current_state in (
        'READY_TO_PUBLISH', 'PUBLISHED', 'VALIDATION_FAILED', 'FAILED', 'ABORTED'
      ) then 'TERMINAL_STATE'
      when request.current_state <> 'VALIDATING' then 'INCONCLUSIVE'
      when batches.batch_count = 0
       and imported.imported_row_count = 0
       and mappings.mapping_record_count = 0 then 'NO_STAGING_COMMITTED'
      when attempt_summary.complete_contiguous_attempt_count = 1
       and batches.batch_attempt_count = 1
       and imported.imported_row_count = request.expected_row_count
       and imported.accepted_row_count = request.expected_accepted_count
       and imported.quarantined_row_count = request.expected_quarantined_count
       and mappings.mapping_record_count = request.expected_accepted_count
       and mappings.referenced_logical_identity_count
         = request.expected_accepted_count
       and mappings.element_mapping_count = request.expected_element_mapping_count
       and mappings.status_mapping_rule_count
         = request.expected_status_mapping_rule_count
       and mappings.governance_guidance_count
         = request.expected_governance_guidance_count
       and mappings.mapping_rows_without_subtype_count = 0
       and mappings.mapping_rows_with_multiple_subtypes_count = 0
       and request.validation_run_id is null then 'FULL_STAGING_POSSIBLE'
      when attempt_summary.partial_contiguous_attempt_count = 1
       and batches.batch_attempt_count = 1
       and attempt_summary.maximum_single_attempt_declared_rows between 1
                                                               and request.expected_row_count - 1
       and imported.imported_row_count = attempt_summary.maximum_single_attempt_declared_rows
       and imported.accepted_row_count + imported.quarantined_row_count
         = imported.imported_row_count
       and mappings.mapping_record_count = imported.accepted_row_count
       and mappings.referenced_logical_identity_count
         = mappings.mapping_record_count
       and mappings.element_mapping_count
         + mappings.status_mapping_rule_count
         + mappings.governance_guidance_count = mappings.mapping_record_count
       and mappings.mapping_rows_without_subtype_count = 0
       and mappings.mapping_rows_with_multiple_subtypes_count = 0
       and request.validation_run_id is null then 'PARTIAL_STAGING_COMMITTED'
      else 'INCONCLUSIVE'
    end as classification,
    case
      when imported.imported_row_count = 0 then 'NO_IMPORTED_ROWS'
      when batches.batch_count = 0 then 'NO_BATCH_EVIDENCE_FOR_IMPORTED_ROWS'
      when imported.imported_row_count
         > attempt_summary.maximum_single_attempt_declared_rows
        then 'IMPORTED_ROWS_EXCEED_EVERY_SINGLE_ATTEMPT_BATCH_TOTAL'
      when attempt_summary.complete_contiguous_attempt_count = 1
       and imported.imported_row_count = request.expected_row_count
        then 'COUNTS_ALIGN_WITH_ONE_COMPLETE_ATTEMPT'
      when imported.imported_row_count
         = attempt_summary.maximum_single_attempt_declared_rows
        then 'COUNTS_ALIGN_WITH_ONE_ATTEMPT'
      else 'AMBIGUOUS_MULTI_ATTEMPT_OR_COUNT_MISMATCH'
    end as batch_evidence_alignment
  from request_data request
  cross join event_rollup events
  cross join batch_rollup batches
  cross join batch_attempt_summary attempt_summary
  cross join imported_row_rollup imported
  cross join mapping_rollup mappings
),
output_rows as (
  select
    1 as section_order,
    'request_summary'::text as result_set,
    0::bigint as item_order,
    pg_catalog.jsonb_build_object(
      'requestFound', diagnostic.resource_config_id is not null,
      'requestId', diagnostic.candidate_import_request_id,
      'resourceConfigId', diagnostic.resource_config_id,
      'baselineSeriesId', diagnostic.baseline_series_id,
      'sourceSystem', diagnostic.source_system,
      'fhirResource', diagnostic.fhir_resource,
      'uploaderPrincipalId', diagnostic.uploader_principal_id,
      'versionLabel', diagnostic.version_label,
      'originalFilename', diagnostic.original_filename,
      'declaredByteSize', diagnostic.declared_byte_size,
      'idempotencyKey', diagnostic.idempotency_key,
      'currentState', diagnostic.current_state,
      'artifactId', diagnostic.artifact_id,
      'artifactPhysicalFilename', diagnostic.artifact_physical_filename,
      'artifactOriginalOrUploadName', diagnostic.artifact_original_or_upload_name,
      'artifactByteSize', diagnostic.artifact_byte_size,
      'artifactSha256', diagnostic.artifact_sha256,
      'baselineVersionId', diagnostic.baseline_version_id,
      'baselineCode', diagnostic.baseline_code,
      'baselineVersionLabel', diagnostic.baseline_version_label,
      'baselineImportSpecificationVersion',
        diagnostic.baseline_import_specification_version,
      'baselineCreatedAt', diagnostic.baseline_created_at,
      'importRunId', diagnostic.import_run_id,
      'importStartedAt', diagnostic.import_started_at,
      'importCompletedAt', diagnostic.import_completed_at,
      'importTerminalStatus', diagnostic.import_terminal_status,
      'importFailureSummary', diagnostic.import_failure_summary,
      'validationRunId', diagnostic.validation_run_id,
      'validationStartedAt', diagnostic.validation_started_at,
      'validationCompletedAt', diagnostic.validation_completed_at,
      'validationCandidateCount', diagnostic.validation_candidate_count,
      'validationAcceptedCount', diagnostic.validation_accepted_count,
      'validationWarningCount', diagnostic.validation_warning_count,
      'validationErrorCount', diagnostic.validation_error_count,
      'validationQuarantinedCount', diagnostic.validation_quarantined_count,
      'validationOutcome', diagnostic.validation_outcome,
      'publishedCandidateLifecycleEventId',
        diagnostic.published_candidate_lifecycle_event_id,
      'expectedCandidateBaselineVersionId',
        diagnostic.expected_candidate_baseline_version_id,
      'expectedCandidateLifecycleEventId',
        diagnostic.expected_candidate_lifecycle_event_id,
      'lastErrorCode', diagnostic.last_error_code,
      'lastErrorReference', diagnostic.last_error_reference,
      'lastErrorMessage', null,
      'lastErrorMessagePersisted', false,
      'requestCreatedAt', diagnostic.request_created_at,
      'requestUpdatedAt', diagnostic.request_updated_at,
      'baselineArtifactLinkCount', artifacts.link_count,
      'baselineArtifactLinks', artifacts.links
    ) as detail
  from diagnostic
  cross join baseline_artifact_rollup artifacts

  union all

  select
    2,
    'lease_status',
    0,
    pg_catalog.jsonb_build_object(
      'requestId', diagnostic.candidate_import_request_id,
      'currentState', diagnostic.current_state,
      'validationAttemptId', diagnostic.validation_attempt_id,
      'validationLeaseExpiresAt', diagnostic.validation_lease_expires_at,
      'observedAt', pg_catalog.statement_timestamp(),
      'leaseIsExpired', case
        when diagnostic.validation_lease_expires_at is null then null
        else diagnostic.validation_lease_expires_at
          <= pg_catalog.statement_timestamp()
      end,
      'leaseStatus', case
        when diagnostic.validation_lease_expires_at is null then 'NO_LEASE'
        when diagnostic.validation_lease_expires_at
          <= pg_catalog.statement_timestamp() then 'EXPIRED'
        else 'ACTIVE'
      end
    )
  from diagnostic

  union all

  select
    3,
    'request_events',
    0,
    pg_catalog.jsonb_build_object(
      'summary', true,
      'eventCount', diagnostic.event_count,
      'validationStartedCount', diagnostic.validation_started_count,
      'validationReclaimedCount', diagnostic.validation_reclaimed_count,
      'validationCompletionOrFailureEventCount',
        diagnostic.validation_terminal_event_count
    )
  from diagnostic

  union all

  select
    3,
    'request_events',
    event.sequence_number::bigint,
    pg_catalog.jsonb_build_object(
      'summary', false,
      'sequenceNumber', event.sequence_number,
      'eventId', event.candidate_import_request_event_id,
      'eventCode', event.event_code,
      'fromState', event.from_state,
      'toState', event.to_state,
      'occurredAt', event.occurred_at,
      'recordedAt', event.recorded_at,
      'actorPrincipalId', event.actor_principal_id,
      'initiatingHumanPrincipalId', event.initiating_human_principal_id,
      'correlationId', event.correlation_id,
      'reason', event.reason,
      'errorCode', event.error_code,
      'detailSchemaId', event.detail_schema_id,
      'detailSchemaVersion', event.detail_schema_version,
      'detail', event.detail_json
    )
  from diagnostic_target target
  join s2t_fhir.candidate_import_request_event event
    on event.candidate_import_request_id = target.candidate_import_request_id

  union all

  select
    4,
    'staging_batches',
    0,
    pg_catalog.jsonb_build_object(
      'summary', true,
      'batchCount', diagnostic.batch_count,
      'attemptCountWithBatches', diagnostic.batch_attempt_count,
      'allAttemptDeclaredRows', diagnostic.all_attempt_declared_rows,
      'currentAttemptDeclaredRows', diagnostic.current_attempt_declared_rows,
      'maximumSingleAttemptDeclaredRows',
        diagnostic.maximum_single_attempt_declared_rows,
      'completeContiguousAttemptCount',
        diagnostic.complete_contiguous_attempt_count,
      'partialContiguousAttemptCount',
        diagnostic.partial_contiguous_attempt_count
    )
  from diagnostic

  union all

  select
    4,
    'staging_batches',
    1 + pg_catalog.row_number() over (
      order by batch.staged_at, batch.validation_attempt_id, batch.batch_number
    ),
    pg_catalog.jsonb_build_object(
      'summary', false,
      'stagingBatchId', batch.candidate_import_staging_batch_id,
      'validationAttemptId', batch.validation_attempt_id,
      'isCurrentAttempt',
        batch.validation_attempt_id = request.validation_attempt_id,
      'batchNumber', batch.batch_number,
      'rowCount', batch.row_count,
      'encodedByteSize', batch.encoded_byte_size,
      'batchDigestSha256', pg_catalog.encode(batch.batch_digest, 'hex'),
      'stagedAt', batch.staged_at,
      'serviceActorPrincipalId', batch.service_actor_principal_id,
      'correlationId', batch.correlation_id
    )
  from request_data request
  join s2t_fhir.candidate_import_staging_batch batch
    on batch.candidate_import_request_id = request.candidate_import_request_id

  union all

  select
    5,
    'imported_row_counts',
    0,
    pg_catalog.jsonb_build_object(
      'summary', true,
      'expectedRowsForThisWorkbook', diagnostic.expected_row_count,
      'expectedAcceptedRowsForThisWorkbook',
        diagnostic.expected_accepted_count,
      'expectedQuarantinedRowsForThisWorkbook',
        diagnostic.expected_quarantined_count,
      'importedRows', diagnostic.imported_row_count,
      'acceptedRows', diagnostic.accepted_row_count,
      'quarantinedRows', diagnostic.quarantined_row_count,
      'countBasedRowsBeyondAnySingleAttemptBatchTotal',
        greatest(
          diagnostic.imported_row_count
            - diagnostic.maximum_single_attempt_declared_rows,
          0
        ),
      'batchEvidenceAlignment', diagnostic.batch_evidence_alignment,
      'rowLevelBatchLinkAvailable', false,
      'interpretation',
        'import_candidate_row has no staging-batch foreign key; alignment is count-based per attempt'
    )
  from diagnostic

  union all

  select
    5,
    'imported_row_counts',
    1 + pg_catalog.row_number() over (order by sheet.source_sheet_name),
    pg_catalog.jsonb_build_object(
      'summary', false,
      'sourceSheetName', sheet.source_sheet_name,
      'rowCount', sheet.row_count
    )
  from sheet_counts sheet

  union all

  select
    6,
    'subtype_counts',
    0,
    pg_catalog.jsonb_build_object(
      'mappingRecords', diagnostic.mapping_record_count,
      'referencedLogicalIdentities',
        diagnostic.referenced_logical_identity_count,
      'elementMappings', diagnostic.element_mapping_count,
      'expectedElementMappings', diagnostic.expected_element_mapping_count,
      'statusMappingRules', diagnostic.status_mapping_rule_count,
      'expectedStatusMappingRules',
        diagnostic.expected_status_mapping_rule_count,
      'governanceGuidanceRows', diagnostic.governance_guidance_count,
      'expectedGovernanceGuidanceRows',
        diagnostic.expected_governance_guidance_count,
      'mappingRowsWithoutSubtype',
        diagnostic.mapping_rows_without_subtype_count,
      'mappingRowsWithMultipleSubtypes',
        diagnostic.mapping_rows_with_multiple_subtypes_count
    )
  from diagnostic

  union all

  select
    7,
    'diagnostic_classification',
    0,
    pg_catalog.jsonb_build_object(
      'classification', diagnostic.classification,
      'currentState', diagnostic.current_state,
      'expectedRowsForThisWorkbook', diagnostic.expected_row_count,
      'batchCount', diagnostic.batch_count,
      'attemptCountWithBatches', diagnostic.batch_attempt_count,
      'currentAttemptDeclaredRows', diagnostic.current_attempt_declared_rows,
      'maximumSingleAttemptDeclaredRows',
        diagnostic.maximum_single_attempt_declared_rows,
      'completeContiguousAttemptCount',
        diagnostic.complete_contiguous_attempt_count,
      'partialContiguousAttemptCount',
        diagnostic.partial_contiguous_attempt_count,
      'importedRows', diagnostic.imported_row_count,
      'acceptedRows', diagnostic.accepted_row_count,
      'quarantinedRows', diagnostic.quarantined_row_count,
      'mappingRecords', diagnostic.mapping_record_count,
      'subtypeRows', diagnostic.element_mapping_count
        + diagnostic.status_mapping_rule_count
        + diagnostic.governance_guidance_count,
      'validationRunId', diagnostic.validation_run_id,
      'validationStartedEventExists',
        diagnostic.validation_started_count > 0,
      'validationReclaimedEventExists',
        diagnostic.validation_reclaimed_count > 0,
      'validationCompletionOrFailureEventExists',
        diagnostic.validation_terminal_event_count > 0,
      'batchEvidenceAlignment', diagnostic.batch_evidence_alignment,
      'classificationScope',
        'Exact for terminal/no-staging states; partial/full labels require count and subtype alignment for the known 293-row workbook'
    )
  from diagnostic
)
select result_set, item_order, detail
from output_rows
order by section_order, item_order;

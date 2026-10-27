import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type {
  CandidateImportConfig,
  SheetManifestEntry,
  StagedRow,
  ValidationFinding,
} from "./contracts.ts";
import { mapDatabaseError } from "./errors.ts";
import { hexBytea } from "./normalization.ts";

async function rpc<T>(
  client: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
  requestId: string | null,
): Promise<T> {
  const { data, error } = await client.schema("s2t_fhir_api").rpc(name, args);
  if (error) throw mapDatabaseError(error, requestId);
  return data as T;
}

export function serviceClient(config: CandidateImportConfig): SupabaseClient {
  return createClient(config.supabaseUrl, config.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

export function beginImport(
  caller: SupabaseClient,
  input: {
    resourceConfigId: string;
    versionLabel: string;
    originalFilename: string;
    declaredByteSize: number;
    idempotencyKey: string;
    expectedCandidateBaselineVersionId: string | null;
    expectedCandidateLifecycleEventId: string | null;
  },
): Promise<Record<string, unknown>> {
  return rpc(caller, "begin_candidate_import", {
    p_resource_config_id: input.resourceConfigId,
    p_version_label: input.versionLabel,
    p_original_filename: input.originalFilename,
    p_declared_byte_size: input.declaredByteSize,
    p_idempotency_key: input.idempotencyKey,
    p_expected_candidate_baseline_version_id: input.expectedCandidateBaselineVersionId,
    p_expected_candidate_lifecycle_event_id: input.expectedCandidateLifecycleEventId,
  }, null);
}

export function getMyImport(
  caller: SupabaseClient,
  requestId: string,
): Promise<Record<string, unknown>> {
  return rpc(caller, "get_my_candidate_import", {
    p_candidate_import_request_id: requestId,
  }, requestId);
}

export function acceptUpload(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
  digest: string,
  byteSize: number,
  observedAt: string,
  correlationId: string,
): Promise<Record<string, unknown>> {
  return rpc(service, "_service_accept_candidate_import_upload", {
    p_request_id: requestId,
    p_sha256_digest: hexBytea(digest),
    p_byte_size: byteSize,
    p_media_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    p_observed_at: observedAt,
    p_service_actor_id: config.serviceActorId,
    p_correlation_id: correlationId,
  }, requestId);
}

export function beginValidation(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
  configurationDigest: string,
  validationAttemptId: string,
  leaseExpiresAt: string,
  correlationId: string,
): Promise<Record<string, unknown>> {
  return rpc(service, "_service_begin_candidate_import_validation", {
    p_request_id: requestId,
    p_parser_name: "exceljs",
    p_parser_version: "4.4.0",
    p_import_specification_version: config.spec,
    p_configuration_digest: hexBytea(configurationDigest),
    p_validation_attempt_id: validationAttemptId,
    p_lease_expires_at: leaseExpiresAt,
    p_service_actor_id: config.serviceActorId,
    p_correlation_id: correlationId,
  }, requestId);
}

export function stageBatch(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
  validationAttemptId: string,
  batchNumber: number,
  digest: string,
  rows: StagedRow[],
  correlationId: string,
): Promise<Record<string, unknown>> {
  return rpc(service, "_service_stage_candidate_import_batch", {
    p_request_id: requestId,
    p_validation_attempt_id: validationAttemptId,
    p_batch_number: batchNumber,
    p_batch_digest: hexBytea(digest),
    p_rows: rows,
    p_service_actor_id: config.serviceActorId,
    p_correlation_id: correlationId,
  }, requestId);
}

export function completeValidation(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
  validationAttemptId: string,
  sheetManifest: SheetManifestEntry[],
  findings: ValidationFinding[],
  summary: Record<string, number>,
  executionFingerprint: string,
  correlationId: string,
): Promise<Record<string, unknown>> {
  return rpc(service, "_service_complete_candidate_import_validation", {
    p_request_id: requestId,
    p_validation_attempt_id: validationAttemptId,
    p_sheet_manifest: sheetManifest,
    p_findings: findings,
    p_summary: summary,
    p_execution_fingerprint: hexBytea(executionFingerprint),
    p_service_actor_id: config.serviceActorId,
    p_correlation_id: correlationId,
  }, requestId);
}

export function failImport(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
  validationAttemptId: string,
  code: string,
  reference: string,
  safeMessage: string,
  correlationId: string,
): Promise<Record<string, unknown>> {
  return rpc(service, "_service_fail_candidate_import", {
    p_request_id: requestId,
    p_validation_attempt_id: validationAttemptId,
    p_error_code: code,
    p_error_reference: reference,
    p_safe_message: safeMessage,
    p_service_actor_id: config.serviceActorId,
    p_correlation_id: correlationId,
  }, requestId);
}

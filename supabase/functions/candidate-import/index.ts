import { type SupabaseClient } from "@supabase/supabase-js";
import { authenticateCaller } from "./lib/auth.ts";
import { createBatches } from "./lib/batching.ts";
import {
  BUCKET_DEFAULT,
  type CandidateImportConfig,
  MAX_COMPRESSED_DEFAULT,
  MAX_EXPANDED_DEFAULT,
  RESOURCE_CONFIG_ID,
  SPEC_VERSION,
} from "./lib/contracts.ts";
import {
  acceptUpload,
  beginImport,
  beginValidation,
  completeValidation,
  failImport,
  getMyImport,
  serviceClient,
  stageBatch,
} from "./lib/database.ts";
import { errorResponse, ImportError } from "./lib/errors.ts";
import { digestCanonical, normalizeText, sha256Hex } from "./lib/normalization.ts";
import { preflightOoxml } from "./lib/ooxml-preflight.ts";
import { configurationDigest, parseAndValidateWorkbook } from "./lib/parser.ts";
import { createUploadTarget, downloadObject } from "./lib/storage.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_JSON_BODY_BYTES = 16_384;
const LOCAL_FAILURE_CODES = new Set([
  "FILE_TYPE_INVALID",
  "FILE_SCHEMA_INVALID",
  "FILE_TOO_LARGE",
  "DUPLICATE_ROW_IDENTITY",
  "IMPORT_VALIDATION_FAILED",
  "ZERO_ACCEPTED_ROWS",
  "INTERNAL_IMPORT_ERROR",
]);

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

export function loadConfig(): CandidateImportConfig {
  const number = (name: string, fallback: number) => {
    const value = Deno.env.get(name);
    const parsed = value ? Number(value) : fallback;
    if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`Invalid ${name}`);
    return parsed;
  };
  const spec = Deno.env.get("CANDIDATE_IMPORT_SPEC") ?? SPEC_VERSION;
  if (spec !== SPEC_VERSION) {
    throw new Error("CANDIDATE_IMPORT_SPEC does not match the deployed contract");
  }
  const bucket = Deno.env.get("CANDIDATE_IMPORT_BUCKET") ?? BUCKET_DEFAULT;
  const maxCompressedBytes = number(
    "CANDIDATE_IMPORT_MAX_COMPRESSED_BYTES",
    MAX_COMPRESSED_DEFAULT,
  );
  const maxExpandedBytes = number("CANDIDATE_IMPORT_MAX_EXPANDED_BYTES", MAX_EXPANDED_DEFAULT);
  const serviceActorId = required("CANDIDATE_IMPORT_SERVICE_ACTOR_ID");
  if (
    bucket !== BUCKET_DEFAULT || maxCompressedBytes !== MAX_COMPRESSED_DEFAULT ||
    maxExpandedBytes !== MAX_EXPANDED_DEFAULT || !UUID.test(serviceActorId)
  ) {
    throw new Error("Candidate import runtime configuration does not match the frozen contract");
  }
  return {
    supabaseUrl: required("SUPABASE_URL"),
    anonKey: required("SUPABASE_ANON_KEY"),
    serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
    serviceActorId,
    bucket,
    spec,
    maxCompressedBytes,
    maxExpandedBytes,
  };
}

export function parseRoute(
  url: URL,
): { action: "begin" | "complete" | "validate" | "status"; requestId: string | null } {
  const parts = url.pathname.split("/").filter(Boolean);
  const marker = parts.lastIndexOf("candidate-import");
  const path = marker >= 0 ? parts.slice(marker + 1) : parts;
  if (path.length === 1 && path[0] === "begin") return { action: "begin", requestId: null };
  if (path.length === 1 && UUID.test(path[0])) return { action: "status", requestId: path[0] };
  if (path.length === 2 && UUID.test(path[0]) && path[1] === "complete-upload") {
    return { action: "complete", requestId: path[0] };
  }
  if (path.length === 2 && UUID.test(path[0]) && path[1] === "validate") {
    return { action: "validate", requestId: path[0] };
  }
  throw new ImportError("FILE_SCHEMA_INVALID", "Unknown Candidate import route.", false, 404);
}

async function jsonObject(request: Request): Promise<Record<string, unknown>> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new ImportError("FILE_SCHEMA_INVALID", "A JSON request body is required.");
  }
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_JSON_BODY_BYTES) {
    throw new ImportError("FILE_TOO_LARGE", "The request body exceeds the allowed size.");
  }
  try {
    const text = await request.text();
    if (new TextEncoder().encode(text).byteLength > MAX_JSON_BODY_BYTES) {
      throw new ImportError("FILE_TOO_LARGE", "The request body exceeds the allowed size.");
    }
    const value = JSON.parse(text);
    if (!value || Array.isArray(value) || typeof value !== "object") throw new Error();
    return value as Record<string, unknown>;
  } catch (error) {
    if (error instanceof ImportError) throw error;
    throw new ImportError("FILE_SCHEMA_INVALID", "The JSON request body is invalid.");
  }
}

function nullableUuid(value: unknown, field: string): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new ImportError("FILE_SCHEMA_INVALID", `${field} must be a UUID or null.`);
  }
  return value.toLowerCase();
}

export function validateBeginPayload(
  body: Record<string, unknown>,
  maxCompressedBytes: number,
) {
  const resourceConfigId = body.resourceConfigId;
  const versionLabel = typeof body.versionLabel === "string"
    ? normalizeText(body.versionLabel)
    : "";
  const originalFilename = typeof body.originalFilename === "string"
    ? body.originalFilename.trim()
    : "";
  const declaredByteSize = body.declaredByteSize;
  const idempotencyKey = body.idempotencyKey;
  const expectedBaseline = nullableUuid(
    body.expectedCandidateBaselineVersionId,
    "expectedCandidateBaselineVersionId",
  );
  const expectedEvent = nullableUuid(
    body.expectedCandidateLifecycleEventId,
    "expectedCandidateLifecycleEventId",
  );
  if (
    resourceConfigId !== RESOURCE_CONFIG_ID || !versionLabel || versionLabel.length > 120 ||
    /[\u0000-\u001f\u007f]/.test(versionLabel) || !/\.xlsx$/i.test(originalFilename) ||
    originalFilename.length > 255 || /[\u0000-\u001f\u007f/\\]/.test(originalFilename) ||
    !Number.isSafeInteger(declaredByteSize) || Number(declaredByteSize) < 1 ||
    Number(declaredByteSize) > maxCompressedBytes || typeof idempotencyKey !== "string" ||
    !UUID.test(idempotencyKey) || (expectedBaseline === null) !== (expectedEvent === null)
  ) {
    throw new ImportError("FILE_SCHEMA_INVALID", "Candidate import request fields are invalid.");
  }
  return {
    resourceConfigId,
    versionLabel,
    originalFilename,
    declaredByteSize: Number(declaredByteSize),
    idempotencyKey: idempotencyKey.toLowerCase(),
    expectedCandidateBaselineVersionId: expectedBaseline,
    expectedCandidateLifecycleEventId: expectedEvent,
  };
}

async function handleBegin(
  request: Request,
  caller: SupabaseClient,
  service: SupabaseClient,
  config: CandidateImportConfig,
) {
  const body = await jsonObject(request);
  const result = await beginImport(
    caller,
    validateBeginPayload(body, config.maxCompressedBytes),
  );
  const requestId = String(result.requestId ?? "");
  if (!UUID.test(requestId)) throw new ImportError("INTERNAL_IMPORT_ERROR");
  const upload = await createUploadTarget(service, config, requestId);
  return { request: result, upload };
}

async function recordFailure(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
  attemptId: string,
  correlationId: string,
  error: ImportError,
): Promise<void> {
  if (!LOCAL_FAILURE_CODES.has(error.code)) return;
  try {
    await failImport(
      service,
      config,
      requestId,
      attemptId,
      error.code,
      error.reference,
      error.message,
      correlationId,
    );
  } catch (failureError) {
    console.error(
      JSON.stringify({
        route: "candidate-import",
        requestId,
        correlationId,
        category: "failure-recording",
        errorCode: error.code,
        failureType: failureError instanceof Error ? failureError.name : "unknown",
      }),
    );
  }
}

async function handleComplete(
  caller: SupabaseClient,
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
) {
  const status = await getMyImport(caller, requestId);
  if (status.state !== "AWAITING_UPLOAD") {
    throw new ImportError(
      "IMPORT_CONFLICT",
      "Upload completion requires AWAITING_UPLOAD.",
      false,
      409,
      requestId,
    );
  }
  const correlationId = crypto.randomUUID();
  const failureAttemptId = crypto.randomUUID();
  try {
    const bytes = await downloadObject(service, config, requestId);
    preflightOoxml(bytes, config.maxCompressedBytes, config.maxExpandedBytes);
    const digest = await sha256Hex(bytes);
    await acceptUpload(
      service,
      config,
      requestId,
      digest,
      bytes.byteLength,
      new Date().toISOString(),
      correlationId,
    );
    return { request: await getMyImport(caller, requestId) };
  } catch (error) {
    const safe = error instanceof ImportError
      ? error
      : new ImportError("INTERNAL_IMPORT_ERROR", undefined, false, 500, requestId);
    await recordFailure(service, config, requestId, failureAttemptId, correlationId, safe);
    throw safe;
  }
}

async function handleValidate(
  caller: SupabaseClient,
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
) {
  const status = await getMyImport(caller, requestId);
  if (status.state !== "UPLOADED" && status.state !== "VALIDATING") {
    throw new ImportError(
      "IMPORT_CONFLICT",
      "Validation requires UPLOADED or reclaimable VALIDATING state.",
      false,
      409,
      requestId,
    );
  }
  const validationAttemptId = crypto.randomUUID();
  const correlationId = crypto.randomUUID();
  let validationStarted = false;
  try {
    const configDigest = await configurationDigest();
    const leaseExpiresAt = new Date(Date.now() + 15 * 60_000).toISOString();
    await beginValidation(
      service,
      config,
      requestId,
      configDigest,
      validationAttemptId,
      leaseExpiresAt,
      correlationId,
    );
    validationStarted = true;
    const bytes = await downloadObject(service, config, requestId);
    preflightOoxml(bytes, config.maxCompressedBytes, config.maxExpandedBytes);
    const result = await parseAndValidateWorkbook(bytes, {
      requestId,
      validationAttemptId,
      versionLabel: String(status.versionLabel ?? ""),
    });
    const batches = await createBatches(result.rows);
    for (const batch of batches) {
      await stageBatch(
        service,
        config,
        requestId,
        validationAttemptId,
        batch.batchNumber,
        batch.digest,
        batch.rows,
        correlationId,
      );
    }
    const executionFingerprint = await digestCanonical({
      schema: "candidate-import-execution-v1",
      artifactSha256: result.artifactSha256,
      configurationDigest: result.configurationDigest,
      sourceRowHashes: result.rows.map((row) => row.sourceRowHash),
      findingFingerprints: result.findings.map((finding) => finding.fingerprint),
    });
    const completion = await completeValidation(
      service,
      config,
      requestId,
      validationAttemptId,
      result.sheetManifest,
      result.findings,
      result.summary,
      executionFingerprint,
      correlationId,
    );
    const finalStatus = await getMyImport(caller, requestId);
    if (completion.state === "VALIDATION_FAILED") {
      validationStarted = false;
      const failureCode = completion.errorCode === "ZERO_ACCEPTED_ROWS"
        ? "ZERO_ACCEPTED_ROWS"
        : "IMPORT_VALIDATION_FAILED";
      throw new ImportError(
        failureCode,
        undefined,
        false,
        422,
        requestId,
        typeof finalStatus.errorReference === "string"
          ? finalStatus.errorReference
          : crypto.randomUUID(),
      );
    }
    return { request: finalStatus };
  } catch (error) {
    const safe = error instanceof ImportError
      ? error
      : new ImportError("INTERNAL_IMPORT_ERROR", undefined, false, 500, requestId);
    if (validationStarted) {
      await recordFailure(service, config, requestId, validationAttemptId, correlationId, safe);
    }
    throw safe;
  }
}

function corsHeaders(request: Request): HeadersInit {
  const allowed = Deno.env.get("CANDIDATE_IMPORT_ALLOWED_ORIGIN");
  const origin = request.headers.get("origin");
  return allowed && origin === allowed
    ? {
      "access-control-allow-origin": allowed,
      "access-control-allow-headers": "authorization, content-type",
      "access-control-allow-methods": "GET, POST, OPTIONS",
      vary: "Origin",
    }
    : {};
}

export async function handleRequest(request: Request, config = loadConfig()): Promise<Response> {
  const started = performance.now();
  let requestId: string | null = null;
  let action = "unknown";
  try {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }
    const matched = parseRoute(new URL(request.url));
    requestId = matched.requestId;
    action = matched.action;
    if (
      (action === "status" && request.method !== "GET") ||
      (action !== "status" && request.method !== "POST")
    ) {
      throw new ImportError(
        "FILE_SCHEMA_INVALID",
        "HTTP method is not allowed for this route.",
        false,
        405,
        requestId,
      );
    }
    const caller = await authenticateCaller(request, config);
    const service = serviceClient(config);
    const body = action === "begin"
      ? await handleBegin(request, caller.client, service, config)
      : action === "complete"
      ? await handleComplete(caller.client, service, config, requestId!)
      : action === "validate"
      ? await handleValidate(caller.client, service, config, requestId!)
      : { request: await getMyImport(caller.client, requestId!) };
    console.info(
      JSON.stringify({
        route: action,
        requestId,
        category: "success",
        durationMs: Math.round(performance.now() - started),
      }),
    );
    return Response.json(body, { headers: corsHeaders(request) });
  } catch (error) {
    const safe = error instanceof ImportError
      ? error
      : new ImportError("INTERNAL_IMPORT_ERROR", undefined, false, 500, requestId);
    console.error(
      JSON.stringify({
        route: action,
        requestId,
        category: "failure",
        errorCode: safe.code,
        errorReference: safe.reference,
        durationMs: Math.round(performance.now() - started),
      }),
    );
    const response = errorResponse(safe);
    for (const [key, value] of Object.entries(corsHeaders(request))) {
      response.headers.set(key, value);
    }
    return response;
  }
}

if (import.meta.main) Deno.serve((request) => handleRequest(request));

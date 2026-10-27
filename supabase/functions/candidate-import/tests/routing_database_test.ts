import { assert, equal, rejects } from "./assert.ts";
import { bearerToken } from "../lib/auth.ts";
import { handleRequest, parseRoute, validateBeginPayload } from "../index.ts";
import type { CandidateImportConfig } from "../lib/contracts.ts";
import { objectPath } from "../lib/storage.ts";

Deno.test("missing JWT and malformed route are rejected", async () => {
  await rejects(
    () => bearerToken(new Request("https://example.invalid/candidate-import/begin")),
    /Authentication/,
  );
  await rejects(
    () => parseRoute(new URL("https://example.invalid/candidate-import/not-a-request")),
    /Unknown/,
  );
});

Deno.test("route and object identities are exact", () => {
  const id = "30000000-0000-4000-8000-000000000001";
  equal(parseRoute(new URL("https://example.invalid/candidate-import/begin")).action, "begin");
  equal(parseRoute(new URL(`https://example.invalid/candidate-import/${id}`)).action, "status");
  equal(
    parseRoute(new URL(`https://example.invalid/candidate-import/${id}/complete-upload`)).action,
    "complete",
  );
  equal(
    parseRoute(new URL(`https://example.invalid/candidate-import/${id}/validate`)).action,
    "validate",
  );
  equal(objectPath(id), `medication-request-cato/${id}/source.xlsx`);
  assert(!objectPath(id).includes(".."));
});

Deno.test("begin payload is locally bounded and preserves paired Candidate expectations", async () => {
  const id = "30000000-0000-4000-8000-000000000002";
  const input = validateBeginPayload({
    resourceConfigId: "medication-request-cato",
    versionLabel: "v1",
    originalFilename: "source.xlsx",
    declaredByteSize: 1024,
    idempotencyKey: id,
    expectedCandidateBaselineVersionId: null,
    expectedCandidateLifecycleEventId: null,
  }, 10_485_760);
  equal(input.idempotencyKey, id);
  await rejects(() =>
    validateBeginPayload({ ...input, originalFilename: "source.xlsm" }, 10_485_760)
  );
  await rejects(() =>
    validateBeginPayload({
      ...input,
      expectedCandidateBaselineVersionId: id,
      expectedCandidateLifecycleEventId: null,
    }, 10_485_760)
  );
});

Deno.test("unsupported methods fail before auth and no publish route is exposed", async () => {
  const config: CandidateImportConfig = {
    supabaseUrl: "https://example.invalid",
    anonKey: "anon",
    serviceRoleKey: "service",
    serviceActorId: "30000000-0000-4000-8000-000000000003",
    bucket: "s2t-candidate-imports",
    spec: "CATO-MEDICATIONREQUEST-XLSX-v1",
    maxCompressedBytes: 10_485_760,
    maxExpandedBytes: 52_428_800,
  };
  const response = await handleRequest(
    new Request("https://example.invalid/candidate-import/begin", { method: "GET" }),
    config,
  );
  equal(response.status, 405);
  await rejects(
    () => parseRoute(new URL("https://example.invalid/candidate-import/publish")),
    /Unknown/,
  );
});

Deno.test("database adapter freezes exact public/service RPC names and argument names", async () => {
  const source = await Deno.readTextFile(new URL("../lib/database.ts", import.meta.url));
  for (
    const name of [
      "begin_candidate_import",
      "get_my_candidate_import",
      "_service_accept_candidate_import_upload",
      "_service_begin_candidate_import_validation",
      "_service_stage_candidate_import_batch",
      "_service_complete_candidate_import_validation",
      "_service_fail_candidate_import",
    ]
  ) assert(source.includes(`\"${name}\"`), name);
  assert(!source.includes('"publish_candidate_import"'));
  assert(source.includes('return rpc(caller, "begin_candidate_import"'));
  assert(source.includes('return rpc(service, "_service_begin_candidate_import_validation"'));
  for (
    const argument of [
      "p_request_id",
      "p_validation_attempt_id",
      "p_service_actor_id",
      "p_correlation_id",
      "p_rows",
      "p_findings",
      "p_sheet_manifest",
    ]
  ) assert(source.includes(argument));
});

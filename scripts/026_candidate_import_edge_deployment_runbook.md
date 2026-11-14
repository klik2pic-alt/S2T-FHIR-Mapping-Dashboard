# Migration 026 Candidate Import Edge Deployment Runbook

This runbook deploys repository artifacts created after Migration 026. It does not alter Migration
026 and must not be run until the F4C.4 deployment checkpoint is approved.

## Contract

- Function: `candidate-import`
- Bucket: `s2t-candidate-imports`
- Object: `medication-request-cato/<requestId>/source.xlsx`
- Bucket is private, 10 MiB maximum, XLSX MIME only.
- Browser upload access is only through one short-lived exact-path signed URL. No standalone token,
  separate private object path, or browser list/read/update/delete policy is returned or created.
- The service role is used only for private Storage and the five service-only Migration 026 helpers.
  Public RPCs run with the governed caller JWT.

## Required secrets and configuration

```text
SUPABASE_URL
SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY
CANDIDATE_IMPORT_SERVICE_ACTOR_ID
CANDIDATE_IMPORT_ALLOWED_ORIGINS=https://fhir-meds-insight.lovable.app
CANDIDATE_IMPORT_BUCKET=s2t-candidate-imports
CANDIDATE_IMPORT_SPEC=CATO-MEDICATIONREQUEST-XLSX-v1
CANDIDATE_IMPORT_MAX_COMPRESSED_BYTES=10485760
CANDIDATE_IMPORT_MAX_EXPANDED_BYTES=52428800
```

`CANDIDATE_IMPORT_SERVICE_ACTOR_ID` must be the exact active governed principal authorized to act as
the import service. Resolve and approve it separately; do not accept a principal ID from a browser
request.

`CANDIDATE_IMPORT_ALLOWED_ORIGINS` is a comma-separated allowlist of exact HTTP(S) origins. Do not
use wildcards, paths, query strings, fragments, or trailing slashes. Each allowed browser origin is
echoed only when it exactly matches the request `Origin`; unknown origins receive no CORS headers.
The function fails closed when the variable is absent, empty, or invalid. Production configuration
must contain only approved production/application origins. For the F4C.5 TEST smoke, use:

```text
CANDIDATE_IMPORT_ALLOWED_ORIGINS=https://fhir-meds-insight.lovable.app,https://f87bf2db-338e-479f-b2c6-3d00f784c975.lovableproject.com
```

The `lovableproject.com` Preview origin is TEST/development configuration and is not a production
requirement.

## Approved deployment and smoke-test sequence

Each HTTP response and log review must be handled as sensitive test evidence. Do not print bearer
tokens, service credentials, or the signed upload URL.

1. Verify the backend commit, applied Migration 026 SHA-256, and Migration 026 postdeploy result.
2. Review all existing `storage.objects` policies for general policies that could expose the new
   bucket, then execute `scripts/026_candidate_import_storage_setup.sql` once. It fails closed on a
   conflicting bucket configuration or a pre-existing bucket-specific policy.
3. Configure the secrets above without printing their values.
4. From the repository root, deploy only the function:

   ```text
   supabase functions deploy candidate-import
   ```

   Do not add `--no-verify-jwt`; `supabase/config.toml` requires gateway JWT verification and the
   function independently validates the caller with Auth.
5. Authenticate as the exact governed test principal, verify an unauthenticated request returns 401,
   and verify `GET /candidate-import/<ownedRequestId>` is caller-scoped.
6. Call `POST /candidate-import/begin` with the frozen resource, file metadata, idempotency key, and
   exact nullable Candidate snapshot. Record only the safe request projection and request ID.
7. Upload the XLSX bytes once through the returned exact-object signed URL. Do not list the bucket,
   disclose the URL, reuse it for another path, or request browser Storage policies.
8. Call `POST /candidate-import/<requestId>/complete-upload`; verify the stored bytes are accepted
   as `UPLOADED` only after size, digest, and OOXML preflight checks.
9. Call `POST /candidate-import/<requestId>/validate`; verify parser metadata, staged counts, and
   the safe terminal response. A governed validation failure must return HTTP 422.
10. Call `GET /candidate-import/<requestId>` and require `READY_TO_PUBLISH` for a clean workbook.
    Stop there: Candidate publication is explicitly outside this deployment smoke test.

## Smoke test checklist

- Unauthenticated GET/POST returns 401 with the frozen safe error envelope.
- Governed uploader can begin one request and receives an exact-path signed upload target with
  `upsert=false`.
- A different user cannot read, complete, or validate that request.
- No authenticated browser can list/read/delete/update bucket objects.
- Wrong magic, malformed ZIP, oversized, macro-enabled, externally-linked, and formula-bearing
  workbooks fail safely.
- A valid upload is SHA-256 checked from stored bytes before upload acceptance.
- Validation stages batches at no more than 250 rows and below the database 2 MiB guard.
- Validation never publishes a Candidate.
- `GET /candidate-import/<requestId>` returns only `get_my_candidate_import(...)`.
- Logs contain request/correlation IDs, counts, duration, and safe codes only; no token, signed URL,
  service key, or workbook cell value appears.

## Historical canonical workbook expectation

The retained canonical workbook is expected to parse as 293 candidates, 292 accepted, five warnings,
one error, and one quarantined row. It therefore does not satisfy CLEAN_IMPORT and must not become
READY_TO_PUBLISH without a new, governed clean workbook.

There is intentionally no cleanup procedure: uploaded artifacts and governed validation evidence
follow the repository's append-only retention rules.

## Replay-safe validation recovery

The normal validation path is:

```text
begin -> signed upload -> complete-upload -> validate -> READY_TO_PUBLISH
```

If a validation worker exits while the request is `VALIDATING`, do not create a replacement request
or blindly retry while its lease is active. A competing validation attempt is rejected while the
active lease remains valid. After the lease expires, Migration 029 supports this governed recovery
path:

```text
VALIDATING
  -> lease expiry
  -> VALIDATION_RECLAIMED
  -> exact artifact-manifest reuse
  -> exact staging replay/materialization reuse
  -> validation completion
  -> READY_TO_PUBLISH
```

Recovery remains fail-closed. The uploaded artifact manifest must match exactly; staging batches are
replayed only when their batch number, digest, row count, size, and materialized evidence match. A
replay batch points directly to its immutable root through `reused_from_staging_batch_id`; replay
chains and duplicate materialization are prohibited. Terminal completion replay is also rejected.
The stable conflict codes are:

- `ARTIFACT_MANIFEST_MISMATCH`
- `BATCH_DIGEST_MISMATCH`
- `STAGING_REPLAY_MISMATCH`
- `IMPORTED_ROW_REPLAY_MISMATCH`
- `COMPLETION_ALREADY_APPLIED`

These conflicts require investigation. They are not permission to replace retained evidence,
disable append-only protections, or create another Candidate merely because a worker failed.

## F4C.7 retained recovery evidence

Request `ef7d9ed5-08fa-46d8-90b8-44904e4ab2cd` was recovered in place after the initial validation
worker returned `WORKER_RESOURCE_LIMIT`. Instrumentation localized the failure, and the Edge
batching optimization staged the 293 rows at the canonical 250 + 43 boundary. A manifest collision
exposed the need for replay-safe completion; Migration 029 then supplied exact immutable manifest reuse,
root-provenance staging replay, and fail-closed completion. The original request was reclaimed after
lease expiry and completed without a replacement Candidate.

The recovered clean fixture is distinct from the historical canonical workbook above:

```text
request_id=ef7d9ed5-08fa-46d8-90b8-44904e4ab2cd
artifact_sha256=766d1b1e31d00eb6931d70db1ed84ae87c58b554a3e02dabc319497c42696e05
request_state=READY_TO_PUBLISH
candidate_rows=293
accepted_rows=293
warning_rows=0
error_rows=0
quarantined_rows=0
element_mappings=238
extension_mappings=9
reference_mappings=46
```

Migration 029 verification passed in TEST: preflight 11/11, postdeploy 16/16, and rollback runtime
18/18 with the committed Candidate-import fingerprint restored after rollback.

`READY_TO_PUBLISH` is validation output, not publication. It does not mean `PUBLISHED`, does not
create a Candidate lifecycle publication event, and does not authorize automatic publication.
Publishing remains a separate governed action and was deliberately not performed during F4C.7.

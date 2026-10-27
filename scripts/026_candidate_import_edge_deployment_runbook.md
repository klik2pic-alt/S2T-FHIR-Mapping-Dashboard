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
CANDIDATE_IMPORT_ALLOWED_ORIGIN
CANDIDATE_IMPORT_BUCKET=s2t-candidate-imports
CANDIDATE_IMPORT_SPEC=CATO-MEDICATIONREQUEST-XLSX-v1
CANDIDATE_IMPORT_MAX_COMPRESSED_BYTES=10485760
CANDIDATE_IMPORT_MAX_EXPANDED_BYTES=52428800
```

`CANDIDATE_IMPORT_SERVICE_ACTOR_ID` must be the exact active governed principal authorized to act as
the import service. Resolve and approve it separately; do not accept a principal ID from a browser
request.

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

## Canonical workbook expectation

The retained canonical workbook is expected to parse as 293 candidates, 292 accepted, five warnings,
one error, and one quarantined row. It therefore does not satisfy CLEAN_IMPORT and must not become
READY_TO_PUBLISH without a new, governed clean workbook.

There is intentionally no cleanup procedure: uploaded artifacts and governed validation evidence
follow the repository's append-only retention rules.

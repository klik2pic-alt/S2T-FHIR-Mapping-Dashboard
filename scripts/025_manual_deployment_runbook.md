# Migration 025 — Candidate UI Read Contracts

Migration 025 adds authenticated read contracts for Candidate workflow UI work.
It does not implement frontend behavior and does not add lifecycle, review,
governance, or Promotion mutations.

Migrations 023 and 024 are immutable prerequisites. The public signature of
`s2t_fhir_api.promote_candidate_baseline(...)` is unchanged.

## Objects introduced

Public authenticated RPCs:

- `get_candidate_ui_context(text)`
- `get_candidate_promotion_readiness(text,uuid,uuid,uuid,uuid,timestamptz)`
- `get_my_candidate_ui_capabilities()`
- `get_my_candidate_review_session(uuid,uuid)`

Private helpers:

- `_candidate_ui_capability_state(uuid)`
- `_candidate_ui_snapshot(text)`
- `_evaluate_candidate_promotion_readiness(...)`
- `_raise_candidate_promotion_evaluation(jsonb)`

The migration behavior-preservingly replaces the private 023 eligibility
assertion and activation-context trigger function. The trigger retains the 023
lock acquisition and failure sequence, then calls the shared evaluator after
all Candidate, ACTIVE, registry, publication, artifact, import, validation, and
gate locks have been acquired.

`governance_mapping_links` retains its original 19 columns in their original
order and appends Candidate baseline, lifecycle-event, and lifecycle-status
provenance.

## Readiness semantics

`ready=true` is an observation at `observedAt`. It is not a reservation, token,
lock, or guarantee. Promotion must submit and revalidate the exact Candidate,
import, gate, and ACTIVE identifiers returned by readiness.

The stored validation outcome is returned as evidence. Migration 025 does not
introduce `VALIDATION_FAILED` as a new independent Promotion rule.

## Deployment order

Use direct PostgreSQL/`psql` with `ON_ERROR_STOP=1`. Do not use Supabase SQL
Editor tabs for concurrency evidence.

1. Confirm accepted Migrations 023 and 024 are deployed.
2. Run `scripts/025_preflight_readonly.sql`.
3. Require every row and the overall result to be `PASS`. Any failure is a hard
   stop; do not apply Migration 025.
4. Apply `supabase/migrations/025_candidate_ui_read_contracts.sql` once.
5. Run `scripts/025_postdeploy_verification.sql`.
6. Require every catalog/ACL check to be `PASS`.
7. Confirm the retained `T023-CONC-PACK-20261009-R1` fixture is present.
8. Run `scripts/025_runtime_tests_rollback.sql`.
9. Require `29/29 PASS` and `FULL ROLLBACK RESTORATION PASS`.
10. Run the direct-session stale/concurrency procedure below.
11. Only after all evidence is retained may frontend integration begin in a
    later checkpoint.

Example invocation pattern:

```powershell
psql "$env:S2T_DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/025_preflight_readonly.sql
psql "$env:S2T_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/025_candidate_ui_read_contracts.sql
psql "$env:S2T_DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/025_postdeploy_verification.sql
psql "$env:S2T_DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/025_runtime_tests_rollback.sql
```

## Direct-psql stale/concurrency validation

Use independent direct PostgreSQL sessions. Supabase SQL Editor tabs are not
evidence of stable session affinity.

### Same-series stale read

1. Session A authenticates as a principal with Candidate read and Promotion
   capability.
2. Session A calls `get_candidate_ui_context(...)` and
   `get_candidate_promotion_readiness(...)`; retain `observedAt` and all exact
   expected identifiers.
3. Session B replaces or promotes that same Candidate through the existing
   governed public mutation and commits only on an approved disposable fixture.
   Prefer a rollback-only blocking variant where possible.
4. Session A calls `promote_candidate_baseline(...)` with its previously read
   identifiers.
5. PASS requires a stale-state rejection (`40001`), with no partial lifecycle or
   activation-context writes from Session A.

### Same-series serialization

1. Session A begins Promotion and pauses after it has acquired the existing
   baseline-series/Candidate path locks.
2. Session B attempts a mutation of the same series.
3. PASS requires Session B to wait and then revalidate stale state after Session
   A completes or rolls back.

### Different-series independence

1. Session A holds the Promotion path for fixture series A.
2. Session B performs the corresponding governed operation on fixture series B.
3. PASS requires series B to proceed without waiting on series A.

Do not delete or normalize historical fixture evidence. The original R1 C01
exception remains historical evidence under the 023/024 closure record.

## Failure handling

- Preflight failure: stop; inspect definition or ACL drift.
- Migration failure: rollback the failed transaction; do not edit 023/024.
- Postdeploy failure: do not begin runtime acceptance.
- Runtime failure: the outer transaction must be rolled back. Retain the output.
- Unexpected blocked session: inspect `pg_stat_activity` and
  `pg_blocking_pids(pid)` from a separate direct session.

## Rollback posture

Migration 025 is additive, but its private function replacements participate in
Promotion. A production rollback must be a reviewed forward migration that
restores the accepted private definitions and removes only 025 public objects.
Never rewrite the applied 025 file after deployment.

## TEST closure evidence — 2026-10-16

Migration 025 backend verification is complete in TEST:

- preflight and deployment completed successfully;
- postdeployment verification passed `12/12`;
- the rollback-only runtime suite passed `29/29`, followed by `FULL ROLLBACK
  RESTORATION PASS`;
- same-series serialization passed on C05: Session B waited on Session A's
  transaction, a `transactionid` lock was observed, and Session B revalidated
  and succeeded after Session A rolled back;
- different-series independence passed: C06 completed while the C05 transaction
  remained held;
- stale-read validation passed on `T025-STALE-20261016-R1`: A1 observed
  promotion-ready V2, B1 committed the V2-to-V3 Candidate replacement, and A2's
  stale Promotion failed with exact SQLSTATE `40001` and no partial writes;
- final retained evidence and all six integrity checks passed.

The dedicated retained fixture identities are:

| Identity | Value |
| --- | --- |
| Namespace / source system | `T025-STALE-20261016-R1` |
| Resource config | `t025-stale-20261016-r1-resource` |
| Baseline series | `02550000-0000-4000-8000-000000000001` |
| Principal A / auth subject | `0255a000-0000-4000-8000-000000000001` / `0255a001-0000-4000-8000-000000000001` |
| Principal B / auth subject | `0255b000-0000-4000-8000-000000000001` / `0255b001-0000-4000-8000-000000000001` |
| V1 | `02550101-0000-4000-8000-000000000001` |
| V2 | `02550201-0000-4000-8000-000000000001` |
| V3 | `02550301-0000-4000-8000-000000000001` |

The initial provisioning attempt committed SP01/SP02, then exposed a
backend-affinity edge: after SP02 committed, the transaction-local custom GUC
`s2t_fhir.finalizing_baseline` remained as an empty backend-scoped placeholder.
SP03 therefore failed closed under the one-baseline-per-finalization rule even
though it finalized only V2. The committed prefix was preserved. Recovery used
`025_stale_concurrency_resume_sp03.sql` in a fresh direct-`psql` backend,
disconnected, used `025_stale_concurrency_resume_sp04.sql` in another fresh
backend, disconnected again, and ran
`025_stale_concurrency_resume_sp05_sp11.sql` in a third fresh backend. The
database invariant and custom GUC were not modified.

Final retained state is exact: V1 is the current `ACTIVE` leaf, V2 is the
current `SUPERSEDED` leaf, V3 is the current `CANDIDATE` leaf, and the
lifecycle/candidate-context/activation-context/relationship counts are
`5/3/1/1`. The verifier must classify this as `RETAINED_STALE_EVIDENCE`; it
classifies the pre-B1 `3/2/1/0` shape as `READY_FOR_STALE_TEST`.

This fixture is append-only retained TEST evidence. B1 must not be run again,
and no destructive cleanup is provided. The retained Migration 023/024 C01-C06
fixtures, including C06-V2/V3, were not mutated.

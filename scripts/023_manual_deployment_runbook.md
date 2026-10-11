# Migration 023 manual TEST deployment runbook

Target project: `S2T-FHIR-DDL-Test`

Approved migration:

```text
supabase/migrations/023_candidate_workflow.sql
SHA-256: 2182F111F0AAD06A7F87F0403337AF644608E51B85F9098723F28D8E5075A631
Lines: 4,602
```

This runbook uses the Supabase SQL Editor only. Do not use `supabase db push`,
`migration up`, `db reset`, project linking, or migration-history manipulation.

## Phase A — preflight

1. Open the Supabase dashboard and positively confirm the project name is
   `S2T-FHIR-DDL-Test`.
2. Open a new SQL Editor query.
3. Copy the complete unchanged contents of `scripts/023_preflight_readonly.sql`.
4. Run the entire script from its first statement.
5. Save every result row, especially fingerprints 101–110.

Stop if `PREFLIGHT SUMMARY` is not `PASS`, any required check is `FAIL`, any 023
object is unexpectedly present, or the environment cannot be positively
identified in the dashboard.

## Phase B — deploy the exact migration

1. Recalculate the local migration SHA-256 and confirm it equals the approved
   value above.
2. Open a fresh SQL Editor query in the confirmed TEST project.
3. Copy the complete unchanged contents of
   `supabase/migrations/023_candidate_workflow.sql`.
4. Run the complete migration as one SQL Editor operation.

Migration 023 already starts with one outer `BEGIN;` and ends with one final
`COMMIT;`. Do not add another wrapper transaction and do not run fragments.

If execution stops before the final `COMMIT`, issue `ROLLBACK;` in that same SQL
Editor session. Do not repair individual objects or rerun only a suffix.

## Phase C — postdeployment verification

1. Open a fresh query.
2. Copy and run all of `scripts/023_postdeploy_verification.sql`.
3. Require `POSTDEPLOY SUMMARY = PASS` and every Checkpoint summary to be
   `PASS`.
4. Compare fingerprints 101–110 exactly with Phase A.
5. Retain all emitted `pg_get_functiondef()`, `pg_get_triggerdef()`,
   `pg_get_indexdef()`, `pg_get_viewdef()`, constraint, and privilege evidence.

Stop on any `FAIL`, fingerprint mismatch, unexpected privilege, or
PostgreSQL error. Do not repair the catalog manually.

## Phase D — rollback-only runtime tests

1. Confirm `scripts/023_runtime_tests_rollback.sql` contains one outer `BEGIN`,
   one final `ROLLBACK`, and no `COMMIT`.
2. Run the complete script as one operation.
3. Require zero unexpected `FAIL` results.
4. Accept `NOT RUN / FIXTURE REQUIRED` only for the scenarios explicitly marked
   by the script; provision dedicated rollback-safe fixtures in a separately
   approved test package before converting those results to PASS.
5. Compare every `RUNTIME BEFORE` fingerprint with its corresponding
   `RUNTIME AFTER ROLLBACK` fingerprint.

Stop if the final rollback is missing, fingerprints differ, or any synthetic
`TEST_023_` / `T023-` data persists.

## Phase E — two-session concurrency tests

Follow `scripts/023_concurrency_test_plan.md` using two independent SQL Editor
sessions plus a read-only observer tab. Run only tests for which dedicated
rollback-safe fixtures have been approved. Capture blocking PIDs, SQLSTATEs,
winner/loser results, final state, and both rollbacks.

Use rollback-only blocking mode in shared TEST. A true stale winner/loser result
requires one session to commit; run that mode only in an explicitly approved
disposable database/fixture as defined by the concurrency plan. Otherwise record
the committed variant as `NOT RUN / FIXTURE REQUIRED`.

Stop on deadlock `40P01`, stale-state success, lifecycle branching, partial
Promotion, or cross-series blocking.

## Phase F — acceptance decision

The acceptance record must include:

- confirmed TEST project;
- migration SHA-256 and line count;
- Phase A summary and fingerprints;
- Phase B transaction/commit result;
- Phase C Checkpoint summaries, definitions, ACLs, and fingerprint comparison;
- Phase D PASS/FAIL/FIXTURE REQUIRED counts and rollback fingerprint comparison;
- Phase E concurrency results or explicit fixture-required deferrals;
- confirmation that no synthetic test mutation persisted.

Do not mark Migration 023 accepted while any required check is failed, any
unexpected drift remains, or a required runtime/concurrency scenario lacks an
approved fixture and explicit disposition.

# Migration 024 manual TEST deployment runbook

Target project: `S2T-FHIR-DDL-Test`

This package is an incremental correction over the already deployed Migration
023. Do not edit or rerun Migration 023, manipulate migration history, or run
any part of the 023 concurrency provisioning package during Phases A-D.

Use the Supabase SQL Editor. Run each file in a fresh query and always run the
complete file from its first statement to its last statement.

## Phase A — read-only preflight

Run the complete unchanged contents of:

```text
scripts/024_preflight_readonly.sql
```

Required result:

- every numbered check is `PASS`;
- `PREFLIGHT SUMMARY = PASS`;
- the fixture detail is exactly
  `last_completed_checkpoint=CP20; exact_next_checkpoint=CP21`.

Stop on any `FAIL`, PostgreSQL error, unexpected function caller, definition
fingerprint mismatch, ACL drift, or fixture-state mismatch. Do not repair the
catalog manually and do not run the migration against a drifted definition.

## Phase B — deploy Migration 024

Run the complete unchanged contents of:

```text
supabase/migrations/024_candidate_review_actor_validation.sql
```

The file owns its single `BEGIN`/`COMMIT` transaction. Do not add another
transaction and do not execute a fragment. It replaces only the three private
Candidate Review cores and re-hardens their execution privileges.

If execution stops before the final `COMMIT`, issue `ROLLBACK;` in the same SQL
Editor session. Do not repair or replace an individual function manually.

## Phase C — read-only postdeployment verification

In a fresh query, run:

```text
scripts/024_postdeploy_verification.sql
```

Required result:

- every numbered check is `PASS`;
- `POSTDEPLOY SUMMARY = PASS`;
- all three target bodies have `guard=0` and their expected fingerprints;
- private cores remain owner-only;
- the five authenticated wrappers remain `authenticated`-only;
- authorization, ACTIVE Review, Governance, relation, view, trigger,
  constraint and index sentinels remain unchanged.

Stop on any failure or unexpected catalog difference. Do not proceed to runtime
testing until the postdeployment summary passes.

## Phase D — rollback-only runtime acceptance

Confirm that the test file contains exactly one application-mutation `BEGIN`,
one final `ROLLBACK`, and no `COMMIT`. Then run the complete file:

```text
scripts/024_runtime_tests_rollback.sql
```

Required result:

- T01-T13 and T15-T29 are `PASS`;
- T14 is `NOT_APPLICABLE` only with the recorded reason that
  `review_actor_authorization_active_uq` prevents duplicate current grants;
- zero tests are `FAIL`;
- the `RUNTIME BEFORE fixture` and `RUNTIME AFTER ROLLBACK fixture`
  fingerprints are identical;
- T29 reports `PASS` after the rollback.

The tests temporarily use exact retained fixture identities under the outer
transaction. The rollback must restore the committed CP20 state. Stop if the
SQL Editor session disconnects during the transaction or if the final rollback
and post-rollback evidence are not visible.

## Phase E — re-run retained fixture verification

In a fresh read-only query, run the existing complete verifier:

```text
scripts/023_concurrency_fixture_verification.sql
```

For `V01_RECOVERY`, require:

```text
last_completed_checkpoint = CP20
exact_next_checkpoint      = CP21
recovery_state             = READY_FOR_EXACT_NEXT_CHECKPOINT
```

Also require every other verification emitted by that script to remain
consistent with the retained CP20 state.

## Mandatory stop before CP21

Do **not** resume CP21 yet.

The current CP21 fixture harness has a separate defect: after
`SET LOCAL ROLE authenticated`, it directly selects
`candidate_lifecycle_event_id` from private `s2t_fhir` tables. The
`authenticated` role intentionally lacks direct schema/table privileges. This
is a fixture-harness defect, not a Migration 024 defect, and must be corrected
in a separate reviewed task without changing this Migration 024 package.

Retain the complete Phase A-D result sets, the two runtime fingerprints, and
the Phase E `V01_RECOVERY` row as acceptance evidence.

# S2T FHIR Mapping Dashboard
## Runtime Test Scripts

This folder contains the runtime regression and concurrency test assets for the S2T FHIR Mapping Review workflow.

Current scope:

- Source system: `CATO`
- FHIR resource: `MedicationRequest`
- Review workflow governance
- Authentication and authorization
- Review session lifecycle
- Review event-chain integrity
- Concurrency serialization

## Migration 022 controlled acceptance package

The migration 022 lifecycle-foundation package was accepted in `S2T-FHIR-DDL-Test` on 2026-10-05:

- `022_preflight_readonly.sql`: Phase A, 15/15 PASS.
- `022_postdeploy_verification.sql`: Phase C, 11/11 PASS with fingerprints 101-109 unchanged.
- `022_runtime_tests_rollback.sql`: Phase D, 24 PASS, 0 FAIL, and T25-T26 `NOT RUN / FIXTURE REQUIRED`.

The runtime suite retained its outer transaction and final rollback. Runtime BEFORE/AFTER fingerprints matched, and no `TEST_022_*` or `T022-*` synthetic fixtures persisted.

Approved SHA-256 values:

- `022_preflight_readonly.sql`: `D24A085711B300091E8B321055C55D7ACE9DE903108A1040034EB9862B38726A`
- `022_postdeploy_verification.sql`: `1A4AEE1C6ECCCF28B87FA61DF2834D2641E3B873945BE5DF7F222B76A3F64AB1`
- `022_runtime_tests_rollback.sql`: `0950E5690BD6630C1462AA66452505273C5F88BA0E0E1901720989E8FD2CE67E`

## Migration 023/024 concurrency validation closure

Migration 023/024 backend concurrency validation is complete with result PASS.
C01 passed on retained replacement fixture
`T023-CONC-PACK-20261010-R2-C01`; the original canonical R1 C01 fixture retains
historical committed Candidate evidence from an invalid SQL Editor concurrency
attempt. C02-C07 passed on canonical fixture `T023-CONC-PACK-20261009-R1`.

The canonical verifier must not be summarized as “all PASS” because its R1 C01
result correctly exposes that retained historical evidence. See the audit-grade
record in `023_024_concurrency_validation_closure.md` for fingerprints, blocking
evidence, verifier results, and the Migration 024 Candidate Review scope.

---

# Files

## 1. runtime_regression_tests.sql

Path:

```text
scripts/runtime_regression_tests.sql
```

Purpose:

Runs the automated runtime regression suite for the governed Mapping Review workflow.

The suite is designed to be:

- Repeatable
- Non-destructive
- Transactional
- Safe for controlled runtime validation
- Self-cleaning through `ROLLBACK`

Current baseline:

```text
20 / 20 PASS
```

Coverage includes:

- Missing Supabase identity rejection
- Governed principal resolution
- `S2T_REVIEW_WRITE` authorization
- Active reviewer acceptance
- Review session creation
- Mandatory session enforcement for authenticated human review
- `REVIEWED` transition
- `NEEDS_FOLLOW_UP` transition
- `NOT_REVIEWED` / clear transition
- Blank review-note validation
- Review session closure
- Double-close protection
- Closed-session reuse protection
- Cross-actor session ownership protection
- Internal service review with `NULL` session
- Single current review per mapping
- Cross-mapping supersedes protection
- Cross-baseline supersedes protection
- Cycle detection
- Branching prevention
- Database unique-index enforcement

---

# Running the automated regression suite

## Step 1 - Open PowerShell

Navigate to the project directory:

```powershell
cd "D:\פרוייקטים Lovable\S2T-FHIR-Mapping-Dashboard"
```

## Step 2 - Connect to PostgreSQL

```powershell
& "C:\Program Files\PostgreSQL\17\bin\psql.exe" "host=aws-0-eu-central-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.brnybpfcrfbbboslopap sslmode=require" -W
```

Enter the database password when prompted.

A successful connection should show:

```text
postgres=>
```

## Step 3 - Run the regression suite

Inside `psql`:

```sql
\i 'scripts/runtime_regression_tests.sql'
```

Expected result:

```text
overall_result | passed | failed | total
---------------+--------+--------+------
PASS           | 20     | 0      | 20
```

The final output must include:

```text
ROLLBACK
```

This confirms that all test data created by the suite was discarded.

---

# Expected automated baseline

Current established baseline:

```text
Runtime Regression Baseline
Date: 2026-09-27
Result: PASS
Passed: 20
Failed: 0
Total: 20
```

Any future migration affecting the Mapping Review workflow should be followed by a full rerun of this suite.

A regression should not be considered accepted if:

```text
failed > 0
```

---

# 2. concurrency_review_test.md

Path:

```text
scripts/concurrency/concurrency_review_test.md
```

Purpose:

Documents the manual two-session concurrency test for simultaneous review operations against the same mapping record.

This test verifies runtime locking behavior that cannot be fully validated inside a single SQL transaction.

Current baseline:

```text
CONCURRENCY-01 PASS
```

---

# Running the concurrency test

The concurrency test requires two separate `psql` sessions.

Follow the detailed procedure in:

```text
scripts/concurrency/concurrency_review_test.md
```

The test verifies:

```text
Session A
→ acquires mapping-level lock

Session B
→ attempts review on same mapping
→ waits on database lock

Session A
→ ROLLBACK

Session B
→ resumes successfully
```

Expected lock evidence:

```text
wait_event_type = Lock
blocking_pids    = {Session A PID}
```

Both sessions must end with:

```sql
ROLLBACK;
```

to ensure no concurrency test events remain persisted.

---

# Concurrency protection architecture

Review-event integrity is protected by two mechanisms.

## Runtime serialization

The review core uses row-level locking:

```text
FOR UPDATE
```

This ensures that competing review operations against the same governed mapping record are serialized.

## Database-level branch prevention

The database also contains:

```sql
CREATE UNIQUE INDEX mapping_review_event_superseded_once_uq
ON s2t_fhir.mapping_review_event (supersedes_event_id)
WHERE supersedes_event_id IS NOT NULL;
```

This prevents two review events from superseding the same parent event.

Together:

```text
Runtime locking
+
Database uniqueness invariant
```

protect the review event chain from concurrent branching.

---

# Governance rule introduced in Migration 019

Migration:

```text
supabase/migrations/019_require_review_session_for_authenticated_actions.sql
```

introduced the following governance rule:

```text
Authenticated human review actions require a Review Session.
```

The rule applies to:

```text
mark_authenticated_mapping_reviewed
mark_authenticated_mapping_needs_follow_up
clear_authenticated_mapping_review
```

The expected behavior is:

```text
Authenticated human review + NULL session
→ REJECT
```

with:

```text
SQLSTATE 22023
review session is required for authenticated review actions
```

The internal service path remains intentionally compatible with:

```text
session_id = NULL
```

through:

```text
s2t_fhir_api._record_mapping_review()
```

This preserves backward compatibility for governed internal/service review operations.

---

# Important safety rule

The automated regression suite and concurrency test were designed to be non-destructive.

Do not replace:

```sql
ROLLBACK;
```

with:

```sql
COMMIT;
```

during runtime testing unless persistent test data is explicitly required.

If a test aborts while inside a transaction and the `psql` prompt changes to:

```text
postgres=!>
```

run:

```sql
ROLLBACK;
```

before continuing.

---

# Test philosophy

The Mapping Review runtime test strategy validates both application behavior and database invariants.

The expected architecture is:

```text
Supabase Authentication
        ↓
Governed Principal Resolution
        ↓
S2T_REVIEW_WRITE Authorization
        ↓
Review Session
        ↓
Review Action
        ↓
Mapping Review Event
        ↓
Supersedes Chain
        ↓
Current Review Projection
```

The system is expected to fail closed when:

- No authenticated identity exists
- No governed principal exists
- The principal is disabled
- No active review-write authorization exists
- Authorization is ambiguous
- The Review Session is invalid
- The Review Session is closed
- The Review Session belongs to another actor
- A human review action omits the Review Session
- A supplied review note is blank

---

# Runtime verification coverage

The runtime verification performed on 2026-09-27 covered the following areas.

## Authentication

Verified:

```text
Missing Supabase JWT subject
→ authenticated principal resolution rejected
```

Verified:

```text
Valid Supabase JWT subject
→ governed principal resolved successfully
```

Runtime test principal:

```text
principal_id:
6637fe25-a71d-46f2-be18-32c994769ea4

display_name:
Runtime Test Reviewer

external_issuer:
supabase-auth

external_subject:
11111111-1111-1111-1111-111111111111
```

---

# Authorization

Review-write authorization uses:

```text
S2T_REVIEW_WRITE
```

The authorization guard verifies:

```text
principal_id matches
AND capability_code = S2T_REVIEW_WRITE
AND effective_at <= transaction_timestamp()
AND revoked_at IS NULL
```

Expected active grant cardinality:

```text
exactly 1
```

Verified behavior:

```text
0 active grants
→ REJECT

1 active grant
→ ACCEPT

more than 1 active grant
→ REJECT as ambiguous
```

---

# Authorization lifecycle

Runtime testing verified the full authorization lifecycle.

## Revoked authorization

Observed:

```text
active_review_write_grants = 0
```

Result:

```text
authenticated principal is not authorized for S2T review writes
```

Status:

```text
PASS
```

## Re-granted authorization

A new authorization row was created.

Observed:

```text
active_review_write_grants = 1
```

Result:

```text
authenticated review principal accepted
```

Status:

```text
PASS
```

The re-grant was performed inside a transaction and rolled back after verification.

---

# Review Session lifecycle

The following session lifecycle was verified:

```text
OPEN
→ review actions allowed
→ END SESSION
→ CLOSED
```

Verified behaviors:

```text
Open owned session
→ ACCEPT
```

```text
Closed session
→ REJECT
```

```text
Double close
→ REJECT
```

```text
Unknown session
→ REJECT
```

```text
Session owned by another actor
→ REJECT
```

---

# Session ownership

A second temporary authenticated reviewer was provisioned for runtime testing.

Actor A:

```text
6637fe25-a71d-46f2-be18-32c994769ea4
```

Actor B:

```text
6a48def5-0924-4bd4-84a1-595a091205d3
```

Actor A opened a Review Session.

Actor B:

- Was authenticated
- Had a valid governed principal
- Had active `S2T_REVIEW_WRITE`

Actor B attempted to close Actor A's session.

Result:

```text
open review session owned by this actor not found in the active baseline
```

Status:

```text
PASS
```

The temporary Actor B principal and grants were removed through `ROLLBACK`.

---

# Review workflow

The following state transition sequence was verified:

```text
REVIEWED
→ NEEDS_FOLLOW_UP
→ NOT_REVIEWED
```

Each transition generated a new immutable review event.

No existing event was overwritten.

Example logical chain:

```text
Previous Event
      ↓
REVIEWED
      ↓
NEEDS_FOLLOW_UP
      ↓
NOT_REVIEWED
```

Each new event stores:

```text
supersedes_event_id
```

pointing to the previous event.

---

# Current review projection

The view:

```text
s2t_fhir.current_mapping_review
```

was verified to expose the current head of each review chain.

The projection excludes events that have already been superseded.

Integrity test:

```text
At most one current review
per baseline_version_id + mapping_record_id
```

Result:

```text
0 violations
```

Status:

```text
PASS
```

---

# Review note validation

The review Core rejects blank notes when a note is supplied.

Test input:

```text
'   '
```

Expected result:

```text
review note must be nonblank when supplied
```

SQLSTATE:

```text
22023
```

Status:

```text
PASS
```

---

# Mandatory human Review Session governance

During runtime validation, a governance gap was identified.

Before Migration 019:

```text
Authenticated human reviewer
+ active S2T_REVIEW_WRITE
+ session_id = NULL
→ review event successfully created
```

This meant human review actions could bypass Review Session context.

The issue was classified as:

```text
Governance Gap
```

The authenticated wrappers were changed to reject:

```text
p_session_id IS NULL
```

Affected functions:

```text
s2t_fhir_api.mark_authenticated_mapping_reviewed
s2t_fhir_api.mark_authenticated_mapping_needs_follow_up
s2t_fhir_api.clear_authenticated_mapping_review
```

Expected error:

```text
review session is required for authenticated review actions
```

SQLSTATE:

```text
22023
```

Regression verification:

```text
mark_authenticated_mapping_reviewed + NULL
→ REJECT

mark_authenticated_mapping_needs_follow_up + NULL
→ REJECT

clear_authenticated_mapping_review + NULL
→ REJECT
```

Status:

```text
PASS
```

---

# Internal service backward compatibility

The internal service API remains intentionally compatible with:

```text
session_id = NULL
```

Internal API:

```text
s2t_fhir_api._record_mapping_review()
```

Internal actor:

```text
2fb03b24-4795-4b19-bf54-b1359593e0d0
S2T FHIR import service
```

Verified:

```text
Internal service actor
+ session_id = NULL
→ review event created successfully
```

Status:

```text
PASS
```

Therefore the governance model is:

```text
Authenticated human API
→ Review Session required

Internal governed service API
→ Review Session optional
```

---

# Event-chain integrity

Multiple integrity checks were performed against:

```text
s2t_fhir.mapping_review_event
```

## Cross-mapping links

Verified that no review event supersedes an event belonging to another mapping record.

Result:

```text
0 violations
```

Status:

```text
PASS
```

## Cross-baseline links

Verified that no review event supersedes an event belonging to another baseline version.

Result:

```text
0 violations
```

Status:

```text
PASS
```

## Cycles

Recursive cycle detection was performed against the complete review-event graph.

Result:

```text
0 cycles
```

Status:

```text
PASS
```

## Branching

Verified that no parent event has multiple successors.

Result:

```text
0 branch points
```

Status:

```text
PASS
```

---

# Database integrity controls

The following database protections were verified.

## Primary key

```text
mapping_review_event_pkey
```

Protects:

```text
mapping_review_event_id
```

## Foreign keys

Verified relationships include:

```text
actor_principal_id
→ principal
```

```text
baseline_version_id
→ baseline_version
```

```text
mapping_record_id
→ mapping_record
```

```text
review_session_id
→ review_session
```

```text
review_status_value_id
→ reference_value
```

```text
supersedes_event_id
→ mapping_review_event
```

## Review-note constraint

```text
mapping_review_event_note_ck
```

Ensures:

```text
review_note IS NULL
OR btrim(review_note) <> ''
```

## Self-supersede protection

```text
mapping_review_event_supersedes_ck
```

Prevents:

```text
supersedes_event_id = mapping_review_event_id
```

## Single-successor protection

```text
mapping_review_event_superseded_once_uq
```

Definition:

```sql
CREATE UNIQUE INDEX mapping_review_event_superseded_once_uq
ON s2t_fhir.mapping_review_event (supersedes_event_id)
WHERE supersedes_event_id IS NOT NULL;
```

This prevents branching at database level.

---

# Concurrency runtime verification

A real two-session concurrency test was performed.

## Session A

Started a transaction and executed:

```text
REVIEWED
```

against the selected mapping node.

The transaction remained open.

## Session B

Started a second transaction and executed:

```text
NEEDS_FOLLOW_UP
```

against the same mapping node.

The request waited for a database lock.

Observed:

```text
state = active
wait_event_type = Lock
wait_event = transactionid
blocking_pids = {Session A PID}
```

Baseline runtime evidence:

```text
Session B PID: 399209
Session A PID: 396062
```

After:

```sql
ROLLBACK;
```

in Session A:

```text
Session B resumed successfully.
```

Session B was then rolled back.

Status:

```text
CONCURRENCY-01 PASS
```

---

# Non-destructive runtime strategy

Runtime tests that create temporary data use:

```sql
BEGIN;
```

and finish with:

```sql
ROLLBACK;
```

This includes temporary:

- Review grants
- Review sessions
- Review events
- Temporary authenticated principals
- Concurrency test events

This prevents runtime validation from polluting governed production-like data.

---

# Migration 019

Migration file:

```text
supabase/migrations/019_require_review_session_for_authenticated_actions.sql
```

Purpose:

```text
Require Review Session context for authenticated human review actions.
```

Migration modifies only:

```text
mark_authenticated_mapping_reviewed
mark_authenticated_mapping_needs_follow_up
clear_authenticated_mapping_review
```

It does not modify:

```text
_record_mapping_review_core
_record_mapping_review
mapping_review_event.review_session_id
```

This preserves the internal service contract.

---

# Automated regression suite

Regression suite:

```text
scripts/runtime_regression_tests.sql
```

Properties:

```text
Transactional
Non-destructive
Repeatable
Self-cleaning
```

Established baseline:

```text
20 / 20 PASS
```

Result:

```text
overall_result = PASS
passed         = 20
failed         = 0
total          = 20
```

The suite ends with:

```text
ROLLBACK
```

---

# Manual concurrency suite

Concurrency documentation:

```text
scripts/concurrency/concurrency_review_test.md
```

Current result:

```text
CONCURRENCY-01 PASS
```

Concurrency remains separate from the automated SQL regression suite because a true concurrency test requires two independent database sessions.

---

# Recommended use after future migrations

After any migration affecting:

- Review authorization
- Review sessions
- Review events
- Review status handling
- Governed principals
- Review APIs
- Current review projection
- Review-event indexes or constraints

run:

```sql
\i 'scripts/runtime_regression_tests.sql'
```

Expected:

```text
20 / 20 PASS
```

If locking or event-chain behavior changed, also rerun:

```text
scripts/concurrency/concurrency_review_test.md
```

Expected:

```text
CONCURRENCY-01 PASS
```

---

# Failure handling

If the automated regression suite returns:

```text
FAIL
```

do not accept the migration until the failing test is understood.

If `psql` enters aborted transaction state:

```text
postgres=!>
```

run:

```sql
ROLLBACK;
```

before continuing.

If a concurrency test session remains blocked unexpectedly, inspect:

```sql
select
    a.pid,
    a.state,
    a.wait_event_type,
    a.wait_event,
    pg_blocking_pids(a.pid)
from pg_stat_activity a
where a.datname = current_database();
```

---

# Current verified status

As of:

```text
2026-09-27
```

the following runtime areas are verified:

```text
Authentication                    PASS
Governed principal resolution     PASS
Review authorization              PASS
Authorization revocation          PASS
Authorization re-grant            PASS
Review Session creation           PASS
Review Session closure            PASS
Double-close protection           PASS
Closed-session protection         PASS
Review Session ownership          PASS
Human session governance          PASS
REVIEWED transition               PASS
NEEDS_FOLLOW_UP transition        PASS
NOT_REVIEWED transition           PASS
Blank-note validation             PASS
Internal service compatibility    PASS
Current review uniqueness         PASS
Cross-mapping integrity           PASS
Cross-baseline integrity          PASS
Cycle detection                   PASS
Branch prevention                 PASS
Database unique enforcement       PASS
Concurrency serialization         PASS
```

Automated regression:

```text
20 / 20 PASS
```

Concurrency:

```text
CONCURRENCY-01 PASS
```

Overall runtime status:

```text
S2T Mapping Review Governance
RUNTIME VERIFIED
```

---

# Migration 025 — Candidate UI Read Contracts

Migration 025 is the backend read-contract checkpoint for future Candidate UI
integration. It adds:

- a cohesive authenticated Candidate/ACTIVE/evidence context RPC;
- server-computed Promotion readiness with stable blocker codes;
- current-user review and Promotion capability booleans;
- current-user Candidate review-session continuation discovery;
- Candidate lifecycle provenance appended to `governance_mapping_links`.

Promotion and readiness share a private non-mutating evaluator. The existing
Promotion trigger retains its Migration 023 lock acquisition order and calls the
shared evaluator only after locking the exact Candidate, ACTIVE, registry,
publication, artifact, import, validation, and gate rows. Promotion continues to
revalidate every expected identifier.

`ready=true` is observational only. It is never a lock, reservation, token, or
guarantee of future Promotion success.

Migration 025 does not:

- modify Migrations 023 or 024;
- change `promote_candidate_baseline(...)`;
- add mutation behavior;
- implement frontend integration;
- create a new independent validation-outcome policy.

Validation order:

1. `025_preflight_readonly.sql`
2. `025_candidate_ui_read_contracts.sql`
3. `025_postdeploy_verification.sql`
4. `025_runtime_tests_rollback.sql`
5. direct PostgreSQL multi-session stale/concurrency validation from
   `025_manual_deployment_runbook.md`

The preflight and postdeployment scripts are read-only. Runtime fixtures are
enclosed in one rollback-only transaction. Concurrency evidence must use
independent direct PostgreSQL/`psql` sessions, never Supabase SQL Editor tabs.

Migration 025 backend verification completed successfully in TEST on 2026-10-16:

- preflight, deployment, and all `12/12` postdeployment checks passed;
- the rollback-only runtime suite passed `29/29`, with full rollback restoration;
- same-series serialization passed on C05, including observed blocking and
  successful revalidation after the holding transaction rolled back;
- different-series independence passed between C05 and C06;
- stale-read validation passed with exact SQLSTATE `40001` and no partial writes;
- the six retained-evidence integrity checks passed.

The stale-read run uses the dedicated retained fixture namespace
`T025-STALE-20261016-R1`: series `02550000-0000-4000-8000-000000000001`, V1
`02550101-0000-4000-8000-000000000001`, V2
`02550201-0000-4000-8000-000000000001`, and V3
`02550301-0000-4000-8000-000000000001`. Its first provisioning attempt exposed
the backend-scoped empty placeholder left by the transaction-local
`s2t_fhir.finalizing_baseline` custom GUC after SP02 committed. Recovery retained
SP01/SP02 and ran SP03 and SP04 in separate fresh PostgreSQL backends, followed
by SP05-SP11 in another fresh connection. No C01-C06 fixture was mutated.

The retained final state is V1 `ACTIVE`, V2 `SUPERSEDED`, and V3 `CANDIDATE`,
with lifecycle/candidate-context/activation-context/relationship cardinalities
`5/3/1/1`. The fixture is retained TEST evidence and must not be cleaned up or
replayed through B1.

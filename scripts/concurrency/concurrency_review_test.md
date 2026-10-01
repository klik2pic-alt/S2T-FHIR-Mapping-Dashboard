# S2T FHIR Mapping Dashboard
## Concurrent Review Runtime Test

### Scope

This test verifies runtime serialization of concurrent review operations against the same governed mapping record.

Target scope:

- Source system: `CATO`
- FHIR resource: `MedicationRequest`
- Review model: `s2t_fhir.mapping_review_event`
- Core function: `s2t_fhir_api._record_mapping_review_core()`
- Internal wrapper used for test isolation: `s2t_fhir_api._record_mapping_review()`

The purpose of this test is to verify that concurrent review operations against the same mapping record are serialized at runtime and cannot create competing review-event branches.

---

## Expected behavior

When two database sessions attempt to review the same mapping record concurrently:

```text
Session A
→ locks mapping record
→ writes review event
→ keeps transaction open

Session B
→ attempts review on same mapping
→ waits on database lock
→ does not create competing event

Session A
→ COMMIT or ROLLBACK

Session B
→ lock released
→ operation continues
```

The implementation is expected to provide two layers of protection:

1. Runtime serialization through row locking (`FOR UPDATE`)
2. Database-level prevention of branching through:

```text
mapping_review_event_superseded_once_uq
UNIQUE(supersedes_event_id)
WHERE supersedes_event_id IS NOT NULL
```

---

# Preconditions

The database must contain:

- One active governed baseline for:
  - `CATO`
  - `MedicationRequest`
- A valid mapping node
- The internal review actor:

```text
principal_id:
2fb03b24-4795-4b19-bf54-b1359593e0d0

display_name:
S2T FHIR import service
```

Current test node:

```text
map-v1-00148e3980ec91a59ace0eaccfe3ce77d6550262703cf8825c13455fc7875c59
```

The test is non-destructive as long as both sessions end with:

```sql
ROLLBACK;
```

---

# Database connection

Open two separate PowerShell windows.

Use the same database connection command in both:

```powershell
& "C:\Program Files\PostgreSQL\17\bin\psql.exe" "host=aws-0-eu-central-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.brnybpfcrfbbboslopap sslmode=require" -W
```

After entering the database password, both windows should show:

```text
postgres=>
```

---

# Test Procedure

## Session A

In the first `psql` window:

```sql
BEGIN;
```

Run:

```sql
select s2t_fhir_api._record_mapping_review(
    'map-v1-00148e3980ec91a59ace0eaccfe3ce77d6550262703cf8825c13455fc7875c59',
    'REVIEWED',
    '2fb03b24-4795-4b19-bf54-b1359593e0d0'::uuid,
    NULL,
    'Concurrency test A - holding mapping lock'
);
```

Expected result:

```text
_record_mapping_review
------------------------

(1 row)
```

### Important

Do not run:

```sql
COMMIT;
```

or:

```sql
ROLLBACK;
```

yet.

Keep Session A transaction open.

---

## Session B

In the second `psql` window:

```sql
BEGIN;
```

Run:

```sql
select s2t_fhir_api._record_mapping_review(
    'map-v1-00148e3980ec91a59ace0eaccfe3ce77d6550262703cf8825c13455fc7875c59',
    'NEEDS_FOLLOW_UP',
    '2fb03b24-4795-4b19-bf54-b1359593e0d0'::uuid,
    NULL,
    'Concurrency test B - should wait for mapping lock'
);
```

Expected behavior:

The query should not return immediately.

The `psql` window should appear to wait.

This indicates that Session B is blocked on the lock held by Session A.

---

# Verify Blocking

While Session B is waiting, return to Session A.

Run:

```sql
select
    a.pid,
    a.state,
    a.wait_event_type,
    a.wait_event,
    pg_blocking_pids(a.pid) as blocking_pids,
    left(a.query, 150) as waiting_query
from pg_stat_activity a
where a.datname = current_database()
  and a.pid <> pg_backend_pid()
  and a.wait_event_type = 'Lock';
```

Expected result should resemble:

```text
pid              = <Session B PID>
state            = active
wait_event_type  = Lock
wait_event       = transactionid
blocking_pids    = {<Session A PID>}
```

Example evidence observed during baseline testing:

```text
pid              = 399209
state            = active
wait_event_type  = Lock
wait_event       = transactionid
blocking_pids    = {396062}
```

Expected conclusion:

```text
Session B is blocked by Session A.
```

---

# Release the Lock

In Session A run:

```sql
ROLLBACK;
```

Expected behavior:

- Session A test event is discarded.
- Session A lock is released.
- Session B should immediately continue.

---

# Verify Session B Continues

Return to Session B.

The previously waiting statement should now complete:

```text
_record_mapping_review
------------------------

(1 row)
```

This confirms that Session B waited for the lock and resumed after Session A released it.

---

# Cleanup

In Session B run:

```sql
ROLLBACK;
```

This removes the Session B test event.

Both test transactions are now cleaned up.

---

# PASS Criteria

The test is considered **PASS** if all of the following are true:

- Session A successfully writes a review event inside an open transaction.
- Session B attempts a review against the same mapping record.
- Session B waits instead of immediately completing.
- `pg_stat_activity` shows:
  - `wait_event_type = 'Lock'`
  - Session A appears in `blocking_pids`
- After Session A releases the transaction:
  - Session B continues successfully.
- Both test transactions are rolled back.
- No test review event remains persisted.

Expected final verdict:

```text
CONCURRENCY-01
PASS
Concurrent review operations on the same mapping record are serialized.
```

---

# Architecture Verified

This test verifies the following runtime behavior:

```text
Review request A
        ↓
mapping_record row lock
        ↓
Review request B
        ↓
WAIT
        ↓
A completes / rolls back
        ↓
B resumes
```

The runtime lock is complemented by the database invariant:

```sql
CREATE UNIQUE INDEX mapping_review_event_superseded_once_uq
ON s2t_fhir.mapping_review_event (supersedes_event_id)
WHERE supersedes_event_id IS NOT NULL;
```

Together these provide:

```text
Runtime serialization
+
Database-level branch prevention
```

This protects the review event chain from concurrent competing successors.

---

# Related Regression Coverage

The primary automated regression suite is:

```text
scripts/runtime_regression_tests.sql
```

Current established baseline:

```text
20 / 20 PASS
```

Coverage includes:

- Authentication
- Authorization
- Review session lifecycle
- Review session ownership
- Mandatory session governance for authenticated human review
- Review workflow transitions
- Blank-note validation
- Internal service backward compatibility
- Single current review
- Cross-mapping integrity
- Cross-baseline integrity
- Cycle detection
- Branch detection
- Unique database enforcement

Concurrency remains a separate manual/two-session test because it requires two independent database sessions.

---

# Baseline Result

Date:

```text
2026-09-27
```

Result:

```text
CONCURRENCY-01 PASS
```

Observed evidence:

```text
Session B:
wait_event_type = Lock

blocking_pids:
Session A PID

After Session A ROLLBACK:
Session B completed successfully.
```

Final status:

```text
Concurrent review serialization verified at runtime.
```
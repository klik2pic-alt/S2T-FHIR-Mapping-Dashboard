# Migration 023 two-session concurrency test plan

Target: `S2T-FHIR-DDL-Test`

Do not run this plan until Phase C and the rollback-only Phase D suite pass.
Every session must use an explicit transaction. Use only dedicated fixtures
prepared for Migration 023 validation; never substitute an existing governed
baseline, review, or governance question.

Two execution modes are distinguished below:

- **rollback-only blocking mode** proves the blocking point and lock order. The
  holding session rolls back, the waiting session is allowed to resume, and it
  also rolls back. This mode leaves no persistent mutation.
- **committed winner/loser mode** proves stale-state rejection after the winner
  commits. Because append-only governed evidence cannot be deleted afterward,
  run this mode only in an approved disposable database/fixture whose retained
  synthetic rows are explicitly acceptable. Otherwise report it as
  `NOT RUN / FIXTURE REQUIRED`; do not weaken it into a rollback-only stale test.

## Shared preparation

Before opening the two sessions, record exact fixture identifiers for:

- candidate baseline and root Candidate lifecycle event;
- committed Candidate publication import;
- current ACTIVE baseline/event, when applicable;
- reviewed Candidate gate evaluation, when applicable;
- Candidate review session and node ID, when applicable;
- synthetic governance question, resource configuration, and node ID.

Supabase SQL Editor does not guarantee backend/session affinity between separate
Run actions. A lock-holding worker must therefore execute `BEGIN` → authenticated
wrapper → bounded `pg_sleep(...)` → `ROLLBACK` in a single Run. Never use one Run
to open a transaction and a later Run to continue or roll it back.

In each session run:

```sql
begin;
select pg_backend_pid();
set constraints all deferred;
```

Observe blocking from a third read-only SQL Editor tab:

```sql
select pid, state, wait_event_type, wait_event, pg_blocking_pids(pid)
from pg_stat_activity
where pid in (<SESSION_A_PID>, <SESSION_B_PID>)
order by pid;
```

The common lock order is:

1. `baseline_series`;
2. exact current Candidate lifecycle event;
3. operation-specific rows—review session, mapping record, governance question/link;
4. current ACTIVE lifecycle context for Promotion;
5. mapping-resource registry and immutable publication/gate evidence.

No workflow operation acquires one of these rows and later attempts to acquire
the owning series in reverse order.

## C01 — concurrent first Candidate creation in one series

Use the dedicated retained replacement fixture
`T023-CONC-PACK-20261010-R2-C01`. The original C01-A Candidate from
`T023-CONC-PACK-20261009-R1` is retained append-only evidence and is not reused,
deleted, rewritten, or superseded for this test. Execute the Supabase-compatible
worker and observer blocks from `scripts/023_c01_r2_runtime_rollback.sql`.

Session A:

1. Call `s2t_fhir_api.publish_candidate_baseline(...)` for baseline A with both
   expected Candidate arguments `NULL`.
2. Hold the transaction with a bounded `pg_sleep(...)` and then `ROLLBACK`, all
   in that same Run action.

Session B:

1. Call the same wrapper for baseline B in the same series, also expecting no
   current Candidate.
2. It must block on the `baseline_series` row.
3. After Session A rolls back, it resumes successfully and rolls back in its
   original Run action.

Resolution:

1. In rollback-only blocking mode, Session A's bounded hold ends in `ROLLBACK`.
   Session B resumes, succeeds against the restored no-Candidate state, and its
   same Run ends in `ROLLBACK`.
   Final state: zero Candidates from this test.
2. In committed winner/loser mode, commit Session A. Session B resumes and must
   fail with SQLSTATE `40001` because its expected no-Candidate state is stale.
   Roll back Session B. Final disposable-fixture state: exactly one Candidate.

## C02 — concurrent Candidate replacement

Both sessions use the same exact current Candidate baseline/event but different
new baselines.

Session A calls `publish_candidate_baseline(...)` and holds the transaction.
Session B calls it with the same expected Candidate identity and blocks at the
series lock. In rollback-only blocking mode, A rolls back and B may proceed,
then B rolls back. In committed winner/loser mode, A commits and B fails with
`40001`. The disposable fixture must have one current Candidate, one successor
of the replaced Candidate event, and no fork.

## C03 — Candidate Review versus Candidate Replacement

Session A:

1. Start or use an `OPEN_CURRENT` Candidate review session.
2. Call a Candidate review write API for one mapping node.
3. Hold the transaction after it locks the series/Candidate/session/mapping.

Session B calls Candidate Replacement for that Candidate and blocks at the
series lock.

Rollback-only blocking mode proves that B waits and both sessions can roll back.
In committed winner/loser mode, when A wins, A's review commits to the old
Candidate and B then replaces it successfully; the old history remains readable
and the new Candidate has no inherited review. Reverse the order in a second
disposable run: if B wins, A resumes and fails with `40001` because its
Candidate event is stale.

## C04 — Candidate Governance link versus Candidate Replacement

Session A calls `gov_link_candidate_mapping(...)` for the exact Candidate and
holds the transaction after acquiring series/Candidate/question/mapping locks.
Session B attempts Candidate Replacement and blocks on the series row.

Rollback-only blocking mode proves the series-lock wait without retaining a
link. In committed winner/loser mode, if A wins, the link remains attached to
the old Candidate after B replaces it. If B wins, A must fail with `40001`. No
link may be rewritten or copied to the replacement Candidate.

## C05 — concurrent Promotion attempts

Both sessions call `promote_candidate_baseline(...)` with the same exact
Candidate, import, gate, and expected ACTIVE identities.

Session A holds the series lock after the call. Session B blocks at that lock.
Rollback-only blocking mode rolls A back, allows B to resume, then rolls B back.
In committed winner/loser mode, after A commits, B resumes and fails with
`40001`: its Candidate and/or ACTIVE expectation is stale. The disposable
fixture contains exactly one activation context, one new ACTIVE event, and at
most one supersession event/relationship.

## C06 — Promotion versus Candidate Replacement

Session A promotes the current Candidate and holds the transaction. Session B
attempts to replace that Candidate and blocks on the series lock.

Rollback-only blocking mode proves the common series-lock serialization in both
orders and rolls both sessions back. In committed winner/loser mode, if
Promotion wins, Replacement fails with `40001` because no matching current
Candidate remains. Repeat in a disposable fixture with the order reversed: if
Replacement wins, Promotion fails with `40001` because its expected Candidate
is stale. Neither ordering may leave a partial activation context or forked
lifecycle chain.

## C07 — operations on different series

Session A performs Candidate Replacement or Promotion in series A and holds the
transaction. Session B performs the corresponding operation in series B.

Expected result: Session B does not wait on Session A's series lock. Both can
reach their operation-specific validations independently. Any failure must be a
fixture/eligibility failure, not cross-series lock contention.

## Acceptance evidence

For each test capture:

- both backend PIDs;
- blocking query output;
- winner result;
- loser SQLSTATE and message;
- final current lifecycle leaves;
- activation/context/relationship counts where applicable;
- final `ROLLBACK` output for both sessions in rollback-only blocking mode; or
- the approved disposable-fixture disposition for committed winner/loser mode.

Unexpected deadlock SQLSTATE `40P01`, a loser that succeeds against stale state,
or any cross-series blocking is a hard stop.

# Repository engineering rules

These rules are durable constraints for future work in this repository.

- Applied database migrations are immutable. Correct deployed behavior with a
  later, scoped migration; never rewrite an applied migration to match the
  current database.
- Concurrency tests that depend on backend/session affinity must use independent
  direct PostgreSQL/`psql` sessions. Supabase SQL Editor tabs are not evidence
  of stable session affinity.
- Operations that mutate the same baseline series must serialize on the
  baseline-series locking path. Operations on different baseline series must
  remain independently executable.
- Prefer rollback-only concurrency runs for blocking evidence. A committed
  winner/loser run is allowed only on an approved disposable fixture where the
  retained append-only evidence is acceptable.
- Retained failed or historical fixture evidence must not be deleted, rewritten,
  or normalized merely to make a verifier report green. Document the exception
  and validate the behavior on a separate retained replacement fixture.
- Migration 023/024 concurrency closure is recorded in
  `scripts/023_024_concurrency_validation_closure.md`. The original R1 C01
  exception is historical evidence, not a product regression.

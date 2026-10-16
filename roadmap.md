# S2T FHIR Mapping Dashboard roadmap

## Completed backend foundations

- [x] Migration 023 Candidate lifecycle, Candidate Review, Candidate
  Governance, and Promotion foundation deployed.
- [x] Migration 024 scoped Candidate Review actor-validation correction
  deployed. The correction changes only the three private Candidate Review
  cores; authenticated wrapper authorization through `S2T_REVIEW_WRITE` remains
  intact.
- [x] Migration 023/024 concurrency validation complete. C01 passed on retained
  replacement fixture `T023-CONC-PACK-20261010-R2-C01`; C02-C07 passed on
  canonical fixture `T023-CONC-PACK-20261009-R1`.
- [x] Migration 025 Candidate UI read contracts deployed and fully verified in
  TEST: postdeployment `12/12`, rollback runtime `29/29` with full restoration,
  same-series serialization, different-series independence, stale-read exact
  SQLSTATE `40001` with no partial writes, and retained-evidence integrity all
  passed.

Migration 025 introduces backend read contracts only: cohesive Candidate/ACTIVE
context, shared server-computed Promotion readiness, current-user capability
visibility, Candidate review-session continuation, and Candidate lifecycle
provenance on governance mapping-link reads. It does not implement the frontend,
does not change the public Promotion signature, and does not modify immutable
Migrations 023 or 024.

The audit-grade closure record is
`scripts/023_024_concurrency_validation_closure.md`. The deployed Migration 023
and 024 SQL files are immutable and are not altered by this documentation
checkpoint.

Migration 025 stale-read closure uses the dedicated retained fixture
`T025-STALE-20261016-R1` (series
`02550000-0000-4000-8000-000000000001`; V1/V2/V3
`02550101-0000-4000-8000-000000000001`,
`02550201-0000-4000-8000-000000000001`, and
`02550301-0000-4000-8000-000000000001`). Initial provisioning exposed the
backend-scoped empty placeholder left by the transaction-local
`s2t_fhir.finalizing_baseline` custom GUC after SP02. SP01/SP02 were retained;
SP03 and SP04 were recovered in separate fresh PostgreSQL backends, then
SP05-SP11 completed in another fresh backend. Final retained state is V1
`ACTIVE`, V2 `SUPERSEDED`, V3 `CANDIDATE`, with exact `5/3/1/1`
lifecycle/candidate-context/activation-context/relationship cardinalities and
all six integrity checks passing. No C01-C06 fixture was mutated.

## Future product work

- [ ] Candidate diff and change detection.
- [ ] Review carry-forward and invalidation policy.
- [ ] Governance blocking policy.
- [ ] Candidate workflow UI and product integration.

These future items are intentionally not marked complete by the backend
concurrency milestone.

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

The audit-grade closure record is
`scripts/023_024_concurrency_validation_closure.md`. The deployed Migration 023
and 024 SQL files are immutable and are not altered by this documentation
checkpoint.

## Future product work

- [ ] Candidate diff and change detection.
- [ ] Review carry-forward and invalidation policy.
- [ ] Governance blocking policy.
- [ ] Candidate workflow UI and product integration.

These future items are intentionally not marked complete by the backend
concurrency milestone.

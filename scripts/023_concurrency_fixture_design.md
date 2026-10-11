# Migration 023 dedicated concurrency fixture design

Document stage: design only. This document contains no executable SQL and does
not authorize fixture provisioning or a Supabase change.

Companion execution plan: `scripts/023_concurrency_test_plan.md`.

## Scope and safety boundary

The first concurrency-validation pass is **rollback-only blocking mode** for
C01-C07. It proves the common series-lock boundary, lock order, and absence of
cross-series contention. It does not attempt to prove stale-state rejection
after a committed winner.

Two phases must remain separate:

1. **Fixture provisioning (future, separately approved):** create and commit a
   named synthetic fixture pack so that two independent sessions can see the
   same seed rows. Some seed evidence is append-only and therefore intentionally
   retained in TEST.
2. **Concurrency execution:** both worker sessions start explicit transactions;
   every workflow mutation is rolled back. The seeded fixture state must be
   byte-for-byte/logically unchanged after each case.

Do not create fixtures ad hoc inside either worker session. Uncommitted setup is
not visible to the other session. Do not reuse an existing governed baseline,
review session, release-gate evaluation, governance question, or ACTIVE context.

Committed winner/loser mode remains `NOT RUN / FIXTURE REQUIRED` until a
separate disposable fixture and retention approval exist.

## Fixture-pack identity and manifest

Provision one immutable pack identifier, for example
`T023-CONC-<UTC timestamp or approved run tag>`. Every synthetic code, label,
description, source system, resource configuration, filename, session name,
question title, and reason must include that pack identifier and the case ID.

The provisioning step must emit a read-only manifest. Store the manifest as
test evidence and do not rediscover rows by broad `LIKE` queries during a run.
For every applicable case record:

- fixture pack ID and case ID;
- series ID and exact source-system/resource pair;
- every baseline ID, baseline code, artifact ID, and committed import ID;
- current Candidate baseline ID and root Candidate lifecycle-event ID;
- current ACTIVE baseline ID and ACTIVE lifecycle-event ID;
- mapping resource configuration ID, mapping-record ID, and derived node ID;
- review-session ID and its expected derived state;
- governance-question ID;
- release-gate evaluation ID;
- seed timestamps and expected pre-test row/count fingerprints;
- the authenticated worker principal IDs and granted capabilities.

Use deterministic, case-specific logical mapping keys and artifact digests.
UUIDs may be generated during provisioning, but the resulting values must be
captured in the manifest and passed explicitly during execution.

## Provisioning transaction boundaries

Fixture preparation must preserve the existing invariant exactly:

> MVP import finalization supports exactly one baseline per transaction

Any transaction that finalizes an import to terminal `COMMITTED` state may
finalize imports for only one baseline. The fixture package must not weaken,
bypass, disable, or work around this invariant. In particular:

- never finalize imports belonging to different baselines in one transaction;
- finalize each baseline/import in its own approved transaction, or use an
  equivalent accepted workflow whose transaction boundaries still contain
  exactly one baseline finalization;
- commit and verify that finalization before starting the next baseline's
  finalization transaction;
- perform cross-baseline publication, review, gate, Promotion, and fixture-state
  assembly only after their required baseline finalizations are visible;
- record every finalization transaction and its single baseline/import IDs in
  the fixture manifest.

Rows that prepare an import may be staged through the accepted import workflow,
but the transition that makes it `COMMITTED` is the boundary governed by this
rule. A failure rolls back only that baseline's preparation/finalization unit;
it must not be retried by bundling it with another baseline.

The multi-baseline cases are provisioned as follows:

- **C01:** finalize baseline A and baseline B in two separate transactions;
  leave both unpublished.
- **C02:** finalize V1, V2A, and V2B in three separate transactions; only after
  all three are committed, publish V1 as the seed Candidate in a later
  transaction.
- **C03:** finalize the Candidate baseline and its unpublished replacement in
  two separate transactions; then publish the Candidate and add its mapping and
  open review-session seed through subsequent accepted transactions.
- **C04:** finalize the Candidate baseline and its unpublished replacement in
  two separate transactions; then publish the Candidate and add its mapping and
  independent governance-question seed through subsequent accepted
  transactions.
- **C05:** finalize V1 and V2 in separate transactions. Build/review/gate and
  promote V1 only after V1 finalization; publish, review, and gate V2 only after
  V2 finalization. No transaction finalizes both versions.
- **C06:** use three separate finalization transactions for V1, V2, and V3.
  Build/review/gate and promote V1 after its finalization, build the
  promotion-ready V2 after its finalization, and leave finalized V3
  unpublished.
- **C07:** use four separate finalization transactions: series A V1, series A
  V2, series B V1, and series B V2. Publish each series' V1 only after its own
  finalization; both V2 baselines remain unpublished.

Transaction grouping may be more granular than this plan, but never less
granular at a `COMMITTED` import transition.

## Shared seed building blocks

### Worker identities

Use dedicated, enabled synthetic human principals resolvable from the trusted
authenticated request context. Grant only the capabilities needed by the pack:

- `S2T_BASELINE_UPLOAD` for Candidate publication/replacement;
- `S2T_REVIEW_WRITE` for Candidate Review;
- `S2T_BASELINE_PROMOTE` for Promotion.

Candidate governance linking requires the same exact active
`S2T_REVIEW_WRITE` authorization path, not a separate baseline capability. The
repository definition proves the following call chain:

1. `s2t_fhir_api.gov_link_candidate_mapping(...)` calls
   `s2t_governance._current_reviewer_principal()`;
2. `_current_reviewer_principal()` calls
   `s2t_fhir_api._require_authenticated_review_principal()`;
3. `_require_authenticated_review_principal()` resolves the authenticated
   principal and requires exactly one active `review_actor_authorization` row
   whose `capability_code` is `S2T_REVIEW_WRITE`; zero or ambiguous active
   grants fail with SQLSTATE `42501`.

Therefore the C04 worker principal must be an enabled Supabase-authenticated
principal with exactly one current, unrevoked `S2T_REVIEW_WRITE` grant. Function
`EXECUTE` permission for the `authenticated` role is necessary but is not by
itself sufficient.

Prefer two worker principals (Session A and Session B) with the same minimal
capability set. This keeps actor provenance explicit and prevents the test from
depending on one shared authenticated identity. Provisioning may use a separate
fixture-owner principal.

### Import-ready unpublished baseline

An unpublished baseline building block contains exactly one baseline version,
one authoritative artifact, and one terminal `COMMITTED` import for that exact
baseline/artifact pair. It has no lifecycle event, Candidate context, review,
governance link, release-gate evaluation, or activation context.

### Published Candidate with one accepted mapping

For C03-C06, extend the import-ready baseline with a case-specific enabled
mapping-resource registry row and exactly one accepted mapping node:

- artifact sheet manifest;
- accepted import candidate row tied to the committed import;
- unique logical mapping identity for the case-specific source system/resource;
- mapping record with a valid subtype row (prefer one simple
  `ELEMENT_MAPPING`);
- valid, nonblank target FHIR path and deterministic derived node ID;
- root `CANDIDATE` lifecycle event and immutable Candidate publication context.

One mapping is intentional: it minimizes seed surface while still exercising
the mapping-record lock and permits complete Promotion eligibility to be proved
without review-cardinality ambiguity.

### Promotion-ready Candidate

A promotion-ready Candidate adds:

- one Candidate review session pinned to the root Candidate event;
- a current `REVIEWED` event for every Candidate mapping (exactly one in this
  design);
- the review session closed after the final review event, with no other open
  session for that Candidate event;
- one current `PASSED` release-gate evaluation for the authoritative artifact,
  backed by the exact committed import and validation run;
- complete passing release-gate requirement results;
- strictly ordered evidence timestamps, all no later than the planned Promotion
  time.

Each Promotion fixture uses its own synthetic source-system/resource pair and
enabled mapping-resource registry row. This prevents an unrelated current
ACTIVE release from making `_active_release_context` ambiguous.

### Existing ACTIVE plus next Candidate

For C05 and C06, provision the fullest Promotion path rather than the initial
ACTIVE shortcut:

1. Build, review, gate, and promote seed baseline V1 in the dedicated series.
2. Publish V2 as the new current Candidate without changing V1's current ACTIVE
   leaf.
3. Fully review and gate V2.
4. Capture V1 ACTIVE and V2 Candidate/import/gate identities in the manifest.

This seed exercises the current-ACTIVE locks and supersession path while all
concurrency operations themselves remain rollback-only.

## Case-specific fixtures

| Case | Dedicated seed state | Session A target | Session B target | Required post-rollback seed state |
|---|---|---|---|---|
| C01 | One empty series; two different import-ready unpublished baselines A and B in that series; no Candidate and no ACTIVE | Publish A, expecting both Candidate identities `NULL` | Publish B with the same null expectation | No Candidate; A and B still have no lifecycle history |
| C02 | One series with current Candidate V1; two different import-ready unpublished replacements V2A and V2B | Replace V1 with V2A using exact V1 baseline/event | Replace V1 with V2B using the same exact expectation | V1 remains the sole current Candidate; neither replacement has lifecycle history |
| C03 | One published Candidate with one accepted mapping; one committed `OPEN_CURRENT` review session pinned to its root Candidate event; one import-ready unpublished replacement | Mark the exact node `REVIEWED` in the open session and hold | Replace the same Candidate | Session remains `OPEN_CURRENT`; no new review event; original Candidate remains current; replacement remains unpublished |
| C04 | One published Candidate with one accepted mapping; one synthetic open governance question with its `QUESTION_CREATED` evidence; no link for the node; one import-ready unpublished replacement | Link the question to the exact Candidate node and hold | Replace the same Candidate | No mapping link or `MAPPING_LINKED` event; question retains only its seed evidence; original Candidate remains current |
| C05 | One dedicated series with current ACTIVE V1 and fully reviewed/gated current Candidate V2 | Promote V2 using exact Candidate/import/gate and exact V1 ACTIVE identities | Invoke the identical Promotion expectation | V1 remains current ACTIVE; V2 remains current Candidate; activation, lifecycle, and relationship counts match the seed |
| C06 | One dedicated series with current ACTIVE V1, fully reviewed/gated current Candidate V2, and one import-ready unpublished replacement V3 | Order 1: promote V2. Order 2: replace V2 with V3 | Perform the opposite operation against the same exact V2 expectation | V1 remains ACTIVE; V2 remains Candidate; V3 remains unpublished; no new activation context or relationship |
| C07 | Two independent dedicated series, each with current Candidate V1 and one import-ready unpublished V2; no shared baselines/artifacts/imports | Replace Candidate in series A and hold | Replace Candidate in series B | Both original Candidates remain current; both replacements remain unpublished |

C06 requires two rollback-only runs with reversed acquisition order. The same
dedicated C06 seed may be reused because each run must return exactly to the
manifested state.

C07 deliberately uses Candidate Replacement rather than Promotion. That keeps
the nonblocking assertion focused on the `baseline_series` lock and avoids a
false dependency through a shared registry or ACTIVE API resource context.

## Rollback-only execution contract

For C01-C06:

1. Validate the fixture against the manifest before either worker begins.
2. Start Session A, execute the selected wrapper, and leave its transaction
   open only after the wrapper returns successfully.
3. Start Session B with the stale-at-start expectation from the manifest.
4. The observer must show Session B waiting and `pg_blocking_pids(Session B)`
   containing Session A. The expected blocking boundary is the dedicated
   `baseline_series` row.
5. Roll back Session A. Session B must resume and succeed against the restored
   seed state.
6. Roll back Session B.
7. Re-run the fixture fingerprint and require exact equality with the manifest.

For C07, Session B must complete while Session A is still open. The observer
must show no blocker from Session A. A C07-only bounded lock timeout may be used
in the future execution package as a deterministic tripwire; do not use such a
timeout in C01-C06, where waiting is the expected result.

No worker transaction may commit, including after an expected error. A worker
error leaves that transaction unsuitable for further assertions; roll it back
and restart the case from the manifested seed state.

## Fingerprints and acceptance evidence

Capture a scoped pre/post fingerprint for each case, limited to its exact
manifested identifiers. At minimum include:

- current Candidate and ACTIVE lifecycle leaves;
- lifecycle-event and baseline-relationship counts for the series;
- Candidate-context and activation-context counts;
- lifecycle-history count for every unpublished target baseline;
- current review event and total review-event count for the C03 node;
- mapping-link and governance-event counts for the C04 question;
- release-gate identity and review completeness for C05/C06;
- both worker PIDs, observer output, wrapper result, and final `ROLLBACK` output.

Acceptance requires:

- C01-C06 block only through the expected same-series serialization path;
- C07 has no cross-series wait;
- both worker transactions end in `ROLLBACK`;
- every post-test fingerprint equals its pre-test value;
- no deadlock (`40P01`), timeout, unexpected uniqueness failure, or eligibility
  error is reclassified as a concurrency pass.

## Global fingerprint and post-validation policy

Provisioning is intentionally persistent and will change global TEST
fingerprints. In particular, the retained C05/C06 ACTIVE fixtures can change
`s2t_fhir_api.active_baseline`, `_active_release_context`, active mapping and
review projections, and any aggregate fingerprint derived from the governed
base tables. Scoped before/after equality during C01-C07 proves rollback of the
concurrent operations; it does not imply equality with the global TEST state
that existed before fixture provisioning.

The approved policy for this fixture design is the fallback reference-point
policy:

- capture and retain the complete global fingerprint set immediately before
  provisioning;
- after all provisioning transactions pass their checks, capture the complete
  global fingerprint set again and bind it to the exact fixture-pack manifest;
- treat that post-provisioning manifest and fingerprint set as the new TEST
  reference point for concurrency validation and later verification;
- never delete, update, rewrite, or otherwise conceal append-only fixture
  evidence to restore an earlier fingerprint.

This fallback is required because the repository currently exposes Candidate
publication/replacement and Promotion workflows but no authenticated,
fixture-specific decommission wrapper. Although the lifecycle validator admits
certain append-only transitions to `SUPERSEDED`, inventing a privileged direct
decommission operation would be a new operational contract and is outside this
approved design. No such transition may be improvised by the provisioning or
concurrency package.

Consequently, synthetic C05/C06 current ACTIVE/CANDIDATE state remains visible
in TEST after validation unless a separate, reviewed append-only decommission
design is approved later. Any future decommission must append only lifecycle
history permitted by the model, preserve all prior evidence, produce a new
manifest/fingerprint reference point, and must not delete or rewrite governed
history.

## Provisioning approval gate

Before any fixture SQL is authored or executed, approve all of the following:

- intentional retention in TEST of the complete synthetic footprint, including
  every applicable `principal`, authorization-history row, `baseline_series`,
  `baseline_version`, `artifact`, `baseline_artifact`,
  `artifact_sheet_manifest`, `import_run`, `import_candidate_row`,
  `logical_mapping_identity`, `mapping_record`, mapping subtype row,
  `mapping_resource_registry`, lifecycle event,
  `baseline_candidate_context`, `review_session`, `mapping_review_event`,
  `validation_run`, `release_gate_evaluation`, `release_gate_result`,
  governance question/event/link, `baseline_activation_context`, and
  `baseline_relationship`;
- explicit acknowledgement that append-only governed history created by the
  fixture pack is intentionally retained in TEST and will not be deleted or
  rewritten;
- the fixture-pack naming/tag and target TEST project;
- the exact synthetic source-system/resource and resource-config IDs for
  C03-C06;
- whether one retained fixture pack is sufficient or a new pack is required per
  validation cycle;
- the evidence location for the emitted manifest, scoped before/after
  fingerprints, and global pre/post-provisioning fingerprints;
- acceptance of the post-provisioning manifest as the new TEST reference point
  while synthetic current state remains present.

Until that approval exists, the correct execution status for C01-C07 is
`NOT RUN / FIXTURE REQUIRED`.

## Final status

Status: READY_FOR_PROVISIONING-SQL-DESIGN

All four required design changes are resolved: single-baseline finalization
transaction boundaries are explicit; the full retained footprint is covered;
the global fingerprint/reference-point policy is defined without deleting or
rewriting evidence; and the Candidate Governance authorization path is proven
as exactly one active `S2T_REVIEW_WRITE` grant. This status authorizes only the
next design step; it does not authorize SQL creation or execution.

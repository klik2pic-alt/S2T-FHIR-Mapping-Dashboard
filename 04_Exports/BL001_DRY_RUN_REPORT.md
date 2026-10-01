# BL-001 Dry-Run Import Report

## Outcome

`READY_FOR_BL001_RUNTIME_IMPORT`

No SQL was executed. No database connection was made. The workbook and migrations 001–012 were not modified. The dry run stopped before commit, release-gate evaluation, or lifecycle activation.

## Artifact

- File: `01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`
- SHA-256: `3c7e551109ab814712c3b7bbbbbda4d41b457327452e4eee7746e698283fdc46`
- Bytes: `252859`
- Payload importer: `bl001-dry-run-v1`

## Reconciliation

| Slice | Candidates | Accepted | Quarantined | Warnings | Errors |
|---|---:|---:|---:|---:|---:|
| `Cato Status Mapping` | 9 | 9 | 0 | 0 | 0 |
| `S2T MedicationRequestCato` | 238 | 237 | 1 | 4 | 1 |
| `הנחיות נוספות מעודכן` | 46 | 46 | 0 | 1 | 0 |

### Mapping kind

| Kind | Candidates | Accepted | Quarantined | Warnings | Errors |
|---|---:|---:|---:|---:|---:|
| `ELEMENT_MAPPING` | 238 | 237 | 1 | 4 | 1 |
| `GOVERNANCE_GUIDANCE` | 46 | 46 | 0 | 1 | 0 |
| `STATUS_MAPPING_RULE` | 9 | 9 | 0 | 0 | 0 |

### Decision Status

| Status | Candidates | Accepted | Quarantined | Warnings | Errors |
|---|---:|---:|---:|---:|---:|
| `FINAL` | 122 | 122 | 0 | 0 | 0 |
| `WIP` | 1 | 1 | 0 | 0 | 0 |
| `OPEN` | 1 | 1 | 0 | 0 | 0 |
| `DO NOT MAP` | 169 | 168 | 1 | 5 | 1 |
| `N/A` | 0 | 0 | 0 | 0 | 0 |

### Disposition and severity

- Accepted: 292
- Quarantined: 1
- Warnings: 5
- Errors: 1

## Quarantine

Exactly one candidate is quarantined: `S2T MedicationRequestCato!77` (`A77:Q77`). No `logical_mapping_identity`, `mapping_record`, or subtype record was generated for it.

## Generated records

| Table | Rows |
|---|---:|
| `artifact` | 1 |
| `artifact_location` | 1 |
| `artifact_sheet_manifest` | 7 |
| `baseline_artifact` | 1 |
| `baseline_series` | 1 |
| `baseline_version` | 1 |
| `element_mapping` | 237 |
| `governance_guidance` | 46 |
| `import_candidate_row` | 293 |
| `import_run` | 1 |
| `import_run_metric` | 62 |
| `logical_mapping_identity` | 292 |
| `mapping_record` | 292 |
| `quarantine_case` | 1 |
| `quarantine_event` | 1 |
| `status_mapping_rule` | 9 |
| `validation_finding` | 6 |
| `validation_finding_row` | 6 |
| `validation_run` | 1 |

Payload files are in `04_Exports/BL001_DRY_RUN/`. Foreign keys to governed reference/configuration rows are represented by deterministic lookup selectors and must be resolved by the runtime importer inside its future transaction.

## Integrity validation

All generated records passed the offline emulation of applicable migrations 004–009 and the runtime-tested invariants in migration 012.

- Artifact digest and manifest match the BL-001 register.
- Candidate terminal states reconcile 292 accepted plus 1 quarantined to 293.
- Accepted records have exactly one matching subtype: 237 element, 9 status, 46 guidance.
- All six findings link to their subject candidates; the sole error opens the sole quarantine case.
- No `release_gate_evaluation`, `release_gate_result`, or `baseline_lifecycle_event` records were generated.

`READY_FOR_BL001_RUNTIME_IMPORT`

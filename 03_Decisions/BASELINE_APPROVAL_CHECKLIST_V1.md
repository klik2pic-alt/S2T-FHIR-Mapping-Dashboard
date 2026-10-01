# Baseline Approval Checklist v1

## Scope

This checklist is derived only from `03_Decisions/BASELINE_RECONCILIATION_V1.md`. It records approval work required before DDL readiness can be declared. It does not approve any item, alter the source workbook, or authorize implementation.

Allowed approval states are `PENDING`, `APPROVED`, `REJECTED`, and `DEFERRED`.

## Current reconciliation status

- Reconciliation status: `NOT_READY_FOR_DDL`
- Baseline: `BL-001`
- Candidate records: 293
- Accepted records under the proposed partial-import policy: **291**
- Quarantined S2T rows under the proposed policy: **90 and 226**
- Proposed target policy: accepted-with-quarantine, subject to approval

## Approval items

### BA-01 — S2T row 90 Decision Status

| Field | Value |
|---|---|
| ID | `BA-01` / reconciliation reference `BR-01` |
| Source workbook row / location | `S2T MedicationRequestCato!Q90`; target `I90 = requester`; cardinality `J90 = 1..1` after whitespace normalization |
| Issue / decision required | Assign an allowed canonical Decision Status, or explicitly approve quarantine until a governed status is supplied. No value may be inferred from cardinality, profile, or neighboring rows. |
| Current classification | `DATA_QUALITY` |
| Proposed decision | No specific canonical status is proposed. Until an approved status exists, quarantine row 90 under an approved accepted-with-quarantine policy. |
| Owner | CATO/FHIR mapping data owner |
| Required approver | Data owner; team approval is additionally required if the chosen status changes an existing mapping policy. |
| Approval status | `PENDING` |
| Impact on DDL readiness | Blocks atomic import. For `READY_WITH_QUARANTINE`, the quarantine treatment and its durable representation must be approved. For `READY_FOR_DDL` without quarantine, the canonical status must be resolved. |
| Notes | Allowed values are `FINAL`, `WIP`, `OPEN`, `DO NOT MAP`, and `N/A`. Blank is not `N/A`. |

### BA-02 — S2T row 226 duplicate

| Field | Value |
|---|---|
| ID | `BA-02` / reconciliation reference `BR-02` |
| Source workbook row / location | `S2T MedicationRequestCato!A198:Q198` and `A226:Q226` |
| Issue / decision required | Confirm whether row 226 is an accidental duplicate of row 198 or represents a distinct concept whose distinguishing semantics are absent. |
| Current classification | `DATA_QUALITY` |
| Proposed decision | Treat row 198 as the first occurrence and quarantine row 226. Do not import both and do not append a sequence suffix. |
| Owner | CATO/FHIR mapping data owner |
| Required approver | CATO/FHIR mapping data owner |
| Approval status | `PENDING` |
| Impact on DDL readiness | Blocks atomic import. For `READY_WITH_QUARANTINE`, treatment of row 226 as a quarantined duplicate must be approved. For `READY_FOR_DDL` without quarantine, the duplicate must be resolved through governed source data or a governed decision. |
| Notes | Both rows target `dosageInstruction.doseAndRate.rateRatio.denominator.comparator`, have cardinality `0..1`, and have Decision Status `DO NOT MAP`. |

### BA-03 — Fourteen blank cardinalities

| Field | Value |
|---|---|
| ID | `BA-03` / reconciliation reference `BR-03` |
| Source workbook row / location | `S2T MedicationRequestCato!J76,J100:J103,J106:J111,J115,J120:J121` |
| Issue / decision required | Confirm whether all 14 blank cardinalities are intentional, including whether row 76 is an approved structural/extension parent. |
| Current classification | `DATA_QUALITY` |
| Proposed decision | If intentional, retain the blank raw values and emit warnings: row 76 under the structural/extension-parent treatment and the other 13 under the explicit `DO NOT MAP` exception. If not intentional, correct only in a future approved workbook revision. |
| Owner | FHIR mapping owner, with IL-Core/profile owner review for row 76 |
| Required approver | FHIR mapping owner; IL-Core/profile owner for row 76 |
| Approval status | `PENDING` |
| Impact on DDL readiness | Blocks readiness until the warning/exception treatment is confirmed. Once approved, these rows are warnings and do not block either approved import policy. |
| Notes | Row 76 is `FINAL`; the other 13 rows are `DO NOT MAP`. The workbook must not be patched during import. |

### BA-04 — Baseline commit policy

| Field | Value |
|---|---|
| ID | `BA-04` / reconciliation reference `BR-04` |
| Source workbook row / location | Cross-workbook policy; applies particularly to `S2T MedicationRequestCato` rows 90 and 226 |
| Issue / decision required | Choose fully atomic import or accepted-with-quarantine. |
| Current classification | `GOVERNANCE_DECISION` |
| Proposed decision | Adopt accepted-with-quarantine for this Human Working Draft baseline, with 291 accepted records and two quarantined rows. Persist candidate, accepted, error, warning, and quarantine counts; full provenance; and the raw quarantined rows. Mark the baseline visibly incomplete/reconciled-with-quarantine. |
| Owner | Data governance owner and product/technical owner |
| Required approver | Data governance owner and product/technical owner |
| Approval status | `PENDING` |
| Impact on DDL readiness | Mandatory. The decision controls transaction boundaries, baseline state, validation-result storage, and quarantine representation. No DDL readiness state may be declared until it is approved. |
| Notes | A failed transaction must not leave a partial authoritative snapshot. The accepted 291 records must not be presented as a clean 293-row import. |

### BA-05 — Cato Status Mapping translation

| Field | Value |
|---|---|
| ID | `BA-05` / reconciliation reference `BR-05A` |
| Source workbook row / location | `Cato Status Mapping!A7:H13`, `A15:H15`, and `A17:H17`; especially column `G` |
| Issue / decision required | Approve the sheet-specific derived Decision Status rule because the sheet has no native Decision Status column. |
| Current classification | `TEAM_APPROVAL_REQUIRED` |
| Proposed decision | Rows 7–13 and 15 → `FINAL`; row 17 (`ON HOLD (אם קיים)`) → `OPEN`. Preserve column G as `mapping_evidence_status_raw`; do not treat it as implementation status. |
| Owner | CATO product/data owner and FHIR mapping governance |
| Required approver | CATO product/data owner confirms Production semantics; FHIR mapping governance approves the canonical translation. |
| Approval status | `PENDING` |
| Impact on DDL readiness | Mandatory. Canonical status and alias behavior affect constraints and staged validation. |
| Notes | Rows 7–13 and 15 have `G = ממופה`; row 17 has `G = לא קיים` and requires a Production check. |

### BA-06 — Hebrew guidance status translations

| Field | Value |
|---|---|
| ID | `BA-06` / reconciliation reference `BR-05B` |
| Source workbook row / location | `הנחיות נוספות מעודכן!A3:A7` and `A9:A49` |
| Issue / decision required | Approve the four Hebrew-to-canonical Decision Status translations. |
| Current classification | `TEAM_APPROVAL_REQUIRED` |
| Proposed decision | `אושר` → `FINAL`; `דיון קליני` → `OPEN`; `לא ניתן למפות` → `DO NOT MAP`; `הוחלט לא למפות` → `DO NOT MAP`. Preserve the Hebrew source values and reject future unapproved nonblank values. |
| Owner | Hebrew-speaking mapping/data owner and data governance owner |
| Required approver | Hebrew-speaking mapping/data owner validates meaning; data governance owner approves canonical values. |
| Approval status | `PENDING` |
| Impact on DDL readiness | Mandatory. The alias configuration and canonical enum contract must be settled before DDL/import implementation. |
| Notes | Current counts are 22, 1, 13, and 10 respectively, for 46 records. |

### BA-07 — Baseline Register filename discrepancy

| Field | Value |
|---|---|
| ID | `BA-07` / reconciliation reference `BR-06` |
| Source workbook row / location | `BASELINE_REGISTER.md`, BL-001 `File` field; repository artifact `01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx` |
| Issue / decision required | Acknowledge the repository filename as canonical metadata and authorize the later documentation correction. |
| Current classification | `TECHNICAL_FIX` |
| Proposed decision | Correct the register filename to `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`. If the timestamped name is historically meaningful, preserve it separately as `Original filename`. Use the workbook digest as the authoritative content identity. |
| Owner | Documentation/repository maintainer |
| Required approver | Baseline custodian acknowledgment; no clinical approval required |
| Approval status | `PENDING` |
| Impact on DDL readiness | Does not block DDL if the actual path and matching digest are verified. It should be corrected before import execution to avoid operator error. |
| Notes | Registered filename is `CATO_IL_Core_MedicationRequest_Mapping_V_4(20260921-203119).xlsx`; repository filename omits the timestamp. This checklist does not edit the register. |

### BA-08 — General guidance scope representation

| Field | Value |
|---|---|
| ID | `BA-08` / reconciliation approval-boundary item |
| Source workbook row / location | General guidance rows in `הנחיות נוספות מעודכן` containing `x` or no concrete FHIR path; reconciliation references `BASELINE_IMPORT_SPEC_V1.md` section 9.8 |
| Issue / decision required | Approve the governed representation for general guidance that has scope but no concrete FHIR path. |
| Current classification | `GOVERNANCE_DECISION` |
| Proposed decision | No specific representation is proposed in the reconciliation. Approve a governed representation before DDL is frozen; do not invent a FHIR path. |
| Owner | Data governance owner and FHIR mapping owner |
| Required approver | Data governance owner and FHIR mapping owner |
| Approval status | `PENDING` |
| Impact on DDL readiness | Mandatory because the chosen representation affects how guidance scope is modeled. |
| Notes | The reconciliation requires approval but intentionally does not select a representation. |

### BA-09 — Durable artifact, manifest, validation, and quarantine storage

| Field | Value |
|---|---|
| ID | `BA-09` / reconciliation approval-boundary item |
| Source workbook row / location | Baseline-wide; workbook artifact, manifest, validation results, and quarantined raw rows; reconciliation references `BASELINE_IMPORT_SPEC_V1.md` section 9.10 |
| Issue / decision required | Approve the durable storage location and retention/access policy. |
| Current classification | `GOVERNANCE_DECISION` |
| Proposed decision | No storage platform or retention period is proposed in the reconciliation. The approved solution must durably preserve the workbook artifact, manifest, validation results, full quarantine provenance, and raw quarantined rows. |
| Owner | Data governance owner and product/technical owner |
| Required approver | Data governance owner and product/technical owner |
| Approval status | `PENDING` |
| Impact on DDL readiness | Mandatory, especially for `READY_WITH_QUARANTINE`, because durable quarantine and provenance cannot be left undefined. |
| Notes | Access and retention rules must be approved with the storage location. |

### BA-10 — Accountable owners and release gate

| Field | Value |
|---|---|
| ID | `BA-10` / reconciliation reference `BR-07` |
| Source workbook row / location | Cross-cutting across all BL-001 source locations and approval items |
| Issue / decision required | Assign named accountable owners and formally define the approval/release gate. |
| Current classification | `GOVERNANCE_DECISION` |
| Proposed decision | Adopt the responsibility boundary in the reconciliation: humans approve clinical meaning, mapping intent, status translations, import policy, and governed representations; technical owners implement only the approved rules and controls. |
| Owner | Data governance owner and technical owner |
| Required approver | Data governance owner assigns accountable owners; technical owner confirms implementability. |
| Approval status | `PENDING` |
| Impact on DDL readiness | Mandatory. DDL must not be frozen until accountable approvers and the release gate are formally recorded. |
| Notes | Technical heuristics cannot substitute for missing mapping or governance decisions. |

## Approval summary

| Metric | Count |
|---|---:|
| Approval items | 10 |
| `PENDING` | 10 |
| `APPROVED` | 0 |
| `REJECTED` | 0 |
| `DEFERRED` | 0 |

## DDL Readiness Gate

Current state: **`NOT_READY_FOR_DDL`**.

### Gate to `READY_FOR_DDL`

`READY_FOR_DDL` means the source-level blockers have approved resolutions and DDL does not need to depend on unresolved quarantine outcomes. All of the following are mandatory:

- `BA-01` is `APPROVED` with a canonical Decision Status for row 90.
- `BA-02` is `APPROVED` with the duplicate resolved through a governed source revision or governed decision, so row 226 no longer requires unresolved quarantine treatment.
- `BA-03`, `BA-05`, `BA-06`, `BA-08`, `BA-09`, and `BA-10` are `APPROVED`.
- `BA-04` is `APPROVED` with the applicable import policy and transaction behavior explicitly recorded.
- No mandatory item above is `REJECTED`, `DEFERRED`, or `PENDING`.

`BA-07` does not block DDL readiness, but the filename metadata correction must be acknowledged and completed before import execution.

### Gate to `READY_WITH_QUARANTINE`

`READY_WITH_QUARANTINE` means DDL may proceed with the two known invalid rows excluded from authoritative mapping results but retained durably and visibly in the governed import record. All of the following are mandatory:

- `BA-01` is `APPROVED` for quarantine of row 90 pending a governed canonical status.
- `BA-02` is `APPROVED` for retaining row 198 and quarantining row 226 as the later duplicate.
- `BA-03` is `APPROVED` for the documented warning/exception treatment of all 14 blank cardinalities.
- `BA-04` is `APPROVED` specifically for accepted-with-quarantine, with 291 accepted records and rows 90 and 226 quarantined.
- `BA-05`, `BA-06`, `BA-08`, `BA-09`, and `BA-10` are `APPROVED`.
- The approved design requires durable raw data and provenance for quarantined rows, complete validation counts, visible incomplete/reconciled-with-quarantine baseline state, and transactional protection against a partial authoritative snapshot.
- No mandatory item above is `REJECTED`, `DEFERRED`, or `PENDING`.

`BA-07` remains non-blocking for DDL but must be completed before import execution.

Until one complete gate is satisfied, the status remains **`NOT_READY_FOR_DDL`** and no DDL implementation is authorized.

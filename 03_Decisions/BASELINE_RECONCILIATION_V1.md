# Baseline Reconciliation v1

## Scope and evidence

This reconciliation covers the pre-DDL blockers for baseline `BL-001`. It is documentation only. It does not change the source workbook, Lovable, Supabase, or application code.

Evidence reviewed:

- `03_Decisions/BASELINE_REGISTER.md`
- `03_Decisions/OPEN_ISSUES.md`
- `04_Exports/LOVABLE_AUDIT_V1.md`
- `04_Exports/BASELINE_IMPORT_SPEC_V1.md`
- `01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`

The repository workbook SHA-256 is `4c072744861a04177609887348cb8d881ba2c7201145570eb65a9a33b2b062af`, matching the digest recorded in `BASELINE_IMPORT_SPEC_V1.md`. The workbook was inspected read-only.

## Reconciliation decisions and recommendations

| ID | Classification | Issue | Exact location | Current value | Recommended action | Implementation blocked? | Owner / approval needed |
|---|---|---|---|---|---|---|---|
| BR-01 | `DATA_QUALITY` | S2T row 90 has no Decision Status. | Workbook sheet `S2T MedicationRequestCato`, row 90; target `I90` = `requester`; status `Q90` | `Q90` is blank. `J90` is `1..1` after whitespace normalization. | The data owner must assign one allowed status: `FINAL`, `WIP`, `OPEN`, `DO NOT MAP`, or `N/A`, with any rationale recorded through the governed process. Do not infer a value from cardinality, profile, or neighboring rows. Until corrected in a future approved workbook or resolved by an approved governance record, quarantine row 90. | **Yes for atomic import.** Under an approved accepted-with-quarantine policy, this row is blocked but the remaining valid rows are not. | CATO/FHIR mapping data owner; team approval only if the chosen status changes an existing mapping policy. |
| BR-02 | `DATA_QUALITY` | S2T row 226 duplicates row 198. | `S2T MedicationRequestCato!A198:Q198` and `A226:Q226` | The two source rows are identical. Both target `dosageInstruction.doseAndRate.rateRatio.denominator.comparator`, cardinality `0..1`, Decision Status `DO NOT MAP`. | Treat row 198 as the first occurrence and row 226 as the later duplicate. Do not import both and do not generate a sequence suffix. Quarantine row 226 unless the data owner confirms that it represents a distinct logical record and supplies the distinguishing semantics in a future governed source revision. | **Yes for atomic import.** Under an approved accepted-with-quarantine policy, only row 226 is blocked. | CATO/FHIR mapping data owner confirms whether the duplicate is accidental. Import behavior after that confirmation is technical. |
| BR-03 | `DATA_QUALITY` | Fourteen S2T rows have blank cardinality. | `S2T MedicationRequestCato!J76,J100:J103,J106:J111,J115,J120:J121` | `J76` is blank with target `extension [MedicationDoseForm]` and status `FINAL`. The other 13 blank cells are on `DO NOT MAP` rows: 100–103, 106–111, 115, 120, and 121. | Require owner confirmation that blank cardinality is intentional. If confirmed, retain the blank raw value and emit a warning: row 76 as an approved structural/extension parent and the other 13 under the explicit `DO NOT MAP` exception. If any blank is unintentional, correct it only in a future approved workbook revision; do not patch BL-001 during import. | **Yes pending confirmation.** Once the exception is approved, these become warnings and do not block either import policy. | FHIR mapping owner, with IL-Core/profile owner review for row 76. |
| BR-04 | `GOVERNANCE_DECISION` | Baseline commit policy is undecided: fully atomic or accepted-with-quarantine. | `BASELINE_IMPORT_SPEC_V1.md`, sections 6, 7, and 9.2 | The spec describes both policies and recommends partial import, but no approved choice is recorded. Current preflight is 293 candidates, 291 acceptable records, and 2 error rows (90 and 226). | Adopt **accepted-with-quarantine** for this Human Working Draft baseline. Commit the baseline only when the import result durably records all candidate counts, errors, warnings, full provenance, and the two quarantined raw rows. The baseline must be visibly marked incomplete/reconciled-with-quarantine and must never present 291 accepted rows as a clean 293-row import. A failed transaction must not leave a partial authoritative snapshot. | **Yes.** The choice affects transaction boundaries, baseline state, validation-result storage, and quarantine representation in the DDL. | Data governance owner and product/technical owner must approve the policy. |
| BR-05A | `TEAM_APPROVAL_REQUIRED` | `Cato Status Mapping` has no native Decision Status column; the proposed canonical statuses are derived from workbook evidence. | `Cato Status Mapping!A7:H13`, `A15:H15`, and `A17:H17`; especially evidence column `G` | Rows 7–13 and 15 have `G = ממופה`. Row 17 (`ON HOLD (אם קיים)` → `on-hold`) has `G = לא קיים` and notes requiring a Production check. | Approve an explicit sheet-specific rule: rows 7–13 and 15 → `FINAL`; row 17 → `OPEN`. Preserve column G as `mapping_evidence_status_raw`; it must not be treated as implementation status. Do not commit this sheet until the rule is approved. | **Yes.** The canonical status and allowed aliases affect constraints and staged validation. | CATO product/data owner confirms Production semantics; FHIR mapping governance approves the canonical translation. |
| BR-05B | `TEAM_APPROVAL_REQUIRED` | Hebrew guidance statuses require an approved canonical translation. | `הנחיות נוספות מעודכן!A3:A7` and `A9:A49` | 46 records: `אושר` ×22, `דיון קליני` ×1, `לא ניתן למפות` ×13, `הוחלט לא למפות` ×10. | Approve the exact translation: `אושר` → `FINAL`; `דיון קליני` → `OPEN`; `לא ניתן למפות` → `DO NOT MAP`; `הוחלט לא למפות` → `DO NOT MAP`. Preserve the Hebrew source value. Reject any future unapproved nonblank value rather than inferring a status. | **Yes.** The alias configuration and canonical enum contract must be settled before DDL/import implementation. | Hebrew-speaking mapping/data owner validates meaning; data governance owner approves canonical values. |
| BR-06 | `TECHNICAL_FIX` | The Baseline Register filename does not match the repository artifact. | `BASELINE_REGISTER.md`, Baseline v1 `File` field; repository path `01_Baseline/` | Register: `CATO_IL_Core_MedicationRequest_Mapping_V_4(20260921-203119).xlsx`. Actual file: `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`. The actual file digest matches the import spec. | Correct the register's `File` field to `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`. Preserve the digest as the authoritative content identity and, if the timestamped name is historically meaningful, record it separately as `Original filename` rather than as the repository filename. This reconciliation does not edit the register. | **No**, provided import verifies the digest and actual path. The register should be corrected before execution to avoid operator error. | Documentation/repository maintainer; no clinical approval needed. Baseline custodian should acknowledge the metadata correction. |
| BR-07 | `GOVERNANCE_DECISION` | Responsibility boundary between technical resolution and human approval is not yet formally recorded. | Cross-cutting: `BASELINE_IMPORT_SPEC_V1.md` sections 3–9 and the six issues above | The spec identifies required confirmations but does not assign final approval roles or a release gate. | Use the approval boundary below. Technical controls may be implemented only after their policy inputs are approved. No technical heuristic may substitute for a missing mapping decision. | **Yes**, because the release gate and accountable approvers must be known before DDL is frozen. | Data governance owner assigns named accountable owners; technical owner confirms implementability. |

## Approval boundary

### Requires human or team approval

- The canonical Decision Status for S2T row 90.
- Whether row 226 is accidental duplication or a distinct concept with missing distinguishing data.
- Whether all 14 blank cardinalities are intentional, including the structural-parent treatment of row 76.
- Accepted-with-quarantine versus atomic import.
- The `Cato Status Mapping` derived-status rule, especially `ON HOLD (אם קיים)` → `OPEN`.
- The four Hebrew status aliases.
- The governed representation of general guidance rows that contain `x` or no concrete FHIR path, already identified in `BASELINE_IMPORT_SPEC_V1.md` section 9.8.
- The durable location and retention/access policy for the workbook artifact, manifest, validation results, and quarantined raw rows, already identified in section 9.10.

### Can be resolved technically after approval

- Exact-cell extraction, Unicode/whitespace normalization, cardinality parsing, source-row hashing, logical-key generation, and duplicate detection.
- Quarantining rows 90 and 226 under the approved policy while preserving their full raw source and provenance.
- Enforcing approved aliases as configuration and rejecting unknown or blank statuses.
- Recording warning/error/candidate/accepted/quarantined counts and making re-import idempotent by baseline ID plus workbook digest.
- Correcting the repository filename metadata in `BASELINE_REGISTER.md`.
- Verifying the workbook digest and exact authoritative sheet names before parsing.

Technical implementation must not decide clinical meaning, mapping intent, or governance status.

## OPEN_ISSUES.md disposition

`OPEN_ISSUES.md` is not changed by this reconciliation. The listed findings are baseline-import reconciliation and governance gates already identified in `BASELINE_IMPORT_SPEC_V1.md`; they are now tracked in this dedicated reconciliation record. The existing open-issue register remains focused on unresolved mapping content such as `route.text`, `doseAndRate`, and terminology decisions. If the project later adopts a single consolidated issue register with IDs, BR-01 through BR-07 should be migrated into it without duplication.

## Recommendation

### `NOT_READY_FOR_DDL`

The workbook identity and technical validation approach are sufficiently understood, but DDL would prematurely encode unresolved policy. Before DDL is frozen, the team must approve BR-04, BR-05A, BR-05B, and BR-07, and the relevant data owners must resolve or explicitly accept the warning/quarantine treatment in BR-01 through BR-03. The recommended target policy is accepted-with-quarantine, with 291 accepted records and two quarantined S2T rows, provided the quarantine is durable, auditable, and visible at the baseline level.

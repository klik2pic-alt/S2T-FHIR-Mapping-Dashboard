# Baseline Reconciliation v2

## Scope and authority

This reconciliation supersedes the V1 preflight findings for the current reconciliation run. It does not modify or approve the V1 records.

The user identified `CATO_IL_Core_MedicationRequest_Mapping_V_4(20260923-160445).xlsx` as the latest candidate source and stated that the attached workbook is authoritative. No file with that timestamped name exists in the project repository. The authoritative attachment was inspected read-only at:

`C:\Users\schna\OneDrive\שולחן העבודה\CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`

The different physical filename is recorded as a provenance discrepancy; no repository path is invented. The repository still contains the older V1 source at `01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`.

## Provenance

| Property | V2 candidate | V1 comparison source |
|---|---|---|
| User-designated source name | `CATO_IL_Core_MedicationRequest_Mapping_V_4(20260923-160445).xlsx` | `CATO_IL_Core_MedicationRequest_Mapping_V_4(20260921-203119).xlsx` in the Baseline Register |
| Inspected physical filename | `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx` | `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx` |
| Inspected location | Attached source at `C:\Users\schna\OneDrive\שולחן העבודה\CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx` | Repository: `01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx` |
| Repository file for timestamped V2 upload | Not present | Not applicable |
| SHA-256 | `f9ecf5b92caddcff51bef6025ab750f1acf179adca80f7932c2bfa4e2e9798a6` | `4c072744861a04177609887348cb8d881ba2c7201145570eb65a9a33b2b062af` |
| File size | 434,783 bytes | 431,786 bytes |
| Authority for this run | Authoritative latest attachment | Historical V1 comparison only |

The digest changed. Under the existing immutable-snapshot rule, this candidate cannot update the V1 baseline rows in place. A new baseline-version identity must be approved; this document does not invent that identifier.

## Authoritative sheets and candidate counts

| Source sheet | Current rows | Candidate records | Errors under the current V1 validation/key contract | Accepted under proposed partial import |
|---|---|---:|---:|---:|
| `S2T MedicationRequestCato` | Header row 1; data rows 2–240 | 239 | 1: later exact/logical duplicate at row 227 | 238 |
| `Cato Status Mapping` | Header row 5; mapping rows 7–13, 15, 17 | 9 | 0, subject to approval of the derived-status rule | 9 |
| `הנחיות נוספות מעודכן` | Header row 2; decision rows 3–7 and 9–49 | 46 | 5: rows 3–7 collide under the current guidance logical-key tuple | 41 |
| **Total** |  | **294** | **6** | **288** |

The accepted count is a preflight eligibility count under the proposed accepted-with-quarantine policy. It is not an approval to commit. All five records in the guidance collision group are counted as errors because the current contract provides no authoritative way to select one or append a sequence suffix.

## Fresh preflight findings

### S2T MedicationRequestCato

- Candidates: 239 rows, current rows 2–240.
- Decision Status values: `FINAL` 88, `DO NOT MAP` 149, `WIP` 2, blank 0, `OPEN` 0, `N/A` 0.
- Blank Decision Status cells: none.
- Missing target paths: none.
- Invalid nonblank cardinalities: none.
- Blank cardinalities: five, all with `DO NOT MAP`:
  - row 77: `extension [MedicationDoseForm]`
  - row 101: `dosageInstruction.timing.repeat.bounds[X]`
  - row 102: `dosageInstruction.timing.repeat.boundsDuration***`
  - row 103: `dosageInstruction.timing.repeat.boundsRange***`
  - row 104: `dosageInstruction.timing.repeat.boundsPeriod***`
- Exact and logical duplicate: rows 199 and 227, both `dosageInstruction.doseAndRate.rateRatio.denominator.comparator`, cardinality `0..1`, Decision Status `DO NOT MAP`. Row 227 is the later occurrence.
- The former V1 `requester` problem is now at row 91 and has Decision Status `FINAL`; it is no longer a blank-status error.

### Cato Status Mapping

- Candidate rows remain 7–13, 15, and 17: nine records.
- Rows 7–13 and 15 have evidence value `ממופה`; row 17 has `לא קיים`.
- No FHIR status target is blank and no duplicate status logical key was found.
- The sheet is unchanged from the V1 comparison source.
- The proposed translation remains rows 7–13 and 15 → `FINAL`; row 17 (`ON HOLD (אם קיים)`) → `OPEN`. It remains unapproved.

### הנחיות נוספות מעודכן

- Candidate rows remain 3–7 and 9–49: 46 records.
- Source statuses are `אושר` 21, `דיון קליני` 1, `לא ניתן למפות` 13, and `הוחלט לא למפות` 11.
- The proposed aliases remain `אושר` → `FINAL`, `דיון קליני` → `OPEN`, and both non-mapping values → `DO NOT MAP`. They remain unapproved.
- Rows 3–7 all use `B = x` and `C = x`. Their guidance text in column D is different, but the existing logical key uses target/scope plus decision topic, so all five generate the same key. This is a newly identified validation blocker under the current contract.
- Cell `E38` is an Excel error-typed cell with value `#VALUE!` in an authoritative record. It was also present in the V1 source, but V1 did not assign a validation disposition. It is recorded as a source anomaly and is not included in the six quarantined/error rows pending an approved rule.
- General-scope representation for rows 3–7 remains unresolved. A FHIR path must not be invented.

### Workbook inventory and sheet-specific anomalies

- The three authoritative sheet names are present exactly.
- The V1 workbook sheet `extension_MedicationForm` is absent from the V2 candidate. It was not classified as an authoritative sheet in the project governance records, so its removal does not change candidate counts. It must be recorded in the future manifest inventory.
- `S2T MedicationRequestCato` contains data only in A:Q for the governed import, although workbook formatting extends the reported used range beyond column Q. Columns beyond Q are not candidates.
- No formula/error cells were found in the governed S2T or status-mapping ranges. The only authoritative-range error cell found is `הנחיות נוספות מעודכן!E38`.

## Status totals under proposed translations

Before quarantine, the 294 candidates would translate to:

| Canonical status | Candidate count |
|---|---:|
| `FINAL` | 117 |
| `WIP` | 2 |
| `OPEN` | 2 |
| `DO NOT MAP` | 173 |
| `N/A` | 0 |

Under strict application of the current logical-key contract and the proposed partial-import policy, quarantine removes S2T row 227 plus guidance rows 3–7. The 288 accepted records would then contain `FINAL` 113, `WIP` 2, `OPEN` 1, `DO NOT MAP` 172, and `N/A` 0. These totals depend on approval of both status-translation rules.

## Delta from V1

### Material source changes

- Total candidates increased from 293 to 294 because S2T candidates increased from 238 to 239.
- The normalized S2T comparison found 55 unchanged row instances, 183 removed-or-changed V1 row instances, and 184 added-or-changed V2 row instances.
- `Cato Status Mapping` is unchanged.
- In `הנחיות נוספות מעודכן`, 43 nonempty rows are unchanged and seven are removed-or-changed/seven added-or-changed.
- Guidance source-status counts changed from `אושר` 22 / `הוחלט לא למפות` 10 to `אושר` 21 / `הוחלט לא למפות` 11.
- The V2 digest differs from V1 and requires a new immutable baseline-version identity.

### Old blockers that disappeared

- V1 BA-01 disappeared as a data error: semantic target `requester` moved from row 90 to row 91 and now has Decision Status `FINAL`.
- Nine of the fourteen V1 blank-cardinality findings now contain `0..1`: semantic targets `countMax`, `boundsDuration`, its `system`, `unit`, `value`, and `code` children, `periodMax`, `offset`, and `timing.code` at current rows 107–112, 116, 121, and 122.

### Blockers that changed location or scope

- The duplicate comparator rows moved from V1 rows 198/226 to current rows 199/227; the semantic duplicate remains.
- Blank cardinalities moved from fourteen V1 rows to five current rows: 77 and 101–104. The MedicationDoseForm parent moved from row 76 to 77 and changed from `FINAL` to `DO NOT MAP`.
- The import-policy decision now covers 294 candidates and, under the strict current contract, six error rows rather than V1's 293 candidates and two error rows.
- The guidance alias counts changed, although the four alias values remain the same.
- The filename issue now involves three identities: the user-designated timestamped name, the non-timestamped attached physical filename, and the older repository artifact/digest.

### Newly identified blockers

- Guidance rows 3–7 collide under the current `GOVERNANCE_GUIDANCE` logical-key definition.
- A new immutable baseline-version identity is required because the digest changed; no ID is proposed here.
- The latest authoritative attachment is not present in the repository under the user-designated timestamped name, and current register/import metadata still describes the V1 artifact.
- The disposition of the error-typed value `הנחיות נוספות מעודכן!E38 = #VALUE!` is undefined.

## V1 approval-item disposition

| V1 item | V2 classification | Current evidence and disposition |
|---|---|---|
| `BA-01` | `RESOLVED_BY_SOURCE_CHANGE` | `requester` is now row 91 with Decision Status `FINAL`; there is no blank S2T Decision Status. Do not carry the V1 approval item forward. |
| `BA-02` | `CHANGED` | The duplicate remains semantically identical but moved to rows 199/227. A fresh V2 approval is required. |
| `BA-03` | `REQUIRES_NEW_REVIEW` | Stop the V1 14-row process. Only five blank cardinalities remain, all `DO NOT MAP`, at rows 77 and 101–104. |
| `BA-04` | `CHANGED` | The commit-policy choice remains, but counts and quarantine scope changed to 294 candidates and six errors under the strict current contract. |
| `BA-05` | `STILL_APPLICABLE` | The status-mapping sheet and proposed derivation are unchanged and remain unapproved. |
| `BA-06` | `CHANGED` | The aliases remain applicable, but source counts changed to 21/1/13/11. Fresh approval is required. |
| `BA-07` | `REQUIRES_NEW_REVIEW` | The latest source is an attachment with a non-timestamped physical name, the requested timestamped file is not in the repository, and the register describes the older artifact. |
| `BA-08` | `CHANGED` | General-scope representation remains unresolved and now also causes a five-row logical-key collision under the current key definition. |
| `BA-09` | `STILL_APPLICABLE` | Durable artifact, manifest, validation, and quarantine storage remains unresolved. |
| `BA-10` | `STILL_APPLICABLE` | Accountable owners and the release gate remain unresolved. |

No approval is carried forward from V1.

## V2 unresolved governance and data-quality gates

| V2 gate | Classification | Decision required | Exact current location | Proposed treatment | Owner / required approval | DDL impact |
|---|---|---|---|---|---|---|
| `V2-G01` | `DATA_QUALITY` | Confirm duplicate treatment. | `S2T MedicationRequestCato!A199:Q199` and `A227:Q227` | Retain row 199 and quarantine later row 227 unless the data owner identifies distinct semantics. | CATO/FHIR mapping data owner | Blocking |
| `V2-G02` | `DATA_QUALITY` | Confirm the five blank cardinalities are intentional. | `S2T MedicationRequestCato!J77,J101:J104` | Retain raw blanks and warn under the explicit `DO NOT MAP` exception if approved. | FHIR mapping owner; IL-Core/profile review as applicable | Blocking until confirmed |
| `V2-G03` | `GOVERNANCE_DECISION` | Choose atomic or accepted-with-quarantine for the current 294-candidate preflight. | Baseline-wide | Recommend accepted-with-quarantine only with durable, visible quarantine and transactional protection. | Data governance and product/technical owners | Blocking |
| `V2-G04` | `TEAM_APPROVAL_REQUIRED` | Approve Cato Status Mapping derivation. | `Cato Status Mapping!A7:H13,A15:H15,A17:H17` | Rows 7–13 and 15 → `FINAL`; row 17 → `OPEN`. | CATO product/data owner and FHIR mapping governance | Blocking |
| `V2-G05` | `TEAM_APPROVAL_REQUIRED` | Approve Hebrew aliases with current counts. | `הנחיות נוספות מעודכן!A3:A7,A9:A49` | Apply the four existing proposed translations and preserve raw Hebrew values. | Hebrew-speaking mapping/data owner and data governance | Blocking |
| `V2-G06` | `GOVERNANCE_DECISION` | Assign a new immutable baseline-version identity. | Candidate digest and baseline metadata | Create a new baseline-version identity; do not update V1/`BL-001` rows in place. No identifier is proposed. | Baseline custodian and data governance owner | Blocking |
| `V2-G07` | `TECHNICAL_FIX` | Reconcile user-designated, attached, repository, and registered source identities. | Candidate attachment, `01_Baseline/`, `BASELINE_REGISTER.md`, and import manifest/spec metadata | Register the approved physical artifact and digest without inventing a repository path; preserve original/upload filename separately if needed. | Repository maintainer; baseline custodian acknowledgment | Non-blocking for DDL, required before import execution |
| `V2-G08` | `GOVERNANCE_DECISION` | Define general-guidance scope and a collision-free logical key. | `הנחיות נוספות מעודכן!A3:F7` | Do not invent a FHIR path or append a sequence suffix. Approve a governed scope/topic representation and revise the key contract accordingly. | Data governance owner and FHIR mapping owner | Blocking |
| `V2-G09` | `GOVERNANCE_DECISION` | Approve durable storage, retention, and access. | Baseline-wide | Preserve artifact, inventory manifest, validation results, raw rows, hashes, and quarantine provenance durably. | Data governance and product/technical owners | Blocking |
| `V2-G10` | `GOVERNANCE_DECISION` | Assign named owners and define the release gate. | Cross-cutting | Keep clinical/governance decisions human-owned and technical implementation limited to approved rules. | Data governance owner and technical owner | Blocking |
| `V2-G11` | `DATA_QUALITY` | Decide how an Excel error-typed notes cell is validated and preserved. | `הנחיות נוספות מעודכן!E38 = #VALUE!` | Do not infer the intended note. Preserve the raw error and require source-owner verification or an approved validation disposition. | Guidance data owner and data governance owner | Blocking until disposition is defined; not included in the current six-row error count |

## OPEN_ISSUES.md disposition

`OPEN_ISSUES.md` is not modified. Its mapping-content issues remain separate. The V2 findings are baseline-import reconciliation gates and are tracked here and in the V2 checklist.

## Recommendation

### `NOT_READY_FOR_DDL`

The current evidence does not support `READY_FOR_DDL` or `READY_WITH_QUARANTINE`. Eleven V2 gates require fresh approval, the current logical-key contract produces six error rows, the new baseline identity is undecided, and the attached artifact is not yet reconciled with repository/register/manifest metadata. The stopped V1 BA-03 process must not be resumed; only V2 gate `V2-G02` applies to the five current blank-cardinality rows.

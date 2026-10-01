# Baseline Import Specification v1

## 1. Purpose and scope

This specification defines the Phase 1 import of the current Excel Human Working Draft Baseline into the governed persistence model.

- Baseline ID: `BL-001`
- Source system: `CATO`
- FHIR resource: `MedicationRequest`
- Baseline type: `HUMAN_WORKING_DRAFT`
- Gold standard: `false`
- Governance status: `ACTIVE`
- Repository workbook: `01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`
- Inspected workbook SHA-256: `4c072744861a04177609887348cb8d881ba2c7201145570eb65a9a33b2b062af`

The import creates an immutable snapshot. It does not update an existing imported row in place. Re-importing changed content requires a new `baseline_version`; corrections to governance state are made through `decision` and `issue`, not by rewriting the imported row. `element_change` is not populated until a second baseline exists.

This document is an import contract, not an importer implementation. Exact physical column names and enum constraints must be reconciled with the approved database DDL before implementation.

## 2. Sheet classification

### 2.1 Authoritative and imported

| Sheet | Header/data range | Import kind | Candidate rows |
|---|---:|---|---:|
| `S2T MedicationRequestCato` | header 1; rows 2–239 | `ELEMENT_MAPPING` | 238 |
| `Cato Status Mapping` | header 5; data rows 7–13, 15, 17 | `STATUS_MAPPING_RULE` | 9 |
| `הנחיות נוספות מעודכן` | header 2; decision rows 3–7 and 9–49 | `GOVERNANCE_GUIDANCE` | 46 |

Rows 8, 50 and 76 in `הנחיות נוספות מעודכן` are section labels, not records. Blank/format-only rows are ignored. Every accepted data row creates one `mapping_element` record and retains its source location.

### 2.2 Non-authoritative context only

The following content is retained in the baseline import manifest as contextual source metadata, but creates no `mapping_element`, `decision`, or `issue` records in v1:

- `Profile`: classification `WIP_PROFILE`; never used to fill, correct, or override an authoritative S2T value.
- `CATO Route Mapping`: classification `WIP_ROUTE_MAPPING`; no terminology mapping may be inferred from it.
- JSON examples, currently the sheet `דוגמאות ב-JSON`: classification `EXAMPLE_ONLY`; examples are not conformance rules or mapping evidence by themselves.

The manifest records the exact sheet name, classification, workbook digest, and whether the sheet was present. If `baseline_version` has no manifest/metadata field, this requires either an approved provenance child entity or external immutable artifact metadata before implementation. It must not be forced into `mapping_element`.

Other workbook sheets are out of scope for v1 and are recorded only in the inventory portion of the manifest.

## 3. Common import contract

### 3.1 Provenance fields

Every `mapping_element` must contain, directly or through the approved provenance structure:

- `baseline_version_id` → the `BL-001` record
- `mapping_kind` → one of the three kinds above
- `source_workbook_name`
- `source_workbook_sha256`
- `source_sheet_name`
- `source_row_number` → one-based Excel row number
- `source_cell_range` → for example `A12:Q12`
- `raw_source_row` → typed JSON defined below
- `source_row_hash`
- `logical_element_key`

Missing workbook, sheet, row number, cell range, or workbook digest is a provenance error. Provenance fields are immutable after commit.

### 3.2 `raw_source_row`

`raw_source_row` is a lossless JSON object containing:

```json
{
  "schema": "baseline-import-v1",
  "sheet": "S2T MedicationRequestCato",
  "row": 12,
  "range": "A12:Q12",
  "cells": {
    "A": {"header": "Source System", "type": "string", "value": "CATO"}
  }
}
```

All columns in the defined source range are preserved, including blank cells, original strings, non-breaking spaces, line breaks, numeric/boolean/date types, and formulas when present. Normalized values used for mapped fields are additional derived values and never replace the raw values. Workbook styles, comments, hidden state, and merged-cell formatting are not row data in v1.

### 3.3 Canonicalization and hashes

Use SHA-256 over UTF-8 encoded RFC 8785 JSON Canonicalization Scheme (JCS) output.

`source_row_hash`:

```text
sha256(jcs({
  schema: "baseline-import-v1",
  sheet: exact_sheet_name,
  cells: ordered_raw_cells_for_the_defined_source_range
}))
```

The row number is intentionally excluded so identical rows on the same sheet produce the same hash. The sheet name is included so identical text in different sheet roles is not treated as the same source row.

For logical keys only, `norm(value)` means: Unicode NFKC, replace non-breaking space with an ordinary space, trim, collapse internal whitespace, normalize CRLF/CR to LF, and case-fold invariant identifiers/statuses. Do not change punctuation, path indices, Hebrew text, or FHIR choice markers.

`logical_element_key` is stored as `me:v1:` plus the lowercase SHA-256 of the relevant canonical tuple:

- `ELEMENT_MAPPING`: `ELEMENT_MAPPING | CATO | MedicationRequest | norm(target_fhir_path) | norm(source_system) | norm(interface_type) | norm(interface_name) | norm(source_expression) | norm(fixed_value)`
- `STATUS_MAPPING_RULE`: `STATUS_MAPPING_RULE | CATO | MedicationRequest.status | norm(cato_status) | norm(fhir_status)`
- `GOVERNANCE_GUIDANCE`: `GOVERNANCE_GUIDANCE | CATO | MedicationRequest | norm(target_fhir_path_or_scope) | norm(decision_topic)`

The source row number is excluded so a row move does not create a new logical element. A collision inside one baseline is a validation error; the importer must not append a sequence number to make it appear unique.

## 4. Authoritative sheet mappings

Field names below describe the logical `mapping_element` contract. Where the governed DDL uses different names, implementation must document the one-to-one translation without changing meaning.

### 4.1 `S2T MedicationRequestCato`

Import `A:Q` for each non-empty row from 2 through 239.

| Excel column | Header | `mapping_element` field |
|---|---|---|
| A | Source System | `source_system` |
| B | Interface Type | `interface_type` |
| C | Interface Name | `interface_name` |
| D | Field / Expression | `source_expression` |
| E | Profile where element is defined | `profile_context` |
| F | Fixed Value | `fixed_value` |
| G | Transformation Rules | `transformation_rule` |
| H | Source Business Definition | `source_business_definition` |
| I | Target Element name (FHIR) | `target_fhir_path` |
| J | Cardinality | `cardinality_raw`, parsed to `cardinality_min` and `cardinality_max` when valid |
| K | Bindings to ValueSet | `valueset_binding` |
| L | Mandated code system | `mandated_code_system` |
| M | Irrelevant under s2t | `irrelevant_under_s2t_raw` |
| N | Example | `example_value` |
| O | Exceptions handling | `exception_handling` |
| P | Notes | `notes` |
| Q | Decision Status | `decision_status` |

All A:Q values are also present in `raw_source_row`. Empty and whitespace-only mapped values become `null`; the exact cell value remains raw. Literal `x` is preserved as source content and is not interpreted beyond any separately approved rule.

`Decision Status` is not copied to `element_status`. No `implementation_status` is set or inferred. In v1, import does not create a formal `decision` record solely because a workbook row has a status; it preserves the baseline's decision-state snapshot on the mapping record. Later governed decisions remain separate records.

### 4.2 `Cato Status Mapping`

Import columns `A:H` only for numbered mapping rows 7–13 and 15, plus the explicitly provisional row 17. Title, explanatory blocks, and group headings are retained only in sheet-level manifest notes.

| Excel column | Header | `mapping_element` field |
|---|---|---|
| A | # | `source_sequence` |
| B | CATO Status | `source_expression` and `source_status_value` |
| C | משמעות קלינית | `source_business_definition` |
| D | FHIR status | `target_value`; `target_fhir_path` is the constant `MedicationRequest.status` |
| E | MedAdministration? | `related_resource_note` |
| F | הערות / כללי מיפוי | `transformation_rule` |
| G | סטטוס מיפוי | `mapping_evidence_status_raw` |
| H | unlabeled workbook column | `notes` |

All A:H values are preserved in `raw_source_row`. Column G is workbook evidence about whether the status mapping exists; it is not the governed `decision_status`, `element_status`, or implementation status.

Decision status derivation for this sheet is limited to an explicit v1 source rule: rows 7–15 are `FINAL`; row 17 (`ON HOLD (אם קיים)`, marked for Production checking and `לא קיים`) is `OPEN`. This rule must be confirmed by the data owner before implementation; until confirmed, the derived value is stored only in the staged record and the import is not committed.

### 4.3 `הנחיות נוספות מעודכן`

Import `A:F` for decision rows 3–7 and 9–49.

| Excel column | Header | `mapping_element` field |
|---|---|---|
| A | סטטוס/חומרה | source for `decision_status` through the explicit translation below; also `guidance_status_raw` |
| B | נושא ההחלטה | `decision_topic` |
| C | אלמנט FHIR | `target_fhir_path_or_scope` |
| D | הנחות יסוד | `transformation_rule` / authoritative guidance text |
| E | הערות | `notes` |
| F | הערות 17.09.2026 | `review_notes` |

All A:F values are preserved in `raw_source_row`. Values such as `x` are preserved; they are not treated as a valid FHIR path. A guidance record may have a scope rather than a concrete element path, so the missing-target-path rule is conditional as described below.

Proposed explicit status translation:

| Workbook value | Canonical `decision_status` |
|---|---|
| `אושר` | `FINAL` |
| `דיון קליני` | `OPEN` |
| `לא ניתן למפות` | `DO NOT MAP` |
| `הוחלט לא למפות` | `DO NOT MAP` |

This translation is an import configuration, not free-text inference. It must be confirmed before implementation. Any other nonblank value is unknown and blocks that row.

## 5. Decision Status handling

Allowed canonical values are exactly:

| Value | Import meaning |
|---|---|
| `FINAL` | Human working-draft decision is final within this baseline only. It does not make the baseline a Gold Standard and does not imply implementation. |
| `WIP` | Mapping is intentionally incomplete. Import it unchanged and make it visible for follow-up. |
| `OPEN` | A decision remains unresolved. Import it unchanged and link/create an `issue` only in a later approved workflow; v1 does not invent issue content. |
| `DO NOT MAP` | Explicit governance decision not to map. Preserve the target row and rationale; do not discard it as irrelevant. |
| `N/A` | The mapping question is not applicable. Preserve the row and rationale; do not treat it as blank or implemented. |

Comparison is performed after trim, NFKC, whitespace collapse, and uppercase conversion. Stored value is the canonical token; the original cell is retained raw. Blank is not `N/A`. Unknown or blank values are validation errors unless a sheet-specific, pre-approved translation rule applies.

`decision_status` must never populate or derive `element_status`. The importer leaves `element_status` at the governed model's neutral imported/default state only if that state is explicitly defined in the DDL; otherwise it leaves it null. The importer never sets or infers Implementation Status from cardinality, fixed values, completeness, workbook wording, application behavior, or Decision Status.

## 6. Validation rules

Validation runs before commit and produces row-level errors plus aggregate counts. A row with an error is quarantined, not partially inserted. Warnings do not alter source values. The baseline is committed only under the approved partial-import policy described in section 7; otherwise any error aborts the transaction.

| Rule | Applies to | Result |
|---|---|---|
| Missing target FHIR path | `ELEMENT_MAPPING`: column I must be nonblank. `STATUS_MAPPING_RULE`: constant path plus column D must be nonblank. `GOVERNANCE_GUIDANCE`: column C may be `x`/blank only for general-scope guidance; mark `target_scope=MedicationRequest` and emit a warning, without inventing a path. | Error for required cases; warning for general guidance. |
| Duplicate logical key | All staged records within `BL-001`. | Error for every conflicting group; no sequence suffix or last-write-wins. |
| Duplicate source row | Same `source_sheet_name` + `source_row_hash` in `BL-001`. | Error on the later occurrence and cross-reference the first row. |
| Invalid cardinality | `ELEMENT_MAPPING`. When present, must match `^(0|[1-9][0-9]*)\\.\\.(\\*|0|[1-9][0-9]*)$`; numeric max must be greater than or equal to min. Blank is allowed only for an explicit `DO NOT MAP` row or a structural parent row and produces a warning; otherwise error. | Error or warning as stated; always preserve `cardinality_raw`. |
| Unknown status value | Any field configured as Decision Status after approved alias translation. Blank is unknown, not `N/A`. | Error; do not infer. |
| Missing source provenance | Any imported row lacking baseline ID, workbook digest/name, exact sheet, one-based row, range, raw row, or hash. | Error. |

Additional required controls:

- Verify the workbook SHA-256 against the registered import artifact before parsing.
- Require the three authoritative sheet names exactly; a missing or renamed sheet blocks the batch.
- Record candidate, accepted, warning, error, and quarantined counts by sheet and Decision Status.
- Re-running the same baseline and workbook digest must be idempotent: return the existing import result, not duplicate records.
- A changed workbook digest cannot update `BL-001` rows in place.

## 7. Expected result for `BL-001`

### 7.1 Current workbook preflight

The inspected workbook produces 293 candidate records:

| Sheet | Candidates | Current known errors | Accepted under partial-import policy |
|---|---:|---:|---:|
| `S2T MedicationRequestCato` | 238 | 2 quarantined rows | 236 |
| `Cato Status Mapping` | 9 | 0 after owner confirmation of the sheet rule | 9 |
| `הנחיות נוספות מעודכן` | 46 | 0 after owner confirmation of Hebrew aliases | 46 |
| **Total** | **293** | **2** | **291** |

Known S2T findings:

- Row 90 (`requester`) has a blank Decision Status. It must be quarantined; the importer must not infer `FINAL`, `OPEN`, or another value.
- Rows 198 and 226 are exact duplicates for `dosageInstruction.doseAndRate.rateRatio.denominator.comparator`, cardinality `0..1`, status `DO NOT MAP`. Row 226 is the later duplicate and is quarantined; row 198 remains the accepted occurrence.
- Fourteen S2T rows have blank cardinality. Thirteen are `DO NOT MAP`; row 76 is `FINAL` and appears to be a structural/extension parent. These receive warnings under the conditional cardinality rule and require owner confirmation that blank cardinality is intentional.
- S2T source statuses before quarantine: `FINAL` 96, `WIP` 2, `OPEN` 1, `DO NOT MAP` 138, blank 1. The workbook contains no S2T `N/A` row; `N/A` remains an allowed value.

### 7.2 Persisted outcome

With the recommended explicit partial-import policy, the expected committed outcome is:

- one `baseline_version` record for `BL-001`, linked to the workbook digest and import specification version;
- 291 immutable `mapping_element` records, one for each accepted row;
- complete row provenance and `raw_source_row` on every mapping record;
- an import summary recording 293 candidates, 291 accepted, 2 quarantined, warning counts, error counts, and counts by sheet/kind/status;
- expected canonical Decision Status counts after the proposed sheet rules are approved: `FINAL` 126, `WIP` 2, `OPEN` 3, `DO NOT MAP` 160, `N/A` 0;
- validation details for both quarantined rows and the cardinality warnings;
- no `element_change` records;
- no inferred implementation status;
- no authoritative mapping records from `Profile`, `CATO Route Mapping`, or JSON examples.

If the governed baseline policy requires atomic all-or-nothing import, the current workbook cannot be committed: preflight must report the same findings and persist no baseline or mapping rows until the two errors have approved resolutions. The choice between partial import with quarantine and atomic import must be confirmed before implementation.

## 8. Proposed import flow

1. Register the source artifact and calculate its SHA-256 without modifying it.
2. Verify `BL-001`, workbook identity, required sheets, and the authority classifications.
3. Read the three authoritative sheets into a staging area and inventory non-authoritative sheets as context.
4. Build lossless `raw_source_row` objects and immutable provenance.
5. Normalize mapped fields, apply only approved status aliases, and parse cardinality without changing raw values.
6. Generate `source_row_hash` and `logical_element_key` using the v1 algorithms.
7. Run row and batch validation; produce errors, warnings, duplicate groups, and summary counts.
8. Require approval of the preflight result and the configured commit policy.
9. In one transaction, create the `baseline_version`, insert accepted immutable `mapping_element` rows, and store the import summary/manifest. Quarantined rows remain in the import report with their full raw data and provenance, not in authoritative mapping results.
10. Verify persisted counts and hashes, then mark the import result complete. Never update imported rows in place.

## 9. Unresolved assumptions and required confirmations

The following must be confirmed before importer implementation:

1. The exact governed DDL and enum names for the logical fields in this document, including where import manifest, validation results, `mapping_kind`, `decision_status`, and provenance live.
2. Whether v1 permits partial import with quarantine (291 records) or requires an atomic all-or-nothing import.
3. The resolution of S2T row 90's blank Decision Status. No default is proposed.
4. Whether row 226 is intentionally duplicated. The proposed behavior retains row 198 and quarantines row 226.
5. Whether blank cardinality is valid for the 14 identified S2T rows, especially FINAL row 76.
6. Approval of the `Cato Status Mapping` Decision Status rule, particularly treating `ON HOLD (אם קיים)` as `OPEN`.
7. Approval of the Hebrew-to-canonical Decision Status aliases for `הנחיות נוספות מעודכן`.
8. Whether general guidance rows with `x` rather than a concrete FHIR path may use `target_scope=MedicationRequest`, or require a different governed representation.
9. Which workbook filename is canonical: the repository contains `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`, while the Baseline Register names `CATO_IL_Core_MedicationRequest_Mapping_V_4(20260921-203119).xlsx`.
10. The durable storage location for the full workbook artifact and non-authoritative sheet manifest, including retention and access rules.

No Profile content may change these answers or override an authoritative S2T row. Profile remains `WIP_PROFILE` until a future governed decision promotes it.

# BL-001 Import Preflight

## Scope and disposition

This is a read-only preflight of the current repository workbook against the schema implemented by migrations `001` through `012`. It does not authorize or execute SQL, write to Supabase, alter the workbook, or alter an existing migration.

The proposed import uses the approved `ACCEPTED_WITH_QUARANTINE` policy. The current workbook produces one quarantined candidate and is otherwise importable. The release evidence must preserve that quarantine visibly and immutably.

## 1. Artifact fingerprint

| Property | Registered value | Observed value | Result |
|---|---|---|---|
| Baseline ID | `BL-001` | `BL-001` import target | Match |
| Filename | `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx` | `CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx` | Match |
| Byte size | `252859` | `252859` | Match |
| SHA-256 | `3c7e551109ab814712c3b7bbbbda4d41b457327452e4eee7746e698283fdc46` | `3c7e551109ab814712c3b7bbbbda4d41b457327452e4eee7746e698283fdc46` | Match |
| Last modified | `2026-09-25 00:08:29 Asia/Jerusalem` | `2026-09-25 00:08:29 +03:00` | Match |
| Last modified UTC | `2026-09-24 21:08:29 UTC` | `2026-09-24 21:08:29 UTC` | Match |

The artifact fingerprint matches the registered BL-001 metadata exactly.

## 2. Authoritative-sheet scan

| Sheet | Governed range | Candidates | Accepted | Quarantined | Warnings | Errors |
|---|---|---:|---:|---:|---:|---:|
| `S2T MedicationRequestCato` | `A2:Q239` | 238 | 237 | 1 | 4 | 1 |
| `Cato Status Mapping` | `A7:H13`, `A15:H15`, `A17:H17` | 9 | 9 | 0 | 0 | 0 |
| `הנחיות נוספות מעודכן` | `A3:F7`, `A9:F49` | 46 | 46 | 0 | 1 | 0 |
| **Total** |  | **293** | **292** | **1** | **5** | **1** |

Warning and error totals are validation-finding counts, consistent with migrations `007`, `009`, and the migration README. Each finding above concerns one candidate row.

## 3. Quarantine set

Exactly one candidate would be quarantined:

| Sheet and row | Range | Mapping kind | Target | Decision Status | Reason |
|---|---|---|---|---|---|
| `S2T MedicationRequestCato!77` | `A77:Q77` | `ELEMENT_MAPPING` | `extension [MedicationDoseForm]` | `DO NOT MAP` | Blank cardinality is outside the four explicitly approved blank-cardinality exceptions. It therefore fails `INVALID_CARDINALITY` v1. The raw blank must be preserved and no cardinality may be inferred. |

No duplicate source-row hash, duplicate logical key, missing target, or unknown Decision Status produced another quarantine candidate.

## 4. Approved cardinality exceptions

The four approved exceptions are present, remain `DO NOT MAP`, and are accepted with warnings. Approval follows semantic identity, not historical row number.

| Current row | Target | Cardinality | Treatment |
|---:|---|---|---|
| 101 | `dosageInstruction.timing.repeat.bounds[X]` | blank | `APPROVED_CARDINALITY_EXCEPTION` warning |
| 102 | `dosageInstruction.timing.repeat.boundsDuration***` | blank | `APPROVED_CARDINALITY_EXCEPTION` warning |
| 103 | `dosageInstruction.timing.repeat.boundsRange***` | blank | `APPROVED_CARDINALITY_EXCEPTION` warning |
| 104 | `dosageInstruction.timing.repeat.boundsPeriod***` | blank | `APPROVED_CARDINALITY_EXCEPTION` warning |

`S2T MedicationRequestCato!76` is not an exception: target `extension` has cardinality `0..1`. Row 77 is distinct from the approved four and is quarantined as stated above.

## 5. Other warning

`הנחיות נוספות מעודכן!E38` is an Excel error-typed optional cell containing `#VALUE!`. Under the approved `ACCEPT_WITH_RAW_ERROR_PRESERVED` disposition, row 38 remains accepted, the error token and Excel error type are preserved in `raw_source_row`, and one `RAW_OPTIONAL_CELL_ERROR` warning is recorded. No replacement note content is inferred.

## 6. Decision Status validation

The approved sheet rules were applied before validation:

- `Cato Status Mapping` rows 7–13 and 15 → `FINAL`; row 17 → `DO NOT MAP`.
- Guidance aliases: `אושר` → `FINAL`; `דיון קליני` → `OPEN`; `לא ניתן למפות` and `הוחלט לא למפות` → `DO NOT MAP`.
- S2T column Q is normalized only for surrounding whitespace and canonical comparison; the raw value remains unchanged.

All 293 candidates resolve to an allowed value: `FINAL`, `WIP`, `OPEN`, `DO NOT MAP`, or `N/A`. No candidate resolves to blank or an unknown value.

| Canonical status | Candidates | Accepted | Quarantined |
|---|---:|---:|---:|
| `FINAL` | 122 | 122 | 0 |
| `WIP` | 1 | 1 | 0 |
| `OPEN` | 1 | 1 | 0 |
| `DO NOT MAP` | 169 | 168 | 1 |
| `N/A` | 0 | 0 | 0 |

## 7. Deterministic logical keys

Logical-key generation can be performed deterministically for every candidate using normalization version `v1`, key algorithm version `v1`, UTF-8, and lowercase SHA-256 output in the schema-required form `me:v1:<64 lowercase hex characters>`.

- `ELEMENT_MAPPING`: mapping kind, `CATO`, `MedicationRequest`, normalized target path, source system, interface type, interface name, source expression, and fixed value.
- `STATUS_MAPPING_RULE`: mapping kind, `CATO`, constant target `MedicationRequest.status`, normalized CATO status, and normalized FHIR status.
- `GOVERNANCE_GUIDANCE`: mapping kind, `CATO`, `MedicationRequest`, governed guidance scope, and governed decision-topic code.

Guidance rows 3–7 use the approved governed scope/topic pairs:

| Row | Guidance scope | Decision topic code |
|---:|---|---|
| 3 | `GLOBAL_MAPPING_POLICY` | `NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING` |
| 4 | `MEDICATION_COMPOSITION` | `PRESCRIBED_DRUG_INGREDIENT_REPRESENTATION` |
| 5 | `DOSAGE_TIMING` | `PO_DURATION_CLINICAL_SIGNIFICANCE` |
| 6 | `PATIENT_IDENTITY` | `CATO_SSN_PATIENT_IDENTIFIER_SEMANTICS` |
| 7 | `TREATMENT_PLAN_ACCESS` | `PATIENT_IDENTIFIER_FOR_PLAN_RETRIEVAL` |

Raw workbook values remain evidence and are not replaced by these governed identities. The scan generated a valid key for all 293 candidates and found no collision.

## 8. Raw evidence and source-row hashes

`raw_source_row` and `source_row_hash` can be generated for every candidate.

- The raw envelope includes `schema`, exact sheet name, one-based row, exact range, and an A:Q, A:H, or A:F cell object as applicable.
- Every governed cell is represented with its header, typed value, and original content, including blanks, non-breaking spaces, line breaks, and the typed `#VALUE!` error at E38.
- `source_row_hash` is SHA-256 over UTF-8 RFC 8785/JCS canonical JSON containing schema, exact sheet name, and ordered raw cells. The row number is excluded by design.
- The scan produced a 32-byte hash for all 293 candidates and found no later duplicate within a source sheet.

The importer must use the same published JCS implementation and version identifiers used to calculate the persisted evidence. It must not serialize normalized mapped fields in place of raw cells.

## 9. Artifact sheet manifest

Register one `artifact_sheet_manifest` row per workbook sheet, in workbook order, using manifest schema `baseline-import-sheet-manifest` version `v1`.

| Order | Sheet | Classification | Authoritative | Header | Candidate range | Governed columns | Candidates | Observed used range |
|---:|---|---|---:|---:|---|---|---:|---|
| 1 | `Cato Status Mapping` | `AUTHORITATIVE` | yes | 5 | `A7:H13;A15:H15;A17:H17` | `A:H` | 9 | `A1:H17` |
| 2 | `S2T MedicationRequestCato` | `AUTHORITATIVE` | yes | 1 | `A2:Q239` | `A:Q` | 238 | `A1:IJ243` |
| 3 | `Profile` | `WIP_PROFILE` | no | — | — | — | 0 | `A1:Q59` |
| 4 | `CATO Route Mapping` | `WIP_ROUTE_MAPPING` | no | — | — | — | 0 | `A1:H15` |
| 5 | `ValueSet` | `OUT_OF_SCOPE` | no | — | — | — | 0 | `A1:E80` |
| 6 | `הנחיות נוספות מעודכן` | `AUTHORITATIVE` | yes | 2 | `A3:F7;A9:F49` | `A:F` | 46 | `A2:F76` |
| 7 | `דוגמאות ב-JSON` | `EXAMPLE_ONLY` | no | — | — | — | 0 | `A2:N2` |

The S2T used range extends to column `IJ` because of workbook formatting or other non-governed sheet content. Only A:Q participates in BL-001 candidate generation.

## 10. Exact proposed import sequence

The following sequence is proposed for one database transaction after an explicit operator approval to execute the import. It is a plan only; this preflight executes none of it.

1. **Principal and actor resolution.** Resolve the seeded service principal `postgres-role / s2t_fhir_importer`. Resolve the initiating human principal when available. Resolve the migrator-created validation ruleset `BASELINE_IMPORT/v1`, its eight rules, release gate `BASELINE_IMPORT/v1`, and all required governed reference values. Fail before creating BL-001 data if any required identity is absent or ambiguous.
2. **`baseline_series`.** Upsert by the governed business key `CATO + MedicationRequest + HUMAN_WORKING_DRAFT`; reuse exactly one existing row or create it.
3. **`baseline_version`.** Insert immutable BL-001 with `baseline_code=BL-001`, its approved version label, `is_gold_standard=false`, and the approved import-specification version. Do not reuse an existing code for a different digest or mutate a historical version.
4. **`artifact`.** Insert or resolve the content-addressed workbook artifact using SHA-256 `3c7e551109ab814712c3b7bbbbda4d41b457327452e4eee7746e698283fdc46`, byte size `252859`, workbook media type, physical filename, capture time, and source-modified timestamp.
5. **`artifact_location`.** Append the observed repository/file location with availability `AVAILABLE`; do not overwrite location history.
6. **`baseline_artifact`.** Link BL-001 to the artifact as `AUTHORITATIVE_SOURCE`. The transaction must leave exactly one authoritative source artifact for BL-001.
7. **`artifact_sheet_manifest`.** Insert the seven manifest rows above, including the three authoritative sheet ranges and the four contextual/non-authoritative sheets.
8. **Governance evidence registration.** Insert or resolve the BL-001 governance items, approved actions, and typed evidence needed by the `GOVERNANCE_APPROVED` gate requirement, including the four cardinality exceptions, status translations, five governed guidance identities, accepted E38 treatment, and accepted-with-quarantine policy.
9. **`import_run`.** Insert a running import with policy `ACCEPTED_WITH_QUARANTINE`, the approved import-specification and importer versions, a configuration digest covering parsing, normalization, key, raw-schema, validation-ruleset, and manifest versions, the authoritative artifact ID, actors, and start time.
10. **`import_candidate_row`.** Insert all 293 candidates with exact provenance, typed `raw_source_row`, 32-byte `source_row_hash`, normalization/key versions, deterministic calculated logical key and components, and final candidate disposition: 292 `ACCEPTED`, row 77 `QUARANTINED`.
11. **Validation.** Insert one completed `validation_run` bound to the import, artifact digest, and `BASELINE_IMPORT/v1` ruleset. Record 293 candidates, 292 accepted, 5 warnings, 1 error, and 1 quarantined candidate with outcome `FAIL` as required by the DDL count/outcome invariant when an error finding exists. Insert five warning findings, one error finding, and their `validation_finding_row` links.
12. **Quarantine.** For S2T row 77 only, insert one `quarantine_case` opened by the error finding and one `quarantine_event` of type `OPENED`. Do not create a mapping record for this candidate.
13. **`logical_mapping_identity`.** Insert or reuse the 292 accepted deterministic identities. Do not create an authoritative mapping identity solely to bypass the quarantined row, and do not append sequence suffixes.
14. **`mapping_record` and subtype records.** Insert 292 mapping records, each matching its accepted candidate's kind, key evidence, and canonical Decision Status. Insert exactly one matching subtype row per record: 237 `element_mapping`, 9 `status_mapping_rule`, and 46 `governance_guidance` rows.
15. **Import metrics.** Insert reconciled `import_run_metric` rows for overall and required sheet/kind/status/severity slices. Overall metrics are candidates 293, accepted 292, warnings 5, errors 1, quarantined 1. Warning/error metrics use finding counts, not affected-row counts.
16. **Finalize the import run.** Set the import completion time and terminal status `COMMITTED` only after deferred integrity checks reconcile candidates, mappings, subtype cardinality, validation findings, quarantine state, metrics, artifact authority, and logical-key evidence.
17. **Release gate.** Insert a `release_gate_evaluation` and four `release_gate_result` rows for `AUTHORITATIVE_ARTIFACT_REGISTERED`, `VALIDATION_COMPLETED`, `GOVERNANCE_APPROVED`, and `PROVENANCE_RECONCILED`. A passed gate is permissible only if each requirement is supported by persisted evidence and the accepted-with-quarantine result remains visible. Bind the evaluation to this exact digest and validation run.
18. **Lifecycle event.** After a passed release gate, append the governed BL-001 lifecycle event. If the approved lifecycle target is `ACTIVE`, preserve the unresolved quarantine as a derived reconciled-with-quarantine condition; do not describe the import as clean. If any gate requirement fails, record no `ACTIVE` event.

## 11. Final readiness decision

The fingerprint, manifest, approved translations, governed guidance identities, raw evidence generation, deterministic keys, and accepted-with-quarantine path are all executable against migrations 001–012. The one invalid row has an exact deterministic quarantine disposition and does not require invented data.

`READY_FOR_BL001_IMPORT`

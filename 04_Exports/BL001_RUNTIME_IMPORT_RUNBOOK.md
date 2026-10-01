# BL-001 Runtime Import Runbook

## Scope and safety boundary

Use this package only in the disposable Supabase test project after migrations 001–012 have passed. Do not run it in production. The package does not modify the workbook or any migration. It imports the exact dry-run payload for workbook SHA-256 `3c7e551109ab814712c3b7bbbbbda4d41b457327452e4eee7746e698283fdc46`.

The SQL is one transaction. It acquires `s2t_fhir_owner` locally, resolves the seeded `postgres-role / s2t_fhir_importer` principal as the actor, defers cross-table integrity constraints while dependent rows are loaded, forces them before release, and commits only after final assertions. Any error rolls back the entire package.

## Before execution

1. Confirm the selected Supabase project is disposable and not production.
2. Confirm migrations 001–012 completed successfully and migration 012 rolled back its test data.
3. Confirm the executing database identity may `SET ROLE s2t_fhir_owner`.
4. Independently hash `01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx`. The result must be `3c7e551109ab814712c3b7bbbbbda4d41b457327452e4eee7746e698283fdc46`.
5. Confirm `BL-001` does not already exist. The package intentionally fails instead of overwriting or duplicating it.
6. Use a client that executes the complete SQL file as one session and stops on the first error. Do not split the transaction across connections.

## Exact execution order and expected rows

| Stage | Operation | Expected inserted rows |
|---:|---|---:|
| 0 | Resolve actor, 52 required reference selectors, ruleset, gate, and four requirements | Temporary only |
| 1 | `baseline_series` (insert only if absent), then `baseline_version` | 0–1; 1 |
| 2 | `artifact` (insert only if digest absent), `artifact_location`, `baseline_artifact`, `artifact_sheet_manifest` | 0–1; 1; 1; 7 |
| 3 | Open `import_run` | 1 |
| 4 | `import_candidate_row` | 293 |
| 5 | `validation_run`, `validation_finding`, `validation_finding_row`, `quarantine_case`, `quarantine_event` | 1; 6; 6; 1; 1 |
| 6 | `logical_mapping_identity`, `mapping_record`, `element_mapping`, `status_mapping_rule`, `governance_guidance` | 292; 292; 237; 9; 46 |
| 7 | `import_run_metric` | 62 |
| 8 | `governance_item`, `governance_action`, pre-release `governance_evidence` | 12; 12; 13 |
| 9 | Integrity checks and import-run finalization | 1 `import_run` updated to `COMMITTED` |
| 10 | `release_gate_evaluation`, `release_gate_result`, release evidence | 1; 4; 1 |
| 11 | Conditional `baseline_lifecycle_event` after passed-gate verification | 1 `ACTIVE` event |

The fixed reconciliation is 293 candidates, 292 accepted, 1 quarantined, 5 warning findings, and 1 error finding. The one quarantined candidate is `S2T MedicationRequestCato!77` (`A77:Q77`). It has no logical identity, mapping record, or subtype.

## Execution

Run `04_Exports/BL001_RUNTIME_IMPORT.sql` exactly once in the disposable project. Do not edit values inside the payload. If the client reports an error, preserve the error text, issue `ROLLBACK` if the client left the transaction open, and investigate before retrying in a freshly reset disposable project.

## Verification queries

### Import and validation reconciliation

```sql
select bv.baseline_code, ir.import_run_id, s.value_code as import_status,
       vr.candidate_count, vr.accepted_count, vr.quarantined_count,
       vr.warning_count, vr.error_count, vo.value_code as validation_outcome
from s2t_fhir.baseline_version bv
join s2t_fhir.import_run ir using (baseline_version_id)
join s2t_fhir.reference_value s on s.reference_value_id=ir.terminal_status_value_id
join s2t_fhir.validation_run vr using (import_run_id)
join s2t_fhir.reference_value vo on vo.reference_value_id=vr.outcome_value_id
where bv.baseline_code='BL-001';
```

Expected: one row; `COMMITTED`, `293`, `292`, `1`, `5`, `1`, `FAIL`. `FAIL` is required because the preserved quarantine was opened by one error finding.

```sql
select count(*) as candidates,
       count(*) filter (where d.value_code='ACCEPTED') as accepted,
       count(*) filter (where d.value_code='QUARANTINED') as quarantined,
       count(*) filter (where c.raw_source_row is not null and octet_length(c.source_row_hash)=32
                         and c.calculated_logical_key is not null and c.logical_key_components_json is not null) as full_provenance
from s2t_fhir.import_candidate_row c
join s2t_fhir.import_run ir using(import_run_id)
join s2t_fhir.baseline_version bv using(baseline_version_id)
join s2t_fhir.reference_value d on d.reference_value_id=c.candidate_disposition_value_id
where bv.baseline_code='BL-001';
```

Expected: `293 / 292 / 1 / 293`.

### Mapping and subtype counts

```sql
select count(*) as mapping_records,
       count(em.mapping_record_id) as element_mappings,
       count(sm.mapping_record_id) as status_rules,
       count(gg.mapping_record_id) as guidance_rows
from s2t_fhir.mapping_record mr
join s2t_fhir.baseline_version bv using(baseline_version_id)
left join s2t_fhir.element_mapping em using(mapping_record_id)
left join s2t_fhir.status_mapping_rule sm using(mapping_record_id)
left join s2t_fhir.governance_guidance gg using(mapping_record_id)
where bv.baseline_code='BL-001';
```

Expected: `292 / 237 / 9 / 46`.

### Quarantined row

```sql
select c.source_sheet_name, c.source_row_number, c.source_cell_range,
       d.value_code as disposition, encode(c.source_row_hash,'hex') as source_row_hash,
       c.calculated_logical_key, c.logical_key_components_json,
       c.raw_source_row, q.quarantine_case_id, f.finding_code, s.value_code as severity,
       mr.mapping_record_id, em.mapping_record_id as element_mapping_id
from s2t_fhir.import_candidate_row c
join s2t_fhir.import_run ir using(import_run_id)
join s2t_fhir.baseline_version bv using(baseline_version_id)
join s2t_fhir.reference_value d on d.reference_value_id=c.candidate_disposition_value_id
left join s2t_fhir.quarantine_case q using(import_candidate_row_id)
left join s2t_fhir.validation_finding f on f.validation_finding_id=q.opening_validation_finding_id
left join s2t_fhir.reference_value s on s.reference_value_id=f.severity_value_id
left join s2t_fhir.mapping_record mr using(import_candidate_row_id)
left join s2t_fhir.element_mapping em using(mapping_record_id)
where bv.baseline_code='BL-001'
  and c.source_sheet_name='S2T MedicationRequestCato' and c.source_row_number=77;
```

Expected: one row, range `A77:Q77`, disposition `QUARANTINED`, finding `INVALID_CARDINALITY`, severity `ERROR`, and both mapping IDs null. The raw evidence must retain the blank cardinality; its calculated logical key and key components remain provenance only.

### Artifact and sheet manifest

```sql
select encode(a.sha256_digest,'hex') as sha256, a.byte_size, a.physical_filename,
       count(asm.*) as manifest_rows,
       count(*) filter (where asm.is_authoritative) as authoritative_sheets,
       sum(asm.candidate_row_count) filter (where asm.is_authoritative) as candidate_rows
from s2t_fhir.baseline_version bv
join s2t_fhir.baseline_artifact ba using(baseline_version_id)
join s2t_fhir.artifact a using(artifact_id)
join s2t_fhir.artifact_sheet_manifest asm using(artifact_id)
where bv.baseline_code='BL-001'
group by a.sha256_digest,a.byte_size,a.physical_filename;
```

Expected: the registered digest, `252859`, the workbook filename, 7 manifest rows, 3 authoritative sheets, and 293 candidate rows.

### Governance and release state

```sql
select count(distinct gi.governance_item_id) as items,
       count(distinct ga.governance_action_id) as approved_actions,
       count(distinct ge.governance_evidence_id) as evidence_rows
from s2t_fhir.governance_item gi
join s2t_fhir.governance_action ga using(governance_item_id)
join s2t_fhir.reference_value at on at.reference_value_id=ga.action_type_value_id and at.value_code='APPROVED'
left join s2t_fhir.governance_evidence ge using(governance_action_id)
join s2t_fhir.baseline_version bv using(baseline_version_id)
where bv.baseline_code='BL-001';
```

Expected: 12 items, 12 approved actions, 14 evidence rows (including validation and release evidence).

```sql
select g.gate_code, g.version_label, o.value_code as gate_outcome,
       count(r.*) as result_count,
       count(*) filter (where ro.value_code='PASSED') as passed_results
from s2t_fhir.current_release_gate_evaluation e
join s2t_fhir.baseline_version bv using(baseline_version_id)
join s2t_fhir.release_gate_definition g using(release_gate_definition_id)
join s2t_fhir.reference_value o on o.reference_value_id=e.gate_outcome_value_id
left join s2t_fhir.release_gate_result r using(release_gate_evaluation_id)
left join s2t_fhir.reference_value ro on ro.reference_value_id=r.requirement_outcome_value_id
where bv.baseline_code='BL-001'
group by g.gate_code,g.version_label,o.value_code;
```

Expected: `BASELINE_IMPORT / v1 / PASSED / 4 / 4`.

```sql
select bv.baseline_code, s.value_code as lifecycle_status, e.occurred_at, e.reason
from s2t_fhir.current_baseline_lifecycle_event e
join s2t_fhir.baseline_version bv using(baseline_version_id)
join s2t_fhir.reference_value s on s.reference_value_id=e.lifecycle_status_value_id
where bv.baseline_code='BL-001';
```

Expected: one `ACTIVE` row whose reason explicitly states that one unresolved quarantine remains visible. Absence of `ACTIVE` means a gate condition failed or the transaction did not commit.

## Rollback guidance

- Before `COMMIT`, run `ROLLBACK`; all persistent BL-001 rows disappear because the package is one transaction.
- Any assertion, trigger, FK, uniqueness, or release-gate failure aborts the transaction. Run `ROLLBACK` if the client does not do so automatically.
- After `COMMIT`, do not delete or update governed evidence. The schema is append-only by design. Reset or recreate the disposable test project and reapply migrations 001–012 for a clean retry.
- Never write a destructive down migration for this test import, and never apply cleanup SQL to production.

## Final acceptance criteria

Accept the runtime import only when all queries above match exactly, the quarantine row has no mapping or subtype, the current release gate is `PASSED` with four passed results, and the current lifecycle state is `ACTIVE`. If any value differs, treat the run as failed and rebuild the disposable project.

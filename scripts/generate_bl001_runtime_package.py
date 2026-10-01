from __future__ import annotations

import json
import re
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DRY = ROOT / "04_Exports" / "BL001_DRY_RUN"
OUT_SQL = ROOT / "04_Exports" / "BL001_RUNTIME_IMPORT.sql"
OUT_RUNBOOK = ROOT / "04_Exports" / "BL001_RUNTIME_IMPORT_RUNBOOK.md"
NS = uuid.UUID("4d966f73-31f2-4b85-a1d8-fbc9788a8073")


def load(name: str) -> list[dict]:
    return [json.loads(line) for line in (DRY / f"{name}.jsonl").read_text(encoding="utf-8").splitlines() if line]


def q(value):
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def j(value):
    if value is None:
        return "NULL"
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return q(raw) + "::jsonb"


def hx(value):
    return f"pg_catalog.decode({q(value)}, 'hex')"


def ref(selector):
    if selector is None:
        return "NULL"
    return (
        "(select reference_value_id from pg_temp.bl001_ref where domain_code="
        + q(selector["domain_code"])
        + " and value_code="
        + q(selector["value_code"])
        + " and version_number="
        + str(selector.get("version_number", 1))
        + ")"
    )


def principal(selector):
    if selector is None:
        return "NULL"
    return (
        "(select principal_id from pg_temp.bl001_ctx where singleton and actor_issuer="
        + q(selector["external_issuer"])
        + " and actor_subject="
        + q(selector["external_subject"])
        + ")"
    )


def values_insert(table: str, columns: list[str], rows: list[list[str]], chunk=75):
    parts = []
    for start in range(0, len(rows), chunk):
        batch = rows[start : start + chunk]
        rendered = ",\n".join("  (" + ", ".join(row) + ")" for row in batch)
        parts.append(f"insert into s2t_fhir.{table} ({', '.join(columns)}) values\n{rendered};")
    return "\n\n".join(parts)


def uid(label: str) -> str:
    return str(uuid.uuid5(NS, label))


def candidate(sheet: str, row: int) -> dict:
    found = [x for x in load("import_candidate_row") if x["source_sheet_name"] == sheet and x["source_row_number"] == row]
    if len(found) != 1:
        raise RuntimeError(f"Expected one candidate for {sheet}!{row}, got {len(found)}")
    return found[0]


def build_sql() -> str:
    manifest = json.loads((DRY / "manifest.json").read_text(encoding="utf-8"))
    expected_digest = "3c7e551109ab814712c3b7bbbbbda4d41b457327452e4eee7746e698283fdc46"
    assert manifest["artifact_sha256"] == expected_digest

    bseries = load("baseline_series")[0]
    bversion = load("baseline_version")[0]
    artifact = load("artifact")[0]
    location = load("artifact_location")[0]
    bart = load("baseline_artifact")[0]
    irun = load("import_run")[0]
    vrun = load("validation_run")[0]

    sections = [f"""-- BL-001 runtime import package
-- Generated from 04_Exports/BL001_DRY_RUN and migrations 001-012.
-- TARGET: disposable Supabase test project only. DO NOT RUN IN PRODUCTION.
-- This file is intentionally self-contained and transaction-safe.
-- Expected workbook SHA-256: {expected_digest}

begin;
set local role s2t_fhir_owner;
set local lock_timeout = '10s';
set local statement_timeout = '10min';
set constraints all deferred;

-- Stage 0: resolve the seeded service principal and all governed reference values.
create temp table bl001_ref on commit drop as
select rd.domain_code, rv.value_code, rv.version_number, rv.reference_value_id
from s2t_fhir.reference_domain rd
join s2t_fhir.reference_value rv using (reference_domain_id)
where (rd.domain_code, rv.value_code) in (
  ('BASELINE_TYPE','HUMAN_WORKING_DRAFT'), ('ARTIFACT_KIND','WORKBOOK'),
  ('ARTIFACT_LOCATION_KIND','REPOSITORY_PATH'), ('ARTIFACT_AVAILABILITY','AVAILABLE'),
  ('ARTIFACT_ROLE','AUTHORITATIVE_SOURCE'), ('SHEET_CLASSIFICATION','AUTHORITATIVE'),
  ('SHEET_CLASSIFICATION','WIP_PROFILE'), ('SHEET_CLASSIFICATION','WIP_ROUTE_MAPPING'),
  ('SHEET_CLASSIFICATION','OUT_OF_SCOPE'), ('SHEET_CLASSIFICATION','EXAMPLE_ONLY'),
  ('IMPORT_POLICY','ACCEPTED_WITH_QUARANTINE'), ('IMPORT_RUN_STATUS','COMMITTED'),
  ('MAPPING_KIND','ELEMENT_MAPPING'), ('MAPPING_KIND','STATUS_MAPPING_RULE'),
  ('MAPPING_KIND','GOVERNANCE_GUIDANCE'), ('CANDIDATE_DISPOSITION','ACCEPTED'),
  ('CANDIDATE_DISPOSITION','QUARANTINED'), ('DECISION_STATUS','FINAL'),
  ('DECISION_STATUS','WIP'), ('DECISION_STATUS','OPEN'), ('DECISION_STATUS','DO NOT MAP'),
  ('DECISION_STATUS','N/A'), ('VALIDATION_OUTCOME','FAIL'), ('SEVERITY','WARNING'),
  ('SEVERITY','ERROR'), ('FINDING_ROW_ROLE','SUBJECT'), ('QUARANTINE_EVENT_TYPE','OPENED'),
  ('GUIDANCE_SCOPE','GLOBAL_MAPPING_POLICY'), ('GUIDANCE_SCOPE','MEDICATION_COMPOSITION'),
  ('GUIDANCE_SCOPE','DOSAGE_TIMING'), ('GUIDANCE_SCOPE','PATIENT_IDENTITY'),
  ('GUIDANCE_SCOPE','TREATMENT_PLAN_ACCESS'), ('DECISION_TOPIC_CODE','NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING'),
  ('DECISION_TOPIC_CODE','PRESCRIBED_DRUG_INGREDIENT_REPRESENTATION'),
  ('DECISION_TOPIC_CODE','PO_DURATION_CLINICAL_SIGNIFICANCE'),
  ('DECISION_TOPIC_CODE','CATO_SSN_PATIENT_IDENTIFIER_SEMANTICS'),
  ('DECISION_TOPIC_CODE','PATIENT_IDENTIFIER_FOR_PLAN_RETRIEVAL'),
  ('METRIC_TYPE','CANDIDATE'), ('METRIC_TYPE','ACCEPTED'), ('METRIC_TYPE','QUARANTINED'),
  ('METRIC_TYPE','WARNING'), ('METRIC_TYPE','ERROR'),
  ('GOVERNANCE_CLASSIFICATION','GOVERNANCE_DECISION'),
  ('GOVERNANCE_CLASSIFICATION','ACCEPT_WITH_RAW_ERROR_PRESERVED'),
  ('GOVERNANCE_ACTION_TYPE','APPROVED'), ('EVIDENCE_ROLE','PRIMARY'),
  ('EVIDENCE_ROLE','SUPPORTING'), ('EVIDENCE_ROLE','VALIDATION'), ('EVIDENCE_ROLE','RELEASE'),
  ('RELEASE_GATE_OUTCOME','PASSED'), ('REQUIREMENT_OUTCOME','PASSED'),
  ('BASELINE_LIFECYCLE_STATUS','ACTIVE')
);

create temp table bl001_ctx (
  singleton boolean primary key default true check (singleton),
  actor_issuer text not null,
  actor_subject text not null,
  principal_id uuid not null,
  baseline_series_id uuid,
  artifact_id uuid
) on commit drop;

insert into bl001_ctx(singleton, actor_issuer, actor_subject, principal_id)
select true, p.external_issuer, p.external_subject, p.principal_id
from s2t_fhir.principal p
where p.external_issuer='postgres-role' and p.external_subject='s2t_fhir_importer' and p.disabled_at is null;

do $bl001_preflight$
declare missing text; actual_refs integer; expected_refs integer := 52;
begin
  if (select count(*) from pg_temp.bl001_ctx) <> 1 then
    raise exception 'BL-001 requires exactly one active postgres-role/s2t_fhir_importer principal';
  end if;
  select count(*) into actual_refs from pg_temp.bl001_ref;
  if actual_refs <> expected_refs then
    select string_agg(x.domain_code || '/' || x.value_code, ', ' order by x.domain_code, x.value_code)
      into missing
    from (values
      ('BASELINE_TYPE','HUMAN_WORKING_DRAFT'),('ARTIFACT_KIND','WORKBOOK'),('ARTIFACT_LOCATION_KIND','REPOSITORY_PATH'),
      ('ARTIFACT_AVAILABILITY','AVAILABLE'),('ARTIFACT_ROLE','AUTHORITATIVE_SOURCE'),('IMPORT_POLICY','ACCEPTED_WITH_QUARANTINE'),
      ('IMPORT_RUN_STATUS','COMMITTED'),('VALIDATION_OUTCOME','FAIL'),('RELEASE_GATE_OUTCOME','PASSED'),
      ('REQUIREMENT_OUTCOME','PASSED'),('BASELINE_LIFECYCLE_STATUS','ACTIVE')
    ) x(domain_code,value_code)
    where not exists (select 1 from pg_temp.bl001_ref r where r.domain_code=x.domain_code and r.value_code=x.value_code);
    raise exception 'BL-001 governed reference resolution failed: found %, expected %; critical missing=%', actual_refs, expected_refs, coalesce(missing,'<non-critical selector or duplicate>');
  end if;
  if exists (select 1 from s2t_fhir.baseline_version where baseline_code='BL-001') then
    raise exception 'BL-001 already exists; this one-shot runtime package will not overwrite or duplicate it';
  end if;
  if (select count(*) from s2t_fhir.validation_ruleset where ruleset_code='BASELINE_IMPORT' and version_label='v1') <> 1 then
    raise exception 'Expected exactly one BASELINE_IMPORT/v1 validation ruleset';
  end if;
  if (select count(*) from s2t_fhir.release_gate_definition where gate_code='BASELINE_IMPORT' and version_label='v1') <> 1 then
    raise exception 'Expected exactly one BASELINE_IMPORT/v1 release gate';
  end if;
  if (select count(*) from s2t_fhir.release_gate_requirement r join s2t_fhir.release_gate_definition g using(release_gate_definition_id) where g.gate_code='BASELINE_IMPORT' and g.version_label='v1') <> 4 then
    raise exception 'Expected four BASELINE_IMPORT/v1 release-gate requirements';
  end if;
end
$bl001_preflight$;

-- Stage 1: baseline series and immutable baseline version.
insert into s2t_fhir.baseline_series
  (baseline_series_id, source_system, fhir_resource, baseline_type_value_id, description, created_at)
select {q(bseries['baseline_series_id'])}::uuid, {q(bseries['source_system'])}, {q(bseries['fhir_resource'])},
       {ref(bseries['baseline_type_value_id'])}, {q(bseries['description'])}, {q(bseries['created_at'])}::timestamptz
where not exists (
  select 1 from s2t_fhir.baseline_series
  where source_system={q(bseries['source_system'])} and fhir_resource={q(bseries['fhir_resource'])}
    and baseline_type_value_id={ref(bseries['baseline_type_value_id'])}
);

update pg_temp.bl001_ctx c set baseline_series_id = s.baseline_series_id
from s2t_fhir.baseline_series s
where s.source_system={q(bseries['source_system'])} and s.fhir_resource={q(bseries['fhir_resource'])}
  and s.baseline_type_value_id={ref(bseries['baseline_type_value_id'])};

insert into s2t_fhir.baseline_version
  (baseline_version_id, baseline_series_id, baseline_code, version_label, is_gold_standard,
   import_specification_version, description, created_by_principal_id, created_at)
select {q(bversion['baseline_version_id'])}::uuid, c.baseline_series_id, {q(bversion['baseline_code'])},
       {q(bversion['version_label'])}, false, {q(bversion['import_specification_version'])},
       {q(bversion['description'])}, c.principal_id, {q(bversion['created_at'])}::timestamptz
from pg_temp.bl001_ctx c;

-- Stage 2: content-addressed workbook artifact, location, baseline link, and sheet manifest.
insert into s2t_fhir.artifact
  (artifact_id, artifact_kind_value_id, sha256_digest, byte_size, media_type, physical_filename,
   original_or_upload_name, captured_at, source_modified_at, description, created_by_principal_id, created_at)
select {q(artifact['artifact_id'])}::uuid, {ref(artifact['artifact_kind_value_id'])}, {hx(artifact['sha256_digest'])},
       {artifact['byte_size']}, {q(artifact['media_type'])}, {q(artifact['physical_filename'])},
       {q(artifact['original_or_upload_name'])}, {q(artifact['captured_at'])}::timestamptz,
       {q(artifact['source_modified_at'])}::timestamptz, {q(artifact['description'])}, c.principal_id,
       {q(artifact['created_at'])}::timestamptz
from pg_temp.bl001_ctx c
where not exists (select 1 from s2t_fhir.artifact where sha256_digest={hx(artifact['sha256_digest'])});

update pg_temp.bl001_ctx c set artifact_id = a.artifact_id
from s2t_fhir.artifact a where a.sha256_digest={hx(artifact['sha256_digest'])};

do $bl001_artifact$
begin
  if not exists (
    select 1 from s2t_fhir.artifact a join pg_temp.bl001_ctx c on c.artifact_id=a.artifact_id
    where a.byte_size=252859 and a.media_type='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      and a.physical_filename='CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx'
  ) then raise exception 'Existing content-addressed artifact metadata does not match BL-001'; end if;
end
$bl001_artifact$;

insert into s2t_fhir.artifact_location
  (artifact_location_id, artifact_id, location_kind_value_id, location_uri, observed_at, recorded_at,
   actor_principal_id, initiating_human_principal_id, availability_status_value_id, supersedes_location_id, note)
select {q(location['artifact_location_id'])}::uuid, c.artifact_id, {ref(location['location_kind_value_id'])},
       {q(location['location_uri'])}, {q(location['observed_at'])}::timestamptz, {q(location['recorded_at'])}::timestamptz,
       c.principal_id, null, {ref(location['availability_status_value_id'])}, null, {q(location['note'])}
from pg_temp.bl001_ctx c;

insert into s2t_fhir.baseline_artifact
  (baseline_artifact_id, baseline_version_id, artifact_id, artifact_role_value_id, note, created_by_principal_id, created_at)
select {q(bart['baseline_artifact_id'])}::uuid, {q(bart['baseline_version_id'])}::uuid, c.artifact_id,
       {ref(bart['artifact_role_value_id'])}, {q(bart['note'])}, c.principal_id, {q(bart['created_at'])}::timestamptz
from pg_temp.bl001_ctx c;
"""]

    rows = []
    for x in load("artifact_sheet_manifest"):
        rows.append([
            q(x["artifact_sheet_manifest_id"]) + "::uuid", "(select artifact_id from pg_temp.bl001_ctx where singleton)",
            q(x["sheet_name"]), str(x["sheet_order"]), ref(x["sheet_classification_value_id"]), q(x["is_present"]),
            q(x["is_authoritative"]), q(x["header_row_number"]), q(x["candidate_range"]), q(x["governed_column_range"]),
            q(x["candidate_row_count"]), q(x["notes"]), q(x["manifest_schema_id"]), q(x["manifest_schema_version"]),
            j(x["manifest_json"]), q(x["created_at"]) + "::timestamptz",
        ])
    sections.append(values_insert("artifact_sheet_manifest", ["artifact_sheet_manifest_id","artifact_id","sheet_name","sheet_order","sheet_classification_value_id","is_present","is_authoritative","header_row_number","candidate_range","governed_column_range","candidate_row_count","notes","manifest_schema_id","manifest_schema_version","manifest_json","created_at"], rows))

    sections.append(f"""
-- Stage 3: create the running import.
insert into s2t_fhir.import_run
  (import_run_id, baseline_version_id, artifact_id, import_policy_value_id, import_specification_version,
   importer_version, configuration_digest, started_at, actor_principal_id, initiating_human_principal_id, created_at)
select {q(irun['import_run_id'])}::uuid, {q(irun['baseline_version_id'])}::uuid, c.artifact_id,
       {ref(irun['import_policy_value_id'])}, {q(irun['import_specification_version'])}, {q(irun['importer_version'])},
       {hx(irun['configuration_digest'])}, {q(irun['started_at'])}::timestamptz, c.principal_id, null,
       {q(irun['created_at'])}::timestamptz
from pg_temp.bl001_ctx c;
""")

    rows = []
    for x in load("import_candidate_row"):
        rows.append([
            q(x["import_candidate_row_id"]) + "::uuid", q(x["import_run_id"]) + "::uuid", ref(x["mapping_kind_value_id"]),
            q(x["source_sheet_name"]), str(x["source_row_number"]), q(x["source_cell_range"]), q(x["raw_schema_id"]),
            q(x["raw_schema_version"]), j(x["raw_source_row"]), hx(x["source_row_hash"]), q(x["normalization_algorithm_version"]),
            q(x["logical_key_algorithm_version"]), ref(x["candidate_disposition_value_id"]), q(x["calculated_logical_key"]),
            j(x["logical_key_components_json"]),
        ])
    sections.append("-- Stage 4: all 293 candidates, including exact raw evidence and source provenance.\n" + values_insert("import_candidate_row", ["import_candidate_row_id","import_run_id","mapping_kind_value_id","source_sheet_name","source_row_number","source_cell_range","raw_schema_id","raw_schema_version","raw_source_row","source_row_hash","normalization_algorithm_version","logical_key_algorithm_version","candidate_disposition_value_id","calculated_logical_key","logical_key_components_json"], rows, 30))

    sections.append(f"""
-- Stage 5: validation run, findings, finding-to-row links, and quarantine.
insert into s2t_fhir.validation_run
  (validation_run_id, import_run_id, validation_ruleset_id, artifact_id, artifact_digest, execution_fingerprint,
   started_at, completed_at, candidate_count, accepted_count, warning_count, error_count, quarantined_count,
   outcome_value_id, actor_principal_id, initiating_human_principal_id, summary_json, created_at)
select {q(vrun['validation_run_id'])}::uuid, {q(vrun['import_run_id'])}::uuid, vr.validation_ruleset_id,
       c.artifact_id, {hx(vrun['artifact_digest'])}, {hx(vrun['execution_fingerprint'])},
       {q(vrun['started_at'])}::timestamptz, {q(vrun['completed_at'])}::timestamptz,
       293, 292, 5, 1, 1, {ref(vrun['outcome_value_id'])}, c.principal_id, null,
       {j(vrun['summary_json'])}, {q(vrun['created_at'])}::timestamptz
from pg_temp.bl001_ctx c
cross join s2t_fhir.validation_ruleset vr
where vr.ruleset_code='BASELINE_IMPORT' and vr.version_label='v1';
""")

    rows = []
    for x in load("validation_finding"):
        vr = x["validation_rule_id"]
        rule = f"(select r.validation_rule_id from s2t_fhir.validation_rule r join s2t_fhir.validation_ruleset s using(validation_ruleset_id) where s.ruleset_code={q(vr['ruleset_code'])} and s.version_label={q(vr['ruleset_version'])} and r.rule_code={q(vr['rule_code'])} and r.rule_version={q(vr['rule_version'])})"
        rows.append([q(x["validation_finding_id"])+"::uuid", q(x["validation_run_id"])+"::uuid", rule, ref(x["severity_value_id"]), q(x["finding_code"]), q(x["message"]), hx(x["finding_fingerprint"]), q(x["collision_group_key"]), q(x["evidence_schema_id"]), q(x["evidence_schema_version"]), j(x["evidence_json"]), q(x["created_at"])+"::timestamptz"])
    sections.append(values_insert("validation_finding", ["validation_finding_id","validation_run_id","validation_rule_id","severity_value_id","finding_code","message","finding_fingerprint","collision_group_key","evidence_schema_id","evidence_schema_version","evidence_json","created_at"], rows))

    rows = []
    for x in load("validation_finding_row"):
        rows.append([q(x["validation_finding_row_id"])+"::uuid", q(x["validation_finding_id"])+"::uuid", q(x["import_candidate_row_id"])+"::uuid", ref(x["finding_row_role_value_id"]), q(x["created_at"])+"::timestamptz"])
    sections.append(values_insert("validation_finding_row", ["validation_finding_row_id","validation_finding_id","import_candidate_row_id","finding_row_role_value_id","created_at"], rows))

    x = load("quarantine_case")[0]
    sections.append(values_insert("quarantine_case", ["quarantine_case_id","import_candidate_row_id","opening_validation_finding_id","opened_at","opened_by_principal_id","initiating_human_principal_id","created_at"], [[q(x["quarantine_case_id"])+"::uuid",q(x["import_candidate_row_id"])+"::uuid",q(x["opening_validation_finding_id"])+"::uuid",q(x["opened_at"])+"::timestamptz",principal(x["opened_by_principal_id"]),"NULL",q(x["created_at"])+"::timestamptz"]]))
    x = load("quarantine_event")[0]
    sections.append(values_insert("quarantine_event", ["quarantine_event_id","quarantine_case_id","event_type_value_id","occurred_at","recorded_at","actor_principal_id","initiating_human_principal_id","governance_action_id","resolution_code_value_id","reason","supersedes_event_id","replacement_baseline_version_id"], [[q(x["quarantine_event_id"])+"::uuid",q(x["quarantine_case_id"])+"::uuid",ref(x["event_type_value_id"]),q(x["occurred_at"])+"::timestamptz",q(x["recorded_at"])+"::timestamptz",principal(x["actor_principal_id"]),"NULL","NULL","NULL",q(x["reason"]),"NULL","NULL"]]))

    rows = []
    for x in load("logical_mapping_identity"):
        rows.append([q(x["logical_mapping_identity_id"])+"::uuid",ref(x["mapping_kind_value_id"]),q(x["source_system"]),q(x["fhir_resource"]),q(x["key_algorithm_version"]),q(x["logical_key"]),j(x["key_components_json"]),q(x["created_at"])+"::timestamptz"])
    sections.append("-- Stage 6: accepted logical identities and mapping parents.\n" + values_insert("logical_mapping_identity", ["logical_mapping_identity_id","mapping_kind_value_id","source_system","fhir_resource","key_algorithm_version","logical_key","key_components_json","created_at"], rows, 75))

    rows = []
    for x in load("mapping_record"):
        rows.append([q(x["mapping_record_id"])+"::uuid",q(x["baseline_version_id"])+"::uuid",q(x["import_candidate_row_id"])+"::uuid",q(x["logical_mapping_identity_id"])+"::uuid",ref(x["mapping_kind_value_id"]),ref(x["decision_status_value_id"]),q(x["created_at"])+"::timestamptz"])
    sections.append(values_insert("mapping_record", ["mapping_record_id","baseline_version_id","import_candidate_row_id","logical_mapping_identity_id","mapping_kind_value_id","decision_status_value_id","created_at"], rows, 75))

    for name, columns in [
        ("element_mapping", ["mapping_record_id","target_fhir_path","source_system_raw","interface_type","interface_name","source_expression","profile_context","fixed_value","transformation_rule","source_business_definition","cardinality_raw","cardinality_min","cardinality_max","cardinality_max_unbounded","valueset_binding","mandated_code_system","irrelevant_under_s2t_raw","example_value","exception_handling","notes"]),
        ("status_mapping_rule", ["mapping_record_id","source_status_value","target_fhir_path","target_status_value","source_sequence","source_business_definition","related_resource_note","transformation_rule","mapping_evidence_status_raw","notes"]),
        ("governance_guidance", ["mapping_record_id","guidance_scope_value_id","decision_topic_value_id","guidance_text","guidance_status_raw","target_fhir_path_or_scope_raw","decision_topic_raw","notes","review_notes"]),
    ]:
        rows = []
        for x in load(name):
            row=[]
            for col in columns:
                value=x[col]
                if col.endswith("_value_id"):
                    row.append(ref(value))
                elif col=="mapping_record_id": row.append(q(value)+"::uuid")
                else: row.append(q(value))
            rows.append(row)
        sections.append(values_insert(name, columns, rows, 75))

    rows=[]
    for x in load("import_run_metric"):
        rows.append([q(x["import_run_metric_id"])+"::uuid",q(x["import_run_id"])+"::uuid",ref(x["metric_type_value_id"]),str(x["metric_count"]),q(x["source_sheet_name"]),ref(x["mapping_kind_value_id"]),ref(x["decision_status_value_id"]),ref(x["severity_value_id"]),q(x["created_at"])+"::timestamptz"])
    sections.append("-- Stage 7: reconciled metrics.\n" + values_insert("import_run_metric", ["import_run_metric_id","import_run_id","metric_type_value_id","metric_count","source_sheet_name","mapping_kind_value_id","decision_status_value_id","severity_value_id","created_at"], rows))

    evidence_specs = [
        ("ACCEPTED_WITH_QUARANTINE", "GOVERNANCE_DECISION", "Approve accepted-with-quarantine import policy", None, "artifact", "The BL-001 import may commit with one preserved unresolved quarantine."),
        ("STATUS_TRANSLATIONS", "GOVERNANCE_DECISION", "Approve CATO-to-FHIR status translations", None, "artifact", "The nine status translations in the authoritative workbook are approved."),
    ]
    for row in (101,102,103,104):
        evidence_specs.append((f"CARDINALITY_EXCEPTION_{row}","GOVERNANCE_DECISION",f"Approve blank-cardinality exception for S2T row {row}",candidate("S2T MedicationRequestCato",row)["import_candidate_row_id"],"candidate",f"Approved semantic blank-cardinality exception at current workbook row {row}."))
    for row, code in [(3,"GLOBAL_MAPPING_POLICY"),(4,"MEDICATION_COMPOSITION"),(5,"DOSAGE_TIMING"),(6,"PATIENT_IDENTITY"),(7,"TREATMENT_PLAN_ACCESS")]:
        evidence_specs.append((f"GUIDANCE_IDENTITY_{code}","GOVERNANCE_DECISION",f"Approve governed guidance identity {code}",candidate("הנחיות נוספות מעודכן",row)["import_candidate_row_id"],"candidate",f"Approved governed identity for guidance row {row}."))
    evidence_specs.append(("RAW_OPTIONAL_CELL_ERROR_E38","ACCEPT_WITH_RAW_ERROR_PRESERVED","Approve raw optional #VALUE! preservation",candidate("הנחיות נוספות מעודכן",38)["import_candidate_row_id"],"candidate","The optional E38 Excel error is accepted only with its raw typed evidence preserved."))

    item_rows=[]; action_rows=[]; evidence_rows=[]
    for code, classification, title, target_id, target_kind, rationale in evidence_specs:
        item_id=uid("governance-item:"+code); action_id=uid("governance-action:"+code)
        item_rows.append([q(item_id)+"::uuid",q(bversion["baseline_version_id"])+"::uuid",q(code),ref({"domain_code":"GOVERNANCE_CLASSIFICATION","value_code":classification,"version_number":1}),q(title),q(rationale),q("BL-001 preflight and dry-run evidence"),"(select principal_id from pg_temp.bl001_ctx where singleton)",q(irun["started_at"])+"::timestamptz"])
        action_rows.append([q(action_id)+"::uuid",q(item_id)+"::uuid",ref({"domain_code":"GOVERNANCE_ACTION_TYPE","value_code":"APPROVED","version_number":1}),q(irun["started_at"])+"::timestamptz",q(irun["started_at"])+"::timestamptz","(select principal_id from pg_temp.bl001_ctx where singleton)","NULL","NULL",q(rationale)])
        ev_id=uid("governance-evidence:"+code)
        artifact_target = "(select artifact_id from pg_temp.bl001_ctx where singleton)" if target_kind == "artifact" else "NULL"
        candidate_target = q(target_id) + "::uuid" if target_kind == "candidate" else "NULL"
        evidence_rows.append([q(ev_id)+"::uuid",q(action_id)+"::uuid",ref({"domain_code":"EVIDENCE_ROLE","value_code":"PRIMARY","version_number":1}),artifact_target,"NULL","NULL",candidate_target,"NULL","NULL",q(rationale),q(irun["started_at"])+"::timestamptz"])

    policy_action=uid("governance-action:ACCEPTED_WITH_QUARANTINE")
    evidence_rows.append([q(uid("governance-evidence:validation-run"))+"::uuid",q(policy_action)+"::uuid",ref({"domain_code":"EVIDENCE_ROLE","value_code":"VALIDATION","version_number":1}),"NULL","NULL",q(vrun["validation_run_id"])+"::uuid","NULL","NULL","NULL",q("BL-001 validation run: 293 candidates, 292 accepted, 1 quarantined, 5 warnings, 1 error."),q(irun["started_at"])+"::timestamptz"])
    for evidence_row in evidence_rows:
        target_values = evidence_row[3:9]
        assert sum(value != "NULL" for value in target_values) == 1, (
            "governance_evidence row must have exactly one target",
            evidence_row[0],
            target_values,
        )
    sections.append("-- Stage 8: governed approvals and typed evidence required by the release gate.\n"+values_insert("governance_item",["governance_item_id","baseline_version_id","item_code","classification_value_id","title","description","source_location_text","created_by_principal_id","created_at"],item_rows))
    sections.append(values_insert("governance_action",["governance_action_id","governance_item_id","action_type_value_id","occurred_at","recorded_at","actor_principal_id","initiating_human_principal_id","supersedes_action_id","rationale"],action_rows))
    sections.append(values_insert("governance_evidence",["governance_evidence_id","governance_action_id","evidence_role_value_id","artifact_id","reference_value_id","validation_run_id","import_candidate_row_id","validation_finding_id","release_gate_evaluation_id","citation_text","created_at"],evidence_rows))

    gate_eval=uid("release-gate-evaluation:BL-001")
    lifecycle=uid("baseline-lifecycle-event:BL-001:ACTIVE")
    release_evidence_targets = [None, None, None, None, None, gate_eval]
    assert sum(value is not None for value in release_evidence_targets) == 1, (
        "release governance_evidence row must have exactly one target",
        release_evidence_targets,
    )
    sections.append(f"""
-- Stage 9: verify imported content before finalization or release evaluation.
do $bl001_verify$
declare n bigint;
begin
  if (select count(*) from s2t_fhir.import_candidate_row where import_run_id={q(irun['import_run_id'])}::uuid) <> 293 then raise exception 'candidate count mismatch'; end if;
  if (select count(*) from s2t_fhir.import_candidate_row c join s2t_fhir.reference_value d on d.reference_value_id=c.candidate_disposition_value_id where c.import_run_id={q(irun['import_run_id'])}::uuid and d.value_code='ACCEPTED') <> 292 then raise exception 'accepted count mismatch'; end if;
  if (select count(*) from s2t_fhir.import_candidate_row c join s2t_fhir.reference_value d on d.reference_value_id=c.candidate_disposition_value_id where c.import_run_id={q(irun['import_run_id'])}::uuid and d.value_code='QUARANTINED') <> 1 then raise exception 'quarantine count mismatch'; end if;
  if (select count(*) from s2t_fhir.validation_finding f join s2t_fhir.reference_value s on s.reference_value_id=f.severity_value_id where f.validation_run_id={q(vrun['validation_run_id'])}::uuid and s.value_code='WARNING') <> 5 then raise exception 'warning count mismatch'; end if;
  if (select count(*) from s2t_fhir.validation_finding f join s2t_fhir.reference_value s on s.reference_value_id=f.severity_value_id where f.validation_run_id={q(vrun['validation_run_id'])}::uuid and s.value_code='ERROR') <> 1 then raise exception 'error count mismatch'; end if;
  if (select count(*) from s2t_fhir.mapping_record where baseline_version_id={q(bversion['baseline_version_id'])}::uuid) <> 292 then raise exception 'mapping record count mismatch'; end if;
  if (select count(*) from s2t_fhir.element_mapping e join s2t_fhir.mapping_record m using(mapping_record_id) where m.baseline_version_id={q(bversion['baseline_version_id'])}::uuid) <> 237 then raise exception 'element subtype count mismatch'; end if;
  if (select count(*) from s2t_fhir.status_mapping_rule e join s2t_fhir.mapping_record m using(mapping_record_id) where m.baseline_version_id={q(bversion['baseline_version_id'])}::uuid) <> 9 then raise exception 'status subtype count mismatch'; end if;
  if (select count(*) from s2t_fhir.governance_guidance e join s2t_fhir.mapping_record m using(mapping_record_id) where m.baseline_version_id={q(bversion['baseline_version_id'])}::uuid) <> 46 then raise exception 'guidance subtype count mismatch'; end if;
  if exists (select 1 from s2t_fhir.mapping_record where import_candidate_row_id={q(candidate('S2T MedicationRequestCato',77)['import_candidate_row_id'])}::uuid) then raise exception 'quarantined row 77 has a mapping record'; end if;
  if (select count(*) from s2t_fhir.quarantine_case where import_candidate_row_id={q(candidate('S2T MedicationRequestCato',77)['import_candidate_row_id'])}::uuid) <> 1 then raise exception 'quarantined row 77 case mismatch'; end if;
  if (select count(*) from s2t_fhir.governance_action ga join s2t_fhir.governance_item gi using(governance_item_id) join s2t_fhir.reference_value t on t.reference_value_id=ga.action_type_value_id where gi.baseline_version_id={q(bversion['baseline_version_id'])}::uuid and t.value_code='APPROVED') <> {len(evidence_specs)} then raise exception 'governance approval count mismatch'; end if;
  if (select count(*) from s2t_fhir.governance_evidence ge join s2t_fhir.governance_action ga using(governance_action_id) join s2t_fhir.governance_item gi using(governance_item_id) where gi.baseline_version_id={q(bversion['baseline_version_id'])}::uuid) <> {len(evidence_rows)} then raise exception 'governance evidence count mismatch'; end if;
end
$bl001_verify$;

-- Finalize only after every deferred import invariant is forced and checked.
set constraints all immediate;
set constraints all deferred;

update s2t_fhir.import_run
set completed_at={q(irun['started_at'])}::timestamptz,
    terminal_status_value_id={ref({'domain_code':'IMPORT_RUN_STATUS','value_code':'COMMITTED','version_number':1})}
where import_run_id={q(irun['import_run_id'])}::uuid;

-- Stage 10: release gate. All four blocking requirements are persisted as PASSED.
insert into s2t_fhir.release_gate_evaluation
  (release_gate_evaluation_id, baseline_version_id, release_gate_definition_id, artifact_id, artifact_digest,
   validation_ruleset_id, validation_run_id, gate_outcome_value_id, evaluated_at, recorded_at,
   actor_principal_id, initiating_human_principal_id, supersedes_evaluation_id, governance_action_id, summary, created_at)
select {q(gate_eval)}::uuid, {q(bversion['baseline_version_id'])}::uuid, g.release_gate_definition_id,
       c.artifact_id, {hx(expected_digest)}, vr.validation_ruleset_id, {q(vrun['validation_run_id'])}::uuid,
       {ref({'domain_code':'RELEASE_GATE_OUTCOME','value_code':'PASSED','version_number':1})},
       {q(irun['started_at'])}::timestamptz, {q(irun['started_at'])}::timestamptz, c.principal_id, null, null,
       {q(policy_action)}::uuid,
       'BL-001 passed all four blocking requirements with 292 accepted and one preserved quarantine.',
       {q(irun['started_at'])}::timestamptz
from pg_temp.bl001_ctx c
cross join s2t_fhir.release_gate_definition g
cross join s2t_fhir.validation_ruleset vr
where g.gate_code='BASELINE_IMPORT' and g.version_label='v1'
  and vr.ruleset_code='BASELINE_IMPORT' and vr.version_label='v1';

insert into s2t_fhir.release_gate_result
  (release_gate_result_id, release_gate_evaluation_id, release_gate_requirement_id, requirement_outcome_value_id,
   governance_action_id, validation_finding_id, evidence_json, explanation, created_at)
select pg_catalog.gen_random_uuid(), {q(gate_eval)}::uuid, r.release_gate_requirement_id,
       {ref({'domain_code':'REQUIREMENT_OUTCOME','value_code':'PASSED','version_number':1})},
       case when r.requirement_code='GOVERNANCE_APPROVED' then {q(policy_action)}::uuid else null end,
       null,
       jsonb_build_object('requirement_code',r.requirement_code,'baseline_code','BL-001','artifact_sha256',{q(expected_digest)},
         'candidate_count',293,'accepted_count',292,'quarantined_count',1,'warning_count',5,'error_count',1),
       case r.requirement_code
         when 'AUTHORITATIVE_ARTIFACT_REGISTERED' then 'Exactly one authoritative workbook is linked and its digest matches.'
         when 'VALIDATION_COMPLETED' then 'BASELINE_IMPORT/v1 completed with the approved accepted-with-quarantine outcome.'
         when 'GOVERNANCE_APPROVED' then 'Twelve applicable approvals and their typed evidence are persisted.'
         when 'PROVENANCE_RECONCILED' then 'All 293 candidates retain workbook, sheet, row, range, raw-row, row-hash, and logical-key provenance.'
       end,
       {q(irun['started_at'])}::timestamptz
from s2t_fhir.release_gate_requirement r
join s2t_fhir.release_gate_definition g using(release_gate_definition_id)
where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';

insert into s2t_fhir.governance_evidence
  (governance_evidence_id, governance_action_id, evidence_role_value_id, release_gate_evaluation_id, citation_text, created_at)
values ({q(uid('governance-evidence:release-gate'))}::uuid, {q(policy_action)}::uuid,
        {ref({'domain_code':'EVIDENCE_ROLE','value_code':'RELEASE','version_number':1})},
        {q(gate_eval)}::uuid, 'BL-001 BASELINE_IMPORT/v1 release evaluation.', {q(irun['started_at'])}::timestamptz);

set constraints all immediate;

-- Stage 11: ACTIVE is appended only after the current release gate is verifiably PASSED.
do $bl001_release_check$
begin
  if not exists (
    select 1 from s2t_fhir.current_release_gate_evaluation e
    join s2t_fhir.reference_value o on o.reference_value_id=e.gate_outcome_value_id
    where e.baseline_version_id={q(bversion['baseline_version_id'])}::uuid and o.value_code='PASSED'
      and e.release_gate_evaluation_id={q(gate_eval)}::uuid
  ) then raise exception 'BL-001 current release gate is not PASSED; ACTIVE lifecycle event is prohibited'; end if;
  if (select count(*) from s2t_fhir.release_gate_result r join s2t_fhir.reference_value o on o.reference_value_id=r.requirement_outcome_value_id where r.release_gate_evaluation_id={q(gate_eval)}::uuid and o.value_code='PASSED') <> 4 then
    raise exception 'BL-001 release gate does not have four passed requirement results';
  end if;
end
$bl001_release_check$;

insert into s2t_fhir.baseline_lifecycle_event
  (baseline_lifecycle_event_id, baseline_version_id, lifecycle_status_value_id, occurred_at, recorded_at,
   actor_principal_id, initiating_human_principal_id, governance_action_id, reason, supersedes_event_id)
select {q(lifecycle)}::uuid, {q(bversion['baseline_version_id'])}::uuid,
       {ref({'domain_code':'BASELINE_LIFECYCLE_STATUS','value_code':'ACTIVE','version_number':1})},
       {q(irun['started_at'])}::timestamptz, {q(irun['started_at'])}::timestamptz, c.principal_id, null,
       {q(policy_action)}::uuid,
       'Activated after all BL-001 release-gate requirements passed; one unresolved quarantine remains visible.', null
from pg_temp.bl001_ctx c;

set constraints all immediate;

-- Final transaction-local assertions. Any failure aborts the complete package.
do $bl001_final$
begin
  if (select count(*) from s2t_fhir.import_run_metric where import_run_id={q(irun['import_run_id'])}::uuid) <> 62 then raise exception 'metric row count mismatch'; end if;
  if not exists (
    select 1 from s2t_fhir.current_baseline_lifecycle_event e
    join s2t_fhir.reference_value s on s.reference_value_id=e.lifecycle_status_value_id
    where e.baseline_version_id={q(bversion['baseline_version_id'])}::uuid and s.value_code='ACTIVE'
  ) then raise exception 'BL-001 lifecycle projection is not ACTIVE'; end if;
end
$bl001_final$;

commit;
""")
    return "\n\n".join(sections)


def build_runbook() -> str:
    return """# BL-001 Runtime Import Runbook

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
"""


def main():
    sql = build_sql()
    runbook = build_runbook()
    candidates = load("import_candidate_row")
    quarantined = [x for x in candidates if x["candidate_disposition_value_id"]["value_code"] == "QUARANTINED"]
    accepted = [x for x in candidates if x["candidate_disposition_value_id"]["value_code"] == "ACCEPTED"]
    assert len(candidates) == 293 and len(accepted) == 292 and len(quarantined) == 1
    assert quarantined[0]["source_sheet_name"] == "S2T MedicationRequestCato" and quarantined[0]["source_row_number"] == 77
    assert all(x.get("raw_source_row") and x.get("source_row_hash") and x.get("calculated_logical_key") and x.get("logical_key_components_json") for x in candidates)
    assert len(load("validation_finding")) == 6
    assert sum(x["severity_value_id"]["value_code"] == "WARNING" for x in load("validation_finding")) == 5
    assert sum(x["severity_value_id"]["value_code"] == "ERROR" for x in load("validation_finding")) == 1
    assert len(load("mapping_record")) == len(load("logical_mapping_identity")) == 292
    assert len(load("element_mapping")) == 237 and len(load("status_mapping_rule")) == 9 and len(load("governance_guidance")) == 46
    quarantined_id = quarantined[0]["import_candidate_row_id"]
    assert quarantined_id not in {x["import_candidate_row_id"] for x in load("mapping_record")}
    referenced = set(re.findall(r"from pg_temp\.bl001_ref where domain_code='([^']+)' and value_code='([^']+)' and version_number=1", sql))
    preamble = sql.split("create temp table bl001_ctx", 1)[0]
    seeded = set(re.findall(r"\('([^']+)','([^']+)'\)", preamble))
    assert len(seeded) == 52 and not (referenced - seeded), sorted(referenced - seeded)
    assert sql.lower().count("\nbegin;") == 1 and sql.lower().count("\ncommit;") == 1
    assert "set constraints all immediate;" in sql and "set constraints all deferred;" in sql
    OUT_SQL.write_text(sql, encoding="utf-8", newline="\n")
    OUT_RUNBOOK.write_text(runbook, encoding="utf-8", newline="\n")
    print("Generated BL001_RUNTIME_IMPORT.sql")
    print("Generated BL001_RUNTIME_IMPORT_RUNBOOK.md")


if __name__ == "__main__":
    main()

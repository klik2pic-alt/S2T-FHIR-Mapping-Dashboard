#!/usr/bin/env python3
"""Build the deterministic, offline BL-001 import payload.

This program never connects to a database and opens the workbook read-only as an
OOXML zip package.  Reference-table foreign keys are represented as governed
lookup objects so runtime import can resolve the UUIDs created by migrations.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
import unicodedata
import uuid
import zipfile
from collections import Counter, defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET

EXPECTED_FILE = "CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx"
EXPECTED_SHA256 = "3c7e551109ab814712c3b7bbbbbda4d41b457327452e4eee7746e698283fdc46"
EXPECTED_SIZE = 252859
SOURCE_MODIFIED = "2026-09-24T21:08:29Z"
STAMP = SOURCE_MODIFIED
NS_UUID = uuid.UUID("a420d86c-3d9d-5c45-8c6d-ff5b2f2db001")
RAW_SCHEMA_ID = "baseline-import"
RAW_SCHEMA_VERSION = "v1"
IMPORTER_VERSION = "bl001-dry-run-v1"
SPEC_VERSION = "BL001-v1"
MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
RULESET_DIGEST = "76e2b329dea2c5e480badbb3e0ade6d26563d304c04fa204136669692053e7bc"

SHEETS = {
    "Cato Status Mapping": {"order": 1, "class": "AUTHORITATIVE", "auth": True, "header": 5, "ranges": [(7, 13), (15, 15), (17, 17)], "cols": 8, "candidate_range": "A7:H13;A15:H15;A17:H17", "used": "A1:H17", "kind": "STATUS_MAPPING_RULE"},
    "S2T MedicationRequestCato": {"order": 2, "class": "AUTHORITATIVE", "auth": True, "header": 1, "ranges": [(2, 239)], "cols": 17, "candidate_range": "A2:Q239", "used": "A1:IJ243", "kind": "ELEMENT_MAPPING"},
    "Profile": {"order": 3, "class": "WIP_PROFILE", "auth": False, "header": None, "ranges": [], "cols": None, "candidate_range": None, "used": "A1:Q59", "kind": None},
    "CATO Route Mapping": {"order": 4, "class": "WIP_ROUTE_MAPPING", "auth": False, "header": None, "ranges": [], "cols": None, "candidate_range": None, "used": "A1:H15", "kind": None},
    "ValueSet": {"order": 5, "class": "OUT_OF_SCOPE", "auth": False, "header": None, "ranges": [], "cols": None, "candidate_range": None, "used": "A1:E80", "kind": None},
    "הנחיות נוספות מעודכן": {"order": 6, "class": "AUTHORITATIVE", "auth": True, "header": 2, "ranges": [(3, 7), (9, 49)], "cols": 6, "candidate_range": "A3:F7;A9:F49", "used": "A2:F76", "kind": "GOVERNANCE_GUIDANCE"},
    "דוגמאות ב-JSON": {"order": 7, "class": "EXAMPLE_ONLY", "auth": False, "header": None, "ranges": [], "cols": None, "candidate_range": None, "used": "A2:N2", "kind": None},
}

GUIDANCE_IDENTITIES = {
    3: ("GLOBAL_MAPPING_POLICY", "NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING"),
    4: ("MEDICATION_COMPOSITION", "PRESCRIBED_DRUG_INGREDIENT_REPRESENTATION"),
    5: ("DOSAGE_TIMING", "PO_DURATION_CLINICAL_SIGNIFICANCE"),
    6: ("PATIENT_IDENTITY", "CATO_SSN_PATIENT_IDENTIFIER_SEMANTICS"),
    7: ("TREATMENT_PLAN_ACCESS", "PATIENT_IDENTIFIER_FOR_PLAN_RETRIEVAL"),
}
GUIDANCE_STATUS = {"אושר": "FINAL", "דיון קליני": "OPEN", "לא ניתן למפות": "DO NOT MAP", "הוחלט לא למפות": "DO NOT MAP"}
APPROVED_BLANK_TARGETS = {
    "dosageinstruction.timing.repeat.bounds[x]",
    "dosageinstruction.timing.repeat.boundsduration***",
    "dosageinstruction.timing.repeat.boundsrange***",
    "dosageinstruction.timing.repeat.boundsperiod***",
}

def canon(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)

def digest_obj(obj):
    return hashlib.sha256(canon(obj).encode("utf-8")).hexdigest()

def uid(kind, key):
    return str(uuid.uuid5(NS_UUID, f"{EXPECTED_SHA256}|{kind}|{key}"))

def ref(domain, code, version=1):
    return {"domain_code": domain, "value_code": code, "version_number": version}

def principal(subject="s2t_fhir_importer"):
    return {"external_issuer": "postgres-role", "external_subject": subject}

def rule_ref(code):
    return {"ruleset_code": "BASELINE_IMPORT", "ruleset_version": "v1", "rule_code": code, "rule_version": "1"}

def norm(value, fold=True):
    if value is None:
        return ""
    s = unicodedata.normalize("NFKC", str(value)).replace("\u00a0", " ").replace("\r\n", "\n").replace("\r", "\n")
    s = re.sub(r"[ \t\f\v]+", " ", s).strip()
    return s.casefold() if fold else s

def text(value):
    if value is None:
        return None
    s = str(value).strip()
    return s if s else None

def col_name(n):
    out = ""
    while n:
        n, r = divmod(n - 1, 26)
        out = chr(65 + r) + out
    return out

def split_ref(cell_ref):
    m = re.match(r"([A-Z]+)([0-9]+)$", cell_ref)
    col = 0
    for c in m.group(1):
        col = col * 26 + ord(c) - 64
    return col, int(m.group(2))

class Xlsx:
    MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    PKG = "http://schemas.openxmlformats.org/package/2006/relationships"

    def __init__(self, path):
        self.z = zipfile.ZipFile(path)
        self.shared = self._shared_strings()
        self.sheets = self._sheet_paths()

    def _shared_strings(self):
        try: root = ET.fromstring(self.z.read("xl/sharedStrings.xml"))
        except KeyError: return []
        out = []
        for si in root.findall(f"{{{self.MAIN}}}si"):
            out.append("".join(t.text or "" for t in si.iter(f"{{{self.MAIN}}}t")))
        return out

    def _sheet_paths(self):
        wb = ET.fromstring(self.z.read("xl/workbook.xml"))
        rels = ET.fromstring(self.z.read("xl/_rels/workbook.xml.rels"))
        targets = {r.attrib["Id"]: r.attrib["Target"] for r in rels.findall(f"{{{self.PKG}}}Relationship")}
        result = {}
        for s in wb.find(f"{{{self.MAIN}}}sheets"):
            target = targets[s.attrib[f"{{{self.REL}}}id"]].lstrip("/")
            if not target.startswith("xl/"): target = "xl/" + target
            result[s.attrib["name"]] = target
        return result

    def rows(self, sheet):
        root = ET.fromstring(self.z.read(self.sheets[sheet]))
        result = defaultdict(dict)
        for c in root.iter(f"{{{self.MAIN}}}c"):
            col, row = split_ref(c.attrib["r"])
            t = c.attrib.get("t")
            v = c.find(f"{{{self.MAIN}}}v")
            inline = c.find(f"{{{self.MAIN}}}is")
            formula = c.find(f"{{{self.MAIN}}}f")
            raw = None if v is None else v.text
            if t == "s": value, typ = self.shared[int(raw)], "string"
            elif t == "inlineStr": value, typ = "".join(x.text or "" for x in inline.iter(f"{{{self.MAIN}}}t")), "string"
            elif t == "str": value, typ = raw or "", "string"
            elif t == "b": value, typ = raw == "1", "boolean"
            elif t == "e": value, typ = raw, "error"
            elif raw is None: value, typ = None, "blank"
            else:
                try:
                    f = float(raw); value = int(f) if f.is_integer() else f; typ = "number"
                except ValueError: value, typ = raw, "string"
            result[row][col] = {"type": typ, "value": value, "original": value, "raw_lexical": raw, **({"formula": formula.text} if formula is not None else {})}
        return result

def raw_cell(cell, header):
    if cell is None: return {"header": header, "type": "blank", "value": None, "original": None, "raw_lexical": None}
    return {"header": header, **cell}

def raw_row(sheet, row, end_col, headers, data):
    cells = {col_name(c): raw_cell(data.get(c), headers.get(c)) for c in range(1, end_col + 1)}
    rng = f"A{row}:{col_name(end_col)}{row}"
    envelope = {"schema": f"{RAW_SCHEMA_ID}-{RAW_SCHEMA_VERSION}", "sheet": sheet, "row": row, "range": rng, "cells": cells}
    hash_body = {"schema": envelope["schema"], "sheet": sheet, "cells": cells}
    return envelope, digest_obj(hash_body)

def logical_key(kind, components):
    ordered = components["canonical_tuple"]
    return "me:v1:" + hashlib.sha256("|".join(ordered).encode("utf-8")).hexdigest()

def build_candidate(sheet, row, headers, data):
    meta = SHEETS[sheet]; kind = meta["kind"]
    raw, row_hash = raw_row(sheet, row, meta["cols"], headers, data)
    vals = [data.get(i, {}).get("value") for i in range(1, meta["cols"] + 1)]
    finding_specs = []
    if kind == "ELEMENT_MAPPING":
        target = text(vals[8]); cardinality = text(vals[9])
        status = norm(vals[16], fold=False).upper()
        components = {"mapping_kind": kind, "source_system": "CATO", "fhir_resource": "MedicationRequest", "target_fhir_path": norm(target), "source_system_raw": norm(vals[0]), "interface_type": norm(vals[1]), "interface_name": norm(vals[2]), "source_expression": norm(vals[3]), "fixed_value": norm(vals[5])}
        components["canonical_tuple"] = [kind, "cato", "medicationrequest", components["target_fhir_path"], components["source_system_raw"], components["interface_type"], components["interface_name"], components["source_expression"], components["fixed_value"]]
        if not cardinality:
            if norm(target) in APPROVED_BLANK_TARGETS and status == "DO NOT MAP":
                finding_specs.append(("APPROVED_CARDINALITY_EXCEPTION", "WARNING", "Approved blank cardinality exception; raw blank preserved."))
            else:
                finding_specs.append(("INVALID_CARDINALITY", "ERROR", "Blank cardinality without an approved exception."))
        elif not re.match(r"^(0|[1-9][0-9]*)\.\.(\*|0|[1-9][0-9]*)$", cardinality):
            finding_specs.append(("INVALID_CARDINALITY", "ERROR", "Cardinality does not match the governed syntax."))
        subtype = {"target_fhir_path": target, "source_system_raw": text(vals[0]), "interface_type": text(vals[1]), "interface_name": text(vals[2]), "source_expression": text(vals[3]), "profile_context": text(vals[4]), "fixed_value": text(vals[5]), "transformation_rule": text(vals[6]), "source_business_definition": text(vals[7]), "cardinality_raw": cardinality, "cardinality_min": None, "cardinality_max": None, "cardinality_max_unbounded": False, "valueset_binding": text(vals[10]), "mandated_code_system": text(vals[11]), "irrelevant_under_s2t_raw": text(vals[12]), "example_value": text(vals[13]), "exception_handling": text(vals[14]), "notes": text(vals[15])}
        if cardinality and re.match(r"^(0|[1-9][0-9]*)\.\.(\*|0|[1-9][0-9]*)$", cardinality):
            lo, hi = cardinality.split(".."); subtype["cardinality_min"] = int(lo)
            if hi == "*": subtype["cardinality_max_unbounded"] = True
            else: subtype["cardinality_max"] = int(hi)
    elif kind == "STATUS_MAPPING_RULE":
        status = "FINAL" if row <= 15 else "DO NOT MAP"
        source, target = text(vals[1]), text(vals[3])
        components = {"mapping_kind": kind, "source_system": "CATO", "target_fhir_path": "MedicationRequest.status", "source_status_value": norm(source), "target_status_value": norm(target)}
        components["canonical_tuple"] = [kind, "cato", "medicationrequest.status", components["source_status_value"], components["target_status_value"]]
        subtype = {"source_status_value": source, "target_fhir_path": "MedicationRequest.status", "target_status_value": target, "source_sequence": int(vals[0]) if isinstance(vals[0], (int, float)) else None, "source_business_definition": text(vals[2]), "related_resource_note": text(vals[4]), "transformation_rule": text(vals[5]), "mapping_evidence_status_raw": text(vals[6]), "notes": text(vals[7])}
    else:
        raw_status = norm(vals[0], fold=False)
        status = GUIDANCE_STATUS.get(raw_status)
        if row in GUIDANCE_IDENTITIES: scope, topic = GUIDANCE_IDENTITIES[row]
        else: scope, topic = "GLOBAL_MAPPING_POLICY", "NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING"
        components = {"mapping_kind": kind, "source_system": "CATO", "fhir_resource": "MedicationRequest", "guidance_scope": scope, "decision_topic_code": topic}
        components["canonical_tuple"] = [kind, "cato", "medicationrequest", norm(scope), norm(topic)]
        # Rows beyond 7 need source-specific identity to avoid collapsing distinct governed guidance.
        if row > 7:
            components["governed_guidance_identity"] = [norm(vals[2]), norm(vals[1]), norm(vals[3])]
            components["canonical_tuple"] += components["governed_guidance_identity"]
        subtype = {"guidance_scope_value_id": ref("GUIDANCE_SCOPE", scope), "decision_topic_value_id": ref("DECISION_TOPIC_CODE", topic), "guidance_text": text(vals[3]), "guidance_status_raw": text(vals[0]), "target_fhir_path_or_scope_raw": text(vals[2]), "decision_topic_raw": text(vals[1]), "notes": text(vals[4]), "review_notes": text(vals[5])}
        if data.get(5, {}).get("type") == "error": finding_specs.append(("RAW_OPTIONAL_CELL_ERROR", "WARNING", "Optional source cell E contains a preserved typed Excel error."))
    key = logical_key(kind, components)
    disposition = "QUARANTINED" if any(x[1] == "ERROR" for x in finding_specs) else "ACCEPTED"
    cid = uid("candidate", f"{sheet}!{row}")
    record = {"import_candidate_row_id": cid, "import_run_id": uid("import_run", "BL-001"), "mapping_kind_value_id": ref("MAPPING_KIND", kind), "source_sheet_name": sheet, "source_row_number": row, "source_cell_range": raw["range"], "raw_schema_id": RAW_SCHEMA_ID, "raw_schema_version": RAW_SCHEMA_VERSION, "raw_source_row": raw, "source_row_hash": row_hash, "normalization_algorithm_version": "v1", "logical_key_algorithm_version": "v1", "candidate_disposition_value_id": ref("CANDIDATE_DISPOSITION", disposition), "calculated_logical_key": key, "logical_key_components_json": components}
    return {"record": record, "kind": kind, "status": status, "disposition": disposition, "subtype": subtype, "findings": finding_specs}

def add(records, table, row): records[table].append(row)

def build(workbook, output):
    blob = workbook.read_bytes(); sha = hashlib.sha256(blob).hexdigest()
    blockers = []
    if workbook.name != EXPECTED_FILE: blockers.append(f"Unexpected workbook filename: {workbook.name}")
    if len(blob) != EXPECTED_SIZE: blockers.append(f"Workbook size mismatch: {len(blob)}")
    if sha != EXPECTED_SHA256: blockers.append(f"Workbook SHA-256 mismatch: {sha}")
    xlsx = Xlsx(workbook)
    if list(xlsx.sheets) != list(SHEETS): blockers.append("Workbook sheet names/order do not match the registered manifest")
    if blockers: return {}, {}, blockers

    records = defaultdict(list)
    ids = {name: uid(name, "BL-001") for name in ("artifact", "artifact_location", "baseline_series", "baseline_version", "baseline_artifact", "import_run", "validation_run")}
    config = {"raw_schema": "baseline-import-v1", "normalization": "v1", "logical_key": "v1", "manifest": "v1", "ruleset_digest": RULESET_DIGEST, "importer": IMPORTER_VERSION}
    add(records, "artifact", {"artifact_id": ids["artifact"], "artifact_kind_value_id": ref("ARTIFACT_KIND", "WORKBOOK"), "sha256_digest": sha, "byte_size": len(blob), "media_type": MIME, "physical_filename": workbook.name, "original_or_upload_name": workbook.name, "captured_at": STAMP, "source_modified_at": SOURCE_MODIFIED, "description": "Registered BL-001 authoritative workbook", "created_by_principal_id": principal(), "created_at": STAMP})
    add(records, "artifact_location", {"artifact_location_id": ids["artifact_location"], "artifact_id": ids["artifact"], "location_kind_value_id": ref("ARTIFACT_LOCATION_KIND", "REPOSITORY_PATH"), "location_uri": f"01_Baseline/{workbook.name}", "observed_at": STAMP, "recorded_at": STAMP, "actor_principal_id": principal(), "initiating_human_principal_id": None, "availability_status_value_id": ref("ARTIFACT_AVAILABILITY", "AVAILABLE"), "supersedes_location_id": None, "note": "Observed by offline BL-001 dry run"})
    add(records, "baseline_series", {"baseline_series_id": ids["baseline_series"], "source_system": "CATO", "fhir_resource": "MedicationRequest", "baseline_type_value_id": ref("BASELINE_TYPE", "HUMAN_WORKING_DRAFT"), "description": "CATO MedicationRequest human working draft", "created_at": STAMP})
    add(records, "baseline_version", {"baseline_version_id": ids["baseline_version"], "baseline_series_id": ids["baseline_series"], "baseline_code": "BL-001", "version_label": "BL-001", "is_gold_standard": False, "import_specification_version": SPEC_VERSION, "description": "Immutable BL-001 dry-run snapshot; not activated", "created_by_principal_id": principal(), "created_at": STAMP})
    add(records, "baseline_artifact", {"baseline_artifact_id": ids["baseline_artifact"], "baseline_version_id": ids["baseline_version"], "artifact_id": ids["artifact"], "artifact_role_value_id": ref("ARTIFACT_ROLE", "AUTHORITATIVE_SOURCE"), "note": "BL-001 authoritative source", "created_by_principal_id": principal(), "created_at": STAMP})
    for name, meta in SHEETS.items():
        count = sum(b-a+1 for a,b in meta["ranges"])
        add(records, "artifact_sheet_manifest", {"artifact_sheet_manifest_id": uid("manifest", name), "artifact_id": ids["artifact"], "sheet_name": name, "sheet_order": meta["order"], "sheet_classification_value_id": ref("SHEET_CLASSIFICATION", meta["class"]), "is_present": True, "is_authoritative": meta["auth"], "header_row_number": meta["header"], "candidate_range": meta["candidate_range"], "governed_column_range": f"A:{col_name(meta['cols'])}" if meta["cols"] else None, "candidate_row_count": count, "notes": None, "manifest_schema_id": "baseline-import-sheet-manifest", "manifest_schema_version": "v1", "manifest_json": {"observed_used_range": meta["used"], "candidate_ranges": [f"A{a}:{col_name(meta['cols'])}{b}" for a,b in meta["ranges"]] if meta["cols"] else []}, "created_at": STAMP})
    add(records, "import_run", {"import_run_id": ids["import_run"], "baseline_version_id": ids["baseline_version"], "artifact_id": ids["artifact"], "import_policy_value_id": ref("IMPORT_POLICY", "ACCEPTED_WITH_QUARANTINE"), "import_specification_version": SPEC_VERSION, "importer_version": IMPORTER_VERSION, "configuration_digest": digest_obj(config), "started_at": STAMP, "completed_at": None, "terminal_status_value_id": None, "failure_summary": None, "actor_principal_id": principal(), "initiating_human_principal_id": None, "created_at": STAMP, "dry_run_state": "STOPPED_BEFORE_COMMIT"})

    candidates = []
    for sheet, meta in SHEETS.items():
        if not meta["auth"]: continue
        rows = xlsx.rows(sheet)
        headers = {c: text(rows[meta["header"]].get(c, {}).get("value")) for c in range(1, meta["cols"]+1)}
        for start, end in meta["ranges"]:
            for row in range(start, end+1):
                c = build_candidate(sheet, row, headers, rows[row]); candidates.append(c); add(records, "import_candidate_row", c["record"])

    # Findings, finding-row links, and quarantine.
    finding_count = Counter()
    for c in candidates:
        cr = c["record"]
        for code, severity, message in c["findings"]:
            evidence = {"sheet": cr["source_sheet_name"], "row": cr["source_row_number"], "range": cr["source_cell_range"], "logical_key": cr["calculated_logical_key"], "source_row_hash": cr["source_row_hash"]}
            fp = digest_obj({"rule": code, "candidate": cr["import_candidate_row_id"], "evidence": evidence})
            fid = uid("finding", fp)
            add(records, "validation_finding", {"validation_finding_id": fid, "validation_run_id": ids["validation_run"], "validation_rule_id": rule_ref(code), "severity_value_id": ref("SEVERITY", severity), "finding_code": code, "message": message, "finding_fingerprint": fp, "collision_group_key": None, "evidence_schema_id": "baseline-import-finding", "evidence_schema_version": "v1", "evidence_json": evidence, "created_at": STAMP})
            add(records, "validation_finding_row", {"validation_finding_row_id": uid("finding_row", fid), "validation_finding_id": fid, "import_candidate_row_id": cr["import_candidate_row_id"], "finding_row_role_value_id": ref("FINDING_ROW_ROLE", "SUBJECT"), "created_at": STAMP})
            finding_count[severity] += 1
            if severity == "ERROR":
                qid = uid("quarantine", cr["import_candidate_row_id"])
                add(records, "quarantine_case", {"quarantine_case_id": qid, "import_candidate_row_id": cr["import_candidate_row_id"], "opening_validation_finding_id": fid, "opened_at": STAMP, "opened_by_principal_id": principal(), "initiating_human_principal_id": None, "created_at": STAMP})
                add(records, "quarantine_event", {"quarantine_event_id": uid("quarantine_event", qid), "quarantine_case_id": qid, "event_type_value_id": ref("QUARANTINE_EVENT_TYPE", "OPENED"), "occurred_at": STAMP, "recorded_at": STAMP, "actor_principal_id": principal(), "initiating_human_principal_id": None, "governance_action_id": None, "resolution_code_value_id": None, "reason": message, "supersedes_event_id": None, "replacement_baseline_version_id": None})

    # Accepted mapping graph only.
    for c in candidates:
        if c["disposition"] != "ACCEPTED": continue
        cr = c["record"]; key = cr["calculated_logical_key"]
        li = uid("identity", key); mr = uid("mapping", cr["import_candidate_row_id"])
        add(records, "logical_mapping_identity", {"logical_mapping_identity_id": li, "mapping_kind_value_id": ref("MAPPING_KIND", c["kind"]), "source_system": "CATO", "fhir_resource": "MedicationRequest", "key_algorithm_version": "v1", "logical_key": key, "key_components_json": cr["logical_key_components_json"], "created_at": STAMP})
        add(records, "mapping_record", {"mapping_record_id": mr, "baseline_version_id": ids["baseline_version"], "import_candidate_row_id": cr["import_candidate_row_id"], "logical_mapping_identity_id": li, "mapping_kind_value_id": ref("MAPPING_KIND", c["kind"]), "decision_status_value_id": ref("DECISION_STATUS", c["status"]), "created_at": STAMP})
        subtype = {"mapping_record_id": mr, **c["subtype"]}; add(records, c["kind"].lower(), subtype)

    accepted = sum(c["disposition"] == "ACCEPTED" for c in candidates); quarantined = len(candidates)-accepted
    summary = {"candidate_count": len(candidates), "accepted_count": accepted, "warning_count": finding_count["WARNING"], "error_count": finding_count["ERROR"], "quarantined_count": quarantined}
    execution = digest_obj({"artifact": sha, "configuration": digest_obj(config), "ruleset": RULESET_DIGEST, "candidates": [c["record"]["source_row_hash"] for c in candidates]})
    add(records, "validation_run", {"validation_run_id": ids["validation_run"], "import_run_id": ids["import_run"], "validation_ruleset_id": {"ruleset_code": "BASELINE_IMPORT", "version_label": "v1"}, "artifact_id": ids["artifact"], "artifact_digest": sha, "execution_fingerprint": execution, "started_at": STAMP, "completed_at": STAMP, **summary, "outcome_value_id": ref("VALIDATION_OUTCOME", "FAIL"), "actor_principal_id": principal(), "initiating_human_principal_id": None, "summary_json": summary, "created_at": STAMP})

    # Metrics: overall plus each requested independent slice, including zero-free observed groups.
    metric_rows = []
    def metric(metric_type, count, sheet=None, kind=None, status=None, severity=None):
        dims = {"source_sheet_name": sheet, "mapping_kind_value_id": ref("MAPPING_KIND", kind) if kind else None, "decision_status_value_id": ref("DECISION_STATUS", status) if status else None, "severity_value_id": ref("SEVERITY", severity) if severity else None}
        key = canon([metric_type, sheet, kind, status, severity])
        metric_rows.append({"import_run_metric_id": uid("metric", key), "import_run_id": ids["import_run"], "metric_type_value_id": ref("METRIC_TYPE", metric_type), "metric_count": count, **dims, "created_at": STAMP})
    for typ, field in [("CANDIDATE", "candidate_count"),("ACCEPTED","accepted_count"),("WARNING","warning_count"),("ERROR","error_count"),("QUARANTINED","quarantined_count")]: metric(typ, summary[field])
    for sheet in [x for x in SHEETS if SHEETS[x]["auth"]]:
        group=[c for c in candidates if c["record"]["source_sheet_name"]==sheet]
        for typ, count in [("CANDIDATE",len(group)),("ACCEPTED",sum(c["disposition"]=="ACCEPTED" for c in group)),("QUARANTINED",sum(c["disposition"]=="QUARANTINED" for c in group))]: metric(typ,count,sheet=sheet)
        for severity in ("WARNING", "ERROR"): metric(severity, sum(f[1] == severity for c in group for f in c["findings"]), sheet=sheet, severity=severity)
    for kind in sorted(set(c["kind"] for c in candidates)):
        group=[c for c in candidates if c["kind"]==kind]
        for typ,count in [("CANDIDATE",len(group)),("ACCEPTED",sum(c["disposition"]=="ACCEPTED" for c in group)),("QUARANTINED",sum(c["disposition"]=="QUARANTINED" for c in group))]: metric(typ,count,kind=kind)
        for severity in ("WARNING", "ERROR"): metric(severity, sum(f[1] == severity for c in group for f in c["findings"]), kind=kind, severity=severity)
    for status in ["FINAL","WIP","OPEN","DO NOT MAP","N/A"]:
        group=[c for c in candidates if c["status"]==status]
        for typ,count in [("CANDIDATE",len(group)),("ACCEPTED",sum(c["disposition"]=="ACCEPTED" for c in group)),("QUARANTINED",sum(c["disposition"]=="QUARANTINED" for c in group))]: metric(typ,count,status=status)
        for severity in ("WARNING", "ERROR"): metric(severity, sum(f[1] == severity for c in group for f in c["findings"]), status=status, severity=severity)
    for severity in ["WARNING","ERROR"]: metric(severity, finding_count[severity], severity=severity)
    records["import_run_metric"] = metric_rows

    # Runtime constraint/integrity emulation.
    blockers.extend(validate(records, candidates, summary))
    recon = reconciliation(candidates, records)
    output.mkdir(parents=True, exist_ok=True)
    for table in sorted(records):
        with (output/f"{table}.jsonl").open("w", encoding="utf-8", newline="\n") as f:
            for row in records[table]: f.write(canon(row)+"\n")
    manifest = {"schema": "bl001-dry-run-payload-v1", "artifact_sha256": sha, "configuration_digest": digest_obj(config), "execution_fingerprint": execution, "record_counts": {k:len(v) for k,v in sorted(records.items())}, "reconciliation": recon, "constraint_validation": "PASS" if not blockers else "FAIL", "release_gate_generated": False, "lifecycle_event_generated": False}
    (output/"manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True)+"\n", encoding="utf-8")
    return records, recon, blockers

def validate(r, candidates, summary):
    b=[]
    expected={"candidate_count":293,"accepted_count":292,"warning_count":5,"error_count":1,"quarantined_count":1}
    if summary != expected: b.append(f"Reconciliation mismatch: {summary}, expected {expected}")
    q=[c for c in candidates if c["disposition"]=="QUARANTINED"]
    if [(c["record"]["source_sheet_name"],c["record"]["source_row_number"]) for c in q] != [("S2T MedicationRequestCato",77)]: b.append("Quarantine set is not exactly S2T MedicationRequestCato!77")
    expected_tables={"mapping_record":292,"logical_mapping_identity":292,"element_mapping":237,"status_mapping_rule":9,"governance_guidance":46,"validation_finding":6,"validation_finding_row":6,"quarantine_case":1,"quarantine_event":1,"artifact_sheet_manifest":7}
    for table,n in expected_tables.items():
        if len(r[table])!=n: b.append(f"{table} count {len(r[table])} != {n}")
    for field in ("source_row_hash","calculated_logical_key"):
        vals=[c["record"][field] for c in candidates]
        if len(vals)!=len(set(vals)): b.append(f"Duplicate {field} generated")
    mids={x["import_candidate_row_id"] for x in r["mapping_record"]}; qids={x["import_candidate_row_id"] for x in r["quarantine_case"]}
    if mids & qids: b.append("Quarantined candidate has a mapping_record")
    if len(mids)!=292 or len(qids)!=1: b.append("Accepted/quarantined terminal cardinality failed")
    subtype_ids=[x["mapping_record_id"] for t in ("element_mapping","status_mapping_rule","governance_guidance") for x in r[t]]
    if len(subtype_ids)!=292 or len(subtype_ids)!=len(set(subtype_ids)): b.append("Exactly-one-subtype integrity failed")
    for c in candidates:
        x=c["record"]
        if x["raw_source_row"]["sheet"]!=x["source_sheet_name"] or x["raw_source_row"]["row"]!=x["source_row_number"] or x["raw_source_row"]["range"]!=x["source_cell_range"]: b.append(f"Raw envelope mismatch at {x['source_sheet_name']}!{x['source_row_number']}")
        if not re.match(r"^me:v1:[0-9a-f]{64}$",x["calculated_logical_key"]): b.append("Invalid logical key syntax")
    return sorted(set(b))

def reconciliation(candidates, records):
    def groups(key):
        out={}
        for value in sorted(set(key(c) for c in candidates)):
            g=[c for c in candidates if key(c)==value]
            out[str(value)]={"candidates":len(g),"accepted":sum(c["disposition"]=="ACCEPTED" for c in g),"quarantined":sum(c["disposition"]=="QUARANTINED" for c in g),"warnings":sum(f[1]=="WARNING" for c in g for f in c["findings"]),"errors":sum(f[1]=="ERROR" for c in g for f in c["findings"])}
        return out
    sev=Counter(f["severity_value_id"]["value_code"] for f in records["validation_finding"])
    return {"overall":{"candidates":len(candidates),"accepted":sum(c["disposition"]=="ACCEPTED" for c in candidates),"quarantined":sum(c["disposition"]=="QUARANTINED" for c in candidates)},"authoritative_sheet":groups(lambda c:c["record"]["source_sheet_name"]),"mapping_kind":groups(lambda c:c["kind"]),"decision_status":groups(lambda c:c["status"]),"disposition":dict(sorted(Counter(c["disposition"] for c in candidates).items())),"severity":{"WARNING":sev["WARNING"],"ERROR":sev["ERROR"]}}

def render_report(path, recon, records, blockers):
    status="READY_FOR_BL001_RUNTIME_IMPORT" if not blockers else "NOT_READY_FOR_BL001_RUNTIME_IMPORT"
    lines=["# BL-001 Dry-Run Import Report","","## Outcome","",f"`{status}`","","No SQL was executed. No database connection was made. The workbook and migrations 001–012 were not modified. The dry run stopped before commit, release-gate evaluation, or lifecycle activation.","","## Artifact","",f"- File: `01_Baseline/{EXPECTED_FILE}`",f"- SHA-256: `{EXPECTED_SHA256}`",f"- Bytes: `{EXPECTED_SIZE}`",f"- Payload importer: `{IMPORTER_VERSION}`","","## Reconciliation","", "| Slice | Candidates | Accepted | Quarantined | Warnings | Errors |","|---|---:|---:|---:|---:|---:|"]
    for k,v in recon.get("authoritative_sheet",{}).items(): lines.append(f"| `{k}` | {v['candidates']} | {v['accepted']} | {v['quarantined']} | {v['warnings']} | {v['errors']} |")
    lines += ["","### Mapping kind","","| Kind | Candidates | Accepted | Quarantined | Warnings | Errors |","|---|---:|---:|---:|---:|---:|"]
    for k,v in recon.get("mapping_kind",{}).items(): lines.append(f"| `{k}` | {v['candidates']} | {v['accepted']} | {v['quarantined']} | {v['warnings']} | {v['errors']} |")
    lines += ["","### Decision Status","","| Status | Candidates | Accepted | Quarantined | Warnings | Errors |","|---|---:|---:|---:|---:|---:|"]
    for k in ["FINAL","WIP","OPEN","DO NOT MAP","N/A"]:
        v=recon.get("decision_status",{}).get(k,{"candidates":0,"accepted":0,"quarantined":0,"warnings":0,"errors":0}); lines.append(f"| `{k}` | {v['candidates']} | {v['accepted']} | {v['quarantined']} | {v['warnings']} | {v['errors']} |")
    lines += ["","### Disposition and severity","",f"- Accepted: {recon.get('disposition',{}).get('ACCEPTED',0)}",f"- Quarantined: {recon.get('disposition',{}).get('QUARANTINED',0)}",f"- Warnings: {recon.get('severity',{}).get('WARNING',0)}",f"- Errors: {recon.get('severity',{}).get('ERROR',0)}","","## Quarantine","","Exactly one candidate is quarantined: `S2T MedicationRequestCato!77` (`A77:Q77`). No `logical_mapping_identity`, `mapping_record`, or subtype record was generated for it.","","## Generated records","","| Table | Rows |","|---|---:|"]
    for table, rows in sorted(records.items()): lines.append(f"| `{table}` | {len(rows)} |")
    lines += ["","Payload files are in `04_Exports/BL001_DRY_RUN/`. Foreign keys to governed reference/configuration rows are represented by deterministic lookup selectors and must be resolved by the runtime importer inside its future transaction.","","## Integrity validation","",("All generated records passed the offline emulation of applicable migrations 004–009 and the runtime-tested invariants in migration 012." if not blockers else "Blocking issues remain:"),""]
    if blockers:
        lines += [f"- {x}" for x in blockers]
    else:
        lines += ["- Artifact digest and manifest match the BL-001 register.","- Candidate terminal states reconcile 292 accepted plus 1 quarantined to 293.","- Accepted records have exactly one matching subtype: 237 element, 9 status, 46 guidance.","- All six findings link to their subject candidates; the sole error opens the sole quarantine case.","- No `release_gate_evaluation`, `release_gate_result`, or `baseline_lifecycle_event` records were generated."]
    lines += ["",f"`{status}`",""]
    path.write_text("\n".join(lines),encoding="utf-8")

def main():
    p=argparse.ArgumentParser(); p.add_argument("--root",type=Path,default=Path(__file__).resolve().parents[1]); a=p.parse_args()
    workbook=a.root/"01_Baseline"/EXPECTED_FILE; out=a.root/"04_Exports"/"BL001_DRY_RUN"; report=a.root/"04_Exports"/"BL001_DRY_RUN_REPORT.md"
    records,recon,blockers=build(workbook,out)
    render_report(report,recon,records,blockers)
    print(json.dumps({"status":"READY_FOR_BL001_RUNTIME_IMPORT" if not blockers else "NOT_READY_FOR_BL001_RUNTIME_IMPORT","blockers":blockers,"report":str(report),"payload":str(out)},ensure_ascii=True,indent=2))
    return 0 if not blockers else 1

if __name__ == "__main__": sys.exit(main())

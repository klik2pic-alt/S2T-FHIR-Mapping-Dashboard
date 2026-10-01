# DDL Architecture Decisions v1

## Status and scope

- Status: `APPROVED_FOR_DDL_DESIGN`
- Baseline context: `BL-002` / `V2`
- Source system: `CATO`
- FHIR resource: `MedicationRequest`
- Authoritative workbook SHA-256: `adaaf27a6165a294f9dd5a710b17a362e757f47e9b3bf08b098577b989bc6239`
- Effective date: 2026-09-23

This record fixes the implementation-neutral architecture inputs for MVP DDL design. It does not authorize import execution and does not create or approve DDL, migrations, a database vendor, or an object-storage vendor.

## Approved decisions

| ID | Approved architecture decision | DDL consequence |
|---|---|---|
| `DDL-AD-01` | Use structured relational database storage for metadata, mappings, provenance, validation, governance, quarantine, and release-gate data. | These domains use normalized relational tables with enforced keys and critical invariants. |
| `DDL-AD-02` | Store authoritative workbook binaries in immutable object/file storage; keep content identity and retrieval metadata in the database. | Artifact rows are content-addressed by digest. Database locations are references, not the authoritative binary payload. |
| `DDL-AD-03` | Baseline version labels are unique within a baseline series defined by `source_system + fhir_resource + baseline_type`. | `baseline_series` owns that tuple; `baseline_version` is unique by series plus version label. |
| `DDL-AD-04` | Use governed reference tables for controlled values rather than database enums. | Controlled fields reference governed domain/value rows. Database enums are not used for governed business values. |
| `DDL-AD-05` | Governance guidance vocabularies (`guidance_scope`, `decision_topic_code`) are versioned governed metadata. | Guidance records reference exact versions of governed terms; raw workbook fields remain separate evidence. |
| `DDL-AD-06` | Artifact locations are append-only historical records. | Relocation or loss of availability adds a new location event/record and never rewrites prior location history. |
| `DDL-AD-07` | Current release-gate state is the latest non-superseded evaluation that still matches the current artifact digest and validation ruleset. | Gate evaluations store both artifact and ruleset identities and may supersede prior evaluations without deleting them. Current state is a derived projection. |
| `DDL-AD-08` | Use baseline-level authorization for MVP; finer-grained row/artifact authorization may be added later. | Ordinary application/API access must be baseline-scoped. The database role `s2t_fhir_governance_reader` is a separately privileged all-baselines governance/audit role and must not be granted to ordinary application identities. The API schema remains private and empty until reviewed baseline-filtered access is implemented. Row/artifact policy tables are deferred. |
| `DDL-AD-09` | Machine actions record the service principal and, when available, the initiating human principal. | Action/event tables provide required actor and nullable initiating-human foreign keys. |
| `DDL-AD-10` | JSON validation is importer-enforced with stored schema/version and integrity tests; database constraints enforce only critical structural invariants. | Raw and evidence JSON carry schema/version fields. DDL checks JSON shape/type and required envelope invariants, not the complete external JSON Schema. |
| `DDL-AD-11` | Governance documents are stored or referenced through immutable snapshots/digests, not only mutable repository paths. | The general artifact model supports immutable governance-document snapshots and their historical locations. |
| `DDL-AD-12` | `V2-BA-07` remains mandatory before import execution but is not a DDL blocker. | The schema supports separate original/upload names, physical names, digests, and append-only locations. Values must be reconciled before the first import is executed. |

## Authority boundary

These decisions supplement, and do not reopen, the approved V2 governance decisions in `03_Decisions/BASELINE_APPROVAL_CHECKLIST_V2.md`. Human governance owners retain authority over business meaning and release decisions. Technical owners may now translate this record and the MVP schema specification into proposed DDL, but must not execute an import until `V2-BA-07` is complete.

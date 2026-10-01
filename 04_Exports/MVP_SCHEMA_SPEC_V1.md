# MVP Schema Specification v1

## 1. Status and conventions

- Status: `APPROVED_INPUT_FOR_DDL_GENERATION`
- Scope: exact MVP persistence model only; no SQL or migration is included.
- Architecture authority: `03_Decisions/DDL_ARCHITECTURE_DECISIONS_V1.md`.
- Baseline authority: `BL-002` / `V2`, authoritative digest `adaaf27a6165a294f9dd5a710b17a362e757f47e9b3bf08b098577b989bc6239`.

Conventions used below:

- All `*_id` primary keys are system-generated UUIDs.
- All timestamps are timezone-aware UTC instants.
- `created_at` is required and immutable unless explicitly stated otherwise. Event tables use immutable `recorded_at` as their authoritative insertion timestamp, and mapping subtype tables inherit creation provenance from their parent `mapping_record`; those tables do not duplicate `created_at`.
- SHA-256 values are stored in a fixed 32-byte representation; hexadecimal rendering is an API/export concern.
- Controlled business values are foreign keys to `reference_value`, never database enums.
- “Append-only” means application roles may insert but not update/delete. Supersession and correction use new rows.
- “Write-once” means a nullable processing field may be set once during finalization but never changed afterward.
- Every JSON document has a required schema identifier and schema version. Full validation is importer-enforced; database checks enforce JSON type and critical envelope fields only.

## 2. Exact MVP tables

### 2.1 Identity, principals, and governed reference values

#### `principal`

Purpose: stable identity for human and service actors.

- PK: `principal_id`.
- Required: `principal_kind_value_id`, `external_issuer`, `external_subject`, `display_name`, `created_at`.
- Nullable: `disabled_at`.
- FKs: `principal_kind_value_id -> reference_value.reference_value_id`.
- Immutable: PK, kind, issuer, subject, `created_at`.
- Alternate key/unique: `(external_issuer, external_subject)`.
- Checks: issuer/subject/display name are nonblank; `disabled_at >= created_at` when present.
- Indexes: kind; `disabled_at`.
- Append-only: no; identity attributes are immutable, while `display_name` and `disabled_at` are administrative state.
- Projection fields: none.

#### `reference_domain`

Purpose: governed vocabulary definition, for example `BASELINE_TYPE`, `MAPPING_KIND`, `DECISION_STATUS`, `GUIDANCE_SCOPE`, and `DECISION_TOPIC_CODE`.

- PK: `reference_domain_id`.
- Required: `domain_code`, `display_name`, `is_versioned`, `created_at`.
- Nullable: `description`.
- FKs: none.
- Immutable: all columns.
- Alternate key/unique: `domain_code`.
- Checks: code matches `^[A-Z][A-Z0-9_]*$`; names are nonblank.
- Indexes: unique code index only.
- Append-only: yes.
- Projection fields: none.

#### `reference_value`

Purpose: governed, versioned controlled value. Guidance scope/topic values use explicit versions; other controlled domains may use version `1` initially.

- PK: `reference_value_id`.
- Required: `reference_domain_id`, `value_code`, `version_number`, `display_name`, `effective_at`, `is_bootstrap_seed`, `created_at`.
- Nullable: `description`, `supersedes_reference_value_id`, `retired_at`, `created_by_principal_id`.
- FKs: domain; self supersession; optional creator principal.
- Immutable: all columns.
- Alternate key/unique: `(reference_domain_id, value_code, version_number)`.
- Checks: code format as above; version > 0; retirement follows effective time; supersession cannot self-reference; creator may be null only for an explicitly marked bootstrap seed. Bootstrap status is immutable.
- Indexes: `(reference_domain_id, value_code)`; supersedes; effective/retired dates.
- Append-only: yes.
- Projection fields: whether a value is “current” is derived from effective/retired/supersession data.

### 2.2 Baselines and lifecycle

#### `baseline_series`

Purpose: identity of the governed baseline sequence for one source system, FHIR resource, and baseline type.

- PK: `baseline_series_id`.
- Required: `source_system`, `fhir_resource`, `baseline_type_value_id`, `created_at`.
- Nullable: `description`.
- FKs: baseline type reference value.
- Immutable: all columns.
- Alternate key/unique: `(source_system, fhir_resource, baseline_type_value_id)`.
- Checks: source system and FHIR resource are nonblank.
- Indexes: alternate-key unique index.
- Append-only: yes.
- Projection fields: none.

#### `baseline_version`

Purpose: immutable baseline-version identity and metadata.

- PK: `baseline_version_id`.
- Required: `baseline_series_id`, `baseline_code`, `version_label`, `is_gold_standard`, `import_specification_version`, `created_at`, `created_by_principal_id`.
- Nullable: `description`.
- FKs: series; creator principal.
- Immutable: all columns.
- Alternate keys/unique: `baseline_code`; `(baseline_series_id, version_label)`.
- Checks: baseline code/version/import-specification version are nonblank.
- Indexes: series; creation time.
- Append-only: yes.
- Projection fields: lifecycle status and current artifact are deliberately absent and derived elsewhere.

#### `baseline_relationship`

Purpose: immutable lineage such as BL-002 superseding BL-001.

- PK: `baseline_relationship_id`.
- Required: `from_baseline_version_id`, `to_baseline_version_id`, `relationship_type_value_id`, `created_at`, `created_by_principal_id`.
- Nullable: `reason`.
- FKs: both baseline versions; relationship type reference value; creator.
- Immutable: all columns.
- Alternate key/unique: `(from_baseline_version_id, to_baseline_version_id, relationship_type_value_id)`.
- Checks: from and to differ.
- Indexes: both directional baseline FKs.
- Append-only: yes.
- Projection fields: none.

#### `baseline_lifecycle_event`

Purpose: authoritative append-only lifecycle history.

- PK: `baseline_lifecycle_event_id`.
- Required: `baseline_version_id`, `lifecycle_status_value_id`, `occurred_at`, `recorded_at`, `actor_principal_id`.
- Nullable: `initiating_human_principal_id`, `governance_action_id`, `reason`, `supersedes_event_id`.
- FKs: baseline; lifecycle-status value; actor/human principals; governance action; self supersession.
- Immutable: all columns.
- Alternate key/unique: `(baseline_version_id, occurred_at, baseline_lifecycle_event_id)` supplies deterministic ordering; no semantic uniqueness beyond PK.
- Checks: actor and initiating human differ unless actor is human; initiating principal, when present, must be human at application validation; supersession cannot self-reference; `recorded_at >= occurred_at`.
- Indexes: `(baseline_version_id, occurred_at desc)`; supersedes; governance action.
- Append-only: yes.
- Projection fields: current lifecycle state is the latest non-superseded valid event.

### 2.3 Immutable artifacts and manifests

#### `artifact`

Purpose: content identity for authoritative workbooks and immutable governance-document snapshots.

- PK: `artifact_id`.
- Required: `artifact_kind_value_id`, `sha256_digest`, `byte_size`, `media_type`, `physical_filename`, `captured_at`, `created_at`, `created_by_principal_id`.
- Nullable: `original_or_upload_name`, `source_modified_at`, `description`.
- FKs: artifact-kind value; creator.
- Immutable: all columns.
- Alternate key/unique: `sha256_digest`.
- Checks: byte size >= 0; names/media type nonblank; digest length exactly 32 bytes.
- Indexes: artifact kind; captured time.
- Append-only: yes.
- Projection fields: availability/current location are not stored here.

#### `artifact_location`

Purpose: append-only retrieval/location history for an artifact.

- PK: `artifact_location_id`.
- Required: `artifact_id`, `location_kind_value_id`, `location_uri`, `observed_at`, `recorded_at`, `actor_principal_id`.
- Nullable: `initiating_human_principal_id`, `availability_status_value_id`, `supersedes_location_id`, `note`.
- FKs: artifact; location kind; availability status; actor/human; self supersession.
- Immutable: all columns.
- Alternate key/unique: `(artifact_id, location_uri, observed_at)`.
- Checks: URI nonblank; recorded time is not before observed time; supersession cannot self-reference.
- Indexes: `(artifact_id, observed_at desc)`; availability; supersedes.
- Append-only: yes.
- Projection fields: current retrievable location is derived from latest non-superseded available record.

#### `baseline_artifact`

Purpose: assign immutable artifact roles within a baseline evidence package.

- PK: `baseline_artifact_id`.
- Required: `baseline_version_id`, `artifact_id`, `artifact_role_value_id`, `created_at`, `created_by_principal_id`.
- Nullable: `note`.
- FKs: baseline; artifact; artifact-role value; creator.
- Immutable: all columns.
- Alternate key/unique: `(baseline_version_id, artifact_id, artifact_role_value_id)`.
- Checks: none beyond FKs/nonblank note handling.
- Indexes: `(baseline_version_id, artifact_role_value_id)`; artifact.
- Append-only: yes.
- Projection fields: “current authoritative artifact” is derived from role, lifecycle, import, and supersession facts.

#### `artifact_sheet_manifest`

Purpose: immutable workbook inventory and governed sheet/range classification.

- PK: `artifact_sheet_manifest_id`.
- Required: `artifact_id`, `sheet_name`, `sheet_order`, `sheet_classification_value_id`, `is_present`, `is_authoritative`, `manifest_schema_id`, `manifest_schema_version`, `created_at`.
- Nullable: `header_row_number`, `candidate_range`, `governed_column_range`, `candidate_row_count`, `notes`, `manifest_json`.
- FKs: artifact; sheet-classification value.
- Immutable: all columns.
- Alternate key/unique: `(artifact_id, sheet_name)` and `(artifact_id, sheet_order)`.
- Checks: order > 0; row/count values nonnegative; authoritative implies present; JSON is an object when present; schema fields nonblank.
- Indexes: classification; `(artifact_id, is_authoritative)`.
- Append-only: yes.
- Projection fields: none.

### 2.4 Import and raw-row provenance

#### `import_run`

Purpose: one import attempt against one baseline and one authoritative artifact.

- PK: `import_run_id`.
- Required: `baseline_version_id`, `artifact_id`, `import_policy_value_id`, `import_specification_version`, `importer_version`, `configuration_digest`, `started_at`, `actor_principal_id`, `created_at`.
- Nullable: `initiating_human_principal_id`, `completed_at`, `terminal_status_value_id`, `failure_summary`.
- FKs: baseline; artifact; policy/status values; actor/human.
- Immutable: identity/configuration/input/actor/start fields. Completion fields are write-once.
- Alternate key/unique: `(baseline_version_id, artifact_id, import_specification_version, importer_version, configuration_digest)` for terminal committed runs; failed attempts remain distinguishable by PK.
- Checks: configuration digest length; completion and terminal status are both null or both present; completion >= start.
- Indexes: `(baseline_version_id, started_at desc)`; artifact; terminal status.
- Append-only: no during execution; immutable after terminal finalization.
- Projection fields: none; terminal status is the authoritative outcome of that attempt.

#### `import_run_metric`

Purpose: immutable aggregate candidate/accepted/warning/error/quarantine counts with optional dimensions.

- PK: `import_run_metric_id`.
- Required: `import_run_id`, `metric_type_value_id`, `metric_count`, `created_at`.
- Nullable: `source_sheet_name`, `mapping_kind_value_id`, `decision_status_value_id`, `severity_value_id`.
- FKs: import run and all controlled dimensions.
- Immutable: all columns.
- Alternate key/unique: import run plus metric type and the null-safe combination of all dimensions.
- Checks: count >= 0; at least one metric type; dimensional combinations are importer-validated.
- Indexes: import run; metric type; source sheet.
- Append-only: yes, inserted when the run is finalized.
- Projection fields: dashboard totals are projections over these authoritative finalized metrics and detailed rows/findings.

#### `import_candidate_row`

Purpose: immutable lossless evidence for every candidate row, including accepted and quarantined candidates.

- PK: `import_candidate_row_id`.
- Required: `import_run_id`, `mapping_kind_value_id`, `source_sheet_name`, `source_row_number`, `source_cell_range`, `raw_schema_id`, `raw_schema_version`, `raw_source_row`, `source_row_hash`, `normalization_algorithm_version`, `logical_key_algorithm_version`, `candidate_disposition_value_id`, `created_at`.
- Nullable: `calculated_logical_key`, `logical_key_components_json`.
- FKs: import run; mapping kind; disposition values.
- Immutable: all columns.
- Alternate key/unique: `(import_run_id, source_sheet_name, source_row_number, source_cell_range)`.
- Checks: row number > 0; source identifiers nonblank; hashes/digests have required length; raw JSON and key-components JSON are objects; schema/version fields nonblank; accepted disposition requires calculated logical key.
- Indexes: `(import_run_id, source_sheet_name, source_row_number)`; `(import_run_id, mapping_kind_value_id)`; `(import_run_id, source_sheet_name, source_row_hash)` nonunique for duplicate detection; calculated logical key.
- Append-only: yes.
- Projection fields: none. Disposition is the immutable result for this import attempt, not a mutable quarantine workflow status.

### 2.5 Logical identities and accepted records

#### `logical_mapping_identity`

Purpose: stable semantic mapping identity independent of physical workbook row.

- PK: `logical_mapping_identity_id`.
- Required: `mapping_kind_value_id`, `source_system`, `fhir_resource`, `key_algorithm_version`, `logical_key`, `key_components_json`, `created_at`.
- Nullable: none.
- FKs: mapping kind value.
- Immutable: all columns.
- Alternate key/unique: `(mapping_kind_value_id, source_system, fhir_resource, key_algorithm_version, logical_key)`.
- Checks: names/version/key nonblank; logical key has approved prefix/hash form; key components JSON is an object.
- Indexes: logical key; `(source_system, fhir_resource, mapping_kind_value_id)`.
- Append-only: yes.
- Projection fields: none.

#### `mapping_record`

Purpose: common immutable header for each accepted governed mapping record.

- PK: `mapping_record_id`.
- Required: `baseline_version_id`, `import_candidate_row_id`, `logical_mapping_identity_id`, `mapping_kind_value_id`, `decision_status_value_id`, `created_at`.
- Nullable: none.
- FKs: baseline; candidate row; logical identity; kind; decision status.
- Immutable: all columns.
- Alternate keys/unique: `import_candidate_row_id`; `(baseline_version_id, logical_mapping_identity_id)`.
- Checks: referenced candidate must be accepted and all kinds must match, enforced through deferred/application integrity tests if cross-table assertions are unavailable.
- Indexes: `(baseline_version_id, mapping_kind_value_id)`; decision status; logical identity.
- Append-only: yes.
- Projection fields: none.

#### `element_mapping`

Purpose: normalized ELEMENT_MAPPING payload.

- PK/FK: `mapping_record_id -> mapping_record`.
- Required: `target_fhir_path`.
- Nullable: `source_system_raw`, `interface_type`, `interface_name`, `source_expression`, `profile_context`, `fixed_value`, `transformation_rule`, `source_business_definition`, `cardinality_raw`, `cardinality_min`, `cardinality_max`, `cardinality_max_unbounded`, `valueset_binding`, `mandated_code_system`, `irrelevant_under_s2t_raw`, `example_value`, `exception_handling`, `notes`.
- Immutable: all columns.
- Alternate keys/unique: inherited logical identity; no additional unique constraint.
- Checks: target path nonblank; cardinality min >= 0; exactly one of numeric max or unbounded may be set; numeric max >= min; parsed fields may all remain null when raw cardinality is an approved blank exception.
- Indexes: target FHIR path; interface name; source expression where supported/useful.
- Append-only: yes.
- Projection fields: parsed cardinality fields are deterministic projections of `cardinality_raw`, retained for query performance but not a replacement for raw evidence.

#### `status_mapping_rule`

Purpose: normalized STATUS_MAPPING_RULE payload.

- PK/FK: `mapping_record_id -> mapping_record`.
- Required: `source_status_value`, `target_fhir_path`, `target_status_value`.
- Nullable: `source_sequence`, `source_business_definition`, `related_resource_note`, `transformation_rule`, `mapping_evidence_status_raw`, `notes`.
- Immutable: all columns.
- Alternate keys/unique: inherited logical identity.
- Checks: required text nonblank; target path equals the governed MedicationRequest status path, enforced by importer integrity test and optionally a DDL check if this table remains resource-specific.
- Indexes: source status; target status; target path.
- Append-only: yes.
- Projection fields: none.

#### `governance_guidance`

Purpose: normalized GOVERNANCE_GUIDANCE payload and approved governed semantic metadata.

- PK/FK: `mapping_record_id -> mapping_record`.
- Required: `guidance_scope_value_id`, `decision_topic_value_id`, `guidance_text`, `guidance_status_raw`.
- Nullable: `target_fhir_path_or_scope_raw`, `decision_topic_raw`, `notes`, `review_notes`.
- FKs: guidance scope and decision topic to exact `reference_value` versions.
- Immutable: all columns.
- Alternate keys/unique: inherited logical identity.
- Checks: required text/raw status nonblank; referenced values must belong to the correct reference domains, enforced by composite/reference integrity strategy in DDL; raw `x` or blank may be retained but cannot supply governed identity.
- Indexes: guidance scope; decision topic; combined scope/topic.
- Append-only: yes.
- Projection fields: governed scope/topic are approved metadata derived from semantic review, not projections inferred automatically from raw B/C cells.

### 2.6 Validation

#### `validation_ruleset`

Purpose: immutable identity for a complete validation-rules configuration.

- PK: `validation_ruleset_id`.
- Required: `ruleset_code`, `version_label`, `ruleset_digest`, `created_at`, `created_by_principal_id`.
- Nullable: `description`, `implementation_version`.
- FKs: creator.
- Immutable: all columns.
- Alternate keys/unique: `(ruleset_code, version_label)`; `ruleset_digest`.
- Checks: codes/versions nonblank; digest length.
- Indexes: unique keys only.
- Append-only: yes.
- Projection fields: none.

#### `validation_rule`

Purpose: immutable rule version within a ruleset.

- PK: `validation_rule_id`.
- Required: `validation_ruleset_id`, `rule_code`, `rule_version`, `default_severity_value_id`, `rule_definition_digest`, `created_at`.
- Nullable: `description`, `applicability_json`.
- FKs: ruleset; severity value.
- Immutable: all columns.
- Alternate key/unique: `(validation_ruleset_id, rule_code, rule_version)`.
- Checks: codes/versions nonblank; digest length; applicability is a JSON object when present.
- Indexes: ruleset; severity.
- Append-only: yes.
- Projection fields: none.

#### `validation_run`

Purpose: immutable execution of a ruleset against one import run and exact artifact.

- PK: `validation_run_id`.
- Required: `import_run_id`, `validation_ruleset_id`, `artifact_id`, `artifact_digest`, `execution_fingerprint`, `started_at`, `completed_at`, `candidate_count`, `accepted_count`, `warning_count`, `error_count`, `quarantined_count`, `outcome_value_id`, `actor_principal_id`, `created_at`.
- Nullable: `initiating_human_principal_id`, `summary_json`.
- FKs: import run; ruleset; artifact; outcome; actors.
- Immutable: all columns.
- Alternate key/unique: `(import_run_id, validation_ruleset_id, execution_fingerprint)`.
- Checks: completion >= start; counts >= 0; accepted + quarantined <= candidates; artifact digest length; summary JSON is an object.
- Indexes: `(import_run_id, completed_at desc)`; ruleset; artifact digest; outcome.
- Append-only: yes; only completed runs are persisted as authoritative validation evidence in MVP.
- Projection fields: none.

#### `validation_finding`

Purpose: immutable warning, error, or accepted-exception evidence.

- PK: `validation_finding_id`.
- Required: `validation_run_id`, `validation_rule_id`, `severity_value_id`, `finding_code`, `message`, `finding_fingerprint`, `evidence_schema_id`, `evidence_schema_version`, `evidence_json`, `created_at`.
- Nullable: `collision_group_key`.
- FKs: validation run; rule; severity.
- Immutable: all columns.
- Alternate key/unique: `(validation_run_id, finding_fingerprint)`.
- Checks: text/schema fields nonblank; fingerprint length; evidence JSON is an object.
- Indexes: `(validation_run_id, severity_value_id)`; rule; collision group.
- Append-only: yes.
- Projection fields: none.

#### `validation_finding_row`

Purpose: associate one finding with every involved candidate row, including collision groups.

- PK: `validation_finding_row_id`.
- Required: `validation_finding_id`, `import_candidate_row_id`, `finding_row_role_value_id`, `created_at`.
- Nullable: none.
- FKs: finding; candidate row; role value.
- Immutable: all columns.
- Alternate key/unique: `(validation_finding_id, import_candidate_row_id, finding_row_role_value_id)`.
- Checks: finding and candidate must belong to the same import run, enforced through application/deferred integrity tests.
- Indexes: candidate row; finding.
- Append-only: yes.
- Projection fields: none.

### 2.7 Quarantine

#### `quarantine_case`

Purpose: immutable opening record for a quarantined candidate.

- PK: `quarantine_case_id`.
- Required: `import_candidate_row_id`, `opening_validation_finding_id`, `opened_at`, `opened_by_principal_id`, `created_at`.
- Nullable: `initiating_human_principal_id`.
- FKs: candidate; finding; actors.
- Immutable: all columns.
- Alternate key/unique: `import_candidate_row_id`.
- Checks: candidate disposition must be quarantined and finding must reference it, enforced through integrity tests.
- Indexes: opening finding; opened time.
- Append-only: yes.
- Projection fields: current quarantine status is absent and derived from events.

#### `quarantine_event`

Purpose: append-only review and resolution history without erasing the original case.

- PK: `quarantine_event_id`.
- Required: `quarantine_case_id`, `event_type_value_id`, `occurred_at`, `recorded_at`, `actor_principal_id`.
- Nullable: `initiating_human_principal_id`, `governance_action_id`, `resolution_code_value_id`, `reason`, `supersedes_event_id`, `replacement_baseline_version_id`.
- FKs: case; event/resolution values; actors; governance action; self supersession; replacement baseline.
- Immutable: all columns.
- Alternate key/unique: none beyond PK.
- Checks: recorded >= occurred; supersession cannot self-reference; event-specific requirements are importer/application integrity tests.
- Indexes: `(quarantine_case_id, occurred_at desc)`; event type; governance action; replacement baseline.
- Append-only: yes.
- Projection fields: current quarantine state and resolution are the latest non-superseded applicable event.

### 2.8 Governance history and evidence

#### `governance_item`

Purpose: stable governed issue/decision identity such as `V2-BA-01`.

- PK: `governance_item_id`.
- Required: `baseline_version_id`, `item_code`, `classification_value_id`, `title`, `created_at`, `created_by_principal_id`.
- Nullable: `description`, `source_location_text`.
- FKs: baseline; classification value; creator.
- Immutable: all columns.
- Alternate key/unique: `(baseline_version_id, item_code)`.
- Checks: code/title nonblank.
- Indexes: classification; baseline.
- Append-only: yes.
- Projection fields: current approval status is derived from actions.

#### `governance_action`

Purpose: append-only proposal, approval, rejection, acknowledgment, or supersession history.

- PK: `governance_action_id`.
- Required: `governance_item_id`, `action_type_value_id`, `occurred_at`, `recorded_at`, `actor_principal_id`, `rationale`.
- Nullable: `initiating_human_principal_id`, `supersedes_action_id`.
- FKs: governance item; action type; actors; self supersession.
- Immutable: all columns.
- Alternate key/unique: none beyond PK.
- Checks: rationale nonblank; recorded >= occurred; supersession cannot self-reference.
- Indexes: `(governance_item_id, occurred_at desc)`; action type; supersedes.
- Append-only: yes.
- Projection fields: current governance disposition is latest non-superseded action according to the governed workflow.

#### `governance_evidence`

Purpose: immutable evidence links from a governance action to artifacts, validation runs, candidate rows, findings, or release evaluations.

- PK: `governance_evidence_id`.
- Required: `governance_action_id`, `evidence_role_value_id`, `created_at`.
- Nullable: `artifact_id`, `reference_value_id`, `validation_run_id`, `import_candidate_row_id`, `validation_finding_id`, `release_gate_evaluation_id`, `citation_text`.
- FKs: action; evidence role; each typed evidence target.
- Immutable: all columns.
- Alternate key/unique: null-safe uniqueness across action, role, and the selected target.
- Checks: exactly one typed evidence target is nonnull; citation may supplement but not replace a target.
- Indexes: each target FK; governance action.
- Append-only: yes.
- Projection fields: none.

### 2.9 Release gates

#### `release_gate_definition`

Purpose: immutable versioned gate definition.

- PK: `release_gate_definition_id`.
- Required: `gate_code`, `version_label`, `definition_digest`, `created_at`, `created_by_principal_id`.
- Nullable: `description`.
- FKs: creator.
- Immutable: all columns.
- Alternate keys/unique: `(gate_code, version_label)`; definition digest.
- Checks: code/version nonblank; digest length.
- Indexes: gate code.
- Append-only: yes.
- Projection fields: none.

#### `release_gate_requirement`

Purpose: individual requirement in a versioned release gate.

- PK: `release_gate_requirement_id`.
- Required: `release_gate_definition_id`, `requirement_code`, `sequence_number`, `is_blocking`, `description`, `created_at`.
- Nullable: none.
- FKs: gate definition.
- Immutable: all columns.
- Alternate keys/unique: `(release_gate_definition_id, requirement_code)`; `(release_gate_definition_id, sequence_number)`.
- Checks: sequence > 0; code/description nonblank.
- Indexes: gate definition and blocking flag.
- Append-only: yes.
- Projection fields: none.

#### `release_gate_evaluation`

Purpose: immutable evaluation bound to the exact baseline, authoritative artifact digest, and validation ruleset.

- PK: `release_gate_evaluation_id`.
- Required: `baseline_version_id`, `release_gate_definition_id`, `artifact_id`, `artifact_digest`, `validation_ruleset_id`, `validation_run_id`, `gate_outcome_value_id`, `evaluated_at`, `recorded_at`, `actor_principal_id`, `created_at`.
- Nullable: `initiating_human_principal_id`, `supersedes_evaluation_id`, `governance_action_id`, `summary`.
- FKs: baseline; gate definition; artifact; ruleset/run; outcome; actors; self supersession; governance action.
- Immutable: all columns.
- Alternate key/unique: none beyond PK; repeated evaluations are valid history.
- Checks: digest length; recorded >= evaluated; supersession cannot self-reference; validation run must use the same artifact digest/ruleset, enforced through integrity tests.
- Indexes: `(baseline_version_id, release_gate_definition_id, evaluated_at desc)`; `(artifact_digest, validation_ruleset_id)`; supersedes; validation run.
- Append-only: yes.
- Projection fields: current gate state is the latest non-superseded evaluation whose digest and ruleset still match the baseline's current authoritative evidence.

#### `release_gate_result`

Purpose: immutable result and evidence for each gate requirement.

- PK: `release_gate_result_id`.
- Required: `release_gate_evaluation_id`, `release_gate_requirement_id`, `requirement_outcome_value_id`, `created_at`.
- Nullable: `governance_action_id`, `validation_finding_id`, `evidence_json`, `explanation`.
- FKs: evaluation; requirement; outcome; governance action; finding.
- Immutable: all columns.
- Alternate key/unique: `(release_gate_evaluation_id, release_gate_requirement_id)`.
- Checks: evidence JSON is an object when present; requirement belongs to the evaluation's gate definition, enforced through integrity tests.
- Indexes: requirement outcome; governance action; finding.
- Append-only: yes.
- Projection fields: aggregate gate outcome may be recomputed from requirement results, but the recorded evaluation outcome remains the historical decision.

### 2.10 Security/operational audit

#### `audit_event`

Purpose: append-only security and administrative audit not already represented by domain events, including restricted raw-evidence access.

- PK: `audit_event_id`.
- Required: `baseline_version_id`, `event_type_value_id`, `occurred_at`, `recorded_at`, `actor_principal_id`, `target_type_value_id`, `target_identifier`, `outcome_value_id`, `created_at`.
- Nullable: `initiating_human_principal_id`, `request_correlation_id`, `detail_schema_id`, `detail_schema_version`, `detail_json`.
- FKs: baseline; event/target/outcome values; actors.
- Immutable: all columns.
- Alternate key/unique: none beyond PK.
- Checks: target identifier nonblank; recorded >= occurred; detail JSON object and schema/version required together.
- Indexes: `(baseline_version_id, occurred_at desc)`; actor; event type; correlation ID; target identifier.
- Append-only: yes.
- Projection fields: none.

## 3. Cross-table integrity tests required for MVP

Some governed invariants cannot be expressed portably as single-table checks. The DDL may use deferred constraints or triggers where safe, but the importer and integrity test suite must always verify:

1. Every controlled FK belongs to the expected reference domain and was effective for the recorded action.
2. The artifact used by an import is linked to that baseline as authoritative evidence and its stored digest matches the artifact row.
3. Accepted candidate rows have exactly one `mapping_record`; quarantined rows have no accepted mapping record and exactly one quarantine case.
4. Mapping kind agrees across candidate, logical identity, mapping record, and exactly one subtype table.
5. Logical-key components and hash recompute correctly under the recorded algorithm version.
6. Finding rows belong to the same import run as their validation finding.
7. Validation summary counts reconcile with candidate rows and findings.
8. Quarantine opening findings reference their quarantined candidate.
9. Governance evidence targets belong to the relevant baseline evidence package.
10. Release requirements belong to the evaluation's gate definition.
11. Release evaluation artifact digest and ruleset match its validation run.
12. A projected current gate is ignored when superseded or when its digest/ruleset no longer matches current authoritative evidence.

## 4. Authoritative state versus projections

The following are explicitly projections and must be implemented initially as queries/views, not independently editable facts:

- current baseline lifecycle status;
- current artifact location and availability;
- current authoritative artifact for a baseline;
- current governance-item approval status;
- current quarantine status/resolution;
- current reference-value version;
- current release-gate state;
- dashboard counts and status summaries.

Parsed cardinality columns are stored deterministic query projections, but `cardinality_raw` and the candidate raw JSON remain the evidence authority. Normalized mapping fields are governed imported facts; they never replace the raw row.

## 5. Tables deferred beyond MVP

The following are intentionally excluded from the exact MVP table list:

- `element_change` and precomputed cross-baseline semantic diff tables;
- materialized current-state/summary tables;
- row-level and artifact-level authorization policy tables;
- notification, assignment, escalation, and remediation workflow tables;
- retention/disposal execution and legal-hold tables;
- artifact replica health, checksum-scan history, and storage-tier management tables;
- terminology/value-set catalogs beyond governed reference values required by this import;
- generalized rule dependency graphs;
- cryptographic signature/attestation tables beyond SHA-256 identity;
- UI annotations, tags, saved filters, and dashboard preferences;
- import staging tables, temporary work queues, leases, and retry internals, which are implementation details rather than governed persistence.

## 6. Remaining blockers to DDL generation

There is no remaining governance or schema decision that blocks generation of a technology-specific DDL proposal.

The database engine must be selected when DDL is generated because UUID generation, binary digest types, JSON checks, filtered/null-safe unique indexes, append-only enforcement, and deferred cross-table constraints are engine-specific syntax. That selection is a technical translation choice already delegated to technical owners by V2-BA-09; it is not a new governance approval.

`V2-BA-07` remains a mandatory data/provenance prerequisite before import execution. It does not block DDL generation because the schema explicitly supports separate artifact digest, physical filename, original/upload name, and append-only locations.

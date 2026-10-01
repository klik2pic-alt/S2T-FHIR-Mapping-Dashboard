set role s2t_fhir_owner;

create table s2t_fhir.release_gate_definition (
  release_gate_definition_id uuid primary key default gen_random_uuid(),
  gate_code text not null,
  version_label text not null,
  definition_digest bytea not null,
  description text,
  created_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint release_gate_definition_version_uq unique (gate_code, version_label),
  constraint release_gate_definition_digest_uq unique (definition_digest),
  constraint release_gate_definition_text_ck check (btrim(gate_code) <> '' and btrim(version_label) <> ''),
  constraint release_gate_definition_digest_ck check (octet_length(definition_digest) = 32)
);

create table s2t_fhir.release_gate_requirement (
  release_gate_requirement_id uuid primary key default gen_random_uuid(),
  release_gate_definition_id uuid not null references s2t_fhir.release_gate_definition(release_gate_definition_id),
  requirement_code text not null,
  sequence_number integer not null,
  is_blocking boolean not null,
  description text not null,
  created_at timestamptz not null default transaction_timestamp(),
  constraint release_gate_requirement_code_uq unique (release_gate_definition_id, requirement_code),
  constraint release_gate_requirement_sequence_uq unique (release_gate_definition_id, sequence_number),
  constraint release_gate_requirement_sequence_ck check (sequence_number > 0),
  constraint release_gate_requirement_text_ck check (btrim(requirement_code) <> '' and btrim(description) <> '')
);

create table s2t_fhir.release_gate_evaluation (
  release_gate_evaluation_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  release_gate_definition_id uuid not null references s2t_fhir.release_gate_definition(release_gate_definition_id),
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  artifact_digest bytea not null,
  validation_ruleset_id uuid not null references s2t_fhir.validation_ruleset(validation_ruleset_id),
  validation_run_id uuid not null references s2t_fhir.validation_run(validation_run_id),
  gate_outcome_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  evaluated_at timestamptz not null,
  recorded_at timestamptz not null default transaction_timestamp(),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  supersedes_evaluation_id uuid references s2t_fhir.release_gate_evaluation(release_gate_evaluation_id),
  governance_action_id uuid references s2t_fhir.governance_action(governance_action_id),
  summary text,
  created_at timestamptz not null default transaction_timestamp(),
  constraint release_gate_evaluation_digest_ck check (octet_length(artifact_digest) = 32),
  constraint release_gate_evaluation_time_ck check (recorded_at >= evaluated_at),
  constraint release_gate_evaluation_supersedes_ck check (supersedes_evaluation_id is null or supersedes_evaluation_id <> release_gate_evaluation_id)
);

create table s2t_fhir.release_gate_result (
  release_gate_result_id uuid primary key default gen_random_uuid(),
  release_gate_evaluation_id uuid not null references s2t_fhir.release_gate_evaluation(release_gate_evaluation_id),
  release_gate_requirement_id uuid not null references s2t_fhir.release_gate_requirement(release_gate_requirement_id),
  requirement_outcome_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  governance_action_id uuid references s2t_fhir.governance_action(governance_action_id),
  validation_finding_id uuid references s2t_fhir.validation_finding(validation_finding_id),
  evidence_json jsonb,
  explanation text,
  created_at timestamptz not null default transaction_timestamp(),
  constraint release_gate_result_requirement_uq unique (release_gate_evaluation_id, release_gate_requirement_id),
  constraint release_gate_result_json_ck check (evidence_json is null or jsonb_typeof(evidence_json) = 'object')
);

create table s2t_fhir.governance_evidence (
  governance_evidence_id uuid primary key default gen_random_uuid(),
  governance_action_id uuid not null references s2t_fhir.governance_action(governance_action_id),
  evidence_role_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  artifact_id uuid references s2t_fhir.artifact(artifact_id),
  reference_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  validation_run_id uuid references s2t_fhir.validation_run(validation_run_id),
  import_candidate_row_id uuid references s2t_fhir.import_candidate_row(import_candidate_row_id),
  validation_finding_id uuid references s2t_fhir.validation_finding(validation_finding_id),
  release_gate_evaluation_id uuid references s2t_fhir.release_gate_evaluation(release_gate_evaluation_id),
  citation_text text,
  created_at timestamptz not null default transaction_timestamp(),
  constraint governance_evidence_one_target_ck check (
    num_nonnulls(artifact_id, reference_value_id, validation_run_id, import_candidate_row_id, validation_finding_id, release_gate_evaluation_id) = 1
  )
);

create table s2t_fhir.audit_event (
  audit_event_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  event_type_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default transaction_timestamp(),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  target_type_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  target_identifier text not null,
  outcome_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  request_correlation_id uuid,
  detail_schema_id text,
  detail_schema_version text,
  detail_json jsonb,
  created_at timestamptz not null default transaction_timestamp(),
  constraint audit_event_time_ck check (recorded_at >= occurred_at),
  constraint audit_event_target_ck check (btrim(target_identifier) <> ''),
  constraint audit_event_detail_pair_ck check (
    (detail_json is null and detail_schema_id is null and detail_schema_version is null) or
    (detail_json is not null and detail_schema_id is not null and detail_schema_version is not null and btrim(detail_schema_id) <> '' and btrim(detail_schema_version) <> '')
  ),
  constraint audit_event_json_ck check (detail_json is null or jsonb_typeof(detail_json) = 'object')
);

reset role;

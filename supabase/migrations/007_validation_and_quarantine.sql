set role s2t_fhir_owner;

create table s2t_fhir.validation_ruleset (
  validation_ruleset_id uuid primary key default gen_random_uuid(),
  ruleset_code text not null,
  version_label text not null,
  ruleset_digest bytea not null,
  description text,
  implementation_version text,
  created_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint validation_ruleset_version_uq unique (ruleset_code, version_label),
  constraint validation_ruleset_digest_uq unique (ruleset_digest),
  constraint validation_ruleset_text_ck check (btrim(ruleset_code) <> '' and btrim(version_label) <> ''),
  constraint validation_ruleset_digest_ck check (octet_length(ruleset_digest) = 32)
);

create table s2t_fhir.validation_rule (
  validation_rule_id uuid primary key default gen_random_uuid(),
  validation_ruleset_id uuid not null references s2t_fhir.validation_ruleset(validation_ruleset_id),
  rule_code text not null,
  rule_version text not null,
  default_severity_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  rule_definition_digest bytea not null,
  description text,
  applicability_json jsonb,
  created_at timestamptz not null default transaction_timestamp(),
  constraint validation_rule_business_uq unique (validation_ruleset_id, rule_code, rule_version),
  constraint validation_rule_text_ck check (btrim(rule_code) <> '' and btrim(rule_version) <> ''),
  constraint validation_rule_digest_ck check (octet_length(rule_definition_digest) = 32),
  constraint validation_rule_json_ck check (applicability_json is null or jsonb_typeof(applicability_json) = 'object')
);

create table s2t_fhir.validation_run (
  validation_run_id uuid primary key default gen_random_uuid(),
  import_run_id uuid not null references s2t_fhir.import_run(import_run_id),
  validation_ruleset_id uuid not null references s2t_fhir.validation_ruleset(validation_ruleset_id),
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  artifact_digest bytea not null,
  execution_fingerprint bytea not null,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  candidate_count bigint not null,
  accepted_count bigint not null,
  warning_count bigint not null,
  error_count bigint not null,
  quarantined_count bigint not null,
  outcome_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  summary_json jsonb,
  created_at timestamptz not null default transaction_timestamp(),
  constraint validation_run_execution_uq unique (import_run_id, validation_ruleset_id, execution_fingerprint),
  constraint validation_run_time_ck check (completed_at >= started_at),
  constraint validation_run_digest_ck check (octet_length(artifact_digest) = 32 and octet_length(execution_fingerprint) = 32),
  constraint validation_run_counts_ck check (candidate_count >= 0 and accepted_count >= 0 and warning_count >= 0 and error_count >= 0 and quarantined_count >= 0 and accepted_count + quarantined_count <= candidate_count),
  constraint validation_run_json_ck check (summary_json is null or jsonb_typeof(summary_json) = 'object')
);

create table s2t_fhir.validation_finding (
  validation_finding_id uuid primary key default gen_random_uuid(),
  validation_run_id uuid not null references s2t_fhir.validation_run(validation_run_id),
  validation_rule_id uuid not null references s2t_fhir.validation_rule(validation_rule_id),
  severity_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  finding_code text not null,
  message text not null,
  finding_fingerprint bytea not null,
  collision_group_key text,
  evidence_schema_id text not null,
  evidence_schema_version text not null,
  evidence_json jsonb not null,
  created_at timestamptz not null default transaction_timestamp(),
  constraint validation_finding_fingerprint_uq unique (validation_run_id, finding_fingerprint),
  constraint validation_finding_text_ck check (btrim(finding_code) <> '' and btrim(message) <> '' and btrim(evidence_schema_id) <> '' and btrim(evidence_schema_version) <> ''),
  constraint validation_finding_digest_ck check (octet_length(finding_fingerprint) = 32),
  constraint validation_finding_json_ck check (jsonb_typeof(evidence_json) = 'object')
);

create table s2t_fhir.validation_finding_row (
  validation_finding_row_id uuid primary key default gen_random_uuid(),
  validation_finding_id uuid not null references s2t_fhir.validation_finding(validation_finding_id),
  import_candidate_row_id uuid not null references s2t_fhir.import_candidate_row(import_candidate_row_id),
  finding_row_role_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint validation_finding_row_business_uq unique (validation_finding_id, import_candidate_row_id, finding_row_role_value_id)
);

create table s2t_fhir.quarantine_case (
  quarantine_case_id uuid primary key default gen_random_uuid(),
  import_candidate_row_id uuid not null references s2t_fhir.import_candidate_row(import_candidate_row_id),
  opening_validation_finding_id uuid not null references s2t_fhir.validation_finding(validation_finding_id),
  opened_at timestamptz not null,
  opened_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint quarantine_case_candidate_uq unique (import_candidate_row_id)
);

create table s2t_fhir.quarantine_event (
  quarantine_event_id uuid primary key default gen_random_uuid(),
  quarantine_case_id uuid not null references s2t_fhir.quarantine_case(quarantine_case_id),
  event_type_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default transaction_timestamp(),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  governance_action_id uuid references s2t_fhir.governance_action(governance_action_id),
  resolution_code_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  reason text,
  supersedes_event_id uuid references s2t_fhir.quarantine_event(quarantine_event_id),
  replacement_baseline_version_id uuid references s2t_fhir.baseline_version(baseline_version_id),
  constraint quarantine_event_time_ck check (recorded_at >= occurred_at),
  constraint quarantine_event_supersedes_ck check (supersedes_event_id is null or supersedes_event_id <> quarantine_event_id)
);

reset role;

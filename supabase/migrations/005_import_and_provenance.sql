set role s2t_fhir_owner;

create table s2t_fhir.import_run (
  import_run_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  import_policy_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  import_specification_version text not null,
  importer_version text not null,
  configuration_digest bytea not null,
  started_at timestamptz not null,
  completed_at timestamptz,
  terminal_status_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  failure_summary text,
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint import_run_text_ck check (btrim(import_specification_version) <> '' and btrim(importer_version) <> ''),
  constraint import_run_digest_ck check (octet_length(configuration_digest) = 32),
  constraint import_run_terminal_pair_ck check ((completed_at is null) = (terminal_status_value_id is null)),
  constraint import_run_completion_ck check (completed_at is null or completed_at >= started_at)
);

create table s2t_fhir.import_run_metric (
  import_run_metric_id uuid primary key default gen_random_uuid(),
  import_run_id uuid not null references s2t_fhir.import_run(import_run_id),
  metric_type_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  metric_count bigint not null,
  source_sheet_name text,
  mapping_kind_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  decision_status_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  severity_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint import_run_metric_count_ck check (metric_count >= 0),
  constraint import_run_metric_sheet_ck check (source_sheet_name is null or btrim(source_sheet_name) <> '')
);

create table s2t_fhir.import_candidate_row (
  import_candidate_row_id uuid primary key default gen_random_uuid(),
  import_run_id uuid not null references s2t_fhir.import_run(import_run_id),
  mapping_kind_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  source_sheet_name text not null,
  source_row_number integer not null,
  source_cell_range text not null,
  raw_schema_id text not null,
  raw_schema_version text not null,
  raw_source_row jsonb not null,
  source_row_hash bytea not null,
  normalization_algorithm_version text not null,
  logical_key_algorithm_version text not null,
  candidate_disposition_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  calculated_logical_key text,
  logical_key_components_json jsonb,
  created_at timestamptz not null default transaction_timestamp(),
  constraint import_candidate_location_uq unique (import_run_id, source_sheet_name, source_row_number, source_cell_range),
  constraint import_candidate_row_number_ck check (source_row_number > 0),
  constraint import_candidate_text_ck check (
    btrim(source_sheet_name) <> '' and btrim(source_cell_range) <> '' and
    btrim(raw_schema_id) <> '' and btrim(raw_schema_version) <> '' and
    btrim(normalization_algorithm_version) <> '' and btrim(logical_key_algorithm_version) <> ''
  ),
  constraint import_candidate_hash_ck check (octet_length(source_row_hash) = 32),
  constraint import_candidate_raw_json_ck check (
    jsonb_typeof(raw_source_row) = 'object'
    and jsonb_typeof(raw_source_row -> 'sheet') = 'string'
    and raw_source_row ->> 'sheet' = source_sheet_name
    and jsonb_typeof(raw_source_row -> 'row') = 'number'
    and (raw_source_row ->> 'row')::integer = source_row_number
    and jsonb_typeof(raw_source_row -> 'range') = 'string'
    and raw_source_row ->> 'range' = source_cell_range
    and jsonb_typeof(raw_source_row -> 'cells') = 'object'
  ),
  constraint import_candidate_key_json_ck check (logical_key_components_json is null or jsonb_typeof(logical_key_components_json) = 'object')
);

reset role;

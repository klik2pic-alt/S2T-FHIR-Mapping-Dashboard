set role s2t_fhir_owner;

create table s2t_fhir.baseline_series (
  baseline_series_id uuid primary key default gen_random_uuid(),
  source_system text not null,
  fhir_resource text not null,
  baseline_type_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  description text,
  created_at timestamptz not null default transaction_timestamp(),
  constraint baseline_series_business_uq unique (source_system, fhir_resource, baseline_type_value_id),
  constraint baseline_series_text_ck check (btrim(source_system) <> '' and btrim(fhir_resource) <> '')
);

create table s2t_fhir.baseline_version (
  baseline_version_id uuid primary key default gen_random_uuid(),
  baseline_series_id uuid not null references s2t_fhir.baseline_series(baseline_series_id),
  baseline_code text not null,
  version_label text not null,
  is_gold_standard boolean not null,
  import_specification_version text not null,
  description text,
  created_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint baseline_version_code_uq unique (baseline_code),
  constraint baseline_version_series_label_uq unique (baseline_series_id, version_label),
  constraint baseline_version_text_ck check (btrim(baseline_code) <> '' and btrim(version_label) <> '' and btrim(import_specification_version) <> '')
);

alter table s2t_fhir.governance_item
  add constraint governance_item_baseline_fk
  foreign key (baseline_version_id) references s2t_fhir.baseline_version(baseline_version_id);

create table s2t_fhir.baseline_relationship (
  baseline_relationship_id uuid primary key default gen_random_uuid(),
  from_baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  to_baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  relationship_type_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  reason text,
  created_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint baseline_relationship_business_uq unique (from_baseline_version_id, to_baseline_version_id, relationship_type_value_id),
  constraint baseline_relationship_distinct_ck check (from_baseline_version_id <> to_baseline_version_id)
);

create table s2t_fhir.artifact (
  artifact_id uuid primary key default gen_random_uuid(),
  artifact_kind_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  sha256_digest bytea not null,
  byte_size bigint not null,
  media_type text not null,
  physical_filename text not null,
  original_or_upload_name text,
  captured_at timestamptz not null,
  source_modified_at timestamptz,
  description text,
  created_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint artifact_digest_uq unique (sha256_digest),
  constraint artifact_digest_ck check (octet_length(sha256_digest) = 32),
  constraint artifact_size_ck check (byte_size >= 0),
  constraint artifact_text_ck check (btrim(media_type) <> '' and btrim(physical_filename) <> '')
);

create table s2t_fhir.artifact_location (
  artifact_location_id uuid primary key default gen_random_uuid(),
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  location_kind_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  location_uri text not null,
  observed_at timestamptz not null,
  recorded_at timestamptz not null default transaction_timestamp(),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  availability_status_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  supersedes_location_id uuid references s2t_fhir.artifact_location(artifact_location_id),
  note text,
  constraint artifact_location_business_uq unique (artifact_id, location_uri, observed_at),
  constraint artifact_location_text_ck check (btrim(location_uri) <> ''),
  constraint artifact_location_time_ck check (recorded_at >= observed_at),
  constraint artifact_location_supersedes_ck check (supersedes_location_id is null or supersedes_location_id <> artifact_location_id)
);

create table s2t_fhir.baseline_artifact (
  baseline_artifact_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  artifact_role_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  note text,
  created_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint baseline_artifact_business_uq unique (baseline_version_id, artifact_id, artifact_role_value_id)
);

create table s2t_fhir.artifact_sheet_manifest (
  artifact_sheet_manifest_id uuid primary key default gen_random_uuid(),
  artifact_id uuid not null references s2t_fhir.artifact(artifact_id),
  sheet_name text not null,
  sheet_order integer not null,
  sheet_classification_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  is_present boolean not null,
  is_authoritative boolean not null,
  header_row_number integer,
  candidate_range text,
  governed_column_range text,
  candidate_row_count integer,
  notes text,
  manifest_schema_id text not null,
  manifest_schema_version text not null,
  manifest_json jsonb,
  created_at timestamptz not null default transaction_timestamp(),
  constraint artifact_sheet_name_uq unique (artifact_id, sheet_name),
  constraint artifact_sheet_order_uq unique (artifact_id, sheet_order),
  constraint artifact_sheet_order_ck check (sheet_order > 0),
  constraint artifact_sheet_header_ck check (header_row_number is null or header_row_number > 0),
  constraint artifact_sheet_count_ck check (candidate_row_count is null or candidate_row_count >= 0),
  constraint artifact_sheet_authority_ck check (not is_authoritative or is_present),
  constraint artifact_sheet_schema_ck check (btrim(manifest_schema_id) <> '' and btrim(manifest_schema_version) <> ''),
  constraint artifact_sheet_json_ck check (manifest_json is null or jsonb_typeof(manifest_json) = 'object')
);

create table s2t_fhir.baseline_lifecycle_event (
  baseline_lifecycle_event_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  lifecycle_status_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default transaction_timestamp(),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  governance_action_id uuid references s2t_fhir.governance_action(governance_action_id),
  reason text,
  supersedes_event_id uuid references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id),
  constraint baseline_lifecycle_time_ck check (recorded_at >= occurred_at),
  constraint baseline_lifecycle_supersedes_ck check (supersedes_event_id is null or supersedes_event_id <> baseline_lifecycle_event_id)
);

reset role;

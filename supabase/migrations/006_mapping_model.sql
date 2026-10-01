set role s2t_fhir_owner;

create table s2t_fhir.logical_mapping_identity (
  logical_mapping_identity_id uuid primary key default gen_random_uuid(),
  mapping_kind_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  source_system text not null,
  fhir_resource text not null,
  key_algorithm_version text not null,
  logical_key text not null,
  key_components_json jsonb not null,
  created_at timestamptz not null default transaction_timestamp(),
  constraint logical_mapping_identity_business_uq unique (mapping_kind_value_id, source_system, fhir_resource, key_algorithm_version, logical_key),
  constraint logical_mapping_identity_text_ck check (
    btrim(source_system) <> '' and btrim(fhir_resource) <> '' and
    btrim(key_algorithm_version) <> '' and logical_key ~ '^me:v[0-9]+:[0-9a-f]{64}$'
  ),
  constraint logical_mapping_identity_json_ck check (jsonb_typeof(key_components_json) = 'object')
);

create table s2t_fhir.mapping_record (
  mapping_record_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null references s2t_fhir.baseline_version(baseline_version_id),
  import_candidate_row_id uuid not null references s2t_fhir.import_candidate_row(import_candidate_row_id),
  logical_mapping_identity_id uuid not null references s2t_fhir.logical_mapping_identity(logical_mapping_identity_id),
  mapping_kind_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  decision_status_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint mapping_record_candidate_uq unique (import_candidate_row_id),
  constraint mapping_record_baseline_identity_uq unique (baseline_version_id, logical_mapping_identity_id)
);

create table s2t_fhir.element_mapping (
  mapping_record_id uuid primary key references s2t_fhir.mapping_record(mapping_record_id),
  target_fhir_path text not null,
  source_system_raw text,
  interface_type text,
  interface_name text,
  source_expression text,
  profile_context text,
  fixed_value text,
  transformation_rule text,
  source_business_definition text,
  cardinality_raw text,
  cardinality_min integer,
  cardinality_max integer,
  cardinality_max_unbounded boolean,
  valueset_binding text,
  mandated_code_system text,
  irrelevant_under_s2t_raw text,
  example_value text,
  exception_handling text,
  notes text,
  constraint element_mapping_target_ck check (btrim(target_fhir_path) <> ''),
  constraint element_mapping_cardinality_min_ck check (cardinality_min is null or cardinality_min >= 0),
  constraint element_mapping_cardinality_choice_ck check (not (cardinality_max is not null and cardinality_max_unbounded is true)),
  constraint element_mapping_cardinality_max_ck check (cardinality_max is null or (cardinality_max >= 0 and (cardinality_min is null or cardinality_max >= cardinality_min)))
);

create table s2t_fhir.status_mapping_rule (
  mapping_record_id uuid primary key references s2t_fhir.mapping_record(mapping_record_id),
  source_status_value text not null,
  target_fhir_path text not null,
  target_status_value text not null,
  source_sequence integer,
  source_business_definition text,
  related_resource_note text,
  transformation_rule text,
  mapping_evidence_status_raw text,
  notes text,
  constraint status_mapping_rule_text_ck check (btrim(source_status_value) <> '' and btrim(target_fhir_path) <> '' and btrim(target_status_value) <> '')
);

create table s2t_fhir.governance_guidance (
  mapping_record_id uuid primary key references s2t_fhir.mapping_record(mapping_record_id),
  guidance_scope_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  decision_topic_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  guidance_text text not null,
  guidance_status_raw text not null,
  target_fhir_path_or_scope_raw text,
  decision_topic_raw text,
  notes text,
  review_notes text,
  constraint governance_guidance_text_ck check (btrim(guidance_text) <> '' and btrim(guidance_status_raw) <> '')
);

reset role;

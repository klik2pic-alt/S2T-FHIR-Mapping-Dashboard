set role s2t_fhir_owner;

create table s2t_fhir.governance_item (
  governance_item_id uuid primary key default gen_random_uuid(),
  baseline_version_id uuid not null,
  item_code text not null,
  classification_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  title text not null,
  description text,
  source_location_text text,
  created_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint governance_item_business_uq unique (baseline_version_id, item_code),
  constraint governance_item_text_ck check (btrim(item_code) <> '' and btrim(title) <> '')
);

create table s2t_fhir.governance_action (
  governance_action_id uuid primary key default gen_random_uuid(),
  governance_item_id uuid not null references s2t_fhir.governance_item(governance_item_id),
  action_type_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default transaction_timestamp(),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  supersedes_action_id uuid references s2t_fhir.governance_action(governance_action_id),
  rationale text not null,
  constraint governance_action_time_ck check (recorded_at >= occurred_at),
  constraint governance_action_reason_ck check (btrim(rationale) <> ''),
  constraint governance_action_supersedes_ck check (supersedes_action_id is null or supersedes_action_id <> governance_action_id)
);

reset role;

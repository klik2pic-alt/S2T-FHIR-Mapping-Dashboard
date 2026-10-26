begin;

set role s2t_fhir_owner;

-- Migration 026: governed Candidate workbook-import database contracts.
-- Parsing and Storage credential issuance are deliberately external to PostgreSQL.

do $preflight$
declare
  v_name text;
begin
  foreach v_name in array array[
    's2t_fhir.candidate_import_request',
    's2t_fhir.candidate_import_request_event',
    's2t_fhir.candidate_import_staging_batch'
  ] loop
    if pg_catalog.to_regclass(v_name) is not null then
      raise exception '026 precondition: relation % already exists', v_name
        using errcode = '55000';
    end if;
  end loop;

  if pg_catalog.to_regprocedure('s2t_fhir._candidate_ui_upload_capability(uuid)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir_api.get_my_candidate_import(uuid)') is not null
     or pg_catalog.to_regprocedure('s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)') is not null then
    raise exception '026 precondition: one or more Candidate import functions already exist'
      using errcode = '55000';
  end if;

  if (select count(*) from s2t_fhir.principal
      where external_issuer = 'postgres-role'
        and external_subject = 's2t_fhir_migrator'
        and disabled_at is null) <> 1 then
    raise exception '026 requires exactly one active postgres-role/s2t_fhir_migrator principal'
      using errcode = '55000';
  end if;
end
$preflight$;

create table s2t_fhir.candidate_import_request (
  candidate_import_request_id uuid primary key default pg_catalog.gen_random_uuid(),
  resource_config_id text not null
    references s2t_fhir.mapping_resource_registry(resource_config_id),
  baseline_series_id uuid not null
    references s2t_fhir.baseline_series(baseline_series_id),
  uploader_principal_id uuid not null
    references s2t_fhir.principal(principal_id),
  version_label text not null,
  original_filename text not null,
  declared_byte_size bigint not null,
  idempotency_key uuid not null,
  expected_candidate_baseline_version_id uuid
    references s2t_fhir.baseline_version(baseline_version_id),
  expected_candidate_lifecycle_event_id uuid
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id),
  storage_object_key text not null,
  current_state text not null,
  artifact_id uuid references s2t_fhir.artifact(artifact_id),
  baseline_version_id uuid references s2t_fhir.baseline_version(baseline_version_id),
  import_run_id uuid references s2t_fhir.import_run(import_run_id),
  validation_run_id uuid references s2t_fhir.validation_run(validation_run_id),
  published_candidate_lifecycle_event_id uuid
    references s2t_fhir.baseline_lifecycle_event(baseline_lifecycle_event_id),
  validation_attempt_id uuid,
  validation_lease_expires_at timestamptz,
  last_error_code text,
  last_error_reference uuid,
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null default pg_catalog.transaction_timestamp(),
  constraint candidate_import_request_idempotency_uq
    unique (uploader_principal_id, resource_config_id, idempotency_key),
  constraint candidate_import_request_storage_object_uq unique (storage_object_key),
  constraint candidate_import_request_expected_pair_ck check (
    (expected_candidate_baseline_version_id is null) =
    (expected_candidate_lifecycle_event_id is null)
  ),
  constraint candidate_import_request_text_ck check (
    nullif(pg_catalog.btrim(version_label), '') is not null
    and pg_catalog.char_length(version_label) <= 120
    and version_label !~ '[[:cntrl:]]'
    and nullif(pg_catalog.btrim(original_filename), '') is not null
    and nullif(pg_catalog.btrim(storage_object_key), '') is not null
  ),
  constraint candidate_import_request_size_ck check (
    declared_byte_size between 1 and 10485760
  ),
  constraint candidate_import_request_state_ck check (current_state in (
    'AWAITING_UPLOAD', 'UPLOADED', 'VALIDATING', 'READY_TO_PUBLISH',
    'PUBLISHED', 'VALIDATION_FAILED', 'FAILED', 'ABORTED'
  )),
  constraint candidate_import_request_lease_pair_ck check (
    (validation_attempt_id is null) = (validation_lease_expires_at is null)
  ),
  constraint candidate_import_request_link_shape_ck check (
    (current_state not in ('UPLOADED', 'VALIDATING', 'READY_TO_PUBLISH', 'PUBLISHED')
         or artifact_id is not null)
    and (current_state not in ('VALIDATING', 'READY_TO_PUBLISH', 'PUBLISHED')
         or (baseline_version_id is not null and import_run_id is not null))
    and (current_state not in ('READY_TO_PUBLISH', 'PUBLISHED')
         or validation_run_id is not null)
    and (current_state <> 'PUBLISHED'
         or published_candidate_lifecycle_event_id is not null)
    and (current_state = 'VALIDATING'
         or (validation_attempt_id is null and validation_lease_expires_at is null))
  ),
  constraint candidate_import_request_time_ck check (updated_at >= created_at),
  constraint candidate_import_request_error_text_ck check (
    last_error_code is null or nullif(pg_catalog.btrim(last_error_code), '') is not null
  )
);

create unique index candidate_import_request_live_series_label_uq
  on s2t_fhir.candidate_import_request (baseline_series_id, version_label)
  where current_state in (
    'AWAITING_UPLOAD', 'UPLOADED', 'VALIDATING', 'READY_TO_PUBLISH'
  );

create index candidate_import_request_owner_idx
  on s2t_fhir.candidate_import_request
  (uploader_principal_id, created_at desc, candidate_import_request_id);

create index candidate_import_request_state_idx
  on s2t_fhir.candidate_import_request
  (current_state, updated_at, candidate_import_request_id);

create table s2t_fhir.candidate_import_request_event (
  candidate_import_request_event_id uuid primary key default pg_catalog.gen_random_uuid(),
  candidate_import_request_id uuid not null
    references s2t_fhir.candidate_import_request(candidate_import_request_id),
  sequence_number integer not null,
  event_code text not null,
  from_state text,
  to_state text not null,
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default pg_catalog.transaction_timestamp(),
  actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  initiating_human_principal_id uuid references s2t_fhir.principal(principal_id),
  correlation_id uuid not null,
  reason text,
  error_code text,
  detail_schema_id text,
  detail_schema_version integer,
  detail_json jsonb,
  constraint candidate_import_request_event_sequence_uq
    unique (candidate_import_request_id, sequence_number),
  constraint candidate_import_request_event_sequence_ck check (sequence_number > 0),
  constraint candidate_import_request_event_state_ck check (
    (from_state is null or from_state in (
      'AWAITING_UPLOAD', 'UPLOADED', 'VALIDATING', 'READY_TO_PUBLISH',
      'PUBLISHED', 'VALIDATION_FAILED', 'FAILED', 'ABORTED'
    ))
    and to_state in (
      'AWAITING_UPLOAD', 'UPLOADED', 'VALIDATING', 'READY_TO_PUBLISH',
      'PUBLISHED', 'VALIDATION_FAILED', 'FAILED', 'ABORTED'
    )
  ),
  constraint candidate_import_request_event_text_ck check (
    nullif(pg_catalog.btrim(event_code), '') is not null
    and (reason is null or nullif(pg_catalog.btrim(reason), '') is not null)
    and (error_code is null or nullif(pg_catalog.btrim(error_code), '') is not null)
  ),
  constraint candidate_import_request_event_detail_ck check (
    (detail_json is null and detail_schema_id is null and detail_schema_version is null)
    or (detail_json is not null
        and pg_catalog.jsonb_typeof(detail_json) = 'object'
        and nullif(pg_catalog.btrim(detail_schema_id), '') is not null
        and detail_schema_version > 0)
  ),
  constraint candidate_import_request_event_time_ck check (recorded_at >= occurred_at)
);

create index candidate_import_request_event_time_idx
  on s2t_fhir.candidate_import_request_event
  (candidate_import_request_id, sequence_number desc);

create table s2t_fhir.candidate_import_staging_batch (
  candidate_import_staging_batch_id uuid primary key default pg_catalog.gen_random_uuid(),
  candidate_import_request_id uuid not null
    references s2t_fhir.candidate_import_request(candidate_import_request_id),
  validation_attempt_id uuid not null,
  batch_number integer not null,
  batch_digest bytea not null,
  row_count integer not null,
  encoded_byte_size integer not null,
  staged_at timestamptz not null default pg_catalog.transaction_timestamp(),
  service_actor_principal_id uuid not null references s2t_fhir.principal(principal_id),
  correlation_id uuid not null,
  constraint candidate_import_staging_batch_business_uq
    unique (candidate_import_request_id, validation_attempt_id, batch_number),
  constraint candidate_import_staging_batch_number_ck check (batch_number >= 0),
  constraint candidate_import_staging_batch_digest_ck check (
    pg_catalog.octet_length(batch_digest) = 32
  ),
  constraint candidate_import_staging_batch_size_ck check (
    row_count between 0 and 250
    and encoded_byte_size between 2 and 2097152
  )
);

create function s2t_fhir.validate_candidate_import_request()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_source_system text;
  v_fhir_resource text;
  v_series_source text;
  v_series_resource text;
  v_link_series uuid;
  v_link_baseline uuid;
begin
  select r.source_system, r.fhir_resource
    into v_source_system, v_fhir_resource
  from s2t_fhir.mapping_resource_registry r
  where r.resource_config_id = new.resource_config_id
    and r.is_enabled;
  if not found then
    raise exception 'FILE_SCHEMA_INVALID: resource configuration is absent or disabled'
      using errcode = '23514';
  end if;

  select bs.source_system, bs.fhir_resource
    into v_series_source, v_series_resource
  from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = new.baseline_series_id;
  if not found or v_series_source is distinct from v_source_system
     or v_series_resource is distinct from v_fhir_resource then
    raise exception 'FILE_SCHEMA_INVALID: request resource and baseline series do not match'
      using errcode = '23514';
  end if;

  if new.expected_candidate_baseline_version_id is not null then
    select bv.baseline_series_id, e.baseline_version_id
      into v_link_series, v_link_baseline
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e
      on e.baseline_lifecycle_event_id = new.expected_candidate_lifecycle_event_id
    where bv.baseline_version_id = new.expected_candidate_baseline_version_id;
    if not found or v_link_series <> new.baseline_series_id
       or v_link_baseline <> new.expected_candidate_baseline_version_id then
      raise exception 'CANDIDATE_CHANGED: expected Candidate identity crosses the request series'
        using errcode = '40001';
    end if;
  end if;

  if new.baseline_version_id is not null and not exists (
    select 1 from s2t_fhir.baseline_version bv
    where bv.baseline_version_id = new.baseline_version_id
      and bv.baseline_series_id = new.baseline_series_id
  ) then
    raise exception 'FILE_SCHEMA_INVALID: staged baseline crosses the request series'
      using errcode = '23514';
  end if;

  if new.import_run_id is not null and not exists (
    select 1 from s2t_fhir.import_run ir
    where ir.import_run_id = new.import_run_id
      and ir.baseline_version_id = new.baseline_version_id
      and ir.artifact_id = new.artifact_id
  ) then
    raise exception 'FILE_SCHEMA_INVALID: request import linkage is inconsistent'
      using errcode = '23514';
  end if;

  if new.validation_run_id is not null and not exists (
    select 1 from s2t_fhir.validation_run vr
    where vr.validation_run_id = new.validation_run_id
      and vr.import_run_id = new.import_run_id
      and vr.artifact_id = new.artifact_id
  ) then
    raise exception 'FILE_SCHEMA_INVALID: request validation linkage is inconsistent'
      using errcode = '23514';
  end if;

  if new.published_candidate_lifecycle_event_id is not null and not exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event e
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = v.reference_domain_id
    where e.baseline_lifecycle_event_id = new.published_candidate_lifecycle_event_id
      and e.baseline_version_id = new.baseline_version_id
      and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
      and v.value_code = 'CANDIDATE'
  ) then
    raise exception 'FILE_SCHEMA_INVALID: published Candidate lifecycle identity is inconsistent'
      using errcode = '23514';
  end if;

  return new;
end
$function$;

create function s2t_fhir_api._service_stage_candidate_import_batch(
  p_request_id uuid,
  p_validation_attempt_id uuid,
  p_batch_number integer,
  p_batch_digest bytea,
  p_rows jsonb,
  p_service_actor_id uuid,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_existing s2t_fhir.candidate_import_staging_batch%rowtype;
  v_row jsonb;
  v_count integer;
  v_encoded integer;
  v_kind_id uuid;
  v_disposition_id uuid;
  v_decision_id uuid;
  v_identity_id uuid;
  v_candidate_id uuid;
  v_mapping_id uuid;
  v_scope_id uuid;
  v_topic_id uuid;
  v_kind text;
  v_disposition text;
  v_logical_key text;
  v_components jsonb;
  v_source_hash bytea;
  v_subtype jsonb;
begin
  if p_batch_number < 0 or pg_catalog.octet_length(p_batch_digest) <> 32
     or pg_catalog.jsonb_typeof(p_rows) <> 'array' then
    raise exception 'FILE_SCHEMA_INVALID: invalid staging batch envelope'
      using errcode = '22023';
  end if;
  v_count := pg_catalog.jsonb_array_length(p_rows);
  v_encoded := pg_catalog.pg_column_size(p_rows);
  if v_count > 250 or v_encoded > 2097152 then
    raise exception 'FILE_TOO_LARGE: staging batch exceeds 250 rows or 2 MiB'
      using errcode = '22023';
  end if;

  select * into v_request from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id for update;
  if not found or v_request.current_state <> 'VALIDATING'
     or v_request.validation_attempt_id is distinct from p_validation_attempt_id
     or v_request.validation_lease_expires_at < pg_catalog.transaction_timestamp() then
    raise exception 'IMPORT_CONFLICT: validation attempt is absent, stale, or expired'
      using errcode = '23505';
  end if;

  select * into v_existing
  from s2t_fhir.candidate_import_staging_batch b
  where b.candidate_import_request_id = p_request_id
    and b.validation_attempt_id = p_validation_attempt_id
    and b.batch_number = p_batch_number;
  if found then
    if v_existing.batch_digest = p_batch_digest
       and v_existing.row_count = v_count
       and v_existing.encoded_byte_size = v_encoded then
      return pg_catalog.jsonb_build_object(
        'requestId', p_request_id, 'batchNumber', p_batch_number,
        'rowCount', v_count, 'idempotentReplay', true);
    end if;
    raise exception 'IMPORT_CONFLICT: staging batch replay digest differs'
      using errcode = '23505';
  end if;

  for v_row in select value from pg_catalog.jsonb_array_elements(p_rows)
  loop
    if pg_catalog.jsonb_typeof(v_row) <> 'object' then
      raise exception 'FILE_SCHEMA_INVALID: every staged row must be an object'
        using errcode = '23514';
    end if;
    v_kind := v_row ->> 'mappingKind';
    v_disposition := coalesce(v_row ->> 'candidateDisposition', 'ACCEPTED');
    v_logical_key := v_row ->> 'logicalKey';
    v_components := v_row -> 'logicalKeyComponents';
    v_subtype := v_row -> 'subtype';
    begin
      v_source_hash := pg_catalog.decode(v_row ->> 'sourceRowHash', 'hex');
    exception when others then
      raise exception 'FILE_SCHEMA_INVALID: source row hash must be lowercase hexadecimal'
        using errcode = '23514';
    end;
    if v_kind not in ('ELEMENT_MAPPING','STATUS_MAPPING_RULE','GOVERNANCE_GUIDANCE')
       or v_disposition not in ('ACCEPTED','QUARANTINED')
       or v_logical_key !~ '^me:v1:[0-9a-f]{64}$'
       or pg_catalog.jsonb_typeof(v_components) <> 'object'
       or pg_catalog.jsonb_typeof(v_row -> 'rawSourceRow') <> 'object'
       or pg_catalog.octet_length(v_source_hash) <> 32 then
      raise exception 'FILE_SCHEMA_INVALID: governed staged row identity is invalid'
        using errcode = '23514';
    end if;

    select rv.reference_value_id into strict v_kind_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'MAPPING_KIND' and rv.value_code = v_kind;
    select rv.reference_value_id into strict v_disposition_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'CANDIDATE_DISPOSITION' and rv.value_code = v_disposition;

    insert into s2t_fhir.import_candidate_row (
      import_run_id, mapping_kind_value_id, source_sheet_name,
      source_row_number, source_cell_range, raw_schema_id, raw_schema_version,
      raw_source_row, source_row_hash, normalization_algorithm_version,
      logical_key_algorithm_version, candidate_disposition_value_id,
      calculated_logical_key, logical_key_components_json
    ) values (
      v_request.import_run_id, v_kind_id, v_row ->> 'sourceSheetName',
      (v_row ->> 'sourceRowNumber')::integer, v_row ->> 'sourceCellRange',
      v_row ->> 'rawSchemaId', v_row ->> 'rawSchemaVersion',
      v_row -> 'rawSourceRow', v_source_hash,
      v_row ->> 'normalizationAlgorithmVersion',
      v_row ->> 'logicalKeyAlgorithmVersion', v_disposition_id,
      v_logical_key, v_components
    ) returning import_candidate_row_id into v_candidate_id;

    if v_disposition = 'ACCEPTED' then
      if nullif(v_row ->> 'decisionStatus', '') is null
         or pg_catalog.jsonb_typeof(v_subtype) <> 'object' then
        raise exception 'FILE_SCHEMA_INVALID: accepted row lacks decision status or subtype'
          using errcode = '23514';
      end if;
      select rv.reference_value_id into strict v_decision_id
      from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
      where rd.domain_code = 'DECISION_STATUS' and rv.value_code = v_row ->> 'decisionStatus';

      insert into s2t_fhir.logical_mapping_identity (
        mapping_kind_value_id, source_system, fhir_resource,
        key_algorithm_version, logical_key, key_components_json
      ) values (
        v_kind_id, 'CATO', 'MedicationRequest',
        v_row ->> 'logicalKeyAlgorithmVersion', v_logical_key, v_components
      ) on conflict on constraint logical_mapping_identity_business_uq do nothing;

      select l.logical_mapping_identity_id into strict v_identity_id
      from s2t_fhir.logical_mapping_identity l
      where l.mapping_kind_value_id = v_kind_id
        and l.source_system = 'CATO'
        and l.fhir_resource = 'MedicationRequest'
        and l.key_algorithm_version = v_row ->> 'logicalKeyAlgorithmVersion'
        and l.logical_key = v_logical_key;
      if (select l.key_components_json from s2t_fhir.logical_mapping_identity l
          where l.logical_mapping_identity_id = v_identity_id) is distinct from v_components then
        raise exception 'DUPLICATE_ROW_IDENTITY: logical key collides with different components'
          using errcode = '23505';
      end if;

      insert into s2t_fhir.mapping_record (
        baseline_version_id, import_candidate_row_id,
        logical_mapping_identity_id, mapping_kind_value_id,
        decision_status_value_id
      ) values (
        v_request.baseline_version_id, v_candidate_id,
        v_identity_id, v_kind_id, v_decision_id
      ) returning mapping_record_id into v_mapping_id;

      if v_kind = 'ELEMENT_MAPPING' then
        insert into s2t_fhir.element_mapping (
          mapping_record_id, target_fhir_path, source_system_raw,
          interface_type, interface_name, source_expression, profile_context,
          fixed_value, transformation_rule, source_business_definition,
          cardinality_raw, cardinality_min, cardinality_max,
          cardinality_max_unbounded, valueset_binding, mandated_code_system,
          irrelevant_under_s2t_raw, example_value, exception_handling, notes
        ) values (
          v_mapping_id, v_subtype ->> 'targetFhirPath',
          v_subtype ->> 'sourceSystemRaw', v_subtype ->> 'interfaceType',
          v_subtype ->> 'interfaceName', v_subtype ->> 'sourceExpression',
          v_subtype ->> 'profileContext', v_subtype ->> 'fixedValue',
          v_subtype ->> 'transformationRule', v_subtype ->> 'sourceBusinessDefinition',
          v_subtype ->> 'cardinalityRaw', nullif(v_subtype ->> 'cardinalityMin','')::integer,
          nullif(v_subtype ->> 'cardinalityMax','')::integer,
          coalesce((v_subtype ->> 'cardinalityMaxUnbounded')::boolean, false),
          v_subtype ->> 'valuesetBinding', v_subtype ->> 'mandatedCodeSystem',
          v_subtype ->> 'irrelevantUnderS2tRaw', v_subtype ->> 'exampleValue',
          v_subtype ->> 'exceptionHandling', v_subtype ->> 'notes'
        );
      elsif v_kind = 'STATUS_MAPPING_RULE' then
        insert into s2t_fhir.status_mapping_rule (
          mapping_record_id, source_status_value, target_fhir_path,
          target_status_value, source_sequence, source_business_definition,
          related_resource_note, transformation_rule,
          mapping_evidence_status_raw, notes
        ) values (
          v_mapping_id, v_subtype ->> 'sourceStatusValue',
          v_subtype ->> 'targetFhirPath', v_subtype ->> 'targetStatusValue',
          nullif(v_subtype ->> 'sourceSequence','')::integer,
          v_subtype ->> 'sourceBusinessDefinition',
          v_subtype ->> 'relatedResourceNote', v_subtype ->> 'transformationRule',
          v_subtype ->> 'mappingEvidenceStatusRaw', v_subtype ->> 'notes'
        );
      else
        select rv.reference_value_id into strict v_scope_id
        from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
        where rd.domain_code = 'GUIDANCE_SCOPE' and rv.value_code = v_subtype ->> 'guidanceScope';
        select rv.reference_value_id into strict v_topic_id
        from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
        where rd.domain_code = 'DECISION_TOPIC_CODE' and rv.value_code = v_subtype ->> 'decisionTopic';
        insert into s2t_fhir.governance_guidance (
          mapping_record_id, guidance_scope_value_id, decision_topic_value_id,
          guidance_text, guidance_status_raw, target_fhir_path_or_scope_raw,
          decision_topic_raw, notes, review_notes
        ) values (
          v_mapping_id, v_scope_id, v_topic_id,
          v_subtype ->> 'guidanceText', v_subtype ->> 'guidanceStatusRaw',
          v_subtype ->> 'targetFhirPathOrScopeRaw',
          v_subtype ->> 'decisionTopicRaw', v_subtype ->> 'notes',
          v_subtype ->> 'reviewNotes'
        );
      end if;
    end if;
  end loop;

  insert into s2t_fhir.candidate_import_staging_batch (
    candidate_import_request_id, validation_attempt_id, batch_number,
    batch_digest, row_count, encoded_byte_size,
    service_actor_principal_id, correlation_id
  ) values (
    p_request_id, p_validation_attempt_id, p_batch_number,
    p_batch_digest, v_count, v_encoded,
    p_service_actor_id, p_correlation_id
  );
  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id, 'batchNumber', p_batch_number,
    'rowCount', v_count, 'idempotentReplay', false);
exception
  when unique_violation then
    raise exception 'DUPLICATE_ROW_IDENTITY: staged source location or logical identity is duplicated'
      using errcode = '23505';
end
$function$;

create function s2t_fhir_api.get_my_candidate_import(
  p_candidate_import_request_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_actor uuid;
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_digest text;
  v_size bigint;
  v_counts jsonb;
  v_current jsonb;
begin
  v_actor := s2t_fhir_api._resolve_authenticated_principal();
  select * into v_request
  from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_candidate_import_request_id
    and r.uploader_principal_id = v_actor;
  if not found then
    raise exception 'IMPORT_CONFLICT: Candidate import request is not accessible'
      using errcode = '42501';
  end if;

  if v_request.artifact_id is not null then
    select pg_catalog.encode(a.sha256_digest, 'hex'), a.byte_size
      into v_digest, v_size
    from s2t_fhir.artifact a where a.artifact_id = v_request.artifact_id;
  end if;
  if v_request.validation_run_id is not null then
    select pg_catalog.jsonb_build_object(
      'candidateCount', vr.candidate_count,
      'acceptedCount', vr.accepted_count,
      'warningCount', vr.warning_count,
      'errorCount', vr.error_count,
      'quarantinedCount', vr.quarantined_count,
      'outcome', outcome.value_code
    ) into v_counts
    from s2t_fhir.validation_run vr
    join s2t_fhir.reference_value outcome
      on outcome.reference_value_id = vr.outcome_value_id
    where vr.validation_run_id = v_request.validation_run_id;
  end if;
  v_current := s2t_fhir_api._candidate_ui_snapshot(v_request.resource_config_id) -> 'candidate';

  return pg_catalog.jsonb_build_object(
    'requestId', v_request.candidate_import_request_id,
    'state', v_request.current_state,
    'resourceConfigId', v_request.resource_config_id,
    'filename', v_request.original_filename,
    'versionLabel', v_request.version_label,
    'digest', v_digest,
    'byteSize', v_size,
    'identicalContent', case when v_request.artifact_id is null then null else exists (
      select 1 from s2t_fhir.artifact_location al
      where al.artifact_id = v_request.artifact_id
      group by al.artifact_id having count(*) > 1
    ) end,
    'counts', coalesce(v_counts, 'null'::jsonb),
    'initialCandidate', pg_catalog.jsonb_build_object(
      'baselineVersionId', v_request.expected_candidate_baseline_version_id,
      'lifecycleEventId', v_request.expected_candidate_lifecycle_event_id),
    'currentCandidate', v_current,
    'retryable', v_request.current_state in ('AWAITING_UPLOAD','UPLOADED','VALIDATING','READY_TO_PUBLISH'),
    'publishedCandidate', case when v_request.current_state = 'PUBLISHED' then
      pg_catalog.jsonb_build_object(
        'baselineVersionId', v_request.baseline_version_id,
        'lifecycleEventId', v_request.published_candidate_lifecycle_event_id)
      else 'null'::jsonb end,
    'createdAt', v_request.created_at,
    'updatedAt', v_request.updated_at,
    'errorCode', v_request.last_error_code,
    'errorReference', v_request.last_error_reference
  );
end
$function$;

create function s2t_fhir_api._service_accept_candidate_import_upload(
  p_request_id uuid,
  p_sha256_digest bytea,
  p_byte_size bigint,
  p_media_type text,
  p_observed_at timestamptz,
  p_service_actor_id uuid,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_artifact_id uuid;
  v_existing_size bigint;
  v_reused boolean := false;
  v_kind_id uuid;
  v_location_kind_id uuid;
  v_available_id uuid;
begin
  if pg_catalog.octet_length(p_sha256_digest) <> 32 then
    raise exception 'FILE_SCHEMA_INVALID: SHA-256 digest must be 32 bytes'
      using errcode = '22023';
  end if;
  if p_media_type <> 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' then
    raise exception 'FILE_TYPE_INVALID: unsupported workbook media type'
      using errcode = '22023';
  end if;
  if p_observed_at is null or p_observed_at > pg_catalog.transaction_timestamp() then
    raise exception 'FILE_SCHEMA_INVALID: upload observation time is invalid'
      using errcode = '22023';
  end if;

  select * into v_request from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id for update;
  if not found then
    raise exception 'IMPORT_CONFLICT: Candidate import request does not exist'
      using errcode = 'P0002';
  end if;
  if p_byte_size <> v_request.declared_byte_size then
    raise exception 'IMPORT_CONFLICT: authoritative byte size differs from declared byte size'
      using errcode = '23505';
  end if;
  if v_request.current_state = 'UPLOADED' then
    if exists (select 1 from s2t_fhir.artifact a
               where a.artifact_id = v_request.artifact_id
                 and a.sha256_digest = p_sha256_digest and a.byte_size = p_byte_size) then
      return pg_catalog.jsonb_build_object(
        'requestId', p_request_id, 'state', 'UPLOADED',
        'artifactId', v_request.artifact_id, 'idempotentReplay', true);
    end if;
    raise exception 'IMPORT_CONFLICT: upload completion replay has different bytes'
      using errcode = '23505';
  elsif v_request.current_state <> 'AWAITING_UPLOAD' then
    raise exception 'IMPORT_CONFLICT: upload acceptance requires AWAITING_UPLOAD'
      using errcode = '23505';
  end if;

  select a.artifact_id, a.byte_size into v_artifact_id, v_existing_size
  from s2t_fhir.artifact a where a.sha256_digest = p_sha256_digest;
  if found then
    if v_existing_size <> p_byte_size then
      raise exception 'IMPORT_CONFLICT: content digest exists with a different byte size'
        using errcode = '23505';
    end if;
    v_reused := true;
  else
    select rv.reference_value_id into strict v_kind_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'ARTIFACT_KIND' and rv.value_code = 'WORKBOOK'
      and rv.effective_at <= pg_catalog.transaction_timestamp()
      and (rv.retired_at is null or rv.retired_at > pg_catalog.transaction_timestamp());
    insert into s2t_fhir.artifact (
      artifact_kind_value_id, sha256_digest, byte_size, media_type,
      physical_filename, original_or_upload_name, captured_at,
      description, created_by_principal_id
    ) values (
      v_kind_id, p_sha256_digest, p_byte_size, p_media_type,
      'source.xlsx', v_request.original_filename, p_observed_at,
      'Candidate workbook upload ' || p_request_id::text, p_service_actor_id
    ) returning artifact_id into v_artifact_id;
  end if;

  select rv.reference_value_id into strict v_location_kind_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'ARTIFACT_LOCATION_KIND' and rv.value_code = 'OBJECT_STORAGE';
  select rv.reference_value_id into strict v_available_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'ARTIFACT_AVAILABILITY' and rv.value_code = 'AVAILABLE';
  insert into s2t_fhir.artifact_location (
    artifact_id, location_kind_value_id, location_uri, observed_at,
    actor_principal_id, initiating_human_principal_id,
    availability_status_value_id, note
  ) values (
    v_artifact_id, v_location_kind_id,
    's2t-candidate-imports/' || v_request.storage_object_key,
    p_observed_at, p_service_actor_id, v_request.uploader_principal_id,
    v_available_id, 'Private Candidate import upload observation'
  );

  update s2t_fhir.candidate_import_request r
  set artifact_id = v_artifact_id
  where r.candidate_import_request_id = p_request_id;
  perform s2t_fhir._transition_candidate_import_request(
    p_request_id, 'AWAITING_UPLOAD', 'UPLOADED', 'UPLOAD_ACCEPTED',
    p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
    null, null, 'candidate-import-upload', 1,
    pg_catalog.jsonb_build_object('artifactId', v_artifact_id, 'artifactReused', v_reused)
  );
  if v_reused then
    perform s2t_fhir._transition_candidate_import_request(
      p_request_id, 'UPLOADED', 'UPLOADED', 'ARTIFACT_REUSED',
      p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
      'Identical workbook bytes reuse an existing artifact', null,
      'candidate-import-upload', 1,
      pg_catalog.jsonb_build_object('artifactId', v_artifact_id)
    );
  end if;
  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id, 'state', 'UPLOADED',
    'artifactId', v_artifact_id, 'artifactReused', v_reused,
    'idempotentReplay', false);
end
$function$;

create function s2t_fhir_api._service_begin_candidate_import_validation(
  p_request_id uuid,
  p_parser_name text,
  p_parser_version text,
  p_import_specification_version text,
  p_configuration_digest bytea,
  p_validation_attempt_id uuid,
  p_lease_expires_at timestamptz,
  p_service_actor_id uuid,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_baseline_id uuid;
  v_import_id uuid;
  v_policy_id uuid;
  v_role_id uuid;
  v_importer_version text;
begin
  if nullif(pg_catalog.btrim(p_parser_name), '') is null
     or nullif(pg_catalog.btrim(p_parser_version), '') is null
     or p_import_specification_version <> 'CATO-MEDICATIONREQUEST-XLSX-v1'
     or pg_catalog.octet_length(p_configuration_digest) <> 32
     or p_validation_attempt_id is null
     or p_lease_expires_at <= pg_catalog.transaction_timestamp() then
    raise exception 'FILE_SCHEMA_INVALID: validation metadata is invalid'
      using errcode = '22023';
  end if;
  v_importer_version := pg_catalog.btrim(p_parser_name) || '@' || pg_catalog.btrim(p_parser_version);

  select * into v_request from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id for update;
  if not found then
    raise exception 'IMPORT_CONFLICT: Candidate import request does not exist'
      using errcode = 'P0002';
  end if;

  if v_request.current_state = 'VALIDATING' then
    if v_request.validation_attempt_id = p_validation_attempt_id then
      return pg_catalog.jsonb_build_object(
        'requestId', p_request_id, 'state', 'VALIDATING',
        'validationAttemptId', p_validation_attempt_id,
        'baselineVersionId', v_request.baseline_version_id,
        'importRunId', v_request.import_run_id, 'idempotentReplay', true);
    end if;
    if v_request.validation_lease_expires_at >= pg_catalog.transaction_timestamp() then
      raise exception 'IMPORT_CONFLICT: another validation attempt owns the active lease'
        using errcode = '23505';
    end if;
    update s2t_fhir.candidate_import_request r
    set validation_attempt_id = p_validation_attempt_id,
        validation_lease_expires_at = p_lease_expires_at
    where r.candidate_import_request_id = p_request_id;
    perform s2t_fhir._transition_candidate_import_request(
      p_request_id, 'VALIDATING', 'VALIDATING', 'VALIDATION_RECLAIMED',
      p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
      'Expired validation lease reclaimed', null,
      'candidate-import-validation', 1,
      pg_catalog.jsonb_build_object('validationAttemptId', p_validation_attempt_id)
    );
    return pg_catalog.jsonb_build_object(
      'requestId', p_request_id, 'state', 'VALIDATING',
      'validationAttemptId', p_validation_attempt_id,
      'baselineVersionId', v_request.baseline_version_id,
      'importRunId', v_request.import_run_id, 'reclaimed', true);
  elsif v_request.current_state <> 'UPLOADED' then
    raise exception 'IMPORT_CONFLICT: validation requires UPLOADED'
      using errcode = '23505';
  end if;

  if exists (select 1 from s2t_fhir.baseline_version bv
             where bv.baseline_series_id = v_request.baseline_series_id
               and bv.version_label = v_request.version_label) then
    raise exception 'VERSION_LABEL_CONFLICT: version label is already used'
      using errcode = '23505';
  end if;
  v_baseline_id := pg_catalog.gen_random_uuid();
  insert into s2t_fhir.baseline_version (
    baseline_version_id, baseline_series_id, baseline_code, version_label,
    is_gold_standard, import_specification_version, description,
    created_by_principal_id
  ) values (
    v_baseline_id, v_request.baseline_series_id,
    'CANDIDATE-IMPORT-' || v_request.candidate_import_request_id::text,
    v_request.version_label, false, p_import_specification_version,
    'Staged Candidate workbook import ' || v_request.candidate_import_request_id::text,
    v_request.uploader_principal_id
  );
  select rv.reference_value_id into strict v_role_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'ARTIFACT_ROLE' and rv.value_code = 'AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.baseline_artifact (
    baseline_version_id, artifact_id, artifact_role_value_id,
    note, created_by_principal_id
  ) values (
    v_baseline_id, v_request.artifact_id, v_role_id,
    'Authoritative Candidate workbook upload', v_request.uploader_principal_id
  );
  select rv.reference_value_id into strict v_policy_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'IMPORT_POLICY' and rv.value_code = 'CLEAN_IMPORT';
  insert into s2t_fhir.import_run (
    baseline_version_id, artifact_id, import_policy_value_id,
    import_specification_version, importer_version, configuration_digest,
    started_at, actor_principal_id, initiating_human_principal_id
  ) values (
    v_baseline_id, v_request.artifact_id, v_policy_id,
    p_import_specification_version, v_importer_version, p_configuration_digest,
    pg_catalog.transaction_timestamp(), p_service_actor_id,
    v_request.uploader_principal_id
  ) returning import_run_id into v_import_id;
  update s2t_fhir.candidate_import_request r
  set baseline_version_id = v_baseline_id,
      import_run_id = v_import_id,
      validation_attempt_id = p_validation_attempt_id,
      validation_lease_expires_at = p_lease_expires_at
  where r.candidate_import_request_id = p_request_id;
  perform s2t_fhir._transition_candidate_import_request(
    p_request_id, 'UPLOADED', 'VALIDATING', 'VALIDATION_STARTED',
    p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
    null, null, 'candidate-import-validation', 1,
    pg_catalog.jsonb_build_object(
      'parserName', p_parser_name, 'parserVersion', p_parser_version,
      'importSpecificationVersion', p_import_specification_version,
      'validationAttemptId', p_validation_attempt_id)
  );
  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id, 'state', 'VALIDATING',
    'validationAttemptId', p_validation_attempt_id,
    'baselineVersionId', v_baseline_id, 'importRunId', v_import_id,
    'idempotentReplay', false);
end
$function$;

create trigger candidate_import_request_validate_trg
before insert or update on s2t_fhir.candidate_import_request
for each row execute function s2t_fhir.validate_candidate_import_request();

create trigger candidate_import_request_event_append_only_trg
before update or delete on s2t_fhir.candidate_import_request_event
for each row execute function s2t_fhir.reject_append_only_change();

create trigger candidate_import_staging_batch_append_only_trg
before update or delete on s2t_fhir.candidate_import_staging_batch
for each row execute function s2t_fhir.reject_append_only_change();

create function s2t_fhir._transition_candidate_import_request(
  p_request_id uuid,
  p_expected_state text,
  p_new_state text,
  p_event_code text,
  p_actor_principal_id uuid,
  p_initiating_human_principal_id uuid,
  p_correlation_id uuid,
  p_reason text default null,
  p_error_code text default null,
  p_detail_schema_id text default null,
  p_detail_schema_version integer default null,
  p_detail_json jsonb default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_sequence integer;
  v_allowed boolean := false;
begin
  select * into v_request
  from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id
  for update;
  if not found then
    raise exception 'IMPORT_CONFLICT: Candidate import request does not exist'
      using errcode = 'P0002';
  end if;
  if v_request.current_state is distinct from p_expected_state then
    raise exception 'IMPORT_CONFLICT: expected request state %, found %',
      p_expected_state, v_request.current_state using errcode = '23505';
  end if;
  if v_request.current_state in ('PUBLISHED','VALIDATION_FAILED','FAILED','ABORTED') then
    raise exception 'IMPORT_CONFLICT: terminal Candidate import request is immutable'
      using errcode = '55000';
  end if;

  v_allowed := (p_expected_state, p_new_state) in (
    ('AWAITING_UPLOAD','UPLOADED'),
    ('AWAITING_UPLOAD','VALIDATION_FAILED'),
    ('AWAITING_UPLOAD','FAILED'),
    ('AWAITING_UPLOAD','ABORTED'),
    ('UPLOADED','VALIDATING'),
    ('UPLOADED','VALIDATION_FAILED'),
    ('UPLOADED','FAILED'),
    ('UPLOADED','ABORTED'),
    ('VALIDATING','READY_TO_PUBLISH'),
    ('VALIDATING','VALIDATION_FAILED'),
    ('VALIDATING','FAILED'),
    ('READY_TO_PUBLISH','PUBLISHED'),
    ('READY_TO_PUBLISH','ABORTED')
  );
  if p_expected_state = p_new_state then
    v_allowed := p_event_code in ('IDEMPOTENT_REPLAY','ARTIFACT_REUSED','VALIDATION_RECLAIMED');
  end if;
  if not v_allowed then
    raise exception 'IMPORT_CONFLICT: forbidden Candidate import transition % -> %',
      p_expected_state, p_new_state using errcode = '23514';
  end if;

  select coalesce(max(e.sequence_number), 0) + 1 into v_sequence
  from s2t_fhir.candidate_import_request_event e
  where e.candidate_import_request_id = p_request_id;

  insert into s2t_fhir.candidate_import_request_event (
    candidate_import_request_id, sequence_number, event_code,
    from_state, to_state, occurred_at, actor_principal_id,
    initiating_human_principal_id, correlation_id, reason, error_code,
    detail_schema_id, detail_schema_version, detail_json
  ) values (
    p_request_id, v_sequence, p_event_code,
    p_expected_state, p_new_state, pg_catalog.transaction_timestamp(),
    p_actor_principal_id, p_initiating_human_principal_id,
    p_correlation_id, p_reason, p_error_code,
    p_detail_schema_id, p_detail_schema_version, p_detail_json
  );

  update s2t_fhir.candidate_import_request r
  set current_state = p_new_state,
      validation_attempt_id = case when p_new_state = 'VALIDATING'
                                   then r.validation_attempt_id else null end,
      validation_lease_expires_at = case when p_new_state = 'VALIDATING'
                                         then r.validation_lease_expires_at else null end,
      last_error_code = case when p_error_code is null then r.last_error_code else p_error_code end,
      updated_at = pg_catalog.transaction_timestamp()
  where r.candidate_import_request_id = p_request_id;

  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id,
    'state', p_new_state,
    'sequenceNumber', v_sequence,
    'eventCode', p_event_code
  );
end
$function$;

create function s2t_fhir._candidate_ui_upload_capability(p_principal_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_count integer;
begin
  select count(*) into v_count
  from s2t_fhir.baseline_action_authorization a
  where a.principal_id = p_principal_id
    and a.capability_code = 'S2T_BASELINE_UPLOAD'
    and a.effective_at <= pg_catalog.transaction_timestamp()
    and a.revoked_at is null;
  if v_count > 1 then
    raise exception 'CAPABILITY_REQUIRED: authenticated principal upload authorization is ambiguous'
      using errcode = '42501';
  end if;
  return v_count = 1;
end
$function$;

create or replace function s2t_fhir_api.get_my_candidate_ui_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_principal_id uuid;
  v_can_review boolean;
  v_can_promote boolean;
  v_can_upload boolean;
begin
  v_principal_id := s2t_fhir_api._resolve_authenticated_principal();
  select c.can_review_candidate, c.can_promote_candidate
    into strict v_can_review, v_can_promote
  from s2t_fhir_api._candidate_ui_capability_state(v_principal_id) c;
  v_can_upload := s2t_fhir._candidate_ui_upload_capability(v_principal_id);
  return pg_catalog.jsonb_build_object(
    'canReviewCandidate', v_can_review,
    'canPromoteCandidate', v_can_promote,
    'canUploadCandidate', v_can_upload
  );
end
$function$;

create or replace function s2t_fhir_api.get_candidate_ui_context(
  p_resource_config_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_principal_id uuid;
  v_can_review boolean;
  v_can_promote boolean;
  v_can_upload boolean;
begin
  v_principal_id := s2t_fhir_api._resolve_authenticated_principal();
  select c.can_review_candidate, c.can_promote_candidate
    into strict v_can_review, v_can_promote
  from s2t_fhir_api._candidate_ui_capability_state(v_principal_id) c;
  v_can_upload := s2t_fhir._candidate_ui_upload_capability(v_principal_id);
  if not v_can_review and not v_can_promote and not v_can_upload then
    raise exception 'CAPABILITY_REQUIRED: authenticated principal lacks Candidate UI access'
      using errcode = '42501';
  end if;
  return s2t_fhir_api._candidate_ui_snapshot(p_resource_config_id);
end
$function$;

create function s2t_fhir_api.begin_candidate_import(
  p_resource_config_id text,
  p_version_label text,
  p_original_filename text,
  p_declared_byte_size bigint,
  p_idempotency_key uuid,
  p_expected_candidate_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor uuid;
  v_label text;
  v_filename text;
  v_existing s2t_fhir.candidate_import_request%rowtype;
  v_source text;
  v_resource text;
  v_series_count integer;
  v_series_id uuid;
  v_candidate_count integer;
  v_candidate_baseline uuid;
  v_candidate_event uuid;
  v_request_id uuid := pg_catalog.gen_random_uuid();
  v_storage_key text;
begin
  v_actor := s2t_fhir_api._require_authenticated_baseline_capability('S2T_BASELINE_UPLOAD');
  v_label := pg_catalog.btrim(pg_catalog.normalize(p_version_label, 'NFKC'));
  v_filename := pg_catalog.btrim(p_original_filename);

  if p_idempotency_key is null then
    raise exception 'IMPORT_CONFLICT: idempotency key is required' using errcode = '22023';
  end if;
  if nullif(v_label, '') is null or pg_catalog.char_length(v_label) > 120
     or v_label ~ '[[:cntrl:]]' then
    raise exception 'VERSION_LABEL_CONFLICT: invalid version label' using errcode = '22023';
  end if;
  if nullif(v_filename, '') is null then
    raise exception 'FILE_TYPE_INVALID: original filename is required' using errcode = '22023';
  end if;
  if pg_catalog.lower(v_filename) !~ '\.xlsx$' then
    raise exception 'FILE_TYPE_INVALID: only .xlsx uploads are accepted' using errcode = '22023';
  end if;
  if p_declared_byte_size not between 1 and 10485760 then
    raise exception 'FILE_TOO_LARGE: declared workbook size must be between 1 and 10485760 bytes'
      using errcode = '22023';
  end if;
  if (p_expected_candidate_baseline_version_id is null) <>
     (p_expected_candidate_lifecycle_event_id is null) then
    raise exception 'CANDIDATE_CHANGED: expected Candidate IDs must be both null or both non-null'
      using errcode = '40001';
  end if;

  select * into v_existing
  from s2t_fhir.candidate_import_request r
  where r.uploader_principal_id = v_actor
    and r.resource_config_id = p_resource_config_id
    and r.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.version_label is distinct from v_label
       or v_existing.original_filename is distinct from v_filename
       or v_existing.declared_byte_size is distinct from p_declared_byte_size
       or v_existing.expected_candidate_baseline_version_id is distinct from p_expected_candidate_baseline_version_id
       or v_existing.expected_candidate_lifecycle_event_id is distinct from p_expected_candidate_lifecycle_event_id then
      raise exception 'IMPORT_CONFLICT: idempotency key was already used with different input'
        using errcode = '23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'requestId', v_existing.candidate_import_request_id,
      'state', v_existing.current_state,
      'resourceConfigId', v_existing.resource_config_id,
      'versionLabel', v_existing.version_label,
      'originalFilename', v_existing.original_filename,
      'declaredByteSize', v_existing.declared_byte_size,
      'candidateSnapshot', pg_catalog.jsonb_build_object(
        'baselineVersionId', v_existing.expected_candidate_baseline_version_id,
        'lifecycleEventId', v_existing.expected_candidate_lifecycle_event_id
      ),
      'createdAt', v_existing.created_at,
      'idempotentReplay', true
    );
  end if;

  select r.source_system, r.fhir_resource into v_source, v_resource
  from s2t_fhir.mapping_resource_registry r
  where r.resource_config_id = p_resource_config_id and r.is_enabled;
  if not found or p_resource_config_id <> 'medication-request-cato'
     or v_source <> 'CATO' or v_resource <> 'MedicationRequest' then
    raise exception 'FILE_SCHEMA_INVALID: unsupported or disabled resource configuration'
      using errcode = '22023';
  end if;

  select count(*), (pg_catalog.array_agg(bs.baseline_series_id))[1]
    into v_series_count, v_series_id
  from s2t_fhir.baseline_series bs
  where bs.source_system = v_source and bs.fhir_resource = v_resource;
  if v_series_count <> 1 then
    raise exception 'FILE_SCHEMA_INVALID: canonical baseline series is absent or ambiguous'
      using errcode = '23514';
  end if;
  perform 1 from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = v_series_id for update;

  select count(*),
         (pg_catalog.array_agg(bv.baseline_version_id))[1],
         (pg_catalog.array_agg(e.baseline_lifecycle_event_id))[1]
    into v_candidate_count, v_candidate_baseline, v_candidate_event
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event e on e.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value rv on rv.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain rd on rd.reference_domain_id = rv.reference_domain_id
  where bv.baseline_series_id = v_series_id
    and rd.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and rv.value_code in ('CANDIDATE','PENDING_APPROVAL')
    and not exists (select 1 from s2t_fhir.baseline_lifecycle_event successor
                    where successor.supersedes_event_id = e.baseline_lifecycle_event_id);
  if v_candidate_count > 1 then
    raise exception 'FILE_SCHEMA_INVALID: multiple current Candidate baselines'
      using errcode = '23514';
  end if;
  if p_expected_candidate_baseline_version_id is null then
    if v_candidate_count <> 0 then
      raise exception 'CANDIDATE_CHANGED: expected no current Candidate'
        using errcode = '40001';
    end if;
  elsif v_candidate_count <> 1
        or v_candidate_baseline is distinct from p_expected_candidate_baseline_version_id
        or v_candidate_event is distinct from p_expected_candidate_lifecycle_event_id then
    raise exception 'CANDIDATE_CHANGED: expected Candidate does not match current Candidate'
      using errcode = '40001';
  end if;

  if exists (select 1 from s2t_fhir.baseline_version bv
             where bv.baseline_series_id = v_series_id and bv.version_label = v_label)
     or exists (select 1 from s2t_fhir.candidate_import_request r
                where r.baseline_series_id = v_series_id and r.version_label = v_label
                  and r.current_state in ('AWAITING_UPLOAD','UPLOADED','VALIDATING','READY_TO_PUBLISH')) then
    raise exception 'VERSION_LABEL_CONFLICT: version label is already reserved'
      using errcode = '23505';
  end if;

  v_storage_key := 'medication-request-cato/' || v_request_id::text || '/source.xlsx';
  insert into s2t_fhir.candidate_import_request (
    candidate_import_request_id, resource_config_id, baseline_series_id,
    uploader_principal_id, version_label, original_filename,
    declared_byte_size, idempotency_key,
    expected_candidate_baseline_version_id, expected_candidate_lifecycle_event_id,
    storage_object_key, current_state
  ) values (
    v_request_id, p_resource_config_id, v_series_id, v_actor, v_label,
    v_filename, p_declared_byte_size, p_idempotency_key,
    p_expected_candidate_baseline_version_id, p_expected_candidate_lifecycle_event_id,
    v_storage_key, 'AWAITING_UPLOAD'
  );
  insert into s2t_fhir.candidate_import_request_event (
    candidate_import_request_id, sequence_number, event_code, from_state,
    to_state, occurred_at, actor_principal_id, initiating_human_principal_id,
    correlation_id, detail_schema_id, detail_schema_version, detail_json
  ) values (
    v_request_id, 1, 'REQUEST_CREATED', null, 'AWAITING_UPLOAD',
    pg_catalog.transaction_timestamp(), v_actor, v_actor, p_idempotency_key,
    'candidate-import-request', 1,
    pg_catalog.jsonb_build_object('resourceConfigId', p_resource_config_id)
  );
  return pg_catalog.jsonb_build_object(
    'requestId', v_request_id, 'state', 'AWAITING_UPLOAD',
    'resourceConfigId', p_resource_config_id, 'versionLabel', v_label,
    'originalFilename', v_filename, 'declaredByteSize', p_declared_byte_size,
    'candidateSnapshot', pg_catalog.jsonb_build_object(
      'baselineVersionId', p_expected_candidate_baseline_version_id,
      'lifecycleEventId', p_expected_candidate_lifecycle_event_id),
    'createdAt', pg_catalog.transaction_timestamp(), 'idempotentReplay', false
  );
end
$function$;

create function s2t_fhir_api._service_complete_candidate_import_validation(
  p_request_id uuid,
  p_validation_attempt_id uuid,
  p_sheet_manifest jsonb,
  p_findings jsonb,
  p_summary jsonb,
  p_execution_fingerprint bytea,
  p_service_actor_id uuid,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_artifact_digest bytea;
  v_ruleset_id uuid;
  v_validation_id uuid;
  v_outcome_id uuid;
  v_outcome text;
  v_candidate_count bigint;
  v_accepted_count bigint;
  v_warning_count bigint;
  v_error_count bigint;
  v_quarantined_count bigint;
  v_actual_candidates bigint;
  v_actual_accepted bigint;
  v_actual_quarantined bigint;
  v_actual_mappings bigint;
  v_manifest jsonb;
  v_finding jsonb;
  v_rule_id uuid;
  v_severity_id uuid;
  v_finding_id uuid;
  v_subject_role_id uuid;
  v_candidate_id uuid;
  v_metric record;
  v_metric_id uuid;
  v_quarantine_event_type_id uuid;
  v_quarantine_case_id uuid;
  v_opening_finding_id uuid;
  v_failed_import_status_id uuid;
  v_quarantined record;
  v_clean boolean;
  v_failure_code text;
  v_failure_message text;
begin
  if pg_catalog.jsonb_typeof(p_sheet_manifest) <> 'array'
     or pg_catalog.jsonb_typeof(p_findings) <> 'array'
     or pg_catalog.jsonb_typeof(p_summary) <> 'object'
     or pg_catalog.octet_length(p_execution_fingerprint) <> 32 then
    raise exception 'FILE_SCHEMA_INVALID: validation completion envelope is invalid'
      using errcode = '22023';
  end if;
  select * into v_request from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id for update;
  if not found or v_request.current_state <> 'VALIDATING'
     or v_request.validation_attempt_id is distinct from p_validation_attempt_id
     or v_request.validation_lease_expires_at < pg_catalog.transaction_timestamp() then
    raise exception 'IMPORT_CONFLICT: validation completion attempt is stale or expired'
      using errcode = '23505';
  end if;
  select a.sha256_digest into strict v_artifact_digest
  from s2t_fhir.artifact a where a.artifact_id = v_request.artifact_id;

  v_candidate_count := (p_summary ->> 'candidateCount')::bigint;
  v_accepted_count := (p_summary ->> 'acceptedCount')::bigint;
  v_warning_count := (p_summary ->> 'warningCount')::bigint;
  v_error_count := (p_summary ->> 'errorCount')::bigint;
  v_quarantined_count := (p_summary ->> 'quarantinedCount')::bigint;
  if least(v_candidate_count, v_accepted_count, v_warning_count,
           v_error_count, v_quarantined_count) < 0 then
    raise exception 'FILE_SCHEMA_INVALID: validation counts cannot be negative'
      using errcode = '23514';
  end if;

  select count(*),
         count(*) filter (where disposition.value_code = 'ACCEPTED'),
         count(*) filter (where disposition.value_code = 'QUARANTINED')
    into v_actual_candidates, v_actual_accepted, v_actual_quarantined
  from s2t_fhir.import_candidate_row row
  join s2t_fhir.reference_value disposition
    on disposition.reference_value_id = row.candidate_disposition_value_id
  where row.import_run_id = v_request.import_run_id;
  select count(*) into v_actual_mappings
  from s2t_fhir.mapping_record m
  where m.baseline_version_id = v_request.baseline_version_id;
  if v_candidate_count <> v_actual_candidates
     or v_accepted_count <> v_actual_accepted
     or v_quarantined_count <> v_actual_quarantined
     or v_actual_mappings <> v_actual_accepted
     or v_warning_count <> (select count(*) from pg_catalog.jsonb_array_elements(p_findings) f
                            where f ->> 'severity' in ('WARNING','ACCEPTED_EXCEPTION'))
     or v_error_count <> (select count(*) from pg_catalog.jsonb_array_elements(p_findings) f
                          where f ->> 'severity' = 'ERROR') then
    raise exception 'FILE_SCHEMA_INVALID: deterministic validation counts do not reconcile'
      using errcode = '23514';
  end if;

  for v_manifest in select value from pg_catalog.jsonb_array_elements(p_sheet_manifest)
  loop
    select rv.reference_value_id into strict v_metric_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'SHEET_CLASSIFICATION'
      and rv.value_code = v_manifest ->> 'classification';
    insert into s2t_fhir.artifact_sheet_manifest (
      artifact_id, sheet_name, sheet_order, sheet_classification_value_id,
      is_present, is_authoritative, header_row_number, candidate_range,
      governed_column_range, candidate_row_count, notes,
      manifest_schema_id, manifest_schema_version, manifest_json
    ) values (
      v_request.artifact_id, v_manifest ->> 'sheetName',
      (v_manifest ->> 'sheetOrder')::integer, v_metric_id,
      (v_manifest ->> 'isPresent')::boolean,
      (v_manifest ->> 'isAuthoritative')::boolean,
      nullif(v_manifest ->> 'headerRowNumber','')::integer,
      v_manifest ->> 'candidateRange', v_manifest ->> 'governedColumnRange',
      nullif(v_manifest ->> 'candidateRowCount','')::integer,
      v_manifest ->> 'notes', 'candidate-import-sheet-manifest', 'v1', v_manifest
    );
  end loop;

  select rs.validation_ruleset_id into strict v_ruleset_id
  from s2t_fhir.validation_ruleset rs
  where rs.ruleset_code = 'CATO-MEDICATIONREQUEST-XLSX'
    and rs.version_label = 'v1';
  v_clean := v_error_count = 0 and v_quarantined_count = 0
             and v_accepted_count > 0 and v_candidate_count = v_accepted_count;
  v_outcome := case when not v_clean then 'FAIL'
                    when v_warning_count > 0 then 'PASS_WITH_WARNINGS'
                    else 'PASS' end;
  select rv.reference_value_id into strict v_outcome_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'VALIDATION_OUTCOME' and rv.value_code = v_outcome;
  insert into s2t_fhir.validation_run (
    import_run_id, validation_ruleset_id, artifact_id, artifact_digest,
    execution_fingerprint, started_at, completed_at,
    candidate_count, accepted_count, warning_count, error_count,
    quarantined_count, outcome_value_id, actor_principal_id,
    initiating_human_principal_id, summary_json
  ) values (
    v_request.import_run_id, v_ruleset_id, v_request.artifact_id,
    v_artifact_digest, p_execution_fingerprint,
    (select ir.started_at from s2t_fhir.import_run ir
     where ir.import_run_id = v_request.import_run_id),
    pg_catalog.transaction_timestamp(), v_candidate_count, v_accepted_count,
    v_warning_count, v_error_count, v_quarantined_count, v_outcome_id,
    p_service_actor_id, v_request.uploader_principal_id, p_summary
  ) returning validation_run_id into v_validation_id;

  select rv.reference_value_id into strict v_subject_role_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'FINDING_ROW_ROLE' and rv.value_code = 'SUBJECT';
  for v_finding in select value from pg_catalog.jsonb_array_elements(p_findings)
  loop
    select rule.validation_rule_id into strict v_rule_id
    from s2t_fhir.validation_rule rule
    where rule.validation_ruleset_id = v_ruleset_id
      and rule.rule_code = v_finding ->> 'code' and rule.rule_version = '1';
    select rv.reference_value_id into strict v_severity_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'SEVERITY' and rv.value_code = v_finding ->> 'severity';
    insert into s2t_fhir.validation_finding (
      validation_run_id, validation_rule_id, severity_value_id,
      finding_code, message, finding_fingerprint, collision_group_key,
      evidence_schema_id, evidence_schema_version, evidence_json
    ) values (
      v_validation_id, v_rule_id, v_severity_id,
      v_finding ->> 'code', v_finding ->> 'safeMessage',
      pg_catalog.decode(v_finding ->> 'fingerprint', 'hex'),
      v_finding ->> 'collisionGroup', 'candidate-import-finding', 'v1',
      coalesce(v_finding -> 'evidence', '{}'::jsonb)
    ) returning validation_finding_id into v_finding_id;
    if v_finding ? 'sourceSheetName' then
      select row.import_candidate_row_id into v_candidate_id
      from s2t_fhir.import_candidate_row row
      where row.import_run_id = v_request.import_run_id
        and row.source_sheet_name = v_finding ->> 'sourceSheetName'
        and row.source_row_number = (v_finding ->> 'sourceRowNumber')::integer
        and row.source_cell_range = v_finding ->> 'sourceCellRange';
      if found then
        insert into s2t_fhir.validation_finding_row (
          validation_finding_id, import_candidate_row_id, finding_row_role_value_id
        ) values (v_finding_id, v_candidate_id, v_subject_role_id);
      end if;
    end if;
  end loop;

  select rv.reference_value_id into strict v_quarantine_event_type_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'QUARANTINE_EVENT_TYPE' and rv.value_code = 'OPENED';
  for v_quarantined in
    select row.import_candidate_row_id
    from s2t_fhir.import_candidate_row row
    join s2t_fhir.reference_value disposition
      on disposition.reference_value_id = row.candidate_disposition_value_id
    where row.import_run_id = v_request.import_run_id
      and disposition.value_code = 'QUARANTINED'
  loop
    select finding.validation_finding_id into v_opening_finding_id
    from s2t_fhir.validation_finding finding
    join s2t_fhir.validation_finding_row link
      on link.validation_finding_id = finding.validation_finding_id
    join s2t_fhir.reference_value severity
      on severity.reference_value_id = finding.severity_value_id
    where finding.validation_run_id = v_validation_id
      and link.import_candidate_row_id = v_quarantined.import_candidate_row_id
      and severity.value_code = 'ERROR'
    order by finding.created_at, finding.validation_finding_id
    limit 1;
    if v_opening_finding_id is null then
      raise exception 'FILE_SCHEMA_INVALID: quarantined row lacks a linked ERROR finding'
        using errcode = '23514';
    end if;
    insert into s2t_fhir.quarantine_case (
      import_candidate_row_id, opening_validation_finding_id,
      opened_at, opened_by_principal_id, initiating_human_principal_id
    ) values (
      v_quarantined.import_candidate_row_id, v_opening_finding_id,
      pg_catalog.transaction_timestamp(), p_service_actor_id,
      v_request.uploader_principal_id
    ) returning quarantine_case_id into v_quarantine_case_id;
    insert into s2t_fhir.quarantine_event (
      quarantine_case_id, event_type_value_id, occurred_at,
      actor_principal_id, initiating_human_principal_id, reason
    ) values (
      v_quarantine_case_id, v_quarantine_event_type_id,
      pg_catalog.transaction_timestamp(), p_service_actor_id,
      v_request.uploader_principal_id,
      'Candidate workbook row retained as validation evidence'
    );
  end loop;

  for v_metric in
    select * from (values
      ('CANDIDATE', v_candidate_count, null::text),
      ('ACCEPTED', v_accepted_count, null::text),
      ('WARNING', v_warning_count, 'WARNING'::text),
      ('ERROR', v_error_count, 'ERROR'::text),
      ('QUARANTINED', v_quarantined_count, null::text)
    ) x(metric_code, metric_count, severity_code)
  loop
    v_severity_id := null;
    select rv.reference_value_id into strict v_metric_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'METRIC_TYPE' and rv.value_code = v_metric.metric_code;
    select rv.reference_value_id into v_severity_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'SEVERITY' and rv.value_code = v_metric.severity_code;
    insert into s2t_fhir.import_run_metric (
      import_run_id, metric_type_value_id, metric_count, severity_value_id
    ) values (v_request.import_run_id, v_metric_id, v_metric.metric_count, v_severity_id);
  end loop;

  update s2t_fhir.candidate_import_request r
  set validation_run_id = v_validation_id
  where r.candidate_import_request_id = p_request_id;
  if v_clean then
    perform s2t_fhir._transition_candidate_import_request(
      p_request_id, 'VALIDATING', 'READY_TO_PUBLISH', 'VALIDATION_COMPLETED',
      p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
      null, null, 'candidate-import-validation', 1,
      pg_catalog.jsonb_build_object('validationRunId', v_validation_id, 'outcome', v_outcome)
    );
  else
    v_failure_code := case when v_accepted_count = 0
                           then 'ZERO_ACCEPTED_ROWS'
                           else 'IMPORT_VALIDATION_FAILED' end;
    v_failure_message := case when v_accepted_count = 0
                              then 'Workbook contains no accepted governed rows'
                              else 'Workbook did not satisfy CLEAN_IMPORT' end;
    select rv.reference_value_id into strict v_failed_import_status_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'IMPORT_RUN_STATUS' and rv.value_code = 'FAILED';
    update s2t_fhir.import_run ir
    set completed_at = pg_catalog.transaction_timestamp(),
        terminal_status_value_id = v_failed_import_status_id,
        failure_summary = v_failure_code
    where ir.import_run_id = v_request.import_run_id
      and ir.completed_at is null;
    update s2t_fhir.candidate_import_request r
    set last_error_reference = pg_catalog.gen_random_uuid()
    where r.candidate_import_request_id = p_request_id;
    perform s2t_fhir._transition_candidate_import_request(
      p_request_id, 'VALIDATING', 'VALIDATION_FAILED', 'VALIDATION_FAILED',
      p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
      v_failure_message, v_failure_code,
      'candidate-import-validation', 1,
      pg_catalog.jsonb_build_object('validationRunId', v_validation_id, 'outcome', v_outcome)
    );
  end if;
  set constraints all immediate;
  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id,
    'state', case when v_clean then 'READY_TO_PUBLISH' else 'VALIDATION_FAILED' end,
    'validationRunId', v_validation_id, 'outcome', v_outcome,
    'candidateCount', v_candidate_count, 'acceptedCount', v_accepted_count,
    'warningCount', v_warning_count, 'errorCount', v_error_count,
    'quarantinedCount', v_quarantined_count,
    'errorCode', case when v_clean then null else v_failure_code end);
end
$function$;

create function s2t_fhir_api._service_fail_candidate_import(
  p_request_id uuid,
  p_validation_attempt_id uuid,
  p_error_code text,
  p_error_reference uuid,
  p_safe_message text,
  p_service_actor_id uuid,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_new_state text;
  v_failed_import_status_id uuid;
begin
  if p_error_code not in (
    'FILE_TYPE_INVALID','FILE_SCHEMA_INVALID','FILE_TOO_LARGE',
    'DUPLICATE_ROW_IDENTITY','IMPORT_VALIDATION_FAILED','ZERO_ACCEPTED_ROWS',
    'CANDIDATE_CHANGED','CAPABILITY_REQUIRED','IMPORT_CONFLICT',
    'VERSION_LABEL_CONFLICT','INTERNAL_IMPORT_ERROR'
  ) or p_error_reference is null or nullif(pg_catalog.btrim(p_safe_message), '') is null then
    raise exception 'FILE_SCHEMA_INVALID: service failure envelope is invalid'
      using errcode = '22023';
  end if;
  select * into v_request from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id for update;
  if not found then raise exception 'IMPORT_CONFLICT: request not found' using errcode = 'P0002'; end if;
  if v_request.current_state = 'VALIDATING'
     and v_request.validation_attempt_id is distinct from p_validation_attempt_id then
    raise exception 'IMPORT_CONFLICT: service failure attempt is stale' using errcode = '23505';
  end if;
  if v_request.current_state not in ('AWAITING_UPLOAD','UPLOADED','VALIDATING') then
    raise exception 'IMPORT_CONFLICT: request cannot transition to failure from current state'
      using errcode = '23505';
  end if;
  v_new_state := case when p_error_code in (
    'FILE_TYPE_INVALID','FILE_SCHEMA_INVALID','FILE_TOO_LARGE',
    'DUPLICATE_ROW_IDENTITY','IMPORT_VALIDATION_FAILED','ZERO_ACCEPTED_ROWS'
  ) then 'VALIDATION_FAILED' else 'FAILED' end;
  if v_request.import_run_id is not null then
    select rv.reference_value_id into strict v_failed_import_status_id
    from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'IMPORT_RUN_STATUS' and rv.value_code = 'FAILED';
    update s2t_fhir.import_run ir
    set completed_at = pg_catalog.transaction_timestamp(),
        terminal_status_value_id = v_failed_import_status_id,
        failure_summary = p_error_code
    where ir.import_run_id = v_request.import_run_id
      and ir.completed_at is null;
  end if;
  update s2t_fhir.candidate_import_request r
  set last_error_reference = p_error_reference
  where r.candidate_import_request_id = p_request_id;
  perform s2t_fhir._transition_candidate_import_request(
    p_request_id, v_request.current_state, v_new_state,
    case when v_new_state = 'VALIDATION_FAILED' then 'VALIDATION_FAILED' else 'REQUEST_FAILED' end,
    p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
    p_safe_message, p_error_code, 'candidate-import-error', 1,
    pg_catalog.jsonb_build_object('errorReference', p_error_reference)
  );
  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id, 'state', v_new_state,
    'errorCode', p_error_code, 'errorReference', p_error_reference);
end
$function$;

create function s2t_fhir_api.publish_candidate_import(
  p_candidate_import_request_id uuid,
  p_expected_candidate_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_replacement_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor uuid;
  v_probe s2t_fhir.candidate_import_request%rowtype;
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_committed_id uuid;
  v_result jsonb;
  v_active_count_before bigint;
  v_active_baseline_before uuid;
  v_active_event_before uuid;
  v_active_import_before uuid;
  v_mapping_count_before bigint;
  v_review_session_count_before bigint;
  v_review_event_count_before bigint;
  v_active_count_after bigint;
  v_active_baseline_after uuid;
  v_active_event_after uuid;
  v_active_import_after uuid;
  v_mapping_count_after bigint;
  v_review_session_count_after bigint;
  v_review_event_count_after bigint;
begin
  v_actor := s2t_fhir_api._require_authenticated_baseline_capability('S2T_BASELINE_UPLOAD');
  if (p_expected_candidate_baseline_version_id is null) <>
     (p_expected_candidate_lifecycle_event_id is null) then
    raise exception 'CANDIDATE_CHANGED: expected Candidate IDs must be both null or both non-null'
      using errcode = '40001';
  end if;

  -- Resolve the protected series without a request-row lock, then take locks in
  -- the same series-first order as replace_current_candidate().
  select * into v_probe from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_candidate_import_request_id;
  if not found or v_probe.uploader_principal_id <> v_actor then
    raise exception 'CAPABILITY_REQUIRED: Candidate import request is not accessible'
      using errcode = '42501';
  end if;
  if v_probe.current_state = 'PUBLISHED' then
    return pg_catalog.jsonb_build_object(
      'requestId', v_probe.candidate_import_request_id,
      'state', 'PUBLISHED',
      'newCandidateBaselineVersionId', v_probe.baseline_version_id,
      'newCandidateLifecycleEventId', v_probe.published_candidate_lifecycle_event_id,
      'idempotentReplay', true);
  end if;

  perform 1 from s2t_fhir.baseline_series bs
  where bs.baseline_series_id = v_probe.baseline_series_id for update;
  select * into strict v_request from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_candidate_import_request_id for update;
  if v_request.uploader_principal_id <> v_actor then
    raise exception 'CAPABILITY_REQUIRED: Candidate import request is not accessible'
      using errcode = '42501';
  end if;
  if v_request.current_state = 'PUBLISHED' then
    return pg_catalog.jsonb_build_object(
      'requestId', v_request.candidate_import_request_id,
      'state', 'PUBLISHED',
      'newCandidateBaselineVersionId', v_request.baseline_version_id,
      'newCandidateLifecycleEventId', v_request.published_candidate_lifecycle_event_id,
      'idempotentReplay', true);
  elsif v_request.current_state <> 'READY_TO_PUBLISH' then
    raise exception 'IMPORT_CONFLICT: Candidate import request is not READY_TO_PUBLISH'
      using errcode = '23505';
  end if;
  if not exists (
    select 1 from s2t_fhir.validation_run vr
    join s2t_fhir.reference_value outcome on outcome.reference_value_id = vr.outcome_value_id
    join s2t_fhir.reference_domain domain on domain.reference_domain_id = outcome.reference_domain_id
    where vr.validation_run_id = v_request.validation_run_id
      and vr.import_run_id = v_request.import_run_id
      and vr.candidate_count = vr.accepted_count
      and vr.accepted_count > 0 and vr.error_count = 0 and vr.quarantined_count = 0
      and domain.domain_code = 'VALIDATION_OUTCOME'
      and outcome.value_code in ('PASS','PASS_WITH_WARNINGS')
  ) then
    raise exception 'IMPORT_VALIDATION_FAILED: CLEAN_IMPORT evidence is incomplete'
      using errcode = '23514';
  end if;

  with current_active as (
    select bv.baseline_version_id, e.baseline_lifecycle_event_id
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e on e.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value rv on rv.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain rd on rd.reference_domain_id = rv.reference_domain_id
    where bv.baseline_series_id = v_request.baseline_series_id
      and rd.domain_code = 'BASELINE_LIFECYCLE_STATUS' and rv.value_code = 'ACTIVE'
      and not exists (select 1 from s2t_fhir.baseline_lifecycle_event successor
                      where successor.supersedes_event_id = e.baseline_lifecycle_event_id)
  )
  select count(*), (pg_catalog.array_agg(baseline_version_id))[1],
         (pg_catalog.array_agg(baseline_lifecycle_event_id))[1]
    into v_active_count_before, v_active_baseline_before, v_active_event_before
  from current_active;
  if v_active_count_before > 1 then
    raise exception 'IMPORT_VALIDATION_FAILED: multiple current ACTIVE baselines'
      using errcode = '23514';
  end if;
  if v_active_baseline_before is not null then
    select context.import_run_id into v_active_import_before
    from s2t_fhir.baseline_activation_context context
    where context.baseline_version_id = v_active_baseline_before;
    select count(*) into v_mapping_count_before from s2t_fhir.mapping_record m
    where m.baseline_version_id = v_active_baseline_before;
    select count(*) into v_review_session_count_before from s2t_fhir.review_session s
    where s.baseline_version_id = v_active_baseline_before;
    select count(*) into v_review_event_count_before from s2t_fhir.mapping_review_event e
    where e.baseline_version_id = v_active_baseline_before;
  else
    v_mapping_count_before := 0; v_review_session_count_before := 0; v_review_event_count_before := 0;
  end if;

  select rv.reference_value_id into strict v_committed_id
  from s2t_fhir.reference_value rv join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'IMPORT_RUN_STATUS' and rv.value_code = 'COMMITTED';
  update s2t_fhir.import_run ir
  set completed_at = pg_catalog.transaction_timestamp(),
      terminal_status_value_id = v_committed_id,
      failure_summary = null
  where ir.import_run_id = v_request.import_run_id
    and ir.completed_at is null and ir.terminal_status_value_id is null;
  if not found then
    raise exception 'IMPORT_CONFLICT: exactly one open import must be finalized'
      using errcode = '23505';
  end if;

  v_result := s2t_fhir.replace_current_candidate(
    v_request.baseline_version_id, v_request.import_run_id,
    p_expected_candidate_baseline_version_id,
    p_expected_candidate_lifecycle_event_id,
    pg_catalog.transaction_timestamp(), p_replacement_reason,
    v_actor, v_actor
  );

  with current_active as (
    select bv.baseline_version_id, e.baseline_lifecycle_event_id
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event e on e.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value rv on rv.reference_value_id = e.lifecycle_status_value_id
    join s2t_fhir.reference_domain rd on rd.reference_domain_id = rv.reference_domain_id
    where bv.baseline_series_id = v_request.baseline_series_id
      and rd.domain_code = 'BASELINE_LIFECYCLE_STATUS' and rv.value_code = 'ACTIVE'
      and not exists (select 1 from s2t_fhir.baseline_lifecycle_event successor
                      where successor.supersedes_event_id = e.baseline_lifecycle_event_id)
  )
  select count(*), (pg_catalog.array_agg(baseline_version_id))[1],
         (pg_catalog.array_agg(baseline_lifecycle_event_id))[1]
    into v_active_count_after, v_active_baseline_after, v_active_event_after
  from current_active;
  if v_active_baseline_after is not null then
    select context.import_run_id into v_active_import_after
    from s2t_fhir.baseline_activation_context context
    where context.baseline_version_id = v_active_baseline_after;
    select count(*) into v_mapping_count_after from s2t_fhir.mapping_record m
    where m.baseline_version_id = v_active_baseline_after;
    select count(*) into v_review_session_count_after from s2t_fhir.review_session s
    where s.baseline_version_id = v_active_baseline_after;
    select count(*) into v_review_event_count_after from s2t_fhir.mapping_review_event e
    where e.baseline_version_id = v_active_baseline_after;
  else
    v_mapping_count_after := 0; v_review_session_count_after := 0; v_review_event_count_after := 0;
  end if;
  if v_active_count_after is distinct from v_active_count_before
     or v_active_baseline_after is distinct from v_active_baseline_before
     or v_active_event_after is distinct from v_active_event_before
     or v_active_import_after is distinct from v_active_import_before
     or v_mapping_count_after is distinct from v_mapping_count_before
     or v_review_session_count_after is distinct from v_review_session_count_before
     or v_review_event_count_after is distinct from v_review_event_count_before then
    raise exception 'IMPORT_VALIDATION_FAILED: Candidate publication changed ACTIVE evidence'
      using errcode = '23514';
  end if;

  update s2t_fhir.candidate_import_request r
  set published_candidate_lifecycle_event_id =
        (v_result ->> 'newCandidateLifecycleEventId')::uuid
  where r.candidate_import_request_id = p_candidate_import_request_id;
  perform s2t_fhir._transition_candidate_import_request(
    p_candidate_import_request_id, 'READY_TO_PUBLISH', 'PUBLISHED',
    'PUBLICATION_SUCCEEDED', v_actor, v_actor,
    p_candidate_import_request_id, p_replacement_reason, null,
    'candidate-import-publication', 1, v_result
  );
  set constraints all immediate;
  return v_result || pg_catalog.jsonb_build_object(
    'requestId', p_candidate_import_request_id,
    'state', 'PUBLISHED', 'idempotentReplay', false);
end
$function$;

-- Immutable validation configuration for the database-applicable part of the
-- external CATO MedicationRequest XLSX v1 parser contract.
with migrator as (
  select principal_id from s2t_fhir.principal
  where external_issuer = 'postgres-role'
    and external_subject = 's2t_fhir_migrator'
    and disabled_at is null
)
insert into s2t_fhir.validation_ruleset (
  ruleset_code, version_label, ruleset_digest, description,
  implementation_version, created_by_principal_id
)
select 'CATO-MEDICATIONREQUEST-XLSX', 'v1',
       pg_catalog.decode(pg_catalog.repeat('26', 32), 'hex'),
       'Database-applicable Candidate workbook import contract checks',
       'CATO-MEDICATIONREQUEST-XLSX-v1', principal_id
from migrator;

with rules(rule_code, ordinal, description) as (
  values
    ('DUPLICATE_SOURCE_ROW', 1, 'Reject duplicate governed source-row content or provenance'),
    ('DUPLICATE_LOGICAL_IDENTITY', 2, 'Reject duplicate logical identities in one baseline'),
    ('REQUIRED_TARGET_FHIR_PATH', 3, 'Require the governed subtype target path where applicable'),
    ('INVALID_CARDINALITY', 4, 'Validate MedicationRequest element cardinality'),
    ('UNKNOWN_DECISION_STATUS', 5, 'Reject blank or unknown governed Decision Status'),
    ('STATUS_MAPPING_CONTRACT', 6, 'Validate the CATO to FHIR status mapping contract'),
    ('GOVERNANCE_GUIDANCE_CONTRACT', 7, 'Validate governed guidance scope and topic'),
    ('ZERO_ACCEPTED_ROWS', 8, 'Reject a workbook with no accepted governed rows'),
    ('CLEAN_IMPORT_INTEGRITY', 9, 'Require no errors or quarantine and candidate equals accepted')
), ruleset as (
  select validation_ruleset_id from s2t_fhir.validation_ruleset
  where ruleset_code = 'CATO-MEDICATIONREQUEST-XLSX' and version_label = 'v1'
), severity as (
  select rv.reference_value_id from s2t_fhir.reference_value rv
  join s2t_fhir.reference_domain rd using(reference_domain_id)
  where rd.domain_code = 'SEVERITY' and rv.value_code = 'ERROR'
)
insert into s2t_fhir.validation_rule (
  validation_ruleset_id, rule_code, rule_version,
  default_severity_value_id, rule_definition_digest, description,
  applicability_json
)
select ruleset.validation_ruleset_id, r.rule_code, '1',
       severity.reference_value_id,
       pg_catalog.decode(pg_catalog.lpad(r.ordinal::text, 64, '0'), 'hex'),
       r.description,
       pg_catalog.jsonb_build_object(
         'importSpecificationVersion', 'CATO-MEDICATIONREQUEST-XLSX-v1',
         'executionBoundary', 'DATABASE')
from rules r cross join ruleset cross join severity;

alter function s2t_fhir.validate_candidate_import_request() owner to s2t_fhir_owner;
alter function s2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb) owner to s2t_fhir_owner;
alter function s2t_fhir._candidate_ui_upload_capability(uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api.get_my_candidate_import(uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text) owner to s2t_fhir_owner;
alter function s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamptz,uuid,uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamptz,uuid,uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid) owner to s2t_fhir_owner;
alter function s2t_fhir_api.get_my_candidate_ui_capabilities() owner to s2t_fhir_owner;
alter function s2t_fhir_api.get_candidate_ui_context(text) owner to s2t_fhir_owner;

revoke all on table s2t_fhir.candidate_import_request,
  s2t_fhir.candidate_import_request_event,
  s2t_fhir.candidate_import_staging_batch
from public, anon, authenticated, service_role, s2t_fhir_importer,
     s2t_fhir_api_reader, s2t_fhir_governance_reader;

revoke all on function s2t_fhir.validate_candidate_import_request(),
  s2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb),
  s2t_fhir._candidate_ui_upload_capability(uuid)
from public, anon, authenticated, service_role, s2t_fhir_importer,
     s2t_fhir_api_reader, s2t_fhir_governance_reader;

revoke all on function s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid),
  s2t_fhir_api.get_my_candidate_import(uuid),
  s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)
from public, anon, service_role, s2t_fhir_importer,
     s2t_fhir_api_reader, s2t_fhir_governance_reader;
grant execute on function s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid),
  s2t_fhir_api.get_my_candidate_import(uuid),
  s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)
to authenticated;

revoke all on function s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamptz,uuid,uuid),
  s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamptz,uuid,uuid),
  s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid),
  s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid),
  s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)
from public, anon, authenticated, service_role, s2t_fhir_importer,
     s2t_fhir_api_reader, s2t_fhir_governance_reader;
grant execute on function s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamptz,uuid,uuid),
  s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamptz,uuid,uuid),
  s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid),
  s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid),
  s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)
to service_role, s2t_fhir_importer;

revoke all on function s2t_fhir_api.get_candidate_ui_context(text),
  s2t_fhir_api.get_my_candidate_ui_capabilities()
from public, anon;
grant execute on function s2t_fhir_api.get_candidate_ui_context(text),
  s2t_fhir_api.get_my_candidate_ui_capabilities()
to authenticated;

comment on table s2t_fhir.candidate_import_request is
  'Private current projection for governed Candidate workbook import; digests and counts remain authoritative on artifact and validation objects.';
comment on table s2t_fhir.candidate_import_request_event is
  'Append-only Candidate import transition and observation history.';
comment on table s2t_fhir.candidate_import_staging_batch is
  'Append-only batch idempotency metadata; normalized mappings are stored only in the governed import/mapping model.';
comment on function s2t_fhir._candidate_ui_upload_capability(uuid) is
  'Private exact active S2T_BASELINE_UPLOAD capability projection.';
comment on function s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid) is
  'Begins an idempotent governed Candidate import. Returns no Storage path, credential, or service token.';
comment on function s2t_fhir_api.get_my_candidate_import(uuid) is
  'Returns the authenticated uploader safe Candidate import projection without raw rows, private paths, or diagnostics.';
comment on function s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text) is
  'Finalizes one CLEAN_IMPORT and delegates Candidate lifecycle publication to replace_current_candidate; ACTIVE evidence must remain unchanged.';
comment on function s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamptz,uuid,uuid) is
  'Service-only acceptance of externally verified private Storage bytes; the XLSX parser remains external.';
comment on function s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamptz,uuid,uuid) is
  'Service-only fenced validation lease and governed baseline/import staging initialization.';
comment on function s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid) is
  'Service-only atomic normalized-row batch persistence using random relational UUIDs and deterministic logical keys.';
comment on function s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid) is
  'Service-only validation evidence completion; READY_TO_PUBLISH requires CLEAN_IMPORT and does not publish lifecycle state.';
comment on function s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid) is
  'Service-only safe failure transition; raw parser stacks and SQL diagnostics are not stored as API contract.';

reset role;

commit;

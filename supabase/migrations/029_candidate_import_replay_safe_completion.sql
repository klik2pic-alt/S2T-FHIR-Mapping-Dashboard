begin;

set role s2t_fhir_owner;

-- Migration 029: make Candidate-import staging replay-safe and permit exact
-- reuse of immutable artifact manifests. Applied migrations remain immutable.

do $preflight$
begin
  if pg_catalog.to_regclass('s2t_fhir.candidate_import_staging_batch') is null
     or pg_catalog.to_regclass('s2t_fhir.artifact_sheet_manifest') is null then
    raise exception '029 precondition: Candidate-import staging or artifact manifest is absent'
      using errcode = '55000';
  end if;
  if pg_catalog.to_regprocedure(
       's2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'
     ) is null then
    raise exception '029 precondition: expected Candidate-import service helpers are absent'
      using errcode = '55000';
  end if;
  if exists (
    select 1
    from pg_catalog.pg_attribute a
    where a.attrelid = 's2t_fhir.candidate_import_staging_batch'::pg_catalog.regclass
      and a.attname = 'reused_from_staging_batch_id'
      and not a.attisdropped
  ) then
    raise exception '029 precondition: replay provenance column already exists'
      using errcode = '55000';
  end if;
  if pg_catalog.to_regprocedure(
       's2t_fhir.validate_candidate_import_staging_batch_reuse()'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir._assert_candidate_import_batch_materialization(uuid,jsonb)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir._assert_candidate_import_materialization_totals(uuid)'
     ) is not null
     or pg_catalog.to_regprocedure(
       's2t_fhir._reconcile_candidate_import_artifact_manifest(uuid,jsonb)'
     ) is not null then
    raise exception '029 precondition: one or more replay helpers already exist'
      using errcode = '55000';
  end if;
  if (select count(*)
      from pg_catalog.pg_constraint c
      where c.conrelid = 's2t_fhir.artifact_sheet_manifest'::pg_catalog.regclass
        and c.conname in ('artifact_sheet_name_uq', 'artifact_sheet_order_uq')) <> 2 then
    raise exception '029 precondition: artifact manifest uniqueness constraints drifted'
      using errcode = '55000';
  end if;
end
$preflight$;

alter table s2t_fhir.candidate_import_staging_batch
  add column reused_from_staging_batch_id uuid,
  add constraint candidate_import_staging_batch_reuse_fk
    foreign key (reused_from_staging_batch_id)
    references s2t_fhir.candidate_import_staging_batch(candidate_import_staging_batch_id),
  add constraint candidate_import_staging_batch_reuse_not_self_ck
    check (
      reused_from_staging_batch_id is null
      or reused_from_staging_batch_id <> candidate_import_staging_batch_id
    );

create index candidate_import_staging_batch_reuse_idx
  on s2t_fhir.candidate_import_staging_batch(reused_from_staging_batch_id)
  where reused_from_staging_batch_id is not null;

create function s2t_fhir.validate_candidate_import_staging_batch_reuse()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_root s2t_fhir.candidate_import_staging_batch%rowtype;
begin
  if new.reused_from_staging_batch_id is null then
    return new;
  end if;

  select * into v_root
  from s2t_fhir.candidate_import_staging_batch b
  where b.candidate_import_staging_batch_id = new.reused_from_staging_batch_id
  for key share;

  if not found
     or v_root.reused_from_staging_batch_id is not null
     or v_root.candidate_import_request_id is distinct from new.candidate_import_request_id
     or v_root.batch_number is distinct from new.batch_number
     or v_root.batch_digest is distinct from new.batch_digest
     or v_root.row_count is distinct from new.row_count
     or v_root.encoded_byte_size is distinct from new.encoded_byte_size
     or v_root.validation_attempt_id is not distinct from new.validation_attempt_id
     or v_root.staged_at > new.staged_at then
    raise exception 'STAGING_REPLAY_MISMATCH: replay provenance must reference the original equivalent materializing batch'
      using errcode = '23514';
  end if;
  return new;
end
$function$;

create trigger candidate_import_staging_batch_reuse_validate_trg
before insert on s2t_fhir.candidate_import_staging_batch
for each row execute function s2t_fhir.validate_candidate_import_staging_batch_reuse();

create function s2t_fhir._assert_candidate_import_batch_materialization(
  p_request_id uuid,
  p_rows jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_row jsonb;
  v_candidate s2t_fhir.import_candidate_row%rowtype;
  v_mapping s2t_fhir.mapping_record%rowtype;
  v_identity s2t_fhir.logical_mapping_identity%rowtype;
  v_kind_id uuid;
  v_disposition_id uuid;
  v_decision_id uuid;
  v_kind text;
  v_disposition text;
  v_source_hash bytea;
  v_mapping_count integer;
  v_subtype_count integer;
  v_actual_subtype jsonb;
begin
  if pg_catalog.jsonb_typeof(p_rows) <> 'array' then
    raise exception 'STAGING_REPLAY_MISMATCH: replay rows must be an array'
      using errcode = '23514';
  end if;

  select * into v_request
  from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id;
  if not found or v_request.import_run_id is null or v_request.baseline_version_id is null then
    raise exception 'STAGING_REPLAY_MISMATCH: replay request links are incomplete'
      using errcode = '23514';
  end if;

  for v_row in select value from pg_catalog.jsonb_array_elements(p_rows)
  loop
    v_kind := v_row ->> 'mappingKind';
    v_disposition := coalesce(v_row ->> 'candidateDisposition', 'ACCEPTED');
    begin
      v_source_hash := pg_catalog.decode(v_row ->> 'sourceRowHash', 'hex');
    exception when others then
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: replay source hash is invalid'
        using errcode = '23514';
    end;

    select rv.reference_value_id into v_kind_id
    from s2t_fhir.reference_value rv
    join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'MAPPING_KIND' and rv.value_code = v_kind;
    select rv.reference_value_id into v_disposition_id
    from s2t_fhir.reference_value rv
    join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'CANDIDATE_DISPOSITION' and rv.value_code = v_disposition;
    if v_kind_id is null or v_disposition_id is null then
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: replay reference values are invalid'
        using errcode = '23514';
    end if;

    select * into v_candidate
    from s2t_fhir.import_candidate_row candidate
    where candidate.import_run_id = v_request.import_run_id
      and candidate.source_sheet_name = v_row ->> 'sourceSheetName'
      and candidate.source_row_number = (v_row ->> 'sourceRowNumber')::integer
      and candidate.source_cell_range = v_row ->> 'sourceCellRange';

    if not found
       or v_candidate.mapping_kind_value_id is distinct from v_kind_id
       or v_candidate.raw_schema_id is distinct from (v_row ->> 'rawSchemaId')
       or v_candidate.raw_schema_version is distinct from (v_row ->> 'rawSchemaVersion')
       or v_candidate.raw_source_row is distinct from (v_row -> 'rawSourceRow')
       or v_candidate.source_row_hash is distinct from v_source_hash
       or v_candidate.normalization_algorithm_version is distinct from
          (v_row ->> 'normalizationAlgorithmVersion')
       or v_candidate.logical_key_algorithm_version is distinct from
          (v_row ->> 'logicalKeyAlgorithmVersion')
       or v_candidate.candidate_disposition_value_id is distinct from v_disposition_id
       or v_candidate.calculated_logical_key is distinct from (v_row ->> 'logicalKey')
       or v_candidate.logical_key_components_json is distinct from
          (v_row -> 'logicalKeyComponents') then
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: persisted candidate evidence differs from replay input'
        using errcode = '23514';
    end if;

    select count(*) into v_mapping_count
    from s2t_fhir.mapping_record m
    where m.import_candidate_row_id = v_candidate.import_candidate_row_id;

    if v_disposition = 'QUARANTINED' then
      if v_mapping_count <> 0 then
        raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: quarantined replay row has mapping evidence'
          using errcode = '23514';
      end if;
      continue;
    end if;
    if v_disposition <> 'ACCEPTED' or v_mapping_count <> 1 then
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: accepted replay row mapping cardinality differs'
        using errcode = '23514';
    end if;

    select * into strict v_mapping
    from s2t_fhir.mapping_record m
    where m.import_candidate_row_id = v_candidate.import_candidate_row_id;
    select * into strict v_identity
    from s2t_fhir.logical_mapping_identity identity
    where identity.logical_mapping_identity_id = v_mapping.logical_mapping_identity_id;
    select rv.reference_value_id into v_decision_id
    from s2t_fhir.reference_value rv
    join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'DECISION_STATUS'
      and rv.value_code = v_row ->> 'decisionStatus';

    if v_mapping.baseline_version_id is distinct from v_request.baseline_version_id
       or v_mapping.mapping_kind_value_id is distinct from v_kind_id
       or v_mapping.decision_status_value_id is distinct from v_decision_id
       or v_identity.mapping_kind_value_id is distinct from v_kind_id
       or v_identity.source_system <> 'CATO'
       or v_identity.fhir_resource <> 'MedicationRequest'
       or v_identity.key_algorithm_version is distinct from
          (v_row ->> 'logicalKeyAlgorithmVersion')
       or v_identity.logical_key is distinct from (v_row ->> 'logicalKey')
       or v_identity.key_components_json is distinct from
          (v_row -> 'logicalKeyComponents') then
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: persisted mapping identity differs from replay input'
        using errcode = '23514';
    end if;

    select pg_catalog.num_nonnulls(
      (select e.mapping_record_id from s2t_fhir.element_mapping e
       where e.mapping_record_id = v_mapping.mapping_record_id),
      (select s.mapping_record_id from s2t_fhir.status_mapping_rule s
       where s.mapping_record_id = v_mapping.mapping_record_id),
      (select g.mapping_record_id from s2t_fhir.governance_guidance g
       where g.mapping_record_id = v_mapping.mapping_record_id)
    ) into v_subtype_count;
    if v_subtype_count <> 1 then
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: accepted replay row subtype cardinality differs'
        using errcode = '23514';
    end if;

    if v_kind = 'ELEMENT_MAPPING' then
      select pg_catalog.jsonb_build_object(
        'targetFhirPath', e.target_fhir_path,
        'sourceSystemRaw', e.source_system_raw,
        'interfaceType', e.interface_type,
        'interfaceName', e.interface_name,
        'sourceExpression', e.source_expression,
        'profileContext', e.profile_context,
        'fixedValue', e.fixed_value,
        'transformationRule', e.transformation_rule,
        'sourceBusinessDefinition', e.source_business_definition,
        'cardinalityRaw', e.cardinality_raw,
        'cardinalityMin', e.cardinality_min,
        'cardinalityMax', e.cardinality_max,
        'cardinalityMaxUnbounded', e.cardinality_max_unbounded,
        'valuesetBinding', e.valueset_binding,
        'mandatedCodeSystem', e.mandated_code_system,
        'irrelevantUnderS2tRaw', e.irrelevant_under_s2t_raw,
        'exampleValue', e.example_value,
        'exceptionHandling', e.exception_handling,
        'notes', e.notes
      ) into v_actual_subtype
      from s2t_fhir.element_mapping e
      where e.mapping_record_id = v_mapping.mapping_record_id;
    elsif v_kind = 'STATUS_MAPPING_RULE' then
      select pg_catalog.jsonb_build_object(
        'sourceStatusValue', s.source_status_value,
        'targetFhirPath', s.target_fhir_path,
        'targetStatusValue', s.target_status_value,
        'sourceSequence', s.source_sequence,
        'sourceBusinessDefinition', s.source_business_definition,
        'relatedResourceNote', s.related_resource_note,
        'transformationRule', s.transformation_rule,
        'mappingEvidenceStatusRaw', s.mapping_evidence_status_raw,
        'notes', s.notes
      ) into v_actual_subtype
      from s2t_fhir.status_mapping_rule s
      where s.mapping_record_id = v_mapping.mapping_record_id;
    elsif v_kind = 'GOVERNANCE_GUIDANCE' then
      select pg_catalog.jsonb_build_object(
        'guidanceScope', scope.value_code,
        'decisionTopic', topic.value_code,
        'guidanceText', g.guidance_text,
        'guidanceStatusRaw', g.guidance_status_raw,
        'targetFhirPathOrScopeRaw', g.target_fhir_path_or_scope_raw,
        'decisionTopicRaw', g.decision_topic_raw,
        'notes', g.notes,
        'reviewNotes', g.review_notes
      ) into v_actual_subtype
      from s2t_fhir.governance_guidance g
      join s2t_fhir.reference_value scope
        on scope.reference_value_id = g.guidance_scope_value_id
      join s2t_fhir.reference_value topic
        on topic.reference_value_id = g.decision_topic_value_id
      where g.mapping_record_id = v_mapping.mapping_record_id;
    else
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: replay mapping kind is unsupported'
        using errcode = '23514';
    end if;

    if v_actual_subtype is distinct from (v_row -> 'subtype') then
      raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: persisted subtype differs from replay input'
        using errcode = '23514';
    end if;
  end loop;
end
$function$;

create function s2t_fhir._assert_candidate_import_materialization_totals(
  p_request_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request s2t_fhir.candidate_import_request%rowtype;
  v_root_batch_count bigint;
  v_root_batch_number_count bigint;
  v_root_row_count bigint;
  v_candidate_count bigint;
  v_accepted_count bigint;
  v_quarantined_count bigint;
  v_mapping_count bigint;
  v_subtype_count bigint;
  v_bad_subtype_count bigint;
begin
  select * into v_request
  from s2t_fhir.candidate_import_request r
  where r.candidate_import_request_id = p_request_id;
  if not found or v_request.import_run_id is null or v_request.baseline_version_id is null then
    raise exception 'STAGING_REPLAY_MISMATCH: materialization request links are incomplete'
      using errcode = '23514';
  end if;

  select count(*), count(distinct b.batch_number), coalesce(sum(b.row_count), 0)
    into v_root_batch_count, v_root_batch_number_count, v_root_row_count
  from s2t_fhir.candidate_import_staging_batch b
  where b.candidate_import_request_id = p_request_id
    and b.reused_from_staging_batch_id is null;

  select count(*),
         count(*) filter (where disposition.value_code = 'ACCEPTED'),
         count(*) filter (where disposition.value_code = 'QUARANTINED')
    into v_candidate_count, v_accepted_count, v_quarantined_count
  from s2t_fhir.import_candidate_row candidate
  join s2t_fhir.reference_value disposition
    on disposition.reference_value_id = candidate.candidate_disposition_value_id
  where candidate.import_run_id = v_request.import_run_id;

  select count(*),
         count(e.mapping_record_id) + count(s.mapping_record_id) + count(g.mapping_record_id),
         count(*) filter (where pg_catalog.num_nonnulls(
           e.mapping_record_id, s.mapping_record_id, g.mapping_record_id) <> 1)
    into v_mapping_count, v_subtype_count, v_bad_subtype_count
  from s2t_fhir.mapping_record m
  join s2t_fhir.import_candidate_row candidate
    on candidate.import_candidate_row_id = m.import_candidate_row_id
  left join s2t_fhir.element_mapping e using(mapping_record_id)
  left join s2t_fhir.status_mapping_rule s using(mapping_record_id)
  left join s2t_fhir.governance_guidance g using(mapping_record_id)
  where candidate.import_run_id = v_request.import_run_id
    and m.baseline_version_id = v_request.baseline_version_id;

  if v_root_batch_count <> v_root_batch_number_count
     or v_root_row_count <> v_candidate_count
     or v_candidate_count <> v_accepted_count + v_quarantined_count
     or v_mapping_count <> v_accepted_count
     or v_subtype_count <> v_mapping_count
     or v_bad_subtype_count <> 0
     or (select count(*) from s2t_fhir.mapping_record m
         where m.baseline_version_id = v_request.baseline_version_id) <> v_mapping_count
     or exists (
       select 1
       from s2t_fhir.mapping_record m
       join s2t_fhir.import_candidate_row candidate
         on candidate.import_candidate_row_id = m.import_candidate_row_id
       join s2t_fhir.reference_value disposition
         on disposition.reference_value_id = candidate.candidate_disposition_value_id
       where candidate.import_run_id = v_request.import_run_id
         and disposition.value_code <> 'ACCEPTED'
     ) then
    raise exception 'STAGING_REPLAY_MISMATCH: materialized import contains missing or extra evidence'
      using errcode = '23514';
  end if;
end
$function$;

create function s2t_fhir._reconcile_candidate_import_artifact_manifest(
  p_artifact_id uuid,
  p_sheet_manifest jsonb
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_manifest jsonb;
  v_metric_id uuid;
  v_submitted_count integer;
  v_existing_count integer;
  v_match_count integer := 0;
begin
  if pg_catalog.jsonb_typeof(p_sheet_manifest) <> 'array'
     or pg_catalog.jsonb_array_length(p_sheet_manifest) = 0 then
    raise exception 'FILE_SCHEMA_INVALID: sheet manifest must be a non-empty array'
      using errcode = '22023';
  end if;
  v_submitted_count := pg_catalog.jsonb_array_length(p_sheet_manifest);
  if (select count(distinct item ->> 'sheetName')
      from pg_catalog.jsonb_array_elements(p_sheet_manifest) item) <> v_submitted_count
     or (select count(distinct (item ->> 'sheetOrder')::integer)
         from pg_catalog.jsonb_array_elements(p_sheet_manifest) item) <> v_submitted_count then
    raise exception 'FILE_SCHEMA_INVALID: sheet manifest names and orders must be unique'
      using errcode = '22023';
  end if;

  -- Validate the entire submitted set before locking or inserting evidence.
  for v_manifest in select value from pg_catalog.jsonb_array_elements(p_sheet_manifest)
  loop
    if pg_catalog.jsonb_typeof(v_manifest) <> 'object'
       or nullif(pg_catalog.btrim(v_manifest ->> 'sheetName'), '') is null
       or (v_manifest ->> 'sheetOrder')::integer <= 0
       or pg_catalog.jsonb_typeof(v_manifest -> 'isPresent') is distinct from 'boolean'
       or pg_catalog.jsonb_typeof(v_manifest -> 'isAuthoritative') is distinct from 'boolean' then
      raise exception 'FILE_SCHEMA_INVALID: sheet manifest entry is invalid'
        using errcode = '22023';
    end if;
    select rv.reference_value_id into v_metric_id
    from s2t_fhir.reference_value rv
    join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'SHEET_CLASSIFICATION'
      and rv.value_code = v_manifest ->> 'classification';
    if v_metric_id is null then
      raise exception 'FILE_SCHEMA_INVALID: sheet classification is invalid'
        using errcode = '22023';
    end if;
  end loop;

  perform 1 from s2t_fhir.artifact a
  where a.artifact_id = p_artifact_id
  for update;
  if not found then
    raise exception 'ARTIFACT_MANIFEST_MISMATCH: artifact is absent'
      using errcode = '23514';
  end if;

  select count(*) into v_existing_count
  from s2t_fhir.artifact_sheet_manifest manifest
  where manifest.artifact_id = p_artifact_id;

  if v_existing_count = 0 then
    for v_manifest in select value from pg_catalog.jsonb_array_elements(p_sheet_manifest)
    loop
      select rv.reference_value_id into strict v_metric_id
      from s2t_fhir.reference_value rv
      join s2t_fhir.reference_domain rd using(reference_domain_id)
      where rd.domain_code = 'SHEET_CLASSIFICATION'
        and rv.value_code = v_manifest ->> 'classification';
      insert into s2t_fhir.artifact_sheet_manifest (
        artifact_id, sheet_name, sheet_order, sheet_classification_value_id,
        is_present, is_authoritative, header_row_number, candidate_range,
        governed_column_range, candidate_row_count, notes,
        manifest_schema_id, manifest_schema_version, manifest_json
      ) values (
        p_artifact_id, v_manifest ->> 'sheetName',
        (v_manifest ->> 'sheetOrder')::integer, v_metric_id,
        (v_manifest ->> 'isPresent')::boolean,
        (v_manifest ->> 'isAuthoritative')::boolean,
        nullif(v_manifest ->> 'headerRowNumber', '')::integer,
        v_manifest ->> 'candidateRange', v_manifest ->> 'governedColumnRange',
        nullif(v_manifest ->> 'candidateRowCount', '')::integer,
        v_manifest ->> 'notes', 'candidate-import-sheet-manifest', 'v1', v_manifest
      );
    end loop;
    return false;
  end if;

  if v_existing_count <> v_submitted_count then
    raise exception 'ARTIFACT_MANIFEST_MISMATCH: persisted and submitted manifest cardinalities differ'
      using errcode = '23514';
  end if;
  for v_manifest in select value from pg_catalog.jsonb_array_elements(p_sheet_manifest)
  loop
    select rv.reference_value_id into strict v_metric_id
    from s2t_fhir.reference_value rv
    join s2t_fhir.reference_domain rd using(reference_domain_id)
    where rd.domain_code = 'SHEET_CLASSIFICATION'
      and rv.value_code = v_manifest ->> 'classification';
    if exists (
      select 1
      from s2t_fhir.artifact_sheet_manifest manifest
      where manifest.artifact_id = p_artifact_id
        and manifest.sheet_name = v_manifest ->> 'sheetName'
        and manifest.sheet_order = (v_manifest ->> 'sheetOrder')::integer
        and manifest.sheet_classification_value_id = v_metric_id
        and manifest.is_present = (v_manifest ->> 'isPresent')::boolean
        and manifest.is_authoritative = (v_manifest ->> 'isAuthoritative')::boolean
        and manifest.header_row_number is not distinct from
          nullif(v_manifest ->> 'headerRowNumber', '')::integer
        and manifest.candidate_range is not distinct from (v_manifest ->> 'candidateRange')
        and manifest.governed_column_range is not distinct from
          (v_manifest ->> 'governedColumnRange')
        and manifest.candidate_row_count is not distinct from
          nullif(v_manifest ->> 'candidateRowCount', '')::integer
        and manifest.notes is not distinct from (v_manifest ->> 'notes')
        and manifest.manifest_schema_id = 'candidate-import-sheet-manifest'
        and manifest.manifest_schema_version = 'v1'
        and manifest.manifest_json = v_manifest
    ) then
      v_match_count := v_match_count + 1;
    end if;
  end loop;
  if v_match_count <> v_submitted_count then
    raise exception 'ARTIFACT_MANIFEST_MISMATCH: persisted and submitted manifest evidence differs'
      using errcode = '23514';
  end if;
  return true;
end
$function$;

create or replace function s2t_fhir_api._service_stage_candidate_import_batch(
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
  v_root s2t_fhir.candidate_import_staging_batch%rowtype;
  v_row jsonb;
  v_count integer;
  v_encoded integer;
  v_root_count integer;
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

  perform s2t_fhir._assert_candidate_import_materialization_totals(p_request_id);

  select * into v_existing
  from s2t_fhir.candidate_import_staging_batch b
  where b.candidate_import_request_id = p_request_id
    and b.validation_attempt_id = p_validation_attempt_id
    and b.batch_number = p_batch_number;
  if found then
    if v_existing.batch_digest is distinct from p_batch_digest
       or v_existing.row_count is distinct from v_count
       or v_existing.encoded_byte_size is distinct from v_encoded then
      raise exception 'BATCH_DIGEST_MISMATCH: same-attempt batch replay envelope differs'
        using errcode = '23514';
    end if;
    perform s2t_fhir._assert_candidate_import_batch_materialization(p_request_id, p_rows);
    return pg_catalog.jsonb_build_object(
      'requestId', p_request_id, 'batchNumber', p_batch_number,
      'rowCount', v_count, 'idempotentReplay', true,
      'materializedRowsReused', v_existing.reused_from_staging_batch_id is not null);
  end if;

  select count(*) into v_root_count
  from s2t_fhir.candidate_import_staging_batch b
  where b.candidate_import_request_id = p_request_id
    and b.batch_number = p_batch_number
    and b.reused_from_staging_batch_id is null;
  if v_root_count > 1 then
    raise exception 'STAGING_REPLAY_MISMATCH: multiple root materializing batches exist'
      using errcode = '23514';
  elsif v_root_count = 1 then
    select * into strict v_root
    from s2t_fhir.candidate_import_staging_batch b
    where b.candidate_import_request_id = p_request_id
      and b.batch_number = p_batch_number
      and b.reused_from_staging_batch_id is null;
    if v_root.batch_digest is distinct from p_batch_digest
       or v_root.row_count is distinct from v_count
       or v_root.encoded_byte_size is distinct from v_encoded then
      raise exception 'BATCH_DIGEST_MISMATCH: cross-attempt batch replay envelope differs'
        using errcode = '23514';
    end if;
    perform s2t_fhir._assert_candidate_import_batch_materialization(p_request_id, p_rows);
    insert into s2t_fhir.candidate_import_staging_batch (
      candidate_import_request_id, validation_attempt_id, batch_number,
      batch_digest, row_count, encoded_byte_size,
      service_actor_principal_id, correlation_id,
      reused_from_staging_batch_id
    ) values (
      p_request_id, p_validation_attempt_id, p_batch_number,
      p_batch_digest, v_count, v_encoded,
      p_service_actor_id, p_correlation_id,
      v_root.candidate_import_staging_batch_id
    );
    perform s2t_fhir._assert_candidate_import_materialization_totals(p_request_id);
    return pg_catalog.jsonb_build_object(
      'requestId', p_request_id, 'batchNumber', p_batch_number,
      'rowCount', v_count, 'idempotentReplay', false,
      'materializedRowsReused', true,
      'reusedFromStagingBatchId', v_root.candidate_import_staging_batch_id);
  elsif exists (
    select 1 from s2t_fhir.candidate_import_staging_batch b
    where b.candidate_import_request_id = p_request_id
      and b.batch_number = p_batch_number
  ) then
    raise exception 'STAGING_REPLAY_MISMATCH: replay batch has no root materialization'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_rows) submitted
    join s2t_fhir.import_candidate_row candidate
      on candidate.import_run_id = v_request.import_run_id
     and candidate.source_sheet_name = submitted ->> 'sourceSheetName'
     and candidate.source_row_number = (submitted ->> 'sourceRowNumber')::integer
     and candidate.source_cell_range = submitted ->> 'sourceCellRange'
  ) then
    raise exception 'IMPORTED_ROW_REPLAY_MISMATCH: materialized rows exist without root batch evidence'
      using errcode = '23514';
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
      select identity.logical_mapping_identity_id into strict v_identity_id
      from s2t_fhir.logical_mapping_identity identity
      where identity.mapping_kind_value_id = v_kind_id
        and identity.source_system = 'CATO'
        and identity.fhir_resource = 'MedicationRequest'
        and identity.key_algorithm_version = v_row ->> 'logicalKeyAlgorithmVersion'
        and identity.logical_key = v_logical_key;
      if (select identity.key_components_json
          from s2t_fhir.logical_mapping_identity identity
          where identity.logical_mapping_identity_id = v_identity_id)
         is distinct from v_components then
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
    service_actor_principal_id, correlation_id, reused_from_staging_batch_id
  ) values (
    p_request_id, p_validation_attempt_id, p_batch_number,
    p_batch_digest, v_count, v_encoded,
    p_service_actor_id, p_correlation_id, null
  );
  perform s2t_fhir._assert_candidate_import_materialization_totals(p_request_id);
  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id, 'batchNumber', p_batch_number,
    'rowCount', v_count, 'idempotentReplay', false,
    'materializedRowsReused', false);
exception
  when unique_violation then
    raise exception 'DUPLICATE_ROW_IDENTITY: staged source location or logical identity is duplicated'
      using errcode = '23505';
end
$function$;

create or replace function s2t_fhir_api._service_complete_candidate_import_validation(
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
  v_batch_count bigint;
  v_distinct_batch_count bigint;
  v_batch_min integer;
  v_batch_max integer;
  v_batch_rows bigint;
  v_manifest_reused boolean;
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
  if not found then
    raise exception 'IMPORT_CONFLICT: Candidate import request does not exist'
      using errcode = 'P0002';
  end if;
  if v_request.current_state <> 'VALIDATING' then
    if v_request.current_state in (
      'READY_TO_PUBLISH','PUBLISHED','VALIDATION_FAILED','FAILED','ABORTED'
    ) then
      raise exception 'COMPLETION_ALREADY_APPLIED: terminal completion replay is fail-closed'
        using errcode = '23514';
    end if;
    raise exception 'IMPORT_CONFLICT: validation completion requires VALIDATING'
      using errcode = '23505';
  end if;
  if v_request.validation_attempt_id is distinct from p_validation_attempt_id
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
  if pg_catalog.num_nulls(
       v_candidate_count, v_accepted_count, v_warning_count,
       v_error_count, v_quarantined_count) > 0
     or least(v_candidate_count, v_accepted_count, v_warning_count,
              v_error_count, v_quarantined_count) < 0 then
    raise exception 'FILE_SCHEMA_INVALID: validation counts are absent or negative'
      using errcode = '23514';
  end if;

  perform s2t_fhir._assert_candidate_import_materialization_totals(p_request_id);
  select count(*), count(distinct b.batch_number), min(b.batch_number),
         max(b.batch_number), coalesce(sum(b.row_count), 0)
    into v_batch_count, v_distinct_batch_count, v_batch_min,
         v_batch_max, v_batch_rows
  from s2t_fhir.candidate_import_staging_batch b
  where b.candidate_import_request_id = p_request_id
    and b.validation_attempt_id = p_validation_attempt_id;
  if v_batch_count = 0
     or v_batch_count <> v_distinct_batch_count
     or v_batch_min <> 0
     or v_batch_max <> v_batch_count - 1
     or v_batch_rows <> v_candidate_count
     or exists (
       select 1
       from s2t_fhir.candidate_import_staging_batch replay
       left join s2t_fhir.candidate_import_staging_batch root
         on root.candidate_import_staging_batch_id = replay.reused_from_staging_batch_id
       where replay.candidate_import_request_id = p_request_id
         and replay.validation_attempt_id = p_validation_attempt_id
         and replay.reused_from_staging_batch_id is not null
         and (root.candidate_import_staging_batch_id is null
           or root.reused_from_staging_batch_id is not null
           or root.candidate_import_request_id <> replay.candidate_import_request_id
           or root.batch_number <> replay.batch_number
           or root.batch_digest <> replay.batch_digest
           or root.row_count <> replay.row_count
           or root.encoded_byte_size <> replay.encoded_byte_size)
     ) then
    raise exception 'STAGING_REPLAY_MISMATCH: current validation attempt batch evidence is incomplete or inconsistent'
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

  v_manifest_reused := s2t_fhir._reconcile_candidate_import_artifact_manifest(
    v_request.artifact_id, p_sheet_manifest
  );

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
      pg_catalog.jsonb_build_object(
        'validationRunId', v_validation_id, 'outcome', v_outcome,
        'validationAttemptId', p_validation_attempt_id,
        'executionFingerprint', pg_catalog.encode(p_execution_fingerprint, 'hex'),
        'artifactManifestReused', v_manifest_reused)
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
      pg_catalog.jsonb_build_object(
        'validationRunId', v_validation_id, 'outcome', v_outcome,
        'validationAttemptId', p_validation_attempt_id,
        'executionFingerprint', pg_catalog.encode(p_execution_fingerprint, 'hex'),
        'artifactManifestReused', v_manifest_reused)
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
    'artifactManifestReused', v_manifest_reused,
    'idempotentReplay', false,
    'errorCode', case when v_clean then null else v_failure_code end);
end
$function$;

alter function s2t_fhir.validate_candidate_import_staging_batch_reuse()
  owner to s2t_fhir_owner;
alter function s2t_fhir._assert_candidate_import_batch_materialization(uuid,jsonb)
  owner to s2t_fhir_owner;
alter function s2t_fhir._assert_candidate_import_materialization_totals(uuid)
  owner to s2t_fhir_owner;
alter function s2t_fhir._reconcile_candidate_import_artifact_manifest(uuid,jsonb)
  owner to s2t_fhir_owner;
alter function s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)
  owner to s2t_fhir_owner;
alter function s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)
  owner to s2t_fhir_owner;

revoke all on function
  s2t_fhir.validate_candidate_import_staging_batch_reuse(),
  s2t_fhir._assert_candidate_import_batch_materialization(uuid,jsonb),
  s2t_fhir._assert_candidate_import_materialization_totals(uuid),
  s2t_fhir._reconcile_candidate_import_artifact_manifest(uuid,jsonb)
from public, anon, authenticated, service_role, s2t_fhir_importer,
     s2t_fhir_api_reader, s2t_fhir_governance_reader;

revoke all on function
  s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid),
  s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)
from public, anon, authenticated, service_role, s2t_fhir_importer,
     s2t_fhir_api_reader, s2t_fhir_governance_reader;
grant execute on function
  s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid),
  s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)
to service_role, s2t_fhir_importer;

comment on column s2t_fhir.candidate_import_staging_batch.reused_from_staging_batch_id is
  'Append-only provenance link to the original materializing batch; replay chains are forbidden.';
comment on function s2t_fhir._reconcile_candidate_import_artifact_manifest(uuid,jsonb) is
  'Validates and inserts a new immutable manifest, or exactly reuses the complete persisted manifest.';
comment on function s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid) is
  'Service-only Candidate staging with exact same-attempt and root-linked cross-attempt replay.';
comment on function s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid) is
  'Service-only validation completion requiring complete current-attempt batches and exact immutable manifest reuse.';

reset role;

commit;

-- Migration 028: make the initial Candidate-import validation state/link
-- projection atomic while preserving the Migration 026 state machine.

begin;

set role s2t_fhir_owner;

do $precondition$
declare
  v_helper oid := pg_catalog.to_regprocedure(
    's2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)');
  v_source text;
  v_transition_calls integer;
  v_constraint_count integer;
  v_constraint_expression text;
  v_constraint_semantics_exact boolean;
  v_constraint_failures text;
begin
  if v_helper is null then
    raise exception '028 precondition: validation-start service helper is absent'
      using errcode = '55000';
  end if;

  select p.prosrc into strict v_source
  from pg_catalog.pg_proc p
  join pg_catalog.pg_roles owner on owner.oid = p.proowner
  where p.oid = v_helper
    and owner.rolname = 's2t_fhir_owner'
    and p.prosecdef
    and p.provolatile = 'v'
    and p.prokind = 'f'
    and p.proconfig is not distinct from array['search_path=""']
    and pg_catalog.pg_get_function_result(p.oid) = 'jsonb';

  if v_source is null then
    raise exception '028 precondition: validation-start service helper metadata drift'
      using errcode = '55000';
  end if;

  select count(*) into v_transition_calls
  from pg_catalog.regexp_matches(
    v_source, 's2t_fhir\._transition_candidate_import_request', 'g');

  if v_transition_calls <> 2
     or v_source not like '%set baseline_version_id = v_baseline_id,%'
     or v_source not like '%import_run_id = v_import_id,%'
     or v_source not like '%validation_attempt_id = p_validation_attempt_id,%'
     or v_source not like '%validation_lease_expires_at = p_lease_expires_at%'
     or v_source not like '%p_request_id, ''UPLOADED'', ''VALIDATING'', ''VALIDATION_STARTED''%' then
    raise exception '028 precondition: expected Migration 026 validation-start implementation drifted'
      using errcode = '55000';
  end if;

  select count(*) into v_constraint_count
  from pg_catalog.pg_constraint c
  where c.conrelid = 's2t_fhir.candidate_import_request'::pg_catalog.regclass
    and c.conname = 'candidate_import_request_link_shape_ck';
  if v_constraint_count <> 1 then
    raise exception '028 precondition: expected exactly one Candidate-import link-shape constraint, found %',
      v_constraint_count using errcode = '55000';
  end if;

  select case when c.contype = 'c' and c.convalidated
                   and not c.condeferrable and not c.condeferred
              then pg_catalog.pg_get_expr(c.conbin, c.conrelid) end
    into strict v_constraint_expression
  from pg_catalog.pg_constraint c
  where c.conrelid = 's2t_fhir.candidate_import_request'::pg_catalog.regclass
    and c.conname = 'candidate_import_request_link_shape_ck';
  if v_constraint_expression is null then
    raise exception '028 precondition: Candidate-import link-shape constraint metadata drifted'
      using errcode = '55000';
  end if;

  execute pg_catalog.format($constraint_probe_sql$
    with probe(
      probe_name,current_state,artifact_id,baseline_version_id,import_run_id,
      validation_run_id,published_candidate_lifecycle_event_id,
      validation_attempt_id,validation_lease_expires_at,expected
    ) as (values
      ('UPLOADED valid','UPLOADED'::text,'00000000-0000-0000-0000-000000000001'::uuid,
       null::uuid,null::uuid,null::uuid,null::uuid,null::uuid,null::timestamptz,true),
      ('UPLOADED missing artifact','UPLOADED',null,null,null,null,null,null,null,false),
      ('UPLOADED attempt forbidden','UPLOADED','00000000-0000-0000-0000-000000000001',
       null,null,null,null,'00000000-0000-0000-0000-000000000006',null,false),
      ('UPLOADED lease forbidden','UPLOADED','00000000-0000-0000-0000-000000000001',
       null,null,null,null,null,'2100-01-01 00:00:00+00',false),
      ('VALIDATING valid','VALIDATING','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,'00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',true),
      ('VALIDATING valid without lease','VALIDATING','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,null,null,true),
      ('VALIDATING missing artifact','VALIDATING',null,
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,null,null,false),
      ('VALIDATING missing baseline','VALIDATING','00000000-0000-0000-0000-000000000001',
       null,'00000000-0000-0000-0000-000000000003',null,null,null,null,false),
      ('VALIDATING missing import','VALIDATING','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002',null,null,null,null,null,false),
      ('READY valid','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,true),
      ('READY missing artifact','READY_TO_PUBLISH',null,
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('READY missing baseline','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       null,'00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('READY missing import','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002',null,
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('READY missing validation','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,null,null,false),
      ('READY attempt forbidden','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,
       '00000000-0000-0000-0000-000000000006',null,false),
      ('READY lease forbidden','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,
       null,'2100-01-01 00:00:00+00',false),
      ('PUBLISHED valid','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,true),
      ('PUBLISHED missing artifact','PUBLISHED',null,
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,false),
      ('PUBLISHED missing baseline','PUBLISHED','00000000-0000-0000-0000-000000000001',
       null,'00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,false),
      ('PUBLISHED missing import','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002',null,
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,false),
      ('PUBLISHED missing validation','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,'00000000-0000-0000-0000-000000000005',null,null,false),
      ('PUBLISHED missing lifecycle','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('PUBLISHED attempt forbidden','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       '00000000-0000-0000-0000-000000000006',null,false),
      ('PUBLISHED lease forbidden','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,'2100-01-01 00:00:00+00',false),
      ('AWAITING lease pair forbidden','AWAITING_UPLOAD',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false),
      ('VALIDATION_FAILED lease pair forbidden','VALIDATION_FAILED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false),
      ('FAILED without validation lease valid','FAILED',null,null,null,null,null,null,null,true),
      ('FAILED attempt forbidden','FAILED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006',null,false),
      ('FAILED lease forbidden','FAILED',null,null,null,null,null,
       null,'2100-01-01 00:00:00+00',false),
      ('ABORTED lease pair forbidden','ABORTED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false)
    )
    select bool_and((%s) is not distinct from expected),
           pg_catalog.string_agg(probe_name, ', ' order by probe_name)
             filter (where (%s) is distinct from expected)
    from probe
  $constraint_probe_sql$, v_constraint_expression, v_constraint_expression)
  into v_constraint_semantics_exact, v_constraint_failures;

  if not coalesce(v_constraint_semantics_exact, false) then
    raise exception '028 precondition: Candidate-import link-shape semantic probes failed: %',
      coalesce(v_constraint_failures, 'unknown probe failure')
      using errcode = '55000';
  end if;

  if pg_catalog.to_regprocedure(
       's2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb)') is null
     or not exists (
       select 1
       from pg_catalog.pg_trigger t
       where t.tgrelid = 's2t_fhir.candidate_import_request'::pg_catalog.regclass
         and t.tgname = 'candidate_import_request_validate_trg'
         and t.tgenabled = 'O'
         and not t.tgisinternal
         and t.tgfoid = pg_catalog.to_regprocedure(
           's2t_fhir.validate_candidate_import_request()')
     ) then
    raise exception '028 precondition: transition helper or request validation trigger drifted'
      using errcode = '55000';
  end if;
end
$precondition$;

create or replace function s2t_fhir_api._service_begin_candidate_import_validation(
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
  v_sequence integer;
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

  -- The request row must never expose VALIDATING-only links while it is still
  -- UPLOADED. Append the matching event under the request-row lock, then make
  -- the state and all validation links visible in one constraint-valid UPDATE.
  select coalesce(max(e.sequence_number), 0) + 1 into v_sequence
  from s2t_fhir.candidate_import_request_event e
  where e.candidate_import_request_id = p_request_id;

  insert into s2t_fhir.candidate_import_request_event (
    candidate_import_request_id, sequence_number, event_code,
    from_state, to_state, occurred_at, actor_principal_id,
    initiating_human_principal_id, correlation_id,
    detail_schema_id, detail_schema_version, detail_json
  ) values (
    p_request_id, v_sequence, 'VALIDATION_STARTED',
    'UPLOADED', 'VALIDATING', pg_catalog.transaction_timestamp(),
    p_service_actor_id, v_request.uploader_principal_id, p_correlation_id,
    'candidate-import-validation', 1,
    pg_catalog.jsonb_build_object(
      'parserName', p_parser_name, 'parserVersion', p_parser_version,
      'importSpecificationVersion', p_import_specification_version,
      'validationAttemptId', p_validation_attempt_id)
  );

  update s2t_fhir.candidate_import_request r
  set current_state = 'VALIDATING',
      baseline_version_id = v_baseline_id,
      import_run_id = v_import_id,
      validation_attempt_id = p_validation_attempt_id,
      validation_lease_expires_at = p_lease_expires_at,
      updated_at = pg_catalog.transaction_timestamp()
  where r.candidate_import_request_id = p_request_id
    and r.current_state = 'UPLOADED';
  if not found then
    raise exception 'IMPORT_CONFLICT: validation start lost the UPLOADED state lock'
      using errcode = '23505';
  end if;

  return pg_catalog.jsonb_build_object(
    'requestId', p_request_id, 'state', 'VALIDATING',
    'validationAttemptId', p_validation_attempt_id,
    'baselineVersionId', v_baseline_id, 'importRunId', v_import_id,
    'idempotentReplay', false);
end
$function$;

do $postcondition$
declare
  v_helper oid := pg_catalog.to_regprocedure(
    's2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)');
  v_source text;
  v_transition_calls integer;
begin
  select p.prosrc into strict v_source
  from pg_catalog.pg_proc p
  join pg_catalog.pg_roles owner on owner.oid = p.proowner
  where p.oid = v_helper
    and owner.rolname = 's2t_fhir_owner'
    and p.prosecdef
    and p.provolatile = 'v'
    and p.prokind = 'f'
    and p.proconfig is not distinct from array['search_path=""']
    and pg_catalog.pg_get_function_result(p.oid) = 'jsonb';

  select count(*) into v_transition_calls
  from pg_catalog.regexp_matches(
    v_source, 's2t_fhir\._transition_candidate_import_request', 'g');

  if v_transition_calls <> 1
     or v_source not like '%''VALIDATION_STARTED'',%'
     or v_source not like '%set current_state = ''VALIDATING'',%'
     or v_source not like '%baseline_version_id = v_baseline_id,%'
     or v_source not like '%import_run_id = v_import_id,%'
     or v_source not like '%and r.current_state = ''UPLOADED'';%'
     or v_source not like '%VALIDATION_RECLAIMED%'
     or v_source not like '%''idempotentReplay'', true%' then
    raise exception '028 postcondition: atomic validation-start implementation is incomplete'
      using errcode = '55000';
  end if;
end
$postcondition$;

reset role;

commit;

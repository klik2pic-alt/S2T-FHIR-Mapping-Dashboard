begin;

set role s2t_fhir_owner;

do $precondition$
declare
  v_function_count integer;
begin
  select count(*) into v_function_count
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace
    on namespace.oid = procedure.pronamespace
  where namespace.nspname = 's2t_fhir_api'
    and procedure.proname = 'get_my_candidate_import'
    and pg_catalog.pg_get_function_identity_arguments(procedure.oid)
          = 'p_candidate_import_request_id uuid'
    and procedure.prokind = 'f'
    and procedure.prorettype = 'jsonb'::regtype
    and procedure.provolatile = 's'
    and procedure.prosecdef
    and procedure.proconfig is not distinct from array['search_path=""']
    and pg_catalog.pg_get_userbyid(procedure.proowner) = 's2t_fhir_owner';

  if v_function_count <> 1 then
    raise exception '030 precondition: get_my_candidate_import metadata drifted'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_attribute attribute
    where attribute.attrelid = 's2t_fhir.candidate_import_request'::regclass
      and attribute.attname = 'baseline_version_id'
      and attribute.atttypid = 'uuid'::regtype
      and attribute.attnotnull is false
      and attribute.attnum > 0
      and not attribute.attisdropped
  ) then
    raise exception '030 precondition: candidate_import_request.baseline_version_id drifted'
      using errcode = '55000';
  end if;
end
$precondition$;

create or replace function s2t_fhir_api.get_my_candidate_import(
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
    'baselineVersionId', v_request.baseline_version_id,
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

alter function s2t_fhir_api.get_my_candidate_import(uuid)
  owner to s2t_fhir_owner;

revoke all on function s2t_fhir_api.get_my_candidate_import(uuid)
  from public, anon, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
grant execute on function s2t_fhir_api.get_my_candidate_import(uuid)
  to authenticated;

comment on function s2t_fhir_api.get_my_candidate_import(uuid) is
  'Returns the authenticated uploader safe Candidate import projection, including its server-assigned baseline version identity, without raw rows, private paths, or diagnostics.';

reset role;

commit;

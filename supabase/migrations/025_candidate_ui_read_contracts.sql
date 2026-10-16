-- Migration 025: Candidate UI read contracts.
-- Additive read-model work over immutable Migrations 023 and 024.

begin;

set role s2t_fhir_owner;

-- Hard-stop on definition drift. These hashes are md5(regexp_replace(prosrc,
-- '\s+', ' ', 'g')) for the accepted Migration 023 function bodies.
do $precondition$
declare
  v_assert_oid oid := pg_catalog.to_regprocedure(
    's2t_fhir.assert_candidate_activation_eligibility(uuid,uuid,uuid,uuid,timestamp with time zone)'
  );
  v_validator_oid oid := pg_catalog.to_regprocedure(
    's2t_fhir.validate_baseline_activation_context()'
  );
  v_view_oid oid := pg_catalog.to_regclass(
    's2t_fhir_api.governance_mapping_links'
  );
  v_columns text[];
  v_types text[];
begin
  if v_assert_oid is null or v_validator_oid is null then
    raise exception '025 precondition: required Migration 023 Promotion definitions are absent'
      using errcode = '55000';
  end if;

  if pg_catalog.md5(pg_catalog.regexp_replace(
       (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_assert_oid),
       '\s+', ' ', 'g')) <> 'b72c63712005f45e443dae17cfbdad09' then
    raise exception '025 precondition: Candidate activation assertion definition drift'
      using errcode = '55000';
  end if;

  if pg_catalog.md5(pg_catalog.regexp_replace(
       (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_validator_oid),
       '\s+', ' ', 'g')) <> 'c3adf758b7385c53a3d44cb005ad45bb' then
    raise exception '025 precondition: activation-context validator definition drift'
      using errcode = '55000';
  end if;

  if pg_catalog.to_regprocedure(
       's2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir.promote_current_candidate(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone,text,uuid,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api._resolve_authenticated_principal()'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir._require_current_candidate_context(uuid,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir.assert_release_gate_evaluation_integrity(uuid)'
     ) is null then
    raise exception '025 precondition: required Promotion or identity dependency is absent'
      using errcode = '55000';
  end if;

  if v_view_oid is null then
    raise exception '025 precondition: governance_mapping_links is absent'
      using errcode = '55000';
  end if;

  select pg_catalog.array_agg(a.attname::text order by a.attnum),
         pg_catalog.array_agg(
           pg_catalog.format_type(a.atttypid, a.atttypmod)
           order by a.attnum
         )
    into v_columns, v_types
  from pg_catalog.pg_attribute a
  where a.attrelid = v_view_oid
    and a.attnum > 0
    and not a.attisdropped;

  if v_columns is distinct from array[
    'link_id','question_id','resource_config_id','baseline_code','node_id',
    'mapping_kind','fhir_resource_type','version_label','target_element',
    'element_path','profile_label','decision_status_at_link','source_sheet',
    'source_row','source_cell_range','artifact_sha256','linked_by_principal',
    'recorded_at','is_active'
  ]::text[] then
    raise exception '025 precondition: governance_mapping_links public shape drift'
      using errcode = '55000';
  end if;

  if v_types is distinct from array[
    'uuid','uuid','text','text','text','text','text','text','text','text[]',
    'text','text','text','integer','text','text','uuid',
    'timestamp with time zone','boolean'
  ]::text[] then
    raise exception '025 precondition: governance_mapping_links public type drift'
      using errcode = '55000';
  end if;

  if not coalesce((
    select count(*) = 3 and bool_and(
      case a.attname
        when 'baseline_version_id' then a.atttypid = 'uuid'::regtype
        when 'review_target_lifecycle_event_id' then a.atttypid = 'uuid'::regtype
        when 'lifecycle_status_at_link' then a.atttypid = 'text'::regtype
        else false
      end
    )
    from pg_catalog.pg_attribute a
    where a.attrelid = pg_catalog.to_regclass(
      's2t_governance.governance_mapping_link'
    )
      and a.attname in (
        'baseline_version_id',
        'review_target_lifecycle_event_id',
        'lifecycle_status_at_link'
      )
      and a.attnum > 0
      and not a.attisdropped
  ), false) then
    raise exception '025 precondition: governance provenance source type drift'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from (values
      ('s2t_fhir_api._candidate_ui_capability_state(uuid)'),
      ('s2t_fhir_api._candidate_ui_snapshot(text)'),
      ('s2t_fhir._evaluate_candidate_promotion_readiness(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone,boolean,boolean)'),
      ('s2t_fhir._raise_candidate_promotion_evaluation(jsonb)'),
      ('s2t_fhir_api.get_candidate_ui_context(text)'),
      ('s2t_fhir_api.get_candidate_promotion_readiness(text,uuid,uuid,uuid,uuid,timestamp with time zone)'),
      ('s2t_fhir_api.get_my_candidate_ui_capabilities()'),
      ('s2t_fhir_api.get_my_candidate_review_session(uuid,uuid)')
    ) expected(signature)
    where pg_catalog.to_regprocedure(expected.signature) is not null
  ) then
    raise exception '025 precondition: one or more Migration 025 functions already exist'
      using errcode = '55000';
  end if;
end
$precondition$;

-- Current-principal capability projection. It deliberately exposes no grant or
-- principal identity and is never executable by browser roles.
create function s2t_fhir_api._candidate_ui_capability_state(
  p_principal_id uuid
)
returns table(can_review_candidate boolean, can_promote_candidate boolean)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_review_count integer;
  v_promote_count integer;
begin
  select count(*) into v_review_count
  from s2t_fhir.review_actor_authorization a
  where a.principal_id = p_principal_id
    and a.capability_code = 'S2T_REVIEW_WRITE'
    and a.effective_at <= pg_catalog.transaction_timestamp()
    and a.revoked_at is null;

  select count(*) into v_promote_count
  from s2t_fhir.baseline_action_authorization a
  where a.principal_id = p_principal_id
    and a.capability_code = 'S2T_BASELINE_PROMOTE'
    and a.effective_at <= pg_catalog.transaction_timestamp()
    and a.revoked_at is null;

  if v_review_count > 1 or v_promote_count > 1 then
    raise exception 'authenticated principal Candidate UI authorization is ambiguous'
      using errcode = '42501';
  end if;

  return query select v_review_count = 1, v_promote_count = 1;
end
$function$;

-- One cohesive resource/series/Candidate/ACTIVE/evidence snapshot. Ambiguity is
-- an integrity error; no ORDER BY/LIMIT is used to choose among current rows.
create function s2t_fhir_api._candidate_ui_snapshot(
  p_resource_config_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_source_system text;
  v_fhir_resource text;
  v_series_count integer;
  v_series_id uuid;
  v_candidate_count integer;
  v_candidate_baseline_id uuid;
  v_candidate_event_id uuid;
  v_candidate_occurred_at timestamptz;
  v_active_count integer;
  v_active_baseline_id uuid;
  v_active_event_id uuid;
  v_active_occurred_at timestamptz;
  v_context_count integer;
  v_artifact_id uuid;
  v_import_run_id uuid;
  v_candidate_effective_at timestamptz;
  v_validation_count integer;
  v_validation_id uuid;
  v_validation_outcome text;
  v_candidate_count_value bigint;
  v_accepted_count bigint;
  v_warning_count bigint;
  v_error_count bigint;
  v_quarantined_count bigint;
  v_validation_started_at timestamptz;
  v_validation_completed_at timestamptz;
  v_gate_count integer;
  v_gate_id uuid;
  v_gate_outcome text;
  v_gate_code text;
  v_gate_version text;
  v_gate_evaluated_at timestamptz;
begin
  if nullif(pg_catalog.btrim(p_resource_config_id), '') is null then
    raise exception 'resource_config_id is required' using errcode = '22023';
  end if;

  select r.source_system, r.fhir_resource
    into v_source_system, v_fhir_resource
  from s2t_fhir.mapping_resource_registry r
  where r.resource_config_id = p_resource_config_id
    and r.is_enabled;

  if not found then
    raise exception 'enabled Candidate resource context % does not exist', p_resource_config_id
      using errcode = 'P0002';
  end if;

  select count(*), min(s.baseline_series_id::text)::uuid
    into v_series_count, v_series_id
  from s2t_fhir.baseline_series s
  where s.source_system = v_source_system
    and s.fhir_resource = v_fhir_resource;

  if v_series_count <> 1 then
    raise exception 'Candidate resource % requires exactly one baseline series, found %',
      p_resource_config_id, v_series_count
      using errcode = '23514';
  end if;

  select count(*),
         min(b.baseline_version_id::text)::uuid,
         min(e.baseline_lifecycle_event_id::text)::uuid,
         min(e.occurred_at)
    into v_candidate_count, v_candidate_baseline_id,
         v_candidate_event_id, v_candidate_occurred_at
  from s2t_fhir.baseline_version b
  join s2t_fhir.current_baseline_lifecycle_event e
    on e.baseline_version_id = b.baseline_version_id
  join s2t_fhir.reference_value status
    on status.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where b.baseline_series_id = v_series_id
    and status.value_code = 'CANDIDATE';

  if v_candidate_count > 1 then
    raise exception 'baseline series % has multiple current Candidate baselines', v_series_id
      using errcode = '23514';
  end if;

  select count(*),
         min(b.baseline_version_id::text)::uuid,
         min(e.baseline_lifecycle_event_id::text)::uuid,
         min(e.occurred_at)
    into v_active_count, v_active_baseline_id,
         v_active_event_id, v_active_occurred_at
  from s2t_fhir.baseline_version b
  join s2t_fhir.current_baseline_lifecycle_event e
    on e.baseline_version_id = b.baseline_version_id
  join s2t_fhir.reference_value status
    on status.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where b.baseline_series_id = v_series_id
    and status.value_code = 'ACTIVE';

  if v_active_count > 1 then
    raise exception 'baseline series % has multiple current ACTIVE baselines', v_series_id
      using errcode = '23514';
  end if;

  if v_candidate_count = 1 then
    select count(*), min(c.artifact_id::text)::uuid,
           min(c.import_run_id::text)::uuid, min(c.effective_at)
      into v_context_count, v_artifact_id, v_import_run_id,
           v_candidate_effective_at
    from s2t_fhir.baseline_candidate_context c
    where c.baseline_version_id = v_candidate_baseline_id
      and c.candidate_lifecycle_event_id = v_candidate_event_id;

    if v_context_count <> 1 then
      raise exception 'current Candidate publication context is missing or ambiguous'
        using errcode = '23514';
    end if;

    select count(*), min(g.release_gate_evaluation_id::text)::uuid
      into v_gate_count, v_gate_id
    from s2t_fhir.current_release_gate_evaluation g
    join s2t_fhir.validation_run validation
      on validation.validation_run_id = g.validation_run_id
     and validation.import_run_id = v_import_run_id
     and validation.artifact_id = v_artifact_id
    where g.baseline_version_id = v_candidate_baseline_id
      and g.artifact_id = v_artifact_id;

    if v_gate_count > 1 then
      raise exception 'current Candidate release-gate evidence is ambiguous'
        using errcode = '23514';
    elsif v_gate_count = 1 then
      select outcome.value_code, definition.gate_code, definition.version_label,
             gate.evaluated_at, gate.validation_run_id
        into strict v_gate_outcome, v_gate_code, v_gate_version,
             v_gate_evaluated_at, v_validation_id
      from s2t_fhir.release_gate_evaluation gate
      join s2t_fhir.reference_value outcome
        on outcome.reference_value_id = gate.gate_outcome_value_id
      join s2t_fhir.reference_domain outcome_domain
        on outcome_domain.reference_domain_id = outcome.reference_domain_id
       and outcome_domain.domain_code = 'RELEASE_GATE_OUTCOME'
      join s2t_fhir.release_gate_definition definition
        on definition.release_gate_definition_id = gate.release_gate_definition_id
      where gate.release_gate_evaluation_id = v_gate_id;
      v_validation_count := 1;
    else
      select count(*), min(v.validation_run_id::text)::uuid
        into v_validation_count, v_validation_id
      from s2t_fhir.validation_run v
      where v.import_run_id = v_import_run_id
        and v.artifact_id = v_artifact_id;

      if v_validation_count > 1 then
        raise exception 'current Candidate validation evidence is ambiguous without a gate'
          using errcode = '23514';
      end if;
    end if;

    if v_validation_count = 1 then
      select outcome.value_code, v.candidate_count, v.accepted_count,
             v.warning_count, v.error_count, v.quarantined_count,
             v.started_at, v.completed_at
        into strict v_validation_outcome, v_candidate_count_value,
             v_accepted_count, v_warning_count, v_error_count,
             v_quarantined_count, v_validation_started_at,
             v_validation_completed_at
      from s2t_fhir.validation_run v
      join s2t_fhir.reference_value outcome
        on outcome.reference_value_id = v.outcome_value_id
      join s2t_fhir.reference_domain outcome_domain
        on outcome_domain.reference_domain_id = outcome.reference_domain_id
       and outcome_domain.domain_code = 'VALIDATION_OUTCOME'
      where v.validation_run_id = v_validation_id;
    end if;
  end if;

  return pg_catalog.jsonb_build_object(
    'resource', pg_catalog.jsonb_build_object(
      'resourceConfigId', p_resource_config_id,
      'sourceSystem', v_source_system,
      'fhirResource', v_fhir_resource,
      'baselineSeriesId', v_series_id
    ),
    'candidate', case when v_candidate_count = 1 then
      pg_catalog.jsonb_build_object(
        'baselineVersionId', v_candidate_baseline_id,
        'lifecycleEventId', v_candidate_event_id,
        'lifecycleEffectiveAt', v_candidate_occurred_at,
        'publicationEffectiveAt', v_candidate_effective_at,
        'importRunId', v_import_run_id,
        'artifactId', v_artifact_id
      ) else 'null'::jsonb end,
    'active', case when v_active_count = 1 then
      pg_catalog.jsonb_build_object(
        'baselineVersionId', v_active_baseline_id,
        'lifecycleEventId', v_active_event_id,
        'lifecycleEffectiveAt', v_active_occurred_at
      ) else 'null'::jsonb end,
    'validation', case when v_validation_count = 1 then
      pg_catalog.jsonb_build_object(
        'validationRunId', v_validation_id,
        'outcome', v_validation_outcome,
        'candidateCount', v_candidate_count_value,
        'acceptedCount', v_accepted_count,
        'warningCount', v_warning_count,
        'errorCount', v_error_count,
        'quarantinedCount', v_quarantined_count,
        'startedAt', v_validation_started_at,
        'completedAt', v_validation_completed_at
      ) else 'null'::jsonb end,
    'releaseGate', case when v_gate_count = 1 then
      pg_catalog.jsonb_build_object(
        'releaseGateEvaluationId', v_gate_id,
        'gateCode', v_gate_code,
        'gateVersion', v_gate_version,
        'outcome', v_gate_outcome,
        'evaluatedAt', v_gate_evaluated_at
      ) else 'null'::jsonb end,
    'observedAt', pg_catalog.transaction_timestamp()
  );
end
$function$;

-- Shared, non-mutating Promotion evaluator. p_enforce_expected_evidence is true
-- on the mutation path and false for UI diagnosis of missing gate evidence.
create function s2t_fhir._evaluate_candidate_promotion_readiness(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_expected_import_run_id uuid,
  p_expected_release_gate_evaluation_id uuid,
  p_expected_active_baseline_version_id uuid,
  p_expected_active_lifecycle_event_id uuid,
  p_effective_at timestamptz,
  p_enforce_expected_evidence boolean,
  p_check_active_context boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_series_id uuid;
  v_source_system text;
  v_fhir_resource text;
  v_authoritative_count integer;
  v_import_completed_at timestamptz;
  v_gate_count integer;
  v_any_gate_count integer;
  v_any_gate_outcome text;
  v_validation_count integer;
  v_gate_id uuid;
  v_validation_run_id uuid;
  v_gate_import_run_id uuid;
  v_gate_evaluated_at timestamptz;
  v_gate_recorded_at timestamptz;
  v_mapping_count bigint;
  v_reviewed_count bigint;
  v_last_review_at timestamptz;
  v_closed_session_count integer;
  v_open_session_count integer;
  v_last_session_end timestamptz;
  v_active_count integer;
  v_active_baseline_id uuid;
  v_active_event_id uuid;
  v_active_occurred_at timestamptz;
  v_resource_count integer;
  v_other_active_context_count integer;
  v_blockers jsonb := '[]'::jsonb;
  v_legacy_sqlstate text;
  v_legacy_message text;
  v_state text;
  v_message text;
begin
  if p_effective_at is null
     or (p_enforce_expected_evidence and (
       p_expected_import_run_id is null
       or p_expected_release_gate_evaluation_id is null
     )) then
    v_legacy_sqlstate := '22023';
    v_legacy_message := 'expected import, release-gate evaluation, and promotion effective time are required';
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'CANDIDATE_CONTEXT_INVALID')
    );
  end if;

  if p_check_active_context and (p_expected_active_baseline_version_id is null)
     <> (p_expected_active_lifecycle_event_id is null) then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '22023';
      v_legacy_message := 'expected ACTIVE baseline and lifecycle event must be both null or both non-null';
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'ACTIVE_CONTEXT_STALE')
    );
  end if;

  if v_legacy_sqlstate is not null then
    return pg_catalog.jsonb_build_object(
      'ready', false, 'blockers', v_blockers,
      'legacyFailure', pg_catalog.jsonb_build_object(
        'sqlstate', v_legacy_sqlstate, 'message', v_legacy_message),
      'observedAt', pg_catalog.transaction_timestamp()
    );
  end if;

  begin
    v_context := s2t_fhir._require_current_candidate_context(
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id
    );
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    select bv.baseline_series_id into v_series_id
    from s2t_fhir.baseline_version bv
    where bv.baseline_version_id = p_baseline_version_id;

    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'code', case when exists (
          select 1
          from s2t_fhir.baseline_version b
          join s2t_fhir.current_baseline_lifecycle_event e
            on e.baseline_version_id = b.baseline_version_id
          join s2t_fhir.reference_value s
            on s.reference_value_id = e.lifecycle_status_value_id
          where b.baseline_series_id = v_series_id
            and s.value_code = 'CANDIDATE'
        ) then 'CANDIDATE_NOT_CURRENT' else 'NO_CURRENT_CANDIDATE' end
      )
    );
    return pg_catalog.jsonb_build_object(
      'ready', false, 'blockers', v_blockers,
      'legacyFailure', pg_catalog.jsonb_build_object(
        'sqlstate', v_state, 'message', v_message),
      'observedAt', pg_catalog.transaction_timestamp()
    );
  end;

  select bv.baseline_series_id, bs.source_system, bs.fhir_resource
    into strict v_series_id, v_source_system, v_fhir_resource
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  where bv.baseline_version_id = p_baseline_version_id;

  if v_context.import_run_id is distinct from p_expected_import_run_id then
    v_legacy_sqlstate := '40001';
    v_legacy_message := pg_catalog.format(
      'candidate import context is stale: expected %s, current %s',
      p_expected_import_run_id, v_context.import_run_id);
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'CANDIDATE_CONTEXT_INVALID')
    );
  end if;

  select count(*) into v_authoritative_count
  from s2t_fhir.baseline_artifact ba
  join s2t_fhir.reference_value role_value
    on role_value.reference_value_id = ba.artifact_role_value_id
  join s2t_fhir.reference_domain role_domain
    on role_domain.reference_domain_id = role_value.reference_domain_id
   and role_domain.domain_code = 'ARTIFACT_ROLE'
  where ba.baseline_version_id = v_context.baseline_version_id
    and ba.artifact_id = v_context.artifact_id
    and role_value.value_code = 'AUTHORITATIVE_SOURCE';

  if v_authoritative_count <> 1 or (
    select count(*)
    from s2t_fhir.baseline_artifact ba
    join s2t_fhir.reference_value role_value
      on role_value.reference_value_id = ba.artifact_role_value_id
    join s2t_fhir.reference_domain role_domain
      on role_domain.reference_domain_id = role_value.reference_domain_id
     and role_domain.domain_code = 'ARTIFACT_ROLE'
    where ba.baseline_version_id = v_context.baseline_version_id
      and role_value.value_code = 'AUTHORITATIVE_SOURCE'
  ) <> 1 then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := 'promotion requires exactly the Candidate publication authoritative artifact';
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'CANDIDATE_CONTEXT_INVALID')
    );
  end if;

  select ir.completed_at into v_import_completed_at
  from s2t_fhir.import_run ir
  join s2t_fhir.reference_value status
    on status.reference_value_id = ir.terminal_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'IMPORT_RUN_STATUS'
  where ir.import_run_id = p_expected_import_run_id
    and ir.baseline_version_id = v_context.baseline_version_id
    and ir.artifact_id = v_context.artifact_id
    and ir.completed_at is not null
    and status.value_code = 'COMMITTED';

  if not found then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := 'promotion requires the exact Candidate COMMITTED import context';
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'IMPORT_NOT_COMMITTED')
    );
  end if;

  select count(*),
         (pg_catalog.array_agg(gate.release_gate_evaluation_id))[1],
         (pg_catalog.array_agg(gate.validation_run_id))[1],
         (pg_catalog.array_agg(import_run.import_run_id))[1],
         min(gate.evaluated_at), min(gate.recorded_at)
    into v_gate_count, v_gate_id, v_validation_run_id,
         v_gate_import_run_id, v_gate_evaluated_at, v_gate_recorded_at
  from s2t_fhir.current_release_gate_evaluation gate
  join s2t_fhir.reference_value outcome
    on outcome.reference_value_id = gate.gate_outcome_value_id
  join s2t_fhir.reference_domain outcome_domain
    on outcome_domain.reference_domain_id = outcome.reference_domain_id
   and outcome_domain.domain_code = 'RELEASE_GATE_OUTCOME'
  join s2t_fhir.artifact artifact
    on artifact.artifact_id = gate.artifact_id
   and artifact.sha256_digest = gate.artifact_digest
  join s2t_fhir.validation_run validation
    on validation.validation_run_id = gate.validation_run_id
   and validation.validation_ruleset_id = gate.validation_ruleset_id
   and validation.artifact_id = gate.artifact_id
   and validation.artifact_digest = gate.artifact_digest
  join s2t_fhir.import_run import_run
    on import_run.import_run_id = validation.import_run_id
   and import_run.baseline_version_id = gate.baseline_version_id
   and import_run.artifact_id = gate.artifact_id
  join s2t_fhir.reference_value import_status
    on import_status.reference_value_id = import_run.terminal_status_value_id
  join s2t_fhir.reference_domain import_domain
    on import_domain.reference_domain_id = import_status.reference_domain_id
   and import_domain.domain_code = 'IMPORT_RUN_STATUS'
  where gate.baseline_version_id = v_context.baseline_version_id
    and gate.artifact_id = v_context.artifact_id
    and outcome.value_code = 'PASSED'
    and import_status.value_code = 'COMMITTED';

  if v_gate_count <> 1
     or v_gate_id is distinct from p_expected_release_gate_evaluation_id
     or v_gate_import_run_id is distinct from p_expected_import_run_id then
    select count(*), min(outcome.value_code)
      into v_any_gate_count, v_any_gate_outcome
    from s2t_fhir.current_release_gate_evaluation gate
    join s2t_fhir.reference_value outcome
      on outcome.reference_value_id = gate.gate_outcome_value_id
    join s2t_fhir.validation_run validation
      on validation.validation_run_id = gate.validation_run_id
     and validation.import_run_id = v_context.import_run_id
     and validation.artifact_id = v_context.artifact_id
    where gate.baseline_version_id = v_context.baseline_version_id
      and gate.artifact_id = v_context.artifact_id;

    select count(*) into v_validation_count
    from s2t_fhir.validation_run validation
    where validation.import_run_id = v_context.import_run_id
      and validation.artifact_id = v_context.artifact_id;

    if v_validation_count = 0 then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'VALIDATION_MISSING')
      );
    end if;
    if v_any_gate_count = 0 then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'RELEASE_GATE_MISSING')
      );
    elsif v_any_gate_count > 1 then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'AMBIGUOUS_STATE')
      );
    elsif v_any_gate_outcome <> 'PASSED' then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'RELEASE_GATE_NOT_PASSED')
      );
    else
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'CANDIDATE_CONTEXT_INVALID')
      );
    end if;

    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '40001';
      v_legacy_message := pg_catalog.format(
        'release-gate context is stale or ambiguous: expected gate %s import %s, current gate %s import %s',
        coalesce(p_expected_release_gate_evaluation_id::text, '<NULL>'),
        coalesce(p_expected_import_run_id::text, '<NULL>'),
        coalesce(v_gate_id::text, '<NULL>'),
        coalesce(v_gate_import_run_id::text, '<NULL>'));
    end if;
  else
    begin
      perform s2t_fhir.assert_release_gate_evaluation_integrity(v_gate_id);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
      if v_legacy_sqlstate is null then
        v_legacy_sqlstate := v_state;
        v_legacy_message := v_message;
      end if;
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'EVIDENCE_INTEGRITY_INVALID')
      );
    end;
  end if;

  with candidate_nodes as (
    select n.mapping_record_id
    from s2t_fhir_api._candidate_mapping_nodes(
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id
    ) n
  )
  select count(*),
         count(*) filter (
           where current_review.review_status = 'REVIEWED'
             and review_event.review_target_lifecycle_event_id
                   = p_expected_candidate_lifecycle_event_id
         ),
         max(review_event.occurred_at)
    into v_mapping_count, v_reviewed_count, v_last_review_at
  from candidate_nodes node
  left join s2t_fhir.current_mapping_review current_review
    on current_review.baseline_version_id = p_baseline_version_id
   and current_review.mapping_record_id = node.mapping_record_id
  left join s2t_fhir.mapping_review_event review_event
    on review_event.mapping_review_event_id = current_review.mapping_review_event_id;

  if v_mapping_count = 0 or v_reviewed_count <> v_mapping_count then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := 'promotion requires every Candidate mapping to be REVIEWED in the exact Candidate lifecycle context';
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'code', case when v_mapping_count = 0
          then 'NO_CANDIDATE_MAPPINGS' else 'REVIEW_INCOMPLETE' end,
        'mappingCount', v_mapping_count,
        'reviewedCount', v_reviewed_count
      )
    );
  end if;

  select count(*) filter (where session.ended_at is not null),
         count(*) filter (where session.ended_at is null),
         max(session.ended_at)
    into v_closed_session_count, v_open_session_count, v_last_session_end
  from s2t_fhir.review_session session
  where session.baseline_version_id = p_baseline_version_id
    and session.review_target_lifecycle_event_id = p_expected_candidate_lifecycle_event_id;

  if v_closed_session_count = 0 or v_open_session_count <> 0 then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := 'promotion requires at least one closed Candidate review session and no open Candidate review session';
    end if;
    if v_closed_session_count = 0 then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'CLOSED_REVIEW_SESSION_MISSING')
      );
    end if;
    if v_open_session_count <> 0 then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'code', 'OPEN_REVIEW_SESSION_EXISTS',
          'openSessionCount', v_open_session_count)
      );
    end if;
  end if;

  if p_effective_at < v_context.effective_at
     or p_effective_at < v_import_completed_at
     or p_effective_at < v_gate_evaluated_at
     or p_effective_at < v_gate_recorded_at
     or p_effective_at < v_last_review_at
     or p_effective_at < v_last_session_end then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := 'promotion effective time cannot precede Candidate, import, gate, or review evidence';
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'EFFECTIVE_TIME_BEFORE_EVIDENCE')
    );
  end if;

  if p_check_active_context then
    select count(*), min(b.baseline_version_id::text)::uuid,
           min(event.baseline_lifecycle_event_id::text)::uuid,
           min(event.occurred_at)
      into v_active_count, v_active_baseline_id,
           v_active_event_id, v_active_occurred_at
    from s2t_fhir.baseline_version b
    join s2t_fhir.baseline_lifecycle_event event
      on event.baseline_version_id = b.baseline_version_id
    join s2t_fhir.reference_value status
      on status.reference_value_id = event.lifecycle_status_value_id
    join s2t_fhir.reference_domain domain
      on domain.reference_domain_id = status.reference_domain_id
     and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    where b.baseline_series_id = v_series_id
      and status.value_code = 'ACTIVE'
      and not exists (
        select 1 from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = event.baseline_lifecycle_event_id
      );
  else
    v_active_count := 0;
  end if;

  if p_check_active_context and v_active_count > 1 then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := pg_catalog.format(
        'baseline series %s has multiple current ACTIVE baselines', v_series_id);
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'AMBIGUOUS_STATE')
    );
  elsif p_check_active_context and v_active_count = 0 and pg_catalog.num_nonnulls(
      p_expected_active_baseline_version_id,
      p_expected_active_lifecycle_event_id) <> 0 then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '40001';
      v_legacy_message := 'ACTIVE state is stale: expected an ACTIVE baseline but none exists';
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'ACTIVE_CONTEXT_STALE')
    );
  elsif p_check_active_context and v_active_count = 1 and (
      p_expected_active_baseline_version_id is distinct from v_active_baseline_id
      or p_expected_active_lifecycle_event_id is distinct from v_active_event_id) then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '40001';
      v_legacy_message := pg_catalog.format(
        'ACTIVE state is stale: expected baseline %s event %s, current baseline %s event %s',
        coalesce(p_expected_active_baseline_version_id::text, '<NULL>'),
        coalesce(p_expected_active_lifecycle_event_id::text, '<NULL>'),
        coalesce(v_active_baseline_id::text, '<NULL>'),
        coalesce(v_active_event_id::text, '<NULL>'));
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'ACTIVE_CONTEXT_STALE')
    );
  end if;

  if p_check_active_context and v_active_count = 1
     and p_effective_at < v_active_occurred_at then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := pg_catalog.format(
        'promotion effective time cannot precede current ACTIVE event %s',
        v_active_event_id);
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'EFFECTIVE_TIME_BEFORE_EVIDENCE')
    );
  end if;

  if p_check_active_context then
    select count(*) into v_resource_count
    from s2t_fhir.mapping_resource_registry registry
    where registry.source_system = v_source_system
      and registry.fhir_resource = v_fhir_resource
      and registry.is_enabled;

    select count(*) into v_other_active_context_count
    from s2t_fhir_api._active_release_context active_context
    where active_context.source_system = v_source_system
      and active_context.fhir_resource = v_fhir_resource
      and active_context.baseline_version_id
            is distinct from p_expected_active_baseline_version_id;
  end if;

  if p_check_active_context
     and (v_resource_count <> 1 or v_other_active_context_count <> 0) then
    if v_legacy_sqlstate is null then
      v_legacy_sqlstate := '23514';
      v_legacy_message := case when v_resource_count <> 1
        then pg_catalog.format(
          'promotion requires one enabled mapping resource context for %s/%s',
          v_source_system, v_fhir_resource)
        else pg_catalog.format(
          'promotion would create an ambiguous ACTIVE API context for %s/%s',
          v_source_system, v_fhir_resource)
      end;
    end if;
    v_blockers := v_blockers || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'RESOURCE_CONTEXT_INVALID')
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ready', pg_catalog.jsonb_array_length(v_blockers) = 0,
    'blockers', v_blockers,
    'expected', pg_catalog.jsonb_build_object(
      'candidateBaselineVersionId', p_baseline_version_id,
      'candidateLifecycleEventId', p_expected_candidate_lifecycle_event_id,
      'importRunId', v_context.import_run_id,
      'releaseGateEvaluationId', v_gate_id,
      'activeBaselineVersionId', v_active_baseline_id,
      'activeLifecycleEventId', v_active_event_id
    ),
    'currentCandidate', pg_catalog.jsonb_build_object(
      'baselineVersionId', v_context.baseline_version_id,
      'lifecycleEventId', v_context.candidate_lifecycle_event_id
    ),
    'currentActive', case when v_active_count = 1 then
      pg_catalog.jsonb_build_object(
        'baselineVersionId', v_active_baseline_id,
        'lifecycleEventId', v_active_event_id
      ) else 'null'::jsonb end,
    'legacyFailure', case when v_legacy_sqlstate is null then 'null'::jsonb
      else pg_catalog.jsonb_build_object(
        'sqlstate', v_legacy_sqlstate, 'message', v_legacy_message) end,
    'observedAt', pg_catalog.transaction_timestamp()
  );
end
$function$;

create function s2t_fhir._raise_candidate_promotion_evaluation(
  p_evaluation jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  if not coalesce((p_evaluation ->> 'ready')::boolean, false) then
    raise exception using
      errcode = coalesce(p_evaluation #>> '{legacyFailure,sqlstate}', '23514'),
      message = coalesce(
        p_evaluation #>> '{legacyFailure,message}',
        'Candidate Promotion eligibility evaluation failed'
      );
  end if;
end
$function$;

-- Existing private signature retained. Its historical eligibility/error
-- contract now delegates to the shared evaluator.
create or replace function s2t_fhir.assert_candidate_activation_eligibility(
  p_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_expected_import_run_id uuid,
  p_expected_release_gate_evaluation_id uuid,
  p_effective_at timestamptz
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  perform s2t_fhir._raise_candidate_promotion_evaluation(
    s2t_fhir._evaluate_candidate_promotion_readiness(
      p_baseline_version_id,
      p_expected_candidate_lifecycle_event_id,
      p_expected_import_run_id,
      p_expected_release_gate_evaluation_id,
      null,
      null,
      p_effective_at,
      true,
      false
    )
  );
end
$function$;

-- Preserve the Migration 023 lock acquisition and failure sequence verbatim.
-- Only the final eligibility call is redirected to the shared evaluator, and
-- it occurs after every existing Candidate/ACTIVE/evidence lock.
create or replace function s2t_fhir.validate_baseline_activation_context()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_context s2t_fhir.baseline_candidate_context%rowtype;
  v_series_id uuid;
  v_source_system text;
  v_fhir_resource text;
  v_active_count integer;
  v_active_baseline_id uuid;
  v_active_event_id uuid;
  v_active_occurred_at timestamptz;
  v_resource_count integer;
  v_other_active_context_count integer;
  v_validation_run_id uuid;
begin
  if new.baseline_version_id is null
     or new.candidate_lifecycle_event_id is null
     or new.active_lifecycle_event_id is null
     or new.artifact_id is null
     or new.import_run_id is null
     or new.release_gate_evaluation_id is null
     or new.effective_at is null then
    raise exception 'activation context requires complete Candidate, evidence, and result identities'
      using errcode = '23502';
  end if;

  if new.effective_at > pg_catalog.transaction_timestamp() then
    raise exception 'promotion effective time cannot be in the future'
      using errcode = '22023';
  end if;

  v_context := s2t_fhir._lock_current_candidate_context(
    new.baseline_version_id,
    new.candidate_lifecycle_event_id
  );

  if v_context.artifact_id is distinct from new.artifact_id
     or v_context.import_run_id is distinct from new.import_run_id then
    raise exception 'activation context does not match the exact Candidate publication context'
      using errcode = '40001';
  end if;

  select bv.baseline_series_id, bs.source_system, bs.fhir_resource
    into strict v_series_id, v_source_system, v_fhir_resource
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  where bv.baseline_version_id = new.baseline_version_id;

  perform 1 from s2t_fhir.baseline_version bv
  where bv.baseline_version_id = new.baseline_version_id for update;

  select count(*) into v_active_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_lifecycle_event event
    on event.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where bv.baseline_series_id = v_series_id
    and status.value_code = 'ACTIVE'
    and not exists (
      select 1 from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = event.baseline_lifecycle_event_id
    );

  if v_active_count > 1 then
    raise exception 'baseline series % has multiple current ACTIVE baselines', v_series_id
      using errcode = '23514';
  elsif v_active_count = 1 then
    select bv.baseline_version_id, event.baseline_lifecycle_event_id,
           event.occurred_at
      into strict v_active_baseline_id, v_active_event_id, v_active_occurred_at
    from s2t_fhir.baseline_version bv
    join s2t_fhir.baseline_lifecycle_event event
      on event.baseline_version_id = bv.baseline_version_id
    join s2t_fhir.reference_value status
      on status.reference_value_id = event.lifecycle_status_value_id
    join s2t_fhir.reference_domain domain
      on domain.reference_domain_id = status.reference_domain_id
     and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    where bv.baseline_series_id = v_series_id
      and status.value_code = 'ACTIVE'
      and not exists (
        select 1 from s2t_fhir.baseline_lifecycle_event successor
        where successor.supersedes_event_id = event.baseline_lifecycle_event_id
      );

    perform 1 from s2t_fhir.baseline_version bv
    where bv.baseline_version_id = v_active_baseline_id for update;

    perform 1 from s2t_fhir.baseline_lifecycle_event event
    where event.baseline_lifecycle_event_id = v_active_event_id for update;
  end if;

  if v_active_count = 0 then
    if pg_catalog.num_nonnulls(
      new.prior_active_baseline_version_id,
      new.prior_active_lifecycle_event_id,
      new.prior_active_superseded_event_id
    ) <> 0 then
      raise exception 'ACTIVE state is stale: expected an ACTIVE baseline but none exists'
        using errcode = '40001';
    end if;
  elsif new.prior_active_baseline_version_id is distinct from v_active_baseline_id
        or new.prior_active_lifecycle_event_id is distinct from v_active_event_id
        or new.prior_active_superseded_event_id is null then
    raise exception 'ACTIVE state is stale: expected baseline % event %, current baseline % event %',
      new.prior_active_baseline_version_id,
      new.prior_active_lifecycle_event_id,
      v_active_baseline_id,
      v_active_event_id
      using errcode = '40001';
  end if;

  if v_active_count = 1 and new.effective_at < v_active_occurred_at then
    raise exception 'promotion effective time cannot precede current ACTIVE event %', v_active_event_id
      using errcode = '23514';
  end if;

  select count(*) into v_resource_count
  from s2t_fhir.mapping_resource_registry registry
  where registry.source_system = v_source_system
    and registry.fhir_resource = v_fhir_resource
    and registry.is_enabled;

  if v_resource_count <> 1 then
    raise exception 'promotion requires one enabled mapping resource context for %/%',
      v_source_system, v_fhir_resource
      using errcode = '23514';
  end if;

  perform 1 from s2t_fhir.mapping_resource_registry registry
  where registry.source_system = v_source_system
    and registry.fhir_resource = v_fhir_resource
    and registry.is_enabled for update;

  select count(*) into v_other_active_context_count
  from s2t_fhir_api._active_release_context active_context
  where active_context.source_system = v_source_system
    and active_context.fhir_resource = v_fhir_resource
    and active_context.baseline_version_id
          is distinct from new.prior_active_baseline_version_id;

  if v_other_active_context_count <> 0 then
    raise exception 'promotion would create an ambiguous ACTIVE API context for %/%',
      v_source_system, v_fhir_resource
      using errcode = '23514';
  end if;

  perform 1 from s2t_fhir.baseline_candidate_context context
  where context.baseline_version_id = new.baseline_version_id
    and context.candidate_lifecycle_event_id = new.candidate_lifecycle_event_id
    and context.artifact_id = new.artifact_id
    and context.import_run_id = new.import_run_id for update;

  if not found then
    raise exception 'exact Candidate publication context is missing during promotion'
      using errcode = '40001';
  end if;

  perform 1 from s2t_fhir.baseline_artifact ba
  where ba.baseline_version_id = new.baseline_version_id
    and ba.artifact_id = new.artifact_id for update;

  perform 1 from s2t_fhir.artifact artifact
  where artifact.artifact_id = new.artifact_id for update;

  perform 1 from s2t_fhir.import_run import_run
  where import_run.import_run_id = new.import_run_id for update;

  select gate.validation_run_id into v_validation_run_id
  from s2t_fhir.release_gate_evaluation gate
  where gate.release_gate_evaluation_id = new.release_gate_evaluation_id;

  if not found then
    raise exception 'release-gate evaluation % does not exist', new.release_gate_evaluation_id
      using errcode = '23503';
  end if;

  perform 1 from s2t_fhir.validation_run validation
  where validation.validation_run_id = v_validation_run_id for update;

  perform 1 from s2t_fhir.release_gate_evaluation gate
  where gate.release_gate_evaluation_id = new.release_gate_evaluation_id for update;

  perform s2t_fhir._raise_candidate_promotion_evaluation(
    s2t_fhir._evaluate_candidate_promotion_readiness(
      new.baseline_version_id,
      new.candidate_lifecycle_event_id,
      new.import_run_id,
      new.release_gate_evaluation_id,
      new.prior_active_baseline_version_id,
      new.prior_active_lifecycle_event_id,
      new.effective_at,
      true,
      true
    )
  );

  if exists (
    select 1 from s2t_fhir.baseline_lifecycle_event event
    where event.baseline_lifecycle_event_id in (
      new.active_lifecycle_event_id,
      new.prior_active_superseded_event_id
    )
  ) then
    raise exception 'promotion result lifecycle event identity already exists'
      using errcode = '23505';
  end if;

  return new;
end
$function$;

create function s2t_fhir_api.get_my_candidate_ui_capabilities()
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
begin
  v_principal_id := s2t_fhir_api._resolve_authenticated_principal();
  select c.can_review_candidate, c.can_promote_candidate
    into strict v_can_review, v_can_promote
  from s2t_fhir_api._candidate_ui_capability_state(v_principal_id) c;
  return pg_catalog.jsonb_build_object(
    'canReviewCandidate', v_can_review,
    'canPromoteCandidate', v_can_promote
  );
end
$function$;

create function s2t_fhir_api.get_candidate_ui_context(
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
begin
  v_principal_id := s2t_fhir_api._resolve_authenticated_principal();
  select c.can_review_candidate, c.can_promote_candidate
    into strict v_can_review, v_can_promote
  from s2t_fhir_api._candidate_ui_capability_state(v_principal_id) c;
  if not v_can_review and not v_can_promote then
    raise exception 'authenticated principal lacks Candidate UI access'
      using errcode = '42501';
  end if;
  return s2t_fhir_api._candidate_ui_snapshot(p_resource_config_id);
end
$function$;

create function s2t_fhir_api.get_candidate_promotion_readiness(
  p_resource_config_id text,
  p_expected_candidate_baseline_version_id uuid,
  p_expected_candidate_lifecycle_event_id uuid,
  p_expected_active_baseline_version_id uuid,
  p_expected_active_lifecycle_event_id uuid,
  p_proposed_occurred_at timestamptz default pg_catalog.transaction_timestamp()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_principal_id uuid;
  v_can_review boolean;
  v_can_promote boolean;
  v_snapshot jsonb;
  v_candidate jsonb;
  v_active jsonb;
  v_evaluation jsonb;
  v_blockers jsonb;
begin
  v_principal_id := s2t_fhir_api._resolve_authenticated_principal();
  select c.can_review_candidate, c.can_promote_candidate
    into strict v_can_review, v_can_promote
  from s2t_fhir_api._candidate_ui_capability_state(v_principal_id) c;
  if not v_can_review and not v_can_promote then
    raise exception 'authenticated principal lacks Candidate UI access'
      using errcode = '42501';
  end if;

  if (p_expected_candidate_baseline_version_id is null)
     <> (p_expected_candidate_lifecycle_event_id is null)
     or (p_expected_active_baseline_version_id is null)
     <> (p_expected_active_lifecycle_event_id is null) then
    raise exception 'expected Candidate and ACTIVE identities must be supplied as complete pairs'
      using errcode = '22023';
  end if;

  v_snapshot := s2t_fhir_api._candidate_ui_snapshot(p_resource_config_id);
  v_candidate := v_snapshot -> 'candidate';
  v_active := v_snapshot -> 'active';

  if v_candidate = 'null'::jsonb then
    v_blockers := pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'NO_CURRENT_CANDIDATE')
    );
    if v_can_promote is false then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'PROMOTE_CAPABILITY_MISSING')
      );
    end if;
    return pg_catalog.jsonb_build_object(
      'ready', false,
      'canPromoteCandidate', v_can_promote,
      'blockers', v_blockers,
      'expected', pg_catalog.jsonb_build_object(
        'candidateBaselineVersionId', null,
        'candidateLifecycleEventId', null,
        'importRunId', null,
        'releaseGateEvaluationId', null,
        'activeBaselineVersionId', v_active ->> 'baselineVersionId',
        'activeLifecycleEventId', v_active ->> 'lifecycleEventId'
      ),
      'currentCandidate', 'null'::jsonb,
      'currentActive', v_active,
      'observedAt', pg_catalog.transaction_timestamp()
    );
  end if;

  if p_expected_candidate_baseline_version_id is distinct from
       (v_candidate ->> 'baselineVersionId')::uuid
     or p_expected_candidate_lifecycle_event_id is distinct from
       (v_candidate ->> 'lifecycleEventId')::uuid then
    v_blockers := pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'CANDIDATE_NOT_CURRENT')
    );
    if v_can_promote is false then
      v_blockers := v_blockers || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'PROMOTE_CAPABILITY_MISSING')
      );
    end if;
    return pg_catalog.jsonb_build_object(
      'ready', false,
      'canPromoteCandidate', v_can_promote,
      'blockers', v_blockers,
      'expected', pg_catalog.jsonb_build_object(
        'candidateBaselineVersionId', v_candidate ->> 'baselineVersionId',
        'candidateLifecycleEventId', v_candidate ->> 'lifecycleEventId',
        'importRunId', v_candidate ->> 'importRunId',
        'releaseGateEvaluationId', v_snapshot #>> '{releaseGate,releaseGateEvaluationId}',
        'activeBaselineVersionId', v_active ->> 'baselineVersionId',
        'activeLifecycleEventId', v_active ->> 'lifecycleEventId'
      ),
      'currentCandidate', pg_catalog.jsonb_build_object(
        'baselineVersionId', v_candidate ->> 'baselineVersionId',
        'lifecycleEventId', v_candidate ->> 'lifecycleEventId'),
      'currentActive', v_active,
      'observedAt', pg_catalog.transaction_timestamp()
    );
  end if;

  v_evaluation := s2t_fhir._evaluate_candidate_promotion_readiness(
    (v_candidate ->> 'baselineVersionId')::uuid,
    (v_candidate ->> 'lifecycleEventId')::uuid,
    (v_candidate ->> 'importRunId')::uuid,
    nullif(v_snapshot #>> '{releaseGate,releaseGateEvaluationId}', '')::uuid,
    p_expected_active_baseline_version_id,
    p_expected_active_lifecycle_event_id,
    p_proposed_occurred_at,
    false,
    true
  );

  -- Internal legacy exception details are never part of the public response.
  v_evaluation := v_evaluation - 'legacyFailure';
  if not v_can_promote then
    v_evaluation := pg_catalog.jsonb_set(
      v_evaluation,
      '{blockers}',
      (v_evaluation -> 'blockers') || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'PROMOTE_CAPABILITY_MISSING')
      )
    );
    v_evaluation := pg_catalog.jsonb_set(v_evaluation, '{ready}', 'false'::jsonb);
  end if;
  return v_evaluation || pg_catalog.jsonb_build_object(
    'canPromoteCandidate', v_can_promote
  );
end
$function$;

create function s2t_fhir_api.get_my_candidate_review_session(
  p_candidate_baseline_version_id uuid,
  p_candidate_lifecycle_event_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_principal_id uuid;
  v_target_count integer;
  v_open_count integer;
  v_session_id uuid;
  v_session_name text;
  v_started_at timestamptz;
  v_ended_at timestamptz;
  v_state text;
begin
  v_principal_id := s2t_fhir_api._require_authenticated_review_principal();

  select count(*) into v_target_count
  from s2t_fhir.baseline_lifecycle_event event
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where event.baseline_lifecycle_event_id = p_candidate_lifecycle_event_id
    and event.baseline_version_id = p_candidate_baseline_version_id
    and status.value_code = 'CANDIDATE';

  if v_target_count <> 1 then
    raise exception 'Candidate review target is missing or invalid'
      using errcode = '23514';
  end if;

  select count(*) into v_open_count
  from s2t_fhir.candidate_review_session_state state
  where state.baseline_version_id = p_candidate_baseline_version_id
    and state.review_target_lifecycle_event_id = p_candidate_lifecycle_event_id
    and state.created_by_principal_id = v_principal_id
    and state.session_state in ('OPEN_CURRENT', 'OPEN_FROZEN');

  if v_open_count > 1 then
    raise exception 'Candidate review session state is ambiguous for the current principal'
      using errcode = '23514';
  elsif v_open_count = 1 then
    select state.review_session_id, state.session_name, state.started_at,
           state.ended_at, state.session_state
      into strict v_session_id, v_session_name, v_started_at, v_ended_at, v_state
    from s2t_fhir.candidate_review_session_state state
    where state.baseline_version_id = p_candidate_baseline_version_id
      and state.review_target_lifecycle_event_id = p_candidate_lifecycle_event_id
      and state.created_by_principal_id = v_principal_id
      and state.session_state in ('OPEN_CURRENT', 'OPEN_FROZEN');
  else
    select state.review_session_id, state.session_name, state.started_at,
           state.ended_at, state.session_state
      into v_session_id, v_session_name, v_started_at, v_ended_at, v_state
    from s2t_fhir.candidate_review_session_state state
    where state.baseline_version_id = p_candidate_baseline_version_id
      and state.review_target_lifecycle_event_id = p_candidate_lifecycle_event_id
      and state.created_by_principal_id = v_principal_id
      and state.session_state = 'CLOSED'
    order by state.ended_at desc, state.started_at desc, state.review_session_id desc
    limit 1;
    if not found then v_state := 'NONE'; end if;
  end if;

  return pg_catalog.jsonb_build_object(
    'state', v_state,
    'reviewSessionId', v_session_id,
    'sessionName', v_session_name,
    'startedAt', v_started_at,
    'endedAt', v_ended_at
  );
end
$function$;

-- Preserve all 19 existing columns in place, including is_active, and append
-- the three Candidate provenance columns required by the UI.
create or replace view s2t_fhir_api.governance_mapping_links (
  link_id, question_id, resource_config_id, baseline_code, node_id,
  mapping_kind, fhir_resource_type, version_label, target_element,
  element_path, profile_label, decision_status_at_link, source_sheet,
  source_row, source_cell_range, artifact_sha256, linked_by_principal,
  recorded_at, is_active, baseline_version_id,
  review_target_lifecycle_event_id, lifecycle_status_at_link
) as
select
  l.link_id, l.question_id, l.resource_config_id, l.baseline_code, l.node_id,
  l.mapping_kind, l.fhir_resource_type, l.version_label, l.target_element,
  l.element_path, l.profile_label, l.decision_status_at_link, l.source_sheet,
  l.source_row, l.source_cell_range, l.artifact_sha256,
  l.linked_by_principal, l.recorded_at,
  (
    le.event_id is not null
    and not exists (
      select 1 from s2t_governance.governance_event r
      where r.retracts_event_id = le.event_id
    )
    and not exists (
      select 1 from s2t_governance.governance_event u
      where u.link_id = l.link_id
        and u.event_type = 'MAPPING_UNLINKED'
        and not exists (
          select 1 from s2t_governance.governance_event r
          where r.retracts_event_id = u.event_id
        )
    )
  ) as is_active,
  l.baseline_version_id,
  l.review_target_lifecycle_event_id,
  l.lifecycle_status_at_link
from s2t_governance.governance_mapping_link l
left join s2t_governance.governance_event le
  on le.link_id = l.link_id
 and le.event_type = 'MAPPING_LINKED'
where s2t_fhir_api._governance_read_allowed();

alter function s2t_fhir_api._candidate_ui_capability_state(uuid)
  owner to s2t_fhir_owner;
alter function s2t_fhir_api._candidate_ui_snapshot(text)
  owner to s2t_fhir_owner;
alter function s2t_fhir._evaluate_candidate_promotion_readiness(
  uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, boolean, boolean
) owner to s2t_fhir_owner;
alter function s2t_fhir._raise_candidate_promotion_evaluation(jsonb)
  owner to s2t_fhir_owner;
alter function s2t_fhir.assert_candidate_activation_eligibility(
  uuid, uuid, uuid, uuid, timestamptz
) owner to s2t_fhir_owner;
alter function s2t_fhir.validate_baseline_activation_context()
  owner to s2t_fhir_owner;
alter function s2t_fhir_api.get_candidate_ui_context(text)
  owner to s2t_fhir_owner;
alter function s2t_fhir_api.get_candidate_promotion_readiness(
  text, uuid, uuid, uuid, uuid, timestamptz
) owner to s2t_fhir_owner;
alter function s2t_fhir_api.get_my_candidate_ui_capabilities()
  owner to s2t_fhir_owner;
alter function s2t_fhir_api.get_my_candidate_review_session(uuid, uuid)
  owner to s2t_fhir_owner;
alter view s2t_fhir_api.governance_mapping_links owner to s2t_fhir_owner;

revoke all on function s2t_fhir_api._candidate_ui_capability_state(uuid)
  from public, anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir_api._candidate_ui_snapshot(text)
  from public, anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir._evaluate_candidate_promotion_readiness(
  uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, boolean, boolean
) from public, anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir._raise_candidate_promotion_evaluation(jsonb)
  from public, anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.assert_candidate_activation_eligibility(
  uuid, uuid, uuid, uuid, timestamptz
) from public, anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;
revoke all on function s2t_fhir.validate_baseline_activation_context()
  from public, anon, authenticated, service_role, s2t_fhir_importer,
       s2t_fhir_api_reader, s2t_fhir_governance_reader;

revoke all on function s2t_fhir_api.get_candidate_ui_context(text)
  from public, anon;
revoke all on function s2t_fhir_api.get_candidate_promotion_readiness(
  text, uuid, uuid, uuid, uuid, timestamptz
) from public, anon;
revoke all on function s2t_fhir_api.get_my_candidate_ui_capabilities()
  from public, anon;
revoke all on function s2t_fhir_api.get_my_candidate_review_session(uuid, uuid)
  from public, anon;

grant execute on function s2t_fhir_api.get_candidate_ui_context(text)
  to authenticated;
grant execute on function s2t_fhir_api.get_candidate_promotion_readiness(
  text, uuid, uuid, uuid, uuid, timestamptz
) to authenticated;
grant execute on function s2t_fhir_api.get_my_candidate_ui_capabilities()
  to authenticated;
grant execute on function s2t_fhir_api.get_my_candidate_review_session(uuid, uuid)
  to authenticated;

revoke all on s2t_fhir_api.governance_mapping_links from public, anon;
grant select on s2t_fhir_api.governance_mapping_links to authenticated;

comment on function s2t_fhir._evaluate_candidate_promotion_readiness(
  uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, boolean, boolean
) is 'Private non-mutating shared authority for Candidate Promotion readiness. A ready observation is not a lock or guarantee.';
comment on function s2t_fhir_api.get_candidate_ui_context(text)
  is 'Authenticated cohesive current Candidate/ACTIVE/evidence snapshot for UI fresh load.';
comment on function s2t_fhir_api.get_candidate_promotion_readiness(
  text, uuid, uuid, uuid, uuid, timestamptz
) is 'Authenticated observational Candidate Promotion readiness; Promotion revalidates all expected identifiers under lock.';
comment on function s2t_fhir_api.get_my_candidate_ui_capabilities()
  is 'Current authenticated principal Candidate UI capability booleans only.';
comment on function s2t_fhir_api.get_my_candidate_review_session(uuid, uuid)
  is 'Current authenticated reviewer Candidate-session continuation state.';

reset role;

commit;

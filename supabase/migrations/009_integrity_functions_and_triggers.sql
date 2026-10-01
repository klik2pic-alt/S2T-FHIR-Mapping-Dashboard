set role s2t_fhir_owner;

create function s2t_fhir.reject_append_only_change()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  raise exception '%.% is append-only; % is prohibited', tg_table_schema, tg_table_name, tg_op
    using errcode = '55000';
end
$function$;

create function s2t_fhir.protect_principal_update()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.principal_id is distinct from old.principal_id
     or new.principal_kind_value_id is distinct from old.principal_kind_value_id
     or new.external_issuer is distinct from old.external_issuer
     or new.external_subject is distinct from old.external_subject
     or new.created_at is distinct from old.created_at then
    raise exception 'immutable principal identity fields cannot be changed' using errcode = '55000';
  end if;
  if old.disabled_at is not null and new.disabled_at is distinct from old.disabled_at then
    raise exception 'principal disabled_at is write-once' using errcode = '55000';
  end if;
  return new;
end
$function$;

create function s2t_fhir.protect_import_run_update()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if old.completed_at is not null then
    raise exception 'terminal import runs are immutable' using errcode = '55000';
  end if;
  if new.import_run_id is distinct from old.import_run_id
     or new.baseline_version_id is distinct from old.baseline_version_id
     or new.artifact_id is distinct from old.artifact_id
     or new.import_policy_value_id is distinct from old.import_policy_value_id
     or new.import_specification_version is distinct from old.import_specification_version
     or new.importer_version is distinct from old.importer_version
     or new.configuration_digest is distinct from old.configuration_digest
     or new.started_at is distinct from old.started_at
     or new.actor_principal_id is distinct from old.actor_principal_id
     or new.initiating_human_principal_id is distinct from old.initiating_human_principal_id
     or new.created_at is distinct from old.created_at then
    raise exception 'immutable import run fields cannot be changed' using errcode = '55000';
  end if;
  if new.completed_at is null or new.terminal_status_value_id is null then
    raise exception 'an import run update must finalize the run atomically' using errcode = '55000';
  end if;
  return new;
end
$function$;

create function s2t_fhir.enforce_reference_domains()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  i integer;
  value_id uuid;
  actual_domain text;
  expected_domain text;
  effective_at timestamptz;
  retired_at timestamptz;
  use_at timestamptz := coalesce(
    nullif(to_jsonb(new)->>'evaluated_at', '')::timestamptz,
    nullif(to_jsonb(new)->>'occurred_at', '')::timestamptz,
    nullif(to_jsonb(new)->>'opened_at', '')::timestamptz,
    nullif(to_jsonb(new)->>'observed_at', '')::timestamptz,
    nullif(to_jsonb(new)->>'captured_at', '')::timestamptz,
    nullif(to_jsonb(new)->>'started_at', '')::timestamptz,
    nullif(to_jsonb(new)->>'effective_at', '')::timestamptz,
    nullif(to_jsonb(new)->>'created_at', '')::timestamptz,
    transaction_timestamp()
  );
begin
  if mod(tg_nargs, 2) <> 0 then
    raise exception 'reference-domain trigger arguments must be column/domain pairs';
  end if;
  i := 0;
  while i < tg_nargs loop
    value_id := nullif(to_jsonb(new)->>tg_argv[i], '')::uuid;
    expected_domain := tg_argv[i + 1];
    if value_id is not null then
      select d.domain_code, v.effective_at, v.retired_at
        into actual_domain, effective_at, retired_at
      from s2t_fhir.reference_value v
      join s2t_fhir.reference_domain d on d.reference_domain_id = v.reference_domain_id
      where v.reference_value_id = value_id;
      if actual_domain is distinct from expected_domain then
        raise exception 'column % must reference domain %, got %', tg_argv[i], expected_domain, coalesce(actual_domain, '<missing>')
          using errcode = '23514';
      end if;
      if use_at < effective_at or (retired_at is not null and use_at >= retired_at) then
        raise exception 'reference value % is not effective at %', value_id, use_at using errcode = '23514';
      end if;
    end if;
    i := i + 2;
  end loop;
  return new;
end
$function$;

revoke all on function s2t_fhir.enforce_reference_domains() from public;

create function s2t_fhir.close_bootstrap_seed_window()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.is_bootstrap_seed then
    raise exception 'bootstrap seed values may only be inserted by the initial bootstrap migration' using errcode = '23514';
  end if;
  if new.created_by_principal_id is null then
    raise exception 'non-bootstrap reference values require a creator principal' using errcode = '23502';
  end if;
  return new;
end
$function$;

create function s2t_fhir.check_mapping_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  target_id uuid := coalesce(new.mapping_record_id, old.mapping_record_id);
  parent_row s2t_fhir.mapping_record%rowtype;
  kind_code text;
  candidate_kind uuid;
  identity_kind uuid;
  disposition_code text;
  import_baseline uuid;
  subtype_count integer;
begin
  select * into parent_row from s2t_fhir.mapping_record where mapping_record_id = target_id;
  if not found then return null; end if;

  select rv.value_code into kind_code from s2t_fhir.reference_value rv where rv.reference_value_id = parent_row.mapping_kind_value_id;
  select c.mapping_kind_value_id, dv.value_code, ir.baseline_version_id
    into candidate_kind, disposition_code, import_baseline
  from s2t_fhir.import_candidate_row c
  join s2t_fhir.import_run ir on ir.import_run_id = c.import_run_id
  join s2t_fhir.reference_value dv on dv.reference_value_id = c.candidate_disposition_value_id
  where c.import_candidate_row_id = parent_row.import_candidate_row_id;
  select mapping_kind_value_id into identity_kind
  from s2t_fhir.logical_mapping_identity where logical_mapping_identity_id = parent_row.logical_mapping_identity_id;

  subtype_count :=
    (case when exists (select 1 from s2t_fhir.element_mapping where mapping_record_id = target_id) then 1 else 0 end) +
    (case when exists (select 1 from s2t_fhir.status_mapping_rule where mapping_record_id = target_id) then 1 else 0 end) +
    (case when exists (select 1 from s2t_fhir.governance_guidance where mapping_record_id = target_id) then 1 else 0 end);

  if disposition_code <> 'ACCEPTED' or import_baseline <> parent_row.baseline_version_id
     or candidate_kind <> parent_row.mapping_kind_value_id or identity_kind <> parent_row.mapping_kind_value_id then
    raise exception 'mapping record % has inconsistent candidate, baseline, kind, or disposition', target_id using errcode = '23514';
  end if;
  if subtype_count <> 1
     or (kind_code = 'ELEMENT_MAPPING' and not exists (select 1 from s2t_fhir.element_mapping where mapping_record_id = target_id))
     or (kind_code = 'STATUS_MAPPING_RULE' and not exists (select 1 from s2t_fhir.status_mapping_rule where mapping_record_id = target_id))
     or (kind_code = 'GOVERNANCE_GUIDANCE' and not exists (select 1 from s2t_fhir.governance_guidance where mapping_record_id = target_id)) then
    raise exception 'mapping record % must have exactly one matching subtype', target_id using errcode = '23514';
  end if;
  return null;
end
$function$;

create function s2t_fhir.check_authoritative_artifact()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  baseline_id uuid;
  assigned_artifact uuid;
  authoritative_count integer;
  status_code text;
  artifact_for_import uuid;
  committed_count integer;
  passed_current_gate_count integer;
begin
  if tg_table_name = 'baseline_artifact' then
    baseline_id := coalesce(new.baseline_version_id, old.baseline_version_id);
  elsif tg_table_name = 'baseline_lifecycle_event' then
    baseline_id := coalesce(new.baseline_version_id, old.baseline_version_id);
    select value_code into status_code from s2t_fhir.reference_value
      where reference_value_id = coalesce(new.lifecycle_status_value_id, old.lifecycle_status_value_id);
  elsif tg_table_name = 'import_run' then
    baseline_id := coalesce(new.baseline_version_id, old.baseline_version_id);
    artifact_for_import := coalesce(new.artifact_id, old.artifact_id);
    select value_code into status_code from s2t_fhir.reference_value
      where reference_value_id = coalesce(new.terminal_status_value_id, old.terminal_status_value_id);
  end if;

  if tg_table_name = 'import_run' and status_code = 'COMMITTED' then
    if current_setting('s2t_fhir.finalizing_baseline', true) is null then
      perform set_config('s2t_fhir.finalizing_baseline', baseline_id::text, true);
    elsif current_setting('s2t_fhir.finalizing_baseline', true) <> baseline_id::text then
      raise exception 'MVP import finalization supports exactly one baseline per transaction' using errcode = '25000';
    end if;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(baseline_id::text, 0));
  select count(*), (array_agg(ba.artifact_id))[1]
    into authoritative_count, assigned_artifact
  from s2t_fhir.baseline_artifact ba
  join s2t_fhir.reference_value rv on rv.reference_value_id = ba.artifact_role_value_id
  join s2t_fhir.reference_domain rd on rd.reference_domain_id = rv.reference_domain_id
  where ba.baseline_version_id = baseline_id
    and rd.domain_code = 'ARTIFACT_ROLE' and rv.value_code = 'AUTHORITATIVE_SOURCE';

  if authoritative_count > 1 then
    raise exception 'baseline % has more than one authoritative artifact', baseline_id using errcode = '23505';
  end if;
  if (tg_table_name = 'baseline_lifecycle_event' and status_code = 'ACTIVE')
     or (tg_table_name = 'import_run' and status_code = 'COMMITTED') then
    if authoritative_count <> 1 then
      raise exception 'baseline % requires exactly one authoritative artifact', baseline_id using errcode = '23514';
    end if;
  end if;
  if tg_table_name = 'import_run' and status_code = 'COMMITTED' and assigned_artifact <> artifact_for_import then
    raise exception 'committed import artifact is not the baseline authoritative artifact' using errcode = '23514';
  end if;
  if tg_table_name = 'import_run' and status_code = 'COMMITTED' then
    select count(*) into committed_count
    from s2t_fhir.import_run ir
    join s2t_fhir.reference_value rv on rv.reference_value_id = ir.terminal_status_value_id
    where ir.import_run_id <> coalesce(new.import_run_id, old.import_run_id)
      and ir.baseline_version_id = baseline_id
      and ir.artifact_id = artifact_for_import
      and ir.import_specification_version = coalesce(new.import_specification_version, old.import_specification_version)
      and ir.importer_version = coalesce(new.importer_version, old.importer_version)
      and ir.configuration_digest = coalesce(new.configuration_digest, old.configuration_digest)
      and rv.value_code = 'COMMITTED';
    if committed_count > 0 then
      raise exception 'an equivalent committed import already exists' using errcode = '23505';
    end if;
  end if;
  if tg_table_name = 'baseline_lifecycle_event' and status_code = 'ACTIVE' then
    select count(*) into passed_current_gate_count
    from s2t_fhir.current_release_gate_evaluation current_gate
    join s2t_fhir.reference_value outcome
      on outcome.reference_value_id = current_gate.gate_outcome_value_id
    join s2t_fhir.reference_domain outcome_domain
      on outcome_domain.reference_domain_id = outcome.reference_domain_id
    where current_gate.baseline_version_id = baseline_id
      and outcome_domain.domain_code = 'RELEASE_GATE_OUTCOME'
      and outcome.value_code = 'PASSED';
    if passed_current_gate_count = 0 then
      raise exception 'baseline % cannot become ACTIVE without a current passed release gate evaluation', baseline_id using errcode = '23514';
    end if;
  end if;
  return null;
end
$function$;

create function s2t_fhir.check_candidate_disposition_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  candidate_id uuid := coalesce(new.import_candidate_row_id, old.import_candidate_row_id);
  disposition_code text;
  mapping_count integer;
  quarantine_count integer;
  candidate_key text;
  candidate_components jsonb;
  candidate_algorithm text;
  identity_key text;
  identity_components jsonb;
  identity_algorithm text;
begin
  select rv.value_code, c.calculated_logical_key, c.logical_key_components_json, c.logical_key_algorithm_version
    into disposition_code, candidate_key, candidate_components, candidate_algorithm
  from s2t_fhir.import_candidate_row c
  join s2t_fhir.reference_value rv on rv.reference_value_id = c.candidate_disposition_value_id
  where c.import_candidate_row_id = candidate_id;
  if not found then return null; end if;
  select count(*) into mapping_count from s2t_fhir.mapping_record where import_candidate_row_id = candidate_id;
  select count(*) into quarantine_count from s2t_fhir.quarantine_case where import_candidate_row_id = candidate_id;
  if disposition_code = 'ACCEPTED' and (mapping_count <> 1 or quarantine_count <> 0) then
    raise exception 'accepted candidate % requires exactly one mapping and no quarantine case', candidate_id using errcode = '23514';
  elsif disposition_code = 'QUARANTINED' and (mapping_count <> 0 or quarantine_count <> 1) then
    raise exception 'quarantined candidate % requires exactly one quarantine case and no mapping', candidate_id using errcode = '23514';
  elsif disposition_code not in ('ACCEPTED','QUARANTINED') then
    raise exception 'unsupported candidate disposition for %', candidate_id using errcode = '23514';
  end if;
  if disposition_code = 'ACCEPTED' then
    if candidate_key is null or candidate_components is null then
      raise exception 'accepted candidate % requires persisted logical key and components', candidate_id using errcode = '23514';
    end if;
    select li.logical_key, li.key_components_json, li.key_algorithm_version
      into identity_key, identity_components, identity_algorithm
    from s2t_fhir.mapping_record mr
    join s2t_fhir.logical_mapping_identity li on li.logical_mapping_identity_id = mr.logical_mapping_identity_id
    where mr.import_candidate_row_id = candidate_id;
    if candidate_key is distinct from identity_key
       or candidate_components is distinct from identity_components
       or candidate_algorithm is distinct from identity_algorithm then
      raise exception 'accepted candidate % logical key evidence does not match its logical identity', candidate_id using errcode = '23514';
    end if;
  end if;
  return null;
end
$function$;

create function s2t_fhir.check_actor_pair()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  actor_id uuid := nullif(to_jsonb(new)->>tg_argv[0], '')::uuid;
  human_id uuid := nullif(to_jsonb(new)->>tg_argv[1], '')::uuid;
  actor_kind text;
  human_kind text;
begin
  select rv.value_code into actor_kind
  from s2t_fhir.principal p join s2t_fhir.reference_value rv on rv.reference_value_id = p.principal_kind_value_id
  where p.principal_id = actor_id;
  if human_id is not null then
    select rv.value_code into human_kind
    from s2t_fhir.principal p join s2t_fhir.reference_value rv on rv.reference_value_id = p.principal_kind_value_id
    where p.principal_id = human_id;
    if human_kind <> 'HUMAN' then
      raise exception 'initiating human principal must have HUMAN kind' using errcode = '23514';
    end if;
    if actor_kind = 'HUMAN' and actor_id <> human_id then
      raise exception 'a human actor may only identify itself as initiating human' using errcode = '23514';
    end if;
  end if;
  return new;
end
$function$;

create function s2t_fhir.check_finding_row_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare finding_import uuid; candidate_import uuid;
begin
  select vr.import_run_id into finding_import
  from s2t_fhir.validation_finding vf join s2t_fhir.validation_run vr on vr.validation_run_id = vf.validation_run_id
  where vf.validation_finding_id = new.validation_finding_id;
  select import_run_id into candidate_import from s2t_fhir.import_candidate_row where import_candidate_row_id = new.import_candidate_row_id;
  if finding_import <> candidate_import then
    raise exception 'validation finding and candidate row must belong to the same import run' using errcode = '23514';
  end if;
  return null;
end
$function$;

create function s2t_fhir.check_quarantine_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  candidate_id uuid := coalesce(new.import_candidate_row_id, old.import_candidate_row_id);
  disposition_code text;
  finding_links integer;
begin
  select rv.value_code into disposition_code
  from s2t_fhir.import_candidate_row c join s2t_fhir.reference_value rv on rv.reference_value_id = c.candidate_disposition_value_id
  where c.import_candidate_row_id = candidate_id;
  if disposition_code <> 'QUARANTINED' then
    raise exception 'quarantine case candidate must have QUARANTINED disposition' using errcode = '23514';
  end if;
  if exists (select 1 from s2t_fhir.mapping_record where import_candidate_row_id = candidate_id) then
    raise exception 'quarantined candidate cannot have an accepted mapping record' using errcode = '23514';
  end if;
  select count(*) into finding_links from s2t_fhir.validation_finding_row
  where validation_finding_id = coalesce(new.opening_validation_finding_id, old.opening_validation_finding_id)
    and import_candidate_row_id = candidate_id;
  if finding_links = 0 then
    raise exception 'opening quarantine finding must reference the quarantined candidate' using errcode = '23514';
  end if;
  return null;
end
$function$;

create function s2t_fhir.assert_validation_run_integrity(target_validation_run_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  target_run s2t_fhir.validation_run%rowtype;
  import_artifact uuid;
  stored_digest bytea;
  actual_candidates bigint;
  actual_accepted bigint;
  actual_quarantined bigint;
  actual_warnings bigint;
  actual_errors bigint;
  actual_outcome text;
  expected_outcome text;
begin
  select * into target_run from s2t_fhir.validation_run where validation_run_id = target_validation_run_id;
  if not found then return; end if;
  select artifact_id into import_artifact from s2t_fhir.import_run where import_run_id = target_run.import_run_id;
  select sha256_digest into stored_digest from s2t_fhir.artifact where artifact_id = target_run.artifact_id;
  if import_artifact <> target_run.artifact_id or stored_digest <> target_run.artifact_digest then
    raise exception 'validation run artifact/digest does not match its import and artifact registry' using errcode = '23514';
  end if;
  select count(*),
         count(*) filter (where dv.value_code = 'ACCEPTED'),
         count(*) filter (where dv.value_code = 'QUARANTINED')
    into actual_candidates, actual_accepted, actual_quarantined
  from s2t_fhir.import_candidate_row c
  join s2t_fhir.reference_value dv on dv.reference_value_id = c.candidate_disposition_value_id
  where c.import_run_id = target_run.import_run_id;
  select count(*) filter (where sv.value_code in ('WARNING','ACCEPTED_EXCEPTION')),
         count(*) filter (where sv.value_code = 'ERROR')
    into actual_warnings, actual_errors
  from s2t_fhir.validation_finding vf
  join s2t_fhir.reference_value sv on sv.reference_value_id = vf.severity_value_id
  where vf.validation_run_id = target_run.validation_run_id;
  if target_run.candidate_count <> actual_candidates or target_run.accepted_count <> actual_accepted
     or target_run.quarantined_count <> actual_quarantined or target_run.warning_count <> actual_warnings
     or target_run.error_count <> actual_errors then
    raise exception 'validation run summary counts do not reconcile to candidates and findings' using errcode = '23514';
  end if;
  select value_code into actual_outcome
  from s2t_fhir.reference_value
  where reference_value_id = target_run.outcome_value_id;
  expected_outcome := case
    when actual_errors > 0 then 'FAIL'
    when actual_warnings > 0 then 'PASS_WITH_WARNINGS'
    else 'PASS'
  end;
  if actual_outcome is distinct from expected_outcome then
    raise exception 'validation run outcome % does not match finding counts; expected %', coalesce(actual_outcome, '<missing>'), expected_outcome using errcode = '23514';
  end if;
end
$function$;

create function s2t_fhir.check_validation_run_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  run_id uuid;
begin
  if tg_table_name = 'validation_run' then
    perform s2t_fhir.assert_validation_run_integrity(new.validation_run_id);
  elsif tg_table_name = 'validation_finding' then
    perform s2t_fhir.assert_validation_run_integrity(new.validation_run_id);
  elsif tg_table_name = 'import_candidate_row' then
    for run_id in select validation_run_id from s2t_fhir.validation_run where import_run_id = new.import_run_id loop
      perform s2t_fhir.assert_validation_run_integrity(run_id);
    end loop;
  end if;
  return null;
end
$function$;

create function s2t_fhir.assert_release_gate_evaluation_integrity(target_evaluation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  target_evaluation s2t_fhir.release_gate_evaluation%rowtype;
  gate_outcome text;
  requirement_count bigint;
  result_count bigint;
  failed_blocking_count bigint;
begin
  select * into target_evaluation
  from s2t_fhir.release_gate_evaluation
  where release_gate_evaluation_id = target_evaluation_id;
  if not found then return; end if;

  select value_code into gate_outcome
  from s2t_fhir.reference_value
  where reference_value_id = target_evaluation.gate_outcome_value_id;
  if gate_outcome = 'PASSED' then
    select count(*) into requirement_count
    from s2t_fhir.release_gate_requirement
    where release_gate_definition_id = target_evaluation.release_gate_definition_id;

    select count(*) into result_count
    from s2t_fhir.release_gate_result result
    join s2t_fhir.release_gate_requirement requirement
      on requirement.release_gate_requirement_id = result.release_gate_requirement_id
     and requirement.release_gate_definition_id = target_evaluation.release_gate_definition_id
    where result.release_gate_evaluation_id = target_evaluation_id;

    select count(*) into failed_blocking_count
    from s2t_fhir.release_gate_requirement requirement
    left join s2t_fhir.release_gate_result result
      on result.release_gate_requirement_id = requirement.release_gate_requirement_id
     and result.release_gate_evaluation_id = target_evaluation_id
    left join s2t_fhir.reference_value outcome
      on outcome.reference_value_id = result.requirement_outcome_value_id
    where requirement.release_gate_definition_id = target_evaluation.release_gate_definition_id
      and requirement.is_blocking
      and outcome.value_code is distinct from 'PASSED';

    if result_count <> requirement_count then
      raise exception 'passed release gate evaluation % requires exactly one result for every gate requirement', target_evaluation_id using errcode = '23514';
    end if;
    if failed_blocking_count > 0 then
      raise exception 'passed release gate evaluation % has a blocking requirement that did not pass', target_evaluation_id using errcode = '23514';
    end if;
  end if;
end
$function$;

create function s2t_fhir.check_release_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  run_ruleset uuid; run_artifact uuid; run_digest bytea; run_baseline uuid; authoritative_count integer;
begin
  select vr.validation_ruleset_id, vr.artifact_id, vr.artifact_digest, ir.baseline_version_id
    into run_ruleset, run_artifact, run_digest, run_baseline
  from s2t_fhir.validation_run vr join s2t_fhir.import_run ir on ir.import_run_id = vr.import_run_id
  where vr.validation_run_id = new.validation_run_id;
  if run_ruleset <> new.validation_ruleset_id or run_artifact <> new.artifact_id
     or run_digest <> new.artifact_digest or run_baseline <> new.baseline_version_id then
    raise exception 'release evaluation does not match validation evidence' using errcode = '23514';
  end if;
  select count(*) into authoritative_count
  from s2t_fhir.baseline_artifact ba
  join s2t_fhir.reference_value rv on rv.reference_value_id = ba.artifact_role_value_id
  where ba.baseline_version_id = new.baseline_version_id and ba.artifact_id = new.artifact_id
    and rv.value_code = 'AUTHORITATIVE_SOURCE';
  if authoritative_count <> 1 then
    raise exception 'release evaluation must reference the baseline authoritative artifact' using errcode = '23514';
  end if;
  perform s2t_fhir.assert_release_gate_evaluation_integrity(new.release_gate_evaluation_id);
  return null;
end
$function$;

create function s2t_fhir.check_release_result_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare evaluation_definition uuid; requirement_definition uuid;
begin
  select release_gate_definition_id into evaluation_definition from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id = new.release_gate_evaluation_id;
  select release_gate_definition_id into requirement_definition from s2t_fhir.release_gate_requirement where release_gate_requirement_id = new.release_gate_requirement_id;
  if evaluation_definition <> requirement_definition then
    raise exception 'release result requirement belongs to a different gate definition' using errcode = '23514';
  end if;
  perform s2t_fhir.assert_release_gate_evaluation_integrity(new.release_gate_evaluation_id);
  return null;
end
$function$;

create function s2t_fhir.check_release_requirement_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare evaluation_id uuid;
begin
  for evaluation_id in
    select evaluation.release_gate_evaluation_id
    from s2t_fhir.release_gate_evaluation evaluation
    where evaluation.release_gate_definition_id = new.release_gate_definition_id
  loop
    perform s2t_fhir.assert_release_gate_evaluation_integrity(evaluation_id);
  end loop;
  return null;
end
$function$;

create trigger principal_protect_update_trg before update on s2t_fhir.principal
for each row execute function s2t_fhir.protect_principal_update();
create trigger principal_reject_delete_trg before delete on s2t_fhir.principal
for each row execute function s2t_fhir.reject_append_only_change();
create trigger import_run_protect_update_trg before update on s2t_fhir.import_run
for each row execute function s2t_fhir.protect_import_run_update();
create trigger import_run_reject_delete_trg before delete on s2t_fhir.import_run
for each row execute function s2t_fhir.reject_append_only_change();
create trigger reference_value_bootstrap_closed_trg before insert on s2t_fhir.reference_value
for each row execute function s2t_fhir.close_bootstrap_seed_window();

do $block$
declare table_name text;
begin
  foreach table_name in array array[
    'reference_domain','reference_value','baseline_series','baseline_version','baseline_relationship','baseline_lifecycle_event',
    'artifact','artifact_location','baseline_artifact','artifact_sheet_manifest','import_run_metric','import_candidate_row',
    'logical_mapping_identity','mapping_record','element_mapping','status_mapping_rule','governance_guidance',
    'validation_ruleset','validation_rule','validation_run','validation_finding','validation_finding_row',
    'quarantine_case','quarantine_event','governance_item','governance_action','governance_evidence',
    'release_gate_definition','release_gate_requirement','release_gate_evaluation','release_gate_result','audit_event'
  ] loop
    execute format(
      'create trigger %I before update or delete on s2t_fhir.%I for each row execute function s2t_fhir.reject_append_only_change()',
      table_name || '_append_only_trg', table_name
    );
  end loop;
end
$block$;

-- Domain membership is a governed invariant not expressible by a UUID FK alone.
create trigger principal_reference_domains_trg before insert or update on s2t_fhir.principal for each row execute function s2t_fhir.enforce_reference_domains('principal_kind_value_id','PRINCIPAL_KIND');
create trigger baseline_series_reference_domains_trg before insert or update on s2t_fhir.baseline_series for each row execute function s2t_fhir.enforce_reference_domains('baseline_type_value_id','BASELINE_TYPE');
create trigger baseline_relationship_reference_domains_trg before insert or update on s2t_fhir.baseline_relationship for each row execute function s2t_fhir.enforce_reference_domains('relationship_type_value_id','BASELINE_RELATIONSHIP_TYPE');
create trigger baseline_lifecycle_reference_domains_trg before insert or update on s2t_fhir.baseline_lifecycle_event for each row execute function s2t_fhir.enforce_reference_domains('lifecycle_status_value_id','BASELINE_LIFECYCLE_STATUS');
create trigger artifact_reference_domains_trg before insert or update on s2t_fhir.artifact for each row execute function s2t_fhir.enforce_reference_domains('artifact_kind_value_id','ARTIFACT_KIND');
create trigger artifact_location_reference_domains_trg before insert or update on s2t_fhir.artifact_location for each row execute function s2t_fhir.enforce_reference_domains('location_kind_value_id','ARTIFACT_LOCATION_KIND','availability_status_value_id','ARTIFACT_AVAILABILITY');
create trigger baseline_artifact_reference_domains_trg before insert or update on s2t_fhir.baseline_artifact for each row execute function s2t_fhir.enforce_reference_domains('artifact_role_value_id','ARTIFACT_ROLE');
create trigger artifact_sheet_reference_domains_trg before insert or update on s2t_fhir.artifact_sheet_manifest for each row execute function s2t_fhir.enforce_reference_domains('sheet_classification_value_id','SHEET_CLASSIFICATION');
create trigger import_run_reference_domains_trg before insert or update on s2t_fhir.import_run for each row execute function s2t_fhir.enforce_reference_domains('import_policy_value_id','IMPORT_POLICY','terminal_status_value_id','IMPORT_RUN_STATUS');
create trigger import_metric_reference_domains_trg before insert or update on s2t_fhir.import_run_metric for each row execute function s2t_fhir.enforce_reference_domains('metric_type_value_id','METRIC_TYPE','mapping_kind_value_id','MAPPING_KIND','decision_status_value_id','DECISION_STATUS','severity_value_id','SEVERITY');
create trigger candidate_reference_domains_trg before insert or update on s2t_fhir.import_candidate_row for each row execute function s2t_fhir.enforce_reference_domains('mapping_kind_value_id','MAPPING_KIND','candidate_disposition_value_id','CANDIDATE_DISPOSITION');
create trigger identity_reference_domains_trg before insert or update on s2t_fhir.logical_mapping_identity for each row execute function s2t_fhir.enforce_reference_domains('mapping_kind_value_id','MAPPING_KIND');
create trigger mapping_reference_domains_trg before insert or update on s2t_fhir.mapping_record for each row execute function s2t_fhir.enforce_reference_domains('mapping_kind_value_id','MAPPING_KIND','decision_status_value_id','DECISION_STATUS');
create trigger guidance_reference_domains_trg before insert or update on s2t_fhir.governance_guidance for each row execute function s2t_fhir.enforce_reference_domains('guidance_scope_value_id','GUIDANCE_SCOPE','decision_topic_value_id','DECISION_TOPIC_CODE');
create trigger validation_rule_reference_domains_trg before insert or update on s2t_fhir.validation_rule for each row execute function s2t_fhir.enforce_reference_domains('default_severity_value_id','SEVERITY');
create trigger validation_run_reference_domains_trg before insert or update on s2t_fhir.validation_run for each row execute function s2t_fhir.enforce_reference_domains('outcome_value_id','VALIDATION_OUTCOME');
create trigger validation_finding_reference_domains_trg before insert or update on s2t_fhir.validation_finding for each row execute function s2t_fhir.enforce_reference_domains('severity_value_id','SEVERITY');
create trigger validation_finding_row_reference_domains_trg before insert or update on s2t_fhir.validation_finding_row for each row execute function s2t_fhir.enforce_reference_domains('finding_row_role_value_id','FINDING_ROW_ROLE');
create trigger quarantine_event_reference_domains_trg before insert or update on s2t_fhir.quarantine_event for each row execute function s2t_fhir.enforce_reference_domains('event_type_value_id','QUARANTINE_EVENT_TYPE','resolution_code_value_id','QUARANTINE_RESOLUTION');
create trigger governance_item_reference_domains_trg before insert or update on s2t_fhir.governance_item for each row execute function s2t_fhir.enforce_reference_domains('classification_value_id','GOVERNANCE_CLASSIFICATION');
create trigger governance_action_reference_domains_trg before insert or update on s2t_fhir.governance_action for each row execute function s2t_fhir.enforce_reference_domains('action_type_value_id','GOVERNANCE_ACTION_TYPE');
create trigger governance_evidence_reference_domains_trg before insert or update on s2t_fhir.governance_evidence for each row execute function s2t_fhir.enforce_reference_domains('evidence_role_value_id','EVIDENCE_ROLE');
create trigger release_evaluation_reference_domains_trg before insert or update on s2t_fhir.release_gate_evaluation for each row execute function s2t_fhir.enforce_reference_domains('gate_outcome_value_id','RELEASE_GATE_OUTCOME');
create trigger release_result_reference_domains_trg before insert or update on s2t_fhir.release_gate_result for each row execute function s2t_fhir.enforce_reference_domains('requirement_outcome_value_id','REQUIREMENT_OUTCOME');
create trigger audit_reference_domains_trg before insert or update on s2t_fhir.audit_event for each row execute function s2t_fhir.enforce_reference_domains('event_type_value_id','AUDIT_EVENT_TYPE','target_type_value_id','AUDIT_TARGET_TYPE','outcome_value_id','AUDIT_OUTCOME');

create trigger artifact_location_actor_pair_trg before insert or update on s2t_fhir.artifact_location for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');
create trigger baseline_lifecycle_actor_pair_trg before insert or update on s2t_fhir.baseline_lifecycle_event for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');
create trigger import_run_actor_pair_trg before insert or update on s2t_fhir.import_run for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');
create trigger validation_run_actor_pair_trg before insert or update on s2t_fhir.validation_run for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');
create trigger quarantine_case_actor_pair_trg before insert or update on s2t_fhir.quarantine_case for each row execute function s2t_fhir.check_actor_pair('opened_by_principal_id','initiating_human_principal_id');
create trigger quarantine_event_actor_pair_trg before insert or update on s2t_fhir.quarantine_event for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');
create trigger governance_action_actor_pair_trg before insert or update on s2t_fhir.governance_action for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');
create trigger release_evaluation_actor_pair_trg before insert or update on s2t_fhir.release_gate_evaluation for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');
create trigger audit_actor_pair_trg before insert or update on s2t_fhir.audit_event for each row execute function s2t_fhir.check_actor_pair('actor_principal_id','initiating_human_principal_id');

create constraint trigger mapping_record_integrity_trg after insert or update or delete on s2t_fhir.mapping_record deferrable initially deferred for each row execute function s2t_fhir.check_mapping_integrity();
create constraint trigger element_mapping_integrity_trg after insert or update or delete on s2t_fhir.element_mapping deferrable initially deferred for each row execute function s2t_fhir.check_mapping_integrity();
create constraint trigger status_mapping_integrity_trg after insert or update or delete on s2t_fhir.status_mapping_rule deferrable initially deferred for each row execute function s2t_fhir.check_mapping_integrity();
create constraint trigger guidance_mapping_integrity_trg after insert or update or delete on s2t_fhir.governance_guidance deferrable initially deferred for each row execute function s2t_fhir.check_mapping_integrity();

create constraint trigger baseline_artifact_authority_trg after insert or update or delete on s2t_fhir.baseline_artifact deferrable initially deferred for each row execute function s2t_fhir.check_authoritative_artifact();
create constraint trigger baseline_lifecycle_authority_trg after insert or update or delete on s2t_fhir.baseline_lifecycle_event deferrable initially deferred for each row execute function s2t_fhir.check_authoritative_artifact();
create constraint trigger import_run_authority_trg after insert or update or delete on s2t_fhir.import_run deferrable initially deferred for each row execute function s2t_fhir.check_authoritative_artifact();

create constraint trigger finding_row_integrity_trg after insert or update on s2t_fhir.validation_finding_row deferrable initially deferred for each row execute function s2t_fhir.check_finding_row_integrity();
create constraint trigger quarantine_integrity_trg after insert or update on s2t_fhir.quarantine_case deferrable initially deferred for each row execute function s2t_fhir.check_quarantine_integrity();
create constraint trigger candidate_disposition_integrity_trg after insert or update on s2t_fhir.import_candidate_row deferrable initially deferred for each row execute function s2t_fhir.check_candidate_disposition_integrity();
create constraint trigger validation_run_integrity_trg after insert or update on s2t_fhir.validation_run deferrable initially deferred for each row execute function s2t_fhir.check_validation_run_integrity();
create constraint trigger candidate_validation_totals_trg after insert or update on s2t_fhir.import_candidate_row deferrable initially deferred for each row execute function s2t_fhir.check_validation_run_integrity();
create constraint trigger finding_validation_totals_trg after insert or update on s2t_fhir.validation_finding deferrable initially deferred for each row execute function s2t_fhir.check_validation_run_integrity();
create constraint trigger release_evaluation_integrity_trg after insert or update on s2t_fhir.release_gate_evaluation deferrable initially deferred for each row execute function s2t_fhir.check_release_integrity();
create constraint trigger release_result_integrity_trg after insert or update on s2t_fhir.release_gate_result deferrable initially deferred for each row execute function s2t_fhir.check_release_result_integrity();
create constraint trigger release_requirement_integrity_trg after insert or update on s2t_fhir.release_gate_requirement deferrable initially deferred for each row execute function s2t_fhir.check_release_requirement_integrity();

create view s2t_fhir.current_baseline_lifecycle_event
with (security_barrier = true)
as
with eligible as (
  select e.*
  from s2t_fhir.baseline_lifecycle_event e
  where not exists (
    select 1 from s2t_fhir.baseline_lifecycle_event newer
    where newer.supersedes_event_id = e.baseline_lifecycle_event_id
  )
), ranked as (
  select e.*, row_number() over (
    partition by e.baseline_version_id
    order by e.occurred_at desc, e.recorded_at desc, e.baseline_lifecycle_event_id desc
  ) as projection_rank
  from eligible e
)
select baseline_lifecycle_event_id, baseline_version_id, lifecycle_status_value_id,
       occurred_at, recorded_at, actor_principal_id, initiating_human_principal_id,
       governance_action_id, reason, supersedes_event_id
from ranked where projection_rank = 1;

create view s2t_fhir.current_release_gate_evaluation
with (security_barrier = true)
as
with eligible as (
  select e.*
  from s2t_fhir.release_gate_evaluation e
  join s2t_fhir.artifact a on a.artifact_id = e.artifact_id and a.sha256_digest = e.artifact_digest
  join s2t_fhir.baseline_artifact ba on ba.baseline_version_id = e.baseline_version_id and ba.artifact_id = e.artifact_id
  join s2t_fhir.reference_value ar on ar.reference_value_id = ba.artifact_role_value_id and ar.value_code = 'AUTHORITATIVE_SOURCE'
  where not exists (
    select 1 from s2t_fhir.release_gate_evaluation newer
    where newer.supersedes_evaluation_id = e.release_gate_evaluation_id
  )
  and e.validation_run_id = (
  select vr.validation_run_id
  from s2t_fhir.validation_run vr
  join s2t_fhir.import_run ir
    on ir.import_run_id = vr.import_run_id
  where ir.baseline_version_id = e.baseline_version_id
    and vr.artifact_id = e.artifact_id
  order by vr.completed_at desc, vr.validation_run_id desc
  limit 1
  )
), ranked as (
  select e.*, row_number() over (
    partition by e.baseline_version_id, e.release_gate_definition_id
    order by e.evaluated_at desc, e.recorded_at desc, e.release_gate_evaluation_id desc
  ) as projection_rank
  from eligible e
)
select release_gate_evaluation_id, baseline_version_id, release_gate_definition_id,
       artifact_id, artifact_digest, validation_ruleset_id, validation_run_id,
       gate_outcome_value_id, evaluated_at, recorded_at, actor_principal_id,
       initiating_human_principal_id, supersedes_evaluation_id,
       governance_action_id, summary, created_at
from ranked where projection_rank = 1;

revoke all on function s2t_fhir.check_mapping_integrity() from public;
revoke all on function s2t_fhir.close_bootstrap_seed_window() from public;
revoke all on function s2t_fhir.check_authoritative_artifact() from public;
revoke all on function s2t_fhir.check_finding_row_integrity() from public;
revoke all on function s2t_fhir.check_quarantine_integrity() from public;
revoke all on function s2t_fhir.check_candidate_disposition_integrity() from public;
revoke all on function s2t_fhir.check_actor_pair() from public;
revoke all on function s2t_fhir.assert_validation_run_integrity(uuid) from public;
revoke all on function s2t_fhir.check_validation_run_integrity() from public;
revoke all on function s2t_fhir.assert_release_gate_evaluation_integrity(uuid) from public;
revoke all on function s2t_fhir.check_release_integrity() from public;
revoke all on function s2t_fhir.check_release_result_integrity() from public;
revoke all on function s2t_fhir.check_release_requirement_integrity() from public;

reset role;

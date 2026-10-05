-- Migration 022 rollback-only runtime tests for S2T-FHIR-DDL-Test.
-- Every mutation is enclosed by this explicit transaction and is rolled back.
-- Synthetic TEST_022_* identities are used; governed existing baselines are not mutated.

begin;
set local role s2t_fhir_owner;
set constraints all deferred;

create temp table pg_temp.test_022_context (
  run_tag text primary key
) on commit drop;

insert into pg_temp.test_022_context(run_tag)
values (replace(gen_random_uuid()::text, '-', ''));

create temp table pg_temp.test_022_results (
  test_no integer primary key,
  test_name text not null,
  status text not null check (status in ('PASS', 'FAIL', 'NOT RUN / FIXTURE REQUIRED')),
  detail text not null
) on commit drop;

create function pg_temp.test_022_ref(p_domain text, p_code text)
returns uuid
language sql
stable
set search_path = ''
as $function$
  select v.reference_value_id
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where d.domain_code = p_domain
    and v.value_code = p_code
    and v.effective_at <= transaction_timestamp()
    and (v.retired_at is null or v.retired_at > transaction_timestamp())
  order by v.version_number desc
  limit 1
$function$;

create function pg_temp.test_022_actor()
returns uuid
language sql
stable
set search_path = ''
as $function$
  select p.principal_id
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null
$function$;

create function pg_temp.test_022_new_series(p_label text)
returns uuid
language plpgsql
volatile
set search_path = ''
as $function$
declare
  v_run_tag text;
  v_series_id uuid;
begin
  select c.run_tag into strict v_run_tag from pg_temp.test_022_context c;

  insert into s2t_fhir.baseline_series
    (source_system, fhir_resource, baseline_type_value_id, description)
  values
    ('TEST_022_' || v_run_tag || '_' || p_label,
     'MedicationRequest',
     pg_temp.test_022_ref('BASELINE_TYPE', 'HUMAN_WORKING_DRAFT'),
     'Rollback-only migration 022 runtime fixture')
  returning baseline_series_id into v_series_id;

  return v_series_id;
end
$function$;

create function pg_temp.test_022_new_baseline(p_series_id uuid, p_label text)
returns uuid
language plpgsql
volatile
set search_path = ''
as $function$
declare
  v_run_tag text;
  v_baseline_id uuid;
begin
  select c.run_tag into strict v_run_tag from pg_temp.test_022_context c;

  insert into s2t_fhir.baseline_version
    (baseline_series_id, baseline_code, version_label, is_gold_standard,
     import_specification_version, description, created_by_principal_id)
  values
    (p_series_id,
     'T022-' || v_run_tag || '-' || p_label,
     'T022-' || p_label,
     false,
     'test-022-v1',
     'Rollback-only migration 022 runtime fixture',
     pg_temp.test_022_actor())
  returning baseline_version_id into v_baseline_id;

  return v_baseline_id;
end
$function$;

create function pg_temp.test_022_candidate(p_baseline_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $function$
declare
  v_event_id uuid;
begin
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, reason)
  values
    (p_baseline_id,
     pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'CANDIDATE'),
     transaction_timestamp(),
     pg_temp.test_022_actor(),
     'Rollback-only migration 022 candidate fixture')
  returning baseline_lifecycle_event_id into v_event_id;

  return v_event_id;
end
$function$;

-- Creates a synthetic CANDIDATE with the already-deployed authoritative-artifact
-- and current-PASSED-gate prerequisites. The import intentionally remains open:
-- migration 022 must not introduce a COMMITTED import requirement.
create function pg_temp.test_022_active_ready_candidate(
  p_series_id uuid,
  p_label text
)
returns table(baseline_id uuid, candidate_event_id uuid)
language plpgsql
volatile
set search_path = ''
as $function$
declare
  v_run_tag text;
  v_baseline_id uuid;
  v_artifact_id uuid;
  v_artifact_digest bytea;
  v_import_id uuid;
  v_validation_id uuid;
  v_ruleset_id uuid;
  v_gate_id uuid;
  v_evaluation_id uuid;
  v_candidate_event_id uuid;
begin
  select c.run_tag into strict v_run_tag from pg_temp.test_022_context c;
  v_baseline_id := pg_temp.test_022_new_baseline(p_series_id, p_label);
  v_artifact_digest := pg_catalog.decode(
    pg_catalog.md5(v_run_tag || p_label || ':artifact:1') ||
    pg_catalog.md5(v_run_tag || p_label || ':artifact:2'),
    'hex'
  );

  insert into s2t_fhir.artifact
    (artifact_kind_value_id, sha256_digest, byte_size, media_type,
     physical_filename, captured_at, description, created_by_principal_id)
  values
    (pg_temp.test_022_ref('ARTIFACT_KIND', 'WORKBOOK'),
     v_artifact_digest, 1, 'application/test',
     'test-022-' || p_label || '.xlsx', transaction_timestamp(),
     'Rollback-only migration 022 ACTIVE prerequisite fixture',
     pg_temp.test_022_actor())
  returning artifact_id into v_artifact_id;

  insert into s2t_fhir.baseline_artifact
    (baseline_version_id, artifact_id, artifact_role_value_id,
     note, created_by_principal_id)
  values
    (v_baseline_id, v_artifact_id,
     pg_temp.test_022_ref('ARTIFACT_ROLE', 'AUTHORITATIVE_SOURCE'),
     'Rollback-only migration 022 fixture', pg_temp.test_022_actor());

  insert into s2t_fhir.import_run
    (baseline_version_id, artifact_id, import_policy_value_id,
     import_specification_version, importer_version, configuration_digest,
     started_at, actor_principal_id)
  values
    (v_baseline_id, v_artifact_id,
     pg_temp.test_022_ref('IMPORT_POLICY', 'CLEAN_IMPORT'),
     'test-022-v1', 'test-022-importer',
     pg_catalog.decode(
       pg_catalog.md5(v_run_tag || p_label || ':config:1') ||
       pg_catalog.md5(v_run_tag || p_label || ':config:2'),
       'hex'
     ),
     transaction_timestamp(), pg_temp.test_022_actor())
  returning import_run_id into v_import_id;

  select r.validation_ruleset_id
    into strict v_ruleset_id
  from s2t_fhir.validation_ruleset r
  where r.ruleset_code = 'BASELINE_IMPORT'
    and r.version_label = 'v1';

  insert into s2t_fhir.validation_run
    (import_run_id, validation_ruleset_id, artifact_id, artifact_digest,
     execution_fingerprint, started_at, completed_at,
     candidate_count, accepted_count, warning_count, error_count,
     quarantined_count, outcome_value_id, actor_principal_id)
  values
    (v_import_id, v_ruleset_id, v_artifact_id, v_artifact_digest,
     pg_catalog.decode(
       pg_catalog.md5(v_run_tag || p_label || ':validation:1') ||
       pg_catalog.md5(v_run_tag || p_label || ':validation:2'),
       'hex'
     ),
     transaction_timestamp(), transaction_timestamp(),
     0, 0, 0, 0, 0,
     pg_temp.test_022_ref('VALIDATION_OUTCOME', 'PASS'),
     pg_temp.test_022_actor())
  returning validation_run_id into v_validation_id;

  select g.release_gate_definition_id
    into strict v_gate_id
  from s2t_fhir.release_gate_definition g
  where g.gate_code = 'BASELINE_IMPORT'
    and g.version_label = 'v1';

  insert into s2t_fhir.release_gate_evaluation
    (baseline_version_id, release_gate_definition_id, artifact_id,
     artifact_digest, validation_ruleset_id, validation_run_id,
     gate_outcome_value_id, evaluated_at, actor_principal_id, summary)
  select v_baseline_id, v_gate_id, v_artifact_id,
         v_artifact_digest, vr.validation_ruleset_id, v_validation_id,
         pg_temp.test_022_ref('RELEASE_GATE_OUTCOME', 'PASSED'),
         transaction_timestamp(), pg_temp.test_022_actor(),
         'Rollback-only migration 022 ACTIVE prerequisite fixture'
  from s2t_fhir.validation_run vr
  where vr.validation_run_id = v_validation_id
  returning release_gate_evaluation_id into v_evaluation_id;

  insert into s2t_fhir.release_gate_result
    (release_gate_evaluation_id, release_gate_requirement_id,
     requirement_outcome_value_id, explanation)
  select v_evaluation_id, requirement.release_gate_requirement_id,
         pg_temp.test_022_ref('REQUIREMENT_OUTCOME', 'PASSED'),
         'Rollback-only migration 022 fixture'
  from s2t_fhir.release_gate_requirement requirement
  where requirement.release_gate_definition_id = v_gate_id;

  v_candidate_event_id := pg_temp.test_022_candidate(v_baseline_id);

  baseline_id := v_baseline_id;
  candidate_event_id := v_candidate_event_id;
  return next;
end
$function$;

-- Baseline/API fingerprints before any synthetic mutations.
select 'RUNTIME BEFORE active_baseline' as fingerprint_name,
       md5(coalesce(string_agg(x::text, '|' order by x::text), '')) as fingerprint
from s2t_fhir_api.active_baseline x
union all
select 'RUNTIME BEFORE active_mapping_record',
       md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
from s2t_fhir_api.active_mapping_record x
union all
select 'RUNTIME BEFORE active RPC JSON',
       md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text, '<null>'));

-- T01 first CANDIDATE succeeds.
do $test$
declare v_series uuid; v_baseline uuid;
begin
  begin
    v_series := pg_temp.test_022_new_series('T01');
    v_baseline := pg_temp.test_022_new_baseline(v_series, 'T01');
    perform pg_temp.test_022_candidate(v_baseline);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (1, 'first CANDIDATE succeeds', 'PASS', 'initial CANDIDATE committed to deferred-check point');
  exception when others then
    insert into pg_temp.test_022_results values
      (1, 'first CANDIDATE succeeds', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T02/T03 first direct ACTIVE and first SUPERSEDED fail.
do $test$
declare v_series uuid; v_baseline uuid;
begin
  v_series := pg_temp.test_022_new_series('T02');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T02');
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor());
    insert into pg_temp.test_022_results values
      (2, 'first direct ACTIVE fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (2, 'first direct ACTIVE fails',
       case when sqlerrm like 'initial lifecycle status%must be CANDIDATE' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;

  v_series := pg_temp.test_022_new_series('T03');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T03');
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id, reason)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), 'test');
    insert into pg_temp.test_022_results values
      (3, 'first SUPERSEDED fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (3, 'first SUPERSEDED fails',
       case when sqlerrm like 'initial lifecycle status%must be CANDIDATE' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T04/T05 CANDIDATE -> SUPERSEDED reason behavior.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid;
begin
  begin
    v_series := pg_temp.test_022_new_series('T04');
    v_baseline := pg_temp.test_022_new_baseline(v_series, 'T04');
    v_candidate := pg_temp.test_022_candidate(v_baseline);
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(),
            'Candidate abandoned by rollback-only test', v_candidate);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (4, 'CANDIDATE -> SUPERSEDED succeeds with reason', 'PASS', 'transition accepted');
  exception when others then
    insert into pg_temp.test_022_results values
      (4, 'CANDIDATE -> SUPERSEDED succeeds with reason', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;

  v_series := pg_temp.test_022_new_series('T05');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T05');
  v_candidate := pg_temp.test_022_candidate(v_baseline);
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), '   ', v_candidate);
    insert into pg_temp.test_022_results values
      (5, 'blank SUPERSEDED reason fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (5, 'blank SUPERSEDED reason fails',
       case when sqlerrm = 'SUPERSEDED lifecycle event requires a nonblank reason' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T06 ACTIVE succeeds with the existing artifact/current-PASSED-gate semantics.
-- The fixture import is intentionally not COMMITTED.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid;
begin
  begin
    v_series := pg_temp.test_022_new_series('T06');
    select f.baseline_id, f.candidate_event_id
      into strict v_baseline, v_candidate
    from pg_temp.test_022_active_ready_candidate(v_series, 'T06') f;
    set constraints all immediate;
    set constraints all deferred;

    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(),
            'Rollback-only activation test', v_candidate);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (6, 'CANDIDATE -> ACTIVE with existing prerequisites', 'PASS',
       'ACTIVE accepted with authoritative artifact/current PASSED gate and open import');
  exception when others then
    insert into pg_temp.test_022_results values
      (6, 'CANDIDATE -> ACTIVE with existing prerequisites', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T07 invalid same-status transition fails.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid;
begin
  v_series := pg_temp.test_022_new_series('T07');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T07');
  v_candidate := pg_temp.test_022_candidate(v_baseline);
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'CANDIDATE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_candidate);
    insert into pg_temp.test_022_results values
      (7, 'invalid same-status transition fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (7, 'invalid same-status transition fails',
       case when sqlerrm like 'baseline lifecycle transition from CANDIDATE to CANDIDATE%' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T08 stale predecessor fails.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid;
begin
  v_series := pg_temp.test_022_new_series('T08');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T08');
  v_candidate := pg_temp.test_022_candidate(v_baseline);
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, reason, supersedes_event_id)
  values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
          transaction_timestamp(), pg_temp.test_022_actor(), 'terminal test', v_candidate);
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_candidate);
    insert into pg_temp.test_022_results values
      (8, 'stale predecessor fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (8, 'stale predecessor fails',
       case when sqlerrm like 'lifecycle event for baseline%must supersede current event%' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T09 cross-baseline predecessor fails.
do $test$
declare v_series uuid; v_a uuid; v_b uuid; v_a_event uuid; v_b_event uuid;
begin
  v_series := pg_temp.test_022_new_series('T09');
  v_a := pg_temp.test_022_new_baseline(v_series, 'T09A');
  v_b := pg_temp.test_022_new_baseline(v_series, 'T09B');
  v_a_event := pg_temp.test_022_candidate(v_a);
  -- The second CANDIDATE is transient; the cross-baseline BEFORE check runs first.
  v_b_event := pg_temp.test_022_candidate(v_b);
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_a, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), 'cross test', v_b_event);
    insert into pg_temp.test_022_results values
      (9, 'cross-baseline predecessor fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (9, 'cross-baseline predecessor fails',
       case when sqlerrm like 'lifecycle predecessor%belongs to baseline%' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
  -- Restore a valid final state for this fixture.
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, reason, supersedes_event_id)
  values (v_b, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
          transaction_timestamp(), pg_temp.test_022_actor(), 'fixture cleanup state', v_b_event);
end
$test$;

-- T10 backdated successor fails.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid;
begin
  v_series := pg_temp.test_022_new_series('T10');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T10');
  v_candidate := pg_temp.test_022_candidate(v_baseline);
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp() - interval '1 second', pg_temp.test_022_actor(),
            'backdated test', v_candidate);
    insert into pg_temp.test_022_results values
      (10, 'backdated successor fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (10, 'backdated successor fails',
       case when sqlerrm like 'lifecycle occurred_at cannot precede predecessor event%' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T11 duplicate root and T12 forked successor fail.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid;
begin
  v_series := pg_temp.test_022_new_series('T11');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T11');
  v_candidate := pg_temp.test_022_candidate(v_baseline);
  begin
    perform pg_temp.test_022_candidate(v_baseline);
    insert into pg_temp.test_022_results values
      (11, 'duplicate root fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (11, 'duplicate root fails',
       case when sqlerrm like 'lifecycle event for baseline%must supersede current event%'
                  or sqlstate = '23505' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;

  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, reason, supersedes_event_id)
  values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
          transaction_timestamp(), pg_temp.test_022_actor(), 'first successor', v_candidate);
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), 'fork successor', v_candidate);
    insert into pg_temp.test_022_results values
      (12, 'forked successor fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (12, 'forked successor fails',
       case when sqlerrm like 'lifecycle event for baseline%must supersede current event%'
                  or sqlstate = '23505' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T13 second current CANDIDATE in the same series fails at deferred evaluation.
do $test$
declare v_series uuid; v_a uuid; v_b uuid;
begin
  v_series := pg_temp.test_022_new_series('T13');
  v_a := pg_temp.test_022_new_baseline(v_series, 'T13A');
  perform pg_temp.test_022_candidate(v_a);
  set constraints all immediate;
  set constraints all deferred;
  v_b := pg_temp.test_022_new_baseline(v_series, 'T13B');
  begin
    perform pg_temp.test_022_candidate(v_b);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (13, 'second current CANDIDATE in same series fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (13, 'second current CANDIDATE in same series fails',
       case when sqlerrm like 'baseline series%current candidate-like baselines%' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T14 second current ACTIVE in the same series fails with both baselines gate-valid.
do $test$
declare
  v_series uuid; v_old uuid; v_old_candidate uuid; v_new uuid; v_new_candidate uuid;
begin
  v_series := pg_temp.test_022_new_series('T14');
  select f.baseline_id, f.candidate_event_id into strict v_old, v_old_candidate
  from pg_temp.test_022_active_ready_candidate(v_series, 'T14OLD') f;
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, supersedes_event_id)
  values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
          transaction_timestamp(), pg_temp.test_022_actor(), v_old_candidate);
  set constraints all immediate;
  set constraints all deferred;

  select f.baseline_id, f.candidate_event_id into strict v_new, v_new_candidate
  from pg_temp.test_022_active_ready_candidate(v_series, 'T14NEW') f;
  set constraints all immediate;
  set constraints all deferred;
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, supersedes_event_id)
    values (v_new, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_new_candidate);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (14, 'second current ACTIVE in same series fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (14, 'second current ACTIVE in same series fails',
       case when sqlerrm like 'baseline series%current ACTIVE baselines%' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T15 zero ACTIVE / zero CANDIDATE is valid.
do $test$
declare v_series uuid; v_baseline uuid;
begin
  begin
    v_series := pg_temp.test_022_new_series('T15');
    v_baseline := pg_temp.test_022_new_baseline(v_series, 'T15');
    perform s2t_fhir.assert_baseline_series_lifecycle(v_series);
    insert into pg_temp.test_022_results values
      (15, 'zero ACTIVE / zero CANDIDATE is valid', 'PASS', 'private invariant assertion accepted empty series state');
  exception when others then
    insert into pg_temp.test_022_results values
      (15, 'zero ACTIVE / zero CANDIDATE is valid', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T16 different series do not conflict.
do $test$
declare v_s1 uuid; v_s2 uuid; v_b1 uuid; v_b2 uuid;
begin
  begin
    v_s1 := pg_temp.test_022_new_series('T16A');
    v_s2 := pg_temp.test_022_new_series('T16B');
    v_b1 := pg_temp.test_022_new_baseline(v_s1, 'T16A');
    v_b2 := pg_temp.test_022_new_baseline(v_s2, 'T16B');
    perform pg_temp.test_022_candidate(v_b1);
    perform pg_temp.test_022_candidate(v_b2);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (16, 'different series do not conflict', 'PASS', 'one CANDIDATE accepted in each series');
  exception when others then
    insert into pg_temp.test_022_results values
      (16, 'different series do not conflict', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T17/T18 candidate replacement in both logical operation orders.
do $test$
declare v_series uuid; v_old uuid; v_new uuid; v_old_event uuid;
begin
  begin
    v_series := pg_temp.test_022_new_series('T17');
    v_old := pg_temp.test_022_new_baseline(v_series, 'T17OLD');
    v_old_event := pg_temp.test_022_candidate(v_old);
    set constraints all immediate;
    set constraints all deferred;
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), 'candidate replacement A', v_old_event);
    v_new := pg_temp.test_022_new_baseline(v_series, 'T17NEW');
    perform pg_temp.test_022_candidate(v_new);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (17, 'candidate replacement: supersede then create', 'PASS', 'final cardinality accepted');
  exception when others then
    insert into pg_temp.test_022_results values
      (17, 'candidate replacement: supersede then create', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;

  begin
    v_series := pg_temp.test_022_new_series('T18');
    v_old := pg_temp.test_022_new_baseline(v_series, 'T18OLD');
    v_old_event := pg_temp.test_022_candidate(v_old);
    set constraints all immediate;
    set constraints all deferred;
    v_new := pg_temp.test_022_new_baseline(v_series, 'T18NEW');
    perform pg_temp.test_022_candidate(v_new);
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), 'candidate replacement B', v_old_event);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (18, 'candidate replacement: create then supersede', 'PASS', 'transient duplicate candidate accepted until final check');
  exception when others then
    insert into pg_temp.test_022_results values
      (18, 'candidate replacement: create then supersede', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T19/T20 promotion in both logical operation orders.
do $test$
declare
  v_series uuid; v_old uuid; v_old_candidate uuid; v_old_active uuid;
  v_new uuid; v_new_candidate uuid;
begin
  begin
    v_series := pg_temp.test_022_new_series('T19');
    select f.baseline_id, f.candidate_event_id into strict v_old, v_old_candidate
    from pg_temp.test_022_active_ready_candidate(v_series, 'T19OLD') f;
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id, supersedes_event_id)
    values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_old_candidate)
    returning baseline_lifecycle_event_id into v_old_active;
    set constraints all immediate;
    set constraints all deferred;
    select f.baseline_id, f.candidate_event_id into strict v_new, v_new_candidate
    from pg_temp.test_022_active_ready_candidate(v_series, 'T19NEW') f;
    set constraints all immediate;
    set constraints all deferred;
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), 'promotion A', v_old_active);
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id, supersedes_event_id)
    values (v_new, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_new_candidate);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (19, 'promotion: supersede old then activate new', 'PASS', 'final cardinality accepted');
  exception when others then
    insert into pg_temp.test_022_results values
      (19, 'promotion: supersede old then activate new', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;

  begin
    v_series := pg_temp.test_022_new_series('T20');
    select f.baseline_id, f.candidate_event_id into strict v_old, v_old_candidate
    from pg_temp.test_022_active_ready_candidate(v_series, 'T20OLD') f;
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id, supersedes_event_id)
    values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_old_candidate)
    returning baseline_lifecycle_event_id into v_old_active;
    set constraints all immediate;
    set constraints all deferred;
    select f.baseline_id, f.candidate_event_id into strict v_new, v_new_candidate
    from pg_temp.test_022_active_ready_candidate(v_series, 'T20NEW') f;
    set constraints all immediate;
    set constraints all deferred;
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id, supersedes_event_id)
    values (v_new, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_new_candidate);
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, reason, supersedes_event_id)
    values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
            transaction_timestamp(), pg_temp.test_022_actor(), 'promotion B', v_old_active);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (20, 'promotion: activate new then supersede old', 'PASS', 'transient duplicate ACTIVE accepted until final check');
  exception when others then
    insert into pg_temp.test_022_results values
      (20, 'promotion: activate new then supersede old', 'FAIL', sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T21 incomplete promotion fails at deferred constraint evaluation.
do $test$
declare
  v_series uuid; v_old uuid; v_old_candidate uuid;
  v_new uuid; v_new_candidate uuid;
begin
  v_series := pg_temp.test_022_new_series('T21');
  select f.baseline_id, f.candidate_event_id into strict v_old, v_old_candidate
  from pg_temp.test_022_active_ready_candidate(v_series, 'T21OLD') f;
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id, supersedes_event_id)
  values (v_old, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
          transaction_timestamp(), pg_temp.test_022_actor(), v_old_candidate);
  set constraints all immediate;
  set constraints all deferred;
  select f.baseline_id, f.candidate_event_id into strict v_new, v_new_candidate
  from pg_temp.test_022_active_ready_candidate(v_series, 'T21NEW') f;
  set constraints all immediate;
  set constraints all deferred;
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at, actor_principal_id, supersedes_event_id)
    values (v_new, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_new_candidate);
    set constraints all immediate;
    insert into pg_temp.test_022_results values
      (21, 'incomplete promotion fails deferred evaluation', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (21, 'incomplete promotion fails deferred evaluation',
       case when sqlerrm like 'baseline series%current ACTIVE baselines%' then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
  set constraints all deferred;
end
$test$;

-- T22 helper functions are not executable by importer/client roles.
insert into pg_temp.test_022_results
select 22, 'importer/client roles cannot EXECUTE helper functions',
       case when count(*) filter (
         where has_function_privilege(r.oid, f.oid, 'EXECUTE')
       ) = 0 then 'PASS' else 'FAIL' end,
       'effective EXECUTE grants=' || count(*) filter (
         where has_function_privilege(r.oid, f.oid, 'EXECUTE')
       )
from (
  select p.oid
  from pg_catalog.pg_proc p
  where p.oid in (
    to_regprocedure('s2t_fhir.validate_baseline_lifecycle_insert()'),
    to_regprocedure('s2t_fhir.assert_baseline_series_lifecycle(uuid)'),
    to_regprocedure('s2t_fhir.check_baseline_series_lifecycle()')
  )
) f
cross join (
  select r.oid
  from pg_catalog.pg_roles r
  where r.rolname in (
    'anon', 'authenticated', 'service_role',
    's2t_fhir_importer', 's2t_fhir_api_reader',
    's2t_fhir_governance_reader'
  )
) r;

-- T23 SUPERSEDED is terminal; a direct-current successor is rejected.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid; v_superseded uuid;
begin
  v_series := pg_temp.test_022_new_series('T23');
  v_baseline := pg_temp.test_022_new_baseline(v_series, 'T23');
  v_candidate := pg_temp.test_022_candidate(v_baseline);
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, reason, supersedes_event_id)
  values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'SUPERSEDED'),
          transaction_timestamp(), pg_temp.test_022_actor(),
          'terminal transition test', v_candidate)
  returning baseline_lifecycle_event_id into v_superseded;
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_superseded);
    insert into pg_temp.test_022_results values
      (23, 'SUPERSEDED is terminal', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (23, 'SUPERSEDED is terminal',
       case when sqlerrm like 'baseline lifecycle transition from SUPERSEDED to ACTIVE%'
            then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- T24 ACTIVE cannot return to CANDIDATE.
do $test$
declare v_series uuid; v_baseline uuid; v_candidate uuid; v_active uuid;
begin
  v_series := pg_temp.test_022_new_series('T24');
  select f.baseline_id, f.candidate_event_id into strict v_baseline, v_candidate
  from pg_temp.test_022_active_ready_candidate(v_series, 'T24') f;
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id, lifecycle_status_value_id, occurred_at,
     actor_principal_id, supersedes_event_id)
  values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'ACTIVE'),
          transaction_timestamp(), pg_temp.test_022_actor(), v_candidate)
  returning baseline_lifecycle_event_id into v_active;
  begin
    insert into s2t_fhir.baseline_lifecycle_event
      (baseline_version_id, lifecycle_status_value_id, occurred_at,
       actor_principal_id, supersedes_event_id)
    values (v_baseline, pg_temp.test_022_ref('BASELINE_LIFECYCLE_STATUS', 'CANDIDATE'),
            transaction_timestamp(), pg_temp.test_022_actor(), v_active);
    insert into pg_temp.test_022_results values
      (24, 'ACTIVE -> CANDIDATE fails', 'FAIL', 'unexpected success');
  exception when others then
    insert into pg_temp.test_022_results values
      (24, 'ACTIVE -> CANDIDATE fails',
       case when sqlerrm like 'baseline lifecycle transition from ACTIVE to CANDIDATE%'
            then 'PASS' else 'FAIL' end,
       sqlstate || ': ' || sqlerrm);
  end;
end
$test$;

-- Historical-only paths are not exercised by mutating governed rows.
insert into pg_temp.test_022_results values
  (25, 'legacy PENDING_APPROVAL transition paths', 'NOT RUN / FIXTURE REQUIRED',
   'Requires a disposable pre-022 PENDING_APPROVAL fixture; governed historical rows are not mutated'),
  (26, 'legacy RETIRED terminal behavior', 'NOT RUN / FIXTURE REQUIRED',
   'Requires a disposable pre-022 RETIRED fixture; governed historical rows are not mutated');

-- Compact runtime result set. Any FAIL blocks acceptance.
select 0 as test_no, 'RUNTIME SUMMARY' as test_name,
       case when count(*) filter (where status = 'FAIL') = 0 then 'PASS' else 'FAIL' end as status,
       format('%s passed, %s failed, %s not run',
         count(*) filter (where status = 'PASS'),
         count(*) filter (where status = 'FAIL'),
         count(*) filter (where status = 'NOT RUN / FIXTURE REQUIRED')) as detail
from pg_temp.test_022_results
union all
select test_no, test_name, status, detail
from pg_temp.test_022_results
order by test_no;

rollback;

-- READ-ONLY regression evidence after rollback. These hashes must equal the
-- RUNTIME BEFORE rows above and FP 102/104/106 from preflight/postdeploy.
select 'RUNTIME AFTER ROLLBACK active_baseline' as fingerprint_name,
       md5(coalesce(string_agg(x::text, '|' order by x::text), '')) as fingerprint
from s2t_fhir_api.active_baseline x
union all
select 'RUNTIME AFTER ROLLBACK active_mapping_record',
       md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
from s2t_fhir_api.active_mapping_record x
union all
select 'RUNTIME AFTER ROLLBACK active RPC JSON',
       md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text, '<null>'));

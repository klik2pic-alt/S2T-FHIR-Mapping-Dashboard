-- C01-R2 rollback-only concurrency execution for Supabase SQL Editor.
-- Fixture: T023-CONC-PACK-20261010-R2-C01
--
-- IMPORTANT: RUN PRE, SESSION A, SESSION B, OBSERVER, and RUN POST are separate
-- selections. Each worker transaction must be submitted in one Run action.
-- Never split a worker's BEGIN -> wrapper -> ROLLBACK sequence across Runs.

-- ==========================================================================
-- RUN PRE START - execute once and retain fixture_fingerprint
-- ==========================================================================
with state as (
  select
    (select count(*) from s2t_fhir.baseline_series
     where baseline_series_id = '023c0100-2026-4010-8000-000000000002') as series_count,
    (select count(*) from s2t_fhir.baseline_version
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as baseline_count,
    (select count(*) from s2t_fhir.artifact
     where artifact_id in (
       '023c0102-2026-4010-8000-000000000002',
       '023c0112-2026-4010-8000-000000000002'
     )) as artifact_count,
    (select count(*) from s2t_fhir.baseline_artifact
     where baseline_artifact_id in (
       '023c0104-2026-4010-8000-000000000002',
       '023c0114-2026-4010-8000-000000000002'
     )) as baseline_artifact_count,
    (select count(*) from s2t_fhir.import_run
     where import_run_id in (
       '023c0103-2026-4010-8000-000000000002',
       '023c0113-2026-4010-8000-000000000002'
     )) as import_count,
    (select count(*) from s2t_fhir.baseline_lifecycle_event
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as lifecycle_event_count,
    (select count(*) from s2t_fhir.baseline_candidate_context
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as candidate_context_count,
    (select count(*) from s2t_fhir.baseline_activation_context
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     ) or prior_active_baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as active_context_count,
    (select count(*) from s2t_fhir.baseline_relationship
     where from_baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     ) or to_baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as relationship_count
), fingerprint as (
  select md5(pg_catalog.concat_ws('|',
    series_count, baseline_count, artifact_count, baseline_artifact_count,
    import_count,
    lifecycle_event_count, candidate_context_count, active_context_count,
    relationship_count,
    '023c0100-2026-4010-8000-000000000002',
    '023c0101-2026-4010-8000-000000000002',
    '023c0111-2026-4010-8000-000000000002',
    '023c0102-2026-4010-8000-000000000002',
    '023c0112-2026-4010-8000-000000000002',
    '023c0104-2026-4010-8000-000000000002',
    '023c0114-2026-4010-8000-000000000002',
    '023c0103-2026-4010-8000-000000000002',
    '023c0113-2026-4010-8000-000000000002'
  )) as fixture_fingerprint
  from state
)
select 'C01_R2_PRE' as section, state.*, fingerprint.fixture_fingerprint,
       case
         when series_count = 1 and baseline_count = 2 and artifact_count = 2
          and baseline_artifact_count = 2 and import_count = 2
          and lifecycle_event_count = 0
          and candidate_context_count = 0 and active_context_count = 0
          and relationship_count = 0
         then 'READY'
         else 'FAIL'
       end as status
from state cross join fingerprint;
-- RUN PRE END

-- ==========================================================================
-- SESSION A START - select this entire section and press Run exactly once
-- ==========================================================================
begin;
set constraints all deferred;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '023c01a1-0000-4000-8000-000000000001',
  true
);
select set_config(
  'application_name',
  'T023-CONC-PACK-20261010-R2-C01-SESSION-A',
  true
);
select pg_backend_pid() as session_a_pid;
select s2t_fhir_api.publish_candidate_baseline(
  '023c0101-2026-4010-8000-000000000002',
  '023c0103-2026-4010-8000-000000000002',
  null,
  null,
  transaction_timestamp(),
  null
) as session_a_publish_result;
select pg_sleep(90);
rollback;
-- SESSION A END

-- ==========================================================================
-- SESSION B START - select this entire section and press Run exactly once
-- Start while Session A is sleeping. This call should block on the series row.
-- ==========================================================================
begin;
set constraints all deferred;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '023c01b1-0000-4000-8000-000000000001',
  true
);
select set_config(
  'application_name',
  'T023-CONC-PACK-20261010-R2-C01-SESSION-B',
  true
);
select pg_backend_pid() as session_b_pid;
select s2t_fhir_api.publish_candidate_baseline(
  '023c0111-2026-4010-8000-000000000002',
  '023c0113-2026-4010-8000-000000000002',
  null,
  null,
  transaction_timestamp(),
  null
) as session_b_publish_result;
rollback;
-- SESSION B END

-- ==========================================================================
-- OBSERVER START - read only; run from a third SQL Editor tab
-- Replace both zero PID values after observing the worker PIDs. With zeros the
-- query discovers both workers by exact transaction-local application_name.
-- ==========================================================================
with operator_pids(session_name, pid) as (
  values
    ('SESSION_A'::text, 0::integer),
    ('SESSION_B'::text, 0::integer)
), selected_activity as (
  select
    coalesce(
      p.session_name,
      case a.application_name
        when 'T023-CONC-PACK-20261010-R2-C01-SESSION-A' then 'SESSION_A'
        when 'T023-CONC-PACK-20261010-R2-C01-SESSION-B' then 'SESSION_B'
        else 'DISCOVER'
      end
    ) as session_name,
    a.pid,
    a.application_name,
    a.state,
    a.xact_start,
    a.query_start,
    a.wait_event_type,
    a.wait_event,
    pg_catalog.pg_blocking_pids(a.pid) as blocking_pids,
    a.query
  from pg_catalog.pg_stat_activity a
  left join operator_pids p on p.pid = a.pid and p.pid > 0
  where a.pid <> pg_backend_pid()
    and a.backend_type = 'client backend'
    and (
      a.pid in (select pid from operator_pids where pid > 0)
      or (
        not exists (select 1 from operator_pids where pid > 0)
        and a.application_name in (
          'T023-CONC-PACK-20261010-R2-C01-SESSION-A',
          'T023-CONC-PACK-20261010-R2-C01-SESSION-B'
        )
      )
    )
)
select *
from selected_activity
order by pid;
-- OBSERVER END

-- ==========================================================================
-- RUN POST START - read only; run after both worker Runs finish
-- Replace PASTE_PRE_RUN_FINGERPRINT_HERE with the exact RUN PRE value.
-- ==========================================================================
with parameters(expected_pre_fingerprint) as (
  values ('PASTE_PRE_RUN_FINGERPRINT_HERE'::text)
), state as (
  select
    (select count(*) from s2t_fhir.baseline_series
     where baseline_series_id = '023c0100-2026-4010-8000-000000000002') as series_count,
    (select count(*) from s2t_fhir.baseline_version
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as baseline_count,
    (select count(*) from s2t_fhir.artifact
     where artifact_id in (
       '023c0102-2026-4010-8000-000000000002',
       '023c0112-2026-4010-8000-000000000002'
     )) as artifact_count,
    (select count(*) from s2t_fhir.baseline_artifact
     where baseline_artifact_id in (
       '023c0104-2026-4010-8000-000000000002',
       '023c0114-2026-4010-8000-000000000002'
     )) as baseline_artifact_count,
    (select count(*) from s2t_fhir.import_run
     where import_run_id in (
       '023c0103-2026-4010-8000-000000000002',
       '023c0113-2026-4010-8000-000000000002'
     )) as import_count,
    (select count(*) from s2t_fhir.baseline_lifecycle_event
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as lifecycle_event_count,
    (select count(*) from s2t_fhir.baseline_candidate_context
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as candidate_context_count,
    (select count(*) from s2t_fhir.baseline_activation_context
     where baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     ) or prior_active_baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as active_context_count,
    (select count(*) from s2t_fhir.baseline_relationship
     where from_baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     ) or to_baseline_version_id in (
       '023c0101-2026-4010-8000-000000000002',
       '023c0111-2026-4010-8000-000000000002'
     )) as relationship_count
), fingerprint as (
  select md5(pg_catalog.concat_ws('|',
    series_count, baseline_count, artifact_count, baseline_artifact_count,
    import_count,
    lifecycle_event_count, candidate_context_count, active_context_count,
    relationship_count,
    '023c0100-2026-4010-8000-000000000002',
    '023c0101-2026-4010-8000-000000000002',
    '023c0111-2026-4010-8000-000000000002',
    '023c0102-2026-4010-8000-000000000002',
    '023c0112-2026-4010-8000-000000000002',
    '023c0104-2026-4010-8000-000000000002',
    '023c0114-2026-4010-8000-000000000002',
    '023c0103-2026-4010-8000-000000000002',
    '023c0113-2026-4010-8000-000000000002'
  )) as fixture_fingerprint
  from state
)
select
  'C01_R2_POST' as section,
  state.*,
  parameters.expected_pre_fingerprint,
  fingerprint.fixture_fingerprint as post_run_fingerprint,
  case
    when parameters.expected_pre_fingerprint = 'PASTE_PRE_RUN_FINGERPRINT_HERE'
      then 'REPLACE_PRE_FINGERPRINT'
    when lifecycle_event_count <> 0 or candidate_context_count <> 0
      or active_context_count <> 0 or relationship_count <> 0
      then 'FAIL_STATE_CHANGED'
    when fingerprint.fixture_fingerprint <> parameters.expected_pre_fingerprint
      then 'FAIL_FINGERPRINT_CHANGED'
    when series_count = 1 and baseline_count = 2
      and artifact_count = 2 and baseline_artifact_count = 2
      and import_count = 2
      then 'PASS_ROLLBACK_RESTORED_EXACT_PRE_STATE'
    else 'FAIL_SEED_INCOMPLETE'
  end as status
from state
cross join fingerprint
cross join parameters;
-- RUN POST END

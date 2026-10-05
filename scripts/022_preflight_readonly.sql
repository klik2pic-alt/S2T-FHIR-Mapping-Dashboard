-- Migration 022 controlled TEST preflight for S2T-FHIR-DDL-Test.
-- STRICTLY READ-ONLY: SELECT/catalog introspection only.
-- Run before deploying the exact approved migration 022.

with
current_events as (
  select e.*
  from s2t_fhir.baseline_lifecycle_event e
  where not exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event successor
    where successor.supersedes_event_id = e.baseline_lifecycle_event_id
  )
),
series_state as (
  select bv.baseline_series_id, e.baseline_version_id, v.value_code
  from current_events e
  join s2t_fhir.baseline_version bv
    on bv.baseline_version_id = e.baseline_version_id
  join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
   and d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
),
bad_active as (
  select e.baseline_version_id
  from current_events e
  join s2t_fhir.reference_value lifecycle_value
    on lifecycle_value.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain lifecycle_domain
    on lifecycle_domain.reference_domain_id = lifecycle_value.reference_domain_id
   and lifecycle_domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where lifecycle_value.value_code = 'ACTIVE'
    and (
      (
        select count(*)
        from s2t_fhir.baseline_artifact ba
        join s2t_fhir.reference_value role_value
          on role_value.reference_value_id = ba.artifact_role_value_id
        join s2t_fhir.reference_domain role_domain
          on role_domain.reference_domain_id = role_value.reference_domain_id
         and role_domain.domain_code = 'ARTIFACT_ROLE'
        where ba.baseline_version_id = e.baseline_version_id
          and role_value.value_code = 'AUTHORITATIVE_SOURCE'
      ) <> 1
      or not exists (
        select 1
        from s2t_fhir.current_release_gate_evaluation gate_evaluation
        join s2t_fhir.reference_value outcome
          on outcome.reference_value_id = gate_evaluation.gate_outcome_value_id
        join s2t_fhir.reference_domain outcome_domain
          on outcome_domain.reference_domain_id = outcome.reference_domain_id
         and outcome_domain.domain_code = 'RELEASE_GATE_OUTCOME'
        where gate_evaluation.baseline_version_id = e.baseline_version_id
          and outcome.value_code = 'PASSED'
      )
    )
),
checks(test_no, test_name, passed, detail) as (
  select 1, 'enabled migration principal prerequisite',
         count(*) = 1,
         'enabled postgres-role/s2t_fhir_migrator count=' || count(*)
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null

  union all
  select 2, 'lifecycle domain prerequisite',
         count(*) = 1,
         'non-versioned BASELINE_LIFECYCLE_STATUS domain count=' || count(*)
  from s2t_fhir.reference_domain d
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and d.is_versioned = false

  union all
  select 3, 'legacy lifecycle values exactly once',
         count(*) filter (where v.value_code = 'PENDING_APPROVAL') = 1
         and count(*) filter (where v.value_code = 'ACTIVE') = 1
         and count(*) filter (where v.value_code = 'RETIRED') = 1,
         format('PENDING_APPROVAL=%s ACTIVE=%s RETIRED=%s',
           count(*) filter (where v.value_code = 'PENDING_APPROVAL'),
           count(*) filter (where v.value_code = 'ACTIVE'),
           count(*) filter (where v.value_code = 'RETIRED'))
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'

  union all
  select 4, 'new lifecycle values absent before deployment',
         count(*) = 0,
         'CANDIDATE/SUPERSEDED rows=' || count(*)
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code in ('CANDIDATE', 'SUPERSEDED')

  union all
  select 5, 'one root maximum per baseline',
         count(*) = 0,
         'violating baselines=' || count(*)
  from (
    select e.baseline_version_id
    from s2t_fhir.baseline_lifecycle_event e
    where e.supersedes_event_id is null
    group by e.baseline_version_id
    having count(*) > 1
  ) violations

  union all
  select 6, 'one successor maximum per lifecycle event',
         count(*) = 0,
         'forked predecessor events=' || count(*)
  from (
    select e.supersedes_event_id
    from s2t_fhir.baseline_lifecycle_event e
    where e.supersedes_event_id is not null
    group by e.supersedes_event_id
    having count(*) > 1
  ) violations

  union all
  select 7, 'no cross-baseline lifecycle predecessor',
         count(*) = 0,
         'cross-baseline links=' || count(*)
  from s2t_fhir.baseline_lifecycle_event child
  join s2t_fhir.baseline_lifecycle_event parent
    on parent.baseline_lifecycle_event_id = child.supersedes_event_id
  where child.baseline_version_id <> parent.baseline_version_id

  union all
  select 8, 'lifecycle time chain is monotonic',
         count(*) = 0,
         'backdated successors=' || count(*)
  from s2t_fhir.baseline_lifecycle_event child
  join s2t_fhir.baseline_lifecycle_event parent
    on parent.baseline_lifecycle_event_id = child.supersedes_event_id
  where child.occurred_at < parent.occurred_at

  union all
  select 9, 'one current lifecycle event maximum per baseline',
         count(*) = 0,
         'baselines with multiple current leaves=' || count(*)
  from (
    select e.baseline_version_id
    from current_events e
    group by e.baseline_version_id
    having count(*) > 1
  ) violations

  union all
  select 10, 'current per-series lifecycle cardinality',
         count(*) = 0,
         'violating series=' || count(*)
  from (
    select s.baseline_series_id
    from series_state s
    group by s.baseline_series_id
    having count(*) filter (where s.value_code = 'ACTIVE') > 1
        or count(*) filter (where s.value_code = 'PENDING_APPROVAL') > 1
  ) violations

  union all
  select 11, 'existing ACTIVE artifact/current-PASSED-gate prerequisite',
         count(*) = 0,
         'invalid current ACTIVE baselines=' || count(*)
  from bad_active

  union all
  select 12, '022 indexes absent',
         to_regclass('s2t_fhir.baseline_lifecycle_root_once_uq') is null
         and to_regclass('s2t_fhir.baseline_lifecycle_superseded_once_uq') is null,
         format('root=%s successor=%s',
           coalesce(to_regclass('s2t_fhir.baseline_lifecycle_root_once_uq')::text, '<absent>'),
           coalesce(to_regclass('s2t_fhir.baseline_lifecycle_superseded_once_uq')::text, '<absent>'))

  union all
  select 13, '022 functions absent',
         to_regprocedure('s2t_fhir.validate_baseline_lifecycle_insert()') is null
         and to_regprocedure('s2t_fhir.assert_baseline_series_lifecycle(uuid)') is null
         and to_regprocedure('s2t_fhir.check_baseline_series_lifecycle()') is null,
         format('validate=%s assert=%s wrapper=%s',
           coalesce(to_regprocedure('s2t_fhir.validate_baseline_lifecycle_insert()')::text, '<absent>'),
           coalesce(to_regprocedure('s2t_fhir.assert_baseline_series_lifecycle(uuid)')::text, '<absent>'),
           coalesce(to_regprocedure('s2t_fhir.check_baseline_series_lifecycle()')::text, '<absent>'))

  union all
  select 14, '022 triggers absent',
         count(*) = 0,
         'matching triggers=' || count(*)
  from pg_catalog.pg_trigger t
  join pg_catalog.pg_class c on c.oid = t.tgrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 's2t_fhir'
    and c.relname = 'baseline_lifecycle_event'
    and t.tgname in (
      'baseline_lifecycle_transition_trg',
      'baseline_series_lifecycle_cardinality_trg'
    )
    and not t.tgisinternal

  union all
  select 15, 'existing lifecycle events use deployed legacy values',
         count(*) = 0,
         'events with unexpected lifecycle reference=' || count(*)
  from s2t_fhir.baseline_lifecycle_event e
  left join s2t_fhir.reference_value v
    on v.reference_value_id = e.lifecycle_status_value_id
  left join s2t_fhir.reference_domain d
    on d.reference_domain_id = v.reference_domain_id
  where d.domain_code is distinct from 'BASELINE_LIFECYCLE_STATUS'
     or v.value_code not in ('PENDING_APPROVAL', 'ACTIVE', 'RETIRED')
),
fingerprints(test_no, test_name, passed, detail) as (
  select 101, 'FP current ACTIVE lifecycle state', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from (
    select bv.baseline_code, bv.version_label, bs.source_system, bs.fhir_resource,
           e.occurred_at, v.value_code as lifecycle_status
    from current_events e
    join s2t_fhir.baseline_version bv using (baseline_version_id)
    join s2t_fhir.baseline_series bs using (baseline_series_id)
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    where v.value_code = 'ACTIVE'
  ) x

  union all
  select 102, 'FP s2t_fhir_api.active_baseline', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.active_baseline x

  union all
  select 103, 'FP s2t_fhir_api._active_release_context', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api._active_release_context x

  union all
  select 104, 'FP s2t_fhir_api.active_mapping_record', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.active_mapping_record x

  union all
  select 105, 'FP active quarantine views', true,
         md5(coalesce(string_agg(x, '|' order by x), ''))
  from (
    select 'item:' || i::text as x from s2t_fhir_api.active_quarantine_item i
    union all
    select 'summary:' || s::text from s2t_fhir_api.active_quarantine_summary s
  ) q

  union all
  select 106, 'FP active MedicationRequest RPC JSON', true,
         md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text, '<null>'))

  union all
  select 107, 'FP API view/function contracts', true,
         md5(coalesce(string_agg(x.definition, E'\n' order by x.object_name), ''))
  from (
    select 'view:' || n.nspname || '.' || c.relname as object_name,
           pg_get_viewdef(c.oid, true) as definition
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 's2t_fhir_api'
      and c.relkind in ('v', 'm')
    union all
    select 'function:' || p.oid::regprocedure::text,
           pg_get_functiondef(p.oid)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 's2t_fhir_api'
  ) x

  union all
  select 108, 'FP pre-022 database contracts', true,
         md5(coalesce(string_agg(x.definition, E'\n' order by x.object_name), ''))
  from (
    select 'constraint:' || c.oid::regclass::text || ':' || con.conname as object_name,
           pg_get_constraintdef(con.oid, true) as definition
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class c on c.oid = con.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and not (
        con.contype = 't'
        and con.conname = 'baseline_series_lifecycle_cardinality_trg'
        and con.conrelid =
          's2t_fhir.baseline_lifecycle_event'::regclass
      )
    union all
    select 'index:' || idx.oid::regclass::text, pg_get_indexdef(idx.oid)
    from pg_catalog.pg_class idx
    join pg_catalog.pg_namespace n on n.oid = idx.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and idx.relkind = 'i'
      and idx.relname not in (
        'baseline_lifecycle_root_once_uq',
        'baseline_lifecycle_superseded_once_uq'
      )
    union all
    select 'function:' || p.oid::regprocedure::text,
           pg_get_functiondef(p.oid) || E'\nACL=' || coalesce(p.proacl::text, '<default>')
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and p.proname not in (
        'validate_baseline_lifecycle_insert',
        'assert_baseline_series_lifecycle',
        'check_baseline_series_lifecycle'
      )
    union all
    select 'trigger:' || t.tgrelid::regclass::text || ':' || t.tgname,
           pg_get_triggerdef(t.oid, true)
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and not t.tgisinternal
      and t.tgname not in (
        'baseline_lifecycle_transition_trg',
        'baseline_series_lifecycle_cardinality_trg'
      )
    union all
    select 'relation-acl:' || c.oid::regclass::text,
           coalesce(c.relacl::text, '<default>')
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and c.relkind in ('r', 'p', 'v', 'm', 'S')
  ) x

  union all
  select 109, 'FP legacy lifecycle reference rows', true,
         md5(coalesce(string_agg(v::text, '|' order by v.value_code), ''))
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code in ('PENDING_APPROVAL', 'ACTIVE', 'RETIRED')
),
all_results as (
  select * from checks
  union all
  select * from fingerprints
),
summary as (
  select 0 as test_no,
         'PREFLIGHT SUMMARY'::text as test_name,
         bool_and(passed) filter (where test_no < 100) as passed,
         format('%s/%s prerequisite checks passed',
           count(*) filter (where test_no < 100 and passed),
           count(*) filter (where test_no < 100)) as detail
  from all_results
)
select test_no, test_name,
       case when passed then 'PASS' else 'FAIL' end as status,
       detail
from (
  select * from summary
  union all
  select * from all_results
) report
order by test_no;

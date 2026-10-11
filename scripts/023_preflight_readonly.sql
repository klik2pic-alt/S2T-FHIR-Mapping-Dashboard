-- Migration 023 controlled TEST preflight for S2T-FHIR-DDL-Test.
-- STRICTLY READ-ONLY: SELECT/catalog introspection only.
-- Run before deploying the exact approved migration 023.

-- Result set 1 is a catalog-only prerequisite gate. It is deliberately a
-- separate statement so missing dependencies produce a diagnostic row before
-- any later data-level check that must bind to those accepted 001-022 objects.
-- If this row is FAIL, stop and do not run or interpret the detailed result set.
with
required_relations(relation_name) as (
  values
    ('s2t_fhir.principal'),
    ('s2t_fhir.reference_domain'),
    ('s2t_fhir.reference_value'),
    ('s2t_fhir.baseline_series'),
    ('s2t_fhir.baseline_version'),
    ('s2t_fhir.baseline_relationship'),
    ('s2t_fhir.baseline_lifecycle_event'),
    ('s2t_fhir.current_baseline_lifecycle_event'),
    ('s2t_fhir.artifact'),
    ('s2t_fhir.baseline_artifact'),
    ('s2t_fhir.import_run'),
    ('s2t_fhir.validation_run'),
    ('s2t_fhir.release_gate_evaluation'),
    ('s2t_fhir.current_release_gate_evaluation'),
    ('s2t_fhir.mapping_resource_registry'),
    ('s2t_fhir.review_actor_authorization'),
    ('s2t_fhir.review_session'),
    ('s2t_fhir.mapping_review_event'),
    ('s2t_fhir.current_mapping_review'),
    ('s2t_governance.governance_mapping_link'),
    ('s2t_fhir_api._active_release_context'),
    ('s2t_fhir_api.active_baseline'),
    ('s2t_fhir_api.active_mapping_record'),
    ('s2t_fhir_api.active_quarantine_item'),
    ('s2t_fhir_api.active_quarantine_summary'),
    ('s2t_fhir_api.governed_mapping_identity'),
    ('s2t_fhir_api.active_mapping_review_status'),
    ('s2t_fhir_api.governance_parties'),
    ('s2t_fhir_api.governance_question_timeline'),
    ('s2t_fhir_api.governance_mapping_links'),
    ('s2t_fhir_api.governance_open_requests'),
    ('s2t_fhir_api.governance_question_timing'),
    ('s2t_fhir_api.governance_questions')
),
required_functions(signature) as (
  values
    ('s2t_fhir.validate_baseline_lifecycle_insert()'),
    ('s2t_fhir.assert_baseline_series_lifecycle(uuid)'),
    ('s2t_fhir.check_baseline_series_lifecycle()'),
    ('s2t_fhir.assert_release_gate_evaluation_integrity(uuid)'),
    ('s2t_fhir_api._resolve_authenticated_principal()'),
    ('s2t_fhir_api._require_authenticated_review_principal()'),
    ('s2t_fhir_api._record_mapping_review_core(text,text,uuid,uuid,text)'),
    ('s2t_governance._current_reviewer_principal()'),
    ('s2t_governance._resolve_mapping_identity(text,text,text)'),
    ('s2t_fhir_api._governance_question_timing(uuid)'),
    ('s2t_fhir_api.gov_link_mapping(uuid,jsonb,timestamptz)'),
    ('s2t_fhir_api.get_active_medication_request_cato()'),
    ('s2t_fhir_api.get_active_medication_request_cato_review_progress()')
),
missing as (
  select 'relation'::text as object_kind, relation_name as object_name
  from required_relations
  where to_regclass(relation_name) is null
  union all
  select 'function', signature
  from required_functions
  where to_regprocedure(signature) is null
)
select -1 as test_no, 'CATALOG PREREQUISITE GATE'::text as test_name,
       case when count(*) = 0 then 'PASS' else 'FAIL' end as status,
       coalesce(string_agg(object_kind || ':' || object_name, ', '
                           order by object_kind, object_name),
                '<all required 001-022 objects present>') as detail
from missing;

with
required_relations(relation_name) as (
  values
    ('s2t_fhir.principal'),
    ('s2t_fhir.reference_domain'),
    ('s2t_fhir.reference_value'),
    ('s2t_fhir.baseline_series'),
    ('s2t_fhir.baseline_version'),
    ('s2t_fhir.baseline_relationship'),
    ('s2t_fhir.baseline_lifecycle_event'),
    ('s2t_fhir.current_baseline_lifecycle_event'),
    ('s2t_fhir.artifact'),
    ('s2t_fhir.baseline_artifact'),
    ('s2t_fhir.import_run'),
    ('s2t_fhir.validation_run'),
    ('s2t_fhir.release_gate_evaluation'),
    ('s2t_fhir.current_release_gate_evaluation'),
    ('s2t_fhir.mapping_resource_registry'),
    ('s2t_fhir.review_actor_authorization'),
    ('s2t_fhir.review_session'),
    ('s2t_fhir.mapping_review_event'),
    ('s2t_fhir.current_mapping_review'),
    ('s2t_governance.governance_mapping_link'),
    ('s2t_fhir_api._active_release_context'),
    ('s2t_fhir_api.active_baseline'),
    ('s2t_fhir_api.active_mapping_record'),
    ('s2t_fhir_api.active_quarantine_item'),
    ('s2t_fhir_api.active_quarantine_summary'),
    ('s2t_fhir_api.governed_mapping_identity'),
    ('s2t_fhir_api.active_mapping_review_status'),
    ('s2t_fhir_api.governance_parties'),
    ('s2t_fhir_api.governance_question_timeline'),
    ('s2t_fhir_api.governance_mapping_links'),
    ('s2t_fhir_api.governance_open_requests'),
    ('s2t_fhir_api.governance_question_timing'),
    ('s2t_fhir_api.governance_questions')
),
required_functions(signature) as (
  values
    ('s2t_fhir.validate_baseline_lifecycle_insert()'),
    ('s2t_fhir.assert_baseline_series_lifecycle(uuid)'),
    ('s2t_fhir.check_baseline_series_lifecycle()'),
    ('s2t_fhir.assert_release_gate_evaluation_integrity(uuid)'),
    ('s2t_fhir_api._resolve_authenticated_principal()'),
    ('s2t_fhir_api._require_authenticated_review_principal()'),
    ('s2t_fhir_api._record_mapping_review_core(text,text,uuid,uuid,text)'),
    ('s2t_governance._current_reviewer_principal()'),
    ('s2t_governance._resolve_mapping_identity(text,text,text)'),
    ('s2t_fhir_api._governance_question_timing(uuid)'),
    ('s2t_fhir_api.gov_link_mapping(uuid,jsonb,timestamptz)'),
    ('s2t_fhir_api.get_active_medication_request_cato()'),
    ('s2t_fhir_api.get_active_medication_request_cato_review_progress()')
),
new_relations(relation_name) as (
  values
    ('s2t_fhir.baseline_action_authorization'),
    ('s2t_fhir.baseline_candidate_context'),
    ('s2t_fhir.candidate_review_session_state'),
    ('s2t_fhir.baseline_activation_context')
),
new_functions(signature) as (
  values
    ('s2t_fhir.protect_baseline_action_authorization_update()'),
    ('s2t_fhir_api._require_authenticated_baseline_capability(text)'),
    ('s2t_fhir.grant_baseline_action(uuid,text,uuid)'),
    ('s2t_fhir.revoke_baseline_action(uuid,text,uuid)'),
    ('s2t_fhir.validate_baseline_candidate_context()'),
    ('s2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)'),
    ('s2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)'),
    ('s2t_fhir._require_current_candidate_context(uuid,uuid)'),
    ('s2t_fhir._lock_current_candidate_context(uuid,uuid)'),
    ('s2t_fhir_api._candidate_mapping_nodes(uuid,uuid)'),
    ('s2t_fhir.protect_review_lifecycle_provenance()'),
    ('s2t_fhir.validate_review_lifecycle_provenance()'),
    ('s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)'),
    ('s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)'),
    ('s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)'),
    ('s2t_fhir_api.get_candidate_medication_request_cato(uuid,uuid)'),
    ('s2t_fhir_api.get_candidate_mapping_review_status(uuid,uuid)'),
    ('s2t_fhir_api.get_candidate_mapping_review_progress(uuid,uuid)'),
    ('s2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)'),
    ('s2t_fhir_api.end_authenticated_candidate_review_session(uuid,uuid,uuid)'),
    ('s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)'),
    ('s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid,uuid,text,uuid,text)'),
    ('s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid,uuid,text,uuid,text)'),
    ('s2t_governance.validate_mapping_link_lifecycle_context()'),
    ('s2t_governance._resolve_candidate_mapping_identity(uuid,uuid,text,text,text)'),
    ('s2t_governance._insert_candidate_mapping_link(uuid,uuid,uuid,jsonb,uuid,timestamptz)'),
    ('s2t_fhir_api.gov_link_candidate_mapping(uuid,uuid,uuid,jsonb,timestamptz)'),
    ('s2t_fhir.assert_candidate_activation_eligibility(uuid,uuid,uuid,uuid,timestamptz)'),
    ('s2t_fhir.validate_baseline_activation_context()'),
    ('s2t_fhir.authorize_active_lifecycle_insert()'),
    ('s2t_fhir.assert_activated_baseline_eligibility(uuid)'),
    ('s2t_fhir.check_active_lifecycle_eligibility()'),
    ('s2t_fhir.check_governed_active_dependency()'),
    ('s2t_fhir.promote_current_candidate(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)'),
    ('s2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)')
),
new_indexes(index_name) as (
  values
    ('baseline_action_authorization_active_uq'),
    ('baseline_action_authorization_lookup_idx'),
    ('baseline_candidate_context_artifact_idx'),
    ('baseline_candidate_context_created_idx'),
    ('review_session_target_lifecycle_idx'),
    ('mapping_review_event_target_lifecycle_idx'),
    ('governance_mapping_link_candidate_context_idx'),
    ('baseline_activation_context_gate_idx'),
    ('baseline_activation_context_prior_active_idx')
),
new_triggers(relation_name, trigger_name) as (
  values
    ('s2t_fhir.baseline_action_authorization', 'baseline_action_authorization_protect_update_trg'),
    ('s2t_fhir.baseline_action_authorization', 'baseline_action_authorization_reject_delete_trg'),
    ('s2t_fhir.baseline_candidate_context', 'baseline_candidate_context_integrity_trg'),
    ('s2t_fhir.baseline_candidate_context', 'baseline_candidate_context_actor_pair_trg'),
    ('s2t_fhir.baseline_candidate_context', 'baseline_candidate_context_append_only_trg'),
    ('s2t_fhir.review_session', 'review_session_lifecycle_provenance_insert_trg'),
    ('s2t_fhir.review_session', 'review_session_lifecycle_provenance_immutable_trg'),
    ('s2t_fhir.mapping_review_event', 'mapping_review_event_lifecycle_provenance_insert_trg'),
    ('s2t_fhir.mapping_review_event', 'mapping_review_event_lifecycle_provenance_immutable_trg'),
    ('s2t_governance.governance_mapping_link', 'lifecycle_context_validate'),
    ('s2t_fhir.baseline_activation_context', 'baseline_activation_context_integrity_trg'),
    ('s2t_fhir.baseline_activation_context', 'baseline_activation_context_actor_pair_trg'),
    ('s2t_fhir.baseline_activation_context', 'baseline_activation_context_append_only_trg'),
    ('s2t_fhir.baseline_lifecycle_event', 'baseline_active_lifecycle_authorization_trg'),
    ('s2t_fhir.baseline_lifecycle_event', 'baseline_active_lifecycle_eligibility_trg'),
    ('s2t_fhir.release_gate_evaluation', 'governed_active_release_gate_dependency_trg'),
    ('s2t_fhir.validation_run', 'governed_active_validation_dependency_trg')
),
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
  select bv.baseline_series_id, e.baseline_version_id, status.value_code
  from current_events e
  join s2t_fhir.baseline_version bv using (baseline_version_id)
  join s2t_fhir.reference_value status
    on status.reference_value_id = e.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
),
checks(test_no, test_name, status, detail) as (
  select 1, 'migration principal prerequisite',
         case when count(*) = 1 then 'PASS' else 'FAIL' end,
         'enabled migrator principals=' || count(*)
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null

  union all
  select 2, 'required 001-022 relations',
         case when count(*) filter (where to_regclass(relation_name) is null) = 0
              then 'PASS' else 'FAIL' end,
         coalesce(string_agg(relation_name, ', ' order by relation_name)
           filter (where to_regclass(relation_name) is null), '<none missing>')
  from required_relations

  union all
  select 3, 'required 001-022 functions',
         case when count(*) filter (where to_regprocedure(signature) is null) = 0
              then 'PASS' else 'FAIL' end,
         coalesce(string_agg(signature, ', ' order by signature)
           filter (where to_regprocedure(signature) is null), '<none missing>')
  from required_functions

  union all
  select 4, 'Migration 022 lifecycle vocabulary',
         case when count(*) = 5
                and count(*) filter (where v.value_code = 'PENDING_APPROVAL') = 1
                and count(*) filter (where v.value_code = 'ACTIVE') = 1
                and count(*) filter (where v.value_code = 'RETIRED') = 1
                and count(*) filter (where v.value_code = 'CANDIDATE') = 1
                and count(*) filter (where v.value_code = 'SUPERSEDED') = 1
              then 'PASS' else 'FAIL' end,
         coalesce(string_agg(v.value_code, ',' order by v.value_code), '<none>')
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and not d.is_versioned
    and v.value_code in ('PENDING_APPROVAL','ACTIVE','RETIRED','CANDIDATE','SUPERSEDED')

  union all
  select 5, 'lifecycle roots/successors/chains',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         'violations=' || count(*)
  from (
    select e.baseline_version_id::text as violation
    from s2t_fhir.baseline_lifecycle_event e
    where e.supersedes_event_id is null
    group by e.baseline_version_id having count(*) > 1
    union all
    select e.supersedes_event_id::text
    from s2t_fhir.baseline_lifecycle_event e
    where e.supersedes_event_id is not null
    group by e.supersedes_event_id having count(*) > 1
    union all
    select child.baseline_lifecycle_event_id::text
    from s2t_fhir.baseline_lifecycle_event child
    join s2t_fhir.baseline_lifecycle_event parent
      on parent.baseline_lifecycle_event_id = child.supersedes_event_id
    where child.baseline_version_id <> parent.baseline_version_id
       or child.occurred_at < parent.occurred_at
  ) violations

  union all
  select 6, 'current lifecycle leaf uniqueness',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         'baselines with multiple leaves=' || count(*)
  from (
    select baseline_version_id from current_events
    group by baseline_version_id having count(*) > 1
  ) violations

  union all
  select 7, 'per-series ACTIVE/Candidate cardinality',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         'violating series=' || count(*)
  from (
    select baseline_series_id from series_state
    group by baseline_series_id
    having count(*) filter (where value_code = 'ACTIVE') > 1
        or count(*) filter (where value_code in ('CANDIDATE','PENDING_APPROVAL')) > 1
  ) violations

  union all
  select 8, 'existing ACTIVE governed-read eligibility',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         'ACTIVE leaves absent from exact active context=' || count(*)
  from current_events e
  join s2t_fhir.reference_value status
    on status.reference_value_id = e.lifecycle_status_value_id
  where status.value_code = 'ACTIVE'
    and (select count(*) from s2t_fhir_api._active_release_context context
         where context.baseline_version_id = e.baseline_version_id) <> 1

  union all
  select 9, 'enabled CATO MedicationRequest registry context',
         case when count(*) = 1 then 'PASS' else 'FAIL' end,
         'enabled rows=' || count(*)
  from s2t_fhir.mapping_resource_registry r
  where r.resource_config_id = 'medication-request-cato'
    and r.source_system = 'CATO'
    and r.fhir_resource = 'MedicationRequest'
    and r.is_enabled

  union all
  select 10, 'review/governance prerequisite owners',
         case when count(*) filter (where owner_name <> 's2t_fhir_owner') = 0
                   and count(*) = 4 then 'PASS' else 'FAIL' end,
         string_agg(object_name || '=' || owner_name, ', ' order by object_name)
  from (
    select c.oid::regclass::text as object_name, owner.rolname as owner_name
    from pg_catalog.pg_class c
    join pg_catalog.pg_roles owner on owner.oid = c.relowner
    where c.oid in (
      to_regclass('s2t_fhir.review_session'),
      to_regclass('s2t_fhir.mapping_review_event'),
      to_regclass('s2t_governance.governance_mapping_link'),
      to_regclass('s2t_fhir.mapping_resource_registry')
    )
  ) owned

  union all
  select 11, 'release-gate/import/artifact prerequisites',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         coalesce(string_agg(relation_name, ', ' order by relation_name), '<none missing>')
  from required_relations
  where relation_name in (
    's2t_fhir.artifact','s2t_fhir.baseline_artifact','s2t_fhir.import_run',
    's2t_fhir.validation_run','s2t_fhir.release_gate_evaluation',
    's2t_fhir.current_release_gate_evaluation'
  ) and to_regclass(relation_name) is null

  union all
  select 12, '023 relations absent',
         case when count(*) filter (where to_regclass(relation_name) is not null) = 0
              then 'PASS' else 'FAIL' end,
         coalesce(string_agg(relation_name, ', ' order by relation_name)
           filter (where to_regclass(relation_name) is not null), '<all absent>')
  from new_relations

  union all
  select 13, '023 functions absent',
         case when count(*) filter (where to_regprocedure(signature) is not null) = 0
              then 'PASS' else 'FAIL' end,
         coalesce(string_agg(signature, ', ' order by signature)
           filter (where to_regprocedure(signature) is not null), '<all absent>')
  from new_functions

  union all
  select 14, '023 indexes absent',
         case when count(*) filter (where to_regclass('s2t_fhir.' || index_name) is not null
                                      or to_regclass('s2t_governance.' || index_name) is not null) = 0
              then 'PASS' else 'FAIL' end,
         coalesce(string_agg(index_name, ', ' order by index_name)
           filter (where to_regclass('s2t_fhir.' || index_name) is not null
                      or to_regclass('s2t_governance.' || index_name) is not null), '<all absent>')
  from new_indexes

  union all
  select 15, '023 triggers absent',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         'unexpected matching triggers=' || count(*)
  from new_triggers expected
  join pg_catalog.pg_trigger trigger
    on trigger.tgrelid = to_regclass(expected.relation_name)
   and trigger.tgname = expected.trigger_name
   and not trigger.tgisinternal

  union all
  select 16, '023 provenance columns absent',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         'unexpected columns=' || count(*)
  from (values
    ('s2t_fhir.review_session','review_target_lifecycle_event_id'),
    ('s2t_fhir.mapping_review_event','review_target_lifecycle_event_id'),
    ('s2t_governance.governance_mapping_link','baseline_version_id'),
    ('s2t_governance.governance_mapping_link','review_target_lifecycle_event_id'),
    ('s2t_governance.governance_mapping_link','lifecycle_status_at_link')
  ) expected(relation_name,column_name)
  join pg_catalog.pg_attribute a
    on a.attrelid = to_regclass(expected.relation_name)
   and a.attname = expected.column_name
   and a.attnum > 0 and not a.attisdropped

  union all
  select 17, 'authorization prerequisites',
         case when count(*) = 6 then 'PASS' else 'FAIL' end,
         'required roles present=' || count(*) || '/6'
  from pg_catalog.pg_roles
  where rolname in ('anon','authenticated','service_role','s2t_fhir_importer',
                    's2t_fhir_api_reader','s2t_fhir_governance_reader')

  union all
  select 18, 'existing Candidate publication rows absent',
         'NOT APPLICABLE',
         'baseline_candidate_context is intentionally absent before migration 023'
),
fingerprints(test_no, test_name, status, detail) as (
  select 101, 'FP current ACTIVE lifecycle state', 'PASS',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from (
    select bv.baseline_code, bv.version_label, bs.source_system, bs.fhir_resource,
           e.occurred_at, status.value_code
    from current_events e
    join s2t_fhir.baseline_version bv using (baseline_version_id)
    join s2t_fhir.baseline_series bs using (baseline_series_id)
    join s2t_fhir.reference_value status
      on status.reference_value_id = e.lifecycle_status_value_id
    where status.value_code = 'ACTIVE'
  ) x

  union all
  select 102, 'FP active_baseline', 'PASS',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.active_baseline x

  union all
  select 103, 'FP _active_release_context', 'PASS',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api._active_release_context x

  union all
  select 104, 'FP active_mapping_record', 'PASS',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.active_mapping_record x

  union all
  select 105, 'FP active quarantine projections', 'PASS',
         md5(coalesce(string_agg(x, '|' order by x), ''))
  from (
    select 'item:' || q::text as x from s2t_fhir_api.active_quarantine_item q
    union all
    select 'summary:' || q::text from s2t_fhir_api.active_quarantine_summary q
  ) data

  union all
  select 106, 'FP governed_mapping_identity', 'PASS',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.governed_mapping_identity x

  union all
  select 107, 'FP active review projections', 'PASS',
         md5(coalesce(string_agg(x, '|' order by x), ''))
  from (
    select 'status:' || r::text as x from s2t_fhir_api.active_mapping_review_status r
    union all
    select 'progress:' || coalesce(
      s2t_fhir_api.get_active_medication_request_cato_review_progress()::text,
      '<null>')
  ) data

  union all
  select 108, 'FP stable governance read views', 'PASS',
         md5(coalesce(string_agg(x, '|' order by x), ''))
  from (
    select 'parties:' || row_value::text as x from s2t_fhir_api.governance_parties row_value
    union all select 'timeline:' || row_value::text from s2t_fhir_api.governance_question_timeline row_value
    union all select 'links:' || row_value::text from s2t_fhir_api.governance_mapping_links row_value
    union all select 'requests:' || row_value::text from s2t_fhir_api.governance_open_requests row_value
    union all
    select 'questions:' || (
      to_jsonb(row_value)
      - 'total_elapsed'
      - 'external_waiting'
      - 'on_hold'
      - 'internal_handling'
      - 'time_to_decision'
    )::text
    from s2t_fhir_api.governance_questions row_value
  ) data

  union all
  select 109, 'FP active CATO MedicationRequest API', 'PASS',
         md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text, '<null>'))

  union all
  select 110, 'FP unchanged ACTIVE API definitions', 'PASS',
         md5(coalesce(string_agg(definition, E'\n' order by object_name), ''))
  from (
    select c.oid::regclass::text as object_name, pg_get_viewdef(c.oid, true) as definition
    from (values
      ('s2t_fhir_api._active_release_context'),
      ('s2t_fhir_api.active_baseline'),
      ('s2t_fhir_api.active_mapping_record'),
      ('s2t_fhir_api.active_mapping_review_status'),
      ('s2t_fhir_api.governed_mapping_identity')
    ) expected(object_name)
    join pg_catalog.pg_class c on c.oid = to_regclass(expected.object_name)
    union all
    select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
    from (values
      ('s2t_fhir_api.get_active_medication_request_cato()'),
      ('s2t_fhir_api.get_active_medication_request_cato_review_progress()'),
      ('s2t_fhir_api.gov_link_mapping(uuid,jsonb,timestamptz)')
    ) expected(signature)
    join pg_catalog.pg_proc p on p.oid = to_regprocedure(expected.signature)
  ) definitions
),
all_results as (
  select * from checks
  union all
  select * from fingerprints
),
summary as (
  select 0 as test_no, 'PREFLIGHT SUMMARY'::text as test_name,
         case when count(*) filter (where test_no < 100 and status = 'FAIL') = 0
              then 'PASS' else 'FAIL' end as status,
         format('%s PASS, %s FAIL, %s NOT APPLICABLE',
           count(*) filter (where test_no < 100 and status = 'PASS'),
           count(*) filter (where test_no < 100 and status = 'FAIL'),
           count(*) filter (where test_no < 100 and status = 'NOT APPLICABLE')) as detail
  from all_results
)
select test_no, test_name, status, detail
from (
  select * from summary
  union all
  select * from all_results
) report
order by test_no;

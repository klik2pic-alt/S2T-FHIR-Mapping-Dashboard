-- 015_governed_row_decision_status.sql
-- Additive contract change for the governed Lovable read API.
--
-- Adds one property to every MappingElement returned by
-- s2t_fhir_api.get_active_medication_request_cato():
--   decisionStatus: 'FINAL' | 'WIP' | 'OPEN' | 'DO NOT MAP' | 'N/A'
-- The value is the original governed _lovable_mapping_node.decision_status,
-- passed through unchanged. It is NOT derived from ui_status.
--
-- Everything else is migration 014 verbatim:
--   * SECURITY DEFINER, search_path = pg_catalog, s2t_fhir_api
--   * _lovable_mapping_node referenced exactly once (local JSONB materialization)
--   * hierarchy built by the unchanged 014 helper _build_lovable_children_from_nodes
--   * same ordering, stable map-v IDs, accepted_count and represented-count reconciliation
--   * same status translation (ui_status), sections, labels, icons
--   * same grants/revokes on the public RPC; helper untouched and still private
-- Fail-closed: returns NULL if any included node has a missing or unknown decision_status,
-- or if any payload lacks id/targetElement/cardinality/profile/status/decisionStatus.
--
-- Not included (already done by 014, must not be repeated):
--   * creation of _build_lovable_children_from_nodes
--   * drop of the migration-013 helper _build_lovable_children

set role s2t_fhir_owner;

create or replace function s2t_fhir_api.get_active_medication_request_cato()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  ctx record;
  context_count bigint;
  nodes jsonb;
  node_count bigint;
  distinct_id_count bigint;
  invalid_count bigint;
  duplicate_path_count bigint;
  section_element jsonb;
  section_status jsonb;
  section_guidance jsonb;
  represented_count bigint;
begin
  select count(*) into context_count
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  if context_count <> 1 then
    return null;
  end if;

  select * into strict ctx
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  -- This is the only reference to _lovable_mapping_node in the RPC.  It
  -- materializes the eligible governed set and its exact external payload once.
  select coalesce(jsonb_agg(jsonb_build_object(
    '_mappingKey', n.mapping_key,
    '_parentMappingKey', n.parent_mapping_key,
    '_sectionId', n.section_id,
    '_sheetOrder', n.sheet_order,
    '_sourceRow', n.source_row,
    '_sourceCellRange', n.source_cell_range,
    '_nodeId', n.node_id,
    '_mappingKind', n.mapping_kind,
    '_comparisonPath', n.comparison_path,
    '_profile', n.ui_profile,
    '_status', n.ui_status,
    -- 015: original governed decision status, captured for fail-closed validation.
    '_decisionStatus', n.decision_status,
    '_targetValid', case
      when n.mapping_kind in ('ELEMENT_MAPPING', 'STATUS_MAPPING_RULE') then n.target_fhir_path is not null
      when n.mapping_kind = 'GOVERNANCE_GUIDANCE' then
        nullif(btrim(coalesce(n.target_fhir_path_or_scope_raw, n.guidance_scope)), '') is not null
      else false
    end,
    '_payload', jsonb_strip_nulls(jsonb_build_object(
      'id', n.node_id,
      'targetElement', case
        when n.mapping_kind in ('ELEMENT_MAPPING', 'STATUS_MAPPING_RULE') then n.target_fhir_path
        else coalesce(nullif(btrim(n.target_fhir_path_or_scope_raw), ''), n.guidance_scope)
      end,
      'cardinality', case when n.mapping_kind = 'ELEMENT_MAPPING' then coalesce(n.cardinality_raw, '') else '' end,
      'profile', n.ui_profile,
      'sourceSystem', coalesce(nullif(btrim(n.source_system_raw), ''), n.source_system),
      'sourceField', case
        when n.mapping_kind = 'ELEMENT_MAPPING' then n.source_expression
        when n.mapping_kind = 'STATUS_MAPPING_RULE' then n.source_status_value
        else coalesce(nullif(btrim(n.decision_topic_raw), ''), n.decision_topic)
      end,
      'fixedValue', case
        when n.mapping_kind = 'ELEMENT_MAPPING' then n.fixed_value
        when n.mapping_kind = 'STATUS_MAPPING_RULE' then n.target_status_value
      end,
      'transformation', case
        when n.mapping_kind = 'ELEMENT_MAPPING' then n.transformation_rule
        when n.mapping_kind = 'STATUS_MAPPING_RULE' then n.status_transformation_rule
        else n.guidance_text
      end,
      'description', case
        when n.mapping_kind = 'ELEMENT_MAPPING' then n.source_business_definition
        when n.mapping_kind = 'STATUS_MAPPING_RULE' then n.status_source_business_definition
        else n.guidance_text
      end,
      'bindingValueSet', case when n.mapping_kind = 'ELEMENT_MAPPING' then n.valueset_binding end,
      'notes', case
        when n.mapping_kind = 'ELEMENT_MAPPING' then n.notes
        when n.mapping_kind = 'STATUS_MAPPING_RULE' then n.status_notes
        else n.guidance_notes
      end,
      'status', n.ui_status,
      -- 015: additive contract field; original governed value, not derived from ui_status.
      'decisionStatus', n.decision_status
    ))
  ) order by n.sheet_order, n.source_row, n.source_cell_range, n.node_id), '[]'::jsonb)
  into nodes
  from s2t_fhir_api._lovable_mapping_node n
  where n.baseline_code = ctx.baseline_code;

  select
    count(*),
    count(distinct item.value ->> '_nodeId'),
    count(*) filter (where
      item.value ->> '_sectionId' is null
      or item.value ->> '_nodeId' is null
      or (item.value ->> '_nodeId') !~ '^map-v[0-9]+-[0-9a-f]{64}$'
      or item.value ->> '_profile' is null
      or item.value ->> '_profile' not in ('IL CORE', 'HDP', 'LOCAL')
      or item.value ->> '_status' is null
      or item.value ->> '_status' not in ('mapped', 'fixed', 'pending', 'unmapped', 'structural')
      or coalesce((item.value ->> '_targetValid')::boolean, false) is not true
      -- 015: fail closed on missing or unknown governed decision status.
      or item.value ->> '_decisionStatus' is null
      or item.value ->> '_decisionStatus' not in ('FINAL', 'WIP', 'OPEN', 'DO NOT MAP', 'N/A')
      -- 015: every external payload must carry the required contract keys.
      or not ((item.value -> '_payload') ?& array['id', 'targetElement', 'cardinality', 'profile', 'status', 'decisionStatus'])
      or (item.value #>> '{_payload,decisionStatus}') is distinct from (item.value ->> '_decisionStatus')
    )
  into node_count, distinct_id_count, invalid_count
  from jsonb_array_elements(nodes) item(value);

  select count(*) into duplicate_path_count
  from (
    select item.value ->> '_comparisonPath'
    from jsonb_array_elements(nodes) item(value)
    where item.value ->> '_mappingKind' = 'ELEMENT_MAPPING'
    group by item.value ->> '_comparisonPath'
    having count(*) > 1
  ) duplicates;

  if node_count <> ctx.accepted_count
     or node_count <> distinct_id_count
     or invalid_count <> 0
     or duplicate_path_count <> 0 then
    return null;
  end if;

  section_element := s2t_fhir_api._build_lovable_children_from_nodes(
    nodes, 'medication-request-cato--element-mapping', null
  );
  section_status := s2t_fhir_api._build_lovable_children_from_nodes(
    nodes, 'medication-request-cato--status-mapping-rule', null
  );
  section_guidance := s2t_fhir_api._build_lovable_children_from_nodes(
    nodes, 'medication-request-cato--governance-guidance', null
  );

  with recursive represented(node) as (
    select value
    from jsonb_array_elements(section_element || section_status || section_guidance)
    union all
    select child.value
    from represented parent
    cross join lateral jsonb_array_elements(coalesce(parent.node -> 'children', '[]'::jsonb)) child
  )
  select count(*) into represented_count from represented;

  if represented_count <> node_count then
    return null;
  end if;

  return jsonb_build_object(
    'id', 'medication-request-cato',
    'label', 'CATO MedicationRequest',
    'description', 'Governed ACTIVE CATO to FHIR MedicationRequest mapping',
    'icon', 'pill',
    'sections', jsonb_build_array(
      jsonb_build_object(
        'id', 'medication-request-cato--element-mapping',
        'label', 'Element mappings',
        'icon', 'list-tree',
        'description', 'Governed element mappings',
        'elements', section_element
      ),
      jsonb_build_object(
        'id', 'medication-request-cato--status-mapping-rule',
        'label', 'Status mapping rules',
        'icon', 'workflow',
        'description', 'Governed status translation rules',
        'elements', section_status
      ),
      jsonb_build_object(
        'id', 'medication-request-cato--governance-guidance',
        'label', 'Governance guidance',
        'icon', 'book-open',
        'description', 'Governed mapping guidance and decisions',
        'elements', section_guidance
      )
    ),
    'crossReferences', '[]'::jsonb
  );
end
$function$;

-- Reassert the existing public boundary without broadening it.
revoke all on function s2t_fhir_api.get_active_medication_request_cato() from public;
grant execute on function s2t_fhir_api.get_active_medication_request_cato() to s2t_fhir_api_reader;

do $block$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function s2t_fhir_api.get_active_medication_request_cato() to anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function s2t_fhir_api.get_active_medication_request_cato() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke all on function s2t_fhir_api.get_active_medication_request_cato() from service_role';
  end if;
end
$block$;

reset role;

-- Runtime verification queries (review/run separately; not executed by this migration).
-- Shared recursive node expansion used by queries 2-8:
--   with recursive doc as (select s2t_fhir_api.get_active_medication_request_cato() as j),
--   nodes(node) as (
--     select e.node from doc
--     cross join lateral jsonb_array_elements(j -> 'sections') s(section)
--     cross join lateral jsonb_array_elements(s.section -> 'elements') e(node)
--     union all
--     select c.node from nodes n
--     cross join lateral jsonb_array_elements(coalesce(n.node -> 'children', '[]'::jsonb)) c(node)
--   )

-- 1. Resource id; expected: medication-request-cato.
-- select s2t_fhir_api.get_active_medication_request_cato() ->> 'id';

-- 2-7. Reconciliation and contract; expected represented=292, distinct_ids=292,
-- ids_valid=true, all_have_decision_status=true, decision_status_valid=true, status_valid=true.
-- with recursive doc as (
--   select s2t_fhir_api.get_active_medication_request_cato() as j
-- ), nodes(node) as (
--   select e.node
--   from doc
--   cross join lateral jsonb_array_elements(j -> 'sections') s(section)
--   cross join lateral jsonb_array_elements(s.section -> 'elements') e(node)
--   union all
--   select c.node
--   from nodes n
--   cross join lateral jsonb_array_elements(coalesce(n.node -> 'children', '[]'::jsonb)) c(node)
-- )
-- select count(*) as represented,
--        count(distinct node ->> 'id') as distinct_ids,
--        bool_and((node ->> 'id') ~ '^map-v[0-9]+-[0-9a-f]{64}$') as ids_valid,
--        bool_and(node ? 'decisionStatus') as all_have_decision_status,
--        bool_and((node ->> 'decisionStatus') in ('FINAL','WIP','OPEN','DO NOT MAP','N/A')) as decision_status_valid,
--        bool_and(node ?& array['id','targetElement','cardinality','profile','status']
--                 and (node ->> 'profile') in ('IL CORE','HDP','LOCAL')
--                 and (node ->> 'status') in ('mapped','fixed','pending','unmapped','structural')) as status_valid
-- from nodes;

-- 8. decisionStatus distribution, cross-tabbed with the unchanged UI status.
-- Inferred expectation for BL-001 (from 013 translation rules + live status counts):
--   DO NOT MAP/unmapped=168, FINAL/fixed=23, FINAL/mapped=99, OPEN+WIP/pending=2, N/A=0.
-- with recursive doc as (
--   select s2t_fhir_api.get_active_medication_request_cato() as j
-- ), nodes(node) as (
--   select e.node from doc
--   cross join lateral jsonb_array_elements(j -> 'sections') s(section)
--   cross join lateral jsonb_array_elements(s.section -> 'elements') e(node)
--   union all
--   select c.node from nodes n
--   cross join lateral jsonb_array_elements(coalesce(n.node -> 'children', '[]'::jsonb)) c(node)
-- )
-- select node ->> 'decisionStatus' as decision_status,
--        node ->> 'status' as ui_status,
--        count(*)
-- from nodes
-- group by 1, 2
-- order by 1, 2;
-- Cross-check against the governed relation (run as owner; expected identical counts):
-- select n.decision_status, n.ui_status, count(*)
-- from s2t_fhir_api._lovable_mapping_node n
-- join s2t_fhir_api._active_release_context c
--   on c.baseline_code = n.baseline_code
--  and c.source_system = 'CATO' and c.fhir_resource = 'MedicationRequest'
-- group by 1, 2 order by 1, 2;

-- 9. Quarantined workbook row 77 remains excluded; expected: 0.
-- select count(*)
-- from s2t_fhir_api.active_mapping_record
-- where source_sheet = 'S2T MedicationRequestCato'
--   and source_row = 77
--   and source_cell_range = 'A77:Q77';

-- 10. No public/internal UUID or raw-evidence leakage; expected: no rows, then false.
-- select table_name, column_name
-- from information_schema.columns
-- where table_schema = 's2t_fhir_api'
--   and table_name in ('active_baseline', 'active_mapping_record',
--                      'active_quarantine_item', 'active_quarantine_summary')
--   and (column_name like '%\_id' escape '\'
--        or column_name in ('raw_source_row', 'evidence_json', 'detail_json',
--                           'actor_principal_id', 'initiating_human_principal_id'));
-- select s2t_fhir_api.get_active_medication_request_cato()::text
--        ~* '(baseline_version_id|artifact_id|import_run_id|validation_run_id|release_gate_evaluation_id|raw_source_row|evidence_json|detail_json|principal|_decisionStatus|_mappingKey|_nodeId|[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})'
--        as has_internal_or_uuid_leak; -- Expected: false.

-- 11. Determinism in one snapshot; expected: true.
-- begin transaction isolation level repeatable read;
-- select s2t_fhir_api.get_active_medication_request_cato()
--      = s2t_fhir_api.get_active_medication_request_cato() as identical_json;
-- rollback;

-- 12. Privileges unchanged: anon/authenticated/reader=true, service_role=false,
-- PUBLIC=false; helper_execute=false for every listed role.
-- select r.rolname,
--        has_function_privilege(r.rolname, 's2t_fhir_api.get_active_medication_request_cato()', 'EXECUTE') as rpc_execute,
--        has_function_privilege(r.rolname, 's2t_fhir_api._build_lovable_children_from_nodes(jsonb,text,text)', 'EXECUTE') as helper_execute
-- from pg_roles r
-- where r.rolname in ('anon','authenticated','service_role','s2t_fhir_api_reader')
-- order by r.rolname;
-- select not exists (
--   select 1
--   from information_schema.routine_privileges
--   where routine_schema = 's2t_fhir_api'
--     and routine_name = 'get_active_medication_request_cato'
--     and grantee = 'PUBLIC'
--     and privilege_type = 'EXECUTE'
-- ) as public_blocked;
-- select p.prosecdef as security_definer, p.proconfig
-- from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
-- where ns.nspname = 's2t_fhir_api' and p.proname = 'get_active_medication_request_cato';
-- Expected: security_definer=true, proconfig={search_path=pg_catalog, s2t_fhir_api}.

-- 13. Performance; must stay well below the anon 3-second timeout, preferred < 1 second
-- (014 baseline ~363 ms). Expected single scan of _lovable_mapping_node.
-- EXPLAIN (ANALYZE, BUFFERS)
-- select s2t_fhir_api.get_active_medication_request_cato();

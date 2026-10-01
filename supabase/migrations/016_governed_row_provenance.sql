-- 016_governed_row_provenance.sql
-- Additive contract change for the governed Lovable read API.
--
-- Adds one read-only provenance object to every MappingElement returned by
-- s2t_fhir_api.get_active_medication_request_cato(). Values come only from the
-- already-loaded _lovable_mapping_node row; there are no additional joins or reads.
--
-- Everything else is migration 015 verbatim:
--   * SECURITY DEFINER, search_path = pg_catalog, s2t_fhir_api
--   * _lovable_mapping_node referenced exactly once (local JSONB materialization)
--   * hierarchy built by the unchanged 014 helper _build_lovable_children_from_nodes
--   * same ordering, stable map-v IDs, accepted_count and represented-count reconciliation
--   * same status translation (ui_status), sections, labels, icons
--   * same grants/revokes on the public RPC; helper untouched and still private
-- Fail-closed: returns NULL if any included node fails the existing checks, lacks
-- an existing required contract key, or has missing/invalid provenance.
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
      'decisionStatus', n.decision_status,
      -- 016: read-only row provenance from this already-loaded governed node.
      'provenance', jsonb_build_object(
        'baselineCode', n.baseline_code,
        'versionLabel', n.version_label,
        'artifactFilename', n.workbook_filename,
        'artifactSha256', n.workbook_sha256,
        'sourceSheet', n.source_sheet,
        'sourceRow', n.source_row,
        'sourceCellRange', n.source_cell_range
      )
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
      -- 016: every included node must carry complete, valid row provenance.
      or jsonb_typeof(item.value #> '{_payload,provenance}') is distinct from 'object'
      or nullif(btrim(item.value #>> '{_payload,provenance,baselineCode}'), '') is null
      or nullif(btrim(item.value #>> '{_payload,provenance,versionLabel}'), '') is null
      or nullif(btrim(item.value #>> '{_payload,provenance,artifactFilename}'), '') is null
      or coalesce(item.value #>> '{_payload,provenance,artifactSha256}', '') !~ '^[0-9a-fA-F]{64}$'
      or nullif(btrim(item.value #>> '{_payload,provenance,sourceSheet}'), '') is null
      or case
           when jsonb_typeof(item.value #> '{_payload,provenance,sourceRow}') = 'number'
             and (item.value #>> '{_payload,provenance,sourceRow}') ~ '^[0-9]+$'
           then (item.value #>> '{_payload,provenance,sourceRow}')::numeric <= 0
           else true
         end
      or nullif(btrim(item.value #>> '{_payload,provenance,sourceCellRange}'), '') is null
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

-- A. Resource identity; expected: medication-request-cato.
-- select s2t_fhir_api.get_active_medication_request_cato() ->> 'id';

-- B-E. Recursive reconciliation, existing contract, provenance presence and validity.
-- Expected: represented=292, distinct_ids=292, existing_contract_valid=true,
-- all_have_provenance=true, provenance_valid=true.
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
--        bool_and(node ?& array['id','targetElement','cardinality','profile','status','decisionStatus'])
--          as existing_contract_valid,
--        bool_and(node ? 'provenance' and jsonb_typeof(node -> 'provenance') = 'object')
--          as all_have_provenance,
--        bool_and(
--          nullif(btrim(node #>> '{provenance,baselineCode}'), '') is not null
--          and nullif(btrim(node #>> '{provenance,versionLabel}'), '') is not null
--          and nullif(btrim(node #>> '{provenance,artifactFilename}'), '') is not null
--          and (node #>> '{provenance,artifactSha256}') ~ '^[0-9a-fA-F]{64}$'
--          and nullif(btrim(node #>> '{provenance,sourceSheet}'), '') is not null
--          and jsonb_typeof(node #> '{provenance,sourceRow}') = 'number'
--          and (node #>> '{provenance,sourceRow}') ~ '^[0-9]+$'
--          and (node #>> '{provenance,sourceRow}')::numeric > 0
--          and nullif(btrim(node #>> '{provenance,sourceCellRange}'), '') is not null
--        ) as provenance_valid
-- from nodes;

-- F. BL-001 consistency. Expected: all_baseline_bl001=true,
-- artifact_filename_variants=1, artifact_sha_variants=1.
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
-- select bool_and(node #>> '{provenance,baselineCode}' = 'BL-001') as all_baseline_bl001,
--        count(distinct node #>> '{provenance,artifactFilename}') as artifact_filename_variants,
--        count(distinct node #>> '{provenance,artifactSha256}') as artifact_sha_variants,
--        min(node #>> '{provenance,artifactFilename}') as expected_artifact_filename,
--        min(node #>> '{provenance,artifactSha256}') as expected_artifact_sha
-- from nodes;

-- G. Owner-side exact cross-check against active_mapping_record using the stable
-- map-v<version>-<digest> construction. Expected: rpc_nodes=292, matched_rows=292,
-- mismatched_rows=0, unmatched_rpc_nodes=0.
-- with recursive doc as (
--   select s2t_fhir_api.get_active_medication_request_cato() as j
-- ), nodes(node) as (
--   select e.node from doc
--   cross join lateral jsonb_array_elements(j -> 'sections') s(section)
--   cross join lateral jsonb_array_elements(s.section -> 'elements') e(node)
--   union all
--   select c.node from nodes n
--   cross join lateral jsonb_array_elements(coalesce(n.node -> 'children', '[]'::jsonb)) c(node)
-- ), governed as (
--   select 'map-v' || substring(m.mapping_key from 'v([0-9]+):[0-9a-f]{64}$')
--          || '-' || substring(m.mapping_key from '([0-9a-f]{64})$') as node_id,
--          m.baseline_code, m.version_label, m.workbook_filename, m.workbook_sha256,
--          m.source_sheet, m.source_row, m.source_cell_range
--   from s2t_fhir_api.active_mapping_record m
--   where m.baseline_code = 'BL-001'
-- )
-- select count(*) as rpc_nodes,
--        count(g.node_id) as matched_rows,
--        count(*) filter (where g.node_id is not null and not (
--          n.node #>> '{provenance,baselineCode}' = g.baseline_code
--          and n.node #>> '{provenance,versionLabel}' = g.version_label
--          and n.node #>> '{provenance,artifactFilename}' = g.workbook_filename
--          and n.node #>> '{provenance,artifactSha256}' = g.workbook_sha256
--          and n.node #>> '{provenance,sourceSheet}' = g.source_sheet
--          and (n.node #>> '{provenance,sourceRow}')::bigint = g.source_row
--          and n.node #>> '{provenance,sourceCellRange}' = g.source_cell_range
--        )) as mismatched_rows,
--        count(*) filter (where g.node_id is null) as unmatched_rpc_nodes
-- from nodes n left join governed g on g.node_id = n.node ->> 'id';

-- H. Quarantine exclusion from the RPC; expected: 0.
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
-- select count(*)
-- from nodes
-- where node #>> '{provenance,sourceSheet}' = 'S2T MedicationRequestCato'
--   and node #>> '{provenance,sourceRow}' = '77'
--   and node #>> '{provenance,sourceCellRange}' = 'A77:Q77';

-- I. No internal UUID or raw-evidence leakage. artifactSha256 is intentionally
-- allowed and is not an internal UUID. Expected: false.
-- select s2t_fhir_api.get_active_medication_request_cato()::text ~*
--   '(baseline_version_id|artifact_id|import_run_id|validation_run_id|release_gate_evaluation_id|logical_mapping_identity_id|raw_source_row|evidence_json|detail_json|logical_key_components_json|manifest_json|principal|_mappingKey|_parentMappingKey|comparison_path|sheet_order|[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})'
--   as has_internal_or_uuid_leak;

-- J. Determinism in one repeatable-read snapshot; expected: true.
-- begin transaction isolation level repeatable read;
-- select s2t_fhir_api.get_active_medication_request_cato()
--      = s2t_fhir_api.get_active_medication_request_cato() as identical_json;
-- rollback;

-- K. Privileges unchanged: anon/authenticated/reader=true, service_role=false,
-- PUBLIC=false; helper_execute=false for every listed role.
-- select r.rolname,
--        has_function_privilege(r.rolname, 's2t_fhir_api.get_active_medication_request_cato()', 'EXECUTE') as rpc_execute,
--        has_function_privilege(r.rolname, 's2t_fhir_api._build_lovable_children_from_nodes(jsonb,text,text)', 'EXECUTE') as helper_execute
-- from pg_roles r
-- where r.rolname in ('anon','authenticated','service_role','s2t_fhir_api_reader')
-- order by r.rolname;
-- select not exists (
--   select 1 from information_schema.routine_privileges
--   where routine_schema = 's2t_fhir_api'
--     and routine_name = 'get_active_medication_request_cato'
--     and grantee = 'PUBLIC'
--     and privilege_type = 'EXECUTE'
-- ) as public_blocked;

-- L. SECURITY DEFINER/search_path; expected:
-- security_definer=true, search_path={pg_catalog,s2t_fhir_api}.
-- select p.prosecdef as security_definer, p.proconfig
-- from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
-- where ns.nspname = 's2t_fhir_api'
--   and p.proname = 'get_active_medication_request_cato';

-- M. Performance; must remain below 3 seconds, preferred below 1 second.
-- Compare with migration 015 runtime baseline ~357 ms and confirm the plan shows
-- one scan/materialization of _lovable_mapping_node.
-- EXPLAIN (ANALYZE, BUFFERS)
-- select s2t_fhir_api.get_active_medication_request_cato();

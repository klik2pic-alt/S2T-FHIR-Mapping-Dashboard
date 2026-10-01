-- Governed read/API boundary for the currently ACTIVE, release-passed baseline.
-- This migration intentionally grants no access to s2t_fhir base objects.

set role s2t_fhir_owner;

revoke all on schema s2t_fhir_api from public;
revoke all on schema s2t_fhir from public;
revoke all on all tables in schema s2t_fhir from public;
revoke all on all functions in schema s2t_fhir from public;

do $block$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema s2t_fhir from anon';
    execute 'revoke all on all tables in schema s2t_fhir from anon';
    execute 'revoke all on all functions in schema s2t_fhir from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on schema s2t_fhir from authenticated';
    execute 'revoke all on all tables in schema s2t_fhir from authenticated';
    execute 'revoke all on all functions in schema s2t_fhir from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke all on schema s2t_fhir from service_role';
    execute 'revoke all on all tables in schema s2t_fhir from service_role';
    execute 'revoke all on all functions in schema s2t_fhir from service_role';
    execute 'revoke all on schema s2t_fhir_api from service_role';
  end if;
end
$block$;

-- Private context. Internal identifiers are required for joins but are never granted.
-- Exactly one eligible current PASSED gate per baseline is required; ambiguity fails closed.
create view s2t_fhir_api._active_release_context
with (security_barrier = true)
as
with eligible as (
  select
    bv.baseline_version_id,
    bv.baseline_code,
    bv.version_label,
    bs.source_system,
    bs.fhir_resource,
    lc.value_code as lifecycle_status,
    cle.occurred_at as lifecycle_effective_at,
    a.artifact_id,
    a.physical_filename as artifact_filename,
    a.original_or_upload_name as artifact_original_name,
    a.sha256_digest,
    a.captured_at as artifact_captured_at,
    ir.import_run_id,
    ir.completed_at as import_completed_at,
    vr.validation_run_id,
    vr.candidate_count,
    vr.accepted_count,
    vr.warning_count,
    vr.error_count,
    vr.quarantined_count,
    vo.value_code as validation_outcome,
    rge.release_gate_evaluation_id,
    rgd.gate_code as release_gate_code,
    rgd.version_label as release_gate_version,
    go.value_code as release_gate_outcome,
    rge.evaluated_at as release_gate_evaluated_at,
    count(*) over (partition by bv.baseline_version_id) as eligible_gate_count
  from s2t_fhir.baseline_version bv
  join s2t_fhir.baseline_series bs
    on bs.baseline_series_id = bv.baseline_series_id
  join s2t_fhir.current_baseline_lifecycle_event cle
    on cle.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value lc
    on lc.reference_value_id = cle.lifecycle_status_value_id
  join s2t_fhir.reference_domain lcd
    on lcd.reference_domain_id = lc.reference_domain_id
   and lcd.domain_code = 'BASELINE_LIFECYCLE_STATUS'
   and lc.value_code = 'ACTIVE'
  join s2t_fhir.baseline_artifact ba
    on ba.baseline_version_id = bv.baseline_version_id
  join s2t_fhir.reference_value ar
    on ar.reference_value_id = ba.artifact_role_value_id
  join s2t_fhir.reference_domain ard
    on ard.reference_domain_id = ar.reference_domain_id
   and ard.domain_code = 'ARTIFACT_ROLE'
   and ar.value_code = 'AUTHORITATIVE_SOURCE'
  join s2t_fhir.artifact a
    on a.artifact_id = ba.artifact_id
  join s2t_fhir.current_release_gate_evaluation rge
    on rge.baseline_version_id = bv.baseline_version_id
   and rge.artifact_id = a.artifact_id
   and rge.artifact_digest = a.sha256_digest
  join s2t_fhir.reference_value go
    on go.reference_value_id = rge.gate_outcome_value_id
  join s2t_fhir.reference_domain god
    on god.reference_domain_id = go.reference_domain_id
   and god.domain_code = 'RELEASE_GATE_OUTCOME'
   and go.value_code = 'PASSED'
  join s2t_fhir.release_gate_definition rgd
    on rgd.release_gate_definition_id = rge.release_gate_definition_id
  join s2t_fhir.validation_run vr
    on vr.validation_run_id = rge.validation_run_id
   and vr.validation_ruleset_id = rge.validation_ruleset_id
   and vr.artifact_id = a.artifact_id
   and vr.artifact_digest = a.sha256_digest
  join s2t_fhir.reference_value vo
    on vo.reference_value_id = vr.outcome_value_id
  join s2t_fhir.reference_domain vod
    on vod.reference_domain_id = vo.reference_domain_id
   and vod.domain_code = 'VALIDATION_OUTCOME'
  join s2t_fhir.import_run ir
    on ir.import_run_id = vr.import_run_id
   and ir.baseline_version_id = bv.baseline_version_id
   and ir.artifact_id = a.artifact_id
  join s2t_fhir.reference_value its
    on its.reference_value_id = ir.terminal_status_value_id
  join s2t_fhir.reference_domain itsd
    on itsd.reference_domain_id = its.reference_domain_id
   and itsd.domain_code = 'IMPORT_RUN_STATUS'
   and its.value_code = 'COMMITTED'
)
select *
from eligible
where eligible_gate_count = 1;

revoke all on s2t_fhir_api._active_release_context from public;

create view s2t_fhir_api.active_baseline
with (security_barrier = true)
as
select
  baseline_code,
  version_label,
  source_system,
  fhir_resource,
  lifecycle_status,
  lifecycle_effective_at,
  artifact_filename,
  artifact_original_name,
  encode(sha256_digest, 'hex') as artifact_sha256,
  artifact_captured_at,
  import_completed_at,
  candidate_count,
  accepted_count,
  warning_count,
  error_count,
  quarantined_count,
  validation_outcome,
  release_gate_code,
  release_gate_version,
  release_gate_outcome,
  release_gate_evaluated_at
from s2t_fhir_api._active_release_context;

create view s2t_fhir_api.active_mapping_record
with (security_barrier = true)
as
select
  lmi.logical_key as mapping_key,
  mk.value_code as mapping_kind,
  ds.value_code as decision_status,
  ctx.baseline_code,
  ctx.version_label,
  ctx.artifact_filename as workbook_filename,
  encode(ctx.sha256_digest, 'hex') as workbook_sha256,
  icr.source_sheet_name as source_sheet,
  icr.source_row_number as source_row,
  icr.source_cell_range,
  lmi.source_system,
  lmi.fhir_resource,
  em.source_system_raw,
  em.interface_type,
  em.interface_name,
  em.source_expression,
  coalesce(em.target_fhir_path, smr.target_fhir_path) as target_fhir_path,
  em.profile_context,
  em.fixed_value,
  em.transformation_rule,
  em.source_business_definition,
  em.cardinality_raw,
  em.cardinality_min,
  em.cardinality_max,
  em.cardinality_max_unbounded,
  em.valueset_binding,
  em.mandated_code_system,
  em.irrelevant_under_s2t_raw,
  em.example_value,
  em.exception_handling,
  em.notes,
  smr.source_status_value,
  smr.target_status_value,
  smr.source_sequence,
  smr.source_business_definition as status_source_business_definition,
  smr.related_resource_note,
  smr.transformation_rule as status_transformation_rule,
  smr.mapping_evidence_status_raw,
  smr.notes as status_notes,
  gs.value_code as guidance_scope,
  gs.display_name as guidance_scope_display,
  dt.value_code as decision_topic,
  dt.display_name as decision_topic_display,
  gg.guidance_text,
  gg.guidance_status_raw,
  gg.target_fhir_path_or_scope_raw,
  gg.decision_topic_raw,
  gg.notes as guidance_notes,
  gg.review_notes
from s2t_fhir_api._active_release_context ctx
join s2t_fhir.mapping_record mr
  on mr.baseline_version_id = ctx.baseline_version_id
join s2t_fhir.import_candidate_row icr
  on icr.import_candidate_row_id = mr.import_candidate_row_id
 and icr.import_run_id = ctx.import_run_id
join s2t_fhir.reference_value cd
  on cd.reference_value_id = icr.candidate_disposition_value_id
join s2t_fhir.reference_domain cdd
  on cdd.reference_domain_id = cd.reference_domain_id
 and cdd.domain_code = 'CANDIDATE_DISPOSITION'
 and cd.value_code = 'ACCEPTED'
join s2t_fhir.logical_mapping_identity lmi
  on lmi.logical_mapping_identity_id = mr.logical_mapping_identity_id
 and lmi.source_system = ctx.source_system
 and lmi.fhir_resource = ctx.fhir_resource
join s2t_fhir.reference_value mk
  on mk.reference_value_id = mr.mapping_kind_value_id
join s2t_fhir.reference_domain mkd
  on mkd.reference_domain_id = mk.reference_domain_id
 and mkd.domain_code = 'MAPPING_KIND'
join s2t_fhir.reference_value ds
  on ds.reference_value_id = mr.decision_status_value_id
join s2t_fhir.reference_domain dsd
  on dsd.reference_domain_id = ds.reference_domain_id
 and dsd.domain_code = 'DECISION_STATUS'
left join s2t_fhir.element_mapping em
  on em.mapping_record_id = mr.mapping_record_id
left join s2t_fhir.status_mapping_rule smr
  on smr.mapping_record_id = mr.mapping_record_id
left join s2t_fhir.governance_guidance gg
  on gg.mapping_record_id = mr.mapping_record_id
left join s2t_fhir.reference_value gs
  on gs.reference_value_id = gg.guidance_scope_value_id
left join s2t_fhir.reference_domain gsd
  on gsd.reference_domain_id = gs.reference_domain_id
 and gsd.domain_code = 'GUIDANCE_SCOPE'
left join s2t_fhir.reference_value dt
  on dt.reference_value_id = gg.decision_topic_value_id
left join s2t_fhir.reference_domain dtd
  on dtd.reference_domain_id = dt.reference_domain_id
 and dtd.domain_code = 'DECISION_TOPIC_CODE'
where mr.mapping_kind_value_id = icr.mapping_kind_value_id
  and mr.mapping_kind_value_id = lmi.mapping_kind_value_id
  and (
    (mk.value_code = 'ELEMENT_MAPPING' and em.mapping_record_id is not null and smr.mapping_record_id is null and gg.mapping_record_id is null)
    or
    (mk.value_code = 'STATUS_MAPPING_RULE' and em.mapping_record_id is null and smr.mapping_record_id is not null and gg.mapping_record_id is null)
    or
    (mk.value_code = 'GOVERNANCE_GUIDANCE'
     and em.mapping_record_id is null
     and smr.mapping_record_id is null
     and gg.mapping_record_id is not null
     and gsd.domain_code = 'GUIDANCE_SCOPE'
     and dtd.domain_code = 'DECISION_TOPIC_CODE')
  );

create view s2t_fhir_api.active_quarantine_item
with (security_barrier = true)
as
select
  ctx.baseline_code,
  ctx.version_label,
  ctx.artifact_filename as workbook_filename,
  encode(ctx.sha256_digest, 'hex') as workbook_sha256,
  mk.value_code as mapping_kind,
  icr.source_sheet_name as source_sheet,
  icr.source_row_number as source_row,
  icr.source_cell_range,
  vf.finding_code,
  sev.value_code as severity,
  vf.message,
  frr.value_code as finding_row_role,
  qc.opened_at as quarantine_opened_at,
  qet.value_code as quarantine_status,
  qrv.value_code as resolution_code,
  current_qe.reason as resolution_reason
from s2t_fhir_api._active_release_context ctx
join s2t_fhir.import_candidate_row icr
  on icr.import_run_id = ctx.import_run_id
join s2t_fhir.reference_value cd
  on cd.reference_value_id = icr.candidate_disposition_value_id
join s2t_fhir.reference_domain cdd
  on cdd.reference_domain_id = cd.reference_domain_id
 and cdd.domain_code = 'CANDIDATE_DISPOSITION'
 and cd.value_code = 'QUARANTINED'
join s2t_fhir.reference_value mk
  on mk.reference_value_id = icr.mapping_kind_value_id
join s2t_fhir.reference_domain mkd
  on mkd.reference_domain_id = mk.reference_domain_id
 and mkd.domain_code = 'MAPPING_KIND'
join s2t_fhir.quarantine_case qc
  on qc.import_candidate_row_id = icr.import_candidate_row_id
join s2t_fhir.validation_finding_row vfr
  on vfr.import_candidate_row_id = icr.import_candidate_row_id
join s2t_fhir.validation_finding vf
  on vf.validation_finding_id = vfr.validation_finding_id
 and vf.validation_run_id = ctx.validation_run_id
join s2t_fhir.reference_value sev
  on sev.reference_value_id = vf.severity_value_id
join s2t_fhir.reference_domain sevd
  on sevd.reference_domain_id = sev.reference_domain_id
 and sevd.domain_code = 'SEVERITY'
join s2t_fhir.reference_value frr
  on frr.reference_value_id = vfr.finding_row_role_value_id
join s2t_fhir.reference_domain frrd
  on frrd.reference_domain_id = frr.reference_domain_id
 and frrd.domain_code = 'FINDING_ROW_ROLE'
left join lateral (
  select qe.*
  from s2t_fhir.quarantine_event qe
  where qe.quarantine_case_id = qc.quarantine_case_id
    and not exists (
      select 1
      from s2t_fhir.quarantine_event superseding
      where superseding.supersedes_event_id = qe.quarantine_event_id
    )
  order by qe.occurred_at desc, qe.recorded_at desc, qe.quarantine_event_id desc
  limit 1
) current_qe on true
left join s2t_fhir.reference_value qet
  on qet.reference_value_id = current_qe.event_type_value_id
left join s2t_fhir.reference_domain qetd
  on qetd.reference_domain_id = qet.reference_domain_id
 and qetd.domain_code = 'QUARANTINE_EVENT_TYPE'
left join s2t_fhir.reference_value qrv
  on qrv.reference_value_id = current_qe.resolution_code_value_id
left join s2t_fhir.reference_domain qrvd
  on qrvd.reference_domain_id = qrv.reference_domain_id
 and qrvd.domain_code = 'QUARANTINE_RESOLUTION';

create view s2t_fhir_api.active_quarantine_summary
with (security_barrier = true)
as
select
  ctx.baseline_code,
  ctx.version_label,
  ctx.candidate_count,
  ctx.accepted_count,
  ctx.quarantined_count,
  ctx.warning_count,
  ctx.error_count,
  ctx.validation_outcome,
  coalesce(q.open_quarantine_count, 0::bigint) as open_quarantine_count,
  coalesce(q.resolved_quarantine_count, 0::bigint) as resolved_quarantine_count,
  coalesce(f.quarantine_finding_count, 0::bigint) as quarantine_finding_count
from s2t_fhir_api._active_release_context ctx
left join lateral (
  select
    count(*) filter (where current_event.resolution_code_value_id is null and coalesce(event_type.value_code, 'OPENED') <> 'CLOSED') as open_quarantine_count,
    count(*) filter (where current_event.resolution_code_value_id is not null or event_type.value_code = 'CLOSED') as resolved_quarantine_count
  from s2t_fhir.import_candidate_row candidate
  join s2t_fhir.reference_value disposition
    on disposition.reference_value_id = candidate.candidate_disposition_value_id
  join s2t_fhir.reference_domain disposition_domain
    on disposition_domain.reference_domain_id = disposition.reference_domain_id
   and disposition_domain.domain_code = 'CANDIDATE_DISPOSITION'
   and disposition.value_code = 'QUARANTINED'
  join s2t_fhir.quarantine_case qc
    on qc.import_candidate_row_id = candidate.import_candidate_row_id
  left join lateral (
    select qe.*
    from s2t_fhir.quarantine_event qe
    where qe.quarantine_case_id = qc.quarantine_case_id
      and not exists (
        select 1 from s2t_fhir.quarantine_event superseding
        where superseding.supersedes_event_id = qe.quarantine_event_id
      )
    order by qe.occurred_at desc, qe.recorded_at desc, qe.quarantine_event_id desc
    limit 1
  ) current_event on true
  left join s2t_fhir.reference_value event_type
    on event_type.reference_value_id = current_event.event_type_value_id
  left join s2t_fhir.reference_domain event_type_domain
    on event_type_domain.reference_domain_id = event_type.reference_domain_id
   and event_type_domain.domain_code = 'QUARANTINE_EVENT_TYPE'
  where candidate.import_run_id = ctx.import_run_id
) q on true
left join lateral (
  select count(*) as quarantine_finding_count
  from s2t_fhir.import_candidate_row candidate
  join s2t_fhir.reference_value disposition
    on disposition.reference_value_id = candidate.candidate_disposition_value_id
  join s2t_fhir.reference_domain disposition_domain
    on disposition_domain.reference_domain_id = disposition.reference_domain_id
   and disposition_domain.domain_code = 'CANDIDATE_DISPOSITION'
   and disposition.value_code = 'QUARANTINED'
  join s2t_fhir.validation_finding_row vfr
    on vfr.import_candidate_row_id = candidate.import_candidate_row_id
  join s2t_fhir.validation_finding vf
    on vf.validation_finding_id = vfr.validation_finding_id
   and vf.validation_run_id = ctx.validation_run_id
  where candidate.import_run_id = ctx.import_run_id
) f on true;

-- Private normalized UI-node relation. It contains no raw evidence and receives no grants.
create view s2t_fhir_api._lovable_mapping_node
with (security_barrier = true)
as
with normalized as (
  select
    m.*,
    case m.mapping_kind
      when 'ELEMENT_MAPPING' then 'medication-request-cato--element-mapping'
      when 'STATUS_MAPPING_RULE' then 'medication-request-cato--status-mapping-rule'
      when 'GOVERNANCE_GUIDANCE' then 'medication-request-cato--governance-guidance'
    end as section_id,
    case m.mapping_kind
      when 'ELEMENT_MAPPING' then 1
      when 'STATUS_MAPPING_RULE' then 2
      when 'GOVERNANCE_GUIDANCE' then 3
    end as section_order,
    -- Parse the governed version marker and terminal digest without depending on
    -- a mapping-kind-specific logical-key prefix.
    'map-v' || substring(m.mapping_key from 'v([0-9]+):[0-9a-f]{64}$') || '-' || substring(m.mapping_key from '([0-9a-f]{64})$') as node_id,
    regexp_replace(btrim(m.target_fhir_path), '\s+\[', '[', 'g') as comparison_path,
    manifest.sheet_order,
    case
      when m.profile_context = 'IL CORE' then 'IL CORE'
      when m.profile_context in ('HDP', 'Ext: Medication Regimen HDP') then 'HDP'
      when m.profile_context = 'LOCAL' then 'LOCAL'
      when m.mapping_kind in ('STATUS_MAPPING_RULE', 'GOVERNANCE_GUIDANCE') then 'LOCAL'
    end as ui_profile,
    case
      when m.decision_status = 'DO NOT MAP' then 'unmapped'
      when m.decision_status in ('OPEN', 'WIP') then 'pending'
      when m.decision_status = 'N/A' then 'structural'
      when m.decision_status = 'FINAL' and m.mapping_kind = 'ELEMENT_MAPPING' and nullif(btrim(m.fixed_value), '') is not null then 'fixed'
      when m.decision_status = 'FINAL' then 'mapped'
    end as ui_status
  from s2t_fhir_api.active_mapping_record m
  join s2t_fhir_api._active_release_context ctx
    on ctx.baseline_code = m.baseline_code
   and ctx.version_label = m.version_label
   and ctx.source_system = 'CATO'
   and ctx.fhir_resource = 'MedicationRequest'
  join s2t_fhir.artifact_sheet_manifest manifest
    on manifest.artifact_id = ctx.artifact_id
   and manifest.sheet_name = m.source_sheet
), parented as (
  select
    child.*,
    parent.mapping_key as parent_mapping_key
  from normalized child
  left join lateral (
    select candidate.mapping_key
    from normalized candidate
    where child.mapping_kind = 'ELEMENT_MAPPING'
      and candidate.mapping_kind = 'ELEMENT_MAPPING'
      and candidate.baseline_code = child.baseline_code
      and candidate.mapping_key <> child.mapping_key
      and (
        left(child.comparison_path, length(candidate.comparison_path) + 1) = candidate.comparison_path || '.'
        or left(child.comparison_path, length(candidate.comparison_path) + 1) = candidate.comparison_path || '['
      )
    order by length(candidate.comparison_path) desc, candidate.mapping_key
    limit 1
  ) parent on true
)
select * from parented;

revoke all on s2t_fhir_api._lovable_mapping_node from public;

-- Recursive builder is private. SECURITY DEFINER is required because web roles have
-- no base-schema access; its caller and output are constrained by the public RPC.
create function s2t_fhir_api._build_lovable_children(
  p_baseline_code text,
  p_section_id text,
  p_parent_mapping_key text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  result jsonb := '[]'::jsonb;
  node record;
  child_nodes jsonb;
  node_json jsonb;
begin
  for node in
    select n.*
    from s2t_fhir_api._lovable_mapping_node n
    where n.baseline_code = p_baseline_code
      and n.section_id = p_section_id
      and n.parent_mapping_key is not distinct from p_parent_mapping_key
    order by n.sheet_order, n.source_row, n.source_cell_range, n.node_id
  loop
    child_nodes := s2t_fhir_api._build_lovable_children(
      p_baseline_code,
      p_section_id,
      node.mapping_key
    );

    node_json := jsonb_strip_nulls(jsonb_build_object(
      'id', node.node_id,
      'targetElement', case
        when node.mapping_kind in ('ELEMENT_MAPPING', 'STATUS_MAPPING_RULE') then node.target_fhir_path
        else coalesce(nullif(btrim(node.target_fhir_path_or_scope_raw), ''), node.guidance_scope)
      end,
      'cardinality', case when node.mapping_kind = 'ELEMENT_MAPPING' then coalesce(node.cardinality_raw, '') else '' end,
      'profile', node.ui_profile,
      'sourceSystem', coalesce(nullif(btrim(node.source_system_raw), ''), node.source_system),
      'sourceField', case
        when node.mapping_kind = 'ELEMENT_MAPPING' then node.source_expression
        when node.mapping_kind = 'STATUS_MAPPING_RULE' then node.source_status_value
        else coalesce(nullif(btrim(node.decision_topic_raw), ''), node.decision_topic)
      end,
      'fixedValue', case
        when node.mapping_kind = 'ELEMENT_MAPPING' then node.fixed_value
        when node.mapping_kind = 'STATUS_MAPPING_RULE' then node.target_status_value
      end,
      'transformation', case
        when node.mapping_kind = 'ELEMENT_MAPPING' then node.transformation_rule
        when node.mapping_kind = 'STATUS_MAPPING_RULE' then node.status_transformation_rule
        else node.guidance_text
      end,
      'description', case
        when node.mapping_kind = 'ELEMENT_MAPPING' then node.source_business_definition
        when node.mapping_kind = 'STATUS_MAPPING_RULE' then node.status_source_business_definition
        else node.guidance_text
      end,
      'bindingValueSet', case when node.mapping_kind = 'ELEMENT_MAPPING' then node.valueset_binding end,
      'notes', case
        when node.mapping_kind = 'ELEMENT_MAPPING' then node.notes
        when node.mapping_kind = 'STATUS_MAPPING_RULE' then node.status_notes
        else node.guidance_notes
      end,
      'status', node.ui_status
    ));

    if jsonb_array_length(child_nodes) > 0 then
      node_json := node_json || jsonb_build_object('children', child_nodes);
    end if;

    result := result || jsonb_build_array(node_json);
  end loop;

  return result;
end
$function$;

revoke all on function s2t_fhir_api._build_lovable_children(text, text, text) from public;

create function s2t_fhir_api.get_active_medication_request_cato()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  ctx record;
  context_count bigint;
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

  select count(*), count(distinct n.node_id)
    into node_count, distinct_id_count
  from s2t_fhir_api._lovable_mapping_node n
  where n.baseline_code = ctx.baseline_code;

  select count(*) into invalid_count
  from s2t_fhir_api._lovable_mapping_node n
  where n.baseline_code = ctx.baseline_code
    and (
      n.section_id is null
      or n.node_id is null
      or n.node_id !~ '^map-v[0-9]+-[0-9a-f]{64}$'
      or n.ui_profile is null
      or n.ui_profile not in ('IL CORE', 'HDP', 'LOCAL')
      or n.ui_status is null
      or n.ui_status not in ('mapped', 'fixed', 'pending', 'unmapped', 'structural')
      or (n.mapping_kind in ('ELEMENT_MAPPING', 'STATUS_MAPPING_RULE') and n.target_fhir_path is null)
      or (n.mapping_kind = 'GOVERNANCE_GUIDANCE'
          and nullif(btrim(coalesce(n.target_fhir_path_or_scope_raw, n.guidance_scope)), '') is null)
    );

  select count(*) into duplicate_path_count
  from (
    select n.comparison_path
    from s2t_fhir_api._lovable_mapping_node n
    where n.baseline_code = ctx.baseline_code
      and n.mapping_kind = 'ELEMENT_MAPPING'
    group by n.comparison_path
    having count(*) > 1
  ) duplicates;

  if node_count <> ctx.accepted_count
     or node_count <> distinct_id_count
     or invalid_count <> 0
     or duplicate_path_count <> 0 then
    return null;
  end if;

  section_element := s2t_fhir_api._build_lovable_children(
    ctx.baseline_code,
    'medication-request-cato--element-mapping',
    null
  );
  section_status := s2t_fhir_api._build_lovable_children(
    ctx.baseline_code,
    'medication-request-cato--status-mapping-rule',
    null
  );
  section_guidance := s2t_fhir_api._build_lovable_children(
    ctx.baseline_code,
    'medication-request-cato--governance-guidance',
    null
  );

  with recursive nodes(node) as (
    select value from jsonb_array_elements(section_element || section_status || section_guidance)
    union all
    select child.value
    from nodes parent
    cross join lateral jsonb_array_elements(coalesce(parent.node -> 'children', '[]'::jsonb)) child
  )
  select count(*) into represented_count from nodes;

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

revoke all on function s2t_fhir_api.get_active_medication_request_cato() from public;

revoke all on s2t_fhir_api.active_baseline from public;
revoke all on s2t_fhir_api.active_mapping_record from public;
revoke all on s2t_fhir_api.active_quarantine_item from public;
revoke all on s2t_fhir_api.active_quarantine_summary from public;

grant usage on schema s2t_fhir_api to s2t_fhir_api_reader;
grant select on
  s2t_fhir_api.active_baseline,
  s2t_fhir_api.active_mapping_record,
  s2t_fhir_api.active_quarantine_item,
  s2t_fhir_api.active_quarantine_summary
to s2t_fhir_api_reader;
grant execute on function s2t_fhir_api.get_active_medication_request_cato() to s2t_fhir_api_reader;

do $block$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant usage on schema s2t_fhir_api to anon';
    execute 'grant select on s2t_fhir_api.active_baseline, s2t_fhir_api.active_mapping_record, s2t_fhir_api.active_quarantine_item, s2t_fhir_api.active_quarantine_summary to anon';
    execute 'grant execute on function s2t_fhir_api.get_active_medication_request_cato() to anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant usage on schema s2t_fhir_api to authenticated';
    execute 'grant select on s2t_fhir_api.active_baseline, s2t_fhir_api.active_mapping_record, s2t_fhir_api.active_quarantine_item, s2t_fhir_api.active_quarantine_summary to authenticated';
    execute 'grant execute on function s2t_fhir_api.get_active_medication_request_cato() to authenticated';
  end if;
end
$block$;

alter default privileges for role s2t_fhir_owner in schema s2t_fhir_api revoke all on tables from public;
alter default privileges for role s2t_fhir_owner in schema s2t_fhir_api revoke all on functions from public;

reset role;

-- Verification queries (review/run separately; intentionally not executed by this migration):
--
-- select * from s2t_fhir_api.active_baseline;
-- Expected: one CATO/MedicationRequest row, lifecycle ACTIVE, gate PASSED,
-- candidate/accepted/quarantined counts 293/292/1.
--
-- select mapping_kind, count(*) from s2t_fhir_api.active_mapping_record
-- group by mapping_kind order by mapping_kind;
-- Expected: ELEMENT_MAPPING 237, GOVERNANCE_GUIDANCE 46, STATUS_MAPPING_RULE 9.
--
-- select count(*) from s2t_fhir_api.active_mapping_record;
-- Expected: 292.
--
-- select count(*) from s2t_fhir_api.active_mapping_record
-- where source_sheet = 'S2T MedicationRequestCato'
--   and source_row = 77 and source_cell_range = 'A77:Q77';
-- Expected: 0.
--
-- select count(*) from s2t_fhir_api.active_mapping_record m
-- join s2t_fhir_api.active_quarantine_item q
--   using (baseline_code, version_label, source_sheet, source_row, source_cell_range);
-- Expected: 0.
--
-- select s2t_fhir_api.get_active_medication_request_cato() ->> 'id';
-- Expected: medication-request-cato.
--
-- with recursive nodes(node) as (
--   select e.value
--   from jsonb_array_elements(s2t_fhir_api.get_active_medication_request_cato() -> 'sections') s
--   cross join lateral jsonb_array_elements(s.value -> 'elements') e
--   union all
--   select c.value from nodes n
--   cross join lateral jsonb_array_elements(coalesce(n.node -> 'children', '[]'::jsonb)) c
-- )
-- select count(*) as represented, count(distinct node ->> 'id') as distinct_ids,
--        bool_and((node ->> 'id') ~ '^map-v[0-9]+-[0-9a-f]{64}$') as ids_valid,
--        bool_and(node ?& array['id','targetElement','cardinality','profile','status']) as shape_valid
-- from nodes;
-- Expected: represented = distinct_ids = 292; ids_valid and shape_valid true.
--
-- select s2t_fhir_api.get_active_medication_request_cato()::text ~ '[א-ת]';
-- Expected: true (Hebrew preserved as UTF-8 text).
--
-- select s2t_fhir_api.get_active_medication_request_cato()
--      = s2t_fhir_api.get_active_medication_request_cato();
-- Expected: true in one snapshot; repeat in separate sessions for regression.
--
-- select table_name, column_name from information_schema.columns
-- where table_schema = 's2t_fhir_api'
--   and table_name in ('active_baseline','active_mapping_record','active_quarantine_item','active_quarantine_summary')
--   and (column_name like '%\_id' escape '\' or column_name in
--        ('raw_source_row','evidence_json','actor_principal_id','initiating_human_principal_id'));
-- Expected: no rows.
--
-- Verify as anon/authenticated: API SELECT/RPC succeeds; s2t_fhir base SELECT fails.
-- Verify as service_role: no direct s2t_fhir or migration-013 API privilege.

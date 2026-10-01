-- =====================================================================
-- 020_mapping_identity_CANDIDATE.sql — CANDIDATE for local migration 020.
-- Source: approved design 015b Revision 4. NOT YET EXECUTED ANYWHERE.
--
-- Intended to become local migration 020 after review.
-- Existing local migrations 001–019 are immutable and hash-protected: DO NOT EDIT THEM.
--
-- EXECUTION EXPECTATIONS
--   * No BEGIN/COMMIT here on purpose (so the exact body can be embedded in the
--     TEST dry-run). The migration runner MUST execute this file inside a single
--     transaction with ON_ERROR_STOP semantics.
--   * Creates ONLY: s2t_fhir.mapping_resource_registry,
--                   s2t_fhir._mapping_identity_base,
--                   s2t_fhir_api.governed_mapping_identity
--   * Only data write: one seed row into the NEW registry table.
--   * Alters/drops no existing object; touches no review/governance/mapping data.
--   * No grants to anon/authenticated; read only by owner SECURITY DEFINER code.
--   * No dependency on s2t_fhir_api._lovable_mapping_node.
-- =====================================================================
-- ---------------------------------------------------------------------
-- 1. Preconditions (no writes)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    's2t_fhir.baseline_series','s2t_fhir.baseline_version','s2t_fhir.mapping_record',
    's2t_fhir.logical_mapping_identity','s2t_fhir.import_candidate_row','s2t_fhir.import_run',
    's2t_fhir.artifact','s2t_fhir.element_mapping','s2t_fhir.status_mapping_rule',
    's2t_fhir.governance_guidance','s2t_fhir.reference_value','s2t_fhir.reference_domain',
    's2t_fhir_api._active_release_context']
  loop
    if to_regclass(t) is null then raise exception '015b precondition: % missing', t; end if;
  end loop;
  if to_regclass('s2t_fhir.mapping_resource_registry') is not null then
    raise exception '015b precondition: registry already exists';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Mapping-layer resource registry (private)
-- ---------------------------------------------------------------------
create table s2t_fhir.mapping_resource_registry (
  resource_config_id text primary key check (resource_config_id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  source_system      text not null check (btrim(source_system) <> ''),
  fhir_resource      text not null check (fhir_resource ~ '^[A-Z][A-Za-z]+$'),
  is_enabled         boolean not null default true,
  created_at         timestamptz not null default transaction_timestamp(),
  unique (source_system, fhir_resource)
);
comment on table s2t_fhir.mapping_resource_registry is
  'Mapping-layer registry: app resource_config_id -> governed (source_system, fhir_resource). Not Governance-owned.';
revoke all on s2t_fhir.mapping_resource_registry from public, anon, authenticated;

-- The ONLY place resource-specific literals may appear.
insert into s2t_fhir.mapping_resource_registry (resource_config_id, source_system, fhir_resource, is_enabled)
values ('medication-request-cato', 'CATO', 'MedicationRequest', true);

-- ---------------------------------------------------------------------
-- 3. Historical base view — all baseline versions, accepted rows only,
--    same accepted-row semantics as active_mapping_record (no validation_outcome rule).
--    Provenance strictly: mapping_record -> import_candidate_row -> import_run -> artifact.
-- ---------------------------------------------------------------------
create view s2t_fhir._mapping_identity_base with (security_barrier = true) as
select
  bs.source_system,
  bs.fhir_resource,
  bv.baseline_code,
  bv.version_label,
  mr.mapping_record_id,
  lmi.logical_key                                as mapping_key,
  -- node_id: 'map-v' || <version from logical_key> || '-' || <final 64-hex of logical_key>.
  -- Fail closed: NULL when logical_key does not yield the canonical shape (tests reject NULL).
  case when n.nid ~ '^map-v[0-9]+-[0-9a-f]{64}$' then n.nid end as node_id,
  mk.value_code                                   as mapping_kind,
  ds.value_code                                   as decision_status,
  coalesce(em.target_fhir_path, smr.target_fhir_path) as target_fhir_path,
  gg.target_fhir_path_or_scope_raw,
  gs.value_code                                   as guidance_scope,
  case
    when mk.value_code in ('STATUS_MAPPING_RULE','GOVERNANCE_GUIDANCE') then 'LOCAL'
    when btrim(em.profile_context) = 'IL CORE' then 'IL CORE'
    when btrim(em.profile_context) in ('HDP','Ext: Medication Regimen HDP') then 'HDP'
    when btrim(em.profile_context) = 'LOCAL' then 'LOCAL'
  end                                             as profile_label,
  icr.source_sheet_name                           as source_sheet,
  icr.source_row_number                           as source_row,
  icr.source_cell_range,
  encode(a.sha256_digest, 'hex')                  as artifact_sha256
from s2t_fhir.mapping_record mr
join s2t_fhir.baseline_version bv          on bv.baseline_version_id = mr.baseline_version_id
join s2t_fhir.baseline_series bs           on bs.baseline_series_id = bv.baseline_series_id
join s2t_fhir.logical_mapping_identity lmi on lmi.logical_mapping_identity_id = mr.logical_mapping_identity_id
                                          and lmi.source_system = bs.source_system
                                          and lmi.fhir_resource = bs.fhir_resource
                                          and lmi.mapping_kind_value_id = mr.mapping_kind_value_id
join s2t_fhir.import_candidate_row icr     on icr.import_candidate_row_id = mr.import_candidate_row_id
                                          and icr.mapping_kind_value_id = mr.mapping_kind_value_id
join s2t_fhir.import_run ir                on ir.import_run_id = icr.import_run_id
                                          and ir.baseline_version_id = mr.baseline_version_id
join s2t_fhir.artifact a                   on a.artifact_id = ir.artifact_id
join s2t_fhir.reference_value mk        on mk.reference_value_id = mr.mapping_kind_value_id
join s2t_fhir.reference_domain mkd      on mkd.reference_domain_id = mk.reference_domain_id
                                          and mkd.domain_code = 'MAPPING_KIND'
join s2t_fhir.reference_value ds        on ds.reference_value_id = mr.decision_status_value_id
join s2t_fhir.reference_domain dsd      on dsd.reference_domain_id = ds.reference_domain_id
                                          and dsd.domain_code = 'DECISION_STATUS'
join s2t_fhir.reference_value cd        on cd.reference_value_id = icr.candidate_disposition_value_id
join s2t_fhir.reference_domain cdd      on cdd.reference_domain_id = cd.reference_domain_id
                                          and cdd.domain_code = 'CANDIDATE_DISPOSITION'
left join s2t_fhir.element_mapping em      on em.mapping_record_id = mr.mapping_record_id
left join s2t_fhir.status_mapping_rule smr on smr.mapping_record_id = mr.mapping_record_id
left join s2t_fhir.governance_guidance gg  on gg.mapping_record_id = mr.mapping_record_id
left join (s2t_fhir.reference_value gs
           join s2t_fhir.reference_domain gsd on gsd.reference_domain_id = gs.reference_domain_id
                                             and gsd.domain_code = 'GUIDANCE_SCOPE')
                                           on gs.reference_value_id = gg.guidance_scope_value_id
cross join lateral (
  select 'map-v' || substring(lmi.logical_key from 'v([0-9]+)')
         || '-' || substring(lmi.logical_key from '([0-9a-f]{64})$') as nid
) n
where cd.value_code = 'ACCEPTED'
  and (
  -- kind integrity: exactly the matching kind table, nothing else
  (mk.value_code = 'ELEMENT_MAPPING'     and em.mapping_record_id is not null and smr.mapping_record_id is null and gg.mapping_record_id is null)
  or (mk.value_code = 'STATUS_MAPPING_RULE' and smr.mapping_record_id is not null and em.mapping_record_id is null and gg.mapping_record_id is null)
  or (mk.value_code = 'GOVERNANCE_GUIDANCE' and gg.mapping_record_id is not null and gs.reference_value_id is not null
      and em.mapping_record_id is null and smr.mapping_record_id is null));
revoke all on s2t_fhir._mapping_identity_base from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Generic identity contract
--    ELEMENT_MAPPING parent = longest-prefix ELEMENT_MAPPING comparison_path in the same
--      resource + baseline, boundary '.' OR '['; comparison_path =
--      regexp_replace(btrim(target_fhir_path), '\s+\[', '[', 'g') — same as current UI view.
--      element_path = recursive root-first chain of target paths (cycle/depth guarded;
--      broken chain => NULL, rejected by tests).
--    STATUS_MAPPING_RULE => ARRAY[target_fhir_path] (no invented hierarchy).
--    GOVERNANCE_GUIDANCE => NULL.
-- ---------------------------------------------------------------------
create view s2t_fhir_api.governed_mapping_identity with (security_barrier = true) as
with recursive
reg as (
  select resource_config_id, source_system, fhir_resource
  from s2t_fhir.mapping_resource_registry where is_enabled
),
b as (
  select r.resource_config_id, m.*
  from s2t_fhir._mapping_identity_base m
  join reg r using (source_system, fhir_resource)
),
el as (
  select resource_config_id, baseline_code, mapping_record_id, mapping_key, target_fhir_path,
         regexp_replace(btrim(target_fhir_path), '\s+\[', '[', 'g') as comparison_path
  from b where mapping_kind = 'ELEMENT_MAPPING'
),
parent as (
  -- Tie-break identical to _lovable_mapping_node: longest comparison_path, then mapping_key.
  -- mapping_record_id is only an internal row handle for recursive joins, never the tie-break.
  select distinct on (c.resource_config_id, c.baseline_code, c.mapping_record_id)
         c.resource_config_id, c.baseline_code, c.mapping_record_id, p.mapping_record_id as parent_id
  from el c
  left join el p
    on p.resource_config_id = c.resource_config_id
   and p.baseline_code      = c.baseline_code
   and p.mapping_record_id <> c.mapping_record_id
   and left(c.comparison_path, length(p.comparison_path) + 1) in (p.comparison_path || '.', p.comparison_path || '[')
  order by c.resource_config_id, c.baseline_code, c.mapping_record_id,
           length(p.comparison_path) desc nulls last, p.mapping_key
),
walk as (
  select pa.resource_config_id, pa.baseline_code, pa.mapping_record_id as origin_id,
         pa.parent_id as next_id, array[e.target_fhir_path] as path_rev,
         array[pa.mapping_record_id] as visited, 1 as depth, false as broken
  from parent pa
  join el e using (resource_config_id, baseline_code, mapping_record_id)
  union all
  select w.resource_config_id, w.baseline_code, w.origin_id,
         pa.parent_id, w.path_rev || e.target_fhir_path,
         w.visited || pa.mapping_record_id, w.depth + 1,
         (pa.mapping_record_id = any(w.visited)) or w.depth >= 64
  from walk w
  join parent pa on pa.resource_config_id = w.resource_config_id
                and pa.baseline_code      = w.baseline_code
                and pa.mapping_record_id  = w.next_id
  join el e      on e.resource_config_id = pa.resource_config_id
                and e.baseline_code      = pa.baseline_code
                and e.mapping_record_id  = pa.mapping_record_id
  where w.next_id is not null and not w.broken
),
terminal as (
  select distinct on (resource_config_id, baseline_code, origin_id)
         resource_config_id, baseline_code, origin_id,
         case when next_id is null and not broken
              then array(select x from unnest(path_rev) with ordinality t(x, o) order by o desc) end as element_path
  from walk
  order by resource_config_id, baseline_code, origin_id, depth desc
),
active as (
  select r.resource_config_id, c.baseline_code
  from s2t_fhir_api._active_release_context c
  join reg r using (source_system, fhir_resource)
)
select
  b.resource_config_id,
  b.fhir_resource                        as fhir_resource_type,
  b.baseline_code,
  b.version_label,
  (a.baseline_code is not null)          as is_active_baseline,
  b.node_id,
  b.mapping_kind,
  case when b.mapping_kind = 'GOVERNANCE_GUIDANCE'
       then coalesce(nullif(btrim(b.target_fhir_path_or_scope_raw), ''), b.guidance_scope)
       else b.target_fhir_path end        as target_element,
  case b.mapping_kind
       when 'ELEMENT_MAPPING'     then t.element_path
       when 'STATUS_MAPPING_RULE' then array[b.target_fhir_path]
  end                                    as element_path,
  b.profile_label,
  b.decision_status,
  b.source_sheet,
  b.source_row,
  b.source_cell_range,
  b.artifact_sha256
from b
left join terminal t on t.resource_config_id = b.resource_config_id
                    and t.baseline_code      = b.baseline_code
                    and t.origin_id          = b.mapping_record_id
left join active a   on a.resource_config_id = b.resource_config_id
                    and a.baseline_code      = b.baseline_code;

comment on view s2t_fhir_api.governed_mapping_identity is
  'Generic mapping identity (resource_config_id, baseline_code, node_id); all baselines. Mapping-layer owned. '
  'Read only by owner SECURITY DEFINER code (Governance 016).';

-- ---------------------------------------------------------------------
-- 5. Security: no direct client grants on any 015b object.
-- ---------------------------------------------------------------------
revoke all on s2t_fhir_api.governed_mapping_identity from public, anon, authenticated;

-- ROLLBACK GUIDANCE (manual, approval required; must precede/omit any 016):
--   drop view  if exists s2t_fhir_api.governed_mapping_identity;
--   drop view  if exists s2t_fhir._mapping_identity_base;
--   drop table if exists s2t_fhir.mapping_resource_registry;

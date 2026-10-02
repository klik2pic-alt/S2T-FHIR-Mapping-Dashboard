-- =====================================================================
-- 020_mapping_identity.sql — Revision 3.
-- Source: approved design 015b Revision 4 + repo-wide Codex review (Revision 2 items + final Codex integrity fixes).
-- PROVENANCE: This migration contract is deployed in S2T-FHIR-DDL-Test.
-- The deployment was manual/unhistorical and is not registered in Supabase migration history.
-- Local-vs-deployed contract parity has been verified; this file is part of the authoritative TEST baseline.
--
-- Local migrations 001–021 are the authoritative, hash-protected TEST baseline: DO NOT EDIT semantic SQL.
--
-- EXECUTION EXPECTATIONS
--   * Supabase-only. Requires roles s2t_fhir_owner, anon, authenticated (checked below).
--   * Runs as s2t_fhir_owner (SET ROLE ... / RESET ROLE), same convention as 014/015.
--   * No BEGIN/COMMIT here on purpose: the exact body (including SET ROLE / RESET ROLE)
--     is embedded verbatim in the TEST dry-run. The migration runner MUST execute this
--     file inside a single transaction with ON_ERROR_STOP semantics.
--   * Creates ONLY: s2t_fhir.mapping_resource_registry,
--                   s2t_fhir._mapping_identity_base,
--                   s2t_fhir_api.governed_mapping_identity
--   * Only data write: one INSERT (seed row) into the NEW registry table.
--   * No UPDATE / DELETE / ALTER / DROP of any existing object or data.
--   * No grants to anon/authenticated; read only by owner SECURITY DEFINER code.
--   * No dependency on s2t_fhir_api._lovable_mapping_node. No dependency on downstream governance consumers.
--
-- SCHEMA BINDINGS
--   Verified against local migrations 004 and 013.
--   Runtime relation/column preconditions remain in place as fail-closed drift protection.
-- =====================================================================
set role s2t_fhir_owner;

-- ---------------------------------------------------------------------
-- 1. Preconditions (no writes)
-- ---------------------------------------------------------------------
do $$
declare
  t text;
  r text;
  tc text[];
begin
  -- 1a. Supabase roles
  foreach r in array array['s2t_fhir_owner','anon','authenticated'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      raise exception '020 precondition: role % missing (Supabase-only migration)', r;
    end if;
  end loop;

  -- 1b. Required relations
  foreach t in array array[
    's2t_fhir.baseline_series','s2t_fhir.baseline_version','s2t_fhir.mapping_record',
    's2t_fhir.logical_mapping_identity','s2t_fhir.import_candidate_row','s2t_fhir.import_run',
    's2t_fhir.artifact','s2t_fhir.artifact_sheet_manifest',
    's2t_fhir.element_mapping','s2t_fhir.status_mapping_rule',
    's2t_fhir.governance_guidance','s2t_fhir.reference_value','s2t_fhir.reference_domain',
    's2t_fhir_api._active_release_context']
  loop
    if to_regclass(t) is null then raise exception '020 precondition: % missing', t; end if;
  end loop;

  -- 1c. Every column referenced by this migration (fail closed on any name drift)
  foreach tc slice 1 in array array[
    array['s2t_fhir.baseline_series','baseline_series_id'],
    array['s2t_fhir.baseline_series','source_system'],
    array['s2t_fhir.baseline_series','fhir_resource'],
    array['s2t_fhir.baseline_version','baseline_version_id'],
    array['s2t_fhir.baseline_version','baseline_series_id'],
    array['s2t_fhir.baseline_version','baseline_code'],
    array['s2t_fhir.baseline_version','version_label'],
    array['s2t_fhir.mapping_record','mapping_record_id'],
    array['s2t_fhir.mapping_record','baseline_version_id'],
    array['s2t_fhir.mapping_record','logical_mapping_identity_id'],
    array['s2t_fhir.mapping_record','import_candidate_row_id'],
    array['s2t_fhir.mapping_record','mapping_kind_value_id'],
    array['s2t_fhir.mapping_record','decision_status_value_id'],
    array['s2t_fhir.logical_mapping_identity','logical_mapping_identity_id'],
    array['s2t_fhir.logical_mapping_identity','logical_key'],
    array['s2t_fhir.logical_mapping_identity','source_system'],
    array['s2t_fhir.logical_mapping_identity','fhir_resource'],
    array['s2t_fhir.logical_mapping_identity','mapping_kind_value_id'],
    array['s2t_fhir.import_candidate_row','import_candidate_row_id'],
    array['s2t_fhir.import_candidate_row','import_run_id'],
    array['s2t_fhir.import_candidate_row','mapping_kind_value_id'],
    array['s2t_fhir.import_candidate_row','candidate_disposition_value_id'],
    array['s2t_fhir.import_candidate_row','source_sheet_name'],
    array['s2t_fhir.import_candidate_row','source_row_number'],
    array['s2t_fhir.import_candidate_row','source_cell_range'],
    array['s2t_fhir.import_run','import_run_id'],
    array['s2t_fhir.import_run','baseline_version_id'],
    array['s2t_fhir.import_run','artifact_id'],
    array['s2t_fhir.artifact','artifact_id'],
    array['s2t_fhir.artifact','sha256_digest'],
    array['s2t_fhir.artifact_sheet_manifest','artifact_id'],
    array['s2t_fhir.artifact_sheet_manifest','sheet_name'],
    array['s2t_fhir.element_mapping','mapping_record_id'],
    array['s2t_fhir.element_mapping','target_fhir_path'],
    array['s2t_fhir.element_mapping','profile_context'],
    array['s2t_fhir.status_mapping_rule','mapping_record_id'],
    array['s2t_fhir.status_mapping_rule','target_fhir_path'],
    array['s2t_fhir.governance_guidance','mapping_record_id'],
    array['s2t_fhir.governance_guidance','target_fhir_path_or_scope_raw'],
    array['s2t_fhir.governance_guidance','guidance_scope_value_id'],
    array['s2t_fhir.governance_guidance','decision_topic_value_id'],
    array['s2t_fhir.reference_value','reference_value_id'],
    array['s2t_fhir.reference_value','reference_domain_id'],
    array['s2t_fhir.reference_value','value_code'],
    array['s2t_fhir.reference_domain','reference_domain_id'],
    array['s2t_fhir.reference_domain','domain_code'],
    array['s2t_fhir_api._active_release_context','source_system'],
    array['s2t_fhir_api._active_release_context','fhir_resource'],
    array['s2t_fhir_api._active_release_context','baseline_code'],
    array['s2t_fhir_api._active_release_context','baseline_version_id'],
    array['s2t_fhir_api._active_release_context','import_run_id']]
  loop
    if not exists (
      select 1 from pg_attribute
      where attrelid = to_regclass(tc[1]) and attname = tc[2] and attnum > 0 and not attisdropped
    ) then
      raise exception '020 precondition: column %.% missing', tc[1], tc[2];
    end if;
  end loop;

  -- 1d. New objects must not exist yet
  foreach t in array array['s2t_fhir.mapping_resource_registry','s2t_fhir._mapping_identity_base',
                           's2t_fhir_api.governed_mapping_identity'] loop
    if to_regclass(t) is not null then raise exception '020 precondition: % already exists', t; end if;
  end loop;
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

-- The ONLY INSERT in this migration and the ONLY place resource-specific literals appear.
insert into s2t_fhir.mapping_resource_registry (resource_config_id, source_system, fhir_resource, is_enabled)
values ('medication-request-cato', 'CATO', 'MedicationRequest', true);

-- ---------------------------------------------------------------------
-- 3. Historical base view — all baseline versions and import runs, accepted rows only,
--    same accepted-row semantics as active_mapping_record (no validation_outcome rule),
--    restricted to sheets backed by the import artifact's artifact_sheet_manifest
--    (same authoritative sheet restriction as the governed/UI read layer).
--    Provenance strictly: mapping_record -> import_candidate_row -> import_run -> artifact.
-- ---------------------------------------------------------------------
create view s2t_fhir._mapping_identity_base with (security_barrier = true) as
select
  bs.source_system,
  bs.fhir_resource,
  bv.baseline_version_id,
  bv.baseline_code,
  bv.version_label,
  ir.import_run_id,
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
  -- Profile normalization: exact literal comparison, no extra btrim (UI parity; see test).
  case
    when mk.value_code in ('STATUS_MAPPING_RULE','GOVERNANCE_GUIDANCE') then 'LOCAL'
    when em.profile_context = 'IL CORE' then 'IL CORE'
    when em.profile_context in ('HDP','Ext: Medication Regimen HDP') then 'HDP'
    when em.profile_context = 'LOCAL' then 'LOCAL'
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
left join (s2t_fhir.reference_value dt
           join s2t_fhir.reference_domain dtd on dtd.reference_domain_id = dt.reference_domain_id
                                             and dtd.domain_code = 'DECISION_TOPIC_CODE')
                                           on dt.reference_value_id = gg.decision_topic_value_id
cross join lateral (
  select 'map-v' || substring(lmi.logical_key from 'v([0-9]+)')
         || '-' || substring(lmi.logical_key from '([0-9a-f]{64})$') as nid
) n
where cd.value_code = 'ACCEPTED'
  -- authoritative sheet manifest: the candidate's sheet must be declared for this import's artifact
  and exists (
    select 1 from s2t_fhir.artifact_sheet_manifest asm
    where asm.artifact_id = ir.artifact_id
      and asm.sheet_name  = icr.source_sheet_name)
  and (
  -- kind integrity: exactly the matching kind table, nothing else
  (mk.value_code = 'ELEMENT_MAPPING'     and em.mapping_record_id is not null and smr.mapping_record_id is null and gg.mapping_record_id is null)
  or (mk.value_code = 'STATUS_MAPPING_RULE' and smr.mapping_record_id is not null and em.mapping_record_id is null and gg.mapping_record_id is null)
  or (mk.value_code = 'GOVERNANCE_GUIDANCE' and gg.mapping_record_id is not null
      and gs.reference_value_id is not null and dt.reference_value_id is not null
      and em.mapping_record_id is null and smr.mapping_record_id is null));
comment on view s2t_fhir._mapping_identity_base is
  'Private historical mapping identity base (all baselines/imports, accepted, manifest-backed sheets). Input to governed_mapping_identity only.';
revoke all on s2t_fhir._mapping_identity_base from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Generic identity contract
--    ELEMENT_MAPPING parent = longest-prefix ELEMENT_MAPPING comparison_path in the same
--      resource + baseline version + import run, boundary '.' OR '['; comparison_path =
--      regexp_replace(btrim(target_fhir_path), '\s+\[', '[', 'g') — same as current UI view.
--      Tie-break: longest comparison_path, then mapping_key (identical to UI view).
--      element_path = recursive root-first chain of target paths (cycle/depth guarded;
--      broken chain => NULL, rejected by tests).
--    STATUS_MAPPING_RULE => ARRAY[target_fhir_path] (no invented hierarchy).
--    GOVERNANCE_GUIDANCE => NULL.
--    is_active_baseline = (resource_config_id, baseline_version_id, import_run_id) equals the
--      active release context for that registry mapping. Never inferred from baseline_code alone.
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
  select resource_config_id, baseline_version_id, import_run_id, mapping_record_id, mapping_key,
         target_fhir_path,
         regexp_replace(btrim(target_fhir_path), '\s+\[', '[', 'g') as comparison_path
  from b where mapping_kind = 'ELEMENT_MAPPING'
),
parent as (
  -- mapping_record_id is only an internal row handle for recursive joins, never the tie-break.
  select distinct on (c.resource_config_id, c.baseline_version_id, c.import_run_id, c.mapping_record_id)
         c.resource_config_id, c.baseline_version_id, c.import_run_id, c.mapping_record_id,
         p.mapping_record_id as parent_id
  from el c
  left join el p
    on p.resource_config_id  = c.resource_config_id
   and p.baseline_version_id = c.baseline_version_id
   and p.import_run_id       = c.import_run_id
   and p.mapping_record_id  <> c.mapping_record_id
   and left(c.comparison_path, length(p.comparison_path) + 1) in (p.comparison_path || '.', p.comparison_path || '[')
  order by c.resource_config_id, c.baseline_version_id, c.import_run_id, c.mapping_record_id,
           length(p.comparison_path) desc nulls last, p.mapping_key
),
walk as (
  select pa.resource_config_id, pa.baseline_version_id, pa.import_run_id,
         pa.mapping_record_id as origin_id,
         pa.parent_id as next_id, array[e.target_fhir_path] as path_rev,
         array[pa.mapping_record_id] as visited, 1 as depth, false as broken
  from parent pa
  join el e using (resource_config_id, baseline_version_id, import_run_id, mapping_record_id)
  union all
  select w.resource_config_id, w.baseline_version_id, w.import_run_id, w.origin_id,
         pa.parent_id, w.path_rev || e.target_fhir_path,
         w.visited || pa.mapping_record_id, w.depth + 1,
         (pa.mapping_record_id = any(w.visited)) or w.depth >= 64
  from walk w
  join parent pa on pa.resource_config_id  = w.resource_config_id
                and pa.baseline_version_id = w.baseline_version_id
                and pa.import_run_id       = w.import_run_id
                and pa.mapping_record_id   = w.next_id
  join el e      on e.resource_config_id  = pa.resource_config_id
                and e.baseline_version_id = pa.baseline_version_id
                and e.import_run_id       = pa.import_run_id
                and e.mapping_record_id   = pa.mapping_record_id
  where w.next_id is not null and not w.broken
),
terminal as (
  select distinct on (resource_config_id, baseline_version_id, import_run_id, origin_id)
         resource_config_id, baseline_version_id, import_run_id, origin_id,
         case when next_id is null and not broken
              then array(select x from unnest(path_rev) with ordinality t(x, o) order by o desc) end as element_path
  from walk
  order by resource_config_id, baseline_version_id, import_run_id, origin_id, depth desc
),
active as (
  select r.resource_config_id, c.baseline_version_id, c.import_run_id
  from s2t_fhir_api._active_release_context c
  join reg r using (source_system, fhir_resource)
)
select
  b.resource_config_id,
  b.fhir_resource                        as fhir_resource_type,
  b.baseline_code,
  b.version_label,
  (a.resource_config_id is not null)     as is_active_baseline,
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
left join terminal t on t.resource_config_id  = b.resource_config_id
                    and t.baseline_version_id = b.baseline_version_id
                    and t.import_run_id       = b.import_run_id
                    and t.origin_id           = b.mapping_record_id
left join active a   on a.resource_config_id  = b.resource_config_id
                    and a.baseline_version_id = b.baseline_version_id
                    and a.import_run_id       = b.import_run_id;

comment on view s2t_fhir_api.governed_mapping_identity is
  'Generic mapping identity (resource_config_id, baseline_code, node_id); all baselines/imports. Mapping-layer owned. '
  'is_active_baseline matches the active release context on baseline_version_id + import_run_id. '
  'No direct client access; intended for separately governed owner-controlled consumers.';

-- ---------------------------------------------------------------------
-- 5. Security: no direct client grants on any 020 object.
-- ---------------------------------------------------------------------
revoke all on s2t_fhir_api.governed_mapping_identity from public, anon, authenticated;

reset role;

-- ROLLBACK GUIDANCE: drop dependent consumers first, if any.
--   set role s2t_fhir_owner;
--   drop view  if exists s2t_fhir_api.governed_mapping_identity;
--   drop view  if exists s2t_fhir._mapping_identity_base;
--   drop table if exists s2t_fhir.mapping_resource_registry;
--   reset role;

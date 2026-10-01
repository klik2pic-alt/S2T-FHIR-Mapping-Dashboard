-- =====================================================================
-- 020_mapping_identity_TEST_DRY_RUN.sql — Revision 3. NOT YET EXECUTED ANYWHERE.
-- Supabase SQL Editor dry-run for 020_mapping_identity_CANDIDATE.sql (Revision 3).
--
-- HOW IT WORKS
--   BEGIN;
--   record narrow "before" fingerprints into a temp table;
--   install the EXACT candidate body (verbatim, incl. SET ROLE / RESET ROLE);
--   run every validation as an INSERT into temp table _t020_result(test_name, passed, details);
--   SELECT all results, then a PASS/FAIL aggregate;
--   ROLLBACK;
--
--   Logical assertion failures do NOT raise: they are recorded as passed = false, so the
--   script reaches ROLLBACK whenever its SQL is syntactically and runtime valid.
--
-- IMPORTANT — RUNTIME ERRORS
--   The candidate's preconditions intentionally RAISE on schema drift, and any other SQL
--   runtime error also aborts the transaction BEFORE the final ROLLBACK is reached.
--   If ANY error appears: run   ROLLBACK;   manually (or close the SQL Editor
--   transaction/connection) before retrying. Nothing is committed in either case.
--
-- No psql meta-commands. Run the whole file as one script.
--
-- SCOPE OF CLAIMS
--   * Fingerprints cover only the active read-model views and the base tables referenced
--     by the candidate. They do NOT prove that all governed data is unchanged.
--   * Static guarantee (by inspection of the candidate): exactly one INSERT, into the newly
--     created registry; no UPDATE/DELETE/ALTER/DROP of existing objects.
--   * _lovable_mapping_node parity tests apply ONLY to resource_config_id =
--     'medication-request-cato'. Other enabled resources are validated by generic invariants.
--
-- OPTIONAL DATASET REGRESSION (comments only, not assertions):
--   BL-001 CATO MedicationRequest at time of writing: 292 active rows
--   (ELEMENT_MAPPING 237, STATUS_MAPPING_RULE 9, GOVERNANCE_GUIDANCE 46).
-- =====================================================================
begin;

create temp table _t020_result (
  seq       serial,
  test_name text not null,
  passed    boolean,
  details   text
) on commit drop;
create temp table _t020_fp (
  phase  text not null,
  object text not null,
  digest text
) on commit drop;
grant all on _t020_result, _t020_fp to s2t_fhir_owner;
grant usage on sequence _t020_result_seq_seq to s2t_fhir_owner;

-- ---------------------------------------------------------------------
-- 0. BEFORE fingerprints (read-only; active read model + referenced base tables)
-- ---------------------------------------------------------------------
set role s2t_fhir_owner;
insert into _t020_fp
select 'before', 'active_baseline',        md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api.active_baseline x
union all select 'before', 'active_mapping_record',  md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api.active_mapping_record x
union all select 'before', '_active_release_context', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api._active_release_context x
union all select 'before', '_lovable_mapping_node',  md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api._lovable_mapping_node x
union all select 'before', 'baseline_series',          md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.baseline_series x
union all select 'before', 'baseline_version',         md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.baseline_version x
union all select 'before', 'mapping_record',           md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.mapping_record x
union all select 'before', 'logical_mapping_identity', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.logical_mapping_identity x
union all select 'before', 'import_candidate_row',     md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.import_candidate_row x
union all select 'before', 'import_run',               md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.import_run x
union all select 'before', 'artifact',                 md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.artifact x
union all select 'before', 'artifact_sheet_manifest',  md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.artifact_sheet_manifest x
union all select 'before', 'element_mapping',          md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.element_mapping x
union all select 'before', 'status_mapping_rule',      md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.status_mapping_rule x
union all select 'before', 'governance_guidance',      md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.governance_guidance x
union all select 'before', 'reference_value',          md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.reference_value x
union all select 'before', 'reference_domain',         md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.reference_domain x;
reset role;

-- =====================================================================
-- >>> BEGIN EXACT CANDIDATE BODY (020_mapping_identity_CANDIDATE.sql, Revision 3) <<<
-- =====================================================================
-- =====================================================================
-- 020_mapping_identity_CANDIDATE.sql — Revision 3 (CANDIDATE for local migration 020).
-- Source: approved design 015b Revision 4 + repo-wide Codex review (Revision 2 items + final Codex integrity fixes).
-- NOT YET EXECUTED ANYWHERE.
--
-- Existing local migrations 001–019 are immutable and hash-protected: DO NOT EDIT THEM.
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
-- =====================================================================
-- >>> END EXACT CANDIDATE BODY <<<
-- =====================================================================

set role s2t_fhir_owner;

-- ---------------------------------------------------------------------
-- 1. Registry
-- ---------------------------------------------------------------------
insert into _t020_result (test_name, passed, details)
select 'T01 registry seed: exactly one row, medication-request-cato/CATO/MedicationRequest enabled',
       count(*) = 1 and bool_and(resource_config_id = 'medication-request-cato' and source_system = 'CATO'
                                 and fhir_resource = 'MedicationRequest' and is_enabled),
       'rows=' || count(*)
from s2t_fhir.mapping_resource_registry;

-- ---------------------------------------------------------------------
-- 2. Generic invariants (all enabled resources, all baselines/imports)
-- ---------------------------------------------------------------------
insert into _t020_result (test_name, passed, details)
select 'T02 key uniqueness (resource_config_id, baseline_code, node_id)', count(*) = 0, 'duplicate keys=' || count(*)
from (select 1 from s2t_fhir_api.governed_mapping_identity
      group by resource_config_id, baseline_code, node_id having count(*) > 1) d;

insert into _t020_result (test_name, passed, details)
select 'T03 node_id non-null and map-vN-<64hex>', count(*) filter (where node_id is null or node_id !~ '^map-v[0-9]+-[0-9a-f]{64}$') = 0,
       'bad=' || count(*) filter (where node_id is null or node_id !~ '^map-v[0-9]+-[0-9a-f]{64}$') || ' of ' || count(*)
from s2t_fhir_api.governed_mapping_identity;

insert into _t020_result (test_name, passed, details)
select 'T04 ELEMENT_MAPPING element_path non-null (no orphan/cycle/broken chain), last = target_element',
       count(*) filter (where element_path is null or element_path[cardinality(element_path)] is distinct from target_element) = 0,
       'bad=' || count(*) filter (where element_path is null or element_path[cardinality(element_path)] is distinct from target_element)
from s2t_fhir_api.governed_mapping_identity where mapping_kind = 'ELEMENT_MAPPING';

insert into _t020_result (test_name, passed, details)
select 'T05 STATUS_MAPPING_RULE element_path = ARRAY[target_element], target non-null',
       count(*) filter (where target_element is null or element_path is distinct from array[target_element]) = 0,
       'bad=' || count(*) filter (where target_element is null or element_path is distinct from array[target_element])
from s2t_fhir_api.governed_mapping_identity where mapping_kind = 'STATUS_MAPPING_RULE';

insert into _t020_result (test_name, passed, details)
select 'T06 GOVERNANCE_GUIDANCE element_path IS NULL, target non-null',
       count(*) filter (where element_path is not null or target_element is null) = 0,
       'bad=' || count(*) filter (where element_path is not null or target_element is null)
from s2t_fhir_api.governed_mapping_identity where mapping_kind = 'GOVERNANCE_GUIDANCE';

insert into _t020_result (test_name, passed, details)
select 'T07 provenance non-null for every row (sheet, row, cell range, sha256 64-hex)',
       count(*) filter (where source_sheet is null or source_row is null or source_cell_range is null
                        or artifact_sha256 is null or artifact_sha256 !~ '^[0-9a-f]{64}$') = 0,
       'bad=' || count(*) filter (where source_sheet is null or source_row is null or source_cell_range is null
                        or artifact_sha256 is null or artifact_sha256 !~ '^[0-9a-f]{64}$')
from s2t_fhir_api.governed_mapping_identity;

insert into _t020_result (test_name, passed, details)
select 'T08 each enabled resource with an active release context has active rows',
       count(*) filter (where n = 0) = 0,
       coalesce(string_agg(resource_config_id || '=' || n, ', '), 'no active contexts')
from (
  select r.resource_config_id,
         (select count(*) from s2t_fhir_api.governed_mapping_identity g
           where g.resource_config_id = r.resource_config_id and g.is_active_baseline) as n
  from s2t_fhir.mapping_resource_registry r
  join s2t_fhir_api._active_release_context c using (source_system, fhir_resource)
  where r.is_enabled) x;

-- T09 is_active_baseline exactness: active flag <=> (version, import) equals active context.
insert into _t020_result (test_name, passed, details)
select 'T09 is_active_baseline true only for active baseline_version_id + import_run_id',
       count(*) filter (where flagged is distinct from expected) = 0,
       'mismatch=' || count(*) filter (where flagged is distinct from expected)
from (
  select g.is_active_baseline as flagged,
         exists (select 1 from s2t_fhir_api._active_release_context c
                 where c.source_system = m.source_system and c.fhir_resource = m.fhir_resource
                   and c.baseline_version_id = m.baseline_version_id
                   and c.import_run_id = m.import_run_id) as expected
  from s2t_fhir._mapping_identity_base m
  join s2t_fhir.mapping_resource_registry r
    on r.source_system = m.source_system and r.fhir_resource = m.fhir_resource and r.is_enabled
  join s2t_fhir_api.governed_mapping_identity g
    on g.resource_config_id = r.resource_config_id and g.baseline_code = m.baseline_code and g.node_id = m.node_id
) x;

-- T10 provenance vs the correctly joined active baseline (no global single-row assumption).
insert into _t020_result (test_name, passed, details)
select 'T10 active rows: artifact_sha256 equals active_baseline.artifact_sha256 of the matching active context',
       count(*) > 0 and count(*) filter (where ab.artifact_sha256 is distinct from g.artifact_sha256) = 0,
       'active rows=' || count(*) || ', mismatch=' || count(*) filter (where ab.artifact_sha256 is distinct from g.artifact_sha256)
from s2t_fhir_api.governed_mapping_identity g
join s2t_fhir.mapping_resource_registry r on r.resource_config_id = g.resource_config_id
join s2t_fhir._mapping_identity_base m
  on m.source_system = r.source_system and m.fhir_resource = r.fhir_resource
 and m.baseline_code = g.baseline_code and m.node_id = g.node_id
join s2t_fhir_api._active_release_context c
  on c.source_system = m.source_system and c.fhir_resource = m.fhir_resource
 and c.baseline_version_id = m.baseline_version_id and c.import_run_id = m.import_run_id
left join s2t_fhir_api.active_baseline ab on ab.baseline_code = c.baseline_code
where g.is_active_baseline;

-- T11 manifest restriction: every row's sheet is declared for its import artifact.
insert into _t020_result (test_name, passed, details)
select 'T11 every base row is backed by artifact_sheet_manifest for its import artifact',
       count(*) filter (where not exists (
         select 1 from s2t_fhir.import_run ir
         join s2t_fhir.artifact_sheet_manifest asm on asm.artifact_id = ir.artifact_id
         where ir.import_run_id = m.import_run_id and asm.sheet_name = m.source_sheet)) = 0,
       'unbacked=' || count(*) filter (where not exists (
         select 1 from s2t_fhir.import_run ir
         join s2t_fhir.artifact_sheet_manifest asm on asm.artifact_id = ir.artifact_id
         where ir.import_run_id = m.import_run_id and asm.sheet_name = m.source_sheet))
from s2t_fhir._mapping_identity_base m;

-- T12 independent guidance target derivation (governance_guidance + GUIDANCE_SCOPE).
insert into _t020_result (test_name, passed, details)
select 'T12 GOVERNANCE_GUIDANCE target_element equals independent coalesce(raw, scope code)',
       count(*) > 0 and count(*) filter (where g.target_element is distinct from x.expected) = 0,
       'guidance rows=' || count(*) || ', mismatch=' || count(*) filter (where g.target_element is distinct from x.expected)
from (
  select bs.source_system, bs.fhir_resource, bv.baseline_code,
         'map-v' || substring(lmi.logical_key from 'v([0-9]+)') || '-' || substring(lmi.logical_key from '([0-9a-f]{64})$') as node_id,
         coalesce(nullif(btrim(gg.target_fhir_path_or_scope_raw), ''), gs.value_code) as expected
  from s2t_fhir.governance_guidance gg
  join s2t_fhir.mapping_record mr            on mr.mapping_record_id = gg.mapping_record_id
  join s2t_fhir.logical_mapping_identity lmi on lmi.logical_mapping_identity_id = mr.logical_mapping_identity_id
  join s2t_fhir.baseline_version bv          on bv.baseline_version_id = mr.baseline_version_id
  join s2t_fhir.baseline_series bs           on bs.baseline_series_id = bv.baseline_series_id
  join s2t_fhir.reference_value gs           on gs.reference_value_id = gg.guidance_scope_value_id
  join s2t_fhir.reference_domain gsd         on gsd.reference_domain_id = gs.reference_domain_id
                                            and gsd.domain_code = 'GUIDANCE_SCOPE'
) x
join s2t_fhir.mapping_resource_registry r
  on r.source_system = x.source_system and r.fhir_resource = x.fhir_resource and r.is_enabled
join s2t_fhir_api.governed_mapping_identity g
  on g.resource_config_id = r.resource_config_id and g.baseline_code = x.baseline_code
 and g.node_id = x.node_id and g.mapping_kind = 'GOVERNANCE_GUIDANCE';

-- ---------------------------------------------------------------------
-- 3. CATO-only parity (resource_config_id = 'medication-request-cato')
-- ---------------------------------------------------------------------
-- T13 row-set parity vs active_mapping_record (set equality on mapping_key + provenance).
create temp table _t020_ours on commit drop as
  select m.mapping_key, m.source_sheet, m.source_row::text as source_row, m.source_cell_range
  from s2t_fhir_api.governed_mapping_identity g
  join s2t_fhir.mapping_resource_registry r on r.resource_config_id = g.resource_config_id
  join s2t_fhir._mapping_identity_base m
    on m.source_system = r.source_system and m.fhir_resource = r.fhir_resource
   and m.baseline_code = g.baseline_code and m.node_id = g.node_id
  where g.resource_config_id = 'medication-request-cato' and g.is_active_baseline;
create temp table _t020_theirs on commit drop as
  select amr.mapping_key, amr.source_sheet, amr.source_row::text as source_row, amr.source_cell_range
  from s2t_fhir_api.active_mapping_record amr
  where amr.baseline_code in (
    select c.baseline_code from s2t_fhir_api._active_release_context c
    join s2t_fhir.mapping_resource_registry r using (source_system, fhir_resource)
    where r.resource_config_id = 'medication-request-cato');
insert into _t020_result (test_name, passed, details)
select 'T13 CATO active row set == active_mapping_record (mapping_key, sheet, row, cell range)',
       a.n = 0 and b.n = 0 and o.n > 0,
       'ours=' || o.n || ', theirs=' || t.n || ', only_ours=' || a.n || ', only_theirs=' || b.n
from (select count(*) n from _t020_ours) o,
     (select count(*) n from _t020_theirs) t,
     (select count(*) n from (select * from _t020_ours except all select * from _t020_theirs) e) a,
     (select count(*) n from (select * from _t020_theirs except all select * from _t020_ours) e) b;

-- T14 grouped parity by source_sheet.
insert into _t020_result (test_name, passed, details)
select 'T14 CATO grouped counts by source_sheet == active_mapping_record',
       count(*) filter (where o.n is distinct from t.n) = 0,
       coalesce(string_agg(coalesce(o.source_sheet, t.source_sheet) || ':' || coalesce(o.n, 0) || '/' || coalesce(t.n, 0), '; '), '')
from (select source_sheet, count(*) n from _t020_ours group by 1) o
full join (select source_sheet, count(*) n from _t020_theirs group by 1) t using (source_sheet);

-- T15 node_id + mapping_kind parity vs _lovable_mapping_node.
create temp table _t020_ui on commit drop as
  select n.* from s2t_fhir_api._lovable_mapping_node n
  where n.baseline_code in (
    select c.baseline_code from s2t_fhir_api._active_release_context c
    join s2t_fhir.mapping_resource_registry r using (source_system, fhir_resource)
    where r.resource_config_id = 'medication-request-cato');
create temp table _t020_cato on commit drop as
  select g.* from s2t_fhir_api.governed_mapping_identity g
  where g.resource_config_id = 'medication-request-cato' and g.is_active_baseline;
insert into _t020_result (test_name, passed, details)
select 'T15 CATO (node_id, mapping_kind) set == _lovable_mapping_node',
       a.n = 0 and b.n = 0,
       'only_ours=' || a.n || ', only_ui=' || b.n
from (select count(*) n from (select node_id, mapping_kind from _t020_cato except all select node_id, mapping_kind from _t020_ui) e) a,
     (select count(*) n from (select node_id, mapping_kind from _t020_ui except all select node_id, mapping_kind from _t020_cato) e) b;

-- T16 profile parity: profile_label == ui_profile (exact, no normalization added by the test).
insert into _t020_result (test_name, passed, details)
select 'T16 CATO profile_label == _lovable_mapping_node.ui_profile',
       count(*) > 0 and count(*) filter (where g.profile_label is distinct from u.ui_profile) = 0,
       'rows=' || count(*) || ', mismatch=' || count(*) filter (where g.profile_label is distinct from u.ui_profile)
from _t020_cato g join _t020_ui u using (node_id);

-- T17 parent identity parity: element_path[-2] == target of UI parent_mapping_key; roots NULL.
insert into _t020_result (test_name, passed, details)
select 'T17 CATO ELEMENT_MAPPING parent parity vs _lovable_mapping_node.parent_mapping_key',
       count(*) > 0 and count(*) filter (where
         (case when cardinality(g.element_path) >= 2 then g.element_path[cardinality(g.element_path) - 1] end)
         is distinct from p.target_fhir_path) = 0,
       'rows=' || count(*) || ', mismatch=' || count(*) filter (where
         (case when cardinality(g.element_path) >= 2 then g.element_path[cardinality(g.element_path) - 1] end)
         is distinct from p.target_fhir_path)
from _t020_cato g
join _t020_ui u using (node_id)
left join _t020_ui p on p.mapping_key = u.parent_mapping_key
where g.mapping_kind = 'ELEMENT_MAPPING';

-- T18 full root-first path parity via recursive walk of UI parent_mapping_key.
insert into _t020_result (test_name, passed, details)
with recursive ui_walk as (
  select u.node_id as origin, u.parent_mapping_key as next_key, array[u.target_fhir_path] as path_rev, 1 as depth
  from _t020_ui u where u.mapping_kind = 'ELEMENT_MAPPING'
  union all
  select w.origin, p.parent_mapping_key, w.path_rev || p.target_fhir_path, w.depth + 1
  from ui_walk w join _t020_ui p on p.mapping_key = w.next_key
  where w.next_key is not null and w.depth < 64
),
ui_path as (
  select distinct on (origin) origin as node_id,
         case when next_key is null
              then array(select x from unnest(path_rev) with ordinality t(x, o) order by o desc) end as path
  from ui_walk order by origin, depth desc
)
select 'T18 CATO ELEMENT_MAPPING element_path == UI root-first chain',
       count(*) > 0 and count(*) filter (where g.element_path is distinct from up.path) = 0,
       'rows=' || count(*) || ', mismatch=' || count(*) filter (where g.element_path is distinct from up.path)
from _t020_cato g full join ui_path up using (node_id)
where coalesce(g.mapping_kind, 'ELEMENT_MAPPING') = 'ELEMENT_MAPPING';

-- T19 bracket boundary coverage (informational pass if no bracketed targets exist).
insert into _t020_result (test_name, passed, details)
select 'T19 CATO bracket ''['' boundary: bracketed children attach to a parent when UI says so',
       bracketed = 0 or attached_ok,
       'bracketed targets=' || bracketed
from (
  select count(*) filter (where u.comparison_path ~ '\[') as bracketed,
         coalesce(bool_and(cardinality(g.element_path) >= 2) filter (where u.comparison_path ~ '\[' and u.parent_mapping_key is not null), true) as attached_ok
  from _t020_cato g join _t020_ui u using (node_id)
  where g.mapping_kind = 'ELEMENT_MAPPING') x;

-- ---------------------------------------------------------------------
-- 4. Security (Supabase roles; never skipped)
-- ---------------------------------------------------------------------
insert into _t020_result (test_name, passed, details)
select 'T20 roles s2t_fhir_owner/anon/authenticated exist',
       count(*) = 3, 'found=' || count(*)
from pg_roles where rolname in ('s2t_fhir_owner','anon','authenticated');

insert into _t020_result (test_name, passed, details)
select 'T21 no effective SELECT/INSERT/UPDATE/DELETE for anon/authenticated on 020 objects',
       count(*) filter (where has_table_privilege(role, obj, priv)) = 0,
       coalesce(string_agg(role || ':' || obj || ':' || priv, ', ') filter (where has_table_privilege(role, obj, priv)), 'none')
from unnest(array['anon','authenticated']) role,
     unnest(array['s2t_fhir.mapping_resource_registry','s2t_fhir._mapping_identity_base',
                  's2t_fhir_api.governed_mapping_identity']) obj,
     unnest(array['SELECT','INSERT','UPDATE','DELETE']) priv;

insert into _t020_result (test_name, passed, details)
select 'T22 020 objects owned by s2t_fhir_owner',
       count(*) = 3 and bool_and(pg_get_userbyid(relowner) = 's2t_fhir_owner'),
       string_agg(oid::regclass || '=' || pg_get_userbyid(relowner), ', ')
from pg_class
where oid in (to_regclass('s2t_fhir.mapping_resource_registry'), to_regclass('s2t_fhir._mapping_identity_base'),
              to_regclass('s2t_fhir_api.governed_mapping_identity'));

-- ---------------------------------------------------------------------
-- 5. Dependency checks
-- ---------------------------------------------------------------------
insert into _t020_result (test_name, passed, details)
select 'T23 production views do not depend on _lovable_mapping_node',
       count(*) = 0, 'deps=' || count(*)
from pg_depend d
join pg_rewrite rw on rw.oid = d.objid
where rw.ev_class in (to_regclass('s2t_fhir._mapping_identity_base'), to_regclass('s2t_fhir_api.governed_mapping_identity'))
  and d.refobjid = to_regclass('s2t_fhir_api._lovable_mapping_node');

insert into _t020_result (test_name, passed, details)
select 'T24 no _mapping_ref_value object exists',
       to_regclass('s2t_fhir._mapping_ref_value') is null and to_regclass('s2t_fhir_api._mapping_ref_value') is null, '';

-- ---------------------------------------------------------------------
-- 6. AFTER fingerprints (narrow: active read model + referenced base tables only)
-- ---------------------------------------------------------------------
insert into _t020_fp
select 'after', 'active_baseline',        md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api.active_baseline x
union all select 'after', 'active_mapping_record',  md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api.active_mapping_record x
union all select 'after', '_active_release_context', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api._active_release_context x
union all select 'after', '_lovable_mapping_node',  md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir_api._lovable_mapping_node x
union all select 'after', 'baseline_series',          md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.baseline_series x
union all select 'after', 'baseline_version',         md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.baseline_version x
union all select 'after', 'mapping_record',           md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.mapping_record x
union all select 'after', 'logical_mapping_identity', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.logical_mapping_identity x
union all select 'after', 'import_candidate_row',     md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.import_candidate_row x
union all select 'after', 'import_run',               md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.import_run x
union all select 'after', 'artifact',                 md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.artifact x
union all select 'after', 'artifact_sheet_manifest',  md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.artifact_sheet_manifest x
union all select 'after', 'element_mapping',          md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.element_mapping x
union all select 'after', 'status_mapping_rule',      md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.status_mapping_rule x
union all select 'after', 'governance_guidance',      md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.governance_guidance x
union all select 'after', 'reference_value',          md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.reference_value x
union all select 'after', 'reference_domain',         md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from s2t_fhir.reference_domain x;

insert into _t020_result (test_name, passed, details)
select 'T25 active read-model + referenced base-table fingerprints unchanged (narrow claim)',
       count(*) = 17 and bool_and(b.digest = a.digest),
       coalesce(string_agg(b.object, ', ') filter (where b.digest is distinct from a.digest), 'all equal')
from _t020_fp b join _t020_fp a on a.object = b.object and a.phase = 'after'
where b.phase = 'before';

reset role;

-- ---------------------------------------------------------------------
-- 7. Results, aggregate, ROLLBACK
-- ---------------------------------------------------------------------
-- Single result set (per-test rows followed by the aggregate) so the SQL Editor shows both.
select seq, test_name, result, details from (
  select seq, test_name, case when passed then 'PASS' else 'FAIL' end as result, details
  from _t020_result
  union all
  select 999999, 'AGGREGATE',
         case when bool_and(coalesce(passed, false)) then 'ALL PASS' else 'FAILURES PRESENT' end,
         'pass=' || count(*) filter (where passed) || ', fail=' || count(*) filter (where passed is not true)
  from _t020_result
) r order by seq;

rollback;

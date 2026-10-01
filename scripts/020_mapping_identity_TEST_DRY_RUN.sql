-- =====================================================================
-- 020_mapping_identity_TEST_DRY_RUN.sql — GOVERNED TEST ONLY.
-- Self-contained: installs the exact body of 020_mapping_identity_CANDIDATE.sql
-- inside one transaction, validates, and ALWAYS ends with ROLLBACK (no residue).
-- Every check fails closed with RAISE EXCEPTION 'FAIL …'.
-- Keep the inlined section byte-identical to the candidate (regenerate on change).
-- =====================================================================
begin;

-- 0. Fingerprint BEFORE (active baseline, active records, current nodes, active review state)
create temp table _fp_before on commit drop as
select 'baseline' k, md5(coalesce(string_agg(to_jsonb(b)::text, '' order by to_jsonb(b)::text), '')) v
  from s2t_fhir_api.active_baseline b
union all select 'records', md5(coalesce(string_agg(to_jsonb(r)::text, '' order by to_jsonb(r)::text), ''))
  from s2t_fhir_api.active_mapping_record r
union all select 'nodes', md5(coalesce(string_agg(to_jsonb(n)::text, '' order by to_jsonb(n)::text), ''))
  from s2t_fhir_api._lovable_mapping_node n
union all select 'review', md5(coalesce(string_agg(to_jsonb(s)::text, '' order by to_jsonb(s)::text), ''))
  from s2t_fhir_api.active_mapping_review_status s;

create temp table _trg_before on commit drop as
select count(*) n from pg_trigger where not tgisinternal;
create temp table _fn_before on commit drop as
select count(*) n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
where s.nspname in ('s2t_fhir','s2t_fhir_api');

-- ===================== BEGIN INLINED CANDIDATE BODY =====================
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
-- ====================== END INLINED CANDIDATE BODY ======================

do $$
declare n int;
begin
  -- 1. registry: exactly one enabled seed + uniqueness
  if (select count(*) from s2t_fhir.mapping_resource_registry) <> 1
  or (select count(*) from s2t_fhir.mapping_resource_registry where is_enabled) <> 1 then
    raise exception 'FAIL registry seed';
  end if;
  begin
    insert into s2t_fhir.mapping_resource_registry(resource_config_id, source_system, fhir_resource)
    select 'dup-test', source_system, fhir_resource from s2t_fhir.mapping_resource_registry limit 1;
    raise exception 'FAIL registry uniqueness';
  exception when unique_violation then null; end;

  -- 2. active counts
  select count(*) into n from s2t_fhir_api.governed_mapping_identity where is_active_baseline;
  if n <> 292 then raise exception 'FAIL active count %', n; end if;
  if n <> (select count(*) from s2t_fhir_api.active_mapping_record) then raise exception 'FAIL vs active_mapping_record'; end if;
  if (select count(*) from s2t_fhir_api.governed_mapping_identity where is_active_baseline and mapping_kind='ELEMENT_MAPPING') <> 237
  or (select count(*) from s2t_fhir_api.governed_mapping_identity where is_active_baseline and mapping_kind='STATUS_MAPPING_RULE') <> 9
  or (select count(*) from s2t_fhir_api.governed_mapping_identity where is_active_baseline and mapping_kind='GOVERNANCE_GUIDANCE') <> 46 then
    raise exception 'FAIL kind counts';
  end if;
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where is_active_baseline and baseline_code not in (select baseline_code from s2t_fhir_api.active_baseline)) then
    raise exception 'FAIL active baseline_code';
  end if;

  -- 3. key uniqueness + node_id shape (NULL rejected)
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             group by resource_config_id, baseline_code, node_id having count(*) > 1) then raise exception 'FAIL key uniqueness'; end if;
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where node_id is null or node_id !~ '^map-v[0-9]+-[0-9a-f]{64}$') then raise exception 'FAIL node_id shape'; end if;

  -- 4. exact node_id parity with _lovable_mapping_node (test-only read)
  if exists (
    (select node_id from s2t_fhir_api.governed_mapping_identity where is_active_baseline
     except select node_id from s2t_fhir_api._lovable_mapping_node)
    union all
    (select node_id from s2t_fhir_api._lovable_mapping_node
     except select node_id from s2t_fhir_api.governed_mapping_identity where is_active_baseline)) then
    raise exception 'FAIL node_id parity';
  end if;

  -- 5. target_element / element_path per kind
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity where target_element is null or btrim(target_element) = '') then
    raise exception 'FAIL target_element null';
  end if;
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where mapping_kind = 'ELEMENT_MAPPING'
               and (element_path is null
                 or element_path[array_length(element_path,1)] <> target_element
                 or array_length(element_path,1) <> (select count(distinct x) from unnest(element_path) x))) then
    raise exception 'FAIL element hierarchy (orphan/cycle/depth)';
  end if;
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where mapping_kind = 'STATUS_MAPPING_RULE'
               and (element_path is distinct from array[target_element] or array_length(element_path,1) <> 1)) then
    raise exception 'FAIL status element_path';
  end if;
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where mapping_kind = 'GOVERNANCE_GUIDANCE' and element_path is not null) then raise exception 'FAIL guidance element_path'; end if;

  -- 6a. ELEMENT_MAPPING path parity vs _lovable_mapping_node.parent_mapping_key chain
  if exists (
    with recursive ln as (
      select node_id, mapping_key, parent_mapping_key, target_fhir_path
      from s2t_fhir_api._lovable_mapping_node where mapping_kind = 'ELEMENT_MAPPING'
    ), ch as (
      select node_id as origin, parent_mapping_key as nxt, array[target_fhir_path] as rev, 1 as d from ln
      union all
      select ch.origin, ln.parent_mapping_key, ch.rev || ln.target_fhir_path, ch.d + 1
      from ch join ln on ln.mapping_key = ch.nxt where ch.d < 64
    ), ui as (
      select distinct on (origin) origin as node_id,
             array(select x from unnest(rev) with ordinality t(x,o) order by o desc) as ui_path
      from ch where nxt is null order by origin, d desc
    )
    select 1
    from (select node_id, element_path from s2t_fhir_api.governed_mapping_identity
          where is_active_baseline and mapping_kind = 'ELEMENT_MAPPING') g
    full join ui using (node_id)
    where g.element_path is distinct from ui.ui_path
  ) then raise exception 'FAIL element_path parity'; end if;

  -- 6b. bracket-boundary behavior
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where is_active_baseline and mapping_kind = 'ELEMENT_MAPPING' and target_element ~ '\[')
  and not exists (
    select 1 from s2t_fhir_api.governed_mapping_identity
    where is_active_baseline and mapping_kind = 'ELEMENT_MAPPING' and array_length(element_path,1) >= 2
      and left(regexp_replace(btrim(target_element), '\s+\[', '[', 'g'),
               length(regexp_replace(btrim(element_path[array_length(element_path,1)-1]), '\s+\[', '[', 'g')) + 1)
          = regexp_replace(btrim(element_path[array_length(element_path,1)-1]), '\s+\[', '[', 'g') || '[')
  then raise exception 'FAIL no [-boundary parent despite bracketed targets'; end if;
  raise notice 'bracketed active element targets: %',
    (select count(*) from s2t_fhir_api.governed_mapping_identity
     where is_active_baseline and mapping_kind = 'ELEMENT_MAPPING' and target_element ~ '\[');

  -- 6c. parent identity parity (tie-break length desc, mapping_key)
  if exists (
    select 1
    from (select node_id, element_path from s2t_fhir_api.governed_mapping_identity
          where is_active_baseline and mapping_kind = 'ELEMENT_MAPPING') g
    join s2t_fhir_api._lovable_mapping_node n on n.node_id = g.node_id
    left join s2t_fhir_api._lovable_mapping_node pn on pn.mapping_key = n.parent_mapping_key
    where (array_length(g.element_path,1) = 1) <> (n.parent_mapping_key is null)
       or (array_length(g.element_path,1) >= 2
           and g.element_path[array_length(g.element_path,1)-1] is distinct from pn.target_fhir_path)
  ) then raise exception 'FAIL parent identity parity'; end if;

  -- 7. active provenance parity
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity g
             where g.is_active_baseline
               and (g.version_label   is distinct from (select version_label   from s2t_fhir_api.active_baseline)
                 or g.artifact_sha256 is distinct from (select artifact_sha256 from s2t_fhir_api.active_baseline)
                 or g.artifact_sha256 !~ '^[0-9a-f]{64}$'
                 or g.source_sheet is null or g.source_row is null or g.source_row < 1)) then
    raise exception 'FAIL provenance';
  end if;
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity g
             join s2t_fhir_api._lovable_mapping_node n using (node_id)
             where g.is_active_baseline
               and (g.source_row is distinct from n.source_row
                 or g.source_cell_range is distinct from n.source_cell_range
                 or g.decision_status is distinct from n.decision_status
                 or g.target_element is distinct from case when g.mapping_kind = 'GOVERNANCE_GUIDANCE'
                                                           then g.target_element else n.target_fhir_path end)) then
    raise exception 'FAIL provenance/status parity';
  end if;

  -- 8. profile_label domain
  if exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where profile_label is not null and profile_label not in ('IL CORE','HDP','LOCAL'))
  or exists (select 1 from s2t_fhir_api.governed_mapping_identity
             where mapping_kind in ('STATUS_MAPPING_RULE','GOVERNANCE_GUIDANCE') and profile_label is distinct from 'LOCAL') then
    raise exception 'FAIL profile_label domain';
  end if;

  -- 9. no direct client grants
  if exists (select 1 from information_schema.role_table_grants
             where (table_schema, table_name) in (('s2t_fhir_api','governed_mapping_identity'),
                    ('s2t_fhir','_mapping_identity_base'), ('s2t_fhir','mapping_resource_registry'))
               and grantee in ('PUBLIC','anon','authenticated')) then
    raise exception 'FAIL client grants present';
  end if;
  if has_table_privilege('anon','s2t_fhir_api.governed_mapping_identity','select')
  or has_table_privilege('authenticated','s2t_fhir_api.governed_mapping_identity','select')
  or has_table_privilege('anon','s2t_fhir.mapping_resource_registry','select,insert,update,delete')
  or has_table_privilege('authenticated','s2t_fhir.mapping_resource_registry','select,insert,update,delete')
  or has_table_privilege('anon','s2t_fhir._mapping_identity_base','select')
  or has_table_privilege('authenticated','s2t_fhir._mapping_identity_base','select') then
    raise exception 'FAIL client privilege effective';
  end if;

  -- 10. no dependency on _lovable_mapping_node from production views
  if exists (select 1 from pg_depend d join pg_rewrite rw on rw.oid = d.objid
             where rw.ev_class in ('s2t_fhir_api.governed_mapping_identity'::regclass, 's2t_fhir._mapping_identity_base'::regclass)
               and d.refobjid = 's2t_fhir_api._lovable_mapping_node'::regclass) then
    raise exception 'FAIL _lovable_mapping_node dependency';
  end if;

  -- 11. no resource literals in production view definitions (seed row is data, not definition)
  if exists (select 1 from (values ('s2t_fhir_api.governed_mapping_identity'), ('s2t_fhir._mapping_identity_base')) x(v)
             where pg_get_viewdef(v::regclass, true) ~* '(''cato''|''medicationrequest''|medication-request-cato|chameleon|section_id|_mapping_ref_value)') then
    raise exception 'FAIL resource literal in view definition';
  end if;

  -- 12. no new triggers / functions (write paths)
  if (select count(*) from pg_trigger where not tgisinternal) <> (select n from _trg_before) then
    raise exception 'FAIL new trigger';
  end if;
  if (select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
      where s.nspname in ('s2t_fhir','s2t_fhir_api')) <> (select n from _fn_before) then
    raise exception 'FAIL new function';
  end if;

  -- 13. fingerprints unchanged
  if exists (
    select 1 from _fp_before b full join (
      select 'baseline' k, md5(coalesce(string_agg(to_jsonb(b)::text, '' order by to_jsonb(b)::text), '')) v
        from s2t_fhir_api.active_baseline b
      union all select 'records', md5(coalesce(string_agg(to_jsonb(r)::text, '' order by to_jsonb(r)::text), ''))
        from s2t_fhir_api.active_mapping_record r
      union all select 'nodes', md5(coalesce(string_agg(to_jsonb(n)::text, '' order by to_jsonb(n)::text), ''))
        from s2t_fhir_api._lovable_mapping_node n
      union all select 'review', md5(coalesce(string_agg(to_jsonb(s)::text, '' order by to_jsonb(s)::text), ''))
        from s2t_fhir_api.active_mapping_review_status s
    ) a using (k) where a.v is distinct from b.v) then
    raise exception 'FAIL fingerprint changed';
  end if;

  raise notice 'ALL 020 DRY-RUN CHECKS PASSED (rolling back)';
end $$;

-- Effective role check (belt and braces; raises if access is possible)
set local role anon;
do $$ begin
  begin perform 1 from s2t_fhir_api.governed_mapping_identity; raise exception 'FAIL anon view';
  exception when insufficient_privilege then null; end;
  begin perform 1 from s2t_fhir.mapping_resource_registry; raise exception 'FAIL anon registry';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role authenticated;
do $$ begin
  begin perform 1 from s2t_fhir_api.governed_mapping_identity; raise exception 'FAIL authenticated view';
  exception when insufficient_privilege then null; end;
  begin perform 1 from s2t_fhir.mapping_resource_registry; raise exception 'FAIL authenticated registry';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

rollback;

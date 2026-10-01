# Governed Read API DDL Review

## Scope

This review covers `supabase/migrations/013_governed_read_api.sql`. The migration has been statically reviewed only; no SQL was executed. Migrations 001-012, the Lovable project, the workbook, and governed runtime data are unchanged.

## Objects created

Private, ungranted implementation objects:

- `s2t_fhir_api._active_release_context`: security-barrier view containing internal join identifiers and the single eligible ACTIVE/PASSED/COMMITTED release context per baseline.
- `s2t_fhir_api._lovable_mapping_node`: security-barrier view translating accepted CATO MedicationRequest rows into deterministic UI nodes and parent identities.
- `s2t_fhir_api._build_lovable_children(text,text,text)`: private recursive JSON builder.

Public read objects:

- `s2t_fhir_api.active_baseline`: baseline, authoritative workbook, counts, validation, and release metadata without UUIDs.
- `s2t_fhir_api.active_mapping_record`: accepted active mappings with all three normalized subtype payloads flattened and full workbook/sheet/row/range provenance.
- `s2t_fhir_api.active_quarantine_item`: safe quarantined-row/finding detail without raw evidence or actor data.
- `s2t_fhir_api.active_quarantine_summary`: authoritative validation counts plus current quarantine-case/finding counts.
- `s2t_fhir_api.get_active_medication_request_cato()`: no-argument read-only JSON RPC returning the nested ResourceConfig-compatible document.

## Eligibility and fail-closed behavior

The private context requires all of the following in one joined graph:

- current non-superseded lifecycle projection is `BASELINE_LIFECYCLE_STATUS/ACTIVE`;
- artifact role is `ARTIFACT_ROLE/AUTHORITATIVE_SOURCE`;
- current release-gate projection uses that artifact/digest and is `RELEASE_GATE_OUTCOME/PASSED`;
- validation run is exactly the run referenced by the release evaluation and matches its ruleset, artifact, and digest;
- import run is exactly the validation-linked run, belongs to the same baseline/artifact, and is `IMPORT_RUN_STATUS/COMMITTED`;
- exactly one eligible current passed gate exists per baseline.

The RPC additionally requires exactly one eligible context for canonical `CATO/MedicationRequest`. Zero or multiple rows return SQL `NULL`. The node count must equal the validation run's `accepted_count`; malformed IDs, unknown translations, duplicate element paths, duplicate IDs, or incomplete recursive representation also return `NULL`.

`active_mapping_record` starts from that context and requires candidate disposition `CANDIDATE_DISPOSITION/ACCEPTED`, the exact linked import run, matching mapping-kind IDs, matching canonical source/resource, and exactly one correct subtype. Quarantined candidates therefore cannot enter the view or tree even if malformed data were introduced elsewhere.

## Grants and revokes

Reasserted:

- `PUBLIC`, `anon`, `authenticated`, and `service_role` have no schema/table/function access to `s2t_fhir`.
- `service_role` has no migration-013 grant and its `s2t_fhir_api` schema access is revoked.
- `PUBLIC` has no access to the API schema, views, or functions.
- restrictive owner default privileges remain in force for future API tables/views/functions.

Granted:

- `s2t_fhir_api_reader`: schema `USAGE`, `SELECT` on the four public views, and `EXECUTE` on the public RPC.
- `anon` and `authenticated`, when those roles exist: the same minimum schema/view/RPC privileges.
- No consumer receives access to either private view or the recursive helper.
- No consumer receives write, sequence, base-table, raw-evidence, or historical-baseline access.

The current Lovable shared-password flow is not a Supabase Auth database role, so browser PostgREST calls may use `anon`. The exposed contract is intentionally minimized for that role. A later Auth migration can revoke `anon` without changing the API shapes.

`s2t_fhir_api_reader` is not introduced or assumed by migration 013: migration 001 explicitly creates it as `NOINHERIT NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION`. It is the existing purpose-built API reader role, so creating another semantic reader role in migration 013 would be incorrect.

## Security rationale

All four public views use `security_barrier=true`. They retain normal owner-rights view behavior because `security_invoker=true` would require direct base-table grants to `anon`/`authenticated`, violating the core boundary. Security-barrier behavior prevents unsafe optimizer predicate pushdown; it is not treated as a substitute for grants.

The public JSON RPC and its recursive helper are `STABLE SECURITY DEFINER`. Definer rights are required because their callers intentionally cannot access private views or base tables. The risk is constrained as follows:

- the public RPC accepts no arguments;
- neither function uses dynamic SQL;
- both have `search_path = pg_catalog, s2t_fhir_api` and schema-qualified object references;
- the helper is not executable by API consumers;
- the public function returns only the reviewed JSON contract;
- `PUBLIC` execution is explicitly revoked;
- the RPC fails closed on ambiguous context or reconciliation/translation defects.

No artifact locations, principal/actor fields, UUIDs, `raw_source_row`, `evidence_json`, logical-key components, or historical/inactive baseline selectors are projected publicly.

## Database-to-Lovable mapping

### ResourceConfig

| Lovable field | Projection |
|---|---|
| `id` | Exact constant `medication-request-cato`, admitted only for canonical governed CATO/MedicationRequest context |
| `label` | `CATO MedicationRequest` |
| `description` | Governed ACTIVE mapping description |
| `icon` | Closed wire token `pill`; client adapter resolves the icon component |
| `sections` | Three deterministic mapping-kind sections |
| `crossReferences` | Empty JSON array |

### MappingSection

| Governed kind | Section ID | Icon token |
|---|---|---|
| `ELEMENT_MAPPING` | `medication-request-cato--element-mapping` | `list-tree` |
| `STATUS_MAPPING_RULE` | `medication-request-cato--status-mapping-rule` | `workflow` |
| `GOVERNANCE_GUIDANCE` | `medication-request-cato--governance-guidance` | `book-open` |

Each section also has a stable label/description and an `elements` array. Section order is the order above.

### MappingElement

| Lovable field | Database rule |
|---|---|
| `id` | Deterministic logical-key conversion described below |
| `targetElement` | Element/status target path; otherwise guidance raw target/scope then governed scope code |
| `cardinality` | Element `cardinality_raw`; empty string for subtype rows without cardinality |
| `profile` | Closed translation below |
| `sourceSystem` | Nonblank raw source system, otherwise canonical source system |
| `sourceField` | Source expression, source status, or decision topic by subtype |
| `fixedValue` | Element fixed value or status target value |
| `transformation` | Applicable subtype transformation; guidance text for guidance |
| `description` | Source business definition; guidance text for guidance |
| `bindingValueSet` | Element value-set binding |
| `notes` | Applicable subtype notes |
| `status` | Closed decision-state translation below |
| `children` | Recursive deterministic element hierarchy; omitted when empty |

Optional null properties are removed with `jsonb_strip_nulls`. Client-only target display normalization, alert filtering, statistics, and auto-valid badges are not generated by SQL.

## ID-generation rules

- Resource algorithm is resource-first/source-second kebab form. The admitted canonical tuple resolves to exactly `medication-request-cato`; the resource-specific RPC emits that stable ID.
- Section IDs are the resource ID plus `--` plus the governed mapping-kind slug listed above.
- Mapping identity comes from the governed logical key. The current schema constraint and all BL-001 records use `me:vN:<64 lowercase hex>` for every mapping kind.
- Node generation is nevertheless mapping-kind/prefix agnostic: it extracts the final `vN:` version marker and terminal 64-character lowercase hexadecimal digest without requiring `me:` (or any other leading prefix).
- Mapping node ID is `map-vN-<terminal 64 lowercase hex>` and must match `^map-v[0-9]+-[0-9a-f]{64}$`.
- IDs do not depend on source row order, labels, translated content, or arbitrary legacy slugs.
- The RPC rejects malformed IDs and requires the node count to equal the distinct-ID count.

Static BL-001 ID reconciliation after the prefix-agnostic correction:

| Mapping kind | Valid generated IDs |
|---|---:|
| `ELEMENT_MAPPING` | 237 |
| `STATUS_MAPPING_RULE` | 9 |
| `GOVERNANCE_GUIDANCE` | 46 |
| **Total** | **292** |

All 292 generated IDs are non-null, unique, and match `^map-v[0-9]+-[0-9a-f]{64}$`. Therefore the RPC cannot return `NULL` merely because a mapping kind uses a different leading logical-key prefix; only a missing/invalid terminal governed version-and-digest form fails closed.

## Hierarchy-generation rules

- Only `ELEMENT_MAPPING` nodes are nested. Status rules and guidance are roots in their own sections.
- Display paths are unchanged. A comparison path trims the value and removes whitespace immediately before `[`.
- A parent is an accepted element whose comparison path is a strict prefix followed by `.` or `[`. The longest candidate wins.
- This nests slices such as `category -> category[il-core] -> category[il-core].coding` without inventing a relationship between `medication[X]` and concrete choice paths.
- Strictly increasing path length prevents cycles. Duplicate comparison paths make the RPC return `NULL`.
- Roots and siblings sort by authoritative manifest sheet order, source row, source cell range, then stable ID.
- Recursive output is counted and must represent every accepted node exactly once. BL-001 must yield 292 nodes.

## Translation rules

Profile:

- `IL CORE` -> `IL CORE`
- `HDP` -> `HDP`
- `Ext: Medication Regimen HDP` -> `HDP`
- `LOCAL` -> `LOCAL`
- status/guidance rows without a profile column -> `LOCAL` as the UI compatibility bucket
- any other/missing element profile -> fail closed

Status, in precedence order:

- `DO NOT MAP` -> `unmapped`
- `OPEN` or `WIP` -> `pending`
- `N/A` -> `structural`
- `FINAL` element with nonblank fixed value -> `fixed`
- other `FINAL` -> `mapped`
- any other value -> fail closed

The UI status is not a replacement for governed validation and does not implement `AUTO VALID`.

## Verification queries

The migration includes commented verification SQL at its bottom. The required review set is summarized here.

```sql
select * from s2t_fhir_api.active_baseline;
-- One row; ACTIVE/PASSED; 293 candidates, 292 accepted, 1 quarantined.

select mapping_kind, count(*)
from s2t_fhir_api.active_mapping_record
group by mapping_kind order by mapping_kind;
-- 237 ELEMENT_MAPPING, 46 GOVERNANCE_GUIDANCE, 9 STATUS_MAPPING_RULE.

select count(*) from s2t_fhir_api.active_mapping_record;
-- 292.

select count(*)
from s2t_fhir_api.active_mapping_record
where source_sheet = 'S2T MedicationRequestCato'
  and source_row = 77 and source_cell_range = 'A77:Q77';
-- 0.

select count(*)
from s2t_fhir_api.active_mapping_record m
join s2t_fhir_api.active_quarantine_item q
  using (baseline_code, version_label, source_sheet, source_row, source_cell_range);
-- 0.

select s2t_fhir_api.get_active_medication_request_cato() ->> 'id';
-- medication-request-cato.
```

Recursive JSON shape/identity check:

```sql
with recursive nodes(node) as (
  select e.value
  from jsonb_array_elements(s2t_fhir_api.get_active_medication_request_cato() -> 'sections') s
  cross join lateral jsonb_array_elements(s.value -> 'elements') e
  union all
  select c.value
  from nodes n
  cross join lateral jsonb_array_elements(coalesce(n.node -> 'children', '[]'::jsonb)) c
)
select count(*) as represented,
       count(distinct node ->> 'id') as distinct_ids,
       bool_and((node ->> 'id') ~ '^map-v[0-9]+-[0-9a-f]{64}$') as ids_valid,
       bool_and(node ?& array['id','targetElement','cardinality','profile','status']) as shape_valid
from nodes;
-- represented = distinct_ids = 292; booleans true.
```

UTF-8 and repeatability:

```sql
select s2t_fhir_api.get_active_medication_request_cato()::text ~ '[א-ת]';
-- true.

select s2t_fhir_api.get_active_medication_request_cato()
     = s2t_fhir_api.get_active_medication_request_cato();
-- true in one snapshot; repeat across sessions for regression.
```

Column/grant checks:

```sql
select table_name, column_name
from information_schema.columns
where table_schema = 's2t_fhir_api'
  and table_name in ('active_baseline','active_mapping_record',
                     'active_quarantine_item','active_quarantine_summary')
  and (column_name like '%\_id' escape '\'
       or column_name in ('raw_source_row','evidence_json',
                          'actor_principal_id','initiating_human_principal_id'));
-- No rows.

select grantee, table_schema, table_name, privilege_type
from information_schema.role_table_grants
where table_schema in ('s2t_fhir','s2t_fhir_api')
  and grantee in ('anon','authenticated','service_role')
order by grantee, table_schema, table_name, privilege_type;
-- No s2t_fhir grants; only intended public-view SELECT grants in s2t_fhir_api.
```

Role tests must prove API SELECT/RPC success and base-table failure for `anon`/`authenticated`, API-reader success, and no migration-013 access for `service_role`. Rollback-only lifecycle/gate/import tests must prove the public views/RPC disappear or return `NULL` when ACTIVE, PASSED, COMMITTED, exact linkage, or uniqueness is violated.

## Static review findings

- Invalid references: all referenced tables, columns, internal projection views, controlled domains, and subtype columns exist in migrations 001-012.
- Base exposure: no grant targets `s2t_fhir`; revocations are reasserted before object creation.
- Definer risk: limited to two fixed-search-path, no-dynamic-SQL, read-only functions; the helper is private and the public RPC has no arguments.
- Recursion: parent paths are strict shorter prefixes; duplicate paths and incomplete recursive counts fail closed.
- Duplicates: logical IDs are checked for uniqueness and JSON represented count must equal accepted count.
- Quarantine leakage: active mappings require `ACCEPTED` from the exact linked import; explicit overlap verification is included.

## Residual risks

- PostgREST must expose `s2t_fhir_api` and keep `s2t_fhir` unexposed; this is project configuration outside SQL migration 013.
- Owner-rights view and function behavior must be confirmed with the supplied role tests in the target Supabase PostgreSQL version.
- The UI icon tokens require the approved small adapter because JSON cannot serialize React component values.
- Deep future FHIR paths increase recursive calls; BL-001 depth/size is small, and runtime tests should still record response time and payload size.
- The explicit legacy fallback/localStorage isolation remains application work and is intentionally not performed by this migration.

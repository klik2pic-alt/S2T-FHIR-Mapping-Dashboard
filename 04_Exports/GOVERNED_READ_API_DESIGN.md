# Governed Read API Design

## 1. Status and scope

This document proposes the minimum read-only contract for the existing Lovable dashboard to display the governed, currently ACTIVE baseline. It is the design input for a future migration named `013_governed_read_api.sql`.

No SQL has been executed. Migrations `001` through `012` and the Lovable application are unchanged.

The design is based on the checked-in migrations, BL-001 runtime/import evidence, `LOVABLE_AUDIT_V1.md`, and the completed live-project source-contract audit supplied on 2026-09-26. The verified runtime types are `ResourceConfig -> MappingSection[] -> MappingElement[]`, with explicit nested `children`. The existing CATO resource ID is `medication-request-cato`; `MappingElement.id` is functionally significant for React keys, alerts, reveal/scroll behavior, and feature hooks.

## 2. Design conclusions

- `s2t_fhir` remains the governed storage schema and is never exposed directly to Lovable.
- `s2t_fhir_api` is the only PostgREST-facing schema for this feature.
- Default API objects expose only baselines whose **current non-superseded lifecycle projection is `ACTIVE`**.
- Rows are additionally bound to the import/validation run referenced by the baseline's current release-gate evaluation. This prevents a stale, failed, or unrelated import from leaking into an ACTIVE baseline response.
- The mapping view contains accepted `mapping_record` rows only and independently requires candidate disposition `ACCEPTED`. Quarantined candidates therefore cannot enter it.
- Mapping subtypes are flattened into one wide, discriminator-based view. Common provenance and governance fields are always populated; subtype fields are nullable outside their applicable kind.
- A no-argument, read-only JSON RPC projects those relational rows into the nested Lovable wire contract. The relational views remain the inspection, reconciliation, and diagnostic contract.
- No internal UUID, principal/actor data, raw source-row JSON, evidence JSON, artifact location URI, or historical baseline is exposed.
- SHA-256 byte values are rendered as lowercase hexadecimal text.
- Hebrew and other source text remains PostgreSQL `text` and must be returned as UTF-8 JSON without transliteration or normalization.
- The JSON projection fails closed unless exactly one current ACTIVE/PASSED/COMMITTED CATO MedicationRequest context is eligible.

## 3. Proposed API objects

### 3.1 `s2t_fhir_api.active_baseline`

Purpose: one metadata row per currently ACTIVE governed baseline series/resource. BL-001 currently yields one row.

| Column | Type | Source/derivation |
|---|---|---|
| `baseline_code` | text | `baseline_version.baseline_code` |
| `version_label` | text | `baseline_version.version_label` |
| `source_system` | text | `baseline_series.source_system` |
| `fhir_resource` | text | `baseline_series.fhir_resource` |
| `lifecycle_status` | text | lifecycle reference value code; fixed by filter to `ACTIVE` |
| `lifecycle_effective_at` | timestamptz | current lifecycle event `occurred_at` |
| `artifact_filename` | text | authoritative `artifact.physical_filename` |
| `artifact_original_name` | text, nullable | `artifact.original_or_upload_name` |
| `artifact_sha256` | text | `encode(artifact.sha256_digest, 'hex')` |
| `artifact_captured_at` | timestamptz | `artifact.captured_at` |
| `import_completed_at` | timestamptz | committed import run `completed_at` |
| `candidate_count` | bigint | release-linked `validation_run.candidate_count` |
| `accepted_count` | bigint | release-linked `validation_run.accepted_count` |
| `warning_count` | bigint | release-linked `validation_run.warning_count` |
| `error_count` | bigint | release-linked `validation_run.error_count` |
| `quarantined_count` | bigint | release-linked `validation_run.quarantined_count` |
| `validation_outcome` | text | validation outcome reference value code |
| `release_gate_code` | text | `release_gate_definition.gate_code` |
| `release_gate_version` | text | release gate definition version label |
| `release_gate_outcome` | text | current release-gate outcome reference value code |
| `release_gate_evaluated_at` | timestamptz | current release-gate evaluation timestamp |

Source graph:

`baseline_series -> baseline_version -> current_baseline_lifecycle_event -> baseline_artifact -> artifact`, plus `current_release_gate_evaluation -> release_gate_definition -> validation_run -> import_run`, and controlled-value joins to `reference_value`.

Filtering and cardinality rules:

1. Join `s2t_fhir.current_baseline_lifecycle_event` and require its controlled value domain to be `BASELINE_LIFECYCLE_STATUS` and code `ACTIVE`.
2. Join only a `baseline_artifact` whose role domain/code is `ARTIFACT_ROLE/AUTHORITATIVE_SOURCE`.
3. Join `s2t_fhir.current_release_gate_evaluation` for the same baseline and authoritative artifact.
4. Require the gate controlled value domain to be `RELEASE_GATE_OUTCOME`; for the default governed endpoint require code `PASSED`. An ACTIVE-but-no-longer-passed inconsistency should disappear from the default endpoint and fail verification rather than serving potentially invalid governed data.
5. Require the referenced `validation_run` to match the evaluation, artifact, and digest, and its `import_run` to match the baseline and artifact.
6. Require import terminal status domain/code `IMPORT_RUN_STATUS/COMMITTED`.
7. Require exactly one eligible current passed release-gate evaluation for the baseline. Zero or multiple eligible evaluations expose no default active row. Do not select among ambiguous gates by recency.

### 3.2 `s2t_fhir_api.active_mapping_record`

Purpose: authoritative mapping rows for the currently ACTIVE and release-passed baseline only. The view is deliberately wide so Lovable can use one endpoint and switch on `mapping_kind`.

#### Common identity, status, and provenance columns

| Column | Type | Source/derivation |
|---|---|---|
| `mapping_key` | text | `logical_mapping_identity.logical_key`; stable non-UUID UI row key |
| `mapping_kind` | text | mapping-kind reference code |
| `decision_status` | text | decision-status reference code |
| `baseline_code` | text | active baseline projection |
| `version_label` | text | active baseline projection |
| `workbook_filename` | text | authoritative artifact filename |
| `workbook_sha256` | text | lowercase hexadecimal authoritative digest |
| `source_sheet` | text | `import_candidate_row.source_sheet_name` |
| `source_row` | integer | `import_candidate_row.source_row_number` |
| `source_cell_range` | text | `import_candidate_row.source_cell_range` |
| `source_system` | text | canonical `logical_mapping_identity.source_system` |
| `fhir_resource` | text | canonical `logical_mapping_identity.fhir_resource` |

`mapping_key` is included because React/table clients need a stable key and because it is a governed semantic identity, not an internal database UUID. It must not be used as a secret.

#### `ELEMENT_MAPPING` columns

| Column | Type |
|---|---|
| `source_system_raw` | text, nullable |
| `interface_type` | text, nullable |
| `interface_name` | text, nullable |
| `source_expression` | text, nullable |
| `target_fhir_path` | text, nullable outside applicable kinds |
| `profile_context` | text, nullable |
| `fixed_value` | text, nullable |
| `transformation_rule` | text, nullable |
| `source_business_definition` | text, nullable |
| `cardinality_raw` | text, nullable |
| `cardinality_min` | integer, nullable |
| `cardinality_max` | integer, nullable |
| `cardinality_max_unbounded` | boolean, nullable |
| `valueset_binding` | text, nullable |
| `mandated_code_system` | text, nullable |
| `irrelevant_under_s2t_raw` | text, nullable |
| `example_value` | text, nullable |
| `exception_handling` | text, nullable |
| `notes` | text, nullable |

#### `STATUS_MAPPING_RULE` columns

| Column | Type |
|---|---|
| `source_status_value` | text, nullable |
| `target_status_value` | text, nullable |
| `source_sequence` | integer, nullable |
| `status_source_business_definition` | text, nullable |
| `related_resource_note` | text, nullable |
| `status_transformation_rule` | text, nullable |
| `mapping_evidence_status_raw` | text, nullable |
| `status_notes` | text, nullable |

For this kind, common `target_fhir_path` is populated from `status_mapping_rule.target_fhir_path`. Keeping subtype-specific transformation/notes names prevents ambiguous `coalesce` behavior and loss of meaning.

#### `GOVERNANCE_GUIDANCE` columns

| Column | Type | Source/derivation |
|---|---|---|
| `guidance_scope` | text, nullable | guidance-scope reference code |
| `guidance_scope_display` | text, nullable | guidance-scope display name |
| `decision_topic` | text, nullable | decision-topic reference code |
| `decision_topic_display` | text, nullable | decision-topic display name |
| `guidance_text` | text, nullable | subtype payload |
| `guidance_status_raw` | text, nullable | subtype payload |
| `target_fhir_path_or_scope_raw` | text, nullable | subtype payload |
| `decision_topic_raw` | text, nullable | subtype payload |
| `guidance_notes` | text, nullable | subtype payload |
| `review_notes` | text, nullable | subtype payload |

Source graph and flattening:

- Begin from the internally composed active-baseline/release/import relation used by `active_baseline`.
- Join `mapping_record` by baseline.
- Join `import_candidate_row` both by `mapping_record.import_candidate_row_id` and by the exact release-linked `import_run_id`.
- Join `logical_mapping_identity` and controlled values.
- Left join all three subtype tables by `mapping_record_id`.
- The existing deferred integrity trigger guarantees exactly one matching subtype. The view should additionally filter each kind to its corresponding non-null subtype row so malformed rows fail closed.

Required filters:

1. Current lifecycle is `ACTIVE`.
2. Current release gate is `PASSED`.
3. Import is `COMMITTED` and is the import referenced through the release-linked validation run.
4. Candidate disposition domain/code is `CANDIDATE_DISPOSITION/ACCEPTED`.
5. Candidate, mapping record, and logical identity mapping-kind IDs all match.
6. Mapping and logical identity belong to the same canonical source system/FHIR resource as the active baseline series.
7. Exactly the subtype matching `mapping_kind` is present.

The view must not project `raw_source_row`, `logical_key_components_json`, hashes other than the public artifact SHA-256, or any UUID.

Expected BL-001 result: 292 rows: 237 element mappings, 9 status rules, and 46 governance guidance rows. The quarantined candidate at `S2T MedicationRequestCato!77`, range `A77:Q77`, cannot appear because it has no `mapping_record` and the view also explicitly requires disposition `ACCEPTED`.

### 3.3 `s2t_fhir_api.active_quarantine_item`

Purpose: safe, transparent detail for excluded candidates associated with the exact import/validation run serving the ACTIVE baseline. One row is emitted per candidate/finding association; this avoids hiding multiple findings behind aggregation.

| Column | Type | Source/derivation |
|---|---|---|
| `baseline_code` | text | active baseline projection |
| `version_label` | text | active baseline projection |
| `workbook_filename` | text | authoritative artifact filename |
| `workbook_sha256` | text | lowercase hexadecimal digest |
| `mapping_kind` | text | candidate mapping-kind code |
| `source_sheet` | text | candidate provenance |
| `source_row` | integer | candidate provenance |
| `source_cell_range` | text | candidate provenance |
| `finding_code` | text | `validation_finding.finding_code` |
| `severity` | text | severity reference code |
| `message` | text | validation finding message |
| `finding_row_role` | text | finding-row-role reference code |
| `quarantine_opened_at` | timestamptz | quarantine case |
| `quarantine_status` | text | latest non-superseded quarantine-event type code |
| `resolution_code` | text, nullable | latest event resolution controlled-value code |
| `resolution_reason` | text, nullable | latest event reason |

Filtering rules:

- Use the same ACTIVE/PASSED/COMMITTED release-linked import context as the mapping view.
- Require candidate disposition `QUARANTINED`.
- Require finding rows to belong to the exact release-linked `validation_run` and candidate.
- Require a matching `quarantine_case`.
- Derive the current quarantine event by excluding events superseded by another event and ranking remaining events per case by `occurred_at`, `recorded_at`, then UUID internally.
- Do not expose raw source rows, finding evidence JSON, fingerprints, principals, governance action IDs, replacement baseline UUIDs, or case/event/finding UUIDs.

### 3.4 `s2t_fhir_api.active_quarantine_summary`

Purpose: a compact validation/quarantine banner and reconciliation endpoint. It aggregates `active_quarantine_item` but obtains authoritative totals from the release-linked validation run.

| Column | Type |
|---|---|
| `baseline_code` | text |
| `version_label` | text |
| `candidate_count` | bigint |
| `accepted_count` | bigint |
| `quarantined_count` | bigint |
| `warning_count` | bigint |
| `error_count` | bigint |
| `validation_outcome` | text |
| `open_quarantine_count` | bigint |
| `resolved_quarantine_count` | bigint |
| `quarantine_finding_count` | bigint |

The first five counts and validation outcome come from `validation_run`, not from UI-side recounting. Case/finding counts are calculated from safe detail rows using internal IDs before projection so repeated findings do not inflate candidate counts. For BL-001, `candidate_count = 293`, `accepted_count = 292`, and `quarantined_count = 1`.

### 3.5 `s2t_fhir_api.get_active_medication_request_cato()`

Purpose: a no-argument, read-only RPC returning one `jsonb` document suitable for adaptation into the existing Lovable `ResourceConfig` type. It is the application endpoint; it does not replace the relational views.

The function returns SQL `NULL` (and PostgREST JSON `null`) unless the private active context resolves to **exactly one** row for canonical `source_system = 'CATO'` and `fhir_resource = 'MedicationRequest'`. The eligible context must already satisfy current lifecycle `ACTIVE`, current release gate `PASSED`, release-linked validation/import identity, and terminal import status `COMMITTED`. Multiple eligible current gates or baselines fail closed rather than selecting one by recency.

Wire document:

```json
{
  "id": "medication-request-cato",
  "label": "CATO MedicationRequest",
  "description": "Governed ACTIVE CATO to FHIR MedicationRequest mapping",
  "icon": "pill",
  "sections": [
    {
      "id": "medication-request-cato--element-mapping",
      "label": "Element mappings",
      "icon": "list-tree",
      "description": "Governed element mappings",
      "elements": []
    }
  ],
  "crossReferences": []
}
```

JSON cannot carry a React/Lucide component value. Therefore `icon` is a closed string token on the wire (`pill`, `list-tree`, `workflow`, `book-open`); a small application adapter resolves it to the existing component value. Apart from icon resolution, the returned keys match `ResourceConfig`, `MappingSection`, and `MappingElement`. Unknown icon tokens must fail to a neutral icon, never to mapping data fallback.

Each JSON mapping node contains exactly the verified `MappingElement` keys:

```text
id, targetElement, cardinality, profile, sourceSystem?, sourceField?,
fixedValue?, transformation?, description?, bindingValueSet?, notes?,
status?, children?
```

Null optional database values are omitted with `jsonb_strip_nulls`. `children` is emitted only when non-empty. `cardinality` is an empty string for status rules and guidance because the existing UI requires a string and those governed kinds have no cardinality. Subtype identity is preserved through deterministic sections and descriptive fields; the relational endpoint remains the lossless subtype contract.

#### Deterministic resource and section rules

- Resource identity algorithm: `kebab(fhir_resource) || '-' || kebab(source_system)`, with resource first and source second. `kebab` splits ASCII camel case, replaces non-alphanumeric runs with one hyphen, lowercases, and trims hyphens. For the governed tuple `MedicationRequest/CATO`, the required result is exactly `medication-request-cato`.
- The RPC is deliberately resource-specific. It asserts the computed ID equals `medication-request-cato`; a mismatch returns `NULL`.
- Sections are fixed by governed `mapping_kind`, not legacy UI slugs, in this order:
  1. `ELEMENT_MAPPING` -> `medication-request-cato--element-mapping`
  2. `STATUS_MAPPING_RULE` -> `medication-request-cato--status-mapping-rule`
  3. `GOVERNANCE_GUIDANCE` -> `medication-request-cato--governance-guidance`
- Section labels/descriptions and icon tokens are API presentation constants versioned by migration 013. They do not alter governed mapping content.

#### Stable mapping-element IDs

- Use the governed `logical_mapping_identity.logical_key`, exposed relationally as `mapping_key`, which has format `me:vN:<64-lowercase-hex>`.
- JSON node ID is `map-<version>-<hex>`, for example `me:v1:abc...` becomes `map-v1-abc...`.
- The conversion is total only for the governed logical-key format; malformed keys make the RPC fail closed.
- A unique constraint already protects the logical identity, and the RPC verifies `count(*) = count(distinct id)` before producing JSON.
- IDs do not depend on row order, labels, translated text, or mutable UI slugs. They remain stable across reads and across a later baseline when the governed logical identity remains the same.
- Existing hardcoded ID-specific hooks are not authoritative. During application migration they must be changed to the new governed IDs or semantic predicates. No undocumented legacy ID alias is generated by SQL.

#### Mapping of governed rows to `MappingElement`

| UI field | Governed projection |
|---|---|
| `id` | stable rule above |
| `targetElement` | element/status `target_fhir_path`; guidance `target_fhir_path_or_scope_raw`, otherwise `guidance_scope` |
| `cardinality` | `cardinality_raw`; empty string for non-element kinds |
| `profile` | translation below |
| `sourceSystem` | `source_system_raw` when nonblank, otherwise canonical `source_system` |
| `sourceField` | element `source_expression`; status `source_status_value`; guidance `decision_topic_raw`, otherwise `decision_topic` |
| `fixedValue` | element `fixed_value`; status `target_status_value`; omitted for guidance |
| `transformation` | element `transformation_rule`; status `status_transformation_rule`; guidance `guidance_text` |
| `description` | element `source_business_definition`; status `status_source_business_definition`; guidance `guidance_text` |
| `bindingValueSet` | element `valueset_binding`; omitted otherwise |
| `notes` | the applicable subtype notes, with other governed subtype context retained in the relational view |
| `status` | deterministic translation below |
| `children` | deterministic hierarchy below |

No client-side automatic-validity badge is generated by the database. The RPC's `status` is a presentation translation of governed decision state, not a validation result or implementation claim.

#### UI status translation

Apply in this exact precedence order:

1. `decision_status = 'DO NOT MAP'` -> `unmapped`.
2. `decision_status in ('OPEN', 'WIP')` -> `pending`.
3. `decision_status = 'N/A'` -> `structural`.
4. `decision_status = 'FINAL'` and mapping kind is `ELEMENT_MAPPING` and `fixed_value` is nonblank -> `fixed`.
5. `decision_status = 'FINAL'` -> `mapped`.
6. Any unknown value makes the RPC fail closed; it is never coerced to a UI status.

This translation does not recreate the legacy `AUTO VALID` behavior. Validation alerts continue to use their own client logic and stable IDs.

#### UI profile translation

Apply a closed mapping:

- `profile_context = 'IL CORE'` -> `IL CORE`.
- `profile_context = 'HDP'` -> `HDP`.
- `profile_context = 'Ext: Medication Regimen HDP'` -> `HDP`.
- `profile_context = 'LOCAL'` -> `LOCAL`.
- Status-rule and governance-guidance nodes, which have no profile column, -> `LOCAL` as the existing UI's neutral compatibility bucket. Their kind, governed scope, and topic remain available in the relational view; `LOCAL` must not be interpreted as a governance reclassification.
- Any other non-null element profile makes the RPC fail closed rather than inventing a category.

#### Parent/child nesting

- Only `ELEMENT_MAPPING` nodes are nested. Status rules and governance guidance remain ordered root nodes in their respective sections.
- Preserve `targetElement` exactly for display. Compute a separate comparison path by trimming and removing whitespace immediately before `[`; do not alter bracket contents or Hebrew/source text.
- A candidate parent is another accepted element whose comparison path is a strict FHIR-path ancestor: the child begins with `parent || '.'`, or the child is a slice of the parent and begins with `parent || '['`.
- Select the candidate with the longest comparison path. If none exists, the node is a section root. This permits `category -> category[il-core] -> category[il-core].coding` while avoiding inference that `medication[X]` is the parent of `medicationCodeableConcept` or `medicationReference`.
- Detect and reject cycles, duplicate comparison paths, duplicate IDs, and a node assigned more than once.
- Sibling/root order is deterministic: source sheet order from `artifact_sheet_manifest.sheet_order`, then `source_row`, `source_cell_range`, then stable node ID. Children use the same ordering.
- Every accepted row appears exactly once in the document, either as a root or descendant. For BL-001 the recursive count across all three sections must be 292.

Quarantined candidates cannot enter the tree because the RPC consumes `active_mapping_record`, which requires `ACCEPTED`, and additionally reconciles the recursive node count to the release-linked `accepted_count`.

## 4. SQL object form recommendation

Use a combination: ordinary PostgreSQL diagnostic views in `s2t_fhir_api`, all declared with `security_barrier = true`, plus the single JSON RPC `get_active_medication_request_cato()` for the nested application document. Keep the existing internal projection views in `s2t_fhir` inaccessible to web roles.

Important distinction: `security_barrier` constrains optimizer predicate pushdown; it does **not** grant access and is not a substitute for RLS. Conversely, `security_invoker = true` would require the calling `anon`/`authenticated` role to hold privileges on `s2t_fhir` base objects, directly conflicting with the boundary requirement. Therefore the proposed API views should use the normal owner-rights view behavior, be owned by `s2t_fhir_owner`, contain only fixed fail-closed filters, and expose only explicitly projected columns.

The verified Lovable contract requires explicit nesting, so a flat view is not a sufficient direct application response. A JSON-producing view could return one `jsonb` column, but it would still need recursive aggregation and would expose a relation whose single-row cardinality is less explicit through PostgREST. A no-argument RPC is preferred for the application document: it gives a single atomic result, can enforce exactly-one active context and reconciliation checks, and keeps historical selection impossible. The function must be `STABLE`, `SECURITY DEFINER`, owned by `s2t_fhir_owner`, have a fixed safe `search_path` (`pg_catalog, s2t_fhir_api`), use schema-qualified references, accept no arguments, and have `EXECUTE` revoked from `PUBLIC` before exact grants. It performs no writes and returns only `jsonb`. Historical access must be a separately reviewed object, never a parameter added to this function.

To avoid repeating the complex active-release context, migration 013 may create one **private helper view** in `s2t_fhir_api`, for example `_active_release_context`, with `security_barrier = true`. Revoke all on it from all web roles and grant no direct access. Public views and the RPC may join it under owner-rights semantics. If PostgREST exposes metadata for underscore-prefixed objects, lack of `SELECT` still makes it inaccessible; alternatively place the helper in `s2t_fhir` and grant it only to the owner. No helper columns are part of the public contract.

## 5. Security model and PostgREST/Supabase implications

### Exposed schemas

- Add `s2t_fhir_api` to the Supabase API exposed-schema configuration before Lovable integration. Merely creating the schema does not make it reachable through PostgREST.
- Do not add `s2t_fhir` to exposed schemas.
- Keep `public` behavior unrelated to this design; no compatibility tables or forwarding views should be created there.

### Grants

Migration 013 should be explicit and idempotent in intent:

- Preserve all migration-011 revocations on `s2t_fhir` for `anon`, `authenticated`, and `service_role`.
- Grant `USAGE` on `s2t_fhir_api` to `anon`, `authenticated`, and the existing `s2t_fhir_api_reader`. The current shared-password flow is not a Supabase Auth session, so browser PostgREST access otherwise runs as `anon`; granting only `authenticated` would not implement the verified loading path.
- Grant `SELECT` only on the four named public views, not on all current/future tables or views in the schema, and grant `EXECUTE` only on `get_active_medication_request_cato()`.
- Grant no `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, sequence privilege, or function `EXECUTE` to web roles.
- Preserve default-privilege revocations so future API objects are not accidentally exposed.
- Grant `SELECT` on the public views to `s2t_fhir_api_reader`; this keeps the designed database role useful for non-PostgREST consumers.

The shared-password gate is not treated as database authorization. Migration 013 therefore exposes only the deliberately minimized, read-only API contract to `anon`/`authenticated`; it does not expose evidence blobs or base data. If a later release introduces Supabase Auth, the `anon` grants can be revoked in a separate reviewed migration without changing the contract.

### `service_role`

`service_role` remains blocked from direct `s2t_fhir` access and receives no migration-013 grant by default. Supabase's service role commonly bypasses RLS, so granting it base-table access would enlarge the blast radius and undermine the curated boundary. If a trusted server/Edge Function later needs reads, grant it only the curated API views/RPC in a separate reviewed migration, or preferably have it assume/use `s2t_fhir_api_reader` where supported.

### RLS

RLS is not the primary control for owner-rights projection views. Column minimization, immutable filters, schema isolation, and exact grants are the controls. Do not create permissive RLS policies on base tables for Lovable. If PostgreSQL/Supabase version behavior differs from the assumed view semantics, validate with role-based tests before exposure.

## 6. Provenance behavior

Every active mapping and quarantine detail row carries:

- immutable authoritative workbook filename;
- authoritative workbook SHA-256;
- exact source sheet name, including Hebrew text;
- one-based workbook row number;
- exact workbook cell range.

This is sufficient to trace a displayed record to its authoritative source without exposing the unrestricted `raw_source_row` JSON. The artifact digest, not an artifact location, is the durable content identity. UI copy/export must preserve these values verbatim. The UI must not reconstruct or infer provenance from display order.

## 7. Lovable migration impact

No Lovable changes belong in migration 013. A later application change should:

1. Call `get_active_medication_request_cato()` and resolve its closed icon tokens to the existing icon components.
2. Preserve the exact resource ID `medication-request-cato`, the returned stable node IDs, and the returned `children`; do not rebuild identity or hierarchy client-side.
3. Keep the current mapping table, stats, legend, validation, and sidebar components. Their data source becomes the RPC result; stats may continue to be calculated recursively from the returned section tree.
4. Keep CATO target-path normalization and alert filtering as presentation behavior. Remove or clearly separate automatic-validity badges that could be mistaken for governed validation/decision state; database status translation is not an `AUTO VALID` assertion.
5. Fetch relational metadata/quarantine views for provenance, baseline banner, and transparent excluded-row detail as needed.
6. Display baseline code/version, lifecycle, artifact digest, validation outcome, release-gate outcome, and provenance in the UI or an accessible details panel.
7. Treat an empty/null RPC response as “no governed ACTIVE baseline available.” During the explicitly time-bounded transition only, the legacy fallback may be selected with a visible `LEGACY / NON-AUTHORITATIVE` marker; it must never be silently merged with governed data.

The API retains all currently evidenced UI-relevant fields: source/interface/expression, target path, cardinality, value-set/code-system data, fixed values, transformations, notes, decision status, validation counts, and subtype-specific content. The JSON RPC intentionally selects the narrower existing `ResourceConfig` shape; the relational views preserve the additional governed fields.

### `sectionOverrides` and localStorage

The governed resource must not pass through the existing `sectionOverrides` merge path.

- Namespace local state by authority and baseline, for example `legacy:<resource-id>` versus `governed:<baseline-code>:<artifact-sha256>`.
- On first successful governed load, ignore all existing unnamespaced/legacy overrides for `medication-request-cato`. Do not automatically migrate them into the governed namespace because they are ungoverned changes.
- The governed resource configuration and sections are immutable in client state. UI preferences that do not change mapping content (expanded rows, selected tab, column visibility) may persist under the governed namespace.
- If the product later needs editable overrides, they require a separate, visibly non-authoritative draft layer and must never affect governed counts, validation alerts, exports, or provenance.
- Add a regression test that pre-populated legacy `sectionOverrides` cannot change any field, node, count, or hierarchy returned for an ACTIVE governed baseline.

## 8. Legacy hardcoded mapping retirement

The legacy `medicationRequestCatoMapping.ts`, demo mappings, localStorage imports, and CATO-specific scenario content must never be merged with governed API results. The hardcoded mapping may remain only as the explicit, visibly non-authoritative transition fallback described below; it is never authoritative and is never used when a governed response passes validation.

Recommended later application sequence:

1. Add the governed RPC client/adapter behind a temporary feature flag while retaining `src/data/medicationRequestCatoMapping.ts` as an explicit transition fallback.
2. In a non-production environment, compare JSON schema, IDs, hierarchy, UTF-8 content, counts, and provenance against BL-001 acceptance values.
3. Change `src/pages/Index.tsx` so a validated non-null governed response is the sole authoritative provider for resource ID `medication-request-cato`.
4. Permit the hardcoded fallback only when the governed endpoint is unavailable or fails validation, and show a persistent `LEGACY / NON-AUTHORITATIVE` state. Never merge fallback nodes with governed nodes; never use fallback for governed statistics, validation claims, or exports.
5. Bypass legacy `sectionOverrides` for governed responses as specified above.
6. Remove `AUTO VALID` inference where it can be confused with governed validity; render translated UI status and governed validation findings distinctly.
7. After an agreed observation period and successful regression tests, remove the direct import from `Index.tsx`, then delete the hardcoded file only after repository search proves no remaining fallback dependency. Demo/scenario data may remain only when clearly labeled and isolated.
8. Add tests proving that a valid governed response always wins, a fallback is visibly non-authoritative, and localStorage cannot shadow governed content.

## 9. Proposed migration 013 contents

`013_governed_read_api.sql` should, in order:

1. `set role s2t_fhir_owner`.
2. Reassert revocations on `s2t_fhir` from `public`, `anon`, `authenticated`, and `service_role` as defense in depth.
3. Create the private active-release context projection.
4. Create the four security-barrier public views with explicit column lists and controlled-value domain checks.
5. Create private helper functions only if required for kebab/ID/tree construction, with no web-role `EXECUTE`; prefer SQL expressions inside the public RPC to minimize callable surface.
6. Create `get_active_medication_request_cato()` with the fail-closed rules, fixed search path, and exact JSON shape above.
7. Revoke all on each API object/function from `public` before granting anything.
8. Grant schema usage, exact view `SELECT`, and exact RPC `EXECUTE` privileges only to the stated consumer roles.
9. Reassert restrictive default privileges for future objects/functions in `s2t_fhir_api`.
10. `reset role`.

It must not alter migrations 001-012, grant base-table privileges to web roles, create write functions, or expose historical data.

## 10. Verification queries for migration 013 review

These are proposed post-migration verification queries; they have not been executed.

### Functional reconciliation

```sql
select baseline_code, lifecycle_status, candidate_count, accepted_count,
       quarantined_count, validation_outcome, release_gate_outcome
from s2t_fhir_api.active_baseline;
-- BL-001 expectation: ACTIVE, 293, 292, 1, recorded validation outcome, PASSED.

select mapping_kind, count(*)
from s2t_fhir_api.active_mapping_record
group by mapping_kind
order by mapping_kind;
-- BL-001: ELEMENT_MAPPING 237; GOVERNANCE_GUIDANCE 46; STATUS_MAPPING_RULE 9.

select count(*) as total
from s2t_fhir_api.active_mapping_record;
-- BL-001: 292.

select *
from s2t_fhir_api.active_quarantine_summary;
-- BL-001: candidate 293, accepted 292, quarantined 1.

select source_sheet, source_row, source_cell_range, finding_code, severity
from s2t_fhir_api.active_quarantine_item;
-- Includes S2T MedicationRequestCato / 77 / A77:Q77 / INVALID_CARDINALITY.
```

### Lovable JSON contract, ID, hierarchy, and UTF-8 assertions

```sql
with doc as (
  select s2t_fhir_api.get_active_medication_request_cato() as j
)
select j is not null as has_document,
       j ->> 'id' = 'medication-request-cato' as resource_id_ok,
       jsonb_typeof(j -> 'sections') = 'array' as sections_ok,
       not exists (
         select 1 from jsonb_object_keys(j) k
         where k not in ('id','label','description','icon','sections','crossReferences')
       ) as top_level_shape_ok
from doc;
-- All true.

with recursive doc as (
  select s2t_fhir_api.get_active_medication_request_cato() as j
), nodes as (
  select e.node
  from doc
  cross join lateral jsonb_array_elements(j -> 'sections') s(section)
  cross join lateral jsonb_array_elements(s.section -> 'elements') e(node)
  union all
  select c.node
  from nodes n
  cross join lateral jsonb_array_elements(coalesce(n.node -> 'children', '[]'::jsonb)) c(node)
)
select count(*) as represented,
       count(distinct node ->> 'id') as distinct_ids,
       bool_and((node ->> 'id') ~ '^map-v[0-9]+-[0-9a-f]{64}$') as id_format_ok,
       bool_and(node ?& array['id','targetElement','cardinality','profile']) as required_shape_ok,
       bool_and((node ->> 'profile') in ('IL CORE','HDP','LOCAL')) as profile_ok,
       bool_and((node ->> 'status') in ('mapped','fixed','pending','unmapped','structural')) as status_ok
from nodes;
-- BL-001: represented = distinct_ids = 292; all booleans true.

select s2t_fhir_api.get_active_medication_request_cato()
     = s2t_fhir_api.get_active_medication_request_cato() as stable_document;
-- True within the same database snapshot; repeat across sessions/releases for stable-ID regression.

select s2t_fhir_api.get_active_medication_request_cato()::text ~ '[א-ת]' as contains_hebrew;
-- True. Application integration test must also assert known Hebrew text survives UTF-8 JSON decode unchanged.
```

Application contract tests must validate the full recursive document against a checked-in JSON Schema mirroring the verified TypeScript types, resolve every icon token, verify every child occurs once under the longest governed ancestor, and recursively count 292 nodes. They must also assert that no node corresponds to workbook row 77; provenance for that assertion comes from the relational views because the narrow `MappingElement` shape intentionally contains no row field.

### Exclusion and provenance assertions

```sql
select count(*)
from s2t_fhir_api.active_mapping_record
where source_sheet = 'S2T MedicationRequestCato'
  and source_row = 77
  and source_cell_range = 'A77:Q77';
-- Must be 0.

select count(*)
from s2t_fhir_api.active_mapping_record
where workbook_filename is null or workbook_sha256 is null
   or source_sheet is null or source_row is null or source_cell_range is null;
-- Must be 0.

select count(*)
from s2t_fhir_api.active_mapping_record m
where not exists (
  select 1
  from s2t_fhir_api.active_baseline b
  where b.baseline_code = m.baseline_code
    and b.version_label = m.version_label
    and b.lifecycle_status = 'ACTIVE'
    and b.release_gate_outcome = 'PASSED'
);
-- Must be 0.
```

### Column-surface assertions

```sql
select table_name, column_name
from information_schema.columns
where table_schema = 's2t_fhir_api'
  and table_name in ('active_baseline', 'active_mapping_record',
                     'active_quarantine_item', 'active_quarantine_summary')
  and (column_name like '%\_id' escape '\'
       or column_name in ('raw_source_row', 'evidence_json', 'detail_json',
                          'actor_principal_id', 'initiating_human_principal_id'));
-- Must return no rows.
```

### Privilege assertions

```sql
select grantee, table_schema, table_name, privilege_type
from information_schema.role_table_grants
where table_schema in ('s2t_fhir', 's2t_fhir_api')
  and grantee in ('anon', 'authenticated', 'service_role')
order by grantee, table_schema, table_name, privilege_type;
-- No grants on s2t_fhir; only intended SELECT grants on named public API views.

select has_schema_privilege('anon', 's2t_fhir', 'USAGE'),
       has_schema_privilege('authenticated', 's2t_fhir', 'USAGE'),
       has_schema_privilege('service_role', 's2t_fhir', 'USAGE');
-- All false.

set local role anon;
select count(*) from s2t_fhir_api.active_mapping_record;
select s2t_fhir_api.get_active_medication_request_cato() ->> 'id';
select count(*) from s2t_fhir.mapping_record;
-- First two succeed and return governed API data; base-table query must fail.
```

Run equivalent positive tests for `authenticated`, a positive least-privilege test for `s2t_fhir_api_reader`, and negative base-schema/API tests for `service_role`. Inspect `pg_views`/`pg_class.reloptions` to confirm all public API views have `security_barrier=true`; inspect `pg_proc.proconfig`, volatility, owner, and grants for the RPC; then confirm PostgREST schema cache has reloaded.

### Lifecycle regression test

In a transaction in a controlled test database, create or select an inactive baseline and prove it is absent from all four API objects and the RPC returns `NULL`; then roll back. Similarly, supersede/retire the current lifecycle event, change the current gate away from `PASSED`, make the linked import non-committed in test setup, and create an ambiguous second eligible context in separate rollback-only tests. In every case the RPC must return `NULL` and no governed tree may be served. This validates ACTIVE/PASSED/COMMITTED enforcement and fail-closed cardinality rather than merely inspecting view text.

## 11. Open questions and non-blocking deployment notes

1. Add `s2t_fhir_api` to the project's PostgREST exposed schemas while keeping `s2t_fhir` excluded. This is a deployment/configuration step and must be verified before Lovable rollout.
2. BL-001 may legitimately show a failed validation outcome alongside a passed release gate under accepted-with-quarantine policy. The UI must display both independently and must not reinterpret the gate from validation outcome alone.
3. This design keeps quarantined candidates from the serving import visible in the quarantine views even after resolution, with their current case state, while always excluding them from the mapping tree.
4. The RPC uses fail-closed exactly-one semantics for eligible CATO MedicationRequest contexts and gates. If governance later permits multiple simultaneously applicable release gates or baselines for this resource, that requires a new explicit selection policy and reviewed migration; migration 013 must not guess.
5. `anon` access is limited to the minimized API contract because the current shared-password flow is not Supabase Auth. A future Auth rollout should revoke `anon` privileges without changing the read shapes.

## 12. Readiness assessment

The read model is internally coherent and fail-closed. The verified Lovable shape, stable identity rules, hierarchy algorithm, status/profile translations, local override isolation, security boundary, transition fallback, and ACTIVE/PASSED/COMMITTED selection are specified sufficiently to author and review `013_governed_read_api.sql` without changing migrations 001-012 or Lovable.

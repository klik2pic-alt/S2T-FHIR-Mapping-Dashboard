# Governed Read API Performance Review — Migration 014

## Scope and conclusion

This review covers only `014_governed_read_api_performance.sql`. It does not modify migrations 001–013, Lovable, API contracts, or governed data. Review is static: no SQL was executed.

Migration 014 preserves the externally validated `s2t_fhir_api.get_active_medication_request_cato()` contract while removing the repeated governed-view execution responsible for the observed 40.58-second runtime and 4,809,167 shared-buffer hits on BL-001.

## Root cause

Migration 013's private `_build_lovable_children(text, text, text)` function queries `s2t_fhir_api._lovable_mapping_node` on every recursive call. Every represented node therefore causes another query of a security-barrier view whose definition expands the active-release selection, accepted mapping projection, normalization, manifest join, and longest-parent search. The RPC also queries that view separately for counts, validity checks, duplicate-path checks, and each section tree.

The result is an N+1 recursive access pattern over an expensive governed relation rather than recursion over a fixed 292-row result.

## Old algorithm complexity and problem

For `N` mapping nodes, the old builder performs approximately one governed-view query per node plus section-root and validation queries. Each view evaluation includes nontrivial governed joins and an ancestor search over the normalized set. The effective work is substantially worse than the small output size suggests and repeatedly touches the same base data. BL-001 demonstrates the consequence: 40,582.573 ms and 4,809,167 shared-buffer hits, far beyond the 3-second `anon` and 8-second `authenticated` limits.

## New algorithm

The replacement RPC:

1. Applies the unchanged ACTIVE + PASSED + COMMITTED, exactly-one-context selection through the existing private views.
2. References `_lovable_mapping_node` exactly once and aggregates the eligible rows into a local JSONB array.
3. Builds each node's exact ResourceConfig payload during that one evaluation, alongside private hierarchy, ordering, and validation metadata.
4. Performs counts, distinct-ID validation, shape validation, and duplicate-path validation against the local JSONB array.
5. Recursively constructs children with `_build_lovable_children_from_nodes(jsonb, text, text)`, which reads only the supplied in-memory JSONB array and never queries a view or base table.
6. Reconciles the recursively represented count with the captured node count before returning the document.

The in-memory helper may scan the 292-item JSONB array while finding children, but those scans are small, deterministic, and contain no governed joins or base-relation access. No permanent cache, duplicate mapping table, or denormalized authority is introduced.

## Objects replaced or created

- Replaced in place: `s2t_fhir_api.get_active_medication_request_cato()`.
- Created as a private helper: `s2t_fhir_api._build_lovable_children_from_nodes(jsonb, text, text)`.
- Removed after dependency replacement: migration 013's private `_build_lovable_children(text, text, text)`.
- No views, tables, governed rows, public RPC names, or public relation shapes are added or changed.

## Security impact

The public RPC remains `STABLE`, `SECURITY DEFINER`, owned through `set role s2t_fhir_owner`, and fixed to `search_path = pg_catalog, s2t_fhir_api`. The new helper uses the same hardening and has all privileges revoked from `PUBLIC`, `anon`, `authenticated`, `service_role`, and `s2t_fhir_api_reader`.

Existing execute access to the public RPC is reasserted for only `anon`, `authenticated`, and `s2t_fhir_api_reader`; `service_role` and `PUBLIC` remain blocked. No base-schema grant is introduced. The local JSONB array contains private construction metadata only inside the function invocation; the returned JSON is still the stripped, governed ResourceConfig document and exposes neither UUIDs nor raw evidence.

## API compatibility

The RPC name and zero-argument signature are unchanged. The resource ID, top-level keys, section IDs, section order, labels, icons, descriptions, node field construction, stable IDs, longest-ancestor hierarchy, sibling ordering, profile translations, status translations, null stripping, and empty `crossReferences` array are copied exactly from migration 013.

The source relation remains `active_mapping_record`, whose accepted-candidate restriction excludes quarantined row 77. The RPC retains fail-closed checks for exactly one eligible CATO MedicationRequest context, accepted-count reconciliation, distinct stable IDs, allowed profile/status values, target presence, duplicate element paths, and represented-node reconciliation. For BL-001 the required result remains 292 represented nodes and 292 distinct IDs.

## Expected runtime improvement

The dominant cost—the repeated expansion and execution of `_lovable_mapping_node`—is reduced to one evaluation per RPC call. Recursive work is limited to a small local JSONB collection. This should remove nearly all of the observed 4.8 million repeated buffer hits and is expected to place BL-001 comfortably below the 3-second anonymous-role timeout, with the preferred target below one second.

That target is an expectation, not a measured claim. Deployment readiness still requires the runtime plan and assertions below in the target environment.

## Exact runtime verification plan

Run the commented queries at the end of migration 014, separately after applying the migration in a controlled runtime environment:

1. Run `EXPLAIN (ANALYZE, BUFFERS)` for the RPC and record execution time and buffer hits. Require less than 3 seconds; prefer less than 1 second.
2. Assert the returned resource ID is exactly `medication-request-cato`.
3. Recursively traverse every section and assert `represented = 292`, `distinct_ids = 292`, `ids_valid = true`, and `shape_valid = true`.
4. Assert the returned JSON contains Hebrew characters after UTF-8 serialization.
5. In one repeatable-read snapshot, assert two RPC calls return byte-equivalent JSONB values.
6. Assert source row 77 / `A77:Q77` is absent from `active_mapping_record`.
7. Inspect public columns and scan returned JSON text for internal identifier names, raw-evidence names, or UUID syntax; require no leakage.
8. Verify execute privileges: `anon`, `authenticated`, and `s2t_fhir_api_reader` retain RPC access; `service_role` and `PUBLIC` do not; no consumer role can execute the helper.

Also compare the full returned JSONB with the migration-013 validated fixture or captured pre-014 document in the same governed snapshot. This is the strongest contract-regression check for every string, Hebrew value, ordering decision, optional key, and hierarchy edge.

## Rollback implications

Rolling back migration 014 requires restoring both migration-013 function definitions: recreate `_build_lovable_children(text, text, text)` and replace `get_active_medication_request_cato()` with its migration-013 body, then drop `_build_lovable_children_from_nodes(jsonb, text, text)`. Grants must be reasserted exactly as in migration 013.

Rollback restores functional behavior but also restores the severe N+1 performance defect, so it is not a viable production remedy under the current 3-second/8-second role timeouts. No governed data rollback or data migration is required because migration 014 changes functions only.

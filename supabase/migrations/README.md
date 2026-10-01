# S2T FHIR PostgreSQL/Supabase migrations

## Status

These migrations implement the approved 34-table MVP schema. They do not seed BL-002, import the workbook, or complete V2-BA-07.

## Required order

1. `001_schemas_and_roles.sql`
2. `002_reference_bootstrap.sql`
3. `003_governance_foundation.sql`
4. `004_baseline_and_artifacts.sql`
5. `005_import_and_provenance.sql`
6. `006_mapping_model.sql`
7. `007_validation_and_quarantine.sql`
8. `008_release_and_audit.sql`
9. `0081_configuration_bootstrap.sql`
10. `009_integrity_functions_and_triggers.sql`
11. `010_indexes.sql`
12. `011_security_and_privileges.sql`
13. `012_integrity_tests.sql`

Do not reorder or selectively skip migrations. The governance/baseline circular reference is resolved deliberately by adding the governance-item baseline FK in migration 004 after both tables exist.

## Prerequisites

- Run as a Supabase/PostgreSQL administrative deployment identity able to create roles and grant role membership.
- The deployment identity must be able to `SET ROLE s2t_fhir_owner` through `s2t_fhir_migrator` or equivalent administrative execution.
- PostgreSQL must provide the built-in `gen_random_uuid()` function. No `uuid-ossp` extension is used.
- Verify the server before deployment:

  `show server_version;`

  `show server_version_num;`

- The SQL is intended to remain compatible with PostgreSQL 13/14. It does not use `NULLS NOT DISTINCT`.
- Supabase `anon`, `authenticated`, and `service_role` roles are handled when present, but the governed core schema remains private and unexposed.
- V2-BA-07 must be completed before executing an import, not before deploying these migrations.

Migration 001 deliberately isolates managed-role creation and ownership setup. Disposable-project testing must confirm that the Supabase deployment identity can create roles, grant membership, transfer schema ownership, and `SET ROLE`. No fallback privilege escalation is embedded in later migrations.

## Transaction and rollback expectations

Apply each numbered migration transactionally where the deployment system permits it. Role creation and schema ownership should be tested in a non-production Supabase branch/project first.

The migrations are forward-only. Rollback of an uncommitted migration uses normal transaction rollback. After a migration has committed, do not use destructive down migrations against governed evidence. Correct schema defects with a reviewed forward migration. Before production deployment, use a disposable environment to verify a clean rebuild from migration 001.

Migration 012 performs transactional negative/positive integrity tests inside `BEGIN`/`ROLLBACK`. It creates no persistent test data and must be run only after migrations 001-011 have succeeded.

Migration 008a creates configuration only: migration/import service principals, the baseline-import validation ruleset and rules, and a baseline-import release-gate definition and requirements. It creates no baseline or workbook data.

The configuration digests in migration 008a are SHA-256 values over UTF-8 canonical text. Rule text is `rule_code|rule_version|severity_code|description`; the ruleset and gate use their code/version followed by ordered, semicolon-delimited member tuples. Any configuration change requires a new version and newly calculated digest.

## PostgreSQL 13/14 null-safe uniqueness

`import_run_metric` uses an expression unique index with reserved null sentinels. `governance_evidence` uses one partial unique index per typed evidence target. These provide the approved null-safe uniqueness without PostgreSQL 15 syntax.

After every supported environment is PostgreSQL 15 or later, the metric expression index may be replaced in a reviewed forward migration by a `UNIQUE NULLS NOT DISTINCT` constraint. That change is optional and does not alter business semantics.

## Security expectations

- `s2t_fhir_owner` owns governed objects and has no login.
- The importer does not own tables.
- Core tables are in `s2t_fhir`, never `public`.
- `s2t_fhir_api` is intentionally empty in MVP.
- Browser-facing Supabase roles have no direct core privileges.
- Append-only behavior is protected by privileges and database triggers because service-level access may bypass RLS.
- Do not expose `s2t_fhir` through Supabase Data API settings.
- `s2t_fhir_governance_reader` is an all-baselines privileged governance/audit role. Ordinary application and API identities must never receive this role.
- Baseline-scoped application access is intentionally deferred: `s2t_fhir_api` remains private and empty until reviewed baseline-filtered views/RPCs and their authorization policies are implemented.
- MVP import finalization is limited to one baseline per transaction. The database records the finalizing baseline in transaction-local state and rejects a second baseline; import orchestration must also acquire baselines in deterministic order and submit separate transactions.

## Validation count semantics

`validation_run.warning_count` and `validation_run.error_count` are finding counts. A single finding linked to several candidate rows counts once. `import_run_metric` warning/error totals must use the same finding-count definition.

## Deployment verification

After all migrations succeed, verify:

- exactly 34 base tables exist in `s2t_fhir`;
- no governed base tables exist in `public`;
- all governed tables are owned by `s2t_fhir_owner`;
- append-only tables reject update/delete operations;
- mapping parents cannot commit without exactly one correct subtype;
- a baseline cannot have multiple authoritative source artifacts;
- accepted and quarantined candidate states remain mutually exclusive;
- release evaluations match their validation artifact digest and ruleset;
- `anon`, `authenticated`, and `service_role` have no direct core grants.

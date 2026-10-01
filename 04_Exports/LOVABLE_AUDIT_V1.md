# Lovable Project Read-Only Audit — V1

This document records the current read-only audit of the existing Lovable project. It describes the observed state and a proposed architectural direction; it does not modify the application, Lovable project, Supabase schema, or source workbook.

## Current state

### Routes

- `/` — Landing page
- `/login` — Shared password gate
- `/dashboard` — Main mapping dashboard
- `*` — NotFound

### Backend / persistence

- The Supabase public schema currently has no tables.
- The backend contains only a `verify-access` edge function for password verification.
- Current application state is stored in browser `localStorage`.
- Local state includes dynamic resources, section overrides, the active resource, configuration versions, diagnosis comparison data, and visibility state.
- Application version changes can clear locally stored state.

### Mapping data sources

- Hardcoded TypeScript mapping files currently exist for multiple FHIR resources.
- `medicationRequestCatoMapping.ts` contains a hardcoded CATO `MedicationRequest` mapping and must be considered legacy relative to the current Excel baseline.
- Excel import exists, but imported data is browser-local and is not persisted as an authoritative baseline.
- Several demo and scenario components contain hardcoded FHIR JSON or CATO-specific narrative.

### Reusable components

- Mapping table / `MappingSection`
- Validation engine
- IL-Core validation
- Validation alerts banner
- Resource sidebar
- Stats / legend
- FHIR term dictionary
- Excel parsing and header detection

### Legacy / high-risk areas

- Hardcoded `medicationRequestCatoMapping.ts`
- CATO-specific logic based on literal resource-ID checks
- `AUTO VALID` behavior derived from cardinality and fixed-value rules rather than approved decision state
- Hardcoded CATO clinical scenarios and summaries
- No durable versioning
- No Decision Register
- No Issue Register

### Architecture gaps

The following capabilities are missing today:

- Baseline Register
- Persistent mapping-element storage
- Decision Register
- Open Issues / Reconciliation
- Version Diff
- Provenance / attribution
- Durable persistence

## Proposed direction

Preserve the existing UI and validation components, but introduce a governed persistence layer underneath them.

Conceptual model:

```text
Excel Baseline → baseline_version → mapping_element → decision / issue → existing mapping UI → future diff views
```

Proposed future entities:

- `baseline_version`
- `mapping_element`
- `decision`
- `issue`
- `element_change`

## Important governance rule

The current Excel workbook is the **Human Working Draft Baseline** and is authoritative over the legacy hardcoded CATO mapping in the application.

This audit is documentation only. Do not modify application code, the Lovable project, the Supabase schema, or the workbook as part of this audit.

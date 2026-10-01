# S2T FHIR Mapping Dashboard

## Scope
CATO → FHIR MedicationRequest mapping governance, comparison and validation.

## Source of truth
The current Excel S2T workbook is the Human Working Draft Baseline.
It is not automatically considered a Gold Standard.

## Authoritative sheets
- S2T MedicationRequestCato
- Cato Status Mapping
- הנחיות נוספות מעודכן

## Work in progress
- Profile
- CATO Route Mapping
- JSON examples

## Governance workflow
Baseline → Compare → Decide → Implement → Validate → Document → Approve

## Decision Status
- FINAL
- WIP
- OPEN
- DO NOT MAP
- N/A

## Important principles
- Existing hardcoded mappings in the Lovable application must not override the Excel baseline.
- Profile is currently WIP and is being developed with the clinical/interoperability team.
- Mapping decisions and implementation status must remain separate concepts.
- No mapping rule should be inferred without evidence or an explicit decision.

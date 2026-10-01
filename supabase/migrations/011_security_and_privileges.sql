set role s2t_fhir_owner;

revoke all on all tables in schema s2t_fhir from public;
revoke all on all functions in schema s2t_fhir from public;
revoke all on schema s2t_fhir from public;
revoke all on schema s2t_fhir_api from public;

do $block$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema s2t_fhir from anon';
    execute 'revoke all on all functions in schema s2t_fhir from anon';
    execute 'revoke all on schema s2t_fhir from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on all tables in schema s2t_fhir from authenticated';
    execute 'revoke all on all functions in schema s2t_fhir from authenticated';
    execute 'revoke all on schema s2t_fhir from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke all on all tables in schema s2t_fhir from service_role';
    execute 'revoke all on all functions in schema s2t_fhir from service_role';
    execute 'revoke all on schema s2t_fhir from service_role';
  end if;
end
$block$;

grant usage on schema s2t_fhir to s2t_fhir_importer, s2t_fhir_governance_reader;
grant usage on schema s2t_fhir_api to s2t_fhir_api_reader, s2t_fhir_governance_reader;

grant select on all tables in schema s2t_fhir to s2t_fhir_importer, s2t_fhir_governance_reader;
grant insert on table
  s2t_fhir.baseline_series,
  s2t_fhir.baseline_version,
  s2t_fhir.baseline_relationship,
  s2t_fhir.baseline_lifecycle_event,
  s2t_fhir.artifact,
  s2t_fhir.artifact_location,
  s2t_fhir.baseline_artifact,
  s2t_fhir.artifact_sheet_manifest,
  s2t_fhir.import_run,
  s2t_fhir.import_run_metric,
  s2t_fhir.import_candidate_row,
  s2t_fhir.logical_mapping_identity,
  s2t_fhir.mapping_record,
  s2t_fhir.element_mapping,
  s2t_fhir.status_mapping_rule,
  s2t_fhir.governance_guidance,
  s2t_fhir.validation_run,
  s2t_fhir.validation_finding,
  s2t_fhir.validation_finding_row,
  s2t_fhir.quarantine_case,
  s2t_fhir.quarantine_event,
  s2t_fhir.governance_evidence,
  s2t_fhir.release_gate_evaluation,
  s2t_fhir.release_gate_result,
  s2t_fhir.audit_event
to s2t_fhir_importer;
grant update (display_name, disabled_at) on s2t_fhir.principal to s2t_fhir_importer;
grant update (completed_at, terminal_status_value_id, failure_summary) on s2t_fhir.import_run to s2t_fhir_importer;

revoke update, delete, truncate on all tables in schema s2t_fhir from s2t_fhir_importer, s2t_fhir_api_reader, s2t_fhir_governance_reader;
grant update (display_name, disabled_at) on s2t_fhir.principal to s2t_fhir_importer;
grant update (completed_at, terminal_status_value_id, failure_summary) on s2t_fhir.import_run to s2t_fhir_importer;

alter default privileges for role s2t_fhir_owner in schema s2t_fhir revoke all on tables from public;
alter default privileges for role s2t_fhir_owner in schema s2t_fhir revoke all on functions from public;
alter default privileges for role s2t_fhir_owner in schema s2t_fhir_api revoke all on tables from public;
alter default privileges for role s2t_fhir_owner in schema s2t_fhir_api revoke all on functions from public;

-- The API schema intentionally has no MVP objects. Exposure is opt-in after reviewed views and RLS policies exist.

reset role;

set role s2t_fhir_owner;

-- PostgreSQL 13/14 null-safe uniqueness: empty sheet names and zero reference UUIDs are prohibited/reserved.
create unique index import_run_metric_dimensions_uq
on s2t_fhir.import_run_metric (
  import_run_id,
  metric_type_value_id,
  coalesce(source_sheet_name, ''),
  coalesce(mapping_kind_value_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(decision_status_value_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(severity_value_id, '00000000-0000-0000-0000-000000000000'::uuid)
);

create unique index governance_evidence_artifact_uq on s2t_fhir.governance_evidence(governance_action_id, evidence_role_value_id, artifact_id) where artifact_id is not null;
create unique index governance_evidence_reference_value_uq on s2t_fhir.governance_evidence(governance_action_id, evidence_role_value_id, reference_value_id) where reference_value_id is not null;
create unique index governance_evidence_validation_run_uq on s2t_fhir.governance_evidence(governance_action_id, evidence_role_value_id, validation_run_id) where validation_run_id is not null;
create unique index governance_evidence_candidate_uq on s2t_fhir.governance_evidence(governance_action_id, evidence_role_value_id, import_candidate_row_id) where import_candidate_row_id is not null;
create unique index governance_evidence_finding_uq on s2t_fhir.governance_evidence(governance_action_id, evidence_role_value_id, validation_finding_id) where validation_finding_id is not null;
create unique index governance_evidence_release_uq on s2t_fhir.governance_evidence(governance_action_id, evidence_role_value_id, release_gate_evaluation_id) where release_gate_evaluation_id is not null;

create index principal_kind_idx on s2t_fhir.principal(principal_kind_value_id);
create index principal_active_idx on s2t_fhir.principal(principal_id) where disabled_at is null;
create index reference_value_supersedes_idx on s2t_fhir.reference_value(supersedes_reference_value_id);
create index reference_value_effective_idx on s2t_fhir.reference_value(reference_domain_id, effective_at, retired_at);
create index baseline_relationship_to_idx on s2t_fhir.baseline_relationship(to_baseline_version_id);
create index baseline_lifecycle_current_idx on s2t_fhir.baseline_lifecycle_event(baseline_version_id, occurred_at desc);
create index baseline_lifecycle_supersedes_idx on s2t_fhir.baseline_lifecycle_event(supersedes_event_id);
create index baseline_lifecycle_governance_idx on s2t_fhir.baseline_lifecycle_event(governance_action_id);
create index artifact_kind_idx on s2t_fhir.artifact(artifact_kind_value_id);
create index artifact_captured_idx on s2t_fhir.artifact(captured_at);
create index artifact_location_current_idx on s2t_fhir.artifact_location(artifact_id, observed_at desc);
create index artifact_location_availability_idx on s2t_fhir.artifact_location(availability_status_value_id);
create index artifact_location_supersedes_idx on s2t_fhir.artifact_location(supersedes_location_id);
create index baseline_artifact_role_idx on s2t_fhir.baseline_artifact(baseline_version_id, artifact_role_value_id);
create index baseline_artifact_artifact_idx on s2t_fhir.baseline_artifact(artifact_id);
create index artifact_sheet_classification_idx on s2t_fhir.artifact_sheet_manifest(sheet_classification_value_id);
create index artifact_sheet_authoritative_idx on s2t_fhir.artifact_sheet_manifest(artifact_id, is_authoritative);
create index governance_item_classification_idx on s2t_fhir.governance_item(classification_value_id);
create index governance_action_current_idx on s2t_fhir.governance_action(governance_item_id, occurred_at desc);
create index governance_action_supersedes_idx on s2t_fhir.governance_action(supersedes_action_id);
create index import_run_baseline_started_idx on s2t_fhir.import_run(baseline_version_id, started_at desc);
create index import_run_artifact_idx on s2t_fhir.import_run(artifact_id);
create index import_run_terminal_idx on s2t_fhir.import_run(terminal_status_value_id);
create index import_run_open_idx on s2t_fhir.import_run(import_run_id) where completed_at is null;
create index import_metric_type_idx on s2t_fhir.import_run_metric(metric_type_value_id);
create index import_candidate_kind_idx on s2t_fhir.import_candidate_row(import_run_id, mapping_kind_value_id);
create index import_candidate_hash_idx on s2t_fhir.import_candidate_row(import_run_id, source_sheet_name, source_row_hash);
create index import_candidate_logical_key_idx on s2t_fhir.import_candidate_row(calculated_logical_key);
create index logical_identity_key_idx on s2t_fhir.logical_mapping_identity(logical_key);
create index logical_identity_scope_idx on s2t_fhir.logical_mapping_identity(source_system, fhir_resource, mapping_kind_value_id);
create index mapping_record_kind_idx on s2t_fhir.mapping_record(baseline_version_id, mapping_kind_value_id);
create index mapping_record_decision_idx on s2t_fhir.mapping_record(decision_status_value_id);
create index mapping_record_identity_idx on s2t_fhir.mapping_record(logical_mapping_identity_id);
create index element_mapping_target_idx on s2t_fhir.element_mapping(target_fhir_path);
create index element_mapping_interface_idx on s2t_fhir.element_mapping(interface_name);
create index status_mapping_source_idx on s2t_fhir.status_mapping_rule(source_status_value);
create index status_mapping_target_idx on s2t_fhir.status_mapping_rule(target_status_value);
create index guidance_scope_topic_idx on s2t_fhir.governance_guidance(guidance_scope_value_id, decision_topic_value_id);
create index validation_run_import_idx on s2t_fhir.validation_run(import_run_id, completed_at desc);
create index validation_run_ruleset_idx on s2t_fhir.validation_run(validation_ruleset_id);
create index validation_run_artifact_digest_idx on s2t_fhir.validation_run(artifact_digest);
create index validation_finding_severity_idx on s2t_fhir.validation_finding(validation_run_id, severity_value_id);
create index validation_finding_rule_idx on s2t_fhir.validation_finding(validation_rule_id);
create index validation_finding_collision_idx on s2t_fhir.validation_finding(collision_group_key) where collision_group_key is not null;
create index validation_finding_row_candidate_idx on s2t_fhir.validation_finding_row(import_candidate_row_id);
create index quarantine_case_finding_idx on s2t_fhir.quarantine_case(opening_validation_finding_id);
create index quarantine_event_current_idx on s2t_fhir.quarantine_event(quarantine_case_id, occurred_at desc);
create index quarantine_event_supersedes_idx on s2t_fhir.quarantine_event(supersedes_event_id);
create index release_gate_requirement_blocking_idx on s2t_fhir.release_gate_requirement(release_gate_definition_id, is_blocking);
create index release_gate_evaluation_current_idx on s2t_fhir.release_gate_evaluation(baseline_version_id, release_gate_definition_id, evaluated_at desc);
create index release_gate_evaluation_evidence_idx on s2t_fhir.release_gate_evaluation(artifact_digest, validation_ruleset_id);
create index release_gate_evaluation_supersedes_idx on s2t_fhir.release_gate_evaluation(supersedes_evaluation_id);
create index release_gate_result_outcome_idx on s2t_fhir.release_gate_result(requirement_outcome_value_id);
create index audit_event_baseline_time_idx on s2t_fhir.audit_event(baseline_version_id, occurred_at desc);
create index audit_event_actor_idx on s2t_fhir.audit_event(actor_principal_id);
create index audit_event_type_idx on s2t_fhir.audit_event(event_type_value_id);
create index audit_event_correlation_idx on s2t_fhir.audit_event(request_correlation_id) where request_correlation_id is not null;
create index audit_event_target_idx on s2t_fhir.audit_event(target_identifier);

create index reference_value_creator_idx on s2t_fhir.reference_value(created_by_principal_id) where created_by_principal_id is not null;
create index baseline_series_type_idx on s2t_fhir.baseline_series(baseline_type_value_id);
create index baseline_version_creator_idx on s2t_fhir.baseline_version(created_by_principal_id);
create index baseline_relationship_type_idx on s2t_fhir.baseline_relationship(relationship_type_value_id);
create index baseline_relationship_creator_idx on s2t_fhir.baseline_relationship(created_by_principal_id);
create index baseline_lifecycle_status_idx on s2t_fhir.baseline_lifecycle_event(lifecycle_status_value_id);
create index baseline_lifecycle_actor_idx on s2t_fhir.baseline_lifecycle_event(actor_principal_id);
create index artifact_creator_idx on s2t_fhir.artifact(created_by_principal_id);
create index artifact_location_kind_idx on s2t_fhir.artifact_location(location_kind_value_id);
create index artifact_location_actor_idx on s2t_fhir.artifact_location(actor_principal_id);
create index baseline_artifact_creator_idx on s2t_fhir.baseline_artifact(created_by_principal_id);
create index governance_item_creator_idx on s2t_fhir.governance_item(created_by_principal_id);
create index governance_action_type_idx on s2t_fhir.governance_action(action_type_value_id);
create index governance_action_actor_idx on s2t_fhir.governance_action(actor_principal_id);
create index import_run_policy_idx on s2t_fhir.import_run(import_policy_value_id);
create index import_run_actor_idx on s2t_fhir.import_run(actor_principal_id);
create index import_candidate_disposition_idx on s2t_fhir.import_candidate_row(candidate_disposition_value_id);
create index logical_identity_kind_idx on s2t_fhir.logical_mapping_identity(mapping_kind_value_id);
create index validation_ruleset_creator_idx on s2t_fhir.validation_ruleset(created_by_principal_id);
create index validation_rule_severity_idx on s2t_fhir.validation_rule(default_severity_value_id);
create index validation_run_artifact_idx on s2t_fhir.validation_run(artifact_id);
create index validation_run_outcome_idx on s2t_fhir.validation_run(outcome_value_id);
create index validation_run_actor_idx on s2t_fhir.validation_run(actor_principal_id);
create index quarantine_case_actor_idx on s2t_fhir.quarantine_case(opened_by_principal_id);
create index quarantine_event_type_idx on s2t_fhir.quarantine_event(event_type_value_id);
create index quarantine_event_actor_idx on s2t_fhir.quarantine_event(actor_principal_id);
create index release_gate_definition_creator_idx on s2t_fhir.release_gate_definition(created_by_principal_id);
create index release_gate_evaluation_outcome_idx on s2t_fhir.release_gate_evaluation(gate_outcome_value_id);
create index release_gate_evaluation_actor_idx on s2t_fhir.release_gate_evaluation(actor_principal_id);
create index release_gate_result_governance_idx on s2t_fhir.release_gate_result(governance_action_id) where governance_action_id is not null;
create index release_gate_result_finding_idx on s2t_fhir.release_gate_result(validation_finding_id) where validation_finding_id is not null;
create index governance_evidence_artifact_lookup_idx on s2t_fhir.governance_evidence(artifact_id) where artifact_id is not null;
create index governance_evidence_reference_lookup_idx on s2t_fhir.governance_evidence(reference_value_id) where reference_value_id is not null;
create index governance_evidence_validation_run_lookup_idx on s2t_fhir.governance_evidence(validation_run_id) where validation_run_id is not null;
create index governance_evidence_candidate_lookup_idx on s2t_fhir.governance_evidence(import_candidate_row_id) where import_candidate_row_id is not null;
create index governance_evidence_finding_lookup_idx on s2t_fhir.governance_evidence(validation_finding_id) where validation_finding_id is not null;
create index governance_evidence_release_lookup_idx on s2t_fhir.governance_evidence(release_gate_evaluation_id) where release_gate_evaluation_id is not null;

reset role;

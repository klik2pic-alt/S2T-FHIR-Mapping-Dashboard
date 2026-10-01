set role s2t_fhir_owner;

create table s2t_fhir.reference_domain (
  reference_domain_id uuid primary key default gen_random_uuid(),
  domain_code text not null,
  display_name text not null,
  is_versioned boolean not null,
  description text,
  created_at timestamptz not null default transaction_timestamp(),
  constraint reference_domain_code_uq unique (domain_code),
  constraint reference_domain_id_nonzero_ck check (reference_domain_id <> '00000000-0000-0000-0000-000000000000'::uuid),
  constraint reference_domain_code_ck check (domain_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint reference_domain_name_ck check (btrim(display_name) <> '')
);

create table s2t_fhir.reference_value (
  reference_value_id uuid primary key default gen_random_uuid(),
  reference_domain_id uuid not null references s2t_fhir.reference_domain(reference_domain_id),
  value_code text not null,
  version_number integer not null,
  display_name text not null,
  description text,
  effective_at timestamptz not null,
  retired_at timestamptz,
  supersedes_reference_value_id uuid references s2t_fhir.reference_value(reference_value_id),
  is_bootstrap_seed boolean not null default false,
  created_by_principal_id uuid,
  created_at timestamptz not null default transaction_timestamp(),
  constraint reference_value_business_uq unique (reference_domain_id, value_code, version_number),
  constraint reference_value_id_nonzero_ck check (reference_value_id <> '00000000-0000-0000-0000-000000000000'::uuid),
  constraint reference_value_code_ck check (
    value_code ~ '^[A-Z][A-Z0-9_]*$' or value_code in ('DO NOT MAP', 'N/A')
  ),
  constraint reference_value_version_ck check (version_number > 0),
  constraint reference_value_name_ck check (btrim(display_name) <> ''),
  constraint reference_value_retired_ck check (retired_at is null or retired_at >= effective_at),
  constraint reference_value_supersedes_ck check (supersedes_reference_value_id is null or supersedes_reference_value_id <> reference_value_id),
  constraint reference_value_creator_ck check (created_by_principal_id is not null or is_bootstrap_seed)
);

insert into s2t_fhir.reference_domain (domain_code, display_name, is_versioned, description)
values
 ('PRINCIPAL_KIND','Principal kind',false,null),
 ('BASELINE_TYPE','Baseline type',false,null),
 ('BASELINE_RELATIONSHIP_TYPE','Baseline relationship type',false,null),
 ('BASELINE_LIFECYCLE_STATUS','Baseline lifecycle status',false,null),
 ('ARTIFACT_KIND','Artifact kind',false,null),
 ('ARTIFACT_LOCATION_KIND','Artifact location kind',false,null),
 ('ARTIFACT_AVAILABILITY','Artifact availability',false,null),
 ('ARTIFACT_ROLE','Artifact role',false,null),
 ('SHEET_CLASSIFICATION','Sheet classification',false,null),
 ('IMPORT_POLICY','Import policy',false,null),
 ('IMPORT_RUN_STATUS','Import run status',false,null),
 ('METRIC_TYPE','Import metric type',false,null),
 ('MAPPING_KIND','Mapping kind',false,null),
 ('DECISION_STATUS','Decision status',false,null),
 ('CANDIDATE_DISPOSITION','Candidate disposition',false,null),
 ('SEVERITY','Validation severity',false,null),
 ('VALIDATION_OUTCOME','Validation outcome',false,null),
 ('FINDING_ROW_ROLE','Validation finding row role',false,null),
 ('QUARANTINE_EVENT_TYPE','Quarantine event type',false,null),
 ('QUARANTINE_RESOLUTION','Quarantine resolution',false,null),
 ('GOVERNANCE_CLASSIFICATION','Governance classification',false,null),
 ('GOVERNANCE_ACTION_TYPE','Governance action type',false,null),
 ('EVIDENCE_ROLE','Governance evidence role',false,null),
 ('RELEASE_GATE_OUTCOME','Release gate outcome',false,null),
 ('REQUIREMENT_OUTCOME','Release requirement outcome',false,null),
 ('AUDIT_EVENT_TYPE','Audit event type',false,null),
 ('AUDIT_TARGET_TYPE','Audit target type',false,null),
 ('AUDIT_OUTCOME','Audit outcome',false,null),
 ('GUIDANCE_SCOPE','Guidance scope',true,'Versioned governed guidance metadata'),
 ('DECISION_TOPIC_CODE','Decision topic code',true,'Versioned governed guidance metadata');

with seed(domain_code, value_code, display_name) as (
 values
 ('PRINCIPAL_KIND','HUMAN','Human'),('PRINCIPAL_KIND','SERVICE','Service'),
 ('BASELINE_TYPE','HUMAN_WORKING_DRAFT','Human working draft'),
 ('BASELINE_RELATIONSHIP_TYPE','SUPERSEDES','Supersedes'),
 ('BASELINE_LIFECYCLE_STATUS','PENDING_APPROVAL','Pending approval'),('BASELINE_LIFECYCLE_STATUS','ACTIVE','Active'),('BASELINE_LIFECYCLE_STATUS','RETIRED','Retired'),
 ('ARTIFACT_KIND','WORKBOOK','Workbook'),('ARTIFACT_KIND','GOVERNANCE_DOCUMENT','Governance document'),
 ('ARTIFACT_LOCATION_KIND','OBJECT_STORAGE','Object storage'),('ARTIFACT_LOCATION_KIND','FILE_STORAGE','File storage'),('ARTIFACT_LOCATION_KIND','REPOSITORY_PATH','Repository path'),
 ('ARTIFACT_AVAILABILITY','AVAILABLE','Available'),('ARTIFACT_AVAILABILITY','UNAVAILABLE','Unavailable'),
 ('ARTIFACT_ROLE','AUTHORITATIVE_SOURCE','Authoritative source'),('ARTIFACT_ROLE','HISTORICAL_EVIDENCE','Historical evidence'),('ARTIFACT_ROLE','SUPPORTING_DOCUMENT','Supporting document'),
 ('SHEET_CLASSIFICATION','AUTHORITATIVE','Authoritative'),('SHEET_CLASSIFICATION','WIP_PROFILE','Work-in-progress profile'),('SHEET_CLASSIFICATION','WIP_ROUTE_MAPPING','Work-in-progress route mapping'),('SHEET_CLASSIFICATION','EXAMPLE_ONLY','Example only'),('SHEET_CLASSIFICATION','OUT_OF_SCOPE','Out of scope'),
 ('IMPORT_POLICY','CLEAN_IMPORT','Clean import'),('IMPORT_POLICY','ACCEPTED_WITH_QUARANTINE','Accepted with quarantine'),
 ('IMPORT_RUN_STATUS','COMMITTED','Committed'),('IMPORT_RUN_STATUS','FAILED','Failed'),('IMPORT_RUN_STATUS','ABORTED','Aborted'),
 ('METRIC_TYPE','CANDIDATE','Candidate'),('METRIC_TYPE','ACCEPTED','Accepted'),('METRIC_TYPE','WARNING','Warning'),('METRIC_TYPE','ERROR','Error'),('METRIC_TYPE','QUARANTINED','Quarantined'),
 ('MAPPING_KIND','ELEMENT_MAPPING','Element mapping'),('MAPPING_KIND','STATUS_MAPPING_RULE','Status mapping rule'),('MAPPING_KIND','GOVERNANCE_GUIDANCE','Governance guidance'),
 ('DECISION_STATUS','FINAL','Final'),('DECISION_STATUS','WIP','Work in progress'),('DECISION_STATUS','OPEN','Open'),('DECISION_STATUS','DO NOT MAP','Do not map'),('DECISION_STATUS','N/A','Not applicable'),
 ('CANDIDATE_DISPOSITION','ACCEPTED','Accepted'),('CANDIDATE_DISPOSITION','QUARANTINED','Quarantined'),
 ('SEVERITY','INFO','Information'),('SEVERITY','WARNING','Warning'),('SEVERITY','ERROR','Error'),('SEVERITY','ACCEPTED_EXCEPTION','Accepted exception'),
 ('VALIDATION_OUTCOME','PASS','Pass'),('VALIDATION_OUTCOME','PASS_WITH_WARNINGS','Pass with warnings'),('VALIDATION_OUTCOME','FAIL','Fail'),
 ('FINDING_ROW_ROLE','SUBJECT','Subject'),('FINDING_ROW_ROLE','FIRST_OCCURRENCE','First occurrence'),('FINDING_ROW_ROLE','CONFLICTING','Conflicting'),
 ('QUARANTINE_EVENT_TYPE','OPENED','Opened'),('QUARANTINE_EVENT_TYPE','REVIEWED','Reviewed'),('QUARANTINE_EVENT_TYPE','RESOLUTION_PROPOSED','Resolution proposed'),('QUARANTINE_EVENT_TYPE','APPROVED','Approved'),('QUARANTINE_EVENT_TYPE','SUPERSEDED','Superseded'),('QUARANTINE_EVENT_TYPE','CLOSED','Closed'),
 ('QUARANTINE_RESOLUTION','CORRECTED_IN_NEW_BASELINE','Corrected in new baseline'),('QUARANTINE_RESOLUTION','ACCEPTED_EXCEPTION','Accepted exception'),('QUARANTINE_RESOLUTION','REJECTED','Rejected'),
 ('GOVERNANCE_CLASSIFICATION','DATA_QUALITY','Data quality'),('GOVERNANCE_CLASSIFICATION','GOVERNANCE_DECISION','Governance decision'),('GOVERNANCE_CLASSIFICATION','TEAM_APPROVAL_REQUIRED','Team approval required'),('GOVERNANCE_CLASSIFICATION','TECHNICAL_FIX','Technical fix'),('GOVERNANCE_CLASSIFICATION','RESOLVED_BY_SOURCE_CORRECTION','Resolved by source correction'),('GOVERNANCE_CLASSIFICATION','ACCEPT_WITH_RAW_ERROR_PRESERVED','Accept with raw error preserved'),
 ('GOVERNANCE_ACTION_TYPE','PROPOSED','Proposed'),('GOVERNANCE_ACTION_TYPE','APPROVED','Approved'),('GOVERNANCE_ACTION_TYPE','REJECTED','Rejected'),('GOVERNANCE_ACTION_TYPE','ACKNOWLEDGED','Acknowledged'),('GOVERNANCE_ACTION_TYPE','SUPERSEDED','Superseded'),
 ('EVIDENCE_ROLE','PRIMARY','Primary'),('EVIDENCE_ROLE','SUPPORTING','Supporting'),('EVIDENCE_ROLE','VALIDATION','Validation'),('EVIDENCE_ROLE','RELEASE','Release'),
 ('RELEASE_GATE_OUTCOME','PASSED','Passed'),('RELEASE_GATE_OUTCOME','FAILED','Failed'),('RELEASE_GATE_OUTCOME','PENDING','Pending'),('RELEASE_GATE_OUTCOME','INVALIDATED','Invalidated'),
 ('REQUIREMENT_OUTCOME','PASSED','Passed'),('REQUIREMENT_OUTCOME','FAILED','Failed'),('REQUIREMENT_OUTCOME','NOT_APPLICABLE','Not applicable'),
 ('AUDIT_EVENT_TYPE','READ','Read'),('AUDIT_EVENT_TYPE','EXPORT','Export'),('AUDIT_EVENT_TYPE','ADMINISTRATIVE_ACTION','Administrative action'),
 ('AUDIT_TARGET_TYPE','BASELINE','Baseline'),('AUDIT_TARGET_TYPE','ARTIFACT','Artifact'),('AUDIT_TARGET_TYPE','RAW_EVIDENCE','Raw evidence'),('AUDIT_TARGET_TYPE','GOVERNANCE','Governance'),
 ('AUDIT_OUTCOME','SUCCESS','Success'),('AUDIT_OUTCOME','FAILURE','Failure'),
 ('GUIDANCE_SCOPE','GLOBAL_MAPPING_POLICY','Global mapping policy'),('GUIDANCE_SCOPE','MEDICATION_COMPOSITION','Medication composition'),('GUIDANCE_SCOPE','DOSAGE_TIMING','Dosage timing'),('GUIDANCE_SCOPE','PATIENT_IDENTITY','Patient identity'),('GUIDANCE_SCOPE','TREATMENT_PLAN_ACCESS','Treatment plan access'),
 ('DECISION_TOPIC_CODE','NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING','No source, no inference, and choice handling'),('DECISION_TOPIC_CODE','PRESCRIBED_DRUG_INGREDIENT_REPRESENTATION','Prescribed drug ingredient representation'),('DECISION_TOPIC_CODE','PO_DURATION_CLINICAL_SIGNIFICANCE','PO duration clinical significance'),('DECISION_TOPIC_CODE','CATO_SSN_PATIENT_IDENTIFIER_SEMANTICS','CATO SSN patient identifier semantics'),('DECISION_TOPIC_CODE','PATIENT_IDENTIFIER_FOR_PLAN_RETRIEVAL','Patient identifier for plan retrieval')
)
insert into s2t_fhir.reference_value
 (reference_domain_id, value_code, version_number, display_name, effective_at, is_bootstrap_seed)
select d.reference_domain_id, s.value_code, 1, s.display_name, '2026-09-23 00:00:00+00'::timestamptz, true
from seed s
join s2t_fhir.reference_domain d on d.domain_code = s.domain_code;

create table s2t_fhir.principal (
  principal_id uuid primary key default gen_random_uuid(),
  principal_kind_value_id uuid not null references s2t_fhir.reference_value(reference_value_id),
  external_issuer text not null,
  external_subject text not null,
  display_name text not null,
  disabled_at timestamptz,
  created_at timestamptz not null default transaction_timestamp(),
  constraint principal_external_identity_uq unique (external_issuer, external_subject),
  constraint principal_text_ck check (btrim(external_issuer) <> '' and btrim(external_subject) <> '' and btrim(display_name) <> ''),
  constraint principal_disabled_ck check (disabled_at is null or disabled_at >= created_at)
);

alter table s2t_fhir.reference_value
  add constraint reference_value_creator_fk
  foreign key (created_by_principal_id) references s2t_fhir.principal(principal_id);

reset role;

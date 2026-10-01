set role s2t_fhir_owner;

-- Configuration identities only; this migration creates no baseline or workbook data.
insert into s2t_fhir.principal
  (principal_kind_value_id, external_issuer, external_subject, display_name)
select rv.reference_value_id, 'postgres-role', p.external_subject, p.display_name
from (values
  ('s2t_fhir_migrator', 'S2T FHIR migration service'),
  ('s2t_fhir_importer', 'S2T FHIR import service')
) as p(external_subject, display_name)
join s2t_fhir.reference_value rv on rv.value_code = 'SERVICE'
join s2t_fhir.reference_domain rd on rd.reference_domain_id = rv.reference_domain_id
where rd.domain_code = 'PRINCIPAL_KIND';

with migrator as (
  select principal_id from s2t_fhir.principal
  where external_issuer = 'postgres-role' and external_subject = 's2t_fhir_migrator'
)
insert into s2t_fhir.validation_ruleset
  (ruleset_code, version_label, ruleset_digest, description, implementation_version, created_by_principal_id)
select 'BASELINE_IMPORT', 'v1', pg_catalog.decode('76e2b329dea2c5e480badbb3e0ade6d26563d304c04fa204136669692053e7bc', 'hex'),
       'Governed baseline import validation rules', 'v1', principal_id
from migrator;

with rules(rule_code, rule_version, severity_code, digest_hex, description) as (
  values
    ('MISSING_SOURCE_PROVENANCE','1','ERROR','7d1800f6ef95254e79ece31210f0c04f451d70571133642095a8a8979643adb3','Required source provenance is missing'),
    ('RAW_EVIDENCE_ENVELOPE','1','ERROR','6f4cc322e654821365eb375e75b0eaa775b2e42a7fc4ee21a4cb9cd3f7a536a0','Raw evidence envelope is invalid or inconsistent'),
    ('DUPLICATE_LOGICAL_KEY','1','ERROR','38f08870f88d494a4b88ef1792931cae11492a20a87516512d7f76b95f29f0a5','Logical key collides within one baseline'),
    ('DUPLICATE_SOURCE_ROW','1','ERROR','872b37df53a2e3b7df10798748c92afc087e7b4b7b3ff623cdc2277353b49aa1','Later duplicate source row'),
    ('INVALID_CARDINALITY','1','ERROR','18a8eee96b2143ada08d39e9c5a7b3430fbccb6c798844f6c02df7f15bb0070e','Cardinality is invalid outside an approved exception'),
    ('UNKNOWN_DECISION_STATUS','1','ERROR','53ee7f3661503e5e02ab0263c936e6fdfe335f5d278216a1314f3cf702ce5ac3','Decision status is blank or unknown'),
    ('APPROVED_CARDINALITY_EXCEPTION','1','WARNING','63eba4455b01c6ff671324f50fb9705e2e58b2fa2240720b701eb053c72ef384','Approved blank cardinality exception'),
    ('RAW_OPTIONAL_CELL_ERROR','1','WARNING','23c350d64822e9856f16ef29288f3db702f160dbfe096c5b87fae1d3674204c4','Optional source cell contains a preserved typed error')
), ruleset as (
  select validation_ruleset_id from s2t_fhir.validation_ruleset
  where ruleset_code = 'BASELINE_IMPORT' and version_label = 'v1'
)
insert into s2t_fhir.validation_rule
  (validation_ruleset_id, rule_code, rule_version, default_severity_value_id, rule_definition_digest, description)
select rs.validation_ruleset_id, r.rule_code, r.rule_version, severity.reference_value_id,
       pg_catalog.decode(r.digest_hex, 'hex'), r.description
from rules r
cross join ruleset rs
join s2t_fhir.reference_value severity on severity.value_code = r.severity_code
join s2t_fhir.reference_domain severity_domain on severity_domain.reference_domain_id = severity.reference_domain_id
where severity_domain.domain_code = 'SEVERITY';

with migrator as (
  select principal_id from s2t_fhir.principal
  where external_issuer = 'postgres-role' and external_subject = 's2t_fhir_migrator'
)
insert into s2t_fhir.release_gate_definition
  (gate_code, version_label, definition_digest, description, created_by_principal_id)
select 'BASELINE_IMPORT', 'v1', pg_catalog.decode('d691f9ac508781b8370201b547f65d9c6aa137db13cc7002a0accaa17165b28e', 'hex'),
       'Gate for committing and activating a governed baseline import', principal_id
from migrator;

with gate as (
  select release_gate_definition_id from s2t_fhir.release_gate_definition
  where gate_code = 'BASELINE_IMPORT' and version_label = 'v1'
), requirements(requirement_code, sequence_number, is_blocking, description) as (
  values
    ('AUTHORITATIVE_ARTIFACT_REGISTERED',1,true,'Exactly one authoritative artifact and digest are registered'),
    ('VALIDATION_COMPLETED',2,true,'Validation completed against the current artifact and ruleset'),
    ('GOVERNANCE_APPROVED',3,true,'Applicable governance approvals are recorded'),
    ('PROVENANCE_RECONCILED',4,true,'Required artifact filename, location, digest, and provenance reconciliation is complete')
)
insert into s2t_fhir.release_gate_requirement
  (release_gate_definition_id, requirement_code, sequence_number, is_blocking, description)
select g.release_gate_definition_id, r.requirement_code, r.sequence_number, r.is_blocking, r.description
from gate g cross join requirements r;

reset role;

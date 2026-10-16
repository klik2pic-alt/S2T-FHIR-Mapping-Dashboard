-- Migration 025 retained R1 recovery: SP05-SP11.
-- Run in a NEW direct-psql connection after SP04 has committed and disconnected.
-- No import is finalized in this file; it may safely use one backend.

-- SP05 - publish V1 Candidate.
begin;
do $sp05_resume_guard$
begin
  if (select count(*) from s2t_fhir.import_run ir join s2t_fhir.reference_value s on s.reference_value_id=ir.terminal_status_value_id
      where ir.import_run_id='02550303-0000-4000-8000-000000000001'
        and ir.baseline_version_id='02550301-0000-4000-8000-000000000001'
        and ir.artifact_id='02550302-0000-4000-8000-000000000001'
        and ir.completed_at is not null and s.value_code='COMMITTED') <> 1
     or (select count(*) from s2t_fhir.artifact where artifact_id='02550302-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.baseline_artifact where baseline_version_id='02550301-0000-4000-8000-000000000001' and artifact_id='02550302-0000-4000-8000-000000000001') <> 1
     or exists(select 1 from s2t_fhir.mapping_record where baseline_version_id='02550301-0000-4000-8000-000000000001')
     or (select count(*) from s2t_fhir.baseline_version
         where baseline_version_id in ('02550101-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001','02550301-0000-4000-8000-000000000001')
           and baseline_series_id='02550000-0000-4000-8000-000000000001') <> 3
     or exists(select 1 from s2t_fhir.baseline_lifecycle_event e join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_candidate_context c join s2t_fhir.baseline_version b using(baseline_version_id) where b.baseline_series_id='02550000-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.review_session where baseline_version_id in ('02550101-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id in ('02550108-0000-4000-8000-000000000001','02550208-0000-4000-8000-000000000001'))
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id in ('02550109-0000-4000-8000-000000000001','02550209-0000-4000-8000-000000000001')) then
    raise exception 'SP05 resume: SP04 is not exact or downstream state already exists' using errcode='55000';
  end if;
end $sp05_resume_guard$;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('02550101-0000-4000-8000-000000000001','02550103-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'SP05' checkpoint,'COMPLETE' state;

-- SP06 - complete V1 review.
begin;
create temp table pg_temp.sp06_resume_context(baseline_version_id uuid primary key,candidate_lifecycle_event_id uuid not null,review_session_id uuid) on commit drop;
insert into pg_temp.sp06_resume_context(baseline_version_id,candidate_lifecycle_event_id)
select c.baseline_version_id,c.candidate_lifecycle_event_id
from s2t_fhir.baseline_candidate_context c
join s2t_fhir.current_baseline_lifecycle_event e on e.baseline_lifecycle_event_id=c.candidate_lifecycle_event_id
join s2t_fhir.reference_value s on s.reference_value_id=e.lifecycle_status_value_id
where c.baseline_version_id='02550101-0000-4000-8000-000000000001' and s.value_code='CANDIDATE';
do $sp06_resume_guard$
begin
  if (select count(*) from pg_temp.sp06_resume_context) <> 1
     or (select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id='02550101-0000-4000-8000-000000000001') <> 1
     or exists(select 1 from s2t_fhir.review_session where baseline_version_id='02550101-0000-4000-8000-000000000001' or session_name='T025-STALE-20261016-R1-V1-REVIEW')
     or exists(select 1 from s2t_fhir.mapping_review_event where baseline_version_id='02550101-0000-4000-8000-000000000001') then
    raise exception 'SP06 resume: SP05 is not exact or SP06 is already/partially present' using errcode='55000';
  end if;
end $sp06_resume_guard$;
grant select,update(review_session_id) on pg_temp.sp06_resume_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
update pg_temp.sp06_resume_context set review_session_id=s2t_fhir_api.start_authenticated_candidate_review_session(baseline_version_id,candidate_lifecycle_event_id,'T025-STALE-20261016-R1-V1-REVIEW','Complete retained fixture V1 review');
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed('02550101-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp06_resume_context),'map-v1-'||md5('T025-STALE-20261016-R1-V1-node-1')||md5('T025-STALE-20261016-R1-V1-node-2'),(select review_session_id from pg_temp.sp06_resume_context),'T025 stale V1 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session('02550101-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp06_resume_context),(select review_session_id from pg_temp.sp06_resume_context));
reset role;
commit;
select 'SP06' checkpoint,'COMPLETE' state;

-- SP07 - V1 validation and passed gate.
begin;
set local role s2t_fhir_owner;
do $sp07_resume_guard$
begin
  if (select count(*) from s2t_fhir.review_session rs
      where rs.session_name='T025-STALE-20261016-R1-V1-REVIEW'
        and rs.baseline_version_id='02550101-0000-4000-8000-000000000001' and rs.ended_at is not null) <> 1
     or (select count(*) from s2t_fhir.mapping_review_event e join s2t_fhir.reference_value s on s.reference_value_id=e.review_status_value_id
         where e.baseline_version_id='02550101-0000-4000-8000-000000000001' and s.value_code='REVIEWED') <> 1
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='02550108-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550109-0000-4000-8000-000000000001') then
    raise exception 'SP07 resume: SP06 is not exact or SP07 is already/partially present' using errcode='55000';
  end if;
end $sp07_resume_guard$;
insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '02550108-0000-4000-8000-000000000001','02550103-0000-4000-8000-000000000001',r.validation_ruleset_id,'02550102-0000-4000-8000-000000000001',a.sha256_digest,decode(md5('T025-STALE-20261016-R1-V1-validation-1')||md5('T025-STALE-20261016-R1-V1-validation-2'),'hex'),transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,o.reference_value_id,'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1') from s2t_fhir.validation_ruleset r join s2t_fhir.artifact a on a.artifact_id='02550102-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASS' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='VALIDATION_OUTCOME' where r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1';
insert into s2t_fhir.release_gate_evaluation(release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,initiating_human_principal_id,summary)
select '02550109-0000-4000-8000-000000000001','02550101-0000-4000-8000-000000000001',g.release_gate_definition_id,'02550102-0000-4000-8000-000000000001',a.sha256_digest,r.validation_ruleset_id,'02550108-0000-4000-8000-000000000001',o.reference_value_id,transaction_timestamp(),'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V1 PASSED' from s2t_fhir.release_gate_definition g join s2t_fhir.validation_ruleset r on r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1' join s2t_fhir.artifact a on a.artifact_id='02550102-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '02550109-0000-4000-8000-000000000001',req.release_gate_requirement_id,o.reference_value_id,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V1','requirement',req.requirement_code),'T025 stale V1 '||req.requirement_code from s2t_fhir.release_gate_requirement req join s2t_fhir.release_gate_definition g using(release_gate_definition_id) join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
commit;
select 'SP07' checkpoint,'COMPLETE' state;

-- SP08 - promote V1 to ACTIVE.
begin;
create temp table pg_temp.sp08_resume_context(candidate_lifecycle_event_id uuid not null) on commit drop;
insert into pg_temp.sp08_resume_context select c.candidate_lifecycle_event_id from s2t_fhir.baseline_candidate_context c join s2t_fhir.current_baseline_lifecycle_event e on e.baseline_lifecycle_event_id=c.candidate_lifecycle_event_id where c.baseline_version_id='02550101-0000-4000-8000-000000000001';
do $sp08_resume_guard$
begin
  if (select count(*) from pg_temp.sp08_resume_context) <> 1
     or (select count(*) from s2t_fhir.validation_run where validation_run_id='02550108-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550109-0000-4000-8000-000000000001' and baseline_version_id='02550101-0000-4000-8000-000000000001') <> 1
     or exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='02550101-0000-4000-8000-000000000001') then
    raise exception 'SP08 resume: SP07 is not exact or SP08 is already/partially present' using errcode='55000';
  end if;
end $sp08_resume_guard$;
grant select on pg_temp.sp08_resume_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
select s2t_fhir_api.promote_candidate_baseline('02550101-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp08_resume_context),'02550103-0000-4000-8000-000000000001','02550109-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'SP08' checkpoint,'COMPLETE' state;

-- SP09 - publish V2 Candidate.
begin;
do $sp09_resume_guard$
begin
  if (select count(*) from s2t_fhir.baseline_activation_context where baseline_version_id='02550101-0000-4000-8000-000000000001' and import_run_id='02550103-0000-4000-8000-000000000001' and release_gate_evaluation_id='02550109-0000-4000-8000-000000000001') <> 1
     or (select count(*) from s2t_fhir.current_baseline_lifecycle_event e join s2t_fhir.reference_value s on s.reference_value_id=e.lifecycle_status_value_id where e.baseline_version_id='02550101-0000-4000-8000-000000000001' and s.value_code='ACTIVE') <> 1
     or exists(select 1 from s2t_fhir.baseline_lifecycle_event where baseline_version_id='02550201-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_candidate_context where baseline_version_id='02550201-0000-4000-8000-000000000001') then
    raise exception 'SP09 resume: SP08 is not exact or SP09 is already/partially present' using errcode='55000';
  end if;
end $sp09_resume_guard$;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('02550201-0000-4000-8000-000000000001','02550203-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'SP09' checkpoint,'COMPLETE' state;

-- SP10 - complete V2 review.
begin;
create temp table pg_temp.sp10_resume_context(baseline_version_id uuid primary key,candidate_lifecycle_event_id uuid not null,review_session_id uuid) on commit drop;
insert into pg_temp.sp10_resume_context(baseline_version_id,candidate_lifecycle_event_id)
select c.baseline_version_id,c.candidate_lifecycle_event_id from s2t_fhir.baseline_candidate_context c join s2t_fhir.current_baseline_lifecycle_event e on e.baseline_lifecycle_event_id=c.candidate_lifecycle_event_id join s2t_fhir.reference_value s on s.reference_value_id=e.lifecycle_status_value_id where c.baseline_version_id='02550201-0000-4000-8000-000000000001' and s.value_code='CANDIDATE';
do $sp10_resume_guard$
begin
  if (select count(*) from pg_temp.sp10_resume_context) <> 1
     or (select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id='02550201-0000-4000-8000-000000000001' and import_run_id='02550203-0000-4000-8000-000000000001') <> 1
     or exists(select 1 from s2t_fhir.review_session where baseline_version_id='02550201-0000-4000-8000-000000000001' or session_name='T025-STALE-20261016-R1-V2-REVIEW')
     or exists(select 1 from s2t_fhir.mapping_review_event where baseline_version_id='02550201-0000-4000-8000-000000000001') then
    raise exception 'SP10 resume: SP09 is not exact or SP10 is already/partially present' using errcode='55000';
  end if;
end $sp10_resume_guard$;
grant select,update(review_session_id) on pg_temp.sp10_resume_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','0255a001-0000-4000-8000-000000000001',true);
update pg_temp.sp10_resume_context set review_session_id=s2t_fhir_api.start_authenticated_candidate_review_session(baseline_version_id,candidate_lifecycle_event_id,'T025-STALE-20261016-R1-V2-REVIEW','Complete retained fixture V2 review');
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed('02550201-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp10_resume_context),'map-v1-'||md5('T025-STALE-20261016-R1-V2-node-1')||md5('T025-STALE-20261016-R1-V2-node-2'),(select review_session_id from pg_temp.sp10_resume_context),'T025 stale V2 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session('02550201-0000-4000-8000-000000000001',(select candidate_lifecycle_event_id from pg_temp.sp10_resume_context),(select review_session_id from pg_temp.sp10_resume_context));
reset role;
commit;
select 'SP10' checkpoint,'COMPLETE' state;

-- SP11 - V2 validation/gate; final READY_FOR_STALE_TEST state.
begin;
set local role s2t_fhir_owner;
do $sp11_resume_guard$
begin
  if (select count(*) from s2t_fhir.review_session where session_name='T025-STALE-20261016-R1-V2-REVIEW' and baseline_version_id='02550201-0000-4000-8000-000000000001' and ended_at is not null) <> 1
     or (select count(*) from s2t_fhir.mapping_review_event e join s2t_fhir.reference_value s on s.reference_value_id=e.review_status_value_id where e.baseline_version_id='02550201-0000-4000-8000-000000000001' and s.value_code='REVIEWED') <> 1
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='02550208-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='02550209-0000-4000-8000-000000000001') then
    raise exception 'SP11 resume: SP10 is not exact or SP11 is already/partially present' using errcode='55000';
  end if;
end $sp11_resume_guard$;
insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '02550208-0000-4000-8000-000000000001','02550203-0000-4000-8000-000000000001',r.validation_ruleset_id,'02550202-0000-4000-8000-000000000001',a.sha256_digest,decode(md5('T025-STALE-20261016-R1-V2-validation-1')||md5('T025-STALE-20261016-R1-V2-validation-2'),'hex'),transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,o.reference_value_id,'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001',jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2') from s2t_fhir.validation_ruleset r join s2t_fhir.artifact a on a.artifact_id='02550202-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASS' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='VALIDATION_OUTCOME' where r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1';
insert into s2t_fhir.release_gate_evaluation(release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,initiating_human_principal_id,summary)
select '02550209-0000-4000-8000-000000000001','02550201-0000-4000-8000-000000000001',g.release_gate_definition_id,'02550202-0000-4000-8000-000000000001',a.sha256_digest,r.validation_ruleset_id,'02550208-0000-4000-8000-000000000001',o.reference_value_id,transaction_timestamp(),'0255a000-0000-4000-8000-000000000001','0255a000-0000-4000-8000-000000000001','T025-STALE-20261016-R1-V2 PASSED' from s2t_fhir.release_gate_definition g join s2t_fhir.validation_ruleset r on r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1' join s2t_fhir.artifact a on a.artifact_id='02550202-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '02550209-0000-4000-8000-000000000001',req.release_gate_requirement_id,o.reference_value_id,jsonb_build_object('fixture','T025-STALE-20261016-R1','version','V2','requirement',req.requirement_code),'T025 stale V2 '||req.requirement_code from s2t_fhir.release_gate_requirement req join s2t_fhir.release_gate_definition g using(release_gate_definition_id) join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
commit;
select 'SP11' checkpoint,'COMPLETE_READY_FOR_STALE_TEST' state,'T025-STALE-20261016-R1' fixture_id;

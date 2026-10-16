-- Migration 025 rollback-only runtime acceptance.
-- Requires accepted Migration 025 and retained fixture T023-CONC-PACK-20261009-R1.
-- All mutations occur inside this transaction and are rolled back.

begin;
set local role s2t_fhir_owner;
set constraints all deferred;

create temp table pg_temp.test_025_results (
  test_no integer primary key,
  test_name text not null,
  result text not null,
  detail text
) on commit drop;

create temp table pg_temp.test_025_context (
  key text primary key,
  value jsonb not null
) on commit drop;

grant insert on table pg_temp.test_025_results to authenticated;
grant select, insert on table pg_temp.test_025_context to authenticated;

do $fixture_gate$
begin
  if (select count(*) from s2t_fhir.mapping_resource_registry
      where resource_config_id in (
        't023-conc-pack-20261009-r1-c03-resource',
        't023-conc-pack-20261009-r1-c04-resource',
        't023-conc-pack-20261009-r1-c05-resource',
        't023-conc-pack-20261009-r1-c06-resource')) <> 4
     or not exists (
       select 1 from s2t_fhir.baseline_candidate_context
       where baseline_version_id='023c0511-0000-4000-8000-000000000001'::uuid
     ) then
    raise exception '025 runtime prerequisite: retained 023 C03-C06 fixture is absent or incomplete'
      using errcode='55000';
  end if;

  if not exists (
       select 1
       from s2t_fhir.baseline_series s
       where s.baseline_series_id='023c0200-0000-4000-8000-000000000002'::uuid
         and s.source_system='T023-CONC-PACK-20261009-R1-C02'
         and s.fhir_resource='MedicationRequest'
     )
     or not exists (
       select 1
       from s2t_fhir.baseline_version b
       join s2t_fhir.baseline_candidate_context c
         on c.baseline_version_id=b.baseline_version_id
       join s2t_fhir.current_baseline_lifecycle_event e
         on e.baseline_version_id=b.baseline_version_id
        and e.baseline_lifecycle_event_id=c.candidate_lifecycle_event_id
       join s2t_fhir.reference_value status
         on status.reference_value_id=e.lifecycle_status_value_id
       join s2t_fhir.reference_domain domain
         on domain.reference_domain_id=status.reference_domain_id
        and domain.domain_code='BASELINE_LIFECYCLE_STATUS'
       where b.baseline_series_id='023c0200-0000-4000-8000-000000000002'::uuid
         and b.baseline_version_id='023c0201-0000-4000-8000-000000000001'::uuid
         and c.artifact_id='023c0202-0000-4000-8000-000000000001'::uuid
         and c.import_run_id='023c0203-0000-4000-8000-000000000001'::uuid
         and status.value_code='CANDIDATE'
     )
     or (select count(*)
         from s2t_fhir.baseline_version b
         join s2t_fhir.current_baseline_lifecycle_event e
           on e.baseline_version_id=b.baseline_version_id
         join s2t_fhir.reference_value status
           on status.reference_value_id=e.lifecycle_status_value_id
         join s2t_fhir.reference_domain domain
           on domain.reference_domain_id=status.reference_domain_id
          and domain.domain_code='BASELINE_LIFECYCLE_STATUS'
         where b.baseline_series_id='023c0200-0000-4000-8000-000000000002'::uuid
           and status.value_code='CANDIDATE') <> 1
     or exists (
       select 1 from s2t_fhir.mapping_record
       where baseline_version_id='023c0201-0000-4000-8000-000000000001'::uuid
     )
     or exists (
       select 1 from s2t_fhir.mapping_resource_registry
       where source_system='T023-CONC-PACK-20261009-R1-C02'
         and fhir_resource='MedicationRequest'
     )
     or exists (
       select 1 from s2t_fhir.mapping_resource_registry
       where resource_config_id='t025-rollback-c02-resource'
     ) then
    raise exception '025 runtime prerequisite: retained 023 C02 no-mapping Candidate fixture is absent, drifted, or already registered'
      using errcode='55000';
  end if;
end
$fixture_gate$;

insert into s2t_fhir.mapping_resource_registry
  (resource_config_id,source_system,fhir_resource,is_enabled)
values
  ('t025-rollback-c02-resource','T023-CONC-PACK-20261009-R1-C02',
   'MedicationRequest',true);

insert into pg_temp.test_025_context(key,value)
select 'c05-before',s2t_fhir_api._candidate_ui_snapshot(
  't023-conc-pack-20261009-r1-c05-resource');
insert into pg_temp.test_025_context(key,value)
select 'c03-before',s2t_fhir_api._candidate_ui_snapshot(
  't023-conc-pack-20261009-r1-c03-resource');
insert into pg_temp.test_025_context(key,value)
select 'c04-before',s2t_fhir_api._candidate_ui_snapshot(
  't023-conc-pack-20261009-r1-c04-resource');
insert into pg_temp.test_025_context(key,value)
select 'c04-question',pg_catalog.jsonb_build_object('questionId',q.question_id)
from s2t_governance.governance_question q
where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION';

-- T01-T07: cohesive context, ACTIVE/Candidate variants, exact publication and
-- validation/gate evidence on the retained C05 ready fixture.
insert into pg_temp.test_025_results
select 1,'fresh-load Candidate context',
  case when value#>>'{candidate,baselineVersionId}'=
       '023c0511-0000-4000-8000-000000000001'
       then 'PASS' else 'FAIL' end,value::text
from pg_temp.test_025_context
where key='c05-before';

insert into pg_temp.test_025_results
select 2,'ACTIVE plus Candidate exact',
  case when value#>>'{active,baselineVersionId}'=
       '023c0501-0000-4000-8000-000000000001'
       then 'PASS' else 'FAIL' end,value::text
from pg_temp.test_025_context where key='c05-before';

insert into pg_temp.test_025_results
select 3,'Candidate with no ACTIVE',
  case when value->'candidate'<>'null'::jsonb and value->'active'='null'::jsonb
       then 'PASS' else 'FAIL' end,value::text
from pg_temp.test_025_context where key='c03-before';

insert into pg_temp.test_025_results
select 4,'exact Candidate import and artifact',
  case when value#>>'{candidate,importRunId}'=
       '023c0513-0000-4000-8000-000000000001'
       and value#>>'{candidate,artifactId}'=
       '023c0512-0000-4000-8000-000000000001'
       then 'PASS' else 'FAIL' end,value::text
from pg_temp.test_025_context where key='c05-before';

insert into pg_temp.test_025_results
select 5,'validation evidence exact',
  case when value#>>'{validation,validationRunId}'=
       '023c0518-0000-4000-8000-000000000001'
       and value#>>'{validation,outcome}'='PASS'
       then 'PASS' else 'FAIL' end,value::text
from pg_temp.test_025_context where key='c05-before';

insert into pg_temp.test_025_results
select 6,'passed release gate evidence exact',
  case when value#>>'{releaseGate,releaseGateEvaluationId}'=
       '023c0519-0000-4000-8000-000000000001'
       and value#>>'{releaseGate,outcome}'='PASSED'
       then 'PASS' else 'FAIL' end,value::text
from pg_temp.test_025_context where key='c05-before';

insert into pg_temp.test_025_results
select 7,'gate missing blocker',
  case when evaluation->'blockers' @>
       '[{"code":"RELEASE_GATE_MISSING"}]'::jsonb
       then 'PASS' else 'FAIL' end,evaluation::text
from (
  select s2t_fhir._evaluate_candidate_promotion_readiness(
    (value#>>'{candidate,baselineVersionId}')::uuid,
    (value#>>'{candidate,lifecycleEventId}')::uuid,
    (value#>>'{candidate,importRunId}')::uuid,
    null,null,null,pg_catalog.transaction_timestamp(),false,false
  ) evaluation
  from pg_temp.test_025_context where key='c03-before'
) x;

-- Create a structurally valid, non-passed current gate on C03. This evidence is
-- diagnostic only and is rolled back with the suite.
insert into s2t_fhir.validation_run(
  validation_run_id,import_run_id,validation_ruleset_id,artifact_id,
  artifact_digest,execution_fingerprint,started_at,completed_at,
  candidate_count,accepted_count,warning_count,error_count,quarantined_count,
  outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json
)
select
  '02500000-0000-4000-8000-000000000071'::uuid,
  '023c0303-0000-4000-8000-000000000001'::uuid,
  template.validation_ruleset_id,
  '023c0302-0000-4000-8000-000000000001'::uuid,
  artifact.sha256_digest,
  pg_catalog.decode(pg_catalog.md5('T025-C03-FAILED-V1')||
                    pg_catalog.md5('T025-C03-FAILED-V2'),'hex'),
  pg_catalog.transaction_timestamp()-interval '2 seconds',
  pg_catalog.transaction_timestamp()-interval '1 second',
  1,1,0,0,0,template.outcome_value_id,
  '023c03a0-0000-4000-8000-000000000001'::uuid,
  '023c03a0-0000-4000-8000-000000000001'::uuid,
  '{"fixture":"T025-ROLLBACK"}'::jsonb
from s2t_fhir.validation_run template
join s2t_fhir.artifact artifact
  on artifact.artifact_id='023c0302-0000-4000-8000-000000000001'::uuid
where template.validation_run_id='023c0518-0000-4000-8000-000000000001'::uuid;

insert into s2t_fhir.release_gate_evaluation(
  release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,
  artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,
  gate_outcome_value_id,evaluated_at,actor_principal_id,
  initiating_human_principal_id,summary
)
select
  '02500000-0000-4000-8000-000000000072'::uuid,
  '023c0301-0000-4000-8000-000000000001'::uuid,
  template.release_gate_definition_id,
  '023c0302-0000-4000-8000-000000000001'::uuid,
  artifact.sha256_digest,validation.validation_ruleset_id,
  validation.validation_run_id,outcome.reference_value_id,
  pg_catalog.transaction_timestamp()-interval '500 milliseconds',
  '023c03a0-0000-4000-8000-000000000001'::uuid,
  '023c03a0-0000-4000-8000-000000000001'::uuid,
  'T025 rollback non-passed gate'
from s2t_fhir.release_gate_evaluation template
join s2t_fhir.validation_run validation
  on validation.validation_run_id='02500000-0000-4000-8000-000000000071'::uuid
join s2t_fhir.artifact artifact
  on artifact.artifact_id=validation.artifact_id
join s2t_fhir.reference_value outcome on outcome.value_code='FAILED'
join s2t_fhir.reference_domain domain
  on domain.reference_domain_id=outcome.reference_domain_id
 and domain.domain_code='RELEASE_GATE_OUTCOME'
where template.release_gate_evaluation_id=
  '023c0519-0000-4000-8000-000000000001'::uuid;

insert into pg_temp.test_025_results
select 8,'gate not passed blocker',
  case when evaluation->'blockers' @>
       '[{"code":"RELEASE_GATE_NOT_PASSED"}]'::jsonb
       then 'PASS' else 'FAIL' end,evaluation::text
from (
  select s2t_fhir._evaluate_candidate_promotion_readiness(
    '023c0301-0000-4000-8000-000000000001'::uuid,
    (value#>>'{candidate,lifecycleEventId}')::uuid,
    '023c0303-0000-4000-8000-000000000001'::uuid,
    '02500000-0000-4000-8000-000000000072'::uuid,
    null,null,pg_catalog.transaction_timestamp(),false,false
  ) evaluation
  from pg_temp.test_025_context where key='c03-before'
) x;

insert into pg_temp.test_025_results
select 9,'incomplete Candidate review blocker',
  case when evaluation->'blockers' @>
       '[{"code":"REVIEW_INCOMPLETE"}]'::jsonb
       then 'PASS' else 'FAIL' end,evaluation::text
from (
  select s2t_fhir._evaluate_candidate_promotion_readiness(
    '023c0301-0000-4000-8000-000000000001'::uuid,
    (value#>>'{candidate,lifecycleEventId}')::uuid,
    '023c0303-0000-4000-8000-000000000001'::uuid,
    '02500000-0000-4000-8000-000000000072'::uuid,
    null,null,pg_catalog.transaction_timestamp(),false,false
  ) evaluation from pg_temp.test_025_context where key='c03-before'
) x;

insert into pg_temp.test_025_results
select 10,'open review session blocker',
  case when evaluation->'blockers' @>
       '[{"code":"OPEN_REVIEW_SESSION_EXISTS"}]'::jsonb
       then 'PASS' else 'FAIL' end,evaluation::text
from (
  select s2t_fhir._evaluate_candidate_promotion_readiness(
    '023c0301-0000-4000-8000-000000000001'::uuid,
    (value#>>'{candidate,lifecycleEventId}')::uuid,
    '023c0303-0000-4000-8000-000000000001'::uuid,
    '02500000-0000-4000-8000-000000000072'::uuid,
    null,null,pg_catalog.transaction_timestamp(),false,false
  ) evaluation from pg_temp.test_025_context where key='c03-before'
) x;

-- C02-V1 is the current Candidate and has no accepted governed mappings.
insert into pg_temp.test_025_results
select 11,'no Candidate mappings blocker',
  case when count(*)=1 and bool_and(evaluation->'blockers' @>
       '[{"code":"NO_CANDIDATE_MAPPINGS"}]'::jsonb
       ) then 'PASS' else 'FAIL' end,
  case when count(*)=1 then min(evaluation::text)
       else pg_catalog.format('matching Candidate contexts=%s',count(*)) end
from (
  select s2t_fhir._evaluate_candidate_promotion_readiness(
    c.baseline_version_id,c.candidate_lifecycle_event_id,c.import_run_id,
    null,null,null,pg_catalog.transaction_timestamp(),false,false
  ) evaluation
  from s2t_fhir.baseline_version b
  join s2t_fhir.baseline_candidate_context c
    on c.baseline_version_id=b.baseline_version_id
  join s2t_fhir.current_baseline_lifecycle_event e
    on e.baseline_version_id=b.baseline_version_id
   and e.baseline_lifecycle_event_id=c.candidate_lifecycle_event_id
  join s2t_fhir.reference_value status
    on status.reference_value_id=e.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id=status.reference_domain_id
   and domain.domain_code='BASELINE_LIFECYCLE_STATUS'
  where b.baseline_series_id='023c0200-0000-4000-8000-000000000002'::uuid
    and status.value_code='CANDIDATE'
) x;

-- T12-T15 capability combinations.
reset role;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c05a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 12,'capability review plus promote',
  case when r='{"canReviewCandidate": true, "canPromoteCandidate": true}'::jsonb
       then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_ui_capabilities() r) x;

insert into pg_temp.test_025_results
select 29,'authenticated public fresh-load context',
  case when r#>>'{candidate,baselineVersionId}'=
       '023c0511-0000-4000-8000-000000000001'
       and r#>>'{active,baselineVersionId}'=
       '023c0501-0000-4000-8000-000000000001'
       then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_candidate_ui_context(
  't023-conc-pack-20261009-r1-c05-resource') r) x;

select pg_catalog.set_config('request.jwt.claim.sub',
  '023c03a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 13,'capability review only',
  case when r='{"canReviewCandidate": true, "canPromoteCandidate": false}'::jsonb
       then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_ui_capabilities() r) x;

insert into pg_temp.test_025_results
select 27,'reviewer readiness includes capability blocker',
  case when r->>'canPromoteCandidate'='false'
       and r->'blockers' @> '[{"code":"PROMOTE_CAPABILITY_MISSING"}]'::jsonb
       then 'PASS' else 'FAIL' end,r::text
from (
  select s2t_fhir_api.get_candidate_promotion_readiness(
    't023-conc-pack-20261009-r1-c03-resource',
    (value#>>'{candidate,baselineVersionId}')::uuid,
    (value#>>'{candidate,lifecycleEventId}')::uuid,
    null,null,pg_catalog.transaction_timestamp()) r
  from pg_temp.test_025_context where key='c03-before'
) x;

select pg_catalog.set_config('request.jwt.claim.sub',
  '023c05b1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 14,'capability promote only',
  case when r='{"canReviewCandidate": false, "canPromoteCandidate": true}'::jsonb
       then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_ui_capabilities() r) x;

select pg_catalog.set_config('request.jwt.claim.sub',
  '02500000-0000-4000-8000-000000000029',true);
do $test$
begin
  perform s2t_fhir_api.get_my_candidate_ui_capabilities();
  insert into pg_temp.test_025_results values
    (28,'unmapped identity fails authorization','FAIL','unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_025_results values
    (28,'unmapped identity fails authorization','PASS',sqlerrm);
when others then
  insert into pg_temp.test_025_results values
    (28,'unmapped identity fails authorization','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

select pg_catalog.set_config('request.jwt.claim.sub',
  '023c03b1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 15,'capability neither for valid principal',
  case when r='{"canReviewCandidate": false, "canPromoteCandidate": false}'::jsonb
       then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_ui_capabilities() r) x;

-- T16-T18 Candidate session NONE / OPEN_CURRENT / CLOSED.
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c04a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 16,'Candidate review session NONE',
  case when r->>'state'='NONE' then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_review_session(
  '023c0401-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c04-before')) r) x;

select pg_catalog.set_config('request.jwt.claim.sub',
  '023c03a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 17,'Candidate review session OPEN_CURRENT',
  case when r->>'state'='OPEN_CURRENT' then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_review_session(
  '023c0301-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c03-before')) r) x;

select pg_catalog.set_config('request.jwt.claim.sub',
  '023c05a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 18,'Candidate review session CLOSED',
  case when r->>'state'='CLOSED' then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_review_session(
  '023c0511-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c05-before')) r) x;

-- T19 ambiguous session fail-closed: C03 already has one open session.
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c03a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.start_authenticated_candidate_review_session(
  '023c0301-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c03-before'),
  'T025-ROLLBACK-AMBIGUOUS-SESSION','rollback-only ambiguity');
do $test$
begin
  perform s2t_fhir_api.get_my_candidate_review_session(
    '023c0301-0000-4000-8000-000000000001'::uuid,
    (select (value#>>'{candidate,lifecycleEventId}')::uuid
     from pg_temp.test_025_context where key='c03-before'));
  insert into pg_temp.test_025_results values
    (19,'ambiguous open session fails closed','FAIL','unexpected success');
exception when sqlstate '23514' then
  insert into pg_temp.test_025_results values
    (19,'ambiguous open session fails closed','PASS',sqlerrm);
when others then
  insert into pg_temp.test_025_results values
    (19,'ambiguous open session fails closed','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

-- T20 Candidate governance link provenance.
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c04a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.gov_link_candidate_mapping(
  (select (value#>>'{questionId}')::uuid
   from pg_temp.test_025_context where key='c04-question'),
  '023c0401-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c04-before'),
  pg_catalog.jsonb_build_object(
    'resource_config_id','t023-conc-pack-20261009-r1-c04-resource',
    'baseline_code','T023-CONC-PACK-20261009-R1-C04-V1',
    'node_id','map-v1-'||pg_catalog.md5('T023-CONC-PACK-20261009-R1-C04-V1-node-1')||
      pg_catalog.md5('T023-CONC-PACK-20261009-R1-C04-V1-node-2')),
  pg_catalog.transaction_timestamp());
insert into pg_temp.test_025_results
select 20,'governance Candidate provenance visible',
  case when count(*)=1 then 'PASS' else 'FAIL' end,
  pg_catalog.format('matching rows=%s',count(*))
from s2t_fhir_api.governance_mapping_links
where baseline_version_id='023c0401-0000-4000-8000-000000000001'::uuid
  and review_target_lifecycle_event_id=
    (select (value#>>'{candidate,lifecycleEventId}')::uuid
     from pg_temp.test_025_context where key='c04-before')
  and lifecycle_status_at_link='CANDIDATE';

-- T21 historical ACTIVE-compatible row keeps appended provenance NULL.
reset role;
set local role s2t_fhir_owner;
with inserted as (
  insert into s2t_governance.governance_mapping_link(
    question_id,resource_config_id,baseline_code,node_id,mapping_kind,
    fhir_resource_type,target_element,linked_by_principal
  ) values (
    (select q.question_id from s2t_governance.governance_question q
     where q.title='T023-CONC-PACK-20261009-R1-C04-QUESTION'),
    't023-conc-pack-20261009-r1-c04-resource','T025-HISTORICAL-ACTIVE',
    'T025-HISTORICAL-ACTIVE-NODE','ELEMENT_MAPPING','MedicationRequest',
    'MedicationRequest.status','023c04a0-0000-4000-8000-000000000001'::uuid
  ) returning link_id,question_id
)
insert into s2t_governance.governance_event(
  question_id,event_type,effective_at,recorded_by_principal,link_id)
select question_id,'MAPPING_LINKED',pg_catalog.transaction_timestamp(),
       '023c04a0-0000-4000-8000-000000000001'::uuid,link_id
from inserted;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c04a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 21,'historical ACTIVE governance compatibility',
  case when count(*)=1 and count(*) filter(where baseline_version_id is null
    and review_target_lifecycle_event_id is null
    and lifecycle_status_at_link is null)=1 then 'PASS' else 'FAIL' end,
  pg_catalog.format('rows=%s',count(*))
from s2t_fhir_api.governance_mapping_links
where node_id='T025-HISTORICAL-ACTIVE-NODE';

-- T26 OPEN_FROZEN: open a C04 session, then publish the retained unpublished
-- replacement through the governed public mutation. The old session must be
-- discoverable by its exact old Candidate identity as frozen.
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c04a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.start_authenticated_candidate_review_session(
  '023c0401-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c04-before'),
  'T025-ROLLBACK-OPEN-FROZEN','rollback-only frozen discovery');
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c04b1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline(
  '023c0411-0000-4000-8000-000000000001'::uuid,
  '023c0413-0000-4000-8000-000000000001'::uuid,
  '023c0401-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c04-before'),
  pg_catalog.transaction_timestamp(),'T025 rollback frozen-session replacement');
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c04a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_results
select 26,'Candidate review session OPEN_FROZEN',
  case when r->>'state'='OPEN_FROZEN' then 'PASS' else 'FAIL' end,r::text
from (select s2t_fhir_api.get_my_candidate_review_session(
  '023c0401-0000-4000-8000-000000000001'::uuid,
  (select (value#>>'{candidate,lifecycleEventId}')::uuid
   from pg_temp.test_025_context where key='c04-before')) r) x;

-- T22 readiness and actual Promotion parity on C05 ready replacement.
select pg_catalog.set_config('request.jwt.claim.sub',
  '023c05a1-0000-4000-8000-000000000001',true);
insert into pg_temp.test_025_context(key,value)
select 'c05-readiness',s2t_fhir_api.get_candidate_promotion_readiness(
  't023-conc-pack-20261009-r1-c05-resource',
  (value#>>'{candidate,baselineVersionId}')::uuid,
  (value#>>'{candidate,lifecycleEventId}')::uuid,
  (value#>>'{active,baselineVersionId}')::uuid,
  (value#>>'{active,lifecycleEventId}')::uuid,
  pg_catalog.transaction_timestamp())
from pg_temp.test_025_context where key='c05-before';

do $test$
declare v_before jsonb; v_ready jsonb; v_result jsonb;
begin
  select value into strict v_before from pg_temp.test_025_context where key='c05-before';
  select value into strict v_ready from pg_temp.test_025_context where key='c05-readiness';
  if not (v_ready->>'ready')::boolean then
    insert into pg_temp.test_025_results values
      (22,'readiness and Promotion parity','FAIL','readiness='||v_ready::text);
    return;
  end if;
  v_result:=s2t_fhir_api.promote_candidate_baseline(
    (v_before#>>'{candidate,baselineVersionId}')::uuid,
    (v_before#>>'{candidate,lifecycleEventId}')::uuid,
    (v_before#>>'{candidate,importRunId}')::uuid,
    (v_before#>>'{releaseGate,releaseGateEvaluationId}')::uuid,
    (v_before#>>'{active,baselineVersionId}')::uuid,
    (v_before#>>'{active,lifecycleEventId}')::uuid,
    pg_catalog.transaction_timestamp(),
    'T025 rollback-only readiness parity');
  insert into pg_temp.test_025_results values
    (22,'readiness and Promotion parity','PASS',v_result::text);
exception when others then
  insert into pg_temp.test_025_results values
    (22,'readiness and Promotion parity','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

-- T23 no-Candidate fresh load after the successful rollback-scoped Promotion.
insert into pg_temp.test_025_results
select 23,'no Candidate after Promotion',
  case when context_result->'candidate'='null'::jsonb
       and readiness_result->'blockers' @>
         '[{"code":"NO_CURRENT_CANDIDATE"}]'::jsonb
       then 'PASS' else 'FAIL' end,
  'context='||context_result::text||'; readiness='||readiness_result::text
from (
  select context_result,
         s2t_fhir_api.get_candidate_promotion_readiness(
           't023-conc-pack-20261009-r1-c05-resource',null,null,
           (context_result#>>'{active,baselineVersionId}')::uuid,
           (context_result#>>'{active,lifecycleEventId}')::uuid,
           pg_catalog.transaction_timestamp()) readiness_result
  from (select s2t_fhir_api.get_candidate_ui_context(
    't023-conc-pack-20261009-r1-c05-resource') context_result) c
) x;

reset role;
set local role s2t_fhir_owner;
-- T24 expected-null ACTIVE is accepted as an initial-activation observation.
insert into pg_temp.test_025_results
select 24,'initial activation expected-null ACTIVE',
  case when not (evaluation->'blockers' @>
       '[{"code":"ACTIVE_CONTEXT_STALE"}]'::jsonb)
       then 'PASS' else 'FAIL' end,evaluation::text
from (
  select s2t_fhir._evaluate_candidate_promotion_readiness(
    '023c0301-0000-4000-8000-000000000001'::uuid,
    (value#>>'{candidate,lifecycleEventId}')::uuid,
    '023c0303-0000-4000-8000-000000000001'::uuid,
    '02500000-0000-4000-8000-000000000072'::uuid,
    null,null,pg_catalog.transaction_timestamp(),false,true
  ) evaluation from pg_temp.test_025_context where key='c03-before'
) x;

reset role;
set local role authenticated;
-- T25 stale Candidate and ACTIVE observations both fail closed.
insert into pg_temp.test_025_results
select 25,'stale Candidate and ACTIVE expected IDs',
  case when candidate_result->'blockers' @>
       '[{"code":"CANDIDATE_NOT_CURRENT"}]'::jsonb
       and active_result->'blockers' @>
       '[{"code":"ACTIVE_CONTEXT_STALE"}]'::jsonb
       then 'PASS' else 'FAIL' end,
  'candidate='||candidate_result::text||'; active='||active_result::text
from (
  select
    s2t_fhir_api.get_candidate_promotion_readiness(
      't023-conc-pack-20261009-r1-c06-resource',
      '02500000-0000-4000-8000-000000000099'::uuid,
      '02500000-0000-4000-8000-000000000098'::uuid,
      (snap#>>'{active,baselineVersionId}')::uuid,
      (snap#>>'{active,lifecycleEventId}')::uuid,
      pg_catalog.transaction_timestamp()) candidate_result,
    s2t_fhir_api.get_candidate_promotion_readiness(
      't023-conc-pack-20261009-r1-c06-resource',
      (snap#>>'{candidate,baselineVersionId}')::uuid,
      (snap#>>'{candidate,lifecycleEventId}')::uuid,
      '02500000-0000-4000-8000-000000000097'::uuid,
      '02500000-0000-4000-8000-000000000096'::uuid,
      pg_catalog.transaction_timestamp()) active_result
  from (select s2t_fhir_api.get_candidate_ui_context(
    't023-conc-pack-20261009-r1-c06-resource') snap) s
) x;

reset role;
set local role s2t_fhir_owner;
select
  test_no,
  test_name,
  result,
  detail
from pg_temp.test_025_results
order by test_no;

select
  count(*) as total_tests,
  count(*) filter(where result='PASS') as pass_count,
  count(*) filter(where result='FAIL') as fail_count,
  case
    when count(*)=29
     and count(*) filter(where result='PASS')=29
     and count(*) filter(where result='FAIL')=0
    then 'PASS'
    else 'FAIL'
  end as overall_runtime_result
from pg_temp.test_025_results;

do $result_number_assert$
declare
  v_missing text;
  v_duplicates text;
begin
  select pg_catalog.string_agg(expected.test_no::text,',' order by expected.test_no)
    into v_missing
  from pg_catalog.generate_series(1,29) expected(test_no)
  where not exists (
    select 1 from pg_temp.test_025_results actual
    where actual.test_no=expected.test_no
  );

  select pg_catalog.string_agg(
           pg_catalog.format('%s(%s)',duplicate.test_no,duplicate.result_count),
           ',' order by duplicate.test_no
         )
    into v_duplicates
  from (
    select test_no,count(*) result_count
    from pg_temp.test_025_results
    group by test_no
    having count(*)>1
  ) duplicate;

  if v_missing is not null or v_duplicates is not null then
    raise exception using
      errcode='P0001',
      message=pg_catalog.format(
        'MIGRATION 025 RESULT NUMBER ASSERTION FAILED: missing=%s duplicates=%s',
        coalesce(v_missing,'none'),
        coalesce(v_duplicates,'none')
      );
  end if;
end
$result_number_assert$;

do $runtime_assert$
declare
  v_total integer;
  v_pass integer;
  v_fail integer;
  v_failed_tests text;
begin
  select count(*),
         count(*) filter(where result='PASS'),
         count(*) filter(where result='FAIL')
    into v_total,v_pass,v_fail
  from pg_temp.test_025_results;

  select pg_catalog.string_agg(
           pg_catalog.format('%s:%s:%s',test_no,test_name,coalesce(detail,'')),
           '; ' order by test_no
         )
    into v_failed_tests
  from pg_temp.test_025_results
  where result='FAIL';

  if v_total<>29 or v_pass<>29 or v_fail<>0 then
    raise exception using
      errcode='P0001',
      message=pg_catalog.format(
        'MIGRATION 025 RUNTIME ASSERTION FAILED: total=%s pass=%s fail=%s; failed_tests=%s',
        v_total,v_pass,v_fail,coalesce(v_failed_tests,'none')
      );
  end if;
end
$runtime_assert$;

rollback;

-- Run B: prove transaction-scoped markers did not survive.
select case when
  not exists(select 1 from s2t_fhir.validation_run
             where validation_run_id='02500000-0000-4000-8000-000000000071'::uuid)
  and not exists(select 1 from s2t_fhir.release_gate_evaluation
             where release_gate_evaluation_id=
               '02500000-0000-4000-8000-000000000072'::uuid)
  and not exists(select 1 from s2t_fhir.review_session
             where session_name in ('T025-ROLLBACK-AMBIGUOUS-SESSION',
                                    'T025-ROLLBACK-OPEN-FROZEN'))
  and not exists(select 1 from s2t_governance.governance_mapping_link
             where node_id='T025-HISTORICAL-ACTIVE-NODE')
  and not exists(select 1 from s2t_fhir.mapping_resource_registry
             where resource_config_id='t025-rollback-c02-resource'
                or (source_system='T023-CONC-PACK-20261009-R1-C02'
                    and fhir_resource='MedicationRequest'
                    and is_enabled))
  and exists(select 1 from s2t_fhir.baseline_candidate_context
             where baseline_version_id='023c0511-0000-4000-8000-000000000001'::uuid)
  then 'MIGRATION 025 FULL ROLLBACK RESTORATION PASS'
  else 'MIGRATION 025 FULL ROLLBACK RESTORATION FAIL'
end as rollback_result;

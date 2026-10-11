-- Migration 023 rollback-only runtime tests for S2T-FHIR-DDL-Test.
-- Every mutation is inside this one outer transaction and the final ROLLBACK.
-- Tests requiring a real reviewed/gated Candidate are explicitly fixture-gated.

begin;
set local role s2t_fhir_owner;
set constraints all deferred;

create temp table pg_temp.test_023_context (
  run_tag text primary key,
  actor_principal_id uuid not null
) on commit drop;

insert into pg_temp.test_023_context(run_tag,actor_principal_id)
select replace(gen_random_uuid()::text,'-',''), p.principal_id
from s2t_fhir.principal p
where p.external_issuer = 'postgres-role'
  and p.external_subject = 's2t_fhir_migrator'
  and p.disabled_at is null;

create temp table pg_temp.test_023_results (
  test_no integer primary key,
  test_name text not null,
  status text not null check (status in ('PASS','FAIL','NOT RUN / FIXTURE REQUIRED')),
  detail text not null
) on commit drop;

create function pg_temp.test_023_ref(p_domain text,p_code text)
returns uuid language sql stable set search_path = '' as $function$
  select value.reference_value_id
  from s2t_fhir.reference_value value
  join s2t_fhir.reference_domain domain using (reference_domain_id)
  where domain.domain_code = p_domain and value.value_code = p_code
    and value.effective_at <= transaction_timestamp()
    and (value.retired_at is null or value.retired_at > transaction_timestamp())
  order by value.version_number desc limit 1
$function$;

create function pg_temp.test_023_actor()
returns uuid language sql stable set search_path = '' as $function$
  select actor_principal_id from pg_temp.test_023_context
$function$;

create function pg_temp.test_023_series(p_label text)
returns uuid language plpgsql volatile set search_path = '' as $function$
declare v_id uuid; v_tag text;
begin
  select run_tag into strict v_tag from pg_temp.test_023_context;
  insert into s2t_fhir.baseline_series
    (source_system,fhir_resource,baseline_type_value_id,description)
  values ('TEST_023_'||v_tag||'_'||p_label,'MedicationRequest',
          pg_temp.test_023_ref('BASELINE_TYPE','HUMAN_WORKING_DRAFT'),
          'Rollback-only Migration 023 fixture')
  returning baseline_series_id into v_id;
  return v_id;
end
$function$;

create function pg_temp.test_023_import_ready_baseline(p_series uuid,p_label text)
returns table(baseline_id uuid,import_id uuid)
language plpgsql volatile set search_path = '' as $function$
declare
  v_tag text; v_baseline uuid; v_artifact uuid; v_import uuid; v_digest bytea;
begin
  select run_tag into strict v_tag from pg_temp.test_023_context;
  insert into s2t_fhir.baseline_version
    (baseline_series_id,baseline_code,version_label,is_gold_standard,
     import_specification_version,description,created_by_principal_id)
  values (p_series,'T023-'||v_tag||'-'||p_label,'T023-'||p_label,false,
          'test-023-v1','Rollback-only Migration 023 fixture',pg_temp.test_023_actor())
  returning baseline_version_id into v_baseline;

  v_digest := decode(md5(v_tag||p_label||':1')||md5(v_tag||p_label||':2'),'hex');
  insert into s2t_fhir.artifact
    (artifact_kind_value_id,sha256_digest,byte_size,media_type,
     physical_filename,captured_at,description,created_by_principal_id)
  values (pg_temp.test_023_ref('ARTIFACT_KIND','WORKBOOK'),v_digest,1,
          'application/test','test-023-'||p_label||'.xlsx',transaction_timestamp(),
          'Rollback-only Migration 023 fixture',pg_temp.test_023_actor())
  returning artifact_id into v_artifact;

  insert into s2t_fhir.baseline_artifact
    (baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id)
  values (v_baseline,v_artifact,
          pg_temp.test_023_ref('ARTIFACT_ROLE','AUTHORITATIVE_SOURCE'),
          'Rollback-only Migration 023 fixture',pg_temp.test_023_actor());

  insert into s2t_fhir.import_run
    (baseline_version_id,artifact_id,import_policy_value_id,
     import_specification_version,importer_version,configuration_digest,
     started_at,completed_at,terminal_status_value_id,actor_principal_id)
  values (v_baseline,v_artifact,pg_temp.test_023_ref('IMPORT_POLICY','CLEAN_IMPORT'),
          'test-023-v1','test-023-importer',
          decode(md5(v_tag||p_label||':c1')||md5(v_tag||p_label||':c2'),'hex'),
          transaction_timestamp(),transaction_timestamp(),
          pg_temp.test_023_ref('IMPORT_RUN_STATUS','COMMITTED'),
          pg_temp.test_023_actor())
  returning import_run_id into v_import;

  baseline_id := v_baseline; import_id := v_import; return next;
end
$function$;

create function pg_temp.test_023_publish(
  p_series uuid,p_label text,p_expected_baseline uuid,p_expected_event uuid,p_reason text
)
returns jsonb language plpgsql volatile set search_path = '' as $function$
declare v_baseline uuid; v_import uuid;
begin
  select baseline_id,import_id into strict v_baseline,v_import
  from pg_temp.test_023_import_ready_baseline(p_series,p_label);
  return s2t_fhir.replace_current_candidate(
    v_baseline,v_import,p_expected_baseline,p_expected_event,
    transaction_timestamp(),p_reason,pg_temp.test_023_actor(),null);
end
$function$;

-- Stable governed ACTIVE fingerprints before synthetic work.
select 'RUNTIME BEFORE active_baseline' as fingerprint_name,
       md5(coalesce(string_agg(x::text,'|' order by x::text),'')) as fingerprint
from s2t_fhir_api.active_baseline x;
select 'RUNTIME BEFORE active_mapping_record' as fingerprint_name,
       md5(coalesce(string_agg(x::text,'|' order by x::text),'')) as fingerprint
from s2t_fhir_api.active_mapping_record x;
select 'RUNTIME BEFORE active_review' as fingerprint_name,
       md5(coalesce(string_agg(x::text,'|' order by x::text),'')) as fingerprint
from s2t_fhir_api.active_mapping_review_status x;
select 'RUNTIME BEFORE governance' as fingerprint_name,
       md5(coalesce(string_agg(x,'|' order by x),'')) as fingerprint
from (
  select 'parties:'||r::text as x from s2t_fhir_api.governance_parties r
  union all select 'timeline:'||r::text from s2t_fhir_api.governance_question_timeline r
  union all select 'links:'||r::text from s2t_fhir_api.governance_mapping_links r
  union all select 'requests:'||r::text from s2t_fhir_api.governance_open_requests r
  union all
  select 'questions:'||(
    to_jsonb(r)-'total_elapsed'-'external_waiting'-'on_hold'
    -'internal_handling'-'time_to_decision'
  )::text
  from s2t_fhir_api.governance_questions r
) governance;
select 'RUNTIME BEFORE active_CATO_API' as fingerprint_name,
       md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text,'<null>')) as fingerprint;

-- T01: first Candidate creation and exact immutable publication context.
do $test$
declare v_series uuid; v_result jsonb; v_count integer; v_status text; v_detail text;
begin
  begin
    v_series := pg_temp.test_023_series('T01');
    v_result := pg_temp.test_023_publish(v_series,'T01',null,null,null);
    select count(*) into v_count from s2t_fhir.baseline_candidate_context c
    where c.baseline_version_id = (v_result->>'newCandidateBaselineVersionId')::uuid
      and c.candidate_lifecycle_event_id = (v_result->>'newCandidateLifecycleEventId')::uuid
      and c.import_run_id = (v_result->>'importRunId')::uuid;
    v_status := case when v_count=1 then 'PASS' else 'FAIL' end;
    v_detail := 'context rows='||v_count;
    raise exception 'rollback isolated T01 fixture' using errcode = 'P0231';
  exception when sqlstate 'P0231' then
    insert into pg_temp.test_023_results values
      (1,'first Candidate creation with exact publication context',v_status,v_detail);
  when others then
    insert into pg_temp.test_023_results values
      (1,'first Candidate creation with exact publication context','FAIL',sqlstate||' '||sqlerrm);
  end;
end
$test$;

-- T02: mixed expected Candidate nullability fails.
do $test$
declare v_series uuid;
begin
  v_series := pg_temp.test_023_series('T02');
  perform pg_temp.test_023_publish(v_series,'T02',gen_random_uuid(),null,null);
  insert into pg_temp.test_023_results values (2,'mixed expected Candidate identity rejected','FAIL','unexpected success');
exception when sqlstate '22023' then
  insert into pg_temp.test_023_results values (2,'mixed expected Candidate identity rejected','PASS',sqlstate||' '||sqlerrm);
when others then
  insert into pg_temp.test_023_results values (2,'mixed expected Candidate identity rejected','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

-- T03: direct second Candidate in one series fails at deferred cardinality evaluation.
do $test$
declare v_series uuid; v_first jsonb; v_second uuid; v_baseline uuid; v_tag text;
begin
  v_series := pg_temp.test_023_series('T03');
  v_first := pg_temp.test_023_publish(v_series,'T03A',null,null,null);
  select run_tag into strict v_tag from pg_temp.test_023_context;
  insert into s2t_fhir.baseline_version
    (baseline_series_id,baseline_code,version_label,is_gold_standard,
     import_specification_version,description,created_by_principal_id)
  values (v_series,'T023-'||v_tag||'-T03B','T023-T03B',false,
          'test-023-v1','Rollback-only cardinality fixture without a second import',
          pg_temp.test_023_actor())
  returning baseline_version_id into v_baseline;
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id,lifecycle_status_value_id,occurred_at,actor_principal_id)
  values (v_baseline,pg_temp.test_023_ref('BASELINE_LIFECYCLE_STATUS','CANDIDATE'),
          transaction_timestamp(),pg_temp.test_023_actor())
  returning baseline_lifecycle_event_id into v_second;
  set constraints all immediate;
  insert into pg_temp.test_023_results values (3,'second current Candidate rejected','FAIL','unexpected success');
exception when sqlstate '23514' then
  set constraints all deferred;
  insert into pg_temp.test_023_results values (3,'second current Candidate rejected','PASS',sqlstate||' '||sqlerrm);
when others then
  set constraints all deferred;
  insert into pg_temp.test_023_results values (3,'second current Candidate rejected','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

-- T04: atomic Candidate replacement and historical context retention.
do $test$
declare v_series uuid; v_first jsonb; v_second jsonb; v_old_leaf text; v_contexts integer;
        v_status text; v_detail text;
begin
  begin
    v_series := pg_temp.test_023_series('T04');
    v_first := pg_temp.test_023_publish(v_series,'T04A',null,null,null);
    v_second := pg_temp.test_023_publish(v_series,'T04B',
      (v_first->>'newCandidateBaselineVersionId')::uuid,
      (v_first->>'newCandidateLifecycleEventId')::uuid,'replace test Candidate');
    select status.value_code into v_old_leaf
    from s2t_fhir.current_baseline_lifecycle_event event
    join s2t_fhir.reference_value status on status.reference_value_id=event.lifecycle_status_value_id
    where event.baseline_version_id=(v_first->>'newCandidateBaselineVersionId')::uuid;
    select count(*) into v_contexts from s2t_fhir.baseline_candidate_context c
    where c.baseline_version_id in ((v_first->>'newCandidateBaselineVersionId')::uuid,
                                    (v_second->>'newCandidateBaselineVersionId')::uuid);
    v_status := case when v_old_leaf='SUPERSEDED' and v_contexts=2 then 'PASS' else 'FAIL' end;
    v_detail := format('old_leaf=%s contexts=%s',v_old_leaf,v_contexts);
    raise exception 'rollback isolated T04 fixture' using errcode = 'P0234';
  exception when sqlstate 'P0234' then
    insert into pg_temp.test_023_results values
      (4,'Candidate replacement is atomic and history retained',v_status,v_detail);
  when others then
    insert into pg_temp.test_023_results values
      (4,'Candidate replacement is atomic and history retained','FAIL',sqlstate||' '||sqlerrm);
  end;
end
$test$;

-- T05: stale replacement request fails closed.
do $test$
declare v_series uuid; v_first jsonb; v_second jsonb;
begin
  v_series := pg_temp.test_023_series('T05');
  v_first := pg_temp.test_023_publish(v_series,'T05A',null,null,null);
  v_second := pg_temp.test_023_publish(v_series,'T05B',
    (v_first->>'newCandidateBaselineVersionId')::uuid,
    (v_first->>'newCandidateLifecycleEventId')::uuid,'first replacement');
  perform pg_temp.test_023_publish(v_series,'T05C',
    (v_first->>'newCandidateBaselineVersionId')::uuid,
    (v_first->>'newCandidateLifecycleEventId')::uuid,'stale replacement');
  insert into pg_temp.test_023_results values (5,'stale Candidate replacement rejected','FAIL','unexpected success');
exception when sqlstate '40001' then
  insert into pg_temp.test_023_results values (5,'stale Candidate replacement rejected','PASS',sqlstate||' '||sqlerrm);
when others then
  insert into pg_temp.test_023_results values (5,'stale Candidate replacement rejected','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

-- T06: backdated Candidate replacement fails.
do $test$
declare v_series uuid; v_first jsonb; v_baseline uuid; v_import uuid;
begin
  v_series := pg_temp.test_023_series('T06');
  v_first := pg_temp.test_023_publish(v_series,'T06A',null,null,null);
  select baseline_id,import_id into strict v_baseline,v_import from pg_temp.test_023_import_ready_baseline(v_series,'T06B');
  perform s2t_fhir.replace_current_candidate(v_baseline,v_import,
    (v_first->>'newCandidateBaselineVersionId')::uuid,(v_first->>'newCandidateLifecycleEventId')::uuid,
    transaction_timestamp()-interval '1 day','backdated replacement',pg_temp.test_023_actor(),null);
  insert into pg_temp.test_023_results values (6,'backdated Candidate replacement rejected','FAIL','unexpected success');
exception when sqlstate '23514' then
  insert into pg_temp.test_023_results values (6,'backdated Candidate replacement rejected','PASS',sqlstate||' '||sqlerrm);
when others then
  insert into pg_temp.test_023_results values (6,'backdated Candidate replacement rejected','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

-- T07: Candidate replacement does not alter the existing ACTIVE identity.
do $test$
declare v_before text; v_after text; v_series uuid; v_first jsonb;
        v_status text; v_detail text;
begin
  begin
    select md5(coalesce(string_agg(x::text,'|' order by x::text),'')) into v_before from s2t_fhir_api.active_baseline x;
    v_series := pg_temp.test_023_series('T07');
    v_first := pg_temp.test_023_publish(v_series,'T07A',null,null,null);
    perform pg_temp.test_023_publish(v_series,'T07B',
      (v_first->>'newCandidateBaselineVersionId')::uuid,(v_first->>'newCandidateLifecycleEventId')::uuid,'replace');
    select md5(coalesce(string_agg(x::text,'|' order by x::text),'')) into v_after from s2t_fhir_api.active_baseline x;
    v_status := case when v_before=v_after then 'PASS' else 'FAIL' end;
    v_detail := format('before=%s after=%s',v_before,v_after);
    raise exception 'rollback isolated T07 fixture' using errcode = 'P0237';
  exception when sqlstate 'P0237' then
    insert into pg_temp.test_023_results values
      (7,'Candidate replacement preserves ACTIVE API',v_status,v_detail);
  when others then
    insert into pg_temp.test_023_results values
      (7,'Candidate replacement preserves ACTIVE API','FAIL',sqlstate||' '||sqlerrm);
  end;
end
$test$;

-- T08: direct ACTIVE bypass is rejected even for a structurally valid Candidate.
do $test$
declare v_series uuid; v_candidate jsonb;
begin
  v_series := pg_temp.test_023_series('T08');
  v_candidate := pg_temp.test_023_publish(v_series,'T08',null,null,null);
  insert into s2t_fhir.baseline_lifecycle_event
    (baseline_version_id,lifecycle_status_value_id,occurred_at,actor_principal_id,supersedes_event_id)
  values ((v_candidate->>'newCandidateBaselineVersionId')::uuid,
          pg_temp.test_023_ref('BASELINE_LIFECYCLE_STATUS','ACTIVE'),transaction_timestamp(),
          pg_temp.test_023_actor(),(v_candidate->>'newCandidateLifecycleEventId')::uuid);
  insert into pg_temp.test_023_results values (8,'direct ACTIVE lifecycle bypass rejected','FAIL','unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_023_results values (8,'direct ACTIVE lifecycle bypass rejected','PASS',sqlstate||' '||sqlerrm);
when others then
  insert into pg_temp.test_023_results values (8,'direct ACTIVE lifecycle bypass rejected','FAIL',sqlstate||' '||sqlerrm);
end
$test$;

-- T09-T15: Candidate Review requires an accepted mapping fixture. The package
-- refuses to mutate a governed existing Candidate merely to manufacture it.
insert into pg_temp.test_023_results values
 (9,'Candidate review session start','NOT RUN / FIXTURE REQUIRED','requires rollback-safe accepted Candidate mapping fixture'),
 (10,'Candidate REVIEWED transition','NOT RUN / FIXTURE REQUIRED','requires rollback-safe accepted Candidate mapping fixture'),
 (11,'Candidate NEEDS_FOLLOW_UP transition','NOT RUN / FIXTURE REQUIRED','requires rollback-safe accepted Candidate mapping fixture'),
 (12,'Candidate clear/reset transition','NOT RUN / FIXTURE REQUIRED','requires rollback-safe accepted Candidate mapping fixture'),
 (13,'stale/wrong Candidate Review rejected','NOT RUN / FIXTURE REQUIRED','requires rollback-safe accepted Candidate mapping fixture'),
 (14,'Candidate V2 review not copied to V3','NOT RUN / FIXTURE REQUIRED','requires two rollback-safe accepted Candidate mapping fixtures'),
 (15,'existing ACTIVE Review unaffected','NOT RUN / FIXTURE REQUIRED','requires safe review fixture without touching governed ACTIVE history');

-- T16-T21: Candidate Governance requires a governed synthetic question and
-- accepted mapping identity. Existing governed questions are not mutated.
insert into pg_temp.test_023_results values
 (16,'Candidate governance exact link succeeds','NOT RUN / FIXTURE REQUIRED','requires governed synthetic question and accepted Candidate mapping'),
 (17,'stale Candidate governance link rejected','NOT RUN / FIXTURE REQUIRED','requires governed synthetic question and Candidate mapping'),
 (18,'wrong Candidate baseline rejected','NOT RUN / FIXTURE REQUIRED','requires governed synthetic question and Candidate mapping'),
 (19,'wrong resource/node rejected','NOT RUN / FIXTURE REQUIRED','requires governed synthetic question and Candidate mapping'),
 (20,'Candidate governance history retained without carry-forward','NOT RUN / FIXTURE REQUIRED','requires two governed Candidate fixtures'),
 (21,'existing ACTIVE gov_link_mapping regression','NOT RUN / FIXTURE REQUIRED','existing governed questions are not mutated by this suite');

-- T22-T34: Promotion requires complete reviewed Candidate mappings plus exact
-- validation and current PASSED gate evidence. No production-like evidence is
-- synthesized by this general-purpose package.
insert into pg_temp.test_023_results values
 (22,'initial Promotion with explicit null ACTIVE','NOT RUN / FIXTURE REQUIRED','requires complete reviewed/gated Candidate fixture'),
 (23,'initial Promotion rejects actual ACTIVE mismatch','NOT RUN / FIXTURE REQUIRED','requires complete reviewed/gated Candidate fixture in ACTIVE series'),
 (24,'replacement Promotion succeeds atomically','NOT RUN / FIXTURE REQUIRED','requires current ACTIVE plus complete reviewed/gated Candidate'),
 (25,'stale expected ACTIVE rejected','NOT RUN / FIXTURE REQUIRED','requires replacement Promotion fixture'),
 (26,'stale Candidate rejected by Promotion','NOT RUN / FIXTURE REQUIRED','requires reviewed/gated replaced Candidate fixture'),
 (27,'stale publication/import rejected','NOT RUN / FIXTURE REQUIRED','requires reviewed/gated Candidate fixture'),
 (28,'stale/current gate mismatch rejected','NOT RUN / FIXTURE REQUIRED','requires multiple governed gate evaluations'),
 (29,'missing review completion rejected','NOT RUN / FIXTURE REQUIRED','requires accepted Candidate mappings and gate'),
 (30,'missing authoritative artifact rejected','NOT RUN / FIXTURE REQUIRED','requires isolated governed validation fixture'),
 (31,'promotion lifecycle/relationship/context results','NOT RUN / FIXTURE REQUIRED','requires replacement Promotion fixture'),
 (32,'fabricated activation context rejected','NOT RUN / FIXTURE REQUIRED','requires exact reviewed/gated Candidate fixture'),
 (33,'forced late Promotion failure is atomic','NOT RUN / FIXTURE REQUIRED','requires replacement Promotion fixture and deterministic late conflict'),
 (34,'Promotion ACTIVE API switch/regression','NOT RUN / FIXTURE REQUIRED','requires replacement Promotion fixture');

-- T35: private surface cannot be executed by client/importer/service roles.
do $test$
declare v_bad integer;
begin
  select count(*) into v_bad
  from (values ('anon'),('authenticated'),('service_role'),('s2t_fhir_importer'),
               ('s2t_fhir_api_reader'),('s2t_fhir_governance_reader')) roles(role_name)
  where has_function_privilege(role_name,
    's2t_fhir.promote_current_candidate(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)'::regprocedure,
    'EXECUTE');
  insert into pg_temp.test_023_results values
    (35,'private Promotion core has no client/importer/service EXECUTE',
     case when v_bad=0 then 'PASS' else 'FAIL' end,'unexpected roles='||v_bad);
end
$test$;

-- T36: only authenticated receives the public wrapper; no actor parameter exists.
do $test$
declare v_ok boolean; v_args text;
begin
  select has_function_privilege('authenticated',p.oid,'EXECUTE'),
         pg_get_function_identity_arguments(p.oid)
    into strict v_ok,v_args
  from pg_catalog.pg_proc p
  where p.oid='s2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)'::regprocedure;
  insert into pg_temp.test_023_results values
    (36,'Promotion wrapper grant and anti-spoof signature',
     case when v_ok and v_args not like '%actor%' and v_args not like '%principal%' then 'PASS' else 'FAIL' end,
     'authenticated='||v_ok||' args='||v_args);
end
$test$;

-- T37-T40 capability separation. Catalog-visible authorization decisions are
-- checked without altering an existing governed user.
do $test$
declare v_tag text; v_admin uuid; v_promoter uuid; v_upload uuid; v_review uuid; v_plain uuid;
        v_message text;
begin
  select run_tag,actor_principal_id into strict v_tag,v_admin from pg_temp.test_023_context;
  v_promoter:=gen_random_uuid(); v_upload:=gen_random_uuid();
  v_review:=gen_random_uuid(); v_plain:=gen_random_uuid();
  insert into s2t_fhir.principal
    (principal_id,principal_kind_value_id,external_issuer,external_subject,display_name)
  values
    (v_promoter,pg_temp.test_023_ref('PRINCIPAL_KIND','HUMAN'),'supabase-auth',v_promoter::text,'T023 Promoter '||v_tag),
    (v_upload,pg_temp.test_023_ref('PRINCIPAL_KIND','HUMAN'),'supabase-auth',v_upload::text,'T023 Uploader '||v_tag),
    (v_review,pg_temp.test_023_ref('PRINCIPAL_KIND','HUMAN'),'supabase-auth',v_review::text,'T023 Reviewer '||v_tag),
    (v_plain,pg_temp.test_023_ref('PRINCIPAL_KIND','HUMAN'),'supabase-auth',v_plain::text,'T023 Plain '||v_tag);
  insert into s2t_fhir.baseline_action_authorization(principal_id,capability_code,granted_by_principal_id)
  values (v_promoter,'S2T_BASELINE_PROMOTE',v_admin),(v_upload,'S2T_BASELINE_UPLOAD',v_admin);
  insert into s2t_fhir.review_actor_authorization(principal_id,capability_code,granted_by_principal_id)
  values (v_review,'S2T_REVIEW_WRITE',v_admin);
  perform set_config('request.jwt.claim.sub',v_promoter::text,true);
  begin
    perform s2t_fhir_api.promote_candidate_baseline(
      gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      null,null,transaction_timestamp(),null);
    insert into pg_temp.test_023_results values (37,'PROMOTE capability reaches governed wrapper','FAIL','unexpected success');
  exception when sqlstate '40001' then
    get stacked diagnostics v_message = message_text;
    if v_message = 'exact Candidate publication context is missing or stale' then
      insert into pg_temp.test_023_results values (37,'PROMOTE capability reaches governed wrapper','PASS','authorization passed; governed core rejected the exact missing/stale Candidate publication context');
    else
      insert into pg_temp.test_023_results values
        (37,'PROMOTE capability reaches governed wrapper','FAIL',
         sqlstate||' unexpected serialization failure message=['||v_message||'] length='||length(v_message));
    end if;
  when others then
    insert into pg_temp.test_023_results values (37,'PROMOTE capability reaches governed wrapper','FAIL',sqlstate||' '||sqlerrm);
  end;

  perform set_config('request.jwt.claim.sub',v_upload::text,true);
  begin
    perform s2t_fhir_api.promote_candidate_baseline(
      gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      null,null,transaction_timestamp(),null);
    insert into pg_temp.test_023_results values (38,'UPLOAD-only cannot promote','FAIL','unexpected success');
  exception when sqlstate '42501' then
    insert into pg_temp.test_023_results values (38,'UPLOAD-only cannot promote','PASS',sqlstate||' '||sqlerrm);
  when others then
    insert into pg_temp.test_023_results values (38,'UPLOAD-only cannot promote','FAIL',sqlstate||' '||sqlerrm);
  end;

  perform set_config('request.jwt.claim.sub',v_review::text,true);
  begin
    perform s2t_fhir_api.promote_candidate_baseline(
      gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      null,null,transaction_timestamp(),null);
    insert into pg_temp.test_023_results values (39,'REVIEW-only cannot promote','FAIL','unexpected success');
  exception when sqlstate '42501' then
    insert into pg_temp.test_023_results values (39,'REVIEW-only cannot promote','PASS',sqlstate||' '||sqlerrm);
  when others then
    insert into pg_temp.test_023_results values (39,'REVIEW-only cannot promote','FAIL',sqlstate||' '||sqlerrm);
  end;

  perform set_config('request.jwt.claim.sub',v_plain::text,true);
  begin
    perform s2t_fhir_api.promote_candidate_baseline(
      gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      null,null,transaction_timestamp(),null);
    insert into pg_temp.test_023_results values (40,'ordinary authenticated cannot promote','FAIL','unexpected success');
  exception when sqlstate '42501' then
    insert into pg_temp.test_023_results values (40,'ordinary authenticated cannot promote','PASS',sqlstate||' '||sqlerrm);
  when others then
    insert into pg_temp.test_023_results values (40,'ordinary authenticated cannot promote','FAIL',sqlstate||' '||sqlerrm);
  end;
exception when others then
  insert into pg_temp.test_023_results(test_no,test_name,status,detail)
  select n,name,'FAIL',sqlstate||' '||sqlerrm from (values
   (37,'PROMOTE capability is distinct'),(38,'UPLOAD-only does not confer PROMOTE'),
   (39,'REVIEW-only does not confer PROMOTE'),(40,'ordinary authenticated principal has no PROMOTE')) x(n,name)
  on conflict (test_no) do nothing;
end
$test$;

select test_no,test_name,status,detail from pg_temp.test_023_results order by test_no;
select case when count(*) filter (where status='FAIL')=0 then 'PASS' else 'FAIL' end as runtime_summary,
       count(*) filter (where status='PASS') as passed,
       count(*) filter (where status='FAIL') as failed,
       count(*) filter (where status='NOT RUN / FIXTURE REQUIRED') as fixture_required,
       count(*) as total
from pg_temp.test_023_results;

rollback;

-- These read-only fingerprints execute after the rollback and must exactly equal
-- their corresponding RUNTIME BEFORE values.
select 'RUNTIME AFTER ROLLBACK active_baseline' as fingerprint_name,
       md5(coalesce(string_agg(x::text,'|' order by x::text),'')) as fingerprint
from s2t_fhir_api.active_baseline x;
select 'RUNTIME AFTER ROLLBACK active_mapping_record' as fingerprint_name,
       md5(coalesce(string_agg(x::text,'|' order by x::text),'')) as fingerprint
from s2t_fhir_api.active_mapping_record x;
select 'RUNTIME AFTER ROLLBACK active_review' as fingerprint_name,
       md5(coalesce(string_agg(x::text,'|' order by x::text),'')) as fingerprint
from s2t_fhir_api.active_mapping_review_status x;
select 'RUNTIME AFTER ROLLBACK governance' as fingerprint_name,
       md5(coalesce(string_agg(x,'|' order by x),'')) as fingerprint
from (
  select 'parties:'||r::text as x from s2t_fhir_api.governance_parties r
  union all select 'timeline:'||r::text from s2t_fhir_api.governance_question_timeline r
  union all select 'links:'||r::text from s2t_fhir_api.governance_mapping_links r
  union all select 'requests:'||r::text from s2t_fhir_api.governance_open_requests r
  union all
  select 'questions:'||(
    to_jsonb(r)-'total_elapsed'-'external_waiting'-'on_hold'
    -'internal_handling'-'time_to_decision'
  )::text
  from s2t_fhir_api.governance_questions r
) governance;
select 'RUNTIME AFTER ROLLBACK active_CATO_API' as fingerprint_name,
       md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text,'<null>')) as fingerprint;

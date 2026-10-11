-- Migration 024 rollback-only runtime acceptance.
-- Requires the retained 023 fixture at CP20/CP21 and an accepted Migration 024.
-- Every application-data mutation is inside this one outer transaction.

-- RUN A START
begin;
set local role s2t_fhir_owner;
set constraints all deferred;

create temp table pg_temp.test_024_context (
  baseline_id uuid primary key,
  candidate_event_id uuid not null,
  node_id text not null,
  session_one uuid,
  session_two uuid,
  active_session uuid
) on commit drop;

insert into pg_temp.test_024_context(baseline_id,candidate_event_id,node_id)
select c.baseline_version_id,c.candidate_lifecycle_event_id,
       'map-v1-'||pg_catalog.md5('T023-CONC-PACK-20261009-R1-C03-V1-node-1')||
       pg_catalog.md5('T023-CONC-PACK-20261009-R1-C03-V1-node-2')
from s2t_fhir.baseline_candidate_context c
where c.baseline_version_id='023c0301-0000-4000-8000-000000000001'::uuid;

create temp table pg_temp.test_024_results (
  test_no integer primary key,
  test_name text not null,
  status text not null check(status in ('PASS','FAIL','NOT_APPLICABLE')),
  sqlstate_text text,
  detail text not null
) on commit drop;

create temp table pg_temp.test_024_report (
  sort_order integer not null,
  section text not null,
  test_no integer,
  test_name text not null,
  status text,
  sqlstate_text text,
  detail text,
  fingerprint text
) on commit drop;

grant select,insert,update on pg_temp.test_024_context to public;
grant select,insert,update on pg_temp.test_024_results to public;
grant select,insert on pg_temp.test_024_report to public;

insert into pg_temp.test_024_report
  (sort_order,section,test_no,test_name,status,sqlstate_text,detail,fingerprint)
select 0,'RUNTIME_BEFORE',null,'RUNTIME BEFORE fixture fingerprint',
       'CAPTURED',null,'committed fixture fingerprint before runtime tests',
       pg_catalog.md5(coalesce(pg_catalog.string_agg(x,'|' order by x),''))
from (
  select 'context:'||c.baseline_version_id::text||':'||c.candidate_lifecycle_event_id::text as x
  from s2t_fhir.baseline_candidate_context c
  where c.baseline_version_id in (
    '023c0301-0000-4000-8000-000000000001','023c0401-0000-4000-8000-000000000001',
    '023c0501-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001')
  union all
  select 'session:'||s.review_session_id::text from s2t_fhir.review_session s
  where s.session_name in ('T024-RUNTIME-C03-SESSION-1','T024-RUNTIME-C03-SESSION-2','T024-RUNTIME-ACTIVE-SMOKE')
  union all
  select 'question:'||q.question_id::text from s2t_governance.governance_question q
  where q.title='T024-RUNTIME-GOVERNANCE-SMOKE'
  union all
  select 'principal:'||p.principal_id::text||':'||coalesce(p.disabled_at::text,'ENABLED')
  from s2t_fhir.principal p
  where p.principal_id in (
    '023c04a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001')
  union all
  select 'review-auth:'||a.principal_id::text||':'||a.review_actor_authorization_id::text||':'||
         coalesce(a.revoked_at::text,'ACTIVE')
  from s2t_fhir.review_actor_authorization a
  where a.principal_id in (
    '023c04a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001')
) fingerprint_rows;

-- T01: authorized human reviewer starts a Candidate Review session.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c03a1-0000-4000-8000-000000000001',true);
do $test$
declare v_session uuid; v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  v_session:=s2t_fhir_api.start_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-RUNTIME-C03-SESSION-1',
    'Migration 024 rollback-only acceptance');
  update pg_temp.test_024_context set session_one=v_session;
  insert into pg_temp.test_024_results values
    (1,'authorized reviewer starts Candidate Review','PASS',null,v_session::text);
exception when others then
  insert into pg_temp.test_024_results values
    (1,'authorized reviewer starts Candidate Review','FAIL',sqlstate,sqlerrm);
end
$test$;

reset role;
set local role s2t_fhir_owner;

-- T02: the stored actor is exactly the JWT-resolved principal.
insert into pg_temp.test_024_results
select 2,'session actor equals JWT principal',
       case when count(*)=1 then 'PASS' else 'FAIL' end,null,
       'matching rows='||count(*)
from pg_temp.test_024_context c
join s2t_fhir.review_session s on s.review_session_id=c.session_one
where s.created_by_principal_id='023c03a0-0000-4000-8000-000000000001'::uuid
  and s.baseline_version_id=c.baseline_id
  and s.review_target_lifecycle_event_id=c.candidate_event_id;

-- T03-T05: append all three supported review states through public wrappers.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c03a1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  begin
    perform s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
      v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.node_id,v_ctx.session_one,'T024 REVIEWED');
    insert into pg_temp.test_024_results values(3,'append REVIEWED','PASS',null,'accepted');
  exception when others then
    insert into pg_temp.test_024_results values(3,'append REVIEWED','FAIL',sqlstate,sqlerrm);
  end;
  begin
    perform s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(
      v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.node_id,v_ctx.session_one,'T024 NEEDS_FOLLOW_UP');
    insert into pg_temp.test_024_results values(4,'append NEEDS_FOLLOW_UP','PASS',null,'accepted');
  exception when others then
    insert into pg_temp.test_024_results values(4,'append NEEDS_FOLLOW_UP','FAIL',sqlstate,sqlerrm);
  end;
  begin
    perform s2t_fhir_api.clear_authenticated_candidate_mapping_review(
      v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.node_id,v_ctx.session_one,'T024 NOT_REVIEWED');
    insert into pg_temp.test_024_results values(5,'append NOT_REVIEWED','PASS',null,'accepted');
  exception when others then
    insert into pg_temp.test_024_results values(5,'append NOT_REVIEWED','FAIL',sqlstate,sqlerrm);
  end;
end
$test$;

reset role;
set local role s2t_fhir_owner;

-- T06: exact three-event append chain, one head, exact actor/session/provenance.
insert into pg_temp.test_024_results
select 6,'append chain and provenance exact',
       case when count(*)=3
              and count(*) filter(where not exists(
                select 1 from s2t_fhir.mapping_review_event successor
                where successor.supersedes_event_id=e.mapping_review_event_id))=1
              and count(*) filter(where e.actor_principal_id<>'023c03a0-0000-4000-8000-000000000001'::uuid)=0
              and count(*) filter(where e.review_session_id is distinct from c.session_one)=0
              and count(*) filter(where e.review_target_lifecycle_event_id is distinct from c.candidate_event_id)=0
            then 'PASS' else 'FAIL' end,null,
       format('events=%s heads=%s',count(*),count(*) filter(where not exists(
         select 1 from s2t_fhir.mapping_review_event successor
         where successor.supersedes_event_id=e.mapping_review_event_id)))
from pg_temp.test_024_context c
join s2t_fhir.mapping_review_event e on e.baseline_version_id=c.baseline_id
where e.review_session_id=c.session_one;

-- T07: owner closes the same session through the authenticated wrapper.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c03a1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.end_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.session_one);
exception when others then
  insert into pg_temp.test_024_results values(7,'close session records actor','FAIL',sqlstate,sqlerrm);
end
$test$;
reset role;
set local role s2t_fhir_owner;
insert into pg_temp.test_024_results
select 7,'close session records actor',
       case when s.ended_at is not null
              and s.ended_by_principal_id='023c03a0-0000-4000-8000-000000000001'::uuid
            then 'PASS' else 'FAIL' end,null,
       coalesce(s.ended_by_principal_id::text,'NULL')
from pg_temp.test_024_context c
join s2t_fhir.review_session s on s.review_session_id=c.session_one
on conflict(test_no) do nothing;

-- T24 is executed here while the Candidate is still current.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c03a1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
    v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.node_id,v_ctx.session_one,'closed session rejection');
  insert into pg_temp.test_024_results values(24,'closed session rejects write','FAIL',null,'unexpected success');
exception when sqlstate '23514' then
  insert into pg_temp.test_024_results values(24,'closed session rejects write','PASS',sqlstate,sqlerrm);
when others then
  insert into pg_temp.test_024_results values(24,'closed session rejects write','FAIL',sqlstate,sqlerrm);
end
$test$;

-- Create a second open session for ownership and OPEN_FROZEN tests.
do $test$
declare v_ctx pg_temp.test_024_context%rowtype; v_session uuid;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  v_session:=s2t_fhir_api.start_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-RUNTIME-C03-SESSION-2',
    'Migration 024 ownership/frozen test');
  update pg_temp.test_024_context set session_two=v_session;
end
$test$;

-- T08: another authorized reviewer cannot write or close the first actor's session.
select pg_catalog.set_config('request.jwt.claim.sub','023c04a1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype; v_write_denied boolean:=false; v_close_denied boolean:=false;
        v_detail text:='';
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  begin
    perform s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
      v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.node_id,v_ctx.session_two,'cross-actor write');
  exception when sqlstate '23514' then v_write_denied:=true; v_detail:=sqlstate||' '||sqlerrm; end;
  begin
    perform s2t_fhir_api.end_authenticated_candidate_review_session(
      v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.session_two);
  exception when sqlstate '23514' then v_close_denied:=true; v_detail:=v_detail||'; '||sqlstate||' '||sqlerrm; end;
  insert into pg_temp.test_024_results values
    (8,'second reviewer cannot use first reviewer session',
     case when v_write_denied and v_close_denied then 'PASS' else 'FAIL' end,
     case when v_write_denied and v_close_denied then '23514' else null end,v_detail);
exception when others then
  insert into pg_temp.test_024_results values(8,'second reviewer cannot use first reviewer session','FAIL',sqlstate,sqlerrm);
end
$test$;

-- T09: missing JWT.
select pg_catalog.set_config('request.jwt.claim.sub','',true);
select pg_catalog.set_config('request.jwt.claims','',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.start_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-NO-JWT',null);
  insert into pg_temp.test_024_results values(9,'missing JWT rejected','FAIL',null,'unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_024_results values(9,'missing JWT rejected','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(9,'missing JWT rejected','FAIL',sqlstate,sqlerrm);
end
$test$;

-- T10: unmapped JWT.
select pg_catalog.set_config('request.jwt.claim.sub','02400000-0000-4000-8000-000000000010',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.start_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-UNMAPPED',null);
  insert into pg_temp.test_024_results values(10,'unmapped JWT rejected','FAIL',null,'unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_024_results values(10,'unmapped JWT rejected','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(10,'unmapped JWT rejected','FAIL',sqlstate,sqlerrm);
end
$test$;

reset role;
set local role s2t_fhir_owner;

-- T11: disabled mapped principal.
update s2t_fhir.principal set disabled_at=pg_catalog.transaction_timestamp()
where principal_id='023c04a0-0000-4000-8000-000000000001'::uuid;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c04a1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.start_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-DISABLED',null);
  insert into pg_temp.test_024_results values(11,'disabled principal rejected','FAIL',null,'unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_024_results values(11,'disabled principal rejected','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(11,'disabled principal rejected','FAIL',sqlstate,sqlerrm);
end
$test$;

-- T12/T15: C03-B is mapped and UPLOAD-only, with no REVIEW_WRITE.
select pg_catalog.set_config('request.jwt.claim.sub','023c03b1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype; v_state text; v_message text;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  begin
    perform s2t_fhir_api.start_authenticated_candidate_review_session(
      v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-UPLOAD-ONLY',null);
    v_state:=null; v_message:='unexpected success';
  exception when others then v_state:=sqlstate; v_message:=sqlerrm; end;
  insert into pg_temp.test_024_results values
    (12,'mapped principal without REVIEW_WRITE rejected',case when v_state='42501' then 'PASS' else 'FAIL' end,v_state,v_message),
    (15,'UPLOAD-only principal rejected',case when v_state='42501' then 'PASS' else 'FAIL' end,v_state,v_message);
end
$test$;

-- T16: C05-B is PROMOTE-only.
select pg_catalog.set_config('request.jwt.claim.sub','023c05b1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.start_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-PROMOTE-ONLY',null);
  insert into pg_temp.test_024_results values(16,'PROMOTE-only principal rejected','FAIL',null,'unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_024_results values(16,'PROMOTE-only principal rejected','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(16,'PROMOTE-only principal rejected','FAIL',sqlstate,sqlerrm);
end
$test$;

reset role;
set local role s2t_fhir_owner;

-- T13: revoke C06-A REVIEW_WRITE, then verify the next wrapper call fails.
select s2t_fhir.revoke_review_write(
  '023c06a0-0000-4000-8000-000000000001'::uuid,
  (select principal_id from s2t_fhir.principal
   where external_issuer='postgres-role' and external_subject='s2t_fhir_importer'
     and disabled_at is null));
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c06a1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.start_authenticated_candidate_review_session(
    v_ctx.baseline_id,v_ctx.candidate_event_id,'T024-REVOKED',null);
  insert into pg_temp.test_024_results values(13,'revoked REVIEW_WRITE rejected','FAIL',null,'unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_024_results values(13,'revoked REVIEW_WRITE rejected','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(13,'revoked REVIEW_WRITE rejected','FAIL',sqlstate,sqlerrm);
end
$test$;

reset role;
set local role s2t_fhir_owner;

-- T14: the accepted partial unique index prevents an ambiguous current grant.
insert into pg_temp.test_024_results
select 14,'ambiguous current review grant',
       case when pg_catalog.to_regclass('s2t_fhir.review_actor_authorization_active_uq') is not null
            then 'NOT_APPLICABLE' else 'FAIL' end,null,
       case when pg_catalog.to_regclass('s2t_fhir.review_actor_authorization_active_uq') is not null
            then 'schema prevents duplicate current grants by partial unique index'
            else 'required uniqueness index is absent' end;

-- T17-T19: direct execution of all three private cores must fail for roles
-- that the SQL Editor execution role can safely impersonate.
-- Dummy UUIDs avoid any dependency on private-table reads by the tested role.
reset role;
set local role authenticated;
do $test$
declare v_denied integer:=0; v_detail text:='';
begin
  begin perform s2t_fhir_api._start_candidate_review_session(gen_random_uuid(),gen_random_uuid(),'x',gen_random_uuid(),null);
  exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=sqlstate||' '||sqlerrm; end;
  begin perform s2t_fhir_api._end_candidate_review_session(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid());
  exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=v_detail||'; '||sqlstate||' '||sqlerrm; end;
  begin perform s2t_fhir_api._record_candidate_mapping_review(gen_random_uuid(),gen_random_uuid(),'x','REVIEWED',gen_random_uuid(),gen_random_uuid(),null);
  exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=v_detail||'; '||sqlstate||' '||sqlerrm; end;
  insert into pg_temp.test_024_results values(17,'authenticated denied direct private-core execution',case when v_denied=3 then 'PASS' else 'FAIL' end,'42501',v_detail);
end
$test$;
reset role;
set local role anon;
do $test$
declare v_denied integer:=0; v_detail text:='';
begin
  begin perform s2t_fhir_api._start_candidate_review_session(gen_random_uuid(),gen_random_uuid(),'x',gen_random_uuid(),null); exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=sqlstate||' '||sqlerrm; end;
  begin perform s2t_fhir_api._end_candidate_review_session(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()); exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=v_detail||'; '||sqlstate||' '||sqlerrm; end;
  begin perform s2t_fhir_api._record_candidate_mapping_review(gen_random_uuid(),gen_random_uuid(),'x','REVIEWED',gen_random_uuid(),gen_random_uuid(),null); exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=v_detail||'; '||sqlstate||' '||sqlerrm; end;
  insert into pg_temp.test_024_results values(18,'anon denied direct private-core execution',case when v_denied=3 then 'PASS' else 'FAIL' end,'42501',v_detail);
end
$test$;
reset role;
set local role service_role;
do $test$
declare v_denied integer:=0; v_detail text:='';
begin
  begin perform s2t_fhir_api._start_candidate_review_session(gen_random_uuid(),gen_random_uuid(),'x',gen_random_uuid(),null); exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=sqlstate||' '||sqlerrm; end;
  begin perform s2t_fhir_api._end_candidate_review_session(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()); exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=v_detail||'; '||sqlstate||' '||sqlerrm; end;
  begin perform s2t_fhir_api._record_candidate_mapping_review(gen_random_uuid(),gen_random_uuid(),'x','REVIEWED',gen_random_uuid(),gen_random_uuid(),null); exception when sqlstate '42501' then v_denied:=v_denied+1; v_detail:=v_detail||'; '||sqlstate||' '||sqlerrm; end;
  insert into pg_temp.test_024_results values(19,'service_role denied direct private-core execution',case when v_denied=3 then 'PASS' else 'FAIL' end,'42501',v_detail);
end
$test$;
reset role;
set local role s2t_fhir_owner;

-- T20: importer is not safely impersonable in the SQL Editor; assert its
-- effective EXECUTE boundary directly from the catalog using exact signatures.
with private_cores(signature, function_oid) as (
  values
    ('s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)',
     pg_catalog.to_regprocedure('s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)')),
    ('s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)',
     pg_catalog.to_regprocedure('s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)')),
    ('s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)',
     pg_catalog.to_regprocedure('s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)'))
)
insert into pg_temp.test_024_results
select 20,'importer has no effective private-core EXECUTE',
       case when count(*)=3 and bool_and(function_oid is not null and not
         pg_catalog.has_function_privilege('s2t_fhir_importer',function_oid,'EXECUTE'))
         then 'PASS' else 'FAIL' end,null,
       pg_catalog.string_agg(signature||' execute='||coalesce(
         pg_catalog.has_function_privilege('s2t_fhir_importer',function_oid,'EXECUTE')::text,
         'NULL'),'; ' order by signature)
from private_cores;

-- T21: both reader roles must lack effective EXECUTE on every private core.
with tested_roles(role_name) as (
  values ('s2t_fhir_api_reader'),('s2t_fhir_governance_reader')
),
private_cores(signature, function_oid) as (
  values
    ('s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)',
     pg_catalog.to_regprocedure('s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)')),
    ('s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)',
     pg_catalog.to_regprocedure('s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)')),
    ('s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)',
     pg_catalog.to_regprocedure('s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)'))
),
effective_acl as (
  select r.role_name,c.signature,c.function_oid,
         pg_catalog.has_function_privilege(r.role_name,c.function_oid,'EXECUTE') as can_execute
  from tested_roles r cross join private_cores c
)
insert into pg_temp.test_024_results
select 21,'reader roles have no effective private-core EXECUTE',
       case when count(*)=6 and bool_and(function_oid is not null and not can_execute)
         then 'PASS' else 'FAIL' end,null,
       pg_catalog.string_agg(role_name||' '||signature||' execute='||
         coalesce(can_execute::text,'NULL'),'; ' order by role_name,signature)
from effective_acl;

-- T22/T23: replace C03 V1 with its staged V2 inside the rollback-only transaction.
reset role;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c03b1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline(
  '023c0311-0000-4000-8000-000000000001','023c0313-0000-4000-8000-000000000001',
  '023c0301-0000-4000-8000-000000000001',
  (select c.candidate_event_id
   from pg_temp.test_024_context c
   where c.baseline_id='023c0301-0000-4000-8000-000000000001'::uuid),
  pg_catalog.transaction_timestamp(),
  'T024 rollback-only C03-V1 to C03-V2 replacement for OPEN_FROZEN acceptance');

select pg_catalog.set_config('request.jwt.claim.sub','023c03a1-0000-4000-8000-000000000001',true);
do $test$
declare v_ctx pg_temp.test_024_context%rowtype;
begin
  select * into strict v_ctx from pg_temp.test_024_context;
  perform s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
    v_ctx.baseline_id,v_ctx.candidate_event_id,v_ctx.node_id,v_ctx.session_two,'stale write');
  insert into pg_temp.test_024_results values(22,'stale Candidate rejects review write','FAIL',null,'unexpected success');
exception when sqlstate '40001' then
  insert into pg_temp.test_024_results values(22,'stale Candidate rejects review write','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(22,'stale Candidate rejects review write','FAIL',sqlstate,sqlerrm);
end
$test$;

reset role;
set local role s2t_fhir_owner;
insert into pg_temp.test_024_results
select 23,'replaced Candidate session is OPEN_FROZEN',
       case when count(*)=1 then 'PASS' else 'FAIL' end,null,'matching rows='||count(*)
from pg_temp.test_024_context c
join s2t_fhir.candidate_review_session_state s on s.review_session_id=c.session_two
where s.session_state='OPEN_FROZEN';

-- T25: legacy importer ACTIVE Review signature still rejects a human actor.
do $test$
begin
  perform s2t_fhir_api.start_mapping_review_session(
    'T024-LEGACY-GUARD','023c03a0-0000-4000-8000-000000000001'::uuid,null);
  insert into pg_temp.test_024_results values(25,'legacy ACTIVE Review importer guard unchanged','FAIL',null,'unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_024_results values(25,'legacy ACTIVE Review importer guard unchanged','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(25,'legacy ACTIVE Review importer guard unchanged','FAIL',sqlstate,sqlerrm);
end
$test$;

-- T26: an importer/admin function remains protected by the same historical guard.
do $test$
begin
  perform s2t_fhir.grant_baseline_action(
    '023c03a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD',
    '023c03a0-0000-4000-8000-000000000001'::uuid);
  insert into pg_temp.test_024_results values(26,'admin importer guard unchanged','FAIL',null,'unexpected success');
exception when sqlstate '42501' then
  insert into pg_temp.test_024_results values(26,'admin importer guard unchanged','PASS',sqlstate,sqlerrm);
when others then insert into pg_temp.test_024_results values(26,'admin importer guard unchanged','FAIL',sqlstate,sqlerrm);
end
$test$;

-- T27: ACTIVE Review authenticated start/end smoke remains operational.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','023c03a1-0000-4000-8000-000000000001',true);
do $test$
declare v_session uuid;
begin
  v_session:=s2t_fhir_api.start_authenticated_mapping_review_session(
    'T024-RUNTIME-ACTIVE-SMOKE','Migration 024 rollback-only ACTIVE smoke');
  perform s2t_fhir_api.end_authenticated_mapping_review_session(v_session);
  update pg_temp.test_024_context set active_session=v_session;
  insert into pg_temp.test_024_results values(27,'ACTIVE Review smoke unchanged','PASS',null,v_session::text);
exception when others then
  insert into pg_temp.test_024_results values(27,'ACTIVE Review smoke unchanged','FAIL',sqlstate,sqlerrm);
end
$test$;

-- T28: Governance authorization/write smoke remains operational.
do $test$
declare v_result jsonb; v_question uuid;
begin
  v_result:=s2t_fhir_api.gov_open_question(
    'T024-RUNTIME-GOVERNANCE-SMOKE','Migration 024 rollback-only Governance smoke',
    pg_catalog.transaction_timestamp(),'[]'::jsonb);
  v_question:=(v_result->>'question_id')::uuid;
  insert into pg_temp.test_024_results values(28,'Governance smoke unchanged','PASS',null,v_question::text);
exception when others then
  insert into pg_temp.test_024_results values(28,'Governance smoke unchanged','FAIL',sqlstate,sqlerrm);
end
$test$;

reset role;
set local role s2t_fhir_owner;

insert into pg_temp.test_024_report
  (sort_order,section,test_no,test_name,status,sqlstate_text,detail,fingerprint)
select 100+test_no,'TEST',test_no,test_name,status,sqlstate_text,detail,null
from pg_temp.test_024_results;

insert into pg_temp.test_024_report
  (sort_order,section,test_no,test_name,status,sqlstate_text,detail,fingerprint)
select 900,'SUMMARY',null,'runtime summary',
       case when count(*) filter(where status='FAIL')=0 then 'PASS' else 'FAIL' end,
       null,
       format('passed=%s; failed=%s; not_applicable=%s; tests_before_postrollback_t29=%s',
         count(*) filter(where status='PASS'),
         count(*) filter(where status='FAIL'),
         count(*) filter(where status='NOT_APPLICABLE'),count(*)),
       null
from pg_temp.test_024_results;

select section,test_no,test_name,status,sqlstate_text,detail,fingerprint
from pg_temp.test_024_report
order by sort_order,test_no nulls first;

rollback;
-- RUN A END

-- RUN B START
-- Run this read-only section separately after RUN A has completed its ROLLBACK.
with after_state as (
  select pg_catalog.md5(coalesce(pg_catalog.string_agg(x,'|' order by x),'')) as fingerprint
  from (
    select 'context:'||c.baseline_version_id::text||':'||c.candidate_lifecycle_event_id::text as x
    from s2t_fhir.baseline_candidate_context c
    where c.baseline_version_id in (
      '023c0301-0000-4000-8000-000000000001','023c0401-0000-4000-8000-000000000001',
      '023c0501-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001')
    union all
    select 'session:'||s.review_session_id::text from s2t_fhir.review_session s
    where s.session_name in ('T024-RUNTIME-C03-SESSION-1','T024-RUNTIME-C03-SESSION-2','T024-RUNTIME-ACTIVE-SMOKE')
    union all
    select 'question:'||q.question_id::text from s2t_governance.governance_question q
    where q.title='T024-RUNTIME-GOVERNANCE-SMOKE'
    union all
    select 'principal:'||p.principal_id::text||':'||coalesce(p.disabled_at::text,'ENABLED')
    from s2t_fhir.principal p
    where p.principal_id in (
      '023c04a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001')
    union all
    select 'review-auth:'||a.principal_id::text||':'||a.review_actor_authorization_id::text||':'||
           coalesce(a.revoked_at::text,'ACTIVE')
    from s2t_fhir.review_actor_authorization a
    where a.principal_id in (
      '023c04a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001')
  ) fingerprint_rows
),
t29_state as (
  select case when
    (select count(*) from s2t_fhir.review_session
     where session_name in ('T024-RUNTIME-C03-SESSION-1','T024-RUNTIME-C03-SESSION-2','T024-RUNTIME-ACTIVE-SMOKE'))=0
    and (select count(*) from s2t_governance.governance_question
         where title='T024-RUNTIME-GOVERNANCE-SMOKE')=0
    and (select count(*) from s2t_fhir.mapping_review_event
         where review_note in ('T024 REVIEWED','T024 NEEDS_FOLLOW_UP','T024 NOT_REVIEWED','closed session rejection','stale write'))=0
    and (select count(*) from s2t_fhir.baseline_candidate_context
         where baseline_version_id='023c0311-0000-4000-8000-000000000001'::uuid)=0
    and (select count(*) from s2t_fhir.principal where principal_id in (
           '023c04a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001')
         and disabled_at is null)=2
    and (select count(*) from s2t_fhir.review_actor_authorization where principal_id in (
           '023c04a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001')
         and revoked_at is null and effective_at<=pg_catalog.transaction_timestamp())=2
    then 'PASS' else 'FAIL' end as status
),
output_rows(sort_order,section,test_no,test_name,status,sqlstate_text,detail,fingerprint) as (
  select 929,'T29',29,'rollback restored committed state',t.status,null,
         'exact T024 names/IDs absent after ROLLBACK; compare with RUN A fingerprint',null
  from t29_state t
  union all
  select 1000,'RUNTIME_AFTER',null,'RUNTIME AFTER ROLLBACK fixture fingerprint',
         'CAPTURED',null,'committed fixture fingerprint after rollback',a.fingerprint
  from after_state a
)
select section,test_no,test_name,status,sqlstate_text,detail,fingerprint
from output_rows
order by sort_order,test_no nulls first;
-- RUN B END

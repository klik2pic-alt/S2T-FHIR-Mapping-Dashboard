-- =====================================================================
-- Governance Phase 1 — REVISION 7 TESTS
-- STATUS: REVIEW CANDIDATE — DO NOT EXECUTE UNTIL REVISION 7 IS APPROVED/APPLIED IN TEST.
-- Target: S2T-FHIR-DDL-Test.
--
-- Supabase SQL Editor compatible:
--   * no psql meta-commands
--   * no direct authenticated SELECT from governed_mapping_identity
--   * owner pre-resolves mapping identity keys, then authenticated receives only those keys
--   * temporary harness tables have explicit minimal grants across SET ROLE
--
-- Test data is wrapped in one transaction and rolled back.
-- If a runtime/syntax/permission error aborts before final ROLLBACK, issue ROLLBACK;
-- or close/reopen the SQL Editor connection before retry.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Editable parameters
-- ---------------------------------------------------------------------
create temp table _gov_test_params (
  reviewer_uid       text not null,
  noperm_uid         text not null,
  resource_config_id text not null
) on commit drop;

insert into _gov_test_params(reviewer_uid, noperm_uid, resource_config_id)
values (
  '<REVIEWER_UID_WITH_ACTIVE_S2T_REVIEW_WRITE>',
  '<AUTH_UID_WITHOUT_S2T_REVIEW_WRITE>',
  'medication-request-cato'
);

do $$
begin
  if exists (
    select 1 from _gov_test_params
    where reviewer_uid like '<%' or noperm_uid like '<%'
  ) then
    raise exception 'TEST PARAMETERS NOT SET: replace the two UID placeholders before running';
  end if;
end $$;

create temp table _gov_test_result (
  seq integer primary key,
  test_name text not null,
  result text not null check (result in ('PASS','FAIL')),
  details text
) on commit drop;

create temp table _ids (
  name text primary key,
  id uuid not null
) on commit drop;

-- Owner-only setup: pre-resolve ONLY the permitted three mapping identity keys.
create temp table _gov_test_mapping_keys (
  mapping_kind text primary key,
  resource_config_id text not null,
  baseline_code text not null,
  node_id text not null
) on commit drop;

insert into _gov_test_mapping_keys(mapping_kind, resource_config_id, baseline_code, node_id)
select distinct on (m.mapping_kind)
       m.mapping_kind, m.resource_config_id, m.baseline_code, m.node_id
from s2t_fhir_api.governed_mapping_identity m
where m.resource_config_id = (select resource_config_id from _gov_test_params)
  and m.is_active_baseline
  and m.mapping_kind in ('ELEMENT_MAPPING','GOVERNANCE_GUIDANCE')
order by m.mapping_kind, m.node_id;

do $$
begin
  if not exists (select 1 from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING') then
    raise exception 'TEST DATASET ERROR: no active ELEMENT_MAPPING row';
  end if;
  if not exists (select 1 from _gov_test_mapping_keys where mapping_kind='GOVERNANCE_GUIDANCE') then
    raise exception 'TEST DATASET ERROR: no active GOVERNANCE_GUIDANCE row';
  end if;
end $$;

-- Minimal harness privileges needed after SET ROLE authenticated.
grant select on _gov_test_params, _gov_test_mapping_keys to authenticated;
grant select, insert on _ids to authenticated;
grant insert on _gov_test_result to authenticated;

create function pg_temp.claims(p_uid text) returns void language sql as $$
  select set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text,
    true
  );
$$;

-- Narrow non-interference fingerprints.
create temp table _fp_before on commit drop as
select 'active_mapping_record' k,
       md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.mapping_key), '')) v
from s2t_fhir_api.active_mapping_record x
union all
select 'active_baseline',
       md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.source_system, x.fhir_resource, x.baseline_code), ''))
from s2t_fhir_api.active_baseline x
union all
select 'review',
       md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.node_id), ''))
from s2t_fhir_api.active_mapping_review_status x;

-- ---------------------------------------------------------------------
-- T01 dependency contracts + schema ownership
-- ---------------------------------------------------------------------
do $$
declare
  bad int := 0;
  p record;
begin
  if to_regprocedure('s2t_fhir_api._require_authenticated_review_principal()') is null
     or to_regclass('s2t_fhir_api.governed_mapping_identity') is null then
    bad := bad + 1;
  end if;

  if (select pg_get_userbyid(nspowner) from pg_namespace where nspname='s2t_fhir_api')
       is distinct from 's2t_fhir_owner' then bad := bad + 1; end if;
  if (select pg_get_userbyid(nspowner) from pg_namespace where nspname='s2t_governance')
       is distinct from 's2t_fhir_owner' then bad := bad + 1; end if;

  select pg_get_userbyid(pr.proowner) owner_name,
         format_type(pr.prorettype,null) return_type,
         pr.prosecdef,
         pr.provolatile,
         coalesce(array_to_string(pr.proconfig,','),'') config
    into p
  from pg_proc pr
  where pr.oid='s2t_fhir_api._require_authenticated_review_principal()'::regprocedure;

  if p.owner_name <> 's2t_fhir_owner'
     or p.return_type <> 'uuid'
     or not p.prosecdef
     or p.provolatile <> 's'
     or p.config not like '%search_path=pg_catalog, s2t_fhir_api%' then
    bad := bad + 1;
  end if;

  -- Least-privilege bootstrap invariant: s2t_fhir_owner may lack database CREATE.
  -- The migration runner is responsible for CREATE SCHEMA ... AUTHORIZATION.
  if has_database_privilege('s2t_fhir_owner', current_database(), 'CREATE') then
    null; -- Allowed, but not required.
  end if;

  insert into _gov_test_result values
    (1,'T01 dependency contracts + API/Governance schema ownership',
     case when bad=0 then 'PASS' else 'FAIL' end,
     'bad='||bad||', owner_db_create='||
       has_database_privilege('s2t_fhir_owner', current_database(), 'CREATE'));
end $$;

-- ---------------------------------------------------------------------
-- T02 ownership of Governance relations, sequences and functions
-- ---------------------------------------------------------------------
do $$
declare bad_rel int; bad_fn int;
begin
  select count(*) into bad_rel
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and c.relname like 'governance_%')
    )
    and pg_get_userbyid(c.relowner) <> 's2t_fhir_owner';

  select count(*) into bad_fn
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and (
            p.proname like 'gov\_%'
            or p.proname like '\_governance\_%'
          ))
    )
    and pg_get_userbyid(p.proowner) <> 's2t_fhir_owner';

  insert into _gov_test_result values
    (2,'T02 Governance relations/sequences/functions owned by s2t_fhir_owner',
     case when bad_rel=0 and bad_fn=0 then 'PASS' else 'FAIL' end,
     'bad_rel='||bad_rel||', bad_fn='||bad_fn);
end $$;

-- ---------------------------------------------------------------------
-- T03 private helpers denied; guarded public read wrappers executable
-- ---------------------------------------------------------------------
select pg_temp.claims((select reviewer_uid from _gov_test_params));
set local role authenticated;
do $$
declare
  private_denied boolean := false;
  wrapper_ok boolean := false;
begin
  begin
    perform s2t_governance._replay_state(gen_random_uuid());
  exception when insufficient_privilege then
    private_denied := true;
  end;

  begin
    perform s2t_fhir_api._governance_read_allowed();
    perform * from s2t_fhir_api._governance_replay_state(gen_random_uuid());
    perform * from s2t_fhir_api._governance_question_timing(gen_random_uuid());
    wrapper_ok := true;
  exception when others then
    wrapper_ok := false;
  end;

  insert into _gov_test_result values
    (3,'T03 private helpers denied; guarded API read wrappers executable',
     case when private_denied and wrapper_ok then 'PASS' else 'FAIL' end,
     'private_denied='||private_denied||', wrapper_ok='||wrapper_ok);
end $$;
reset role;

-- ---------------------------------------------------------------------
-- T04 non-reviewer public contract
-- ---------------------------------------------------------------------
select pg_temp.claims((select noperm_uid from _gov_test_params));
set local role authenticated;
do $$
declare ok boolean := true; c int;
begin
  select count(*) into c from s2t_fhir_api.governance_questions;
  if c <> 0 then ok := false; end if;

  if s2t_fhir_api._governance_read_allowed() then
    ok := false;
  end if;

  select count(*) into c
  from s2t_fhir_api._governance_replay_state(gen_random_uuid());
  if c <> 0 then ok := false; end if;

  select count(*) into c
  from s2t_fhir_api._governance_question_timing(gen_random_uuid());
  if c <> 0 then ok := false; end if;

  begin
    perform s2t_fhir_api.gov_open_question('No permission','Synthetic test',now(),'[]');
    ok := false;
  exception when insufficient_privilege then null;
  end;

  insert into _gov_test_result values
    (4,'T04 non-reviewer sees no governed rows and cannot write',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Reviewer tests
-- ---------------------------------------------------------------------
select pg_temp.claims((select reviewer_uid from _gov_test_params));
set local role authenticated;

-- T05 open question
do $$
declare q uuid;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Governance R5 test','Synthetic reviewer flow',
          now()-interval '40 days','[]'
       )->>'question_id')::uuid;
  insert into _ids values ('q',q);
  insert into _gov_test_result values (5,'T05 reviewer opens question','PASS',q::text);
end $$;

-- T06 response lifecycle
do $$
declare q uuid; party uuid; r uuid; ok boolean := true;
begin
  select id into q from _ids where name='q';
  select party_id into party from s2t_fhir_api.governance_parties where party_code='IL_CORE';

  r := s2t_fhir_api.gov_record_request(q,party,now()-interval '30 days','request');
  insert into _ids values ('request_final',r);

  perform s2t_fhir_api.gov_record_response(q,r,'INTERIM',now()-interval '29 days','interim 1');
  perform s2t_fhir_api.gov_record_response(q,r,'INTERIM',now()-interval '28 days','interim 2');
  perform s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '27 days','final');

  begin
    perform s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '26 days','duplicate final');
    ok := false;
  exception when check_violation then null; end;

  begin
    perform s2t_fhir_api.gov_record_response(q,r,'INTERIM',now()-interval '25 days','late interim');
    ok := false;
  exception when check_violation then null; end;

  insert into _gov_test_result values
    (6,'T06 INTERIM* then one FINAL; nothing after FINAL',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T07 cannot retract request beneath live responses
do $$
declare r uuid; ok boolean := false;
begin
  select id into r from _ids where name='request_final';
  begin
    perform s2t_fhir_api.gov_retract_event(r,'must fail');
  exception when check_violation then ok := true; end;

  insert into _gov_test_result values
    (7,'T07 request retraction cannot orphan live responses',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T08 unknown/inactive mapping fails closed
do $$
declare q uuid; ok boolean := false;
begin
  select id into q from _ids where name='q';
  begin
    perform s2t_fhir_api.gov_link_mapping(
      q,
      jsonb_build_object(
        'resource_config_id',(select resource_config_id from _gov_test_params),
        'baseline_code','NO-SUCH-BASELINE',
        'node_id','map-v1-does-not-exist'
      ),
      now()
    );
  exception when foreign_key_violation then ok := true; end;

  insert into _gov_test_result values
    (8,'T08 unknown/inactive mapping identity fails closed',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T09 client sends only identity keys; server snapshots metadata
do $$
declare q uuid; lk uuid; k record; ok boolean;
begin
  select id into q from _ids where name='q';
  select * into k from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING';

  lk := s2t_fhir_api.gov_link_mapping(
    q,
    jsonb_build_object(
      'resource_config_id',k.resource_config_id,
      'baseline_code',k.baseline_code,
      'node_id',k.node_id,
      'target_element','CLIENT-SUPPLIED-IGNORED',
      'mapping_kind','CLIENT-SUPPLIED-IGNORED'
    ),
    now()
  );
  insert into _ids values ('element_link',lk);

  select target_element <> 'CLIENT-SUPPLIED-IGNORED'
     and mapping_kind='ELEMENT_MAPPING'
  into ok
  from s2t_fhir_api.governance_mapping_links
  where link_id=lk;

  insert into _gov_test_result values
    (9,'T09 server snapshots mapping metadata; client extras ignored',
     case when coalesce(ok,false) then 'PASS' else 'FAIL' end,null);
end $$;

-- T10 guidance NULL element_path preserved
do $$
declare q uuid; lk uuid; k record; ok boolean;
begin
  select id into q from _ids where name='q';
  select * into k from _gov_test_mapping_keys where mapping_kind='GOVERNANCE_GUIDANCE';

  lk := s2t_fhir_api.gov_link_mapping(
    q,
    jsonb_build_object(
      'resource_config_id',k.resource_config_id,
      'baseline_code',k.baseline_code,
      'node_id',k.node_id
    ),
    now()
  );

  select mapping_kind='GOVERNANCE_GUIDANCE' and element_path is null
  into ok
  from s2t_fhir_api.governance_mapping_links
  where link_id=lk;

  insert into _gov_test_result values
    (10,'T10 GOVERNANCE_GUIDANCE preserves element_path NULL',
     case when coalesce(ok,false) then 'PASS' else 'FAIL' end,null);
end $$;

-- T11 link -> unlink causal chain; cannot retract link beneath live unlink
do $$
declare q uuid; lk uuid; le uuid; ok boolean := false;
begin
  select id into q from _ids where name='q';
  select id into lk from _ids where name='element_link';

  select event_id into le
  from s2t_fhir_api.governance_question_timeline
  where question_id=q and link_id=lk and event_type='MAPPING_LINKED';

  perform s2t_fhir_api.gov_unlink_mapping(q,lk,'synthetic unlink',now());

  begin
    perform s2t_fhir_api.gov_retract_event(le,'must fail');
  exception when check_violation then ok := true; end;

  insert into _gov_test_result values
    (11,'T11 MAPPING_LINKED cannot be retracted beneath live unlink',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T12 deterministic equal-effective-time order:
-- request->response, hold-start->hold-end, link->unlink all share one effective timestamp.
do $$
declare
  q uuid; p uuid; r uuid; lk uuid; k record;
  t0 timestamptz := now()-interval '1 day';
  ok boolean := true;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Equal-time ordering','Deterministic sequence test',
          now()-interval '2 days','[]'
       )->>'question_id')::uuid;

  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';

  r := s2t_fhir_api.gov_record_request(q,p,t0,null);
  perform s2t_fhir_api.gov_record_response(q,r,'FINAL',t0,'same effective time');

  perform s2t_fhir_api.gov_start_hold(q,'same-time hold',t0);
  perform s2t_fhir_api.gov_end_hold(q,t0,'same effective time');

  select * into k from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING';
  lk := s2t_fhir_api.gov_link_mapping(
    q,
    jsonb_build_object(
      'resource_config_id',k.resource_config_id,
      'baseline_code',k.baseline_code,
      'node_id',k.node_id
    ),
    t0
  );
  perform s2t_fhir_api.gov_unlink_mapping(q,lk,'same effective time',t0);

  if exists (
    select 1
    from (
      select event_type, recording_seq,
             lag(recording_seq) over(order by effective_at, recording_seq) prev_seq
      from s2t_fhir_api.governance_question_timeline
      where question_id=q
    ) s
    where prev_seq is not null and recording_seq <= prev_seq
  ) then
    ok := false;
  end if;

  insert into _gov_test_result values
    (12,'T12 equal-effective-time causal order uses immutable recording_seq',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T13 exact timing with overlapping waits and hold
do $$
declare q uuid; il uuid; term uuid; r1 uuid; r2 uuid; t record; ok boolean;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Timing test','Synthetic timing flow',
          now()-interval '40 days','[]'
       )->>'question_id')::uuid;

  select party_id into il from s2t_fhir_api.governance_parties where party_code='IL_CORE';
  select party_id into term from s2t_fhir_api.governance_parties where party_code='TERMINOLOGY';

  r1 := s2t_fhir_api.gov_record_request(q,il,now()-interval '30 days',null);
  r2 := s2t_fhir_api.gov_record_request(q,term,now()-interval '25 days',null);
  perform s2t_fhir_api.gov_record_response(q,r1,'FINAL',now()-interval '22 days','final');
  perform s2t_fhir_api.gov_record_response(q,r2,'FINAL',now()-interval '20 days','final');
  perform s2t_fhir_api.gov_start_hold(q,'hold',now()-interval '15 days');
  perform s2t_fhir_api.gov_end_hold(q,now()-interval '10 days');
  perform s2t_fhir_api.gov_record_decision(q,'decision','DOCUMENTATION_ONLY',now()-interval '5 days');

  select * into t from s2t_fhir_api.governance_question_timing where question_id=q;

  ok := round(extract(epoch from t.total_elapsed)/86400)=35
    and round(extract(epoch from t.external_waiting)/86400)=10
    and round(extract(epoch from t.on_hold)/86400)=5
    and round(extract(epoch from t.internal_handling)/86400)=20
    and round(extract(epoch from t.time_to_decision)/86400)=35;

  insert into _gov_test_result values
    (13,'T13 timing unions waits, excludes holds, preserves totals',
     case when ok then 'PASS' else 'FAIL' end,
     'total='||t.total_elapsed||', external='||t.external_waiting||
     ', hold='||t.on_hold||', internal='||t.internal_handling||
     ', ttd='||t.time_to_decision);
end $$;

-- T14 CLOSED rejects open request
do $$
declare q uuid; p uuid; r uuid; ok boolean := false;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Close guard','Synthetic close guard',
          now()-interval '3 days','[]'
       )->>'question_id')::uuid;
  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';
  r := s2t_fhir_api.gov_record_request(q,p,now()-interval '2 days',null);
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '1 day');

  begin
    perform s2t_fhir_api.gov_close(q,now(),null);
  exception when check_violation then ok := true; end;

  insert into _gov_test_result values
    (14,'T14 CLOSED rejected while request lacks FINAL',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T15 CLOSED operation contract + REOPEN success
do $$
declare
  q uuid; p uuid; r uuid; k record; lk uuid;
  note_ok boolean := false;
  request_reject boolean := false;
  hold_reject boolean := false;
  decision_reject boolean := false;
  link_reject boolean := false;
  close_reject boolean := false;
  reopen_ok boolean := false;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Closed operations','Synthetic closed flow',
          now()-interval '5 days','[]'
       )->>'question_id')::uuid;
  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';

  r := s2t_fhir_api.gov_record_request(q,p,now()-interval '4 days',null);
  perform s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '3 days','final');
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '2 days');
  perform s2t_fhir_api.gov_close(q,now()-interval '1 day',null);

  perform s2t_fhir_api.gov_add_note(q,'audit note after close',now(),null);
  note_ok := true;

  begin perform s2t_fhir_api.gov_record_request(q,p,now(),null);
  exception when check_violation then request_reject := true; end;

  begin perform s2t_fhir_api.gov_start_hold(q,'not allowed',now());
  exception when check_violation then hold_reject := true; end;

  begin perform s2t_fhir_api.gov_record_decision(q,'not allowed','NO_CHANGE',now());
  exception when check_violation then decision_reject := true; end;

  select * into k from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING';
  begin
    lk := s2t_fhir_api.gov_link_mapping(
      q,
      jsonb_build_object(
        'resource_config_id',k.resource_config_id,
        'baseline_code',k.baseline_code,
        'node_id',k.node_id
      ),
      now()
    );
  exception when check_violation then link_reject := true; end;

  begin perform s2t_fhir_api.gov_close(q,now(),null);
  exception when check_violation then close_reject := true; end;

  perform s2t_fhir_api.gov_reopen(q,'new evidence',now());
  reopen_ok := (select derived_status='REOPENED'
                from s2t_fhir_api.governance_questions where question_id=q);

  insert into _gov_test_result values
    (15,'T15 CLOSED contract: note allowed, lifecycle writes rejected, REOPEN succeeds',
     case when note_ok and request_reject and hold_reject and decision_reject
                    and link_reject and close_reject and reopen_ok
          then 'PASS' else 'FAIL' end,null);
end $$;

-- T16 causal retraction cases
do $$
declare
  q uuid; p uuid; r uuid; final_ev uuid;
  hs uuid; he uuid;
  ok_final boolean := false;
  ok_hs boolean := false;
  ok_he boolean := false;
begin
  -- FINAL beneath CLOSED
  q := (s2t_fhir_api.gov_open_question(
          'Retraction final','Synthetic',
          now()-interval '5 days','[]'
       )->>'question_id')::uuid;
  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';
  r := s2t_fhir_api.gov_record_request(q,p,now()-interval '4 days',null);
  final_ev := s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '3 days','final');
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '2 days');
  perform s2t_fhir_api.gov_close(q,now()-interval '1 day',null);
  begin perform s2t_fhir_api.gov_retract_event(final_ev,'must fail');
  exception when check_violation then ok_final := true; end;

  -- HOLD_STARTED beneath HOLD_ENDED
  q := (s2t_fhir_api.gov_open_question(
          'Retraction hold start','Synthetic',
          now()-interval '5 days','[]'
       )->>'question_id')::uuid;
  hs := s2t_fhir_api.gov_start_hold(q,'hold',now()-interval '4 days');
  he := s2t_fhir_api.gov_end_hold(q,now()-interval '3 days');
  begin perform s2t_fhir_api.gov_retract_event(hs,'must fail');
  exception when check_violation then ok_hs := true; end;

  -- HOLD_ENDED beneath later decision
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '2 days');
  begin perform s2t_fhir_api.gov_retract_event(he,'must fail');
  exception when check_violation then ok_he := true; end;

  insert into _gov_test_result values
    (16,'T16 causal retractions cannot invalidate FINAL/hold dependencies',
     case when ok_final and ok_hs and ok_he then 'PASS' else 'FAIL' end,null);
end $$;

-- T17 invalid backdated event is rejected and absent
do $$
declare q uuid; before_n int; after_n int; ok boolean := false;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Backdated replay','Synthetic',
          now()-interval '10 days','[]'
       )->>'question_id')::uuid;

  perform s2t_fhir_api.gov_start_hold(q,'hold',now()-interval '5 days');
  perform s2t_fhir_api.gov_end_hold(q,now()-interval '3 days');

  select count(*) into before_n
  from s2t_fhir_api.governance_question_timeline where question_id=q;

  begin
    perform s2t_fhir_api.gov_end_hold(q,now()-interval '7 days','invalid backdate');
  exception when check_violation then ok := true; end;

  select count(*) into after_n
  from s2t_fhir_api.governance_question_timeline where question_id=q;

  if before_n <> after_n then ok := false; end if;

  insert into _gov_test_result values
    (17,'T17 replay rejects invalid backdated history with no residue',
     case when ok then 'PASS' else 'FAIL' end,
     'before='||before_n||', after='||after_n);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Owner/static tests after reviewer flow
-- ---------------------------------------------------------------------

-- T18 append-only protection
-- TRUNCATE targets governance_event so FK topology does not mask the append-only trigger.
do $$
declare ok boolean := true;
begin
  begin update s2t_governance.governance_event set note='x'; ok:=false;
  exception when insufficient_privilege then null; end;
  begin delete from s2t_governance.governance_question; ok:=false;
  exception when insufficient_privilege then null; end;
  begin truncate s2t_governance.governance_event; ok:=false;
  exception when insufficient_privilege then null; end;

  insert into _gov_test_result values
    (18,'T18 append-only UPDATE/DELETE/TRUNCATE protection',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T19 client privilege model
do $$
declare bad_table int; bad_fn int;
begin
  select count(*) into bad_table
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='s2t_governance'
    and (
      has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE')
      or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE')
    );

  select count(*) into bad_fn
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='s2t_governance'
    and (
      has_function_privilege('anon',p.oid,'EXECUTE')
      or has_function_privilege('authenticated',p.oid,'EXECUTE')
    );

  insert into _gov_test_result values
    (19,'T19 private Governance inaccessible; read wrappers are API-only bridge',
     case when bad_table=0 and bad_fn=0
       and has_function_privilege('authenticated',
           's2t_fhir_api._governance_read_allowed()'::regprocedure,'EXECUTE')
       and has_function_privilege('authenticated',
           's2t_fhir_api._governance_replay_state(uuid)'::regprocedure,'EXECUTE')
       and has_function_privilege('authenticated',
           's2t_fhir_api._governance_question_timing(uuid)'::regprocedure,'EXECUTE')
       and not has_function_privilege('anon',
           's2t_fhir_api._governance_read_allowed()'::regprocedure,'EXECUTE')
       and not has_function_privilege('anon',
           's2t_fhir_api._governance_replay_state(uuid)'::regprocedure,'EXECUTE')
       and not has_function_privilege('anon',
           's2t_fhir_api._governance_question_timing(uuid)'::regprocedure,'EXECUTE')
     then 'PASS' else 'FAIL' end,
     'bad_table='||bad_table||', bad_private_fn='||bad_fn);
end $$;

-- T20 resolver source is active-only + STRICT + TOO_MANY_ROWS handling
-- POSIX [[:space:]] is used intentionally for pg_get_functiondef() text matching.
do $$
declare d text; ok boolean;
begin
  select pg_get_functiondef(
    's2t_governance._resolve_mapping_identity(text,text,text)'::regprocedure
  ) into d;

  ok := d ~* 'into[[:space:]]+strict'
    and d ~* 'is_active_baseline[[:space:]]*=[[:space:]]*true'
    and d ~* 'too_many_rows';

  insert into _gov_test_result values
    (20,'T20 mapping resolver fails closed on 0 or >1 active matches',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T21 deterministic ordering definition + immutable recording_seq
-- POSIX [[:space:]] avoids backslash-escape ambiguity in PostgreSQL regex strings.
do $$
declare d text; ok boolean; col_ok boolean;
begin
  select pg_get_functiondef(
    's2t_governance._replay_state(uuid,boolean)'::regprocedure
  ) into d;

  select a.attidentity='a' and a.attnotnull
    into col_ok
  from pg_attribute a
  where a.attrelid='s2t_governance.governance_event'::regclass
    and a.attname='recording_seq'
    and a.attnum>0 and not a.attisdropped;

  ok := coalesce(col_ok,false)
    and d ~* 'order[[:space:]]+by[[:space:]]+ev[.]effective_at[[:space:]]*,[[:space:]]*ev[.]recording_seq';

  insert into _gov_test_result values
    (21,'T21 replay uses identity recording_seq as deterministic causal tie-breaker',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T22 governance_open_requests contains only genuinely open requests
do $$
declare bad int;
begin
  select count(*) into bad
  from s2t_fhir_api.governance_open_requests o
  where exists (
    select 1
    from s2t_fhir_api.governance_question_timeline f
    where f.question_id=o.question_id
      and f.related_request_event_id=o.request_event_id
      and f.event_type='RESPONSE_RECEIVED'
      and f.response_kind='FINAL'
      and not f.is_retracted
  );

  insert into _gov_test_result values
    (22,'T22 governance_open_requests excludes requests with live FINAL',
     case when bad=0 then 'PASS' else 'FAIL' end,'bad='||bad);
end $$;

-- T23 no resource-specific Governance branches
do $$
declare bad int;
begin
  select count(*) into bad
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and p.proname like 'gov\\_%')
    )
    and p.prosrc ~* '(medication-request-cato|MedicationRequest|CATO|_lovable_mapping_node)';

  insert into _gov_test_result values
    (23,'T23 no resource-specific Governance branches',
     case when bad=0 then 'PASS' else 'FAIL' end,'bad='||bad);
end $$;

-- T24 no mapping/Baseline/review writes
do $$
declare bad int;
begin
  select count(*) into bad
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and p.proname like 'gov\\_%')
    )
    and p.prosrc ~* '(insert\\s+into|update|delete\\s+from)\\s+s2t_fhir\\.';

  insert into _gov_test_result values
    (24,'T24 Governance functions do not write mapping/Baseline/review schemas',
     case when bad=0 then 'PASS' else 'FAIL' end,'bad='||bad);
end $$;

-- T25 narrow non-interference fingerprint
do $$
declare bad int;
begin
  with fp_after as (
    select 'active_mapping_record' k,
           md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.mapping_key), '')) v
    from s2t_fhir_api.active_mapping_record x
    union all
    select 'active_baseline',
           md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.source_system, x.fhir_resource, x.baseline_code), ''))
    from s2t_fhir_api.active_baseline x
    union all
    select 'review',
           md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.node_id), ''))
    from s2t_fhir_api.active_mapping_review_status x
  )
  select count(*) into bad
  from _fp_before b join fp_after a using(k)
  where a.v is distinct from b.v;

  insert into _gov_test_result values
    (25,'T25 mapping/Baseline/review fingerprints unchanged',
     case when bad=0 then 'PASS' else 'FAIL' end,'changed='||bad);
end $$;

-- Manual two-session concurrency checks still required after automated dry-run:
-- C1 HOLD_STARTED vs HOLD_STARTED on same question.
-- C2 DECISION_RECORDED vs DECISION_RECORDED on same question.
-- C3 FINAL response vs FINAL response on same request.
-- C4 request retraction vs FINAL response.
-- C5 MAPPING_UNLINKED vs MAPPING_UNLINKED.
-- C6 MAPPING_LINKED vs CLOSE on same question.
-- C7 REQUEST_SENT vs CLOSE on same question.
-- Expected in every case: second writer blocks on the per-question advisory lock, then
-- replays committed history and either fails 23514 or records the single valid successor.

select seq, test_name, result, details
from _gov_test_result
order by seq;

select
  999999 as seq,
  'AGGREGATE' as test_name,
  case when count(*) filter (where result='FAIL')=0 then 'ALL PASS' else 'FAIL' end as result,
  'pass='||count(*) filter (where result='PASS')||
  ', fail='||count(*) filter (where result='FAIL') as details
from _gov_test_result;

rollback;

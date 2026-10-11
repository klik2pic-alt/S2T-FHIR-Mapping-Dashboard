-- Migration 024 read-only postdeployment verification.
-- This script contains SELECT statements only. It creates no objects and mutates no data.

with
client_roles(role_name) as (
  values ('authenticated'),('anon'),('service_role'),('s2t_fhir_importer'),
         ('s2t_fhir_api_reader'),('s2t_fhir_governance_reader')
),
target_expected(signature,return_type,body_md5) as (
  values
    ('s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)',
     'uuid','fb2324ade872d878859aba075dbc8948'),
    ('s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)',
     'void','ab3517926eeea0f9ed9fdf6f48b732c3'),
    ('s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)',
     'void','348c14ed64eb6d714337f9e82e11587a')
),
target_state as (
  select e.*,p.oid,owner.rolname owner_name,p.prosecdef,p.provolatile,
         p.proconfig,p.proacl,p.prosrc,
         pg_catalog.pg_get_function_result(p.oid) actual_return_type,
         pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g')) actual_body_md5,
         (select count(*) from pg_catalog.regexp_matches(
           p.prosrc,'s2t_fhir_api\._assert_review_actor\s*\(','gi')) guard_count
  from target_expected e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
wrapper_expected(signature,body_md5,expected_core) as (
  values
    ('s2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)',
     'a985f47e1e9cc45c4312fbba7c9035a0','_start_candidate_review_session'),
    ('s2t_fhir_api.end_authenticated_candidate_review_session(uuid,uuid,uuid)',
     '8430a675bac72d8d1881ff78f8674f15','_end_candidate_review_session'),
    ('s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)',
     'b74ffa8b39f10a4ccb283dce3a5d0c9c','_record_candidate_mapping_review'),
    ('s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid,uuid,text,uuid,text)',
     '806937be5df5f4c43291dbafe4e2ab6f','_record_candidate_mapping_review'),
    ('s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid,uuid,text,uuid,text)',
     '8511baa88e31b29e46279486ab562115','_record_candidate_mapping_review')
),
wrapper_state as (
  select e.*,p.oid,p.prosrc,p.proargnames,p.proacl,p.proowner,
         owner.rolname owner_name,p.prosecdef,p.provolatile,p.proconfig,
         pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g')) actual_body_md5,
         (select count(*) from pg_catalog.regexp_matches(
           p.prosrc,'s2t_fhir_api\._require_authenticated_review_principal\s*\(\s*\)','gi')) auth_call_count
  from wrapper_expected e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
expected_callers(target_name,caller_signature) as (
  values
    ('_start_candidate_review_session','s2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)'),
    ('_end_candidate_review_session','s2t_fhir_api.end_authenticated_candidate_review_session(uuid,uuid,uuid)'),
    ('_record_candidate_mapping_review','s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)'),
    ('_record_candidate_mapping_review','s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid,uuid,text,uuid,text)'),
    ('_record_candidate_mapping_review','s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid,uuid,text,uuid,text)')
),
actual_callers as (
  select target.target_name,
         n.nspname||'.'||p.proname||'('||pg_catalog.replace(
           pg_catalog.oidvectortypes(p.proargtypes),', ', ',')||')'
         as caller_signature
  from (values
    ('_start_candidate_review_session'),
    ('_end_candidate_review_session'),
    ('_record_candidate_mapping_review')
  ) target(target_name)
  join pg_catalog.pg_proc p
    on pg_catalog.strpos(p.prosrc,'s2t_fhir_api.'||target.target_name||'(')>0
  join pg_catalog.pg_namespace n on n.oid=p.pronamespace
),
untouched_expected(signature,body_md5,area) as (
  values
    ('s2t_fhir_api._start_mapping_review_session(text,uuid,text)','6cb4bf4171be4d740a933a69fb7c96f5','ACTIVE Review'),
    ('s2t_fhir_api._end_mapping_review_session(uuid,uuid)','2cc5fce8d24c5bace6b88f9d8626cb5a','ACTIVE Review'),
    ('s2t_fhir_api._record_mapping_review_core(text,text,uuid,uuid,text)','1339420196a3c78bf65309dc1407c858','ACTIVE Review'),
    ('s2t_governance._current_reviewer_principal()','38de713b25ab452fa6a45c95122285c8','Governance'),
    ('s2t_fhir_api.gov_open_question(text,text,timestamptz,jsonb)','b5bfbf3cb2be3b0cc79ba16bf4a7e3fc','Governance'),
    ('s2t_fhir_api.gov_link_candidate_mapping(uuid,uuid,uuid,jsonb,timestamptz)','c1314b99d6525b591d77127bfae8124d','Governance')
),
untouched_state as (
  select e.*,p.oid,
         pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g')) actual_body_md5
  from untouched_expected e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
),
review_oids as (
  select pg_catalog.to_regclass('s2t_fhir.review_session') review_session_oid,
         pg_catalog.to_regclass('s2t_fhir.mapping_review_event') review_event_oid,
         pg_catalog.to_regclass('s2t_fhir.candidate_review_session_state') state_view_oid
),
review_objects as (
  select
    o.review_session_oid is not null as review_session_exists,
    o.review_event_oid is not null as review_event_exists,
    o.state_view_oid is not null as state_view_exists,
    exists(select 1 from pg_catalog.pg_attribute a
      where a.attrelid=o.review_session_oid
        and a.attname='review_target_lifecycle_event_id' and not a.attisdropped
        and a.atttypid='uuid'::regtype) as session_column_exact,
    exists(select 1 from pg_catalog.pg_attribute a
      where a.attrelid=o.review_event_oid
        and a.attname='review_target_lifecycle_event_id' and not a.attisdropped
        and a.atttypid='uuid'::regtype) as event_column_exact,
    (select c.reloptions @> array['security_barrier=true']::text[]
       and pg_catalog.pg_get_viewdef(c.oid,true) like '%OPEN_CURRENT%'
       and pg_catalog.pg_get_viewdef(c.oid,true) like '%OPEN_FROZEN%'
       and pg_catalog.pg_get_viewdef(c.oid,true) like '%CLOSED%'
     from pg_catalog.pg_class c
     where c.oid=o.state_view_oid) as view_contract_exact
  from review_oids o
),
checks(check_no,check_name,result,detail) as (
  select 1,'three target signatures and metadata',
    case when count(*)=3 and bool_and(oid is not null and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile='v'
      and proconfig is not distinct from array['search_path=""']
      and actual_return_type=return_type) then 'PASS' else 'FAIL' end,
    format('%s/3 exact',count(*) filter(where oid is not null and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile='v' and proconfig is not distinct from array['search_path=""']
      and actual_return_type=return_type))
    from target_state
  union all
  select 2,'defect removed with exact body parity',
    case when bool_and(guard_count=0 and actual_body_md5=body_md5) then 'PASS' else 'FAIL' end,
    string_agg(signature||':guard='||coalesce(guard_count::text,'NULL')||':md5='||coalesce(actual_body_md5,'NULL'),'; ' order by signature)
    from target_state
  union all
  select 3,'private core ACL is owner-only',
    case when not exists(
      select 1 from target_state t cross join client_roles r
      where t.oid is null or pg_catalog.has_function_privilege(r.role_name,t.oid,'EXECUTE')
    ) and not exists(
      select 1 from target_state t
      cross join lateral pg_catalog.aclexplode(coalesce(t.proacl,
        pg_catalog.acldefault('f',(select p.proowner from pg_catalog.pg_proc p where p.oid=t.oid)))) acl
      where acl.privilege_type='EXECUTE'
        and acl.grantee<>(select p.proowner from pg_catalog.pg_proc p where p.oid=t.oid)
    ) then 'PASS' else 'FAIL' end,
    'PUBLIC and six client/import roles denied'
    from (select 1) seed
  union all
  select 4,'historical importer guard unchanged',
    case when p.oid is not null and owner.rolname='s2t_fhir_owner' and p.prosecdef
      and p.provolatile='s'
      and p.proconfig is not distinct from array['search_path=pg_catalog, s2t_fhir_api']
      and pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g'))='fbd414965d0705cdcc0c1a5802c5a415'
      then 'PASS' else 'FAIL' end,
    'importer-only guard fingerprint and metadata'
    from (select pg_catalog.to_regprocedure('s2t_fhir_api._assert_review_actor(uuid)') oid) x
    left join pg_catalog.pg_proc p on p.oid=x.oid
    left join pg_catalog.pg_roles owner on owner.oid=p.proowner
  union all
  select 5,'authenticated authorization chain unchanged',
    case when
      (select pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g'))
       from pg_catalog.pg_proc p where p.oid=pg_catalog.to_regprocedure(
         's2t_fhir_api._require_authenticated_review_principal()'))='25fe6d45595b4e6d6cef5dd74e50643c'
      and
      (select pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g'))
       from pg_catalog.pg_proc p where p.oid=pg_catalog.to_regprocedure(
         's2t_fhir_api._resolve_authenticated_principal()'))='0fb059ee81137fac7b3c9ce6572f99c1'
      then 'PASS' else 'FAIL' end,
    'review capability and JWT resolver fingerprints'
  union all
  select 6,'five public wrappers unchanged',
    case when count(*)=5 and bool_and(oid is not null and actual_body_md5=body_md5
      and auth_call_count=1
      and pg_catalog.strpos(prosrc,'s2t_fhir_api.'||expected_core||'(')>0
      and not exists(select 1 from pg_catalog.unnest(coalesce(proargnames,array[]::text[])) n
                     where n~*'(actor|principal)')
      and owner_name='s2t_fhir_owner' and prosecdef and provolatile='v'
      and proconfig is not distinct from array['search_path=""']
      and pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE'))
      then 'PASS' else 'FAIL' end,
    format('%s/5 exact',count(*) filter(where oid is not null and actual_body_md5=body_md5))
    from wrapper_state
  union all
  select 7,'wrapper privilege boundary unchanged',
    case when not exists(
      select 1 from wrapper_state w cross join client_roles r
      where r.role_name<>'authenticated'
        and (w.oid is null or pg_catalog.has_function_privilege(r.role_name,w.oid,'EXECUTE'))
    ) and not exists(
      select 1 from wrapper_state w
      cross join lateral pg_catalog.aclexplode(coalesce(
        w.proacl,pg_catalog.acldefault('f',w.proowner))) acl
      where acl.privilege_type='EXECUTE'
        and acl.grantee not in (
          w.proowner,
          (select r.oid from pg_catalog.pg_roles r where r.rolname='authenticated')
        )
    ) then 'PASS' else 'FAIL' end,
    'only owner and authenticated have EXECUTE'
    from (select 1) seed
  union all
  select 8,'private core caller inventory exact',
    case when not exists(select * from expected_callers except select * from actual_callers)
      and not exists(select * from actual_callers except select * from expected_callers)
      then 'PASS' else 'FAIL' end,
    format('expected=%s actual=%s',(select count(*) from expected_callers),(select count(*) from actual_callers))
  union all
  select 9,'ACTIVE Review and Governance sentinels unchanged',
    case when count(*)=6 and bool_and(oid is not null and body_md5=actual_body_md5)
      then 'PASS' else 'FAIL' end,
    format('%s/6 exact',count(*) filter(where oid is not null and body_md5=actual_body_md5))
    from untouched_state
  union all
  select 10,'Candidate Review relations and view unchanged',
    case when review_session_exists and review_event_exists and state_view_exists
      and session_column_exact and event_column_exact and view_contract_exact
      then 'PASS' else 'FAIL' end,
    'tables, lifecycle provenance columns, and state view contract'
    from review_objects
  union all
  select 11,'Candidate Review triggers unchanged',
    case when count(*)=4 and bool_and(t.oid is not null and t.tgenabled<>'D')
      then 'PASS' else 'FAIL' end,
    format('%s/4 present and enabled',count(*) filter(where t.oid is not null and t.tgenabled<>'D'))
    from (values
      ('s2t_fhir.review_session','review_session_lifecycle_provenance_insert_trg'),
      ('s2t_fhir.review_session','review_session_lifecycle_provenance_immutable_trg'),
      ('s2t_fhir.mapping_review_event','mapping_review_event_lifecycle_provenance_insert_trg'),
      ('s2t_fhir.mapping_review_event','mapping_review_event_lifecycle_provenance_immutable_trg')
    ) e(relation_name,trigger_name)
    left join pg_catalog.pg_trigger t
      on t.tgrelid=pg_catalog.to_regclass(e.relation_name)
     and t.tgname=e.trigger_name and not t.tgisinternal
  union all
  select 12,'Candidate Review constraints and indexes unchanged',
    case when
      (select count(*) from pg_catalog.pg_constraint c where c.conname in (
        'review_session_target_lifecycle_event_fk','mapping_review_event_target_lifecycle_event_fk')
        and c.conrelid in (
          pg_catalog.to_regclass('s2t_fhir.review_session'),
          pg_catalog.to_regclass('s2t_fhir.mapping_review_event'))
        and c.convalidated)=2
      and (select count(*) from pg_catalog.pg_index i where i.indexrelid in (
        pg_catalog.to_regclass('s2t_fhir.review_session_target_lifecycle_idx'),
        pg_catalog.to_regclass('s2t_fhir.mapping_review_event_target_lifecycle_idx'))
        and i.indisvalid and i.indisready)=2
      then 'PASS' else 'FAIL' end,
    'two validated FKs and two valid lifecycle indexes'
),
output_rows as (
  select check_no,check_name,result,detail from checks
  union all
  select 999,'POSTDEPLOY SUMMARY',
    case when count(*) filter(where result<>'PASS')=0 then 'PASS' else 'FAIL' end,
    format('%s/%s checks passed',count(*) filter(where result='PASS'),count(*))
  from checks
)
select check_no,check_name,result,detail
from output_rows
order by check_no;

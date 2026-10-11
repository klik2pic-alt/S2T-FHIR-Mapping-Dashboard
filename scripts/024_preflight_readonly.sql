-- Migration 024 read-only preflight.
-- Target: S2T-FHIR-DDL-Test after Migration 023 and before Migration 024.
-- This script contains SELECT statements only. It creates no objects and mutates no data.

with
client_roles(role_name) as (
  values ('authenticated'),('anon'),('service_role'),('s2t_fhir_importer'),
         ('s2t_fhir_api_reader'),('s2t_fhir_governance_reader')
),
target_expected(signature,return_type,post024_body_md5) as (
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
         p.proconfig,p.proacl,p.prosrc,pg_catalog.pg_get_function_result(p.oid) actual_return_type,
         (select count(*) from pg_catalog.regexp_matches(
           p.prosrc,
           'perform\s+s2t_fhir_api\._assert_review_actor\s*\(\s*p_actor_principal_id\s*\)\s*;',
           'gi')) guard_count,
         pg_catalog.md5(pg_catalog.regexp_replace(
           pg_catalog.regexp_replace(
             p.prosrc,
             'perform\s+s2t_fhir_api\._assert_review_actor\s*\(\s*p_actor_principal_id\s*\)\s*;',
             '', 'gi'),
           '\s+',' ','g')) body_without_guard_md5
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
    on pg_catalog.strpos(
      p.prosrc,'s2t_fhir_api.'||target.target_name||'('
    ) > 0
  join pg_catalog.pg_namespace n on n.oid=p.pronamespace
),
fixture_workers(principal_id,auth_subject) as (
  values
    ('023c01a0-0000-4000-8000-000000000001'::uuid,'023c01a1-0000-4000-8000-000000000001'),
    ('023c01b0-0000-4000-8000-000000000001'::uuid,'023c01b1-0000-4000-8000-000000000001'),
    ('023c02a0-0000-4000-8000-000000000001'::uuid,'023c02a1-0000-4000-8000-000000000001'),
    ('023c02b0-0000-4000-8000-000000000001'::uuid,'023c02b1-0000-4000-8000-000000000001'),
    ('023c03a0-0000-4000-8000-000000000001'::uuid,'023c03a1-0000-4000-8000-000000000001'),
    ('023c03b0-0000-4000-8000-000000000001'::uuid,'023c03b1-0000-4000-8000-000000000001'),
    ('023c04a0-0000-4000-8000-000000000001'::uuid,'023c04a1-0000-4000-8000-000000000001'),
    ('023c04b0-0000-4000-8000-000000000001'::uuid,'023c04b1-0000-4000-8000-000000000001'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'023c05a1-0000-4000-8000-000000000001'),
    ('023c05b0-0000-4000-8000-000000000001'::uuid,'023c05b1-0000-4000-8000-000000000001'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'023c06a1-0000-4000-8000-000000000001'),
    ('023c06b0-0000-4000-8000-000000000001'::uuid,'023c06b1-0000-4000-8000-000000000001'),
    ('023c07a0-0000-4000-8000-000000000001'::uuid,'023c07a1-0000-4000-8000-000000000001'),
    ('023c07b0-0000-4000-8000-000000000001'::uuid,'023c07b1-0000-4000-8000-000000000001')
),
fixture_expected_capability(principal_id,capability_code) as (
  values
    ('023c01a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c01b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c02a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c02b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c03a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),
    ('023c03b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c04a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),
    ('023c04b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),
    ('023c05a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c05b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_REVIEW_WRITE'),
    ('023c06a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c06b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c06b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_PROMOTE'),
    ('023c07a0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD'),
    ('023c07b0-0000-4000-8000-000000000001'::uuid,'S2T_BASELINE_UPLOAD')
),
fixture_actual_capability as (
  select a.principal_id,a.capability_code
  from s2t_fhir.baseline_action_authorization a
  join fixture_workers w using(principal_id)
  where a.revoked_at is null and a.effective_at<=pg_catalog.transaction_timestamp()
  union all
  select a.principal_id,a.capability_code
  from s2t_fhir.review_actor_authorization a
  join fixture_workers w using(principal_id)
  where a.revoked_at is null and a.effective_at<=pg_catalog.transaction_timestamp()
),
fixture_state as (
  select
    (select count(*) from fixture_workers w join s2t_fhir.principal p using(principal_id)
      where p.external_issuer='supabase-auth' and p.external_subject=w.auth_subject
        and p.disabled_at is null)=14 as workers_exact,
    not exists(select * from fixture_expected_capability except select * from fixture_actual_capability)
      and not exists(select * from fixture_actual_capability except select * from fixture_expected_capability)
      as capabilities_exact,
    (select count(*) from s2t_fhir.baseline_series where baseline_series_id in (
      '023c0100-0000-4000-8000-000000000001','023c0200-0000-4000-8000-000000000002',
      '023c0300-0000-4000-8000-000000000003','023c0400-0000-4000-8000-000000000004',
      '023c0500-0000-4000-8000-000000000005','023c0600-0000-4000-8000-000000000006',
      '023c0700-0000-4000-8000-000000000071','023c0700-0000-4000-8000-000000000072'))=8
      as series_exact,
    (select count(*) from s2t_fhir.mapping_resource_registry where resource_config_id in (
      't023-conc-pack-20261009-r1-c03-resource','t023-conc-pack-20261009-r1-c04-resource',
      't023-conc-pack-20261009-r1-c05-resource','t023-conc-pack-20261009-r1-c06-resource'))=4
      as registry_exact,
    (select count(*) from s2t_fhir.baseline_version where baseline_version_id in (
      '023c0101-0000-4000-8000-000000000001','023c0111-0000-4000-8000-000000000001',
      '023c0201-0000-4000-8000-000000000001','023c0211-0000-4000-8000-000000000001','023c0221-0000-4000-8000-000000000001',
      '023c0301-0000-4000-8000-000000000001','023c0311-0000-4000-8000-000000000001',
      '023c0401-0000-4000-8000-000000000001','023c0411-0000-4000-8000-000000000001',
      '023c0501-0000-4000-8000-000000000001','023c0511-0000-4000-8000-000000000001',
      '023c0601-0000-4000-8000-000000000001','023c0611-0000-4000-8000-000000000001','023c0621-0000-4000-8000-000000000001',
      '023c0701-0000-4000-8000-000000000001','023c0711-0000-4000-8000-000000000001',
      '023c0781-0000-4000-8000-000000000001','023c0791-0000-4000-8000-000000000001'))=18
      as baselines_exact,
    (select count(*) from s2t_fhir.artifact where artifact_id in (
      '023c0102-0000-4000-8000-000000000001','023c0112-0000-4000-8000-000000000001',
      '023c0202-0000-4000-8000-000000000001','023c0212-0000-4000-8000-000000000001','023c0222-0000-4000-8000-000000000001',
      '023c0302-0000-4000-8000-000000000001','023c0312-0000-4000-8000-000000000001',
      '023c0402-0000-4000-8000-000000000001','023c0412-0000-4000-8000-000000000001',
      '023c0502-0000-4000-8000-000000000001','023c0512-0000-4000-8000-000000000001',
      '023c0602-0000-4000-8000-000000000001','023c0612-0000-4000-8000-000000000001','023c0622-0000-4000-8000-000000000001',
      '023c0702-0000-4000-8000-000000000001','023c0712-0000-4000-8000-000000000001',
      '023c0782-0000-4000-8000-000000000001','023c0792-0000-4000-8000-000000000001'))=18
      as artifacts_exact,
    (select count(*) from s2t_fhir.import_run where import_run_id in (
      '023c0103-0000-4000-8000-000000000001','023c0113-0000-4000-8000-000000000001',
      '023c0203-0000-4000-8000-000000000001','023c0213-0000-4000-8000-000000000001','023c0223-0000-4000-8000-000000000001',
      '023c0303-0000-4000-8000-000000000001','023c0313-0000-4000-8000-000000000001',
      '023c0403-0000-4000-8000-000000000001','023c0413-0000-4000-8000-000000000001',
      '023c0503-0000-4000-8000-000000000001','023c0513-0000-4000-8000-000000000001',
      '023c0603-0000-4000-8000-000000000001','023c0613-0000-4000-8000-000000000001','023c0623-0000-4000-8000-000000000001',
      '023c0703-0000-4000-8000-000000000001','023c0713-0000-4000-8000-000000000001',
      '023c0783-0000-4000-8000-000000000001','023c0793-0000-4000-8000-000000000001'))=18
      as imports_exact,
    (select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id in (
      '023c0201-0000-4000-8000-000000000001','023c0301-0000-4000-8000-000000000001',
      '023c0401-0000-4000-8000-000000000001','023c0501-0000-4000-8000-000000000001',
      '023c0601-0000-4000-8000-000000000001','023c0701-0000-4000-8000-000000000001',
      '023c0781-0000-4000-8000-000000000001'))=7 as cp20_exact,
    (select count(*) from s2t_fhir.review_session where session_name in (
      'T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT','T023-CONC-PACK-20261009-R1-C05-V1-REVIEW',
      'T023-CONC-PACK-20261009-R1-C05-V2-REVIEW','T023-CONC-PACK-20261009-R1-C06-V1-REVIEW',
      'T023-CONC-PACK-20261009-R1-C06-V2-REVIEW'))=0 as later_sessions_absent,
    (select count(*) from s2t_governance.governance_question
      where title='T023-CONC-PACK-20261009-R1-C04-QUESTION')=0 as cp21_question_absent,
    (select count(*) from s2t_fhir.validation_run where validation_run_id in (
      '023c0508-0000-4000-8000-000000000001','023c0518-0000-4000-8000-000000000001',
      '023c0608-0000-4000-8000-000000000001','023c0618-0000-4000-8000-000000000001'))=0
      as later_validations_absent,
    (select count(*) from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id in (
      '023c0509-0000-4000-8000-000000000001','023c0519-0000-4000-8000-000000000001',
      '023c0609-0000-4000-8000-000000000001','023c0619-0000-4000-8000-000000000001'))=0
      as later_gates_absent,
    (select count(*) from s2t_fhir.mapping_review_event where baseline_version_id in (
      '023c0301-0000-4000-8000-000000000001','023c0501-0000-4000-8000-000000000001',
      '023c0511-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001',
      '023c0611-0000-4000-8000-000000000001'))=0 as later_review_events_absent,
    (select count(*) from s2t_fhir.baseline_activation_context where baseline_version_id in (
      '023c0501-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001'))=0
      as later_activations_absent,
    (select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id in (
      '023c0511-0000-4000-8000-000000000001','023c0611-0000-4000-8000-000000000001'))=0
      as later_candidates_absent
),
checks(check_no,check_name,result,detail) as (
  select 1,'three target signatures exist',
    case when count(*) filter(where oid is not null)=3 then 'PASS' else 'FAIL' end,
    format('%s/3 present',count(*) filter(where oid is not null)) from target_state
  union all
  select 2,'target metadata is exact',
    case when bool_and(owner_name='s2t_fhir_owner' and prosecdef
      and provolatile='v' and proconfig is not distinct from array['search_path=""']
      and actual_return_type=return_type) then 'PASS' else 'FAIL' end,
    'owner/security/volatility/search_path/return type' from target_state
  union all
  select 3,'exact deployed defect confirmed',
    case when bool_and(guard_count=1 and body_without_guard_md5=post024_body_md5)
      then 'PASS' else 'FAIL' end,
    string_agg(signature||':guard='||coalesce(guard_count::text,'NULL'),'; ' order by signature)
    from target_state
  union all
  select 4,'private core ACL is owner-only',
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
  select 5,'historical importer guard unchanged',
    case when p.oid is not null and owner.rolname='s2t_fhir_owner' and p.prosecdef
      and p.provolatile='s'
      and p.proconfig is not distinct from array['search_path=pg_catalog, s2t_fhir_api']
      and pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g'))='fbd414965d0705cdcc0c1a5802c5a415'
      then 'PASS' else 'FAIL' end,
    's2t_fhir_api._assert_review_actor(uuid) importer-only fingerprint'
    from (select pg_catalog.to_regprocedure('s2t_fhir_api._assert_review_actor(uuid)') oid) x
    left join pg_catalog.pg_proc p on p.oid=x.oid
    left join pg_catalog.pg_roles owner on owner.oid=p.proowner
  union all
  select 6,'authenticated authorization dependencies unchanged',
    case when
      (select pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g'))
       from pg_catalog.pg_proc p where p.oid=pg_catalog.to_regprocedure(
         's2t_fhir_api._require_authenticated_review_principal()'))='25fe6d45595b4e6d6cef5dd74e50643c'
      and
      (select pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g'))
       from pg_catalog.pg_proc p where p.oid=pg_catalog.to_regprocedure(
         's2t_fhir_api._resolve_authenticated_principal()'))='0fb059ee81137fac7b3c9ce6572f99c1'
      then 'PASS' else 'FAIL' end,
    '_require_authenticated_review_principal and JWT resolver fingerprints'
  union all
  select 7,'five authenticated wrappers unchanged',
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
  select 8,'wrapper ACL boundary exact',
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
    'only owner and authenticated have EXECUTE; PUBLIC/client/import roles denied'
    from (select 1) seed
  union all
  select 9,'private core caller inventory exact',
    case when not exists(select * from expected_callers except select * from actual_callers)
      and not exists(select * from actual_callers except select * from expected_callers)
      then 'PASS' else 'FAIL' end,
    format('expected=%s actual=%s',(select count(*) from expected_callers),(select count(*) from actual_callers))
  union all
  select 10,'retained fixture recovery state',
    case when workers_exact and capabilities_exact and series_exact and registry_exact and baselines_exact
      and artifacts_exact and imports_exact and cp20_exact and later_sessions_absent
      and cp21_question_absent and later_validations_absent and later_gates_absent
      and later_review_events_absent and later_activations_absent
      and later_candidates_absent then 'PASS' else 'FAIL' end,
    case when workers_exact and capabilities_exact and series_exact and registry_exact and baselines_exact
      and artifacts_exact and imports_exact and cp20_exact and later_sessions_absent
      and cp21_question_absent and later_validations_absent and later_gates_absent
      and later_review_events_absent and later_activations_absent
      and later_candidates_absent
      then 'last_completed_checkpoint=CP20; exact_next_checkpoint=CP21'
      else 'fixture is not the exact retained CP20/CP21 recovery state' end
    from fixture_state
),
output_rows as (
  select check_no,check_name,result,detail from checks
  union all
  select 999,'PREFLIGHT SUMMARY',
    case when count(*) filter(where result<>'PASS')=0 then 'PASS' else 'FAIL' end,
    format('%s/%s checks passed',count(*) filter(where result='PASS'),count(*))
  from checks
)
select check_no,check_name,result,detail
from output_rows
order by check_no;

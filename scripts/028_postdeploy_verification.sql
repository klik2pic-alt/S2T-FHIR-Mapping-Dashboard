-- Migration 028 read-only postdeployment verification.
-- Read-only semantic probes plus SELECT output. Any FAIL is a deployment hard stop.

do $link_shape_semantic_probe$
declare
  v_count integer;
  v_expression text;
  v_semantics_exact boolean;
  v_failures text;
begin
  select count(*) into v_count
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.candidate_import_request'::pg_catalog.regclass
    and c.conname='candidate_import_request_link_shape_ck';
  if v_count <> 1 then
    raise exception '028 postdeploy: expected exactly one candidate_import_request_link_shape_ck, found %',
      v_count using errcode='55000';
  end if;

  select case when c.contype='c' and c.convalidated
                   and not c.condeferrable and not c.condeferred
              then pg_catalog.pg_get_expr(c.conbin,c.conrelid) end
    into strict v_expression
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.candidate_import_request'::pg_catalog.regclass
    and c.conname='candidate_import_request_link_shape_ck';
  if v_expression is null then
    raise exception '028 postdeploy: candidate_import_request_link_shape_ck metadata drifted'
      using errcode='55000';
  end if;

  execute pg_catalog.format($probe_sql$
    with probe(
      probe_name,current_state,artifact_id,baseline_version_id,import_run_id,
      validation_run_id,published_candidate_lifecycle_event_id,
      validation_attempt_id,validation_lease_expires_at,expected
    ) as (values
      ('UPLOADED valid','UPLOADED'::text,'00000000-0000-0000-0000-000000000001'::uuid,
       null::uuid,null::uuid,null::uuid,null::uuid,null::uuid,null::timestamptz,true),
      ('UPLOADED missing artifact','UPLOADED',null,null,null,null,null,null,null,false),
      ('UPLOADED attempt forbidden','UPLOADED','00000000-0000-0000-0000-000000000001',
       null,null,null,null,'00000000-0000-0000-0000-000000000006',null,false),
      ('UPLOADED lease forbidden','UPLOADED','00000000-0000-0000-0000-000000000001',
       null,null,null,null,null,'2100-01-01 00:00:00+00',false),
      ('VALIDATING valid','VALIDATING','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,'00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',true),
      ('VALIDATING valid without lease','VALIDATING','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,null,null,true),
      ('VALIDATING missing artifact','VALIDATING',null,
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,null,null,false),
      ('VALIDATING missing baseline','VALIDATING','00000000-0000-0000-0000-000000000001',
       null,'00000000-0000-0000-0000-000000000003',null,null,null,null,false),
      ('VALIDATING missing import','VALIDATING','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002',null,null,null,null,null,false),
      ('READY valid','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,true),
      ('READY missing artifact','READY_TO_PUBLISH',null,
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('READY missing baseline','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       null,'00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('READY missing import','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002',null,
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('READY missing validation','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,null,null,null,false),
      ('READY attempt forbidden','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,
       '00000000-0000-0000-0000-000000000006',null,false),
      ('READY lease forbidden','READY_TO_PUBLISH','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,
       null,'2100-01-01 00:00:00+00',false),
      ('PUBLISHED valid','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,true),
      ('PUBLISHED missing artifact','PUBLISHED',null,
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,false),
      ('PUBLISHED missing baseline','PUBLISHED','00000000-0000-0000-0000-000000000001',
       null,'00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,false),
      ('PUBLISHED missing import','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002',null,
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,null,false),
      ('PUBLISHED missing validation','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       null,'00000000-0000-0000-0000-000000000005',null,null,false),
      ('PUBLISHED missing lifecycle','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004',null,null,null,false),
      ('PUBLISHED attempt forbidden','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       '00000000-0000-0000-0000-000000000006',null,false),
      ('PUBLISHED lease forbidden','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,'2100-01-01 00:00:00+00',false),
      ('AWAITING lease pair forbidden','AWAITING_UPLOAD',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false),
      ('VALIDATION_FAILED lease pair forbidden','VALIDATION_FAILED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false),
      ('FAILED without validation lease valid','FAILED',null,null,null,null,null,null,null,true),
      ('FAILED attempt forbidden','FAILED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006',null,false),
      ('FAILED lease forbidden','FAILED',null,null,null,null,null,
       null,'2100-01-01 00:00:00+00',false),
      ('ABORTED lease pair forbidden','ABORTED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false)
    )
    select bool_and((%s) is not distinct from expected),
           pg_catalog.string_agg(probe_name,', ' order by probe_name)
             filter (where (%s) is distinct from expected)
    from probe
  $probe_sql$,v_expression,v_expression)
  into v_semantics_exact,v_failures;

  if not coalesce(v_semantics_exact,false) then
    raise exception '028 postdeploy: link-shape semantic probes failed: %',
      coalesce(v_failures,'unknown probe failure') using errcode='55000';
  end if;
end
$link_shape_semantic_probe$;

with
helper as (
  select p.oid,p.prosrc,p.proacl,p.proowner,p.prosecdef,p.provolatile,p.prokind,
         p.proconfig,owner.rolname owner_name,
         pg_catalog.pg_get_function_result(p.oid) result_type
  from pg_catalog.pg_proc p
  join pg_catalog.pg_roles owner on owner.oid=p.proowner
  where p.oid=pg_catalog.to_regprocedure(
    's2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)')
),
related(signature,oid,prosrc,definition_md5) as (
  select e.signature,p.oid,p.prosrc,
         pg_catalog.md5(coalesce(pg_catalog.pg_get_functiondef(p.oid),''))
  from (values
    ('s2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb)'),
    ('s2t_fhir.validate_candidate_import_request()'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
    ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)'),
    ('s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')
  ) e(signature)
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
),
request_fingerprint as (
  select count(*) row_count,
         coalesce(pg_catalog.md5(pg_catalog.string_agg(
           r.candidate_import_request_id::text||'|'||r.current_state||'|'||
           coalesce(r.baseline_version_id::text,'')||'|'||coalesce(r.import_run_id::text,'')||'|'||
           coalesce(r.validation_run_id::text,'')||'|'||
           coalesce(r.published_candidate_lifecycle_event_id::text,'')||'|'||
           coalesce(r.validation_attempt_id::text,'')||'|'||
           coalesce(r.validation_lease_expires_at::text,''), E'\n'
           order by r.candidate_import_request_id)),pg_catalog.md5('')) state_md5
  from s2t_fhir.candidate_import_request r
),
checks(check_no,check_name,result,detail) as (
  select 1,'validation-start helper metadata exact',
    case when count(*)=1 and bool_and(owner_name='s2t_fhir_owner' and prosecdef
      and provolatile='v' and prokind='f'
      and proconfig is not distinct from array['search_path=""']
      and result_type='jsonb') then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 exact',count(*) filter (where owner_name='s2t_fhir_owner'
      and prosecdef and provolatile='v' and prokind='f'
      and proconfig is not distinct from array['search_path=""'] and result_type='jsonb'))
  from helper
  union all
  select 2,'initial validation state and links update atomically',
    case when prosrc like '%''VALIDATION_STARTED'',%'
      and prosrc like '%set current_state = ''VALIDATING'',%'
      and prosrc like '%baseline_version_id = v_baseline_id,%'
      and prosrc like '%import_run_id = v_import_id,%'
      and prosrc like '%validation_attempt_id = p_validation_attempt_id,%'
      and prosrc like '%validation_lease_expires_at = p_lease_expires_at,%'
      and prosrc like '%and r.current_state = ''UPLOADED'';%'
      then 'PASS' else 'FAIL' end,
    'one constraint-valid UPDATE writes VALIDATING plus baseline/import/attempt/lease'
  from helper
  union all
  select 3,'initial path appends one event without a second transition call',
    case when (select count(*) from pg_catalog.regexp_matches(
      prosrc,'s2t_fhir\._transition_candidate_import_request','g'))=1
      and prosrc like '%insert into s2t_fhir.candidate_import_request_event (%'
      and prosrc like '%''VALIDATION_STARTED'',%'
      and prosrc like '%''UPLOADED'', ''VALIDATING''%'
      then 'PASS' else 'FAIL' end,
    'single remaining transition-helper call is the VALIDATION_RECLAIMED path'
  from helper
  union all
  select 4,'replay reclaim and lease fencing retained',
    case when prosrc like '%v_request.validation_attempt_id = p_validation_attempt_id%'
      and prosrc like '%''idempotentReplay'', true%'
      and prosrc like '%validation_lease_expires_at >= pg_catalog.transaction_timestamp()%'
      and prosrc like '%another validation attempt owns the active lease%'
      and prosrc like '%VALIDATION_RECLAIMED%'
      and prosrc like '%''reclaimed'', true%'
      then 'PASS' else 'FAIL' end,
    'same-attempt replay, active-lease conflict, expired-lease reclaim'
  from helper
  union all
  select 5,'link-shape constraint remains strong and immediate',
    case when count(*)=1 and bool_and(c.contype='c' and c.convalidated
      and not c.condeferrable and not c.condeferred)
      then 'PASS' else 'FAIL' end,
    case when count(*)=1 then
      'exact validated immediate CHECK; semantic truth-table probes passed'
      else pg_catalog.format('matching constraints=%s',count(*)) end
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.candidate_import_request'::pg_catalog.regclass
    and c.conname='candidate_import_request_link_shape_ck'
  union all
  select 6,'request validation trigger remains exact',
    case when count(*)=1 and bool_and(t.tgenabled='O' and not t.tgisinternal
      and t.tgfoid=pg_catalog.to_regprocedure('s2t_fhir.validate_candidate_import_request()'))
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 exact',count(*))
  from pg_catalog.pg_trigger t
  where t.tgrelid='s2t_fhir.candidate_import_request'::pg_catalog.regclass
    and t.tgname='candidate_import_request_validate_trg'
  union all
  select 7,'validation-start helper ACL remains narrow',
    case when not pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',oid,'EXECUTE')
      and pg_catalog.has_function_privilege('service_role',oid,'EXECUTE')
      and pg_catalog.has_function_privilege('s2t_fhir_importer',oid,'EXECUTE')
      and not exists (
        select 1 from pg_catalog.aclexplode(coalesce(proacl,
          pg_catalog.acldefault('f',proowner))) acl
        where acl.privilege_type='EXECUTE' and acl.grantee not in (
          proowner,
          (select oid from pg_catalog.pg_roles where rolname='service_role'),
          (select oid from pg_catalog.pg_roles where rolname='s2t_fhir_importer')))
      then 'PASS' else 'FAIL' end,
    'owner + service_role + s2t_fhir_importer; browser roles denied'
  from helper
  union all
  select 8,'completion publication and failure paths remain structurally valid',
    case when count(*)=3 and bool_and(oid is not null) and
      (select prosrc like '%set validation_run_id = v_validation_id%'
              and prosrc like '%VALIDATING'', ''READY_TO_PUBLISH''%'
              and prosrc like '%VALIDATING'', ''VALIDATION_FAILED''%'
       from related where signature like '%_service_complete%') and
      (select prosrc like '%set published_candidate_lifecycle_event_id =%'
              and prosrc like '%''READY_TO_PUBLISH'', ''PUBLISHED''%'
       from related where signature like '%publish_candidate_import%') and
      (select prosrc like '%set last_error_reference = p_error_reference%'
              and prosrc like '%perform s2t_fhir._transition_candidate_import_request(%'
       from related where signature like '%_service_fail%')
      then 'PASS' else 'FAIL' end,
    'link writes remain legal in their pre-transition states and transitions clear leases'
  from related where signature like 's2t_fhir_api.%'
  union all
  select 9,'related function fingerprints captured','PASS',
    pg_catalog.string_agg(signature||'='||definition_md5,'; ' order by signature)
  from related
  union all
  select 10,'Candidate-import request data fingerprint captured','PASS',
    pg_catalog.format('rows=%s state_md5=%s; compare exactly with preflight output',
      row_count,state_md5)
  from request_fingerprint
)
select check_no,check_name,result,detail from checks
union all
select 999,'overall postdeploy result',
  case when bool_and(result='PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',count(*) filter (where result='PASS'),count(*))
from checks
order by check_no;

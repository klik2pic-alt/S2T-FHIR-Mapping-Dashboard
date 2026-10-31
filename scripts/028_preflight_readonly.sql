-- Migration 028 read-only preflight.
-- Run after accepted Migration 027 and before Migration 028.
-- Read-only semantic probes plus SELECT output: no DDL, DML, temporary objects,
-- persistent data changes, or session mutation.

do $link_shape_semantic_probe$
declare
  v_count integer;
  v_constraint_oid oid;
  v_expression text;
  v_semantics_exact boolean;
  v_failures text;
begin
  select count(*) into v_count
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.candidate_import_request'::pg_catalog.regclass
    and c.conname='candidate_import_request_link_shape_ck';
  if v_count <> 1 then
    raise exception '028 preflight: expected exactly one candidate_import_request_link_shape_ck, found %',
      v_count using errcode='55000';
  end if;

  select c.oid,pg_catalog.pg_get_expr(c.conbin,c.conrelid)
    into strict v_constraint_oid,v_expression
  from pg_catalog.pg_constraint c
  where c.conrelid='s2t_fhir.candidate_import_request'::pg_catalog.regclass
    and c.conname='candidate_import_request_link_shape_ck'
    and c.contype='c' and c.convalidated
    and not c.condeferrable and not c.condeferred;

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
      ('PUBLISHED lease forbidden','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       null,'2100-01-01 00:00:00+00',false),
      ('PUBLISHED attempt forbidden','PUBLISHED','00000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005',
       '00000000-0000-0000-0000-000000000006',null,false),
      ('AWAITING lease pair forbidden','AWAITING_UPLOAD',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false),
      ('VALIDATION_FAILED lease pair forbidden','VALIDATION_FAILED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false),
      ('ABORTED lease pair forbidden','ABORTED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006','2100-01-01 00:00:00+00',false),
      ('FAILED without validation lease valid','FAILED',null,null,null,null,null,null,null,true),
      ('FAILED attempt forbidden','FAILED',null,null,null,null,null,
       '00000000-0000-0000-0000-000000000006',null,false),
      ('FAILED lease forbidden','FAILED',null,null,null,null,null,
       null,'2100-01-01 00:00:00+00',false)
    )
    select bool_and((%s) is not distinct from expected),
           pg_catalog.string_agg(probe_name,', ' order by probe_name)
             filter (where (%s) is distinct from expected)
    from probe
  $probe_sql$,v_expression,v_expression)
  into v_semantics_exact,v_failures;

  if not coalesce(v_semantics_exact,false) then
    raise exception '028 preflight: link-shape semantic probes failed: %',
      coalesce(v_failures,'unknown probe failure') using errcode='55000';
  end if;
end
$link_shape_semantic_probe$;

with
expected(signature,expected_result) as (
  values
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)','jsonb'),
    ('s2t_fhir._transition_candidate_import_request(uuid,text,text,text,uuid,uuid,uuid,text,text,text,integer,jsonb)','jsonb'),
    ('s2t_fhir.validate_candidate_import_request()','trigger')
),
function_state as (
  select e.signature,e.expected_result,p.oid,p.prosrc,p.proacl,p.proowner,
         owner.rolname owner_name,p.prosecdef,p.provolatile,p.prokind,p.proconfig,
         pg_catalog.pg_get_function_result(p.oid) result_type,
         pg_catalog.md5(coalesce(pg_catalog.pg_get_functiondef(p.oid),'')) definition_md5
  from expected e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
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
  select 1,'required function signatures and metadata exact',
    case when count(*)=3 and bool_and(oid is not null and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile='v' and prokind='f'
      and proconfig is not distinct from array['search_path=""']
      and result_type=expected_result) then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/3 metadata exact',count(*) filter (where oid is not null
      and owner_name='s2t_fhir_owner' and prosecdef and provolatile='v' and prokind='f'
      and proconfig is not distinct from array['search_path=""']
      and result_type=expected_result))
  from function_state
  union all
  select 2,'Migration 026 validation-start defect shape is present',
    case when prosrc like '%set baseline_version_id = v_baseline_id,%'
      and prosrc like '%validation_lease_expires_at = p_lease_expires_at%'
      and prosrc like '%p_request_id, ''UPLOADED'', ''VALIDATING'', ''VALIDATION_STARTED''%'
      and (select count(*) from pg_catalog.regexp_matches(
        prosrc,'s2t_fhir\._transition_candidate_import_request','g'))=2
      then 'PASS' else 'FAIL' end,
    'separate link UPDATE precedes UPLOADED -> VALIDATING transition'
  from function_state where signature like 's2t_fhir_api._service_begin%'
  union all
  select 3,'link-shape constraint remains strong and immediate',
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
  select 4,'request validation trigger exact',
    case when count(*)=1 and bool_and(t.tgenabled='O' and not t.tgisinternal
      and t.tgfoid=pg_catalog.to_regprocedure('s2t_fhir.validate_candidate_import_request()'))
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/1 exact',count(*))
  from pg_catalog.pg_trigger t
  where t.tgrelid='s2t_fhir.candidate_import_request'::pg_catalog.regclass
    and t.tgname='candidate_import_request_validate_trg'
  union all
  select 5,'validation-start helper ACL remains narrow',
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
  from function_state where signature like 's2t_fhir_api._service_begin%'
  union all
  select 6,'related-path source fingerprints captured','PASS',
    pg_catalog.string_agg(signature||'='||definition_md5,'; ' order by signature)
  from function_state
  union all
  select 7,'Candidate-import request data fingerprint captured','PASS',
    pg_catalog.format('rows=%s state_md5=%s',row_count,state_md5)
  from request_fingerprint
)
select check_no,check_name,result,detail from checks
union all
select 999,'overall preflight result',
  case when bool_and(result='PASS') then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',count(*) filter (where result='PASS'),count(*))
from checks
order by check_no;

-- Migration 025 read-only postdeployment verification.
-- SELECT statements only. Any FAIL is a deployment hard stop.

with
client_roles(role_name) as (
  values ('anon'),('service_role'),('s2t_fhir_importer'),
         ('s2t_fhir_api_reader'),('s2t_fhir_governance_reader')
),
public_expected(signature,volatility) as (
  values
    ('s2t_fhir_api.get_candidate_ui_context(text)','s'),
    ('s2t_fhir_api.get_candidate_promotion_readiness(text,uuid,uuid,uuid,uuid,timestamp with time zone)','v'),
    ('s2t_fhir_api.get_my_candidate_ui_capabilities()','s'),
    ('s2t_fhir_api.get_my_candidate_review_session(uuid,uuid)','s')
),
public_state as (
  select e.*,p.oid,p.proowner,p.proacl,p.prosecdef,p.provolatile,p.proconfig,
         p.proargnames,p.prosrc,owner.rolname owner_name,
         pg_catalog.pg_get_function_result(p.oid) result_type
  from public_expected e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
private_expected(signature,volatility) as (
  values
    ('s2t_fhir_api._candidate_ui_capability_state(uuid)','s'),
    ('s2t_fhir_api._candidate_ui_snapshot(text)','s'),
    ('s2t_fhir._evaluate_candidate_promotion_readiness(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone,boolean,boolean)','v'),
    ('s2t_fhir._raise_candidate_promotion_evaluation(jsonb)','v'),
    ('s2t_fhir.assert_candidate_activation_eligibility(uuid,uuid,uuid,uuid,timestamp with time zone)','v'),
    ('s2t_fhir.validate_baseline_activation_context()','v')
),
private_state as (
  select e.*,p.oid,p.proowner,p.proacl,p.prosecdef,p.provolatile,p.proconfig,
         p.prosrc,owner.rolname owner_name
  from private_expected e
  left join pg_catalog.pg_proc p on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
view_columns as (
  select pg_catalog.array_agg(a.attname::text order by a.attnum) columns,
         pg_catalog.array_agg(pg_catalog.format_type(a.atttypid,a.atttypmod)
                              order by a.attnum) types
  from pg_catalog.pg_attribute a
  where a.attrelid=pg_catalog.to_regclass('s2t_fhir_api.governance_mapping_links')
    and a.attnum>0 and not a.attisdropped
),
checks(check_no,check_name,result,detail) as (
  select 1,'four public RPC definitions exact',
    case when count(*)=4 and bool_and(oid is not null
      and result_type='jsonb' and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile=volatility
      and proconfig is not distinct from array['search_path=""'])
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/4 exact',count(*) filter(where oid is not null
      and result_type='jsonb' and owner_name='s2t_fhir_owner'
      and prosecdef and provolatile=volatility
      and proconfig is not distinct from array['search_path=""']))
    from public_state
  union all
  select 2,'public RPC arguments contain no actor/principal ID',
    case when not exists (
      select 1 from public_state s
      cross join lateral pg_catalog.unnest(coalesce(s.proargnames,array[]::text[])) n
      where n~*'(actor|principal)'
    ) then 'PASS' else 'FAIL' end,
    'caller identity is resolved internally' from (select 1) seed
  union all
  select 3,'public RPC ACL exact',
    case when not exists (
      select 1 from public_state p
      where p.oid is null
         or not pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
    ) and not exists (
      select 1 from public_state p cross join client_roles r
      where pg_catalog.has_function_privilege(r.role_name,p.oid,'EXECUTE')
    ) and not exists (
      select 1 from public_state p
      cross join lateral pg_catalog.aclexplode(coalesce(
        p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
      where acl.privilege_type='EXECUTE'
        and acl.grantee not in (
          p.proowner,
          (select oid from pg_catalog.pg_roles where rolname='authenticated')
        )
    ) then 'PASS' else 'FAIL' end,
    'owner + authenticated only' from (select 1) seed
  union all
  select 4,'private helper metadata exact',
    case when count(*)=6 and bool_and(oid is not null
      and owner_name='s2t_fhir_owner' and prosecdef
      and provolatile=volatility
      and proconfig is not distinct from array['search_path=""'])
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/6 metadata exact',count(*) filter(where oid is not null
      and owner_name='s2t_fhir_owner' and prosecdef
      and provolatile=volatility
      and proconfig is not distinct from array['search_path=""']))
    from private_state
  union all
  select 5,'private helper ACL owner-only',
    case when not exists (
      select 1 from private_state p
      cross join (values('authenticated'),('anon'),('service_role'),
                        ('s2t_fhir_importer'),('s2t_fhir_api_reader'),
                        ('s2t_fhir_governance_reader')) r(role_name)
      where p.oid is null
         or pg_catalog.has_function_privilege(r.role_name,p.oid,'EXECUTE')
    ) and not exists (
      select 1 from private_state p
      cross join lateral pg_catalog.aclexplode(coalesce(
        p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
      where acl.privilege_type='EXECUTE' and acl.grantee<>p.proowner
    ) then 'PASS' else 'FAIL' end,
    'all browser/import/service roles denied' from (select 1) seed
  union all
  select 6,'Promotion public signature unchanged',
    case when count(*)=1
      and min(pg_catalog.pg_get_function_result(p.oid))='jsonb'
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('overloads=%s',count(*))
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='s2t_fhir_api' and p.proname='promote_candidate_baseline'
  union all
  select 7,'Promotion trigger uses shared evaluator after locks',
    case when pg_catalog.strpos(p.prosrc,
        's2t_fhir._evaluate_candidate_promotion_readiness(')>0
      and pg_catalog.strpos(p.prosrc,'for update')>0
      and pg_catalog.strpos(p.prosrc,
        's2t_fhir._evaluate_candidate_promotion_readiness(')>
          pg_catalog.strpos(p.prosrc,'for update')
      then 'PASS' else 'FAIL' end,
    'shared evaluator call follows preserved FOR UPDATE sequence'
    from pg_catalog.pg_proc p
    where p.oid=pg_catalog.to_regprocedure(
      's2t_fhir.validate_baseline_activation_context()')
  union all
  select 8,'legacy assertion delegates to shared evaluator',
    case when pg_catalog.strpos(p.prosrc,
      's2t_fhir._evaluate_candidate_promotion_readiness(')>0
      then 'PASS' else 'FAIL' end,
    'five-argument private signature retained'
    from pg_catalog.pg_proc p
    where p.oid=pg_catalog.to_regprocedure(
      's2t_fhir.assert_candidate_activation_eligibility(uuid,uuid,uuid,uuid,timestamp with time zone)')
  union all
  select 9,'governance view append-only column shape',
    case when columns is not distinct from array[
      'link_id','question_id','resource_config_id','baseline_code','node_id',
      'mapping_kind','fhir_resource_type','version_label','target_element',
      'element_path','profile_label','decision_status_at_link','source_sheet',
      'source_row','source_cell_range','artifact_sha256','linked_by_principal',
      'recorded_at','is_active','baseline_version_id',
      'review_target_lifecycle_event_id','lifecycle_status_at_link']::text[]
      then 'PASS' else 'FAIL' end,
    coalesce(columns::text,'ABSENT') from view_columns
  union all
  select 10,'governance full column types exact',
    case when types is not distinct from array[
      'uuid','uuid','text','text','text','text','text','text','text','text[]',
      'text','text','text','integer','text','text','uuid',
      'timestamp with time zone','boolean','uuid','uuid','text']::text[]
      then 'PASS' else 'FAIL' end,
    coalesce(types::text,'ABSENT') from view_columns
  union all
  select 11,'governance authorization and ACL preserved',
    case when pg_catalog.pg_get_viewdef(
        's2t_fhir_api.governance_mapping_links'::regclass,true)
          like '%_governance_read_allowed()%'
      and pg_catalog.has_table_privilege('authenticated',
        's2t_fhir_api.governance_mapping_links','SELECT')
      and not pg_catalog.has_table_privilege('anon',
        's2t_fhir_api.governance_mapping_links','SELECT')
      and not exists (
        select 1
        from pg_catalog.pg_class c
        cross join lateral pg_catalog.aclexplode(coalesce(
          c.relacl,pg_catalog.acldefault('r',c.relowner))) acl
        where c.oid=pg_catalog.to_regclass(
          's2t_fhir_api.governance_mapping_links')
          and acl.grantee=0 and acl.privilege_type='SELECT'
      )
      then 'PASS' else 'FAIL' end,
    'existing helper + authenticated SELECT only'
  union all
  select 12,'private relations have no client SELECT',
    case when not exists (
      select 1 from (values
        ('s2t_fhir.baseline_candidate_context'),
        ('s2t_fhir.baseline_activation_context'),
        ('s2t_fhir.candidate_review_session_state'),
        ('s2t_fhir.review_actor_authorization'),
        ('s2t_fhir.baseline_action_authorization'),
        ('s2t_governance.governance_mapping_link')
      ) x(relation_name)
      cross join (values('authenticated'),('anon')) r(role_name)
      where pg_catalog.has_table_privilege(r.role_name,x.relation_name,'SELECT')
    ) then 'PASS' else 'FAIL' end,
    'authenticated and anon denied' from (select 1) seed
)
select check_no,check_name,result,detail
from checks
union all
select 999,'overall postdeploy result',
  case when bool_and(result='PASS')
    then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',
    count(*) filter (where result='PASS'),count(*))
from checks
order by check_no;

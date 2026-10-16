-- Migration 025 read-only preflight.
-- Run after accepted Migration 024 and before Migration 025.
-- SELECT statements only: no DDL, DML, temporary objects, or session mutation.

with
accepted_functions(signature,body_md5) as (
  values
    ('s2t_fhir.assert_candidate_activation_eligibility(uuid,uuid,uuid,uuid,timestamp with time zone)',
     'b72c63712005f45e443dae17cfbdad09'),
    ('s2t_fhir.validate_baseline_activation_context()',
     'c3adf758b7385c53a3d44cb005ad45bb')
),
accepted_state as (
  select e.signature,e.body_md5,p.oid,p.prosrc,p.prosecdef,p.provolatile,
         p.proconfig,p.proacl,p.proowner,owner.rolname owner_name,
         pg_catalog.md5(pg_catalog.regexp_replace(p.prosrc,'\s+',' ','g')) actual_md5
  from accepted_functions e
  left join pg_catalog.pg_proc p
    on p.oid=pg_catalog.to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner on owner.oid=p.proowner
),
required_signatures(signature) as (
  values
    ('s2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone,text)'),
    ('s2t_fhir.promote_current_candidate(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone,text,uuid,uuid)'),
    ('s2t_fhir._require_current_candidate_context(uuid,uuid)'),
    ('s2t_fhir._lock_current_candidate_context(uuid,uuid)'),
    ('s2t_fhir.assert_release_gate_evaluation_integrity(uuid)'),
    ('s2t_fhir_api._resolve_authenticated_principal()'),
    ('s2t_fhir_api._require_authenticated_review_principal()')
),
new_signatures(signature) as (
  values
    ('s2t_fhir_api._candidate_ui_capability_state(uuid)'),
    ('s2t_fhir_api._candidate_ui_snapshot(text)'),
    ('s2t_fhir._evaluate_candidate_promotion_readiness(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone,boolean,boolean)'),
    ('s2t_fhir._raise_candidate_promotion_evaluation(jsonb)'),
    ('s2t_fhir_api.get_candidate_ui_context(text)'),
    ('s2t_fhir_api.get_candidate_promotion_readiness(text,uuid,uuid,uuid,uuid,timestamp with time zone)'),
    ('s2t_fhir_api.get_my_candidate_ui_capabilities()'),
    ('s2t_fhir_api.get_my_candidate_review_session(uuid,uuid)')
),
governance_columns as (
  select pg_catalog.array_agg(a.attname::text order by a.attnum) columns,
         pg_catalog.array_agg(
           pg_catalog.format_type(a.atttypid,a.atttypmod)
           order by a.attnum
         ) types
  from pg_catalog.pg_attribute a
  where a.attrelid=pg_catalog.to_regclass('s2t_fhir_api.governance_mapping_links')
    and a.attnum>0 and not a.attisdropped
),
checks(check_no,check_name,result,detail) as (
  select 1,'accepted Promotion definitions exact',
    case when count(*)=2 and bool_and(oid is not null and actual_md5=body_md5
      and owner_name='s2t_fhir_owner' and prosecdef and provolatile='v'
      and proconfig is not distinct from array['search_path=""'])
      then 'PASS' else 'FAIL' end,
    pg_catalog.string_agg(signature||':expected='||body_md5||':actual='||
      coalesce(actual_md5,'ABSENT'),'; ' order by signature)
    from accepted_state
  union all
  select 2,'required 023/024 dependencies exist',
    case when count(*) filter(where pg_catalog.to_regprocedure(signature) is not null)=count(*)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/%s present',
      count(*) filter(where pg_catalog.to_regprocedure(signature) is not null),count(*))
    from required_signatures
  union all
  select 3,'Migration 025 function namespace is unused',
    case when count(*) filter(where pg_catalog.to_regprocedure(signature) is not null)=0
      then 'PASS' else 'FAIL' end,
    coalesce(pg_catalog.string_agg(signature,', ') filter(
      where pg_catalog.to_regprocedure(signature) is not null),'none present')
    from new_signatures
  union all
  select 4,'governance view original shape exact',
    case when columns is not distinct from array[
      'link_id','question_id','resource_config_id','baseline_code','node_id',
      'mapping_kind','fhir_resource_type','version_label','target_element',
      'element_path','profile_label','decision_status_at_link','source_sheet',
      'source_row','source_cell_range','artifact_sha256','linked_by_principal',
      'recorded_at','is_active']::text[] then 'PASS' else 'FAIL' end,
    coalesce(columns::text,'ABSENT') from governance_columns
  union all
  select 5,'governance provenance source columns exact',
    case when count(*)=3 and bool_and(
      case a.attname
        when 'baseline_version_id' then a.atttypid='uuid'::regtype
        when 'review_target_lifecycle_event_id' then a.atttypid='uuid'::regtype
        when 'lifecycle_status_at_link' then a.atttypid='text'::regtype
        else false
      end)
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('%s/3 columns present',count(*))
    from pg_catalog.pg_attribute a
    where a.attrelid=pg_catalog.to_regclass('s2t_governance.governance_mapping_link')
      and a.attname in ('baseline_version_id','review_target_lifecycle_event_id',
                        'lifecycle_status_at_link')
      and a.attnum>0 and not a.attisdropped
  union all
  select 6,'governance view ACL baseline exact',
    case when pg_catalog.has_table_privilege('authenticated',
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
    'authenticated=SELECT; anon/PUBLIC=denied'
  union all
  select 7,'private source relations remain client-inaccessible',
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
    'authenticated and anon have no direct SELECT'
  union all
  select 8,'Promotion public signature singular and unchanged',
    case when count(*)=1
      and bool_and(pg_catalog.pg_get_function_result(p.oid)='jsonb')
      then 'PASS' else 'FAIL' end,
    pg_catalog.format('matching overloads=%s',count(*))
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='s2t_fhir_api' and p.proname='promote_candidate_baseline'
  union all
  select 9,'replaced private definitions are owner-only',
    case when not exists (
      select 1 from accepted_state s
      cross join (values('authenticated'),('anon'),('service_role'),
                        ('s2t_fhir_importer'),('s2t_fhir_api_reader'),
                        ('s2t_fhir_governance_reader')) r(role_name)
      where s.oid is null
         or pg_catalog.has_function_privilege(r.role_name,s.oid,'EXECUTE')
    ) and not exists (
      select 1 from accepted_state s
      cross join lateral pg_catalog.aclexplode(coalesce(
        s.proacl,pg_catalog.acldefault('f',
          (select p.proowner from pg_catalog.pg_proc p where p.oid=s.oid)))) acl
      where acl.privilege_type='EXECUTE'
        and acl.grantee<>(select p.proowner from pg_catalog.pg_proc p where p.oid=s.oid)
    ) then 'PASS' else 'FAIL' end,
    'all browser/import/service roles denied' from (select 1) seed
  union all
  select 10,'governance view original types exact',
    case when types is not distinct from array[
      'uuid','uuid','text','text','text','text','text','text','text','text[]',
      'text','text','text','integer','text','text','uuid',
      'timestamp with time zone','boolean']::text[]
      then 'PASS' else 'FAIL' end,
    coalesce(types::text,'ABSENT') from governance_columns
)
select check_no,check_name,result,detail
from checks
union all
select 999,'overall preflight result',
  case when bool_and(result='PASS')
    then 'PASS' else 'FAIL' end,
  pg_catalog.format('%s/%s checks passed',
    count(*) filter (where result='PASS'),count(*))
from checks
order by check_no;

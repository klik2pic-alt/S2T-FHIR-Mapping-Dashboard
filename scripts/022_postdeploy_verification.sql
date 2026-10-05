-- Migration 022 controlled TEST post-deployment verification.
-- STRICTLY READ-ONLY: SELECT/catalog introspection only.
-- Compare FP rows exactly with 022_preflight_readonly.sql output.

with
expected_functions(signature) as (
  values
    ('s2t_fhir.validate_baseline_lifecycle_insert()'),
    ('s2t_fhir.assert_baseline_series_lifecycle(uuid)'),
    ('s2t_fhir.check_baseline_series_lifecycle()')
),
function_state as (
  select e.signature,
         p.oid,
         owner_role.rolname as owner_name,
         p.prosecdef,
         p.provolatile,
         coalesce(array_to_string(p.proconfig, ','), '') as config
  from expected_functions e
  left join pg_catalog.pg_proc p
    on p.oid = to_regprocedure(e.signature)
  left join pg_catalog.pg_roles owner_role
    on owner_role.oid = p.proowner
),
expected_indexes(index_name, column_name, predicate_text) as (
  values
    ('baseline_lifecycle_root_once_uq', 'baseline_version_id', 'supersedes_event_id IS NULL'),
    ('baseline_lifecycle_superseded_once_uq', 'supersedes_event_id', 'supersedes_event_id IS NOT NULL')
),
index_state as (
  select e.index_name, e.column_name, e.predicate_text,
         idx.oid, i.indrelid, i.indisunique, i.indisvalid, i.indisready,
         i.indnkeyatts, i.indnatts, am.amname as access_method,
         pg_get_indexdef(idx.oid) as index_definition,
         pg_get_expr(i.indpred, i.indrelid) as predicate_definition,
         array(
           select a.attname
           from unnest(i.indkey::smallint[]) with ordinality key(attnum, ord)
           join pg_catalog.pg_attribute a
             on a.attrelid = i.indrelid and a.attnum = key.attnum
           order by key.ord
         ) as indexed_columns
  from expected_indexes e
  left join pg_catalog.pg_class idx
    on idx.oid = to_regclass('s2t_fhir.' || e.index_name)
  left join pg_catalog.pg_index i on i.indexrelid = idx.oid
  left join pg_catalog.pg_am am on am.oid = idx.relam
),
expected_triggers(trigger_name) as (
  values
    ('baseline_lifecycle_transition_trg'),
    ('baseline_series_lifecycle_cardinality_trg')
),
trigger_state as (
  select e.trigger_name, t.oid, t.tgdeferrable, t.tginitdeferred,
         pg_get_triggerdef(t.oid, true) as trigger_definition
  from expected_triggers e
  left join pg_catalog.pg_trigger t
    on t.tgrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
   and t.tgname = e.trigger_name
   and not t.tgisinternal
),
client_roles as (
  select r.oid, r.rolname
  from pg_catalog.pg_roles r
  where r.rolname in (
    'anon', 'authenticated', 'service_role',
    's2t_fhir_importer', 's2t_fhir_api_reader',
    's2t_fhir_governance_reader'
  )
),
current_events as (
  select e.*
  from s2t_fhir.baseline_lifecycle_event e
  where not exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event successor
    where successor.supersedes_event_id = e.baseline_lifecycle_event_id
  )
),
checks(test_no, test_name, passed, detail) as (
  select 1, 'CANDIDATE reference value',
         count(*) = 1
         and bool_and(v.version_number = 1)
         and bool_and(not v.is_bootstrap_seed)
         and bool_and(v.retired_at is null)
         and bool_and(v.created_by_principal_id = migrator.principal_id),
         'matching rows=' || count(*)
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  cross join lateral (
    select p.principal_id
    from s2t_fhir.principal p
    where p.external_issuer = 'postgres-role'
      and p.external_subject = 's2t_fhir_migrator'
      and p.disabled_at is null
  ) migrator
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and not d.is_versioned
    and v.value_code = 'CANDIDATE'

  union all
  select 2, 'SUPERSEDED reference value',
         count(*) = 1
         and bool_and(v.version_number = 1)
         and bool_and(not v.is_bootstrap_seed)
         and bool_and(v.retired_at is null)
         and bool_and(v.created_by_principal_id = migrator.principal_id),
         'matching rows=' || count(*)
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  cross join lateral (
    select p.principal_id
    from s2t_fhir.principal p
    where p.external_issuer = 'postgres-role'
      and p.external_subject = 's2t_fhir_migrator'
      and p.disabled_at is null
  ) migrator
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and not d.is_versioned
    and v.value_code = 'SUPERSEDED'

  union all
  select 3, 'legacy lifecycle values unchanged',
         count(*) = 3
         and count(*) filter (where v.value_code = 'PENDING_APPROVAL') = 1
         and count(*) filter (where v.value_code = 'ACTIVE') = 1
         and count(*) filter (where v.value_code = 'RETIRED') = 1
         and bool_and(v.version_number = 1)
         and bool_and(v.is_bootstrap_seed)
         and bool_and(v.created_by_principal_id is null)
         and bool_and(v.retired_at is null),
         format('rows=%s values=%s', count(*),
           coalesce(string_agg(v.value_code, ',' order by v.value_code), '<none>'))
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and not d.is_versioned
    and v.value_code in ('PENDING_APPROVAL', 'ACTIVE', 'RETIRED')

  union all
  select 4, 'unique index definitions and predicates',
         count(*) = 2
         and bool_and(oid is not null)
         and bool_and(indrelid = 's2t_fhir.baseline_lifecycle_event'::regclass)
         and bool_and(indisunique)
         and bool_and(indisvalid and indisready)
         and bool_and(indnkeyatts = 1 and indnatts = 1)
         and bool_and(access_method = 'btree')
         and bool_and(indexed_columns::text[] = array[column_name]::text[])
         and bool_and(
           regexp_replace(predicate_definition, '[()]', '', 'g') = predicate_text
         ),
         'valid indexes=' || count(*) filter (
           where oid is not null
             and indrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
             and indisunique and indisvalid and indisready
             and indnkeyatts = 1 and indnatts = 1
             and access_method = 'btree'
             and indexed_columns::text[] = array[column_name]::text[]
             and regexp_replace(predicate_definition, '[()]', '', 'g') = predicate_text
         ) || '/2'
  from index_state

  union all
  select 5, 'function ownership/security/volatility/search_path',
         count(*) = 3
         and bool_and(oid is not null)
         and bool_and(owner_name = 's2t_fhir_owner')
         and bool_and(prosecdef)
         and bool_and(provolatile = 'v')
         and bool_and(config = 'search_path=""'),
         'valid functions=' || count(*) filter (
           where oid is not null
             and owner_name = 's2t_fhir_owner'
             and prosecdef and provolatile = 'v'
             and config = 'search_path=""'
         ) || '/3'
  from function_state

  union all
  select 6, 'no unintended function EXECUTE ACLs',
         count(*) = 0,
         'non-owner direct EXECUTE ACL entries=' || count(*)
  from function_state f
  join pg_catalog.pg_proc p on p.oid = f.oid
  cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
  where acl.privilege_type = 'EXECUTE'
    and acl.grantee <> p.proowner

  union all
  select 7, 'client/importer roles cannot EXECUTE helpers',
         count(*) filter (
           where has_function_privilege(r.oid, f.oid, 'EXECUTE')
         ) = 0,
         'effective EXECUTE grants=' || count(*) filter (
           where has_function_privilege(r.oid, f.oid, 'EXECUTE')
         )
  from function_state f
  cross join client_roles r
  where f.oid is not null

  union all
  select 8, 'transition trigger definition',
         count(*) = 1
         and bool_and(oid is not null)
         and bool_and(not tgdeferrable)
         and bool_and(not tginitdeferred)
         and bool_and(trigger_definition ~* '^CREATE TRIGGER baseline_lifecycle_transition_trg BEFORE INSERT'),
         coalesce(max(trigger_definition), '<missing>')
  from trigger_state
  where trigger_name = 'baseline_lifecycle_transition_trg'

  union all
  select 9, 'cardinality trigger is deferred',
         count(*) = 1
         and bool_and(oid is not null)
         and bool_and(tgdeferrable)
         and bool_and(tginitdeferred)
         and bool_and(trigger_definition ~* '^CREATE CONSTRAINT TRIGGER baseline_series_lifecycle_cardinality_trg AFTER INSERT'),
         coalesce(max(trigger_definition), '<missing>')
  from trigger_state
  where trigger_name = 'baseline_series_lifecycle_cardinality_trg'

  union all
  select 10, 'existing current ACTIVE lifecycle remains structurally valid',
         count(*) = 0,
         'ACTIVE baselines without one artifact/current PASSED gate=' || count(*)
  from current_events e
  join s2t_fhir.reference_value lifecycle_value
    on lifecycle_value.reference_value_id = e.lifecycle_status_value_id
  where lifecycle_value.value_code = 'ACTIVE'
    and (
      (
        select count(*)
        from s2t_fhir.baseline_artifact ba
        join s2t_fhir.reference_value role_value
          on role_value.reference_value_id = ba.artifact_role_value_id
        where ba.baseline_version_id = e.baseline_version_id
          and role_value.value_code = 'AUTHORITATIVE_SOURCE'
      ) <> 1
      or not exists (
        select 1
        from s2t_fhir.current_release_gate_evaluation gate_evaluation
        join s2t_fhir.reference_value outcome
          on outcome.reference_value_id = gate_evaluation.gate_outcome_value_id
        where gate_evaluation.baseline_version_id = e.baseline_version_id
          and outcome.value_code = 'PASSED'
      )
    )

  union all
  select 11, 'no new API relations from 022',
         count(*) = 0,
         'API objects matching lifecycle/candidate/superseded=' || count(*)
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 's2t_fhir_api'
    and c.relname ~* '(candidate|superseded|lifecycle)'
),
fingerprints(test_no, test_name, passed, detail) as (
  select 101, 'FP current ACTIVE lifecycle state', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from (
    select bv.baseline_code, bv.version_label, bs.source_system, bs.fhir_resource,
           e.occurred_at, v.value_code as lifecycle_status
    from current_events e
    join s2t_fhir.baseline_version bv using (baseline_version_id)
    join s2t_fhir.baseline_series bs using (baseline_series_id)
    join s2t_fhir.reference_value v
      on v.reference_value_id = e.lifecycle_status_value_id
    where v.value_code = 'ACTIVE'
  ) x
  union all
  select 102, 'FP s2t_fhir_api.active_baseline', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.active_baseline x
  union all
  select 103, 'FP s2t_fhir_api._active_release_context', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api._active_release_context x
  union all
  select 104, 'FP s2t_fhir_api.active_mapping_record', true,
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.active_mapping_record x
  union all
  select 105, 'FP active quarantine views', true,
         md5(coalesce(string_agg(x, '|' order by x), ''))
  from (
    select 'item:' || i::text as x from s2t_fhir_api.active_quarantine_item i
    union all
    select 'summary:' || s::text from s2t_fhir_api.active_quarantine_summary s
  ) q
  union all
  select 106, 'FP active MedicationRequest RPC JSON', true,
         md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text, '<null>'))
  union all
  select 107, 'FP API view/function contracts', true,
         md5(coalesce(string_agg(x.definition, E'\n' order by x.object_name), ''))
  from (
    select 'view:' || n.nspname || '.' || c.relname as object_name,
           pg_get_viewdef(c.oid, true) as definition
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 's2t_fhir_api' and c.relkind in ('v', 'm')
    union all
    select 'function:' || p.oid::regprocedure::text, pg_get_functiondef(p.oid)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 's2t_fhir_api'
  ) x

  union all
  select 108, 'FP pre-022 database contracts', true,
         md5(coalesce(string_agg(x.definition, E'\n' order by x.object_name), ''))
  from (
    select 'constraint:' || c.oid::regclass::text || ':' || con.conname as object_name,
           pg_get_constraintdef(con.oid, true) as definition
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class c on c.oid = con.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and not (
        con.contype = 't'
        and con.conname = 'baseline_series_lifecycle_cardinality_trg'
        and con.conrelid =
          's2t_fhir.baseline_lifecycle_event'::regclass
      )
    union all
    select 'index:' || idx.oid::regclass::text, pg_get_indexdef(idx.oid)
    from pg_catalog.pg_class idx
    join pg_catalog.pg_namespace n on n.oid = idx.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and idx.relkind = 'i'
      and idx.relname not in (
        'baseline_lifecycle_root_once_uq',
        'baseline_lifecycle_superseded_once_uq'
      )
    union all
    select 'function:' || p.oid::regprocedure::text,
           pg_get_functiondef(p.oid) || E'\nACL=' || coalesce(p.proacl::text, '<default>')
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and p.proname not in (
        'validate_baseline_lifecycle_insert',
        'assert_baseline_series_lifecycle',
        'check_baseline_series_lifecycle'
      )
    union all
    select 'trigger:' || t.tgrelid::regclass::text || ':' || t.tgname,
           pg_get_triggerdef(t.oid, true)
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and not t.tgisinternal
      and t.tgname not in (
        'baseline_lifecycle_transition_trg',
        'baseline_series_lifecycle_cardinality_trg'
      )
    union all
    select 'relation-acl:' || c.oid::regclass::text,
           coalesce(c.relacl::text, '<default>')
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('s2t_fhir', 's2t_fhir_api')
      and c.relkind in ('r', 'p', 'v', 'm', 'S')
  ) x

  union all
  select 109, 'FP legacy lifecycle reference rows', true,
         md5(coalesce(string_agg(v::text, '|' order by v.value_code), ''))
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'BASELINE_LIFECYCLE_STATUS'
    and v.value_code in ('PENDING_APPROVAL', 'ACTIVE', 'RETIRED')
),
all_results as (
  select * from checks
  union all
  select * from fingerprints
),
summary as (
  select 0 as test_no, 'POSTDEPLOY SUMMARY'::text as test_name,
         bool_and(passed) filter (where test_no < 100) as passed,
         format('%s/%s verification checks passed; compare FP 101-109 with preflight',
           count(*) filter (where test_no < 100 and passed),
           count(*) filter (where test_no < 100)) as detail
  from all_results
)
select test_no, test_name,
       case when passed then 'PASS' else 'FAIL' end as status,
       detail
from (
  select * from summary
  union all
  select * from all_results
) report
order by test_no;

-- Definition evidence. Review these rows together with checks 4, 5, 8, and 9.
select 'INDEX' as object_type,
       idx.oid::regclass::text as object_name,
       pg_get_indexdef(idx.oid) as definition
from pg_catalog.pg_class idx
where idx.oid in (
  to_regclass('s2t_fhir.baseline_lifecycle_root_once_uq'),
  to_regclass('s2t_fhir.baseline_lifecycle_superseded_once_uq')
)
union all
select 'FUNCTION', p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_catalog.pg_proc p
where p.oid in (
  to_regprocedure('s2t_fhir.validate_baseline_lifecycle_insert()'),
  to_regprocedure('s2t_fhir.assert_baseline_series_lifecycle(uuid)'),
  to_regprocedure('s2t_fhir.check_baseline_series_lifecycle()')
)
union all
select 'TRIGGER', t.tgname, pg_get_triggerdef(t.oid, true)
from pg_catalog.pg_trigger t
where t.tgrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
  and t.tgname in (
    'baseline_lifecycle_transition_trg',
    'baseline_series_lifecycle_cardinality_trg'
  )
order by object_type, object_name;

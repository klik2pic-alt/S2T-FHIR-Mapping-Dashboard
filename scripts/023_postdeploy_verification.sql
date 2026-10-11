-- Migration 023 controlled TEST post-deployment verification.
-- STRICTLY READ-ONLY: SELECT/catalog introspection only.
-- Compare fingerprints 101-110 exactly with 023_preflight_readonly.sql.

with
expected_relations(checkpoint, relation_name, relation_kind) as (
  values
    (1, 's2t_fhir.baseline_action_authorization', 'r'),
    (1, 's2t_fhir.baseline_candidate_context', 'r'),
    (2, 's2t_fhir.candidate_review_session_state', 'v'),
    (4, 's2t_fhir.baseline_activation_context', 'r')
),
expected_columns(checkpoint, relation_name, column_name, type_name, nullable) as (
  values
    (1,'s2t_fhir.baseline_action_authorization','baseline_action_authorization_id','uuid',false),
    (1,'s2t_fhir.baseline_action_authorization','principal_id','uuid',false),
    (1,'s2t_fhir.baseline_action_authorization','capability_code','text',false),
    (1,'s2t_fhir.baseline_action_authorization','effective_at','timestamp with time zone',false),
    (1,'s2t_fhir.baseline_action_authorization','revoked_at','timestamp with time zone',true),
    (1,'s2t_fhir.baseline_action_authorization','granted_by_principal_id','uuid',false),
    (1,'s2t_fhir.baseline_action_authorization','revoked_by_principal_id','uuid',true),
    (1,'s2t_fhir.baseline_action_authorization','created_at','timestamp with time zone',false),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_id','uuid',false),
    (1,'s2t_fhir.baseline_candidate_context','baseline_version_id','uuid',false),
    (1,'s2t_fhir.baseline_candidate_context','candidate_lifecycle_event_id','uuid',false),
    (1,'s2t_fhir.baseline_candidate_context','artifact_id','uuid',false),
    (1,'s2t_fhir.baseline_candidate_context','import_run_id','uuid',false),
    (1,'s2t_fhir.baseline_candidate_context','effective_at','timestamp with time zone',false),
    (1,'s2t_fhir.baseline_candidate_context','actor_principal_id','uuid',false),
    (1,'s2t_fhir.baseline_candidate_context','initiating_human_principal_id','uuid',true),
    (1,'s2t_fhir.baseline_candidate_context','created_at','timestamp with time zone',false),
    (2,'s2t_fhir.review_session','review_target_lifecycle_event_id','uuid',true),
    (2,'s2t_fhir.mapping_review_event','review_target_lifecycle_event_id','uuid',true),
    (3,'s2t_governance.governance_mapping_link','baseline_version_id','uuid',true),
    (3,'s2t_governance.governance_mapping_link','review_target_lifecycle_event_id','uuid',true),
    (3,'s2t_governance.governance_mapping_link','lifecycle_status_at_link','text',true),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','baseline_version_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','candidate_lifecycle_event_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','active_lifecycle_event_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','artifact_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','import_run_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','release_gate_evaluation_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','prior_active_baseline_version_id','uuid',true),
    (4,'s2t_fhir.baseline_activation_context','prior_active_lifecycle_event_id','uuid',true),
    (4,'s2t_fhir.baseline_activation_context','prior_active_superseded_event_id','uuid',true),
    (4,'s2t_fhir.baseline_activation_context','effective_at','timestamp with time zone',false),
    (4,'s2t_fhir.baseline_activation_context','actor_principal_id','uuid',false),
    (4,'s2t_fhir.baseline_activation_context','initiating_human_principal_id','uuid',true),
    (4,'s2t_fhir.baseline_activation_context','created_at','timestamp with time zone',false)
),
expected_constraints(checkpoint, relation_name, constraint_name) as (
  values
    (1,'s2t_fhir.baseline_action_authorization','baseline_action_authorization_capability_ck'),
    (1,'s2t_fhir.baseline_action_authorization','baseline_action_authorization_revoke_pair_ck'),
    (1,'s2t_fhir.baseline_action_authorization','baseline_action_authorization_time_ck'),
    (1,'s2t_fhir.baseline_action_authorization','baseline_action_authorization_created_ck'),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_baseline_uq'),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_event_uq'),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_import_uq'),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_time_ck'),
    (2,'s2t_fhir.review_session','review_session_target_lifecycle_event_fk'),
    (2,'s2t_fhir.mapping_review_event','mapping_review_event_target_lifecycle_event_fk'),
    (3,'s2t_governance.governance_mapping_link','governance_mapping_link_baseline_version_fk'),
    (3,'s2t_governance.governance_mapping_link','governance_mapping_link_lifecycle_event_fk'),
    (3,'s2t_governance.governance_mapping_link','governance_mapping_link_lifecycle_context_ck'),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_baseline_uq'),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_import_uq'),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_active_event_fk'),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_prior_superseded_event_fk'),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_prior_active_shape_ck'),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_event_identity_ck'),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_time_ck')
),
expected_indexes(
  checkpoint, schema_name, index_name, relation_name,
  is_unique, key_columns, predicate_text
) as (
  values
    (1,'s2t_fhir','baseline_action_authorization_active_uq',
      's2t_fhir.baseline_action_authorization',true,
      array['principal_id','capability_code']::text[],'revoked_at IS NULL'),
    (1,'s2t_fhir','baseline_action_authorization_lookup_idx',
      's2t_fhir.baseline_action_authorization',false,
      array['principal_id','capability_code','effective_at','revoked_at']::text[],null::text),
    (1,'s2t_fhir','baseline_candidate_context_artifact_idx',
      's2t_fhir.baseline_candidate_context',false,array['artifact_id']::text[],null::text),
    (1,'s2t_fhir','baseline_candidate_context_created_idx',
      's2t_fhir.baseline_candidate_context',false,
      array['created_at','baseline_candidate_context_id']::text[],null::text),
    (2,'s2t_fhir','review_session_target_lifecycle_idx',
      's2t_fhir.review_session',false,
      array['baseline_version_id','review_target_lifecycle_event_id','ended_at']::text[],null::text),
    (2,'s2t_fhir','mapping_review_event_target_lifecycle_idx',
      's2t_fhir.mapping_review_event',false,
      array['baseline_version_id','review_target_lifecycle_event_id','mapping_record_id']::text[],null::text),
    (3,'s2t_governance','governance_mapping_link_candidate_context_idx',
      's2t_governance.governance_mapping_link',false,
      array['baseline_version_id','review_target_lifecycle_event_id','question_id']::text[],
      'baseline_version_id IS NOT NULL'),
    (4,'s2t_fhir','baseline_activation_context_gate_idx',
      's2t_fhir.baseline_activation_context',false,
      array['release_gate_evaluation_id','baseline_version_id']::text[],null::text),
    (4,'s2t_fhir','baseline_activation_context_prior_active_idx',
      's2t_fhir.baseline_activation_context',false,
      array['prior_active_baseline_version_id','prior_active_lifecycle_event_id']::text[],
      'prior_active_baseline_version_id IS NOT NULL')
),
index_state as (
  select expected.*, idx.oid, ind.indrelid, ind.indisunique,
         ind.indisvalid, ind.indisready, ind.indnkeyatts, ind.indnatts,
         am.amname as access_method,
         pg_get_expr(ind.indpred, ind.indrelid) as predicate_definition,
         array(
           select attribute.attname
           from unnest(ind.indkey::smallint[]) with ordinality key(attnum, ord)
           join pg_catalog.pg_attribute attribute
             on attribute.attrelid = ind.indrelid
            and attribute.attnum = key.attnum
           order by key.ord
         ) as indexed_columns
  from expected_indexes expected
  left join pg_catalog.pg_class idx
    on idx.oid = to_regclass(expected.schema_name || '.' || expected.index_name)
  left join pg_catalog.pg_index ind on ind.indexrelid = idx.oid
  left join pg_catalog.pg_am am on am.oid = idx.relam
),
expected_functions(checkpoint, signature, security_definer, volatility, public_api, importer_admin) as (
  values
    (1,'s2t_fhir.protect_baseline_action_authorization_update()',false,'v',false,false),
    (1,'s2t_fhir_api._require_authenticated_baseline_capability(text)',true,'s',false,false),
    (1,'s2t_fhir.grant_baseline_action(uuid,text,uuid)',true,'v',false,true),
    (1,'s2t_fhir.revoke_baseline_action(uuid,text,uuid)',true,'v',false,true),
    (1,'s2t_fhir.validate_baseline_candidate_context()',true,'v',false,false),
    (1,'s2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)',true,'v',false,false),
    (1,'s2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)',true,'v',true,false),
    (2,'s2t_fhir._require_current_candidate_context(uuid,uuid)',true,'s',false,false),
    (2,'s2t_fhir._lock_current_candidate_context(uuid,uuid)',true,'v',false,false),
    (2,'s2t_fhir_api._candidate_mapping_nodes(uuid,uuid)',true,'s',false,false),
    (2,'s2t_fhir.protect_review_lifecycle_provenance()',false,'v',false,false),
    (2,'s2t_fhir.validate_review_lifecycle_provenance()',true,'v',false,false),
    (2,'s2t_fhir_api._start_candidate_review_session(uuid,uuid,text,uuid,text)',true,'v',false,false),
    (2,'s2t_fhir_api._end_candidate_review_session(uuid,uuid,uuid,uuid)',true,'v',false,false),
    (2,'s2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)',true,'v',false,false),
    (2,'s2t_fhir_api.get_candidate_medication_request_cato(uuid,uuid)',true,'s',true,false),
    (2,'s2t_fhir_api.get_candidate_mapping_review_status(uuid,uuid)',true,'s',true,false),
    (2,'s2t_fhir_api.get_candidate_mapping_review_progress(uuid,uuid)',true,'s',true,false),
    (2,'s2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)',true,'v',true,false),
    (2,'s2t_fhir_api.end_authenticated_candidate_review_session(uuid,uuid,uuid)',true,'v',true,false),
    (2,'s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)',true,'v',true,false),
    (2,'s2t_fhir_api.mark_authenticated_candidate_mapping_needs_follow_up(uuid,uuid,text,uuid,text)',true,'v',true,false),
    (2,'s2t_fhir_api.clear_authenticated_candidate_mapping_review(uuid,uuid,text,uuid,text)',true,'v',true,false),
    (3,'s2t_governance.validate_mapping_link_lifecycle_context()',true,'v',false,false),
    (3,'s2t_governance._resolve_candidate_mapping_identity(uuid,uuid,text,text,text)',true,'s',false,false),
    (3,'s2t_governance._insert_candidate_mapping_link(uuid,uuid,uuid,jsonb,uuid,timestamptz)',true,'v',false,false),
    (3,'s2t_fhir_api.gov_link_candidate_mapping(uuid,uuid,uuid,jsonb,timestamptz)',true,'v',true,false),
    (4,'s2t_fhir.assert_candidate_activation_eligibility(uuid,uuid,uuid,uuid,timestamptz)',true,'v',false,false),
    (4,'s2t_fhir.validate_baseline_activation_context()',true,'v',false,false),
    (4,'s2t_fhir.authorize_active_lifecycle_insert()',true,'v',false,false),
    (4,'s2t_fhir.assert_activated_baseline_eligibility(uuid)',true,'v',false,false),
    (4,'s2t_fhir.check_active_lifecycle_eligibility()',true,'v',false,false),
    (4,'s2t_fhir.check_governed_active_dependency()',true,'v',false,false),
    (4,'s2t_fhir.promote_current_candidate(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)',true,'v',false,false),
    (4,'s2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)',true,'v',true,false)
),
function_state as (
  select expected.*, p.oid, owner.rolname as owner_name, p.prosecdef,
         p.provolatile, p.proconfig, p.proacl
  from expected_functions expected
  left join pg_catalog.pg_proc p on p.oid = to_regprocedure(expected.signature)
  left join pg_catalog.pg_roles owner on owner.oid = p.proowner
),
expected_triggers(checkpoint, relation_name, trigger_name, must_defer) as (
  values
    (1,'s2t_fhir.baseline_action_authorization','baseline_action_authorization_protect_update_trg',false),
    (1,'s2t_fhir.baseline_action_authorization','baseline_action_authorization_reject_delete_trg',false),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_integrity_trg',false),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_actor_pair_trg',false),
    (1,'s2t_fhir.baseline_candidate_context','baseline_candidate_context_append_only_trg',false),
    (2,'s2t_fhir.review_session','review_session_lifecycle_provenance_insert_trg',false),
    (2,'s2t_fhir.review_session','review_session_lifecycle_provenance_immutable_trg',false),
    (2,'s2t_fhir.mapping_review_event','mapping_review_event_lifecycle_provenance_insert_trg',false),
    (2,'s2t_fhir.mapping_review_event','mapping_review_event_lifecycle_provenance_immutable_trg',false),
    (3,'s2t_governance.governance_mapping_link','lifecycle_context_validate',false),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_integrity_trg',false),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_actor_pair_trg',false),
    (4,'s2t_fhir.baseline_activation_context','baseline_activation_context_append_only_trg',false),
    (4,'s2t_fhir.baseline_lifecycle_event','baseline_active_lifecycle_authorization_trg',false),
    (4,'s2t_fhir.baseline_lifecycle_event','baseline_active_lifecycle_eligibility_trg',true),
    (4,'s2t_fhir.release_gate_evaluation','governed_active_release_gate_dependency_trg',true),
    (4,'s2t_fhir.validation_run','governed_active_validation_dependency_trg',true)
),
trigger_state as (
  select expected.*, t.oid, t.tgdeferrable, t.tginitdeferred
  from expected_triggers expected
  left join pg_catalog.pg_trigger t
    on t.tgrelid = to_regclass(expected.relation_name)
   and t.tgname = expected.trigger_name
   and not t.tgisinternal
),
client_roles(role_name) as (
  values ('anon'),('authenticated'),('service_role'),('s2t_fhir_importer'),
         ('s2t_fhir_api_reader'),('s2t_fhir_governance_reader')
),
protected_relations(checkpoint, relation_name) as (
  values
    (1,'s2t_fhir.baseline_action_authorization'),
    (1,'s2t_fhir.baseline_candidate_context'),
    (2,'s2t_fhir.candidate_review_session_state'),
    (3,'s2t_governance.governance_mapping_link'),
    (4,'s2t_fhir.baseline_activation_context')
),
checks(test_no, checkpoint, test_name, status, detail) as (
  select 1, checkpoint, 'relations and owners',
         case when count(*) filter (where c.oid is null or c.relkind::text <> relation_kind
                                      or owner.rolname <> 's2t_fhir_owner') = 0
              then 'PASS' else 'FAIL' end,
         format('%s/%s exact', count(*) filter (where c.oid is not null
           and c.relkind::text = relation_kind and owner.rolname = 's2t_fhir_owner'), count(*))
  from expected_relations expected
  left join pg_catalog.pg_class c on c.oid = to_regclass(expected.relation_name)
  left join pg_catalog.pg_roles owner on owner.oid = c.relowner
  group by checkpoint

  union all
  select 2, checkpoint, 'column definitions',
         case when count(*) filter (where a.attnum is null
                     or pg_catalog.format_type(a.atttypid,a.atttypmod) <> type_name
                     or a.attnotnull = nullable) = 0 then 'PASS' else 'FAIL' end,
         format('%s/%s exact', count(*) filter (where a.attnum is not null
                     and pg_catalog.format_type(a.atttypid,a.atttypmod) = type_name
                     and a.attnotnull <> nullable), count(*))
  from expected_columns expected
  left join pg_catalog.pg_attribute a
    on a.attrelid = to_regclass(expected.relation_name)
   and a.attname = expected.column_name and a.attnum > 0 and not a.attisdropped
  group by checkpoint

  union all
  select 3, checkpoint, 'named constraints',
         case when count(*) filter (where con.oid is null) = 0 then 'PASS' else 'FAIL' end,
         format('%s/%s present', count(con.oid), count(*))
  from expected_constraints expected
  left join pg_catalog.pg_constraint con
    on con.conrelid = to_regclass(expected.relation_name)
   and con.conname = expected.constraint_name
  group by checkpoint

  union all
  select 4, checkpoint, 'exact index definitions',
         case when count(*) filter (where oid is null
                  or indrelid <> to_regclass(relation_name)
                  or indisunique <> is_unique
                  or not indisvalid or not indisready
                  or indnkeyatts <> cardinality(key_columns)
                  or indnatts <> cardinality(key_columns)
                  or access_method <> 'btree'
                  or indexed_columns::text[] <> key_columns
                  or coalesce(regexp_replace(predicate_definition,'[()]','','g'),'')
                       <> coalesce(predicate_text,'')) = 0
              then 'PASS' else 'FAIL' end,
         format('%s/%s exact', count(*) filter (where oid is not null
           and indrelid = to_regclass(relation_name)
           and indisunique = is_unique and indisvalid and indisready
           and indnkeyatts = cardinality(key_columns)
           and indnatts = cardinality(key_columns)
           and access_method = 'btree'
           and indexed_columns::text[] = key_columns
           and coalesce(regexp_replace(predicate_definition,'[()]','','g'),'')
                 = coalesce(predicate_text,'')), count(*))
  from index_state
  group by checkpoint

  union all
  select 5, checkpoint, 'function metadata',
         case when count(*) filter (where oid is null or owner_name <> 's2t_fhir_owner'
                 or prosecdef <> security_definer or provolatile::text <> volatility
                 or proconfig is distinct from array['search_path=""']) = 0
              then 'PASS' else 'FAIL' end,
         format('%s/%s exact', count(*) filter (where oid is not null
                 and owner_name = 's2t_fhir_owner' and prosecdef = security_definer
                 and provolatile::text = volatility
                 and proconfig is not distinct from array['search_path=""']), count(*))
  from function_state group by checkpoint

  union all
  select 6, checkpoint, 'trigger presence/deferral',
         case when count(*) filter (where oid is null
                 or (must_defer and (not tgdeferrable or not tginitdeferred))) = 0
              then 'PASS' else 'FAIL' end,
         format('%s/%s exact', count(*) filter (where oid is not null
                 and (not must_defer or (tgdeferrable and tginitdeferred))), count(*))
  from trigger_state group by checkpoint

  union all
  select 7, 1, 'baseline capabilities exact',
         case when pg_get_constraintdef(con.oid, true) like '%S2T_BASELINE_UPLOAD%'
                    and pg_get_constraintdef(con.oid, true) like '%S2T_BASELINE_PROMOTE%'
              then 'PASS' else 'FAIL' end,
         coalesce(pg_get_constraintdef(con.oid, true), '<absent>')
  from (select 1) seed
  left join pg_catalog.pg_constraint con
    on con.conrelid = to_regclass('s2t_fhir.baseline_action_authorization')
   and con.conname = 'baseline_action_authorization_capability_ck'

  union all
  select 8, 2, 'Candidate Review provenance state model',
         case when c.reloptions @> array['security_barrier=true']::text[]
                   and pg_get_viewdef(c.oid, true)
                    like '%OPEN_CURRENT%'
                   and pg_get_viewdef(c.oid, true)
                    like '%OPEN_FROZEN%'
                   and pg_get_viewdef(c.oid, true)
                    like '%CLOSED%'
              then 'PASS' else 'FAIL' end,
         'security_barrier; OPEN_CURRENT / OPEN_FROZEN / CLOSED'
  from pg_catalog.pg_class c
  where c.oid = 's2t_fhir.candidate_review_session_state'::regclass

  union all
  select 9, 3, 'Candidate governance avoids ACTIVE resolver',
         case when pg_get_functiondef(
                    's2t_governance._resolve_candidate_mapping_identity(uuid,uuid,text,text,text)'::regprocedure)
                    not like '%_active_release_context%'
                   and pg_get_functiondef(
                    's2t_governance._insert_candidate_mapping_link(uuid,uuid,uuid,jsonb,uuid,timestamptz)'::regprocedure)
                    not like '%_active_release_context%'
              then 'PASS' else 'FAIL' end,
         'Candidate resolver/core contain no _active_release_context reference'

  union all
  select 10, 3, 'existing ACTIVE governance wrapper definition', 'PASS',
         md5(pg_get_functiondef('s2t_fhir_api.gov_link_mapping(uuid,jsonb,timestamptz)'::regprocedure))

  union all
  select 11, 4, 'direct ACTIVE guard installed',
         case when count(*) = 1 then 'PASS' else 'FAIL' end,
         'authorization triggers=' || count(*)
  from pg_catalog.pg_trigger t
  where t.tgrelid = 's2t_fhir.baseline_lifecycle_event'::regclass
    and t.tgname = 'baseline_active_lifecycle_authorization_trg'
    and not t.tgisinternal

  union all
  select 12, 4, 'deferred ACTIVE final-state checks',
         case when count(*) = 3 and bool_and(tgdeferrable and tginitdeferred)
              then 'PASS' else 'FAIL' end,
         'deferred triggers=' || count(*)
  from trigger_state
  where checkpoint = 4 and must_defer

  union all
  select 13, checkpoint, 'function privilege boundary',
         case when count(*) filter (where
              (role_name = 'authenticated' and can_execute <> public_api)
              or (role_name = 's2t_fhir_importer' and can_execute <> importer_admin)
              or (role_name not in ('authenticated','s2t_fhir_importer') and can_execute)) = 0
              then 'PASS' else 'FAIL' end,
         format('%s privilege probes', count(*))
  from (
    select f.checkpoint, f.public_api, f.importer_admin, r.role_name,
           has_function_privilege(r.role_name, f.oid, 'EXECUTE') as can_execute
    from function_state f cross join client_roles r
    where f.oid is not null
  ) privileges
  group by checkpoint

  union all
  select 14, checkpoint, 'no direct protected-relation client access',
         case when count(*) filter (where can_access) = 0 then 'PASS' else 'FAIL' end,
         format('%s privilege probes; granted=%s', count(*), count(*) filter (where can_access))
  from (
    select expected.checkpoint, r.role_name,
      has_table_privilege(r.role_name, to_regclass(expected.relation_name),
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') as can_access
    from protected_relations expected cross join client_roles r
  ) privileges
  group by checkpoint

  union all
  select 15, function_state.checkpoint, 'direct function EXECUTE ACLs',
         case when count(*) filter (where acl.privilege_type = 'EXECUTE'
                    and acl.grantee <> function_state.owner_oid
                    and not (function_state.public_api and acl.grantee = authenticated.oid)
                    and not (function_state.importer_admin and acl.grantee = importer.oid)) = 0
              then 'PASS' else 'FAIL' end,
         format('%s direct EXECUTE ACL entries; unexpected=%s',
           count(*) filter (where acl.privilege_type = 'EXECUTE'),
           count(*) filter (where acl.privilege_type = 'EXECUTE'
                    and acl.grantee <> function_state.owner_oid
                    and not (function_state.public_api and acl.grantee = authenticated.oid)
                    and not (function_state.importer_admin and acl.grantee = importer.oid)))
  from (
    select state.*, proc.proowner as owner_oid
    from function_state state
    join pg_catalog.pg_proc proc on proc.oid = state.oid
  ) function_state
  cross join lateral pg_catalog.aclexplode(
    coalesce(function_state.proacl,
             pg_catalog.acldefault('f',function_state.owner_oid))) acl
  cross join pg_catalog.pg_roles authenticated
  cross join pg_catalog.pg_roles importer
  where authenticated.rolname = 'authenticated'
    and importer.rolname = 's2t_fhir_importer'
  group by function_state.checkpoint

  union all
  select 16, 4, 'existing ACTIVE governed-read eligibility',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         'current ACTIVE leaves absent from exact active context=' || count(*)
  from s2t_fhir.current_baseline_lifecycle_event event
  join s2t_fhir.reference_value status
    on status.reference_value_id = event.lifecycle_status_value_id
  join s2t_fhir.reference_domain domain
    on domain.reference_domain_id = status.reference_domain_id
   and domain.domain_code = 'BASELINE_LIFECYCLE_STATUS'
  where status.value_code = 'ACTIVE'
    and (select count(*)
         from s2t_fhir_api._active_release_context active_context
         where active_context.baseline_version_id = event.baseline_version_id) <> 1
),
fingerprints(test_no, checkpoint, test_name, status, detail) as (
  select 101, 0, 'FP current ACTIVE lifecycle state', 'PASS',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from (
    select bv.baseline_code, bv.version_label, bs.source_system, bs.fhir_resource,
           e.occurred_at, status.value_code
    from s2t_fhir.baseline_lifecycle_event e
    join s2t_fhir.baseline_version bv using (baseline_version_id)
    join s2t_fhir.baseline_series bs using (baseline_series_id)
    join s2t_fhir.reference_value status on status.reference_value_id = e.lifecycle_status_value_id
    where status.value_code = 'ACTIVE' and not exists (
      select 1 from s2t_fhir.baseline_lifecycle_event successor
      where successor.supersedes_event_id = e.baseline_lifecycle_event_id)
  ) x
  union all select 102,0,'FP active_baseline','PASS',md5(coalesce(string_agg(x::text,'|' order by x::text),'')) from s2t_fhir_api.active_baseline x
  union all select 103,0,'FP _active_release_context','PASS',md5(coalesce(string_agg(x::text,'|' order by x::text),'')) from s2t_fhir_api._active_release_context x
  union all select 104,0,'FP active_mapping_record','PASS',md5(coalesce(string_agg(x::text,'|' order by x::text),'')) from s2t_fhir_api.active_mapping_record x
  union all select 105,0,'FP active quarantine projections','PASS',md5(coalesce(string_agg(x,'|' order by x),'')) from (
    select 'item:'||q::text x from s2t_fhir_api.active_quarantine_item q union all
    select 'summary:'||q::text from s2t_fhir_api.active_quarantine_summary q) data
  union all select 106,0,'FP governed_mapping_identity','PASS',md5(coalesce(string_agg(x::text,'|' order by x::text),'')) from s2t_fhir_api.governed_mapping_identity x
  union all select 107,0,'FP active review projections','PASS',md5(coalesce(string_agg(x,'|' order by x),'')) from (
    select 'status:'||r::text x from s2t_fhir_api.active_mapping_review_status r union all
    select 'progress:'||coalesce(s2t_fhir_api.get_active_medication_request_cato_review_progress()::text,'<null>')) data
  union all select 108,0,'FP stable governance read views','PASS',md5(coalesce(string_agg(x,'|' order by x),'')) from (
    select 'parties:'||r::text x from s2t_fhir_api.governance_parties r
    union all select 'timeline:'||r::text from s2t_fhir_api.governance_question_timeline r
    union all select 'links:'||r::text from s2t_fhir_api.governance_mapping_links r
    union all select 'requests:'||r::text from s2t_fhir_api.governance_open_requests r
    union all
    select 'questions:'||(
      to_jsonb(r)-'total_elapsed'-'external_waiting'-'on_hold'
      -'internal_handling'-'time_to_decision'
    )::text
    from s2t_fhir_api.governance_questions r) data
  union all select 109,0,'FP active CATO MedicationRequest API','PASS',md5(coalesce(s2t_fhir_api.get_active_medication_request_cato()::text,'<null>'))
  union all select 110,0,'FP unchanged ACTIVE API definitions','PASS',md5(coalesce(string_agg(definition,E'\n' order by object_name),'')) from (
    select c.oid::regclass::text object_name,pg_get_viewdef(c.oid,true) definition from pg_catalog.pg_class c
    where c.oid in ('s2t_fhir_api._active_release_context'::regclass,'s2t_fhir_api.active_baseline'::regclass,
      's2t_fhir_api.active_mapping_record'::regclass,'s2t_fhir_api.active_mapping_review_status'::regclass,
      's2t_fhir_api.governed_mapping_identity'::regclass)
    union all select p.oid::regprocedure::text,pg_get_functiondef(p.oid) from pg_catalog.pg_proc p
    where p.oid in ('s2t_fhir_api.get_active_medication_request_cato()'::regprocedure,
      's2t_fhir_api.get_active_medication_request_cato_review_progress()'::regprocedure,
      's2t_fhir_api.gov_link_mapping(uuid,jsonb,timestamptz)'::regprocedure)) definitions
),
all_results as (
  select * from checks union all select * from fingerprints
),
checkpoint_summary as (
  select 90 + checkpoint as test_no, checkpoint,
         'CHECKPOINT ' || checkpoint || ' SUMMARY' as test_name,
         case when count(*) filter (where status = 'FAIL') = 0
              then 'PASS' else 'FAIL' end as status,
         format('%s PASS, %s FAIL',
           count(*) filter (where status = 'PASS'),
           count(*) filter (where status = 'FAIL')) as detail
  from checks group by checkpoint
),
overall as (
  select 0 as test_no, 0 as checkpoint, 'POSTDEPLOY SUMMARY'::text as test_name,
         case when count(*) filter (where status = 'FAIL') = 0
              then 'PASS' else 'FAIL' end as status,
         format('%s PASS, %s FAIL; compare FP101-110 with preflight',
           count(*) filter (where status = 'PASS'),
           count(*) filter (where status = 'FAIL')) as detail
  from all_results
)
select test_no, checkpoint, test_name, status, detail
from (select * from overall union all select * from checkpoint_summary union all select * from all_results) report
order by test_no, checkpoint;

-- Exact catalog evidence. These result sets are evidence, not additional writes.
select expected.checkpoint, expected.schema_name, expected.index_name,
       pg_get_indexdef(idx.oid) as index_definition
from (values
  (1,'s2t_fhir','baseline_action_authorization_active_uq'),
  (1,'s2t_fhir','baseline_action_authorization_lookup_idx'),
  (1,'s2t_fhir','baseline_candidate_context_artifact_idx'),
  (1,'s2t_fhir','baseline_candidate_context_created_idx'),
  (2,'s2t_fhir','review_session_target_lifecycle_idx'),
  (2,'s2t_fhir','mapping_review_event_target_lifecycle_idx'),
  (3,'s2t_governance','governance_mapping_link_candidate_context_idx'),
  (4,'s2t_fhir','baseline_activation_context_gate_idx'),
  (4,'s2t_fhir','baseline_activation_context_prior_active_idx')
) expected(checkpoint,schema_name,index_name)
left join pg_catalog.pg_class idx
  on idx.oid = to_regclass(expected.schema_name || '.' || expected.index_name)
order by checkpoint,index_name;

select p.oid::regprocedure::text as function_signature,
       owner.rolname as owner_name, p.prosecdef, p.provolatile,
       p.proconfig, p.proacl, pg_get_functiondef(p.oid) as function_definition
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
join pg_catalog.pg_roles owner on owner.oid = p.proowner
where n.nspname in ('s2t_fhir','s2t_fhir_api','s2t_governance')
  and p.proname in (
    'protect_baseline_action_authorization_update','_require_authenticated_baseline_capability',
    'grant_baseline_action','revoke_baseline_action','validate_baseline_candidate_context',
    'replace_current_candidate','publish_candidate_baseline','_require_current_candidate_context',
    '_lock_current_candidate_context','_candidate_mapping_nodes','protect_review_lifecycle_provenance',
    'validate_review_lifecycle_provenance','_start_candidate_review_session',
    '_end_candidate_review_session','_record_candidate_mapping_review',
    'get_candidate_medication_request_cato','get_candidate_mapping_review_status',
    'get_candidate_mapping_review_progress','start_authenticated_candidate_review_session',
    'end_authenticated_candidate_review_session','mark_authenticated_candidate_mapping_reviewed',
    'mark_authenticated_candidate_mapping_needs_follow_up','clear_authenticated_candidate_mapping_review',
    'validate_mapping_link_lifecycle_context','_resolve_candidate_mapping_identity',
    '_insert_candidate_mapping_link','gov_link_candidate_mapping',
    'assert_candidate_activation_eligibility','validate_baseline_activation_context',
    'authorize_active_lifecycle_insert','assert_activated_baseline_eligibility',
    'check_active_lifecycle_eligibility','check_governed_active_dependency',
    'promote_current_candidate','promote_candidate_baseline')
order by function_signature;

select t.tgrelid::regclass::text as relation_name, t.tgname,
       t.tgdeferrable, t.tginitdeferred,
       pg_get_triggerdef(t.oid, true) as trigger_definition
from pg_catalog.pg_trigger t
where not t.tgisinternal
  and t.tgname in (
    'baseline_action_authorization_protect_update_trg','baseline_action_authorization_reject_delete_trg',
    'baseline_candidate_context_integrity_trg','baseline_candidate_context_actor_pair_trg',
    'baseline_candidate_context_append_only_trg','review_session_lifecycle_provenance_insert_trg',
    'review_session_lifecycle_provenance_immutable_trg','mapping_review_event_lifecycle_provenance_insert_trg',
    'mapping_review_event_lifecycle_provenance_immutable_trg','lifecycle_context_validate',
    'baseline_activation_context_integrity_trg','baseline_activation_context_actor_pair_trg',
    'baseline_activation_context_append_only_trg','baseline_active_lifecycle_authorization_trg',
    'baseline_active_lifecycle_eligibility_trg','governed_active_release_gate_dependency_trg',
    'governed_active_validation_dependency_trg')
order by relation_name,tgname;

select c.oid::regclass::text as view_name, pg_get_viewdef(c.oid, true) as view_definition
from pg_catalog.pg_class c
where c.oid = 's2t_fhir.candidate_review_session_state'::regclass;

select con.conrelid::regclass::text as relation_name, con.conname,
       con.contype, con.condeferrable, con.condeferred,
       pg_get_constraintdef(con.oid, true) as constraint_definition
from pg_catalog.pg_constraint con
where con.conrelid in (
  's2t_fhir.baseline_action_authorization'::regclass,
  's2t_fhir.baseline_candidate_context'::regclass,
  's2t_fhir.baseline_activation_context'::regclass
)
   or con.conname in (
  'baseline_action_authorization_capability_ck','baseline_action_authorization_revoke_pair_ck',
  'baseline_action_authorization_time_ck','baseline_action_authorization_created_ck',
  'baseline_candidate_context_baseline_uq','baseline_candidate_context_event_uq',
  'baseline_candidate_context_import_uq','baseline_candidate_context_time_ck',
  'review_session_target_lifecycle_event_fk','mapping_review_event_target_lifecycle_event_fk',
  'governance_mapping_link_baseline_version_fk','governance_mapping_link_lifecycle_event_fk',
  'governance_mapping_link_lifecycle_context_ck','baseline_activation_context_baseline_uq',
  'baseline_activation_context_import_uq','baseline_activation_context_active_event_fk',
  'baseline_activation_context_prior_superseded_event_fk','baseline_activation_context_prior_active_shape_ck',
  'baseline_activation_context_event_identity_ck','baseline_activation_context_time_ck')
order by relation_name,conname;

select function_state.oid::regprocedure::text as function_signature,
       role_name,
       has_function_privilege(role_name,function_state.oid,'EXECUTE') as effective_execute
from pg_catalog.pg_proc function_state
cross join (values ('anon'),('authenticated'),('service_role'),('s2t_fhir_importer'),
                   ('s2t_fhir_api_reader'),('s2t_fhir_governance_reader')) roles(role_name)
where function_state.oid in (
  's2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)'::regprocedure,
  's2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)'::regprocedure,
  's2t_fhir_api._record_candidate_mapping_review(uuid,uuid,text,text,uuid,uuid,text)'::regprocedure,
  's2t_fhir_api.gov_link_candidate_mapping(uuid,uuid,uuid,jsonb,timestamptz)'::regprocedure,
  's2t_fhir.promote_current_candidate(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text,uuid,uuid)'::regprocedure,
  's2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)'::regprocedure)
order by function_signature,role_name;

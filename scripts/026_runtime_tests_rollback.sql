-- Migration 026 rollback-only runtime contract verification.
-- Run only after 026 postdeployment verification passes.
-- All fixture mutations are enclosed by the single outer transaction and ROLLBACK.

begin;
set local role s2t_fhir_owner;

create temporary table test_026_results (
  test_no integer primary key,
  test_name text not null,
  result text not null check (result in ('PASS','FAIL')),
  detail text not null
) on commit drop;

create function pg_temp.test_026_record(
  p_test_no integer,
  p_test_name text,
  p_pass boolean,
  p_detail text
) returns void language sql as $function$
  insert into pg_temp.test_026_results(test_no,test_name,result,detail)
  values (p_test_no,p_test_name,case when p_pass then 'PASS' else 'FAIL' end,p_detail);
$function$;

select pg_temp.test_026_record(1,'private import tables present',
  (select count(*)=3 from (values
    ('s2t_fhir.candidate_import_request'),
    ('s2t_fhir.candidate_import_request_event'),
    ('s2t_fhir.candidate_import_staging_batch')) x(name)
   where pg_catalog.to_regclass(name) is not null),
  'three private relations required');

select pg_temp.test_026_record(2,'signatures and governed artifact vocabulary resolve',
  (select count(*)=8 from (values
    ('s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)'),
    ('s2t_fhir_api.get_my_candidate_import(uuid)'),
    ('s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)'),
    ('s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
    ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
    ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
      ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)')) x(signature)
   where pg_catalog.to_regprocedure(signature) is not null)
  and
  (select count(*)=2 and count(*) filter (
      where rv.effective_at<=pg_catalog.transaction_timestamp()
        and (rv.retired_at is null or rv.retired_at>pg_catalog.transaction_timestamp()))=2
   from s2t_fhir.reference_domain rd
   join s2t_fhir.reference_value rv using(reference_domain_id)
   where (rd.domain_code,rv.value_code) in (
     ('ARTIFACT_KIND','WORKBOOK'),
     ('ARTIFACT_LOCATION_KIND','OBJECT_STORAGE')))
  and
  (select prosrc like '%ARTIFACT_KIND%WORKBOOK%'
          and prosrc like '%ARTIFACT_LOCATION_KIND%OBJECT_STORAGE%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)')),
  'eight signatures plus singular active WORKBOOK/OBJECT_STORAGE helper lookups');

select pg_temp.test_026_record(3,'state vocabulary exact',
  pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint
    where conname='candidate_import_request_state_ck')) like all(array[
      '%AWAITING_UPLOAD%','%UPLOADED%','%VALIDATING%','%READY_TO_PUBLISH%',
      '%PUBLISHED%','%VALIDATION_FAILED%','%FAILED%','%ABORTED%'])
    and pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint
      where conname='candidate_import_request_state_ck')) not like '%PUBLISHING%',
  'eight states; no persisted PUBLISHING');

select pg_temp.test_026_record(4,'append-only protections installed',
  (select count(*)=2 from pg_catalog.pg_trigger
   where tgname in ('candidate_import_request_event_append_only_trg',
                    'candidate_import_staging_batch_append_only_trg')
     and not tgisinternal),
  'event and staging batch UPDATE/DELETE triggers');

select pg_temp.test_026_record(5,'browser direct DML denied',
  not exists (
    select 1 from (values
      ('s2t_fhir.candidate_import_request'),
      ('s2t_fhir.candidate_import_request_event'),
      ('s2t_fhir.candidate_import_staging_batch')) t(name)
    cross join (values('authenticated'),('anon')) r(role_name)
    cross join (values('INSERT'),('UPDATE'),('DELETE')) p(privilege_name)
    where pg_catalog.has_table_privilege(r.role_name,t.name,p.privilege_name)),
  'authenticated and anon have no private-table DML');

select pg_temp.test_026_record(6,'anonymous public RPC execution denied',
  not exists (
    select 1 from (values
      ('s2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)'),
      ('s2t_fhir_api.get_my_candidate_import(uuid)'),
      ('s2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')) x(signature)
    where pg_catalog.has_function_privilege('anon',
      pg_catalog.to_regprocedure(signature),'EXECUTE')),
  'anon has no EXECUTE on public import RPCs');

create temporary table test_026_context(
  request_one uuid,
  request_two uuid,
  principal_id uuid,
  resource_config_id text,
  baseline_series_id uuid
) on commit drop;

do $fixture$
declare
  v_principal uuid;
  v_resource text;
  v_series uuid;
  v_one uuid;
  v_two uuid;
begin
  select p.principal_id into strict v_principal
  from s2t_fhir.principal p
  where p.external_issuer='postgres-role'
    and p.external_subject='s2t_fhir_migrator' and p.disabled_at is null;
  select r.resource_config_id,bs.baseline_series_id into v_resource,v_series
  from s2t_fhir.mapping_resource_registry r
  join s2t_fhir.baseline_series bs
    on bs.source_system=r.source_system and bs.fhir_resource=r.fhir_resource
  where r.is_enabled
  order by r.resource_config_id,bs.baseline_series_id
  limit 1;
  if v_series is null then
    raise exception '026 runtime fixture requires one enabled registry/series pair';
  end if;
  insert into s2t_fhir.candidate_import_request(
    resource_config_id,baseline_series_id,uploader_principal_id,version_label,
    original_filename,declared_byte_size,idempotency_key,storage_object_key,current_state
  ) values (
    v_resource,v_series,v_principal,'T026-RUNTIME-'||pg_catalog.gen_random_uuid(),
    'T026-runtime.xlsx',1,pg_catalog.gen_random_uuid(),
    'candidate-import/T026-runtime-'||pg_catalog.gen_random_uuid()||'.xlsx','AWAITING_UPLOAD'
  ) returning candidate_import_request_id into v_one;
  insert into s2t_fhir.candidate_import_request(
    resource_config_id,baseline_series_id,uploader_principal_id,version_label,
    original_filename,declared_byte_size,idempotency_key,storage_object_key,current_state
  ) values (
    v_resource,v_series,v_principal,'T026-RUNTIME-'||pg_catalog.gen_random_uuid(),
    'T026-runtime.xlsx',1,pg_catalog.gen_random_uuid(),
    'candidate-import/T026-runtime-'||pg_catalog.gen_random_uuid()||'.xlsx','AWAITING_UPLOAD'
  ) returning candidate_import_request_id into v_two;
  insert into s2t_fhir.candidate_import_request_event(
    candidate_import_request_id,sequence_number,event_code,from_state,to_state,
    occurred_at,actor_principal_id,initiating_human_principal_id,correlation_id
  ) values
    (v_one,1,'REQUEST_CREATED',null,'AWAITING_UPLOAD',pg_catalog.transaction_timestamp(),
     v_principal,v_principal,pg_catalog.gen_random_uuid()),
    (v_two,1,'REQUEST_CREATED',null,'AWAITING_UPLOAD',pg_catalog.transaction_timestamp(),
     v_principal,v_principal,pg_catalog.gen_random_uuid());
  insert into pg_temp.test_026_context
  values(v_one,v_two,v_principal,v_resource,v_series);
end
$fixture$;

select pg_temp.test_026_record(7,'random relational UUID defaults',
  (select request_one is not null and request_two is not null and request_one<>request_two
   from pg_temp.test_026_context),
  'two default-generated request PKs are non-null and distinct');

do $allowed_transition$
declare v pg_temp.test_026_context%rowtype;
begin
  select * into strict v from pg_temp.test_026_context;
  perform s2t_fhir._transition_candidate_import_request(
    v.request_one,'AWAITING_UPLOAD','ABORTED','REQUEST_ABORTED',
    v.principal_id,v.principal_id,pg_catalog.gen_random_uuid(),
    'rollback-only runtime fixture');
  perform pg_temp.test_026_record(8,'allowed transition succeeds',
    (select current_state='ABORTED' from s2t_fhir.candidate_import_request
     where candidate_import_request_id=v.request_one),
    'AWAITING_UPLOAD -> ABORTED');
exception when others then
  perform pg_temp.test_026_record(8,'allowed transition succeeds',false,
    pg_catalog.format('unexpected SQLSTATE %s',sqlstate));
end
$allowed_transition$;

do $forbidden_transition$
declare v pg_temp.test_026_context%rowtype; v_state text;
begin
  select * into strict v from pg_temp.test_026_context;
  begin
    perform s2t_fhir._transition_candidate_import_request(
      v.request_two,'AWAITING_UPLOAD','READY_TO_PUBLISH','INVALID_TEST',
      v.principal_id,v.principal_id,pg_catalog.gen_random_uuid());
    perform pg_temp.test_026_record(9,'forbidden transition rejected',false,'unexpected success');
  exception when sqlstate '23514' then
    select current_state into v_state from s2t_fhir.candidate_import_request
    where candidate_import_request_id=v.request_two;
    perform pg_temp.test_026_record(9,'forbidden transition rejected',
      v_state='AWAITING_UPLOAD','SQLSTATE 23514; state unchanged');
  end;
end
$forbidden_transition$;

do $terminal_transition$
declare v pg_temp.test_026_context%rowtype;
begin
  select * into strict v from pg_temp.test_026_context;
  perform s2t_fhir._transition_candidate_import_request(
    v.request_two,'AWAITING_UPLOAD','ABORTED','REQUEST_ABORTED',
    v.principal_id,v.principal_id,pg_catalog.gen_random_uuid(),'terminal test');
  begin
    perform s2t_fhir._transition_candidate_import_request(
      v.request_two,'ABORTED','ABORTED','IDEMPOTENT_REPLAY',
      v.principal_id,v.principal_id,pg_catalog.gen_random_uuid());
    perform pg_temp.test_026_record(10,'terminal state immutable',false,'unexpected success');
  exception when sqlstate '55000' then
    perform pg_temp.test_026_record(10,'terminal state immutable',true,'ABORTED rejected with 55000');
  end;
end
$terminal_transition$;

do $append_update$
declare v pg_temp.test_026_context%rowtype;
begin
  select * into strict v from pg_temp.test_026_context;
  begin
    update s2t_fhir.candidate_import_request_event set reason='forbidden'
    where candidate_import_request_id=v.request_one and sequence_number=1;
    perform pg_temp.test_026_record(11,'event UPDATE rejected',false,'unexpected success');
  exception when others then
    perform pg_temp.test_026_record(11,'event UPDATE rejected',true,'append-only trigger rejected mutation');
  end;
end
$append_update$;

do $append_delete$
declare v pg_temp.test_026_context%rowtype;
begin
  select * into strict v from pg_temp.test_026_context;
  begin
    delete from s2t_fhir.candidate_import_request_event
    where candidate_import_request_id=v.request_one and sequence_number=1;
    perform pg_temp.test_026_record(12,'event DELETE rejected',false,'unexpected success');
  exception when others then
    perform pg_temp.test_026_record(12,'event DELETE rejected',true,'append-only trigger rejected mutation');
  end;
end
$append_delete$;

select pg_temp.test_026_record(13,'begin exact replay is idempotent',
  (select prosrc like '%idempotentReplay'', true%'
          and prosrc like '%idempotency_key = p_idempotency_key%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)')),
  'same actor/resource/idempotency key returns existing request');

select pg_temp.test_026_record(14,'begin changed replay conflicts',
  (select prosrc like '%idempotency key was already used with different input%'
          and prosrc like '%errcode = ''23505''%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)')),
  'changed payload classified IMPORT_CONFLICT/23505');

select pg_temp.test_026_record(15,'batch same-digest replay is idempotent',
  (select prosrc like '%batch_digest = p_batch_digest%'
          and prosrc like '%idempotentReplay'', true%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)')),
  'same request/attempt/batch/digest returns existing batch');

select pg_temp.test_026_record(16,'batch changed-digest replay conflicts',
  (select prosrc like '%staging batch replay digest differs%'
          and prosrc like '%errcode = ''23505''%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)')),
  'changed batch digest classified IMPORT_CONFLICT/23505');

select pg_temp.test_026_record(17,'upload capability is exact active grant projection',
  (select prosrc like '%S2T_BASELINE_UPLOAD%'
          and prosrc like '%effective_at <=%'
          and prosrc like '%revoked_at is null%'
          and prosrc like '%v_count > 1%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir._candidate_ui_upload_capability(uuid)'))
  and
  (select prosrc like '%_require_authenticated_baseline_capability(''S2T_BASELINE_UPLOAD'')%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)')),
  'zero=false, one=true, ambiguity fails closed; begin requires upload capability');

select pg_temp.test_026_record(18,'upload-only Candidate context is safely authorized',
  (select prosrc like '%not v_can_review and not v_can_promote and not v_can_upload%'
          and prosrc like '%_candidate_ui_snapshot%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.get_candidate_ui_context(text)')),
  'snapshot allowed by any exact review/promote/upload capability');

select pg_temp.test_026_record(19,'service helpers are browser-inaccessible',
  not exists (
    select 1 from (values
      ('s2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)'),
      ('s2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)'),
      ('s2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)'),
      ('s2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)'),
      ('s2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)')) x(signature)
    cross join (values('authenticated'),('anon')) r(role_name)
    where pg_catalog.has_function_privilege(r.role_name,
      pg_catalog.to_regprocedure(signature),'EXECUTE')),
  'authenticated and anon denied all five service helpers');

select pg_temp.test_026_record(20,'zero accepted rows are blocked',
  (select prosrc like '%v_accepted_count > 0%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)')),
  'CLEAN_IMPORT requires accepted_count > 0');

select pg_temp.test_026_record(21,'quarantined imports are blocked',
  (select prosrc like '%v_quarantined_count = 0%'
          and prosrc like '%VALIDATION_FAILED%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)')),
  'quarantine prevents READY_TO_PUBLISH');

select pg_temp.test_026_record(22,'warning-only imports are accepted',
  (select prosrc like '%v_warning_count > 0 then ''PASS_WITH_WARNINGS''%'
          and prosrc like '%VALIDATING'', ''READY_TO_PUBLISH''%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)')),
  'warnings select PASS_WITH_WARNINGS without failing CLEAN_IMPORT');

select pg_temp.test_026_record(23,'CLEAN_IMPORT is rechecked at publication',
  (select prosrc like '%candidate_count = vr.accepted_count%'
          and prosrc like '%accepted_count > 0%'
          and prosrc like '%error_count = 0%'
          and prosrc like '%quarantined_count = 0%'
          and prosrc like '%PASS_WITH_WARNINGS%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')),
  'publish independently requires PASS/PASS_WITH_WARNINGS clean evidence');

select pg_temp.test_026_record(24,'first Candidate publication delegates to shared primitive',
  (select prosrc like '%replace_current_candidate(%'
          and prosrc like '%p_expected_candidate_baseline_version_id%'
          and prosrc like '%p_expected_candidate_lifecycle_event_id%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')),
  'nullable expected pair is passed unchanged for first Candidate');

select pg_temp.test_026_record(25,'replacement Candidate uses governed reason path',
  (select prosrc like '%p_replacement_reason%'
          and prosrc like '%replace_current_candidate(%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')),
  'replacement reason is delegated to Migration 023 invariant');

select pg_temp.test_026_record(26,'stale Candidate is SQLSTATE 40001',
  (select prosrc like '%CANDIDATE_CHANGED%'
          and prosrc like '%errcode = ''40001''%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.begin_candidate_import(text,text,text,bigint,uuid,uuid,uuid)'))
  and
  (select prosrc like '%using errcode = ''40001''%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamp with time zone,text,uuid,uuid)')),
  'begin and shared publication primitive use serialization failure');

with checks as (
  select
    pg_catalog.strpos(prosrc,'update s2t_fhir.import_run')>0 update_present,
    pg_catalog.strpos(prosrc,'v_result := s2t_fhir.replace_current_candidate(')>
      pg_catalog.strpos(prosrc,'update s2t_fhir.import_run') publication_after_finalize,
    prosrc like '%IMPORT_RUN_STATUS%COMMITTED%' committed_status,
    prosrc like '%where ir.import_run_id = v_request.import_run_id%' request_import_scope,
    prosrc like '%ir.completed_at is null%'
      and prosrc like '%ir.terminal_status_value_id is null%' requires_open,
    prosrc like '%if not found then%exactly one open import must be finalized%' zero_row_rejected
  from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
    's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')
)
select pg_temp.test_026_record(27,'successful publication finalizes exactly one import',
  update_present and publication_after_finalize and committed_status
    and request_import_scope and requires_open and zero_row_rejected,
  pg_catalog.format(
    'update_present=%s publication_after_finalize=%s committed_status=%s request_import_scope=%s requires_open=%s zero_row_rejected=%s',
    update_present,publication_after_finalize,committed_status,
    request_import_scope,requires_open,zero_row_rejected))
from checks;

with checks as (
  select
    (select pg_catalog.strpos(prosrc,'update s2t_fhir.import_run')>0
              and pg_catalog.strpos(prosrc,
                    'v_result := s2t_fhir.replace_current_candidate(')>
                  pg_catalog.strpos(prosrc,'update s2t_fhir.import_run')
       from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
         's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')) update_before_delegate,
    (select prosrc like '%p_expected_candidate_baseline_version_id%'
              and prosrc like '%p_expected_candidate_lifecycle_event_id%'
       from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
         's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')) expected_pair_passed,
    (select prosrc !~* 'exception[[:space:]]+when'
       from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
         's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')) no_local_handler,
    (select prosrc like '%using errcode = ''40001''%'
       from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
         's2t_fhir.replace_current_candidate(uuid,uuid,uuid,uuid,timestamp with time zone,text,uuid,uuid)')) shared_40001
)
select pg_temp.test_026_record(28,'stale publication leaves no partial writes',
  update_before_delegate and expected_pair_passed and no_local_handler and shared_40001,
  pg_catalog.format(
    'update_before_delegate=%s expected_pair_passed=%s no_local_handler=%s shared_40001=%s',
    update_before_delegate,expected_pair_passed,no_local_handler,shared_40001))
from checks;

with checks as (
  select
    pg_catalog.strpos(prosrc,'if v_probe.current_state = ''PUBLISHED'' then')>0
      and pg_catalog.strpos(prosrc,'if v_probe.current_state = ''PUBLISHED'' then')<
          pg_catalog.strpos(prosrc,'update s2t_fhir.import_run') probe_before_mutation,
    pg_catalog.strpos(prosrc,'if v_request.current_state = ''PUBLISHED'' then')>0
      and pg_catalog.strpos(prosrc,'if v_request.current_state = ''PUBLISHED'' then')<
          pg_catalog.strpos(prosrc,'update s2t_fhir.import_run') locked_before_mutation,
    prosrc like '%newCandidateBaselineVersionId'', v_probe.baseline_version_id%'
      and prosrc like '%newCandidateLifecycleEventId'', v_probe.published_candidate_lifecycle_event_id%'
      probe_stored_ids,
    prosrc like '%newCandidateBaselineVersionId'', v_request.baseline_version_id%'
      and prosrc like '%newCandidateLifecycleEventId'', v_request.published_candidate_lifecycle_event_id%'
      locked_stored_ids,
    prosrc like '%idempotentReplay'', true%' replay_true
  from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
    's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')
)
select pg_temp.test_026_record(29,'PUBLISHED replay creates no duplicate writes',
  probe_before_mutation and locked_before_mutation
    and probe_stored_ids and locked_stored_ids and replay_true,
  pg_catalog.format(
    'probe_before_mutation=%s locked_before_mutation=%s probe_stored_ids=%s locked_stored_ids=%s replay_true=%s',
    probe_before_mutation,locked_before_mutation,
    probe_stored_ids,locked_stored_ids,replay_true))
from checks;

select pg_temp.test_026_record(30,'ACTIVE evidence is asserted unchanged',
  (select prosrc like '%v_active_baseline_after is distinct from v_active_baseline_before%'
          and prosrc like '%v_active_import_after is distinct from v_active_import_before%'
          and prosrc like '%v_mapping_count_after is distinct from v_mapping_count_before%'
          and prosrc like '%v_review_session_count_after is distinct from v_review_session_count_before%'
          and prosrc like '%v_review_event_count_after is distinct from v_review_event_count_before%'
   from pg_catalog.pg_proc where oid=pg_catalog.to_regprocedure(
     's2t_fhir_api.publish_candidate_import(uuid,uuid,uuid,text)')),
  'baseline, lifecycle, import, mapping, review session/event evidence compared');

select pg_temp.test_026_record(31,'F4B Candidate node identity remains unchanged',
  pg_catalog.pg_get_viewdef('s2t_fhir._mapping_identity_base'::regclass,true)
    like '%map-v%logical_key%'
  and pg_catalog.pg_get_viewdef('s2t_fhir._mapping_identity_base'::regclass,true)
    like '%sha256%',
  'node_id remains map-v<version>-<logical-key-sha256>');

select test_no,test_name,result,detail
from pg_temp.test_026_results
order by test_no;

select count(*) total_tests,
       count(*) filter (where result='PASS') pass_count,
       count(*) filter (where result='FAIL') fail_count,
       case when count(*)=31 and count(*) filter (where result='PASS')=31
                  and count(*) filter (where result='FAIL')=0
            then 'PASS' else 'FAIL' end overall_runtime_result
from pg_temp.test_026_results;

do $runtime_assert$
declare
  v_total integer;
  v_pass integer;
  v_fail integer;
  v_missing text;
  v_duplicates text;
  v_failed text;
begin
  select pg_catalog.string_agg(n::text,',' order by n) into v_missing
  from pg_catalog.generate_series(1,31) n
  where not exists (select 1 from pg_temp.test_026_results r where r.test_no=n);
  select pg_catalog.string_agg(test_no||'('||row_count||')',',' order by test_no)
    into v_duplicates
  from (select test_no,count(*) row_count from pg_temp.test_026_results
        group by test_no having count(*)<>1) duplicate_state;
  if v_missing is not null or v_duplicates is not null then
    raise exception using errcode='P0001',message=pg_catalog.format(
      'MIGRATION 026 RESULT NUMBER ASSERTION FAILED: missing=%s duplicates=%s',
      coalesce(v_missing,'none'),coalesce(v_duplicates,'none'));
  end if;
  select count(*),count(*) filter (where result='PASS'),
         count(*) filter (where result='FAIL')
    into v_total,v_pass,v_fail from pg_temp.test_026_results;
  select pg_catalog.string_agg(test_no||':'||test_name||':'||detail,'; ' order by test_no)
    into v_failed from pg_temp.test_026_results where result='FAIL';
  if v_total<>31 or v_pass<>31 or v_fail<>0 then
    raise exception using errcode='P0001',message=pg_catalog.format(
      'MIGRATION 026 RUNTIME ASSERTION FAILED: total=%s pass=%s fail=%s; failed_tests=%s',
      v_total,v_pass,v_fail,coalesce(v_failed,'none'));
  end if;
end
$runtime_assert$;

rollback;

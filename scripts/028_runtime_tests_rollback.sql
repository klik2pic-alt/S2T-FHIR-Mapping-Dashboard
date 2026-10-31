-- Migration 028 rollback-only runtime verification.
-- Run only after 028 postdeployment verification passes, in one session.
-- All application fixture mutations are enclosed by the outer transaction.

create temporary table test_028_restore_context (
  request_id uuid primary key,
  attempt_one uuid not null,
  attempt_two uuid not null,
  attempt_three uuid not null,
  artifact_digest bytea not null,
  request_count_before bigint not null,
  event_count_before bigint not null,
  baseline_count_before bigint not null,
  import_count_before bigint not null,
  artifact_count_before bigint not null,
  committed_fingerprint_before text not null
) on commit preserve rows;

insert into pg_temp.test_028_restore_context
select pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.decode(pg_catalog.md5(pg_catalog.gen_random_uuid()::text)||
                         pg_catalog.md5(pg_catalog.gen_random_uuid()::text),'hex'),
       (select count(*) from s2t_fhir.candidate_import_request),
       (select count(*) from s2t_fhir.candidate_import_request_event),
       (select count(*) from s2t_fhir.baseline_version),
       (select count(*) from s2t_fhir.import_run),
       (select count(*) from s2t_fhir.artifact),
       (select pg_catalog.md5(coalesce(
          pg_catalog.string_agg(fingerprint_row,E'\n' order by fingerprint_row),''))
        from (
          select 'request:'||r::text fingerprint_row
          from s2t_fhir.candidate_import_request r
          union all
          select 'event:'||e::text
          from s2t_fhir.candidate_import_request_event e
          union all
          select 'baseline:'||bv::text
          from s2t_fhir.baseline_version bv
          where exists (select 1 from s2t_fhir.candidate_import_request r
                        where r.baseline_version_id=bv.baseline_version_id)
          union all
          select 'baseline-artifact:'||ba::text
          from s2t_fhir.baseline_artifact ba
          where exists (select 1 from s2t_fhir.candidate_import_request r
                        where r.baseline_version_id=ba.baseline_version_id)
          union all
          select 'import:'||ir::text
          from s2t_fhir.import_run ir
          where exists (select 1 from s2t_fhir.candidate_import_request r
                        where r.import_run_id=ir.import_run_id)
          union all
          select 'artifact:'||a::text
          from s2t_fhir.artifact a
          where exists (select 1 from s2t_fhir.candidate_import_request r
                        where r.artifact_id=a.artifact_id)
          union all
          select 'artifact-location:'||al::text
          from s2t_fhir.artifact_location al
          where exists (select 1 from s2t_fhir.candidate_import_request r
                        where r.artifact_id=al.artifact_id)
        ) committed_candidate_import_rows);

grant select on pg_temp.test_028_restore_context to s2t_fhir_owner;

begin;
set local role s2t_fhir_owner;

create temporary table test_028_results (
  test_no integer primary key,
  test_name text not null,
  result text not null check (result in ('PASS','FAIL')),
  detail text not null
) on commit drop;

create function pg_temp.test_028_record(
  p_test_no integer,p_test_name text,p_pass boolean,p_detail text
) returns void language sql as $function$
  insert into pg_temp.test_028_results(test_no,test_name,result,detail)
  values (p_test_no,p_test_name,case when p_pass then 'PASS' else 'FAIL' end,p_detail);
$function$;

create temporary table test_028_fixture (
  request_id uuid primary key,
  uploader_principal_id uuid not null,
  service_actor_principal_id uuid not null,
  resource_config_id text not null,
  baseline_series_id uuid not null,
  attempt_one uuid not null,
  attempt_two uuid not null,
  attempt_three uuid not null,
  artifact_digest bytea not null,
  baseline_version_id uuid,
  import_run_id uuid
) on commit drop;

do $fixture$
declare
  v_restore pg_temp.test_028_restore_context%rowtype;
  v_uploader uuid;
  v_service_actor constant uuid := '2fb03b24-4795-4b19-bf54-b1359593e0d0'::uuid;
  v_uploader_kind text;
  v_service_actor_kind text;
  v_resource text;
  v_series uuid;
begin
  select * into strict v_restore from pg_temp.test_028_restore_context;

  select r.uploader_principal_id,r.resource_config_id,r.baseline_series_id,kind.value_code
    into v_uploader,v_resource,v_series,v_uploader_kind
  from s2t_fhir.candidate_import_request r
  join s2t_fhir.principal p on p.principal_id=r.uploader_principal_id
  join s2t_fhir.reference_value kind
    on kind.reference_value_id=p.principal_kind_value_id
  join s2t_fhir.reference_domain kind_domain
    on kind_domain.reference_domain_id=kind.reference_domain_id
  where p.disabled_at is null
    and kind_domain.domain_code='PRINCIPAL_KIND'
    and kind.value_code='HUMAN'
  order by r.created_at desc,r.candidate_import_request_id
  limit 1;
  if v_uploader is null or v_series is null then
    raise exception '028 runtime fixture requires an existing Candidate-import request with an active HUMAN uploader';
  end if;

  select kind.value_code into strict v_service_actor_kind
  from s2t_fhir.principal p
  join s2t_fhir.reference_value kind
    on kind.reference_value_id=p.principal_kind_value_id
  join s2t_fhir.reference_domain kind_domain
    on kind_domain.reference_domain_id=kind.reference_domain_id
  where p.principal_id=v_service_actor
    and p.disabled_at is null
    and kind_domain.domain_code='PRINCIPAL_KIND';
  if v_uploader_kind <> 'HUMAN' then
    raise exception '028 runtime fixture uploader % has kind %, expected HUMAN',
      v_uploader,v_uploader_kind using errcode='23514';
  end if;
  if v_service_actor_kind not in ('SERVICE','SYSTEM') then
    raise exception '028 runtime fixture service actor % has incompatible kind %',
      v_service_actor,v_service_actor_kind using errcode='23514';
  end if;
  if v_uploader=v_service_actor then
    raise exception '028 runtime fixture uploader and service actor must be distinct'
      using errcode='23514';
  end if;

  insert into s2t_fhir.candidate_import_request(
    candidate_import_request_id,resource_config_id,baseline_series_id,
    uploader_principal_id,version_label,original_filename,declared_byte_size,
    idempotency_key,storage_object_key,current_state
  ) values (
    v_restore.request_id,v_resource,v_series,v_uploader,
    'T028-RUNTIME-'||v_restore.request_id::text,'T028-runtime.xlsx',1,
    pg_catalog.gen_random_uuid(),
    'candidate-import/T028-runtime-'||v_restore.request_id::text||'.xlsx',
    'AWAITING_UPLOAD'
  );
  insert into s2t_fhir.candidate_import_request_event(
    candidate_import_request_id,sequence_number,event_code,from_state,to_state,
    occurred_at,actor_principal_id,initiating_human_principal_id,correlation_id
  ) values (
    v_restore.request_id,1,'REQUEST_CREATED',null,'AWAITING_UPLOAD',
    pg_catalog.transaction_timestamp(),v_service_actor,v_uploader,
    pg_catalog.gen_random_uuid()
  );
  insert into pg_temp.test_028_fixture values (
    v_restore.request_id,v_uploader,v_service_actor,v_resource,v_series,
    v_restore.attempt_one,v_restore.attempt_two,v_restore.attempt_three,
    v_restore.artifact_digest,null,null
  );

  perform s2t_fhir_api._service_accept_candidate_import_upload(
    v_restore.request_id,v_restore.artifact_digest,1,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    pg_catalog.transaction_timestamp(),v_service_actor,pg_catalog.gen_random_uuid());
end
$fixture$;

select pg_temp.test_028_record(1,'rollback-local request reaches UPLOADED',
  (select r.current_state='UPLOADED' and r.artifact_id is not null
      and uploader_kind.value_code='HUMAN'
      and service_kind.value_code in ('SERVICE','SYSTEM')
      and f.uploader_principal_id<>f.service_actor_principal_id
   from s2t_fhir.candidate_import_request r
   join pg_temp.test_028_fixture f on f.request_id=r.candidate_import_request_id
   join s2t_fhir.principal uploader
     on uploader.principal_id=f.uploader_principal_id
   join s2t_fhir.reference_value uploader_kind
     on uploader_kind.reference_value_id=uploader.principal_kind_value_id
   join s2t_fhir.principal service_actor
     on service_actor.principal_id=f.service_actor_principal_id
   join s2t_fhir.reference_value service_kind
     on service_kind.reference_value_id=service_actor.principal_kind_value_id),
  'HUMAN uploader and distinct service-compatible actor supplied the governed artifact link');

do $initial_start$
declare
  f pg_temp.test_028_fixture%rowtype;
  v_result jsonb;
begin
  select * into strict f from pg_temp.test_028_fixture;
  v_result := s2t_fhir_api._service_begin_candidate_import_validation(
    f.request_id,'T028-parser','1.0','CATO-MEDICATIONREQUEST-XLSX-v1',
    pg_catalog.decode(pg_catalog.repeat('28',32),'hex'),f.attempt_one,
    pg_catalog.transaction_timestamp()+interval '15 minutes',
    f.service_actor_principal_id,pg_catalog.gen_random_uuid());
  update pg_temp.test_028_fixture x
  set baseline_version_id=(v_result->>'baselineVersionId')::uuid,
      import_run_id=(v_result->>'importRunId')::uuid
  where x.request_id=f.request_id;
  perform pg_temp.test_028_record(2,'UPLOADED to VALIDATING succeeds atomically',
    v_result->>'state'='VALIDATING'
      and coalesce((v_result->>'idempotentReplay')::boolean,false)=false
      and (v_result->>'baselineVersionId') is not null
      and (v_result->>'importRunId') is not null,
    'state plus baseline/import/attempt/lease links were accepted');
exception when others then
  perform pg_temp.test_028_record(2,'UPLOADED to VALIDATING succeeds atomically',false,
    pg_catalog.format('unexpected SQLSTATE %s: %s',sqlstate,sqlerrm));
end
$initial_start$;

select pg_temp.test_028_record(3,'VALIDATING row has exact required link shape',
  (select r.current_state='VALIDATING'
      and r.artifact_id is not null
      and r.baseline_version_id=f.baseline_version_id
      and r.import_run_id=f.import_run_id
      and r.validation_attempt_id=f.attempt_one
      and r.validation_lease_expires_at>pg_catalog.transaction_timestamp()
      and r.validation_run_id is null
      and r.published_candidate_lifecycle_event_id is null
   from s2t_fhir.candidate_import_request r
   join pg_temp.test_028_fixture f on f.request_id=r.candidate_import_request_id),
  'candidate_import_request_link_shape_ck remains satisfied');

select pg_temp.test_028_record(4,'exactly one VALIDATION_STARTED event appended',
  (select count(*)=1 and min(from_state)='UPLOADED' and min(to_state)='VALIDATING'
   from s2t_fhir.candidate_import_request_event e
   join pg_temp.test_028_fixture f
     on f.request_id=e.candidate_import_request_id
   where e.event_code='VALIDATION_STARTED'),
  'one append-only state-history event');

do $exact_replay$
declare f pg_temp.test_028_fixture%rowtype; v_result jsonb; v_events bigint;
begin
  select * into strict f from pg_temp.test_028_fixture;
  v_result := s2t_fhir_api._service_begin_candidate_import_validation(
    f.request_id,'T028-parser','1.0','CATO-MEDICATIONREQUEST-XLSX-v1',
    pg_catalog.decode(pg_catalog.repeat('28',32),'hex'),f.attempt_one,
    pg_catalog.transaction_timestamp()+interval '15 minutes',
    f.service_actor_principal_id,pg_catalog.gen_random_uuid());
  select count(*) into v_events from s2t_fhir.candidate_import_request_event e
  where e.candidate_import_request_id=f.request_id and e.event_code='VALIDATION_STARTED';
  perform pg_temp.test_028_record(5,'same-attempt replay is idempotent',
    coalesce((v_result->>'idempotentReplay')::boolean,false)
      and (v_result->>'baselineVersionId')::uuid=f.baseline_version_id
      and (v_result->>'importRunId')::uuid=f.import_run_id and v_events=1,
    'same links returned; no second VALIDATION_STARTED event');
end
$exact_replay$;

do $active_lease$
declare f pg_temp.test_028_fixture%rowtype;
begin
  select * into strict f from pg_temp.test_028_fixture;
  begin
    perform s2t_fhir_api._service_begin_candidate_import_validation(
      f.request_id,'T028-parser','1.0','CATO-MEDICATIONREQUEST-XLSX-v1',
      pg_catalog.decode(pg_catalog.repeat('28',32),'hex'),f.attempt_two,
      pg_catalog.transaction_timestamp()+interval '15 minutes',
      f.service_actor_principal_id,pg_catalog.gen_random_uuid());
    perform pg_temp.test_028_record(6,'active lease fences another attempt',false,
      'unexpected success');
  exception when sqlstate '23505' then
    perform pg_temp.test_028_record(6,'active lease fences another attempt',true,
      'SQLSTATE 23505; active attempt retained');
  end;
end
$active_lease$;

do $reclaim$
declare f pg_temp.test_028_fixture%rowtype; v_result jsonb; v_started bigint; v_reclaimed bigint;
begin
  select * into strict f from pg_temp.test_028_fixture;
  update s2t_fhir.candidate_import_request r
  set validation_lease_expires_at=pg_catalog.transaction_timestamp()-interval '1 second'
  where r.candidate_import_request_id=f.request_id;
  v_result := s2t_fhir_api._service_begin_candidate_import_validation(
    f.request_id,'T028-parser','1.0','CATO-MEDICATIONREQUEST-XLSX-v1',
    pg_catalog.decode(pg_catalog.repeat('28',32),'hex'),f.attempt_three,
    pg_catalog.transaction_timestamp()+interval '15 minutes',
    f.service_actor_principal_id,pg_catalog.gen_random_uuid());
  select count(*) filter (where event_code='VALIDATION_STARTED'),
         count(*) filter (where event_code='VALIDATION_RECLAIMED')
    into v_started,v_reclaimed
  from s2t_fhir.candidate_import_request_event e
  where e.candidate_import_request_id=f.request_id;
  perform pg_temp.test_028_record(7,'expired lease reclaim preserves created links',
    coalesce((v_result->>'reclaimed')::boolean,false)
      and (v_result->>'baselineVersionId')::uuid=f.baseline_version_id
      and (v_result->>'importRunId')::uuid=f.import_run_id
      and v_started=1 and v_reclaimed=1
      and (select count(*)=1 from s2t_fhir.baseline_version bv
           where bv.baseline_code='CANDIDATE-IMPORT-'||f.request_id::text)
      and (select count(*)=1 from s2t_fhir.import_run ir
           where ir.import_run_id=f.import_run_id),
    'one baseline/import; one start event; one reclaim event');
end
$reclaim$;

do $invalid_shape$
declare f pg_temp.test_028_fixture%rowtype; v_state text;
begin
  select * into strict f from pg_temp.test_028_fixture;
  begin
    update s2t_fhir.candidate_import_request r set current_state='UPLOADED'
    where r.candidate_import_request_id=f.request_id;
    perform pg_temp.test_028_record(8,'invalid state/link shape remains rejected',false,
      'unexpected success');
  exception when sqlstate '23514' then
    select current_state into strict v_state
    from s2t_fhir.candidate_import_request r
    where r.candidate_import_request_id=f.request_id;
    perform pg_temp.test_028_record(8,'invalid state/link shape remains rejected',
      v_state='VALIDATING','SQLSTATE 23514; row unchanged');
  end;
end
$invalid_shape$;

with updated as (
  update s2t_fhir.candidate_import_request r
  set updated_at=r.updated_at
  from pg_temp.test_028_fixture f
  where r.candidate_import_request_id=f.request_id
  returning r.candidate_import_request_id
)
select pg_temp.test_028_record(9,'request trigger accepts a no-op valid projection update',
  (select count(*)=1 from updated),
  'constraint and validate_candidate_import_request trigger both accept the final row');

select test_no,test_name,result,detail
from pg_temp.test_028_results
order by test_no;

select count(*) total_tests,
       count(*) filter (where result='PASS') pass_count,
       count(*) filter (where result='FAIL') fail_count,
       case when count(*)=9 and count(*) filter (where result='PASS')=9
                  and count(*) filter (where result='FAIL')=0
            then 'PASS' else 'FAIL' end overall_runtime_result
from pg_temp.test_028_results;

-- Capture all transaction-local result state as literals in a session-scoped
-- prepared statement. SQL Editor may include statements before BEGIN in the
-- same implicit transaction, so a temp relation is not a safe bridge across
-- the ROLLBACK. The prepared statement contains no temp-object references.
do $prepare_postrollback_verification$
declare
  c pg_temp.test_028_restore_context%rowtype;
  v_total integer;
  v_pass integer;
  v_fail integer;
  v_failed_tests text;
begin
  select * into strict c from pg_temp.test_028_restore_context;
  select count(*),count(*) filter (where result='PASS'),
         count(*) filter (where result='FAIL')
    into v_total,v_pass,v_fail
  from pg_temp.test_028_results;
  select pg_catalog.string_agg(
           test_no||':'||test_name||':'||detail,'; ' order by test_no)
    into v_failed_tests
  from pg_temp.test_028_results
  where result='FAIL';

  if exists (select 1 from pg_catalog.pg_prepared_statements
             where name='test_028_postrollback_verification') then
    execute 'deallocate test_028_postrollback_verification';
  end if;

  execute pg_catalog.format($prepared_sql$
    prepare test_028_postrollback_verification as
    with after_fingerprint as (
      select pg_catalog.md5(coalesce(
        pg_catalog.string_agg(fingerprint_row,E'\n' order by fingerprint_row),''))
        as committed_fingerprint_after
      from (
        select 'request:'||r::text fingerprint_row
        from s2t_fhir.candidate_import_request r
        union all
        select 'event:'||e::text
        from s2t_fhir.candidate_import_request_event e
        union all
        select 'baseline:'||bv::text
        from s2t_fhir.baseline_version bv
        where exists (select 1 from s2t_fhir.candidate_import_request r
                      where r.baseline_version_id=bv.baseline_version_id)
        union all
        select 'baseline-artifact:'||ba::text
        from s2t_fhir.baseline_artifact ba
        where exists (select 1 from s2t_fhir.candidate_import_request r
                      where r.baseline_version_id=ba.baseline_version_id)
        union all
        select 'import:'||ir::text
        from s2t_fhir.import_run ir
        where exists (select 1 from s2t_fhir.candidate_import_request r
                      where r.import_run_id=ir.import_run_id)
        union all
        select 'artifact:'||a::text
        from s2t_fhir.artifact a
        where exists (select 1 from s2t_fhir.candidate_import_request r
                      where r.artifact_id=a.artifact_id)
        union all
        select 'artifact-location:'||al::text
        from s2t_fhir.artifact_location al
        where exists (select 1 from s2t_fhir.candidate_import_request r
                      where r.artifact_id=al.artifact_id)
      ) committed_candidate_import_rows
    ), restoration as (
      select
        not exists (
          select 1 from s2t_fhir.candidate_import_request r
          where r.candidate_import_request_id=%1$L::uuid) request_absent,
        not exists (
          select 1 from s2t_fhir.candidate_import_request_event e
          where e.candidate_import_request_id=%1$L::uuid) event_absent,
        not exists (
          select 1 from s2t_fhir.baseline_version bv
          where bv.baseline_code='CANDIDATE-IMPORT-'||%1$L) baseline_absent,
        not exists (
          select 1 from s2t_fhir.import_run ir
          join s2t_fhir.baseline_version bv using(baseline_version_id)
          where bv.baseline_code='CANDIDATE-IMPORT-'||%1$L) import_absent,
        (select count(*) from s2t_fhir.candidate_import_request)=%2$s::bigint
          as request_count_restored,
        (select count(*) from s2t_fhir.candidate_import_request_event)=%3$s::bigint
          as event_count_restored,
        (select count(*) from s2t_fhir.baseline_version)=%4$s::bigint
          as baseline_count_restored,
        (select count(*) from s2t_fhir.import_run)=%5$s::bigint
          as import_count_restored,
        (select count(*) from s2t_fhir.artifact)=%6$s::bigint
          as artifact_count_restored
    )
    select
      case when %8$s=9 and %9$s=9 and %10$s=0
             and r.request_absent and r.event_absent
             and r.baseline_absent and r.import_absent
             and r.request_count_restored and r.event_count_restored
             and r.baseline_count_restored and r.import_count_restored
             and r.artifact_count_restored
             and a.committed_fingerprint_after=%7$L
           then 'PASS' else 'FAIL' end as overall_runtime_and_rollback_result,
      %8$s::integer as total_tests,
      %9$s::integer as pass_count,
      %10$s::integer as fail_count,
      %11$L::text as failed_tests,
      r.request_absent as synthetic_request_absent,
      r.event_absent as synthetic_event_absent,
      r.baseline_absent as synthetic_baseline_absent,
      r.import_absent as synthetic_import_absent,
      %7$L::text as committed_fingerprint_before,
      a.committed_fingerprint_after,
      a.committed_fingerprint_after=%7$L as committed_fingerprint_restored
    from restoration r cross join after_fingerprint a
  $prepared_sql$,
    c.request_id,c.request_count_before,c.event_count_before,
    c.baseline_count_before,c.import_count_before,c.artifact_count_before,
    c.committed_fingerprint_before,v_total,v_pass,v_fail,
    coalesce(v_failed_tests,'none'));
end
$prepare_postrollback_verification$;

rollback;

-- RUN B: this statement contains only captured literals and persistent-table
-- reads, so it remains executable after all transaction-local temp objects
-- and fixture rows have been rolled back.
execute test_028_postrollback_verification;
deallocate test_028_postrollback_verification;

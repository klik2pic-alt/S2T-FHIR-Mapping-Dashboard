-- Migration 029 rollback-only runtime verification.
-- Run only after the 029 postdeploy verifier passes, in one session.

create temporary table test_029_restore_context (
  request_a uuid primary key,
  request_b uuid not null,
  request_c uuid not null,
  request_d uuid not null,
  attempt_a1 uuid not null,
  attempt_a2 uuid not null,
  attempt_b1 uuid not null,
  attempt_b2 uuid not null,
  attempt_c1 uuid not null,
  attempt_c2 uuid not null,
  attempt_d1 uuid not null,
  attempt_d2 uuid not null,
  artifact_digest bytea not null,
  committed_fingerprint_before text not null
) on commit preserve rows;

insert into pg_temp.test_029_restore_context
select pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.gen_random_uuid(),pg_catalog.gen_random_uuid(),
       pg_catalog.decode(pg_catalog.md5(pg_catalog.gen_random_uuid()::text)||
                         pg_catalog.md5(pg_catalog.gen_random_uuid()::text),'hex'),
       (select pg_catalog.md5(coalesce(pg_catalog.string_agg(fingerprint_row,E'\n'
          order by fingerprint_row),''))
        from (
          select 'request:'||r::text fingerprint_row
          from s2t_fhir.candidate_import_request r
          union all select 'event:'||e::text
          from s2t_fhir.candidate_import_request_event e
          union all select 'batch:'||b::text
          from s2t_fhir.candidate_import_staging_batch b
          union all select 'manifest:'||m::text
          from s2t_fhir.artifact_sheet_manifest m
          union all select 'candidate:'||c::text
          from s2t_fhir.import_candidate_row c
          union all select 'mapping:'||m::text
          from s2t_fhir.mapping_record m
          union all select 'validation:'||v::text
          from s2t_fhir.validation_run v
        ) committed_rows);

grant select on pg_temp.test_029_restore_context to s2t_fhir_owner;

begin;
set local role s2t_fhir_owner;

create temporary table test_029_results (
  test_no integer primary key,
  test_name text not null,
  result text not null check(result in ('PASS','FAIL')),
  detail text not null
) on commit drop;

create function pg_temp.test_029_record(
  p_test_no integer,p_test_name text,p_pass boolean,p_detail text
) returns void language sql as $function$
  insert into pg_temp.test_029_results(test_no,test_name,result,detail)
  values(p_test_no,p_test_name,case when p_pass then 'PASS' else 'FAIL' end,p_detail);
$function$;

create temporary table test_029_fixture (
  label text primary key,
  request_id uuid not null,
  attempt_one uuid not null,
  attempt_two uuid not null,
  uploader_id uuid not null,
  service_actor_id uuid not null,
  baseline_version_id uuid not null,
  import_run_id uuid not null
) on commit drop;

create function pg_temp.test_029_row(p_row integer,p_hex text)
returns jsonb language sql immutable as $function$
  select pg_catalog.jsonb_build_object(
    'sourceSheetName','T029',
    'sourceRowNumber',p_row,
    'sourceCellRange','A'||p_row::text||':Q'||p_row::text,
    'rawSchemaId','candidate-import-raw-row',
    'rawSchemaVersion','v1',
    'rawSourceRow',pg_catalog.jsonb_build_object(
      'schema','candidate-import-raw-row-v1','sheet','T029','row',p_row,
      'range','A'||p_row::text||':Q'||p_row::text,
      'cells',pg_catalog.jsonb_build_object('marker',p_hex)),
    'sourceRowHash',pg_catalog.repeat(p_hex,64),
    'normalizationAlgorithmVersion','nfkc-ws-v1',
    'mappingKind','ELEMENT_MAPPING',
    'candidateDisposition','ACCEPTED',
    'decisionStatus','FINAL',
    'logicalKeyAlgorithmVersion','v1',
    'logicalKey','me:v1:'||pg_catalog.repeat(p_hex,64),
    'logicalKeyComponents',pg_catalog.jsonb_build_object(
      'mappingKind','ELEMENT_MAPPING','sourceSystem','CATO',
      'fhirResource','MedicationRequest','targetFhirPath','medicationrequest.test'||p_row,
      'sourceSystemRaw','cato','interfaceType','xml','interfaceName','test',
      'sourceExpression','field-'||p_row,'fixedValue','',
      'canonicalTuple',pg_catalog.jsonb_build_array(
        'ELEMENT_MAPPING','CATO','MedicationRequest','medicationrequest.test'||p_row,
        'cato','xml','test','field-'||p_row,'')),
    'subtype',pg_catalog.jsonb_build_object(
      'targetFhirPath','MedicationRequest.test'||p_row,
      'sourceSystemRaw','CATO','interfaceType','XML','interfaceName','test',
      'sourceExpression','field-'||p_row,'profileContext','',
      'fixedValue','','transformationRule','','sourceBusinessDefinition','',
      'cardinalityRaw','0..1','cardinalityMin',0,'cardinalityMax',1,
      'cardinalityMaxUnbounded',false,'valuesetBinding','',
      'mandatedCodeSystem','','irrelevantUnderS2tRaw','','exampleValue','',
      'exceptionHandling','','notes','')
  );
$function$;

create function pg_temp.test_029_manifest(p_candidate_count integer)
returns jsonb language sql immutable as $function$
  select pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'sheetName','T029','sheetOrder',1,'classification','AUTHORITATIVE',
    'isPresent',true,'isAuthoritative',true,'headerRowNumber',1,
    'candidateRange','A2:Q'||(p_candidate_count+1)::text,
    'governedColumnRange','A:Q','candidateRowCount',p_candidate_count,
    'notes',null));
$function$;

do $fixture$
declare
  c pg_temp.test_029_restore_context%rowtype;
  v_uploader uuid;
  v_service constant uuid := '2fb03b24-4795-4b19-bf54-b1359593e0d0'::uuid;
  v_resource text;
  v_series uuid;
  v_request uuid;
  v_attempt_one uuid;
  v_attempt_two uuid;
  v_label text;
  v_begin jsonb;
begin
  select * into strict c from pg_temp.test_029_restore_context;
  select r.uploader_principal_id,r.resource_config_id,r.baseline_series_id
    into v_uploader,v_resource,v_series
  from s2t_fhir.candidate_import_request r
  join s2t_fhir.principal p on p.principal_id=r.uploader_principal_id
  join s2t_fhir.reference_value kind on kind.reference_value_id=p.principal_kind_value_id
  join s2t_fhir.reference_domain domain on domain.reference_domain_id=kind.reference_domain_id
  where p.disabled_at is null and domain.domain_code='PRINCIPAL_KIND'
    and kind.value_code='HUMAN'
  order by r.created_at desc limit 1;
  if v_uploader is null then
    raise exception '029 runtime requires one active HUMAN Candidate-import uploader';
  end if;

  for v_label,v_request,v_attempt_one,v_attempt_two in
    select * from (values
      ('A',c.request_a,c.attempt_a1,c.attempt_a2),
      ('B',c.request_b,c.attempt_b1,c.attempt_b2),
      ('C',c.request_c,c.attempt_c1,c.attempt_c2),
      ('D',c.request_d,c.attempt_d1,c.attempt_d2)
    ) x(label,request_id,attempt_one,attempt_two)
  loop
    insert into s2t_fhir.candidate_import_request(
      candidate_import_request_id,resource_config_id,baseline_series_id,
      uploader_principal_id,version_label,original_filename,declared_byte_size,
      idempotency_key,storage_object_key,current_state
    ) values (
      v_request,v_resource,v_series,v_uploader,
      'T029-RUNTIME-'||v_label||'-'||v_request::text,'T029-runtime.xlsx',1,
      pg_catalog.gen_random_uuid(),'candidate-import/T029-'||v_request::text||'.xlsx',
      'AWAITING_UPLOAD');
    insert into s2t_fhir.candidate_import_request_event(
      candidate_import_request_id,sequence_number,event_code,from_state,to_state,
      occurred_at,actor_principal_id,initiating_human_principal_id,correlation_id
    ) values (v_request,1,'REQUEST_CREATED',null,'AWAITING_UPLOAD',
      pg_catalog.transaction_timestamp(),v_service,v_uploader,pg_catalog.gen_random_uuid());
    perform s2t_fhir_api._service_accept_candidate_import_upload(
      v_request,c.artifact_digest,1,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      pg_catalog.transaction_timestamp(),v_service,pg_catalog.gen_random_uuid());
    v_begin:=s2t_fhir_api._service_begin_candidate_import_validation(
      v_request,'exceljs','4.4.0','CATO-MEDICATIONREQUEST-XLSX-v1',
      pg_catalog.decode(pg_catalog.repeat('29',32),'hex'),v_attempt_one,
      pg_catalog.transaction_timestamp()+interval '15 minutes',
      v_service,pg_catalog.gen_random_uuid());
    insert into pg_temp.test_029_fixture values(
      v_label,v_request,v_attempt_one,v_attempt_two,v_uploader,v_service,
      (v_begin->>'baselineVersionId')::uuid,(v_begin->>'importRunId')::uuid);
  end loop;
end
$fixture$;

-- A/G/N: fresh staging, same-attempt replay, and active-lease fencing.
do $fresh_a$
declare f pg_temp.test_029_fixture%rowtype; v_rows jsonb; v_result jsonb;
begin
  select * into strict f from pg_temp.test_029_fixture where label='A';
  v_rows:=pg_catalog.jsonb_build_array(pg_temp.test_029_row(2,'a'));
  perform s2t_fhir_api._service_stage_candidate_import_batch(
    f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
    v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  v_result:=s2t_fhir_api._service_stage_candidate_import_batch(
    f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
    v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  perform pg_temp.test_029_record(7,'same-attempt exact batch replay',
    coalesce((v_result->>'idempotentReplay')::boolean,false)
      and (select count(*)=1 from s2t_fhir.candidate_import_staging_batch b
           where b.candidate_import_request_id=f.request_id),
    'one root batch; second call returned idempotently');
  begin
    perform s2t_fhir_api._service_begin_candidate_import_validation(
      f.request_id,'exceljs','4.4.0','CATO-MEDICATIONREQUEST-XLSX-v1',
      pg_catalog.decode(pg_catalog.repeat('29',32),'hex'),f.attempt_two,
      pg_catalog.transaction_timestamp()+interval '15 minutes',
      f.service_actor_id,pg_catalog.gen_random_uuid());
    perform pg_temp.test_029_record(14,'active lease rejects competing attempt',false,'unexpected success');
  exception when sqlstate '23505' then
    perform pg_temp.test_029_record(14,'active lease rejects competing attempt',true,'SQLSTATE 23505');
  end;
  v_result:=s2t_fhir_api._service_complete_candidate_import_validation(
    f.request_id,f.attempt_one,pg_temp.test_029_manifest(1),'[]'::jsonb,
    '{"candidateCount":1,"acceptedCount":1,"warningCount":0,"errorCount":0,"quarantinedCount":0}'::jsonb,
    pg_catalog.decode(pg_catalog.repeat('12',32),'hex'),f.service_actor_id,
    pg_catalog.gen_random_uuid());
  perform pg_temp.test_029_record(1,'fresh first validation completes',
    v_result->>'state'='READY_TO_PUBLISH'
      and coalesce((v_result->>'artifactManifestReused')::boolean,true)=false,
    'fresh root batch, manifest, validation and transition committed inside rollback');
end
$fresh_a$;

-- The production helper runs in its own transaction. Restore the harness's
-- outer transaction to the normal initially-deferred mode before exercising
-- another synthetic request.
set constraints all deferred;

-- D: reclaim before any staging.
do $reclaim_d$
declare f pg_temp.test_029_fixture%rowtype; v_result jsonb;
begin
  select * into strict f from pg_temp.test_029_fixture where label='D';
  update s2t_fhir.candidate_import_request set
    validation_lease_expires_at=pg_catalog.transaction_timestamp()-interval '1 second'
  where candidate_import_request_id=f.request_id;
  v_result:=s2t_fhir_api._service_begin_candidate_import_validation(
    f.request_id,'exceljs','4.4.0','CATO-MEDICATIONREQUEST-XLSX-v1',
    pg_catalog.decode(pg_catalog.repeat('29',32),'hex'),f.attempt_two,
    pg_catalog.transaction_timestamp()+interval '15 minutes',
    f.service_actor_id,pg_catalog.gen_random_uuid());
  perform pg_temp.test_029_record(4,'reclaim before staging',
    coalesce((v_result->>'reclaimed')::boolean,false)
      and not exists(select 1 from s2t_fhir.candidate_import_staging_batch b
                     where b.candidate_import_request_id=f.request_id),
    'links reused; zero batch evidence');
end
$reclaim_d$;

-- B: fully stage attempt one, exercise mismatch guards, then reclaim/reuse.
do $stage_b_guards$
declare
  f pg_temp.test_029_fixture%rowtype;
  v_rows jsonb;
  v_changed jsonb;
  v_digest_ok boolean:=false;
  v_size_ok boolean:=false;
begin
  select * into strict f from pg_temp.test_029_fixture where label='B';
  v_rows:=pg_catalog.jsonb_build_array(pg_temp.test_029_row(2,'a'));
  perform s2t_fhir_api._service_stage_candidate_import_batch(
    f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
    v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  begin
    perform s2t_fhir_api._service_stage_candidate_import_batch(
      f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('22',32),'hex'),
      v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  exception when sqlstate '23514' then
    v_digest_ok:=sqlerrm like 'BATCH_DIGEST_MISMATCH:%';
  end;
  begin
    perform s2t_fhir_api._service_stage_candidate_import_batch(
      f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
      v_rows||v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  exception when sqlstate '23514' then
    v_size_ok:=sqlerrm like 'BATCH_DIGEST_MISMATCH:%';
  end;
  perform pg_temp.test_029_record(10,'digest count and size mismatch fail closed',
    v_digest_ok and v_size_ok,'fixed BATCH_DIGEST_MISMATCH code');

  v_changed:=pg_catalog.jsonb_set(v_rows,'{0,rawSourceRow,cells,marker}','"b"'::jsonb);
  begin
    perform s2t_fhir_api._service_stage_candidate_import_batch(
      f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
      v_changed,f.service_actor_id,pg_catalog.gen_random_uuid());
    perform pg_temp.test_029_record(11,'row hash and raw replay mismatch fails closed',false,'unexpected success');
  exception when sqlstate '23514' then
    perform pg_temp.test_029_record(11,'row hash and raw replay mismatch fails closed',
      sqlerrm like 'IMPORTED_ROW_REPLAY_MISMATCH:%','fixed imported-row code');
  end;

  v_changed:=pg_catalog.jsonb_set(
    v_rows,'{0,subtype,interfaceType}','"CSV"'::jsonb);
  begin
    if pg_catalog.pg_column_size(v_changed) <> pg_catalog.pg_column_size(v_rows) then
      raise exception '029 runtime setup: equal-size subtype mismatch payload drifted'
        using errcode='P0001';
    end if;
    perform s2t_fhir_api._service_stage_candidate_import_batch(
      f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
      v_changed,f.service_actor_id,pg_catalog.gen_random_uuid());
    perform pg_temp.test_029_record(12,'mapping subtype mismatch fails closed',false,'unexpected success');
  exception when sqlstate '23514' then
    perform pg_temp.test_029_record(12,'mapping subtype mismatch fails closed',
      sqlerrm like 'IMPORTED_ROW_REPLAY_MISMATCH:%',
      'equal-size replay payload changed interfaceType XML to CSV; persisted subtype untouched');
  end;

  begin
    insert into s2t_fhir.import_candidate_row(
      import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,
      source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,
      source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,
      candidate_disposition_value_id,calculated_logical_key,logical_key_components_json)
    select f.import_run_id,kind.reference_value_id,'T029',99,'A99:Q99',
      'candidate-import-raw-row','v1',
      '{"sheet":"T029","row":99,"range":"A99:Q99","cells":{}}'::jsonb,
      pg_catalog.decode(pg_catalog.repeat('f',64),'hex'),'nfkc-ws-v1','v1',
      disposition.reference_value_id,'me:v1:'||pg_catalog.repeat('f',64),'{}'::jsonb
    from s2t_fhir.reference_value kind
    join s2t_fhir.reference_domain kd on kd.reference_domain_id=kind.reference_domain_id
    cross join s2t_fhir.reference_value disposition
    join s2t_fhir.reference_domain dd on dd.reference_domain_id=disposition.reference_domain_id
    where kd.domain_code='MAPPING_KIND' and kind.value_code='ELEMENT_MAPPING'
      and dd.domain_code='CANDIDATE_DISPOSITION' and disposition.value_code='QUARANTINED';
    perform s2t_fhir_api._service_stage_candidate_import_batch(
      f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
      v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
    perform pg_temp.test_029_record(13,'unexpected extra materialized evidence rejected',false,'unexpected success');
  exception when sqlstate '23514' then
    perform pg_temp.test_029_record(13,'unexpected extra materialized evidence rejected',
      sqlerrm like 'STAGING_REPLAY_MISMATCH:%','global root-row totals rejected extra row');
  end;
end
$stage_b_guards$;

do $manifest_mismatch_b$
declare f pg_temp.test_029_fixture%rowtype;
begin
  select * into strict f from pg_temp.test_029_fixture where label='B';
  begin
    perform s2t_fhir_api._service_complete_candidate_import_validation(
      f.request_id,f.attempt_one,pg_temp.test_029_manifest(2),'[]'::jsonb,
      '{"candidateCount":1,"acceptedCount":1,"warningCount":0,"errorCount":0,"quarantinedCount":0}'::jsonb,
      pg_catalog.decode(pg_catalog.repeat('12',32),'hex'),f.service_actor_id,
      pg_catalog.gen_random_uuid());
    perform pg_temp.test_029_record(3,'manifest mismatch fails closed',false,'unexpected success');
  exception when sqlstate '23514' then
    perform pg_temp.test_029_record(3,'manifest mismatch fails closed',
      sqlerrm like 'ARTIFACT_MANIFEST_MISMATCH:%','fixed manifest mismatch code');
  end;
end
$manifest_mismatch_b$;

do $recover_b$
declare f pg_temp.test_029_fixture%rowtype; v_rows jsonb; v_result jsonb; v_root uuid;
begin
  select * into strict f from pg_temp.test_029_fixture where label='B';
  update s2t_fhir.candidate_import_request set
    validation_lease_expires_at=pg_catalog.transaction_timestamp()-interval '1 second'
  where candidate_import_request_id=f.request_id;
  perform s2t_fhir_api._service_begin_candidate_import_validation(
    f.request_id,'exceljs','4.4.0','CATO-MEDICATIONREQUEST-XLSX-v1',
    pg_catalog.decode(pg_catalog.repeat('29',32),'hex'),f.attempt_two,
    pg_catalog.transaction_timestamp()+interval '15 minutes',
    f.service_actor_id,pg_catalog.gen_random_uuid());
  perform pg_temp.test_029_record(6,'reclaim after all batches before completion',
    (select count(*)=1 from s2t_fhir.candidate_import_staging_batch b
     where b.candidate_import_request_id=f.request_id and b.validation_attempt_id=f.attempt_one)
      and (select validation_attempt_id=f.attempt_two
           from s2t_fhir.candidate_import_request where candidate_import_request_id=f.request_id),
    'one historical root batch retained; new attempt owns lease');
  v_rows:=pg_catalog.jsonb_build_array(pg_temp.test_029_row(2,'a'));
  v_result:=s2t_fhir_api._service_stage_candidate_import_batch(
    f.request_id,f.attempt_two,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
    v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  perform pg_temp.test_029_record(8,'cross-attempt exact replay reuses materialization',
    coalesce((v_result->>'materializedRowsReused')::boolean,false)
      and (select count(*)=1 from s2t_fhir.import_candidate_row c
           where c.import_run_id=f.import_run_id),
    'new batch evidence; one persisted candidate');
  select b.candidate_import_staging_batch_id into strict v_root
  from s2t_fhir.candidate_import_staging_batch b
  where b.candidate_import_request_id=f.request_id
    and b.validation_attempt_id=f.attempt_one and b.reused_from_staging_batch_id is null;
  perform pg_temp.test_029_record(9,'replay provenance points directly to root',
    (select count(*)=1 and bool_and(reused_from_staging_batch_id=v_root)
     from s2t_fhir.candidate_import_staging_batch b
     where b.candidate_import_request_id=f.request_id
       and b.validation_attempt_id=f.attempt_two),
    'attempt-two batch references attempt-one materializing root');
  v_result:=s2t_fhir_api._service_complete_candidate_import_validation(
    f.request_id,f.attempt_two,pg_temp.test_029_manifest(1),'[]'::jsonb,
    '{"candidateCount":1,"acceptedCount":1,"warningCount":0,"errorCount":0,"quarantinedCount":0}'::jsonb,
    pg_catalog.decode(pg_catalog.repeat('12',32),'hex'),f.service_actor_id,
    pg_catalog.gen_random_uuid());
  perform pg_temp.test_029_record(2,'identical artifact manifest is reused',
    coalesce((v_result->>'artifactManifestReused')::boolean,false)
      and (select count(*)=1 from s2t_fhir.artifact_sheet_manifest m
           join s2t_fhir.candidate_import_request r on r.artifact_id=m.artifact_id
           where r.candidate_import_request_id=f.request_id),
    'shared immutable artifact retained one exact manifest row');
  perform pg_temp.test_029_record(16,'fully staged reclaimed request completes',
    v_result->>'state'='READY_TO_PUBLISH'
      and (select current_state='READY_TO_PUBLISH' and validation_run_id is not null
           from s2t_fhir.candidate_import_request where candidate_import_request_id=f.request_id),
    'normal validate replay path reached READY_TO_PUBLISH');
end
$recover_b$;

set constraints all deferred;

-- C: one committed batch, reclaim, root replay, then a deliberate batch gap.
do $partial_c$
declare f pg_temp.test_029_fixture%rowtype; v_rows jsonb;
begin
  select * into strict f from pg_temp.test_029_fixture where label='C';
  v_rows:=pg_catalog.jsonb_build_array(pg_temp.test_029_row(2,'a'));
  perform s2t_fhir_api._service_stage_candidate_import_batch(
    f.request_id,f.attempt_one,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
    v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  update s2t_fhir.candidate_import_request set
    validation_lease_expires_at=pg_catalog.transaction_timestamp()-interval '1 second'
  where candidate_import_request_id=f.request_id;
  perform s2t_fhir_api._service_begin_candidate_import_validation(
    f.request_id,'exceljs','4.4.0','CATO-MEDICATIONREQUEST-XLSX-v1',
    pg_catalog.decode(pg_catalog.repeat('29',32),'hex'),f.attempt_two,
    pg_catalog.transaction_timestamp()+interval '15 minutes',
    f.service_actor_id,pg_catalog.gen_random_uuid());
  perform s2t_fhir_api._service_stage_candidate_import_batch(
    f.request_id,f.attempt_two,0,pg_catalog.decode(pg_catalog.repeat('11',32),'hex'),
    v_rows,f.service_actor_id,pg_catalog.gen_random_uuid());
  perform pg_temp.test_029_record(5,'reclaim after one committed batch',
    (select count(*)=2 and count(*) filter(where reused_from_staging_batch_id is null)=1
     from s2t_fhir.candidate_import_staging_batch b
     where b.candidate_import_request_id=f.request_id),
    'root retained and attempt-two replay appended');
  perform s2t_fhir_api._service_stage_candidate_import_batch(
    f.request_id,f.attempt_two,2,pg_catalog.decode(pg_catalog.repeat('33',32),'hex'),
    pg_catalog.jsonb_build_array(pg_temp.test_029_row(4,'c')),
    f.service_actor_id,pg_catalog.gen_random_uuid());
  begin
    perform s2t_fhir_api._service_complete_candidate_import_validation(
      f.request_id,f.attempt_two,pg_temp.test_029_manifest(2),'[]'::jsonb,
      '{"candidateCount":2,"acceptedCount":2,"warningCount":0,"errorCount":0,"quarantinedCount":0}'::jsonb,
      pg_catalog.decode(pg_catalog.repeat('34',32),'hex'),f.service_actor_id,
      pg_catalog.gen_random_uuid());
    perform pg_temp.test_029_record(15,'gapped current-attempt batches block completion',false,'unexpected success');
  exception when sqlstate '23514' then
    perform pg_temp.test_029_record(15,'gapped current-attempt batches block completion',
      sqlerrm like 'STAGING_REPLAY_MISMATCH:%','attempt has batches 0 and 2');
  end;
end
$partial_c$;

do $terminal_protection$
declare f pg_temp.test_029_fixture%rowtype;
begin
  select * into strict f from pg_temp.test_029_fixture where label='B';
  begin
    perform s2t_fhir_api._service_complete_candidate_import_validation(
      f.request_id,f.attempt_two,pg_temp.test_029_manifest(1),'[]'::jsonb,
      '{"candidateCount":1,"acceptedCount":1,"warningCount":0,"errorCount":0,"quarantinedCount":0}'::jsonb,
      pg_catalog.decode(pg_catalog.repeat('12',32),'hex'),f.service_actor_id,
      pg_catalog.gen_random_uuid());
    perform pg_temp.test_029_record(17,'terminal completion replay fails closed',false,'unexpected success');
  exception when sqlstate '23514' then
    perform pg_temp.test_029_record(17,'terminal completion replay fails closed',
      sqlerrm like 'COMPLETION_ALREADY_APPLIED:%','weak terminal idempotency not introduced');
  end;
end
$terminal_protection$;

select pg_temp.test_029_record(18,'rollback restoration proof armed',
  (select count(*)=4 from pg_temp.test_029_fixture)
    and (select count(*)>0 from s2t_fhir.candidate_import_request r
         where r.candidate_import_request_id in (
           select request_id from pg_temp.test_029_fixture)),
  'prepared post-rollback statement will require exact committed fingerprint restoration');

select test_no,test_name,result,detail
from pg_temp.test_029_results order by test_no;

select count(*) total_tests,
       count(*) filter(where result='PASS') pass_count,
       count(*) filter(where result='FAIL') fail_count,
       case when count(*)=18 and count(*) filter(where result='PASS')=18
              and count(*) filter(where result='FAIL')=0 then 'PASS' else 'FAIL' end
         overall_runtime_result
from pg_temp.test_029_results;

do $prepare_postrollback$
declare
  c pg_temp.test_029_restore_context%rowtype;
  v_total integer;
  v_pass integer;
  v_fail integer;
  v_failed text;
begin
  select * into strict c from pg_temp.test_029_restore_context;
  select count(*),count(*) filter(where result='PASS'),
         count(*) filter(where result='FAIL')
    into v_total,v_pass,v_fail from pg_temp.test_029_results;
  select pg_catalog.string_agg(test_no||':'||test_name||':'||detail,'; ' order by test_no)
    into v_failed from pg_temp.test_029_results where result='FAIL';
  if exists(select 1 from pg_catalog.pg_prepared_statements
            where name='test_029_postrollback') then
    execute 'deallocate test_029_postrollback';
  end if;
  execute pg_catalog.format($prepared$
    prepare test_029_postrollback as
    with after_state as (
      select pg_catalog.md5(coalesce(pg_catalog.string_agg(fingerprint_row,E'\n'
        order by fingerprint_row),'')) fingerprint_after
      from (
        select 'request:'||r::text fingerprint_row from s2t_fhir.candidate_import_request r
        union all select 'event:'||e::text from s2t_fhir.candidate_import_request_event e
        union all select 'batch:'||b::text from s2t_fhir.candidate_import_staging_batch b
        union all select 'manifest:'||m::text from s2t_fhir.artifact_sheet_manifest m
        union all select 'candidate:'||c::text from s2t_fhir.import_candidate_row c
        union all select 'mapping:'||m::text from s2t_fhir.mapping_record m
        union all select 'validation:'||v::text from s2t_fhir.validation_run v
      ) rows
    )
    select case when %6$s=18 and %7$s=18 and %8$s=0
      and a.fingerprint_after=%5$L
      and not exists(select 1 from s2t_fhir.candidate_import_request r
        where r.candidate_import_request_id in (%1$L::uuid,%2$L::uuid,%3$L::uuid,%4$L::uuid))
      then 'PASS' else 'FAIL' end overall_runtime_and_rollback_result,
      %6$s::integer total_tests,%7$s::integer pass_count,%8$s::integer fail_count,
      %9$L::text failed_tests,%5$L::text committed_fingerprint_before,
      a.fingerprint_after committed_fingerprint_after,
      a.fingerprint_after=%5$L committed_fingerprint_restored
    from after_state a
  $prepared$,c.request_a,c.request_b,c.request_c,c.request_d,
    c.committed_fingerprint_before,v_total,v_pass,v_fail,coalesce(v_failed,'none'));
end
$prepare_postrollback$;

rollback;

execute test_029_postrollback;
deallocate test_029_postrollback;

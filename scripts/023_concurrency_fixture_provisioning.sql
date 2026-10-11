-- Migration 023 concurrency fixture provisioning package.
-- DESIGN ONLY: DO NOT RUN until separately approved for S2T-FHIR-DDL-Test.
-- This file is for manual Supabase SQL Editor execution. It uses no psql
-- variables, shell expansion, Supabase CLI state, or temporary cross-run state.
--
-- Immutable fixture pack ID: T023-CONC-PACK-20261009-R1
--
-- SAFETY CONTRACT
-- 1. Run checkpoint 00 first. For a new pack it must report NEW_PACK.
-- 2. Run each numbered transaction separately and retain its result grid.
-- 3. Never select and execute more than one finalization checkpoint at once.
-- 4. Every CP02-CP19 transaction finalizes exactly one baseline/import.
-- 5. The database invariant remains authoritative:
--      MVP import finalization supports exactly one baseline per transaction
-- 6. On any error, stop. Run 023_concurrency_fixture_verification.sql. Resume
--    only when it reports a contiguous completed prefix and one exact next
--    checkpoint. Never repair or delete append-only fixture evidence ad hoc.
-- 7. A complete pack is fail-closed on rerun; do not provision it again.
--
-- Shared reference values, BASELINE_IMPORT/v1 validation configuration, and
-- gate requirements are accepted immutable configuration, not reused fixture
-- evidence. All governed fixture evidence itself is pack/case-specific.

-- ---------------------------------------------------------------------------
-- CP00 (READ ONLY) - environment, dependency, and rerun preflight
-- ---------------------------------------------------------------------------
do $cp00$
declare
  v_count integer;
begin
  if pg_catalog.to_regprocedure(
       's2t_fhir.grant_baseline_action(uuid,text,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir.grant_review_write(uuid,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.start_authenticated_candidate_review_session(uuid,uuid,text,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(uuid,uuid,text,uuid,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.end_authenticated_candidate_review_session(uuid,uuid,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.gov_open_question(text,text,timestamptz,jsonb)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.gov_link_candidate_mapping(uuid,uuid,uuid,jsonb,timestamptz)'
     ) is null
     or pg_catalog.to_regprocedure(
       's2t_fhir_api.promote_candidate_baseline(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,text)'
     ) is null then
    raise exception 'CP00: required Migration 023 workflow functions are missing'
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_migrator'
    and p.disabled_at is null;
  if v_count <> 1 then
    raise exception 'CP00: expected one active s2t_fhir_migrator principal; found %', v_count
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from s2t_fhir.principal p
  where p.external_issuer = 'postgres-role'
    and p.external_subject = 's2t_fhir_importer'
    and p.disabled_at is null;
  if v_count <> 1 then
    raise exception 'CP00: expected one active s2t_fhir_importer principal; found %', v_count
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from s2t_fhir.validation_ruleset r
  where r.ruleset_code = 'BASELINE_IMPORT' and r.version_label = 'v1';
  if v_count <> 1 then
    raise exception 'CP00: expected one BASELINE_IMPORT/v1 validation ruleset; found %', v_count
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from s2t_fhir.release_gate_definition g
  where g.gate_code = 'BASELINE_IMPORT' and g.version_label = 'v1';
  if v_count <> 1 then
    raise exception 'CP00: expected one BASELINE_IMPORT/v1 release gate; found %', v_count
      using errcode = '55000';
  end if;

  if exists (
    select 1 from s2t_fhir.principal p
    where p.principal_id in (
      '023c01a0-0000-4000-8000-000000000001','023c01b0-0000-4000-8000-000000000001',
      '023c02a0-0000-4000-8000-000000000001','023c02b0-0000-4000-8000-000000000001',
      '023c03a0-0000-4000-8000-000000000001','023c03b0-0000-4000-8000-000000000001',
      '023c04a0-0000-4000-8000-000000000001','023c04b0-0000-4000-8000-000000000001',
      '023c05a0-0000-4000-8000-000000000001','023c05b0-0000-4000-8000-000000000001',
      '023c06a0-0000-4000-8000-000000000001','023c06b0-0000-4000-8000-000000000001',
      '023c07a0-0000-4000-8000-000000000001','023c07b0-0000-4000-8000-000000000001'
    )
  ) or exists (
    select 1 from s2t_fhir.baseline_series s
    where s.baseline_series_id in (
      '023c0100-0000-4000-8000-000000000001','023c0200-0000-4000-8000-000000000002',
      '023c0300-0000-4000-8000-000000000003','023c0400-0000-4000-8000-000000000004',
      '023c0500-0000-4000-8000-000000000005','023c0600-0000-4000-8000-000000000006',
      '023c0700-0000-4000-8000-000000000071','023c0700-0000-4000-8000-000000000072'
    )
  ) or exists (
    select 1 from s2t_fhir.baseline_version b
    where b.baseline_version_id in (
      '023c0101-0000-4000-8000-000000000001','023c0111-0000-4000-8000-000000000001',
      '023c0201-0000-4000-8000-000000000001','023c0211-0000-4000-8000-000000000001','023c0221-0000-4000-8000-000000000001',
      '023c0301-0000-4000-8000-000000000001','023c0311-0000-4000-8000-000000000001',
      '023c0401-0000-4000-8000-000000000001','023c0411-0000-4000-8000-000000000001',
      '023c0501-0000-4000-8000-000000000001','023c0511-0000-4000-8000-000000000001',
      '023c0601-0000-4000-8000-000000000001','023c0611-0000-4000-8000-000000000001','023c0621-0000-4000-8000-000000000001',
      '023c0701-0000-4000-8000-000000000001','023c0711-0000-4000-8000-000000000001',
      '023c0781-0000-4000-8000-000000000001','023c0791-0000-4000-8000-000000000001'
    )
  ) or exists (
    select 1 from s2t_fhir.mapping_resource_registry r
    where r.resource_config_id in (
      't023-conc-pack-20261009-r1-c03-resource','t023-conc-pack-20261009-r1-c04-resource',
      't023-conc-pack-20261009-r1-c05-resource','t023-conc-pack-20261009-r1-c06-resource'
    )
  ) or exists (
    select 1 from s2t_fhir.review_session rs
    where rs.session_name in (
      'T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT','T023-CONC-PACK-20261009-R1-C05-V1-REVIEW',
      'T023-CONC-PACK-20261009-R1-C05-V2-REVIEW','T023-CONC-PACK-20261009-R1-C06-V1-REVIEW',
      'T023-CONC-PACK-20261009-R1-C06-V2-REVIEW'
    )
  ) or exists (
    select 1 from s2t_governance.governance_question q
    where q.title = 'T023-CONC-PACK-20261009-R1-C04-QUESTION'
  ) then
    raise exception 'CP00: exact pack or partial pack already exists; run verification and do not restart at CP01'
      using errcode = '55000';
  end if;
end
$cp00$;

select 'CP00' as checkpoint, 'NEW_PACK' as state,
       'T023-CONC-PACK-20261009-R1' as pack_id,
       transaction_timestamp() as observed_at;

-- Save these global pre-provisioning fingerprints outside the database. They
-- will legitimately change after C05/C06 retain synthetic ACTIVE/CANDIDATE data.
select 'GLOBAL_PRE' as phase, fingerprint_name, fingerprint
from (
  select 'active_baseline'::text as fingerprint_name,
         md5(coalesce(string_agg(x::text, '|' order by x::text), '')) as fingerprint
  from s2t_fhir_api.active_baseline x
  union all
  select '_active_release_context',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api._active_release_context x
  union all
  select 'active_mapping_record',
         md5(coalesce(string_agg(x::text, '|' order by x::text), ''))
  from s2t_fhir_api.active_mapping_record x
) f
order by fingerprint_name;

-- ---------------------------------------------------------------------------
-- CP01 - principals, authorizations, series, and mapping registries
-- No import is finalized in this transaction.
-- ---------------------------------------------------------------------------
begin;
set local role s2t_fhir_owner;
set constraints all deferred;

do $cp01_guard$
begin
  if exists (
    select 1 from s2t_fhir.principal
    where principal_id in (
      '023c01a0-0000-4000-8000-000000000001','023c01b0-0000-4000-8000-000000000001',
      '023c02a0-0000-4000-8000-000000000001','023c02b0-0000-4000-8000-000000000001',
      '023c03a0-0000-4000-8000-000000000001','023c03b0-0000-4000-8000-000000000001',
      '023c04a0-0000-4000-8000-000000000001','023c04b0-0000-4000-8000-000000000001',
      '023c05a0-0000-4000-8000-000000000001','023c05b0-0000-4000-8000-000000000001',
      '023c06a0-0000-4000-8000-000000000001','023c06b0-0000-4000-8000-000000000001',
      '023c07a0-0000-4000-8000-000000000001','023c07b0-0000-4000-8000-000000000001'
    )
  ) or exists (
    select 1 from s2t_fhir.baseline_series
    where baseline_series_id in (
      '023c0100-0000-4000-8000-000000000001','023c0200-0000-4000-8000-000000000002',
      '023c0300-0000-4000-8000-000000000003','023c0400-0000-4000-8000-000000000004',
      '023c0500-0000-4000-8000-000000000005','023c0600-0000-4000-8000-000000000006',
      '023c0700-0000-4000-8000-000000000071','023c0700-0000-4000-8000-000000000072'
    )
  ) or exists (
    select 1 from s2t_fhir.mapping_resource_registry
    where resource_config_id in (
      't023-conc-pack-20261009-r1-c03-resource','t023-conc-pack-20261009-r1-c04-resource',
      't023-conc-pack-20261009-r1-c05-resource','t023-conc-pack-20261009-r1-c06-resource'
    )
  ) then
    raise exception 'CP01: infrastructure is already present or partial; fail closed'
      using errcode = '55000';
  end if;
end
$cp01_guard$;

insert into s2t_fhir.principal
  (principal_id, principal_kind_value_id, external_issuer, external_subject, display_name)
select p.principal_id, kind.reference_value_id, 'supabase-auth', p.auth_subject, p.display_name
from (values
  ('023c01a0-0000-4000-8000-000000000001'::uuid,'023c01a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C01-WORKER-A'),
  ('023c01b0-0000-4000-8000-000000000001'::uuid,'023c01b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C01-WORKER-B'),
  ('023c02a0-0000-4000-8000-000000000001'::uuid,'023c02a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C02-WORKER-A'),
  ('023c02b0-0000-4000-8000-000000000001'::uuid,'023c02b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C02-WORKER-B'),
  ('023c03a0-0000-4000-8000-000000000001'::uuid,'023c03a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C03-WORKER-A'),
  ('023c03b0-0000-4000-8000-000000000001'::uuid,'023c03b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C03-WORKER-B'),
  ('023c04a0-0000-4000-8000-000000000001'::uuid,'023c04a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C04-WORKER-A'),
  ('023c04b0-0000-4000-8000-000000000001'::uuid,'023c04b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C04-WORKER-B'),
  ('023c05a0-0000-4000-8000-000000000001'::uuid,'023c05a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C05-WORKER-A'),
  ('023c05b0-0000-4000-8000-000000000001'::uuid,'023c05b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C05-WORKER-B'),
  ('023c06a0-0000-4000-8000-000000000001'::uuid,'023c06a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C06-WORKER-A'),
  ('023c06b0-0000-4000-8000-000000000001'::uuid,'023c06b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C06-WORKER-B'),
  ('023c07a0-0000-4000-8000-000000000001'::uuid,'023c07a1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C07-WORKER-A'),
  ('023c07b0-0000-4000-8000-000000000001'::uuid,'023c07b1-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C07-WORKER-B')
) p(principal_id,auth_subject,display_name)
cross join lateral (
  select v.reference_value_id
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'PRINCIPAL_KIND' and v.value_code = 'HUMAN'
    and v.effective_at <= transaction_timestamp()
    and (v.retired_at is null or v.retired_at > transaction_timestamp())
) kind;

insert into s2t_fhir.baseline_series
  (baseline_series_id, source_system, fhir_resource, baseline_type_value_id, description)
select s.series_id, s.source_system, 'MedicationRequest', bt.reference_value_id,
       s.source_system || ' dedicated concurrency fixture series'
from (values
  ('023c0100-0000-4000-8000-000000000001'::uuid,'T023-CONC-PACK-20261009-R1-C01'),
  ('023c0200-0000-4000-8000-000000000002'::uuid,'T023-CONC-PACK-20261009-R1-C02'),
  ('023c0300-0000-4000-8000-000000000003'::uuid,'T023-CONC-PACK-20261009-R1-C03'),
  ('023c0400-0000-4000-8000-000000000004'::uuid,'T023-CONC-PACK-20261009-R1-C04'),
  ('023c0500-0000-4000-8000-000000000005'::uuid,'T023-CONC-PACK-20261009-R1-C05'),
  ('023c0600-0000-4000-8000-000000000006'::uuid,'T023-CONC-PACK-20261009-R1-C06'),
  ('023c0700-0000-4000-8000-000000000071'::uuid,'T023-CONC-PACK-20261009-R1-C07-A'),
  ('023c0700-0000-4000-8000-000000000072'::uuid,'T023-CONC-PACK-20261009-R1-C07-B')
) s(series_id,source_system)
cross join lateral (
  select v.reference_value_id
  from s2t_fhir.reference_value v
  join s2t_fhir.reference_domain d using (reference_domain_id)
  where d.domain_code = 'BASELINE_TYPE' and v.value_code = 'HUMAN_WORKING_DRAFT'
) bt;

insert into s2t_fhir.mapping_resource_registry
  (resource_config_id, source_system, fhir_resource, is_enabled)
values
  ('t023-conc-pack-20261009-r1-c03-resource','T023-CONC-PACK-20261009-R1-C03','MedicationRequest',true),
  ('t023-conc-pack-20261009-r1-c04-resource','T023-CONC-PACK-20261009-R1-C04','MedicationRequest',true),
  ('t023-conc-pack-20261009-r1-c05-resource','T023-CONC-PACK-20261009-R1-C05','MedicationRequest',true),
  ('t023-conc-pack-20261009-r1-c06-resource','T023-CONC-PACK-20261009-R1-C06','MedicationRequest',true);

-- Authorization history is created through the accepted grant functions.
select s2t_fhir.grant_baseline_action(p, 'S2T_BASELINE_UPLOAD', admin_id)
from (values
  ('023c01a0-0000-4000-8000-000000000001'::uuid),('023c01b0-0000-4000-8000-000000000001'::uuid),
  ('023c02a0-0000-4000-8000-000000000001'::uuid),('023c02b0-0000-4000-8000-000000000001'::uuid),
  ('023c03b0-0000-4000-8000-000000000001'::uuid),('023c04b0-0000-4000-8000-000000000001'::uuid),
  ('023c05a0-0000-4000-8000-000000000001'::uuid),
  ('023c06a0-0000-4000-8000-000000000001'::uuid),('023c06b0-0000-4000-8000-000000000001'::uuid),
  ('023c07a0-0000-4000-8000-000000000001'::uuid),('023c07b0-0000-4000-8000-000000000001'::uuid)
) workers(p)
cross join lateral (
  select principal_id as admin_id from s2t_fhir.principal
  where external_issuer = 'postgres-role' and external_subject = 's2t_fhir_importer'
    and disabled_at is null
) admin;

select s2t_fhir.grant_baseline_action(p, 'S2T_BASELINE_PROMOTE', admin_id)
from (values
  ('023c05a0-0000-4000-8000-000000000001'::uuid),('023c05b0-0000-4000-8000-000000000001'::uuid),
  ('023c06a0-0000-4000-8000-000000000001'::uuid),('023c06b0-0000-4000-8000-000000000001'::uuid)
) workers(p)
cross join lateral (
  select principal_id as admin_id from s2t_fhir.principal
  where external_issuer = 'postgres-role' and external_subject = 's2t_fhir_importer'
    and disabled_at is null
) admin;

select s2t_fhir.grant_review_write(p, admin_id)
from (values
  ('023c03a0-0000-4000-8000-000000000001'::uuid),
  ('023c04a0-0000-4000-8000-000000000001'::uuid),
  ('023c05a0-0000-4000-8000-000000000001'::uuid),
  ('023c06a0-0000-4000-8000-000000000001'::uuid)
) workers(p)
cross join lateral (
  select principal_id as admin_id from s2t_fhir.principal
  where external_issuer = 'postgres-role' and external_subject = 's2t_fhir_importer'
    and disabled_at is null
) admin;

commit;

select 'CP01' as checkpoint, 'COMPLETE' as state,
       'T023-CONC-PACK-20261009-R1' as pack_id,
       (select count(*) from s2t_fhir.principal
        where principal_id in (
          '023c01a0-0000-4000-8000-000000000001','023c01b0-0000-4000-8000-000000000001',
          '023c02a0-0000-4000-8000-000000000001','023c02b0-0000-4000-8000-000000000001',
          '023c03a0-0000-4000-8000-000000000001','023c03b0-0000-4000-8000-000000000001',
          '023c04a0-0000-4000-8000-000000000001','023c04b0-0000-4000-8000-000000000001',
          '023c05a0-0000-4000-8000-000000000001','023c05b0-0000-4000-8000-000000000001',
          '023c06a0-0000-4000-8000-000000000001','023c06b0-0000-4000-8000-000000000001',
          '023c07a0-0000-4000-8000-000000000001','023c07b0-0000-4000-8000-000000000001')) as principal_count,
       (select count(*) from s2t_fhir.baseline_series
        where baseline_series_id in (
          '023c0100-0000-4000-8000-000000000001','023c0200-0000-4000-8000-000000000002',
          '023c0300-0000-4000-8000-000000000003','023c0400-0000-4000-8000-000000000004',
          '023c0500-0000-4000-8000-000000000005','023c0600-0000-4000-8000-000000000006',
          '023c0700-0000-4000-8000-000000000071','023c0700-0000-4000-8000-000000000072')) as series_count,
       (select count(*) from s2t_fhir.mapping_resource_registry
        where resource_config_id in (
          't023-conc-pack-20261009-r1-c03-resource','t023-conc-pack-20261009-r1-c04-resource',
          't023-conc-pack-20261009-r1-c05-resource','t023-conc-pack-20261009-r1-c06-resource')) as registry_count;

-- CP02-CP19 below are the only import-finalization checkpoints. Each explicit
-- transaction creates and finalizes exactly one baseline/import and emits its
-- exact deterministic IDs after COMMIT.

-- CP02 - C01 baseline A
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp02$
declare
  v_series constant uuid := '023c0100-0000-4000-8000-000000000001';
  v_baseline constant uuid := '023c0101-0000-4000-8000-000000000001';
  v_artifact constant uuid := '023c0102-0000-4000-8000-000000000001';
  v_import constant uuid := '023c0103-0000-4000-8000-000000000001';
  v_actor constant uuid := '023c01a0-0000-4000-8000-000000000001';
begin
  if not exists (select 1 from s2t_fhir.baseline_series where baseline_series_id = v_series)
     or exists (select 1 from s2t_fhir.baseline_version where baseline_version_id = v_baseline)
     or exists (select 1 from s2t_fhir.artifact where artifact_id = v_artifact)
     or exists (select 1 from s2t_fhir.import_run where import_run_id = v_import) then
    raise exception 'CP02: prerequisite missing or checkpoint already/partially present' using errcode = '55000';
  end if;
  insert into s2t_fhir.baseline_version
    (baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,
     import_specification_version,description,created_by_principal_id)
  values (v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C01-A','T023-CONC-PACK-20261009-R1-C01-A',false,
          'T023-CONC-PACK-20261009-R1-C01-v1','T023-CONC-PACK-20261009-R1-C01 baseline A',v_actor);
  insert into s2t_fhir.artifact
    (artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,
     captured_at,description,created_by_principal_id)
  select v_artifact,v.reference_value_id,
         decode(md5('T023-CONC-PACK-20261009-R1-C01-A-artifact-1')||md5('T023-CONC-PACK-20261009-R1-C01-A-artifact-2'),'hex'),
         1,'application/test','T023-CONC-PACK-20261009-R1-C01-A.xlsx',transaction_timestamp(),
         'T023-CONC-PACK-20261009-R1-C01 artifact A',v_actor
  from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id)
  where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact
    (baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id)
  select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C01 authoritative A',v_actor
  from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id)
  where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run
    (import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,
     importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id)
  select v_import,v_baseline,v_artifact,policy.reference_value_id,
         'T023-CONC-PACK-20261009-R1-C01-v1','T023-CONC-PACK-20261009-R1-C01-importer',
         decode(md5('T023-CONC-PACK-20261009-R1-C01-A-config-1')||md5('T023-CONC-PACK-20261009-R1-C01-A-config-2'),'hex'),
         transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',status.reference_value_id,v_actor
  from s2t_fhir.reference_value policy join s2t_fhir.reference_domain pd on pd.reference_domain_id=policy.reference_domain_id
  cross join s2t_fhir.reference_value status join s2t_fhir.reference_domain sd on sd.reference_domain_id=status.reference_domain_id
  where pd.domain_code='IMPORT_POLICY' and policy.value_code='CLEAN_IMPORT'
    and sd.domain_code='IMPORT_RUN_STATUS' and status.value_code='COMMITTED';
end
$cp02$;
commit;
select 'CP02' checkpoint,'COMPLETE' state,'C01' case_id,
       '023c0101-0000-4000-8000-000000000001'::uuid baseline_id,
       '023c0102-0000-4000-8000-000000000001'::uuid artifact_id,
       '023c0103-0000-4000-8000-000000000001'::uuid import_id;

-- CP03 - C01 baseline B
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp03$
declare
  v_series constant uuid := '023c0100-0000-4000-8000-000000000001';
  v_baseline constant uuid := '023c0111-0000-4000-8000-000000000001';
  v_artifact constant uuid := '023c0112-0000-4000-8000-000000000001';
  v_import constant uuid := '023c0113-0000-4000-8000-000000000001';
  v_actor constant uuid := '023c01b0-0000-4000-8000-000000000001';
begin
  if not exists (select 1 from s2t_fhir.import_run where import_run_id='023c0103-0000-4000-8000-000000000001')
     or exists (select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists (select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists (select 1 from s2t_fhir.import_run where import_run_id=v_import) then
    raise exception 'CP03: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;
  insert into s2t_fhir.baseline_version values
    (v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C01-B','T023-CONC-PACK-20261009-R1-C01-B',false,
     'T023-CONC-PACK-20261009-R1-C01-v1','T023-CONC-PACK-20261009-R1-C01 baseline B',v_actor,transaction_timestamp());
  insert into s2t_fhir.artifact
    (artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id)
  select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C01-B-artifact-1')||md5('T023-CONC-PACK-20261009-R1-C01-B-artifact-2'),'hex'),
         1,'application/test','T023-CONC-PACK-20261009-R1-C01-B.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C01 artifact B',v_actor
  from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id)
  where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact
    (baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id)
  select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C01 authoritative B',v_actor
  from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id)
  where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run
    (import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,
     configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id)
  select v_import,v_baseline,v_artifact,policy.reference_value_id,'T023-CONC-PACK-20261009-R1-C01-v1',
         'T023-CONC-PACK-20261009-R1-C01-importer',decode(md5('T023-CONC-PACK-20261009-R1-C01-B-config-1')||md5('T023-CONC-PACK-20261009-R1-C01-B-config-2'),'hex'),
         transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',status.reference_value_id,v_actor
  from s2t_fhir.reference_value policy join s2t_fhir.reference_domain pd on pd.reference_domain_id=policy.reference_domain_id
  cross join s2t_fhir.reference_value status join s2t_fhir.reference_domain sd on sd.reference_domain_id=status.reference_domain_id
  where pd.domain_code='IMPORT_POLICY' and policy.value_code='CLEAN_IMPORT'
    and sd.domain_code='IMPORT_RUN_STATUS' and status.value_code='COMMITTED';
end
$cp03$;
commit;
select 'CP03' checkpoint,'COMPLETE' state,'C01' case_id,
       '023c0111-0000-4000-8000-000000000001'::uuid baseline_id,
       '023c0112-0000-4000-8000-000000000001'::uuid artifact_id,
       '023c0113-0000-4000-8000-000000000001'::uuid import_id;

-- CP04 - C02 V1; CP05 - C02 V2A; CP06 - C02 V2B
-- These three transactions intentionally repeat the same accepted one-baseline
-- finalization shape with distinct immutable IDs.
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp04$
declare v_series uuid:='023c0200-0000-4000-8000-000000000002'; v_baseline uuid:='023c0201-0000-4000-8000-000000000001';
v_artifact uuid:='023c0202-0000-4000-8000-000000000001'; v_import uuid:='023c0203-0000-4000-8000-000000000001'; v_actor uuid:='023c02a0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0113-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP04: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id)
  values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C02-V1','T023-CONC-PACK-20261009-R1-C02-V1',false,'T023-CONC-PACK-20261009-R1-C02-v1','T023-CONC-PACK-20261009-R1-C02 V1',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id)
  select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C02-V1-a1')||md5('T023-CONC-PACK-20261009-R1-C02-V1-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C02-V1.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C02 V1 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id)
  select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C02 V1 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id)
  select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C02-v1','T023-CONC-PACK-20261009-R1-C02-importer',decode(md5('T023-CONC-PACK-20261009-R1-C02-V1-c1')||md5('T023-CONC-PACK-20261009-R1-C02-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp04$;
commit;
select 'CP04' checkpoint,'COMPLETE' state,'C02' case_id,'023c0201-0000-4000-8000-000000000001'::uuid baseline_id,'023c0202-0000-4000-8000-000000000001'::uuid artifact_id,'023c0203-0000-4000-8000-000000000001'::uuid import_id;

begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp05$
declare v_series uuid:='023c0200-0000-4000-8000-000000000002'; v_baseline uuid:='023c0211-0000-4000-8000-000000000001';
v_artifact uuid:='023c0212-0000-4000-8000-000000000001'; v_import uuid:='023c0213-0000-4000-8000-000000000001'; v_actor uuid:='023c02a0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0203-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP05: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C02-V2A','T023-CONC-PACK-20261009-R1-C02-V2A',false,'T023-CONC-PACK-20261009-R1-C02-v1','T023-CONC-PACK-20261009-R1-C02 V2A',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C02-V2A-a1')||md5('T023-CONC-PACK-20261009-R1-C02-V2A-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C02-V2A.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C02 V2A artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C02 V2A authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C02-v1','T023-CONC-PACK-20261009-R1-C02-importer',decode(md5('T023-CONC-PACK-20261009-R1-C02-V2A-c1')||md5('T023-CONC-PACK-20261009-R1-C02-V2A-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp05$;
commit;
select 'CP05' checkpoint,'COMPLETE' state,'C02' case_id,'023c0211-0000-4000-8000-000000000001'::uuid baseline_id,'023c0212-0000-4000-8000-000000000001'::uuid artifact_id,'023c0213-0000-4000-8000-000000000001'::uuid import_id;

begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp06$
declare v_series uuid:='023c0200-0000-4000-8000-000000000002'; v_baseline uuid:='023c0221-0000-4000-8000-000000000001';
v_artifact uuid:='023c0222-0000-4000-8000-000000000001'; v_import uuid:='023c0223-0000-4000-8000-000000000001'; v_actor uuid:='023c02b0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0213-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP06: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C02-V2B','T023-CONC-PACK-20261009-R1-C02-V2B',false,'T023-CONC-PACK-20261009-R1-C02-v1','T023-CONC-PACK-20261009-R1-C02 V2B',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C02-V2B-a1')||md5('T023-CONC-PACK-20261009-R1-C02-V2B-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C02-V2B.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C02 V2B artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C02 V2B authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C02-v1','T023-CONC-PACK-20261009-R1-C02-importer',decode(md5('T023-CONC-PACK-20261009-R1-C02-V2B-c1')||md5('T023-CONC-PACK-20261009-R1-C02-V2B-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp06$;
commit;
select 'CP06' checkpoint,'COMPLETE' state,'C02' case_id,'023c0221-0000-4000-8000-000000000001'::uuid baseline_id,'023c0222-0000-4000-8000-000000000001'::uuid artifact_id,'023c0223-0000-4000-8000-000000000001'::uuid import_id;

-- CP07 - C03 mapped Candidate baseline V1
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp07$
declare v_series uuid:='023c0300-0000-4000-8000-000000000003'; v_baseline uuid:='023c0301-0000-4000-8000-000000000001'; v_artifact uuid:='023c0302-0000-4000-8000-000000000001'; v_import uuid:='023c0303-0000-4000-8000-000000000001'; v_manifest uuid:='023c0304-0000-4000-8000-000000000001'; v_row uuid:='023c0305-0000-4000-8000-000000000001'; v_identity uuid:='023c0306-0000-4000-8000-000000000001'; v_mapping uuid:='023c0307-0000-4000-8000-000000000001'; v_actor uuid:='023c03a0-0000-4000-8000-000000000001'; v_hash text:=md5('T023-CONC-PACK-20261009-R1-C03-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C03-V1-node-2');
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0223-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP07: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C03-V1','T023-CONC-PACK-20261009-R1-C03-V1',false,'T023-CONC-PACK-20261009-R1-C03-v1','T023-CONC-PACK-20261009-R1-C03 mapped V1',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C03-V1-a1')||md5('T023-CONC-PACK-20261009-R1-C03-V1-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C03-V1.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C03 V1 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C03 V1 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_manifest,v_artifact,'T023-CONC-PACK-20261009-R1-C03-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T023-CONC-PACK-20261009-R1-C03 manifest','T023-CONC-PACK-20261009-R1-C03-manifest','1',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C03') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C03-v1','T023-CONC-PACK-20261009-R1-C03-importer',decode(md5('T023-CONC-PACK-20261009-R1-C03-V1-c1')||md5('T023-CONC-PACK-20261009-R1-C03-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_import,mk.reference_value_id,'T023-CONC-PACK-20261009-R1-C03-SHEET',2,'A2:Q2','T023-CONC-PACK-20261009-R1-C03-raw','1',jsonb_build_object('sheet','T023-CONC-PACK-20261009-R1-C03-SHEET','row',2,'range','A2:Q2','cells',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C03')),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C03') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_identity,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C03','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C03') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_mapping,v_baseline,v_row,v_identity,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_mapping,'MedicationRequest.status','T023-CONC-PACK-20261009-R1-C03','T023-CONC-PACK-20261009-R1-C03.source','LOCAL','T023-CONC-PACK-20261009-R1-C03 mapping');
end $cp07$;
commit;
select 'CP07' checkpoint,'COMPLETE' state,'C03' case_id,'023c0301-0000-4000-8000-000000000001'::uuid baseline_id,'023c0302-0000-4000-8000-000000000001'::uuid artifact_id,'023c0303-0000-4000-8000-000000000001'::uuid import_id,'023c0307-0000-4000-8000-000000000001'::uuid mapping_record_id;

-- CP08 - C03 unpublished replacement V2
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp08$
declare v_series uuid:='023c0300-0000-4000-8000-000000000003'; v_baseline uuid:='023c0311-0000-4000-8000-000000000001'; v_artifact uuid:='023c0312-0000-4000-8000-000000000001'; v_import uuid:='023c0313-0000-4000-8000-000000000001'; v_actor uuid:='023c03b0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0303-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP08: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C03-V2','T023-CONC-PACK-20261009-R1-C03-V2',false,'T023-CONC-PACK-20261009-R1-C03-v1','T023-CONC-PACK-20261009-R1-C03 replacement V2',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C03-V2-a1')||md5('T023-CONC-PACK-20261009-R1-C03-V2-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C03-V2.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C03 V2 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C03 V2 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C03-v1','T023-CONC-PACK-20261009-R1-C03-importer',decode(md5('T023-CONC-PACK-20261009-R1-C03-V2-c1')||md5('T023-CONC-PACK-20261009-R1-C03-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp08$;
commit;
select 'CP08' checkpoint,'COMPLETE' state,'C03' case_id,'023c0311-0000-4000-8000-000000000001'::uuid baseline_id,'023c0312-0000-4000-8000-000000000001'::uuid artifact_id,'023c0313-0000-4000-8000-000000000001'::uuid import_id;

-- CP09 - C04 mapped Candidate baseline V1
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp09$
declare v_series uuid:='023c0400-0000-4000-8000-000000000004'; v_baseline uuid:='023c0401-0000-4000-8000-000000000001'; v_artifact uuid:='023c0402-0000-4000-8000-000000000001'; v_import uuid:='023c0403-0000-4000-8000-000000000001'; v_manifest uuid:='023c0404-0000-4000-8000-000000000001'; v_row uuid:='023c0405-0000-4000-8000-000000000001'; v_identity uuid:='023c0406-0000-4000-8000-000000000001'; v_mapping uuid:='023c0407-0000-4000-8000-000000000001'; v_actor uuid:='023c04a0-0000-4000-8000-000000000001'; v_hash text:=md5('T023-CONC-PACK-20261009-R1-C04-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C04-V1-node-2');
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0313-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP09: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C04-V1','T023-CONC-PACK-20261009-R1-C04-V1',false,'T023-CONC-PACK-20261009-R1-C04-v1','T023-CONC-PACK-20261009-R1-C04 mapped V1',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C04-V1-a1')||md5('T023-CONC-PACK-20261009-R1-C04-V1-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C04-V1.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C04 V1 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C04 V1 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_manifest,v_artifact,'T023-CONC-PACK-20261009-R1-C04-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T023-CONC-PACK-20261009-R1-C04 manifest','T023-CONC-PACK-20261009-R1-C04-manifest','1',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C04') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C04-v1','T023-CONC-PACK-20261009-R1-C04-importer',decode(md5('T023-CONC-PACK-20261009-R1-C04-V1-c1')||md5('T023-CONC-PACK-20261009-R1-C04-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_import,mk.reference_value_id,'T023-CONC-PACK-20261009-R1-C04-SHEET',2,'A2:Q2','T023-CONC-PACK-20261009-R1-C04-raw','1',jsonb_build_object('sheet','T023-CONC-PACK-20261009-R1-C04-SHEET','row',2,'range','A2:Q2','cells',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C04')),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C04') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_identity,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C04','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C04') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_mapping,v_baseline,v_row,v_identity,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_mapping,'MedicationRequest.status','T023-CONC-PACK-20261009-R1-C04','T023-CONC-PACK-20261009-R1-C04.source','LOCAL','T023-CONC-PACK-20261009-R1-C04 mapping');
end $cp09$;
commit;
select 'CP09' checkpoint,'COMPLETE' state,'C04' case_id,'023c0401-0000-4000-8000-000000000001'::uuid baseline_id,'023c0402-0000-4000-8000-000000000001'::uuid artifact_id,'023c0403-0000-4000-8000-000000000001'::uuid import_id,'023c0407-0000-4000-8000-000000000001'::uuid mapping_record_id;

-- CP10 - C04 unpublished replacement V2
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp10$
declare v_series uuid:='023c0400-0000-4000-8000-000000000004'; v_baseline uuid:='023c0411-0000-4000-8000-000000000001'; v_artifact uuid:='023c0412-0000-4000-8000-000000000001'; v_import uuid:='023c0413-0000-4000-8000-000000000001'; v_actor uuid:='023c04b0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0403-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP10: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C04-V2','T023-CONC-PACK-20261009-R1-C04-V2',false,'T023-CONC-PACK-20261009-R1-C04-v1','T023-CONC-PACK-20261009-R1-C04 replacement V2',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C04-V2-a1')||md5('T023-CONC-PACK-20261009-R1-C04-V2-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C04-V2.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C04 V2 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C04 V2 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C04-v1','T023-CONC-PACK-20261009-R1-C04-importer',decode(md5('T023-CONC-PACK-20261009-R1-C04-V2-c1')||md5('T023-CONC-PACK-20261009-R1-C04-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp10$;
commit;
select 'CP10' checkpoint,'COMPLETE' state,'C04' case_id,'023c0411-0000-4000-8000-000000000001'::uuid baseline_id,'023c0412-0000-4000-8000-000000000001'::uuid artifact_id,'023c0413-0000-4000-8000-000000000001'::uuid import_id;

-- CP11-CP14 - mapped Promotion baselines (C05 V1/V2 and C06 V1/V2).
-- Each transaction is intentionally self-contained and finalizes one import.

-- CP11 - C05 V1
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp11$
declare v_series uuid:='023c0500-0000-4000-8000-000000000005'; v_baseline uuid:='023c0501-0000-4000-8000-000000000001'; v_artifact uuid:='023c0502-0000-4000-8000-000000000001'; v_import uuid:='023c0503-0000-4000-8000-000000000001'; v_manifest uuid:='023c0504-0000-4000-8000-000000000001'; v_row uuid:='023c0505-0000-4000-8000-000000000001'; v_identity uuid:='023c0506-0000-4000-8000-000000000001'; v_mapping uuid:='023c0507-0000-4000-8000-000000000001'; v_actor uuid:='023c05a0-0000-4000-8000-000000000001'; v_hash text:=md5('T023-CONC-PACK-20261009-R1-C05-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V1-node-2');
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0413-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP11: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C05-V1','T023-CONC-PACK-20261009-R1-C05-V1',false,'T023-CONC-PACK-20261009-R1-C05-v1','T023-CONC-PACK-20261009-R1-C05 Promotion V1',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C05-V1-a1')||md5('T023-CONC-PACK-20261009-R1-C05-V1-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C05-V1.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C05 V1 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C05 V1 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_manifest,v_artifact,'T023-CONC-PACK-20261009-R1-C05-V1-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T023-CONC-PACK-20261009-R1-C05 V1 manifest','T023-CONC-PACK-20261009-R1-C05-manifest','1',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V1') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C05-v1','T023-CONC-PACK-20261009-R1-C05-importer',decode(md5('T023-CONC-PACK-20261009-R1-C05-V1-c1')||md5('T023-CONC-PACK-20261009-R1-C05-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_import,mk.reference_value_id,'T023-CONC-PACK-20261009-R1-C05-V1-SHEET',2,'A2:Q2','T023-CONC-PACK-20261009-R1-C05-raw','1',jsonb_build_object('sheet','T023-CONC-PACK-20261009-R1-C05-V1-SHEET','row',2,'range','A2:Q2','cells',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V1')),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V1') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_identity,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C05','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V1') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_mapping,v_baseline,v_row,v_identity,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_mapping,'MedicationRequest.status','T023-CONC-PACK-20261009-R1-C05','T023-CONC-PACK-20261009-R1-C05-V1.source','LOCAL','T023-CONC-PACK-20261009-R1-C05 V1 mapping');
end $cp11$;
commit;
select 'CP11' checkpoint,'COMPLETE' state,'C05' case_id,'023c0501-0000-4000-8000-000000000001'::uuid baseline_id,'023c0502-0000-4000-8000-000000000001'::uuid artifact_id,'023c0503-0000-4000-8000-000000000001'::uuid import_id,'023c0507-0000-4000-8000-000000000001'::uuid mapping_record_id;

-- CP12 - C05 V2
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp12$
declare v_series uuid:='023c0500-0000-4000-8000-000000000005'; v_baseline uuid:='023c0511-0000-4000-8000-000000000001'; v_artifact uuid:='023c0512-0000-4000-8000-000000000001'; v_import uuid:='023c0513-0000-4000-8000-000000000001'; v_manifest uuid:='023c0514-0000-4000-8000-000000000001'; v_row uuid:='023c0515-0000-4000-8000-000000000001'; v_identity uuid:='023c0516-0000-4000-8000-000000000001'; v_mapping uuid:='023c0517-0000-4000-8000-000000000001'; v_actor uuid:='023c05a0-0000-4000-8000-000000000001'; v_hash text:=md5('T023-CONC-PACK-20261009-R1-C05-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V2-node-2');
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0503-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP12: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C05-V2','T023-CONC-PACK-20261009-R1-C05-V2',false,'T023-CONC-PACK-20261009-R1-C05-v1','T023-CONC-PACK-20261009-R1-C05 Promotion V2',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C05-V2-a1')||md5('T023-CONC-PACK-20261009-R1-C05-V2-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C05-V2.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C05 V2 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C05 V2 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_manifest,v_artifact,'T023-CONC-PACK-20261009-R1-C05-V2-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T023-CONC-PACK-20261009-R1-C05 V2 manifest','T023-CONC-PACK-20261009-R1-C05-manifest','1',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C05-v1','T023-CONC-PACK-20261009-R1-C05-importer',decode(md5('T023-CONC-PACK-20261009-R1-C05-V2-c1')||md5('T023-CONC-PACK-20261009-R1-C05-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_import,mk.reference_value_id,'T023-CONC-PACK-20261009-R1-C05-V2-SHEET',2,'A2:Q2','T023-CONC-PACK-20261009-R1-C05-raw','1',jsonb_build_object('sheet','T023-CONC-PACK-20261009-R1-C05-V2-SHEET','row',2,'range','A2:Q2','cells',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V2')),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V2') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_identity,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C05','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_mapping,v_baseline,v_row,v_identity,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_mapping,'MedicationRequest.status','T023-CONC-PACK-20261009-R1-C05','T023-CONC-PACK-20261009-R1-C05-V2.source','LOCAL','T023-CONC-PACK-20261009-R1-C05 V2 mapping');
end $cp12$;
commit;
select 'CP12' checkpoint,'COMPLETE' state,'C05' case_id,'023c0511-0000-4000-8000-000000000001'::uuid baseline_id,'023c0512-0000-4000-8000-000000000001'::uuid artifact_id,'023c0513-0000-4000-8000-000000000001'::uuid import_id,'023c0517-0000-4000-8000-000000000001'::uuid mapping_record_id;

-- CP13 - C06 V1
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp13$
declare v_series uuid:='023c0600-0000-4000-8000-000000000006'; v_baseline uuid:='023c0601-0000-4000-8000-000000000001'; v_artifact uuid:='023c0602-0000-4000-8000-000000000001'; v_import uuid:='023c0603-0000-4000-8000-000000000001'; v_manifest uuid:='023c0604-0000-4000-8000-000000000001'; v_row uuid:='023c0605-0000-4000-8000-000000000001'; v_identity uuid:='023c0606-0000-4000-8000-000000000001'; v_mapping uuid:='023c0607-0000-4000-8000-000000000001'; v_actor uuid:='023c06a0-0000-4000-8000-000000000001'; v_hash text:=md5('T023-CONC-PACK-20261009-R1-C06-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V1-node-2');
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0513-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP13: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C06-V1','T023-CONC-PACK-20261009-R1-C06-V1',false,'T023-CONC-PACK-20261009-R1-C06-v1','T023-CONC-PACK-20261009-R1-C06 Promotion V1',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C06-V1-a1')||md5('T023-CONC-PACK-20261009-R1-C06-V1-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C06-V1.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C06 V1 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C06 V1 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_manifest,v_artifact,'T023-CONC-PACK-20261009-R1-C06-V1-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T023-CONC-PACK-20261009-R1-C06 V1 manifest','T023-CONC-PACK-20261009-R1-C06-manifest','1',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V1') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C06-v1','T023-CONC-PACK-20261009-R1-C06-importer',decode(md5('T023-CONC-PACK-20261009-R1-C06-V1-c1')||md5('T023-CONC-PACK-20261009-R1-C06-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_import,mk.reference_value_id,'T023-CONC-PACK-20261009-R1-C06-V1-SHEET',2,'A2:Q2','T023-CONC-PACK-20261009-R1-C06-raw','1',jsonb_build_object('sheet','T023-CONC-PACK-20261009-R1-C06-V1-SHEET','row',2,'range','A2:Q2','cells',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V1')),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V1') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_identity,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C06','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V1') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_mapping,v_baseline,v_row,v_identity,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_mapping,'MedicationRequest.status','T023-CONC-PACK-20261009-R1-C06','T023-CONC-PACK-20261009-R1-C06-V1.source','LOCAL','T023-CONC-PACK-20261009-R1-C06 V1 mapping');
end $cp13$;
commit;
select 'CP13' checkpoint,'COMPLETE' state,'C06' case_id,'023c0601-0000-4000-8000-000000000001'::uuid baseline_id,'023c0602-0000-4000-8000-000000000001'::uuid artifact_id,'023c0603-0000-4000-8000-000000000001'::uuid import_id,'023c0607-0000-4000-8000-000000000001'::uuid mapping_record_id;

-- CP14 - C06 V2
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp14$
declare v_series uuid:='023c0600-0000-4000-8000-000000000006'; v_baseline uuid:='023c0611-0000-4000-8000-000000000001'; v_artifact uuid:='023c0612-0000-4000-8000-000000000001'; v_import uuid:='023c0613-0000-4000-8000-000000000001'; v_manifest uuid:='023c0614-0000-4000-8000-000000000001'; v_row uuid:='023c0615-0000-4000-8000-000000000001'; v_identity uuid:='023c0616-0000-4000-8000-000000000001'; v_mapping uuid:='023c0617-0000-4000-8000-000000000001'; v_actor uuid:='023c06a0-0000-4000-8000-000000000001'; v_hash text:=md5('T023-CONC-PACK-20261009-R1-C06-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V2-node-2');
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0603-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP14: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C06-V2','T023-CONC-PACK-20261009-R1-C06-V2',false,'T023-CONC-PACK-20261009-R1-C06-v1','T023-CONC-PACK-20261009-R1-C06 Promotion V2',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C06-V2-a1')||md5('T023-CONC-PACK-20261009-R1-C06-V2-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C06-V2.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C06 V2 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C06 V2 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.artifact_sheet_manifest(artifact_sheet_manifest_id,artifact_id,sheet_name,sheet_order,sheet_classification_value_id,is_present,is_authoritative,header_row_number,candidate_range,governed_column_range,candidate_row_count,notes,manifest_schema_id,manifest_schema_version,manifest_json) select v_manifest,v_artifact,'T023-CONC-PACK-20261009-R1-C06-V2-SHEET',1,v.reference_value_id,true,true,1,'A2:Q2','A:Q',1,'T023-CONC-PACK-20261009-R1-C06 V2 manifest','T023-CONC-PACK-20261009-R1-C06-manifest','1',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='SHEET_CLASSIFICATION' and v.value_code='AUTHORITATIVE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C06-v1','T023-CONC-PACK-20261009-R1-C06-importer',decode(md5('T023-CONC-PACK-20261009-R1-C06-V2-c1')||md5('T023-CONC-PACK-20261009-R1-C06-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
  insert into s2t_fhir.import_candidate_row(import_candidate_row_id,import_run_id,mapping_kind_value_id,source_sheet_name,source_row_number,source_cell_range,raw_schema_id,raw_schema_version,raw_source_row,source_row_hash,normalization_algorithm_version,logical_key_algorithm_version,candidate_disposition_value_id,calculated_logical_key,logical_key_components_json) select v_row,v_import,mk.reference_value_id,'T023-CONC-PACK-20261009-R1-C06-V2-SHEET',2,'A2:Q2','T023-CONC-PACK-20261009-R1-C06-raw','1',jsonb_build_object('sheet','T023-CONC-PACK-20261009-R1-C06-V2-SHEET','row',2,'range','A2:Q2','cells',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V2')),decode(v_hash,'hex'),'v1','v1',disp.reference_value_id,'me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V2') from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value disp join s2t_fhir.reference_domain dd on dd.reference_domain_id=disp.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='CANDIDATE_DISPOSITION' and disp.value_code='ACCEPTED';
  insert into s2t_fhir.logical_mapping_identity(logical_mapping_identity_id,mapping_kind_value_id,source_system,fhir_resource,key_algorithm_version,logical_key,key_components_json) select v_identity,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C06','MedicationRequest','v1','me:v1:'||v_hash,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V2') from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='MAPPING_KIND' and v.value_code='ELEMENT_MAPPING';
  insert into s2t_fhir.mapping_record(mapping_record_id,baseline_version_id,import_candidate_row_id,logical_mapping_identity_id,mapping_kind_value_id,decision_status_value_id) select v_mapping,v_baseline,v_row,v_identity,mk.reference_value_id,ds.reference_value_id from s2t_fhir.reference_value mk join s2t_fhir.reference_domain md on md.reference_domain_id=mk.reference_domain_id cross join s2t_fhir.reference_value ds join s2t_fhir.reference_domain dd on dd.reference_domain_id=ds.reference_domain_id where md.domain_code='MAPPING_KIND' and mk.value_code='ELEMENT_MAPPING' and dd.domain_code='DECISION_STATUS' and ds.value_code='FINAL';
  insert into s2t_fhir.element_mapping(mapping_record_id,target_fhir_path,source_system_raw,source_expression,profile_context,notes) values(v_mapping,'MedicationRequest.status','T023-CONC-PACK-20261009-R1-C06','T023-CONC-PACK-20261009-R1-C06-V2.source','LOCAL','T023-CONC-PACK-20261009-R1-C06 V2 mapping');
end $cp14$;
commit;
select 'CP14' checkpoint,'COMPLETE' state,'C06' case_id,'023c0611-0000-4000-8000-000000000001'::uuid baseline_id,'023c0612-0000-4000-8000-000000000001'::uuid artifact_id,'023c0613-0000-4000-8000-000000000001'::uuid import_id,'023c0617-0000-4000-8000-000000000001'::uuid mapping_record_id;

-- CP15-CP19 - C06 V3 and the four C07 baselines.
-- The repeated compact shape remains one transaction per finalized baseline.

-- CP15 - C06 unpublished V3
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp15$
declare v_series uuid:='023c0600-0000-4000-8000-000000000006'; v_baseline uuid:='023c0621-0000-4000-8000-000000000001'; v_artifact uuid:='023c0622-0000-4000-8000-000000000001'; v_import uuid:='023c0623-0000-4000-8000-000000000001'; v_actor uuid:='023c06b0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0613-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP15: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C06-V3','T023-CONC-PACK-20261009-R1-C06-V3',false,'T023-CONC-PACK-20261009-R1-C06-v1','T023-CONC-PACK-20261009-R1-C06 unpublished V3',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C06-V3-a1')||md5('T023-CONC-PACK-20261009-R1-C06-V3-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C06-V3.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C06 V3 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C06 V3 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C06-v1','T023-CONC-PACK-20261009-R1-C06-importer',decode(md5('T023-CONC-PACK-20261009-R1-C06-V3-c1')||md5('T023-CONC-PACK-20261009-R1-C06-V3-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp15$;
commit;
select 'CP15' checkpoint,'COMPLETE' state,'C06' case_id,'023c0621-0000-4000-8000-000000000001'::uuid baseline_id,'023c0622-0000-4000-8000-000000000001'::uuid artifact_id,'023c0623-0000-4000-8000-000000000001'::uuid import_id;

-- CP16 - C07 series A V1
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp16$
declare v_series uuid:='023c0700-0000-4000-8000-000000000071'; v_baseline uuid:='023c0701-0000-4000-8000-000000000001'; v_artifact uuid:='023c0702-0000-4000-8000-000000000001'; v_import uuid:='023c0703-0000-4000-8000-000000000001'; v_actor uuid:='023c07a0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0623-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP16: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C07-A-V1','T023-CONC-PACK-20261009-R1-C07-A-V1',false,'T023-CONC-PACK-20261009-R1-C07-A-v1','T023-CONC-PACK-20261009-R1-C07 series A V1',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C07-A-V1-a1')||md5('T023-CONC-PACK-20261009-R1-C07-A-V1-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C07-A-V1.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C07 A V1 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C07 A V1 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C07-A-v1','T023-CONC-PACK-20261009-R1-C07-A-importer',decode(md5('T023-CONC-PACK-20261009-R1-C07-A-V1-c1')||md5('T023-CONC-PACK-20261009-R1-C07-A-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp16$;
commit;
select 'CP16' checkpoint,'COMPLETE' state,'C07-A' case_id,'023c0701-0000-4000-8000-000000000001'::uuid baseline_id,'023c0702-0000-4000-8000-000000000001'::uuid artifact_id,'023c0703-0000-4000-8000-000000000001'::uuid import_id;

-- CP17 - C07 series A V2
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp17$
declare v_series uuid:='023c0700-0000-4000-8000-000000000071'; v_baseline uuid:='023c0711-0000-4000-8000-000000000001'; v_artifact uuid:='023c0712-0000-4000-8000-000000000001'; v_import uuid:='023c0713-0000-4000-8000-000000000001'; v_actor uuid:='023c07a0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0703-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP17: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C07-A-V2','T023-CONC-PACK-20261009-R1-C07-A-V2',false,'T023-CONC-PACK-20261009-R1-C07-A-v1','T023-CONC-PACK-20261009-R1-C07 series A V2',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C07-A-V2-a1')||md5('T023-CONC-PACK-20261009-R1-C07-A-V2-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C07-A-V2.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C07 A V2 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C07 A V2 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C07-A-v1','T023-CONC-PACK-20261009-R1-C07-A-importer',decode(md5('T023-CONC-PACK-20261009-R1-C07-A-V2-c1')||md5('T023-CONC-PACK-20261009-R1-C07-A-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp17$;
commit;
select 'CP17' checkpoint,'COMPLETE' state,'C07-A' case_id,'023c0711-0000-4000-8000-000000000001'::uuid baseline_id,'023c0712-0000-4000-8000-000000000001'::uuid artifact_id,'023c0713-0000-4000-8000-000000000001'::uuid import_id;

-- CP18 - C07 series B V1
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp18$
declare v_series uuid:='023c0700-0000-4000-8000-000000000072'; v_baseline uuid:='023c0781-0000-4000-8000-000000000001'; v_artifact uuid:='023c0782-0000-4000-8000-000000000001'; v_import uuid:='023c0783-0000-4000-8000-000000000001'; v_actor uuid:='023c07b0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0713-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP18: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C07-B-V1','T023-CONC-PACK-20261009-R1-C07-B-V1',false,'T023-CONC-PACK-20261009-R1-C07-B-v1','T023-CONC-PACK-20261009-R1-C07 series B V1',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C07-B-V1-a1')||md5('T023-CONC-PACK-20261009-R1-C07-B-V1-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C07-B-V1.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C07 B V1 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C07 B V1 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C07-B-v1','T023-CONC-PACK-20261009-R1-C07-B-importer',decode(md5('T023-CONC-PACK-20261009-R1-C07-B-V1-c1')||md5('T023-CONC-PACK-20261009-R1-C07-B-V1-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp18$;
commit;
select 'CP18' checkpoint,'COMPLETE' state,'C07-B' case_id,'023c0781-0000-4000-8000-000000000001'::uuid baseline_id,'023c0782-0000-4000-8000-000000000001'::uuid artifact_id,'023c0783-0000-4000-8000-000000000001'::uuid import_id;

-- CP19 - C07 series B V2
begin;
set local role s2t_fhir_owner;
set constraints all deferred;
do $cp19$
declare v_series uuid:='023c0700-0000-4000-8000-000000000072'; v_baseline uuid:='023c0791-0000-4000-8000-000000000001'; v_artifact uuid:='023c0792-0000-4000-8000-000000000001'; v_import uuid:='023c0793-0000-4000-8000-000000000001'; v_actor uuid:='023c07b0-0000-4000-8000-000000000001';
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0783-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_version where baseline_version_id=v_baseline)
     or exists(select 1 from s2t_fhir.artifact where artifact_id=v_artifact)
     or exists(select 1 from s2t_fhir.import_run where import_run_id=v_import)
  then raise exception 'CP19: prerequisite missing or checkpoint already/partially present' using errcode='55000'; end if;
  insert into s2t_fhir.baseline_version(baseline_version_id,baseline_series_id,baseline_code,version_label,is_gold_standard,import_specification_version,description,created_by_principal_id) values(v_baseline,v_series,'T023-CONC-PACK-20261009-R1-C07-B-V2','T023-CONC-PACK-20261009-R1-C07-B-V2',false,'T023-CONC-PACK-20261009-R1-C07-B-v1','T023-CONC-PACK-20261009-R1-C07 series B V2',v_actor);
  insert into s2t_fhir.artifact(artifact_id,artifact_kind_value_id,sha256_digest,byte_size,media_type,physical_filename,captured_at,description,created_by_principal_id) select v_artifact,v.reference_value_id,decode(md5('T023-CONC-PACK-20261009-R1-C07-B-V2-a1')||md5('T023-CONC-PACK-20261009-R1-C07-B-V2-a2'),'hex'),1,'application/test','T023-CONC-PACK-20261009-R1-C07-B-V2.xlsx',transaction_timestamp(),'T023-CONC-PACK-20261009-R1-C07 B V2 artifact',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_KIND' and v.value_code='WORKBOOK';
  insert into s2t_fhir.baseline_artifact(baseline_version_id,artifact_id,artifact_role_value_id,note,created_by_principal_id) select v_baseline,v_artifact,v.reference_value_id,'T023-CONC-PACK-20261009-R1-C07 B V2 authoritative',v_actor from s2t_fhir.reference_value v join s2t_fhir.reference_domain d using(reference_domain_id) where d.domain_code='ARTIFACT_ROLE' and v.value_code='AUTHORITATIVE_SOURCE';
  insert into s2t_fhir.import_run(import_run_id,baseline_version_id,artifact_id,import_policy_value_id,import_specification_version,importer_version,configuration_digest,started_at,completed_at,terminal_status_value_id,actor_principal_id) select v_import,v_baseline,v_artifact,p.reference_value_id,'T023-CONC-PACK-20261009-R1-C07-B-v1','T023-CONC-PACK-20261009-R1-C07-B-importer',decode(md5('T023-CONC-PACK-20261009-R1-C07-B-V2-c1')||md5('T023-CONC-PACK-20261009-R1-C07-B-V2-c2'),'hex'),transaction_timestamp()-interval '2 seconds',transaction_timestamp()-interval '1 second',s.reference_value_id,v_actor from s2t_fhir.reference_value p join s2t_fhir.reference_domain pd on pd.reference_domain_id=p.reference_domain_id cross join s2t_fhir.reference_value s join s2t_fhir.reference_domain sd on sd.reference_domain_id=s.reference_domain_id where pd.domain_code='IMPORT_POLICY' and p.value_code='CLEAN_IMPORT' and sd.domain_code='IMPORT_RUN_STATUS' and s.value_code='COMMITTED';
end $cp19$;
commit;
select 'CP19' checkpoint,'COMPLETE' state,'C07-B' case_id,'023c0791-0000-4000-8000-000000000001'::uuid baseline_id,'023c0792-0000-4000-8000-000000000001'::uuid artifact_id,'023c0793-0000-4000-8000-000000000001'::uuid import_id;

-- ---------------------------------------------------------------------------
-- CP20 - publish the seed Candidates through authenticated Migration 023 APIs
-- No import is finalized in this transaction.
-- ---------------------------------------------------------------------------
begin;
set constraints all deferred;
do $cp20_guard$
begin
  if not exists(select 1 from s2t_fhir.import_run where import_run_id='023c0793-0000-4000-8000-000000000001')
     or exists (
       select 1 from s2t_fhir.baseline_lifecycle_event
       where baseline_version_id in (
         '023c0201-0000-4000-8000-000000000001','023c0301-0000-4000-8000-000000000001',
         '023c0401-0000-4000-8000-000000000001','023c0501-0000-4000-8000-000000000001',
         '023c0601-0000-4000-8000-000000000001','023c0701-0000-4000-8000-000000000001',
         '023c0781-0000-4000-8000-000000000001'
       )
     ) then
    raise exception 'CP20: finalization prefix incomplete or Candidate publication already/partially present'
      using errcode='55000';
  end if;
end $cp20_guard$;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c02a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0201-0000-4000-8000-000000000001','023c0203-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
select set_config('request.jwt.claim.sub','023c03b1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0301-0000-4000-8000-000000000001','023c0303-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
select set_config('request.jwt.claim.sub','023c04b1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0401-0000-4000-8000-000000000001','023c0403-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
select set_config('request.jwt.claim.sub','023c05a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0501-0000-4000-8000-000000000001','023c0503-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
select set_config('request.jwt.claim.sub','023c06a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0601-0000-4000-8000-000000000001','023c0603-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
select set_config('request.jwt.claim.sub','023c07a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0701-0000-4000-8000-000000000001','023c0703-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
select set_config('request.jwt.claim.sub','023c07b1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0781-0000-4000-8000-000000000001','023c0783-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;

select 'CP20' checkpoint,'COMPLETE' state,b.baseline_version_id,
       c.candidate_lifecycle_event_id,c.baseline_candidate_context_id,c.import_run_id
from s2t_fhir.baseline_candidate_context c
join s2t_fhir.baseline_version b using(baseline_version_id)
where b.baseline_version_id in (
  '023c0201-0000-4000-8000-000000000001','023c0301-0000-4000-8000-000000000001',
  '023c0401-0000-4000-8000-000000000001','023c0501-0000-4000-8000-000000000001',
  '023c0601-0000-4000-8000-000000000001','023c0701-0000-4000-8000-000000000001',
  '023c0781-0000-4000-8000-000000000001'
)
order by b.baseline_version_id;

-- ---------------------------------------------------------------------------
-- CP21 - C03 OPEN_CURRENT session and C04 open governance question
-- Candidate Governance uses the verified S2T_REVIEW_WRITE path.
-- ---------------------------------------------------------------------------
begin;
set constraints all deferred;
create temp table pg_temp.cp21_candidate_context (
  baseline_version_id uuid primary key,
  candidate_lifecycle_event_id uuid not null
) on commit drop;
do $cp21_guard$
declare
  v_c03_context_count integer;
  v_c03_candidate_lifecycle_event_id uuid;
begin
  select count(*), min(candidate_lifecycle_event_id::text)::uuid
    into v_c03_context_count, v_c03_candidate_lifecycle_event_id
  from s2t_fhir.baseline_candidate_context
  where baseline_version_id='023c0301-0000-4000-8000-000000000001';

  if (select count(*) from s2t_fhir.baseline_candidate_context
      where baseline_version_id in ('023c0301-0000-4000-8000-000000000001','023c0401-0000-4000-8000-000000000001')) <> 2
     or exists (select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT')
     or exists (select 1 from s2t_governance.governance_question where title='T023-CONC-PACK-20261009-R1-C04-QUESTION') then
    raise exception 'CP21: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;

  if v_c03_context_count <> 1
     or v_c03_candidate_lifecycle_event_id is null
     or v_c03_candidate_lifecycle_event_id <> '3c4e4bad-0c47-4b48-864e-bd4000d67c9a'::uuid then
    raise exception 'CP21: C03 current Candidate lifecycle event is null, ambiguous, or unexpected' using errcode='55000';
  end if;

  insert into pg_temp.cp21_candidate_context (
    baseline_version_id,
    candidate_lifecycle_event_id
  ) values (
    '023c0301-0000-4000-8000-000000000001',
    v_c03_candidate_lifecycle_event_id
  );
end $cp21_guard$;

grant select on pg_temp.cp21_candidate_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c03a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.start_authenticated_candidate_review_session(
  '023c0301-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp21_candidate_context where baseline_version_id='023c0301-0000-4000-8000-000000000001'),
  'T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT',
  'T023-CONC-PACK-20261009-R1-C03 rollback-only concurrency review session');

select set_config('request.jwt.claim.sub','023c04a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.gov_open_question(
  'T023-CONC-PACK-20261009-R1-C04-QUESTION',
  'T023-CONC-PACK-20261009-R1-C04 synthetic Candidate governance concurrency question',
  transaction_timestamp(),
  '[]'::jsonb);
reset role;
commit;

select 'CP21' checkpoint,'COMPLETE' state,
       (select review_session_id from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C03-OPEN_CURRENT') as c03_review_session_id,
       (select question_id from s2t_governance.governance_question where title='T023-CONC-PACK-20261009-R1-C04-QUESTION') as c04_question_id;

-- ---------------------------------------------------------------------------
-- CP22A - fully review C05 V1 through the governed workflow
-- ---------------------------------------------------------------------------
begin;
set constraints all deferred;
create temp table pg_temp.cp22a_candidate_review_context (
  baseline_version_id uuid primary key,
  candidate_lifecycle_event_id uuid not null,
  review_session_id uuid
) on commit drop;
do $cp22_guard$
declare
  v_candidate_context_count integer;
  v_candidate_lifecycle_event_id uuid;
begin
  select count(*), min(candidate_lifecycle_event_id::text)::uuid
    into v_candidate_context_count, v_candidate_lifecycle_event_id
  from s2t_fhir.baseline_candidate_context
  where baseline_version_id='023c0501-0000-4000-8000-000000000001';

  if not exists(select 1 from s2t_fhir.baseline_candidate_context where baseline_version_id='023c0501-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V1-REVIEW')
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0508-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0509-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='023c0501-0000-4000-8000-000000000001') then
    raise exception 'CP22: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;

  if v_candidate_context_count <> 1 or v_candidate_lifecycle_event_id is null then
    raise exception 'CP22A: C05 V1 current Candidate context is missing, ambiguous, or null' using errcode='55000';
  end if;

  insert into pg_temp.cp22a_candidate_review_context (
    baseline_version_id,
    candidate_lifecycle_event_id
  ) values (
    '023c0501-0000-4000-8000-000000000001',
    v_candidate_lifecycle_event_id
  );
end $cp22_guard$;

grant select, update (review_session_id) on pg_temp.cp22a_candidate_review_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c05a1-0000-4000-8000-000000000001',true);
update pg_temp.cp22a_candidate_review_context
set review_session_id = s2t_fhir_api.start_authenticated_candidate_review_session(
  baseline_version_id,
  candidate_lifecycle_event_id,
  'T023-CONC-PACK-20261009-R1-C05-V1-REVIEW',
  'T023-CONC-PACK-20261009-R1-C05-V1 complete Promotion review');
do $cp22a_session_guard$
begin
  if (select review_session_id from pg_temp.cp22a_candidate_review_context) is null then
    raise exception 'CP22A: authenticated review session creation returned no session ID' using errcode='55000';
  end if;
end $cp22a_session_guard$;
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
  '023c0501-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp22a_candidate_review_context),
  'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C05-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V1-node-2'),
  (select review_session_id from pg_temp.cp22a_candidate_review_context),
  'T023-CONC-PACK-20261009-R1-C05-V1 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session(
  '023c0501-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp22a_candidate_review_context),
  (select review_session_id from pg_temp.cp22a_candidate_review_context));
reset role;

commit;
select 'CP22A' checkpoint,'COMPLETE' state,
       (select review_session_id from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V1-REVIEW') review_session_id;

-- CP22B - create complete passing validation/gate evidence for C05 V1
begin;
set constraints all deferred;
do $cp22b_guard$
begin
  if not exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V1-REVIEW' and ended_at is not null)
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0508-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0509-0000-4000-8000-000000000001') then
    raise exception 'CP22B: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;
end $cp22b_guard$;

set local role s2t_fhir_owner;
insert into s2t_fhir.validation_run
  (validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,
   started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,
   outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '023c0508-0000-4000-8000-000000000001','023c0503-0000-4000-8000-000000000001',ruleset.validation_ruleset_id,
       '023c0502-0000-4000-8000-000000000001',artifact.sha256_digest,
       decode(md5('T023-CONC-PACK-20261009-R1-C05-V1-validation-1')||md5('T023-CONC-PACK-20261009-R1-C05-V1-validation-2'),'hex'),
       transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,outcome.reference_value_id,
       '023c05a0-0000-4000-8000-000000000001','023c05a0-0000-4000-8000-000000000001',
       jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V1')
from s2t_fhir.validation_ruleset ruleset
join s2t_fhir.artifact artifact on artifact.artifact_id='023c0502-0000-4000-8000-000000000001'
join s2t_fhir.reference_value outcome on outcome.value_code='PASS'
join s2t_fhir.reference_domain od on od.reference_domain_id=outcome.reference_domain_id and od.domain_code='VALIDATION_OUTCOME'
where ruleset.ruleset_code='BASELINE_IMPORT' and ruleset.version_label='v1';

insert into s2t_fhir.release_gate_evaluation
  (release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,
   validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,
   initiating_human_principal_id,summary)
select '023c0509-0000-4000-8000-000000000001','023c0501-0000-4000-8000-000000000001',gate.release_gate_definition_id,
       '023c0502-0000-4000-8000-000000000001',artifact.sha256_digest,ruleset.validation_ruleset_id,
       '023c0508-0000-4000-8000-000000000001',outcome.reference_value_id,transaction_timestamp(),
       '023c05a0-0000-4000-8000-000000000001','023c05a0-0000-4000-8000-000000000001',
       'T023-CONC-PACK-20261009-R1-C05-V1 PASSED'
from s2t_fhir.release_gate_definition gate
join s2t_fhir.validation_ruleset ruleset on ruleset.ruleset_code='BASELINE_IMPORT' and ruleset.version_label='v1'
join s2t_fhir.artifact artifact on artifact.artifact_id='023c0502-0000-4000-8000-000000000001'
join s2t_fhir.reference_value outcome on outcome.value_code='PASSED'
join s2t_fhir.reference_domain od on od.reference_domain_id=outcome.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME'
where gate.gate_code='BASELINE_IMPORT' and gate.version_label='v1';
insert into s2t_fhir.release_gate_result
  (release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '023c0509-0000-4000-8000-000000000001',req.release_gate_requirement_id,outcome.reference_value_id,
       jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V1','requirement',req.requirement_code),
       'T023-CONC-PACK-20261009-R1-C05-V1 '||req.requirement_code
from s2t_fhir.release_gate_requirement req
join s2t_fhir.release_gate_definition gate using(release_gate_definition_id)
join s2t_fhir.reference_value outcome on outcome.value_code='PASSED'
join s2t_fhir.reference_domain od on od.reference_domain_id=outcome.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME'
where gate.gate_code='BASELINE_IMPORT' and gate.version_label='v1';
reset role;

commit;
select 'CP22B' checkpoint,'COMPLETE' state,'023c0508-0000-4000-8000-000000000001'::uuid validation_run_id,
       '023c0509-0000-4000-8000-000000000001'::uuid release_gate_evaluation_id;

-- CP22C - promote C05 V1 only after committed review and gate evidence
begin;
set constraints all deferred;
create temp table pg_temp.cp22c_candidate_context (
  baseline_version_id uuid primary key,
  candidate_lifecycle_event_id uuid not null
) on commit drop;
do $cp22c_guard$
declare
  v_candidate_context_count integer;
  v_candidate_lifecycle_event_id uuid;
begin
  select count(*), min(candidate_lifecycle_event_id::text)::uuid
    into v_candidate_context_count, v_candidate_lifecycle_event_id
  from s2t_fhir.baseline_candidate_context
  where baseline_version_id='023c0501-0000-4000-8000-000000000001';

  if not exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0509-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='023c0501-0000-4000-8000-000000000001') then
    raise exception 'CP22C: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;

  if v_candidate_context_count <> 1 or v_candidate_lifecycle_event_id is null then
    raise exception 'CP22C: C05 V1 current Candidate context is missing, ambiguous, or null' using errcode='55000';
  end if;

  insert into pg_temp.cp22c_candidate_context values (
    '023c0501-0000-4000-8000-000000000001',
    v_candidate_lifecycle_event_id
  );
end $cp22c_guard$;

grant select on pg_temp.cp22c_candidate_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c05a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.promote_candidate_baseline(
  '023c0501-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp22c_candidate_context),
  '023c0503-0000-4000-8000-000000000001','023c0509-0000-4000-8000-000000000001',
  null,null,transaction_timestamp(),null);
reset role;
commit;

select 'CP22C' checkpoint,'COMPLETE' state,'C05' case_id,c.baseline_activation_context_id,
       c.active_lifecycle_event_id,c.release_gate_evaluation_id
from s2t_fhir.baseline_activation_context c where c.baseline_version_id='023c0501-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------------
-- CP23A - publish C05 V2 after C05 V1 Promotion
-- ---------------------------------------------------------------------------
begin;
set constraints all deferred;
do $cp23_guard$
begin
  if not exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='023c0501-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_lifecycle_event where baseline_version_id='023c0511-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0518-0000-4000-8000-000000000001') then
    raise exception 'CP23: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;
end $cp23_guard$;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c05a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0511-0000-4000-8000-000000000001','023c0513-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'CP23A' checkpoint,'COMPLETE' state,c.candidate_lifecycle_event_id,c.baseline_candidate_context_id
from s2t_fhir.baseline_candidate_context c where c.baseline_version_id='023c0511-0000-4000-8000-000000000001';

-- CP23B - fully review C05 V2 in a later committed transaction
begin;
set constraints all deferred;
create temp table pg_temp.cp23b_candidate_review_context (
  baseline_version_id uuid primary key,
  candidate_lifecycle_event_id uuid not null,
  review_session_id uuid
) on commit drop;
do $cp23b_guard$
declare
  v_candidate_context_count integer;
  v_candidate_lifecycle_event_id uuid;
begin
  select count(*), min(candidate_lifecycle_event_id::text)::uuid
    into v_candidate_context_count, v_candidate_lifecycle_event_id
  from s2t_fhir.baseline_candidate_context
  where baseline_version_id='023c0511-0000-4000-8000-000000000001';

  if not exists(select 1 from s2t_fhir.baseline_candidate_context where baseline_version_id='023c0511-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V2-REVIEW') then
    raise exception 'CP23B: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;

  if v_candidate_context_count <> 1 or v_candidate_lifecycle_event_id is null then
    raise exception 'CP23B: C05 V2 current Candidate context is missing, ambiguous, or null' using errcode='55000';
  end if;

  insert into pg_temp.cp23b_candidate_review_context (
    baseline_version_id,
    candidate_lifecycle_event_id
  ) values (
    '023c0511-0000-4000-8000-000000000001',
    v_candidate_lifecycle_event_id
  );
end $cp23b_guard$;

grant select, update (review_session_id) on pg_temp.cp23b_candidate_review_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c05a1-0000-4000-8000-000000000001',true);
update pg_temp.cp23b_candidate_review_context
set review_session_id = s2t_fhir_api.start_authenticated_candidate_review_session(
  baseline_version_id,
  candidate_lifecycle_event_id,
  'T023-CONC-PACK-20261009-R1-C05-V2-REVIEW',
  'T023-CONC-PACK-20261009-R1-C05-V2 complete Promotion review');
do $cp23b_session_guard$
begin
  if (select review_session_id from pg_temp.cp23b_candidate_review_context) is null then
    raise exception 'CP23B: authenticated review session creation returned no session ID' using errcode='55000';
  end if;
end $cp23b_session_guard$;
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
  '023c0511-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp23b_candidate_review_context),
  'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C05-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C05-V2-node-2'),
  (select review_session_id from pg_temp.cp23b_candidate_review_context),
  'T023-CONC-PACK-20261009-R1-C05-V2 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session(
  '023c0511-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp23b_candidate_review_context),
  (select review_session_id from pg_temp.cp23b_candidate_review_context));
reset role;

commit;
select 'CP23B' checkpoint,'COMPLETE' state,
       (select review_session_id from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V2-REVIEW') review_session_id;

-- CP23C - create complete passing validation/gate evidence for C05 V2
begin;
set constraints all deferred;
do $cp23c_guard$
begin
  if not exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C05-V2-REVIEW' and ended_at is not null)
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0518-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0519-0000-4000-8000-000000000001') then
    raise exception 'CP23C: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;
end $cp23c_guard$;

set local role s2t_fhir_owner;
insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '023c0518-0000-4000-8000-000000000001','023c0513-0000-4000-8000-000000000001',r.validation_ruleset_id,'023c0512-0000-4000-8000-000000000001',a.sha256_digest,decode(md5('T023-CONC-PACK-20261009-R1-C05-V2-validation-1')||md5('T023-CONC-PACK-20261009-R1-C05-V2-validation-2'),'hex'),transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,o.reference_value_id,'023c05a0-0000-4000-8000-000000000001','023c05a0-0000-4000-8000-000000000001',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V2') from s2t_fhir.validation_ruleset r join s2t_fhir.artifact a on a.artifact_id='023c0512-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASS' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='VALIDATION_OUTCOME' where r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1';
insert into s2t_fhir.release_gate_evaluation(release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,initiating_human_principal_id,summary)
select '023c0519-0000-4000-8000-000000000001','023c0511-0000-4000-8000-000000000001',g.release_gate_definition_id,'023c0512-0000-4000-8000-000000000001',a.sha256_digest,r.validation_ruleset_id,'023c0518-0000-4000-8000-000000000001',o.reference_value_id,transaction_timestamp(),'023c05a0-0000-4000-8000-000000000001','023c05a0-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C05-V2 PASSED' from s2t_fhir.release_gate_definition g join s2t_fhir.validation_ruleset r on r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1' join s2t_fhir.artifact a on a.artifact_id='023c0512-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '023c0519-0000-4000-8000-000000000001',req.release_gate_requirement_id,o.reference_value_id,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C05','version','V2','requirement',req.requirement_code),'T023-CONC-PACK-20261009-R1-C05-V2 '||req.requirement_code from s2t_fhir.release_gate_requirement req join s2t_fhir.release_gate_definition g using(release_gate_definition_id) join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
reset role;
commit;

select 'CP23C' checkpoint,'COMPLETE' state,'C05' case_id,c.candidate_lifecycle_event_id,c.baseline_candidate_context_id,
       '023c0518-0000-4000-8000-000000000001'::uuid validation_run_id,'023c0519-0000-4000-8000-000000000001'::uuid release_gate_evaluation_id
from s2t_fhir.baseline_candidate_context c where c.baseline_version_id='023c0511-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------------
-- CP24A - fully review C06 V1 through the governed workflow
-- ---------------------------------------------------------------------------
begin;
set constraints all deferred;
create temp table pg_temp.cp24a_candidate_review_context (
  baseline_version_id uuid primary key,
  candidate_lifecycle_event_id uuid not null,
  review_session_id uuid
) on commit drop;
do $cp24_guard$
declare
  v_candidate_context_count integer;
  v_candidate_lifecycle_event_id uuid;
begin
  select count(*), min(candidate_lifecycle_event_id::text)::uuid
    into v_candidate_context_count, v_candidate_lifecycle_event_id
  from s2t_fhir.baseline_candidate_context
  where baseline_version_id='023c0601-0000-4000-8000-000000000001';

  if not exists(select 1 from s2t_fhir.baseline_candidate_context where baseline_version_id='023c0601-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V1-REVIEW')
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0608-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0609-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='023c0601-0000-4000-8000-000000000001') then
    raise exception 'CP24: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;

  if v_candidate_context_count <> 1 or v_candidate_lifecycle_event_id is null then
    raise exception 'CP24A: C06 V1 current Candidate context is missing, ambiguous, or null' using errcode='55000';
  end if;

  insert into pg_temp.cp24a_candidate_review_context (
    baseline_version_id,
    candidate_lifecycle_event_id
  ) values (
    '023c0601-0000-4000-8000-000000000001',
    v_candidate_lifecycle_event_id
  );
end $cp24_guard$;

grant select, update (review_session_id) on pg_temp.cp24a_candidate_review_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c06a1-0000-4000-8000-000000000001',true);
update pg_temp.cp24a_candidate_review_context
set review_session_id = s2t_fhir_api.start_authenticated_candidate_review_session(
  baseline_version_id,
  candidate_lifecycle_event_id,
  'T023-CONC-PACK-20261009-R1-C06-V1-REVIEW',
  'T023-CONC-PACK-20261009-R1-C06-V1 complete Promotion review');
do $cp24a_session_guard$
begin
  if (select review_session_id from pg_temp.cp24a_candidate_review_context) is null then
    raise exception 'CP24A: authenticated review session creation returned no session ID' using errcode='55000';
  end if;
end $cp24a_session_guard$;
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
  '023c0601-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp24a_candidate_review_context),
  'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C06-V1-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V1-node-2'),
  (select review_session_id from pg_temp.cp24a_candidate_review_context),
  'T023-CONC-PACK-20261009-R1-C06-V1 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session(
  '023c0601-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp24a_candidate_review_context),
  (select review_session_id from pg_temp.cp24a_candidate_review_context));
reset role;

commit;
select 'CP24A' checkpoint,'COMPLETE' state,
       (select review_session_id from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V1-REVIEW') review_session_id;

-- CP24B - create complete passing validation/gate evidence for C06 V1
begin;
set constraints all deferred;
do $cp24b_guard$
begin
  if not exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V1-REVIEW' and ended_at is not null)
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0608-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0609-0000-4000-8000-000000000001') then
    raise exception 'CP24B: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;
end $cp24b_guard$;

set local role s2t_fhir_owner;
insert into s2t_fhir.validation_run
  (validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,
   started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,
   outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '023c0608-0000-4000-8000-000000000001','023c0603-0000-4000-8000-000000000001',ruleset.validation_ruleset_id,
       '023c0602-0000-4000-8000-000000000001',artifact.sha256_digest,
       decode(md5('T023-CONC-PACK-20261009-R1-C06-V1-validation-1')||md5('T023-CONC-PACK-20261009-R1-C06-V1-validation-2'),'hex'),
       transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,outcome.reference_value_id,
       '023c06a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001',
       jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V1')
from s2t_fhir.validation_ruleset ruleset
join s2t_fhir.artifact artifact on artifact.artifact_id='023c0602-0000-4000-8000-000000000001'
join s2t_fhir.reference_value outcome on outcome.value_code='PASS'
join s2t_fhir.reference_domain od on od.reference_domain_id=outcome.reference_domain_id and od.domain_code='VALIDATION_OUTCOME'
where ruleset.ruleset_code='BASELINE_IMPORT' and ruleset.version_label='v1';

insert into s2t_fhir.release_gate_evaluation
  (release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,
   validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,
   initiating_human_principal_id,summary)
select '023c0609-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001',gate.release_gate_definition_id,
       '023c0602-0000-4000-8000-000000000001',artifact.sha256_digest,ruleset.validation_ruleset_id,
       '023c0608-0000-4000-8000-000000000001',outcome.reference_value_id,transaction_timestamp(),
       '023c06a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001',
       'T023-CONC-PACK-20261009-R1-C06-V1 PASSED'
from s2t_fhir.release_gate_definition gate
join s2t_fhir.validation_ruleset ruleset on ruleset.ruleset_code='BASELINE_IMPORT' and ruleset.version_label='v1'
join s2t_fhir.artifact artifact on artifact.artifact_id='023c0602-0000-4000-8000-000000000001'
join s2t_fhir.reference_value outcome on outcome.value_code='PASSED'
join s2t_fhir.reference_domain od on od.reference_domain_id=outcome.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME'
where gate.gate_code='BASELINE_IMPORT' and gate.version_label='v1';
insert into s2t_fhir.release_gate_result
  (release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '023c0609-0000-4000-8000-000000000001',req.release_gate_requirement_id,outcome.reference_value_id,
       jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V1','requirement',req.requirement_code),
       'T023-CONC-PACK-20261009-R1-C06-V1 '||req.requirement_code
from s2t_fhir.release_gate_requirement req
join s2t_fhir.release_gate_definition gate using(release_gate_definition_id)
join s2t_fhir.reference_value outcome on outcome.value_code='PASSED'
join s2t_fhir.reference_domain od on od.reference_domain_id=outcome.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME'
where gate.gate_code='BASELINE_IMPORT' and gate.version_label='v1';
reset role;

commit;
select 'CP24B' checkpoint,'COMPLETE' state,'023c0608-0000-4000-8000-000000000001'::uuid validation_run_id,
       '023c0609-0000-4000-8000-000000000001'::uuid release_gate_evaluation_id;

-- CP24C - promote C06 V1 only after committed review and gate evidence
begin;
set constraints all deferred;
create temp table pg_temp.cp24c_candidate_context (
  baseline_version_id uuid primary key,
  candidate_lifecycle_event_id uuid not null
) on commit drop;
do $cp24c_guard$
declare
  v_candidate_context_count integer;
  v_candidate_lifecycle_event_id uuid;
begin
  select count(*), min(candidate_lifecycle_event_id::text)::uuid
    into v_candidate_context_count, v_candidate_lifecycle_event_id
  from s2t_fhir.baseline_candidate_context
  where baseline_version_id='023c0601-0000-4000-8000-000000000001';

  if not exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0609-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='023c0601-0000-4000-8000-000000000001') then
    raise exception 'CP24C: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;

  if v_candidate_context_count <> 1 or v_candidate_lifecycle_event_id is null then
    raise exception 'CP24C: C06 V1 current Candidate context is missing, ambiguous, or null' using errcode='55000';
  end if;

  insert into pg_temp.cp24c_candidate_context values (
    '023c0601-0000-4000-8000-000000000001',
    v_candidate_lifecycle_event_id
  );
end $cp24c_guard$;

grant select on pg_temp.cp24c_candidate_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c06a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.promote_candidate_baseline(
  '023c0601-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp24c_candidate_context),
  '023c0603-0000-4000-8000-000000000001','023c0609-0000-4000-8000-000000000001',
  null,null,transaction_timestamp(),null);
reset role;
commit;

select 'CP24C' checkpoint,'COMPLETE' state,'C06' case_id,c.baseline_activation_context_id,
       c.active_lifecycle_event_id,c.release_gate_evaluation_id
from s2t_fhir.baseline_activation_context c where c.baseline_version_id='023c0601-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------------
-- CP25A - publish C06 V2 after C06 V1 Promotion
-- ---------------------------------------------------------------------------
begin;
set constraints all deferred;
do $cp25_guard$
begin
  if not exists(select 1 from s2t_fhir.baseline_activation_context where baseline_version_id='023c0601-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.baseline_lifecycle_event where baseline_version_id='023c0611-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0618-0000-4000-8000-000000000001') then
    raise exception 'CP25: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;
end $cp25_guard$;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c06a1-0000-4000-8000-000000000001',true);
select s2t_fhir_api.publish_candidate_baseline('023c0611-0000-4000-8000-000000000001','023c0613-0000-4000-8000-000000000001',null,null,transaction_timestamp(),null);
reset role;
commit;
select 'CP25A' checkpoint,'COMPLETE' state,c.candidate_lifecycle_event_id,c.baseline_candidate_context_id
from s2t_fhir.baseline_candidate_context c where c.baseline_version_id='023c0611-0000-4000-8000-000000000001';

-- CP25B - fully review C06 V2 in a later committed transaction
begin;
set constraints all deferred;
create temp table pg_temp.cp25b_candidate_review_context (
  baseline_version_id uuid primary key,
  candidate_lifecycle_event_id uuid not null,
  review_session_id uuid
) on commit drop;
do $cp25b_guard$
declare
  v_candidate_context_count integer;
  v_candidate_lifecycle_event_id uuid;
begin
  select count(*), min(candidate_lifecycle_event_id::text)::uuid
    into v_candidate_context_count, v_candidate_lifecycle_event_id
  from s2t_fhir.baseline_candidate_context
  where baseline_version_id='023c0611-0000-4000-8000-000000000001';

  if not exists(select 1 from s2t_fhir.baseline_candidate_context where baseline_version_id='023c0611-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V2-REVIEW') then
    raise exception 'CP25B: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;

  if v_candidate_context_count <> 1 or v_candidate_lifecycle_event_id is null then
    raise exception 'CP25B: C06 V2 current Candidate context is missing, ambiguous, or null' using errcode='55000';
  end if;

  insert into pg_temp.cp25b_candidate_review_context (
    baseline_version_id,
    candidate_lifecycle_event_id
  ) values (
    '023c0611-0000-4000-8000-000000000001',
    v_candidate_lifecycle_event_id
  );
end $cp25b_guard$;

grant select, update (review_session_id) on pg_temp.cp25b_candidate_review_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','023c06a1-0000-4000-8000-000000000001',true);
update pg_temp.cp25b_candidate_review_context
set review_session_id = s2t_fhir_api.start_authenticated_candidate_review_session(
  baseline_version_id,
  candidate_lifecycle_event_id,
  'T023-CONC-PACK-20261009-R1-C06-V2-REVIEW',
  'T023-CONC-PACK-20261009-R1-C06-V2 complete Promotion review');
do $cp25b_session_guard$
begin
  if (select review_session_id from pg_temp.cp25b_candidate_review_context) is null then
    raise exception 'CP25B: authenticated review session creation returned no session ID' using errcode='55000';
  end if;
end $cp25b_session_guard$;
select s2t_fhir_api.mark_authenticated_candidate_mapping_reviewed(
  '023c0611-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp25b_candidate_review_context),
  'map-v1-'||md5('T023-CONC-PACK-20261009-R1-C06-V2-node-1')||md5('T023-CONC-PACK-20261009-R1-C06-V2-node-2'),
  (select review_session_id from pg_temp.cp25b_candidate_review_context),
  'T023-CONC-PACK-20261009-R1-C06-V2 REVIEWED');
select s2t_fhir_api.end_authenticated_candidate_review_session(
  '023c0611-0000-4000-8000-000000000001',
  (select candidate_lifecycle_event_id from pg_temp.cp25b_candidate_review_context),
  (select review_session_id from pg_temp.cp25b_candidate_review_context));
reset role;

commit;
select 'CP25B' checkpoint,'COMPLETE' state,
       (select review_session_id from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V2-REVIEW') review_session_id;

-- CP25C - create complete passing validation/gate evidence for C06 V2
begin;
set constraints all deferred;
do $cp25c_guard$
begin
  if not exists(select 1 from s2t_fhir.review_session where session_name='T023-CONC-PACK-20261009-R1-C06-V2-REVIEW' and ended_at is not null)
     or exists(select 1 from s2t_fhir.validation_run where validation_run_id='023c0618-0000-4000-8000-000000000001')
     or exists(select 1 from s2t_fhir.release_gate_evaluation where release_gate_evaluation_id='023c0619-0000-4000-8000-000000000001') then
    raise exception 'CP25C: prerequisite missing or checkpoint already/partially present' using errcode='55000';
  end if;
end $cp25c_guard$;

set local role s2t_fhir_owner;
insert into s2t_fhir.validation_run(validation_run_id,import_run_id,validation_ruleset_id,artifact_id,artifact_digest,execution_fingerprint,started_at,completed_at,candidate_count,accepted_count,warning_count,error_count,quarantined_count,outcome_value_id,actor_principal_id,initiating_human_principal_id,summary_json)
select '023c0618-0000-4000-8000-000000000001','023c0613-0000-4000-8000-000000000001',r.validation_ruleset_id,'023c0612-0000-4000-8000-000000000001',a.sha256_digest,decode(md5('T023-CONC-PACK-20261009-R1-C06-V2-validation-1')||md5('T023-CONC-PACK-20261009-R1-C06-V2-validation-2'),'hex'),transaction_timestamp()-interval '2 microseconds',transaction_timestamp()-interval '1 microsecond',1,1,0,0,0,o.reference_value_id,'023c06a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001',jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V2') from s2t_fhir.validation_ruleset r join s2t_fhir.artifact a on a.artifact_id='023c0612-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASS' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='VALIDATION_OUTCOME' where r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1';
insert into s2t_fhir.release_gate_evaluation(release_gate_evaluation_id,baseline_version_id,release_gate_definition_id,artifact_id,artifact_digest,validation_ruleset_id,validation_run_id,gate_outcome_value_id,evaluated_at,actor_principal_id,initiating_human_principal_id,summary)
select '023c0619-0000-4000-8000-000000000001','023c0611-0000-4000-8000-000000000001',g.release_gate_definition_id,'023c0612-0000-4000-8000-000000000001',a.sha256_digest,r.validation_ruleset_id,'023c0618-0000-4000-8000-000000000001',o.reference_value_id,transaction_timestamp(),'023c06a0-0000-4000-8000-000000000001','023c06a0-0000-4000-8000-000000000001','T023-CONC-PACK-20261009-R1-C06-V2 PASSED' from s2t_fhir.release_gate_definition g join s2t_fhir.validation_ruleset r on r.ruleset_code='BASELINE_IMPORT' and r.version_label='v1' join s2t_fhir.artifact a on a.artifact_id='023c0612-0000-4000-8000-000000000001' join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='RELEASE_GATE_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
insert into s2t_fhir.release_gate_result(release_gate_evaluation_id,release_gate_requirement_id,requirement_outcome_value_id,evidence_json,explanation)
select '023c0619-0000-4000-8000-000000000001',req.release_gate_requirement_id,o.reference_value_id,jsonb_build_object('pack','T023-CONC-PACK-20261009-R1','case','C06','version','V2','requirement',req.requirement_code),'T023-CONC-PACK-20261009-R1-C06-V2 '||req.requirement_code from s2t_fhir.release_gate_requirement req join s2t_fhir.release_gate_definition g using(release_gate_definition_id) join s2t_fhir.reference_value o on o.value_code='PASSED' join s2t_fhir.reference_domain od on od.reference_domain_id=o.reference_domain_id and od.domain_code='REQUIREMENT_OUTCOME' where g.gate_code='BASELINE_IMPORT' and g.version_label='v1';
reset role;
commit;

select 'CP25C' checkpoint,'COMPLETE' state,'C06' case_id,c.candidate_lifecycle_event_id,c.baseline_candidate_context_id,
       '023c0618-0000-4000-8000-000000000001'::uuid validation_run_id,'023c0619-0000-4000-8000-000000000001'::uuid release_gate_evaluation_id
from s2t_fhir.baseline_candidate_context c where c.baseline_version_id='023c0611-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------------
-- CP26 - read-only completion marker and post-provisioning global fingerprints
-- The companion verification script emits the complete deterministic manifest.
-- ---------------------------------------------------------------------------
select 'CP26' checkpoint,
       case when
         (select count(*) from s2t_fhir.baseline_series where baseline_series_id in (
           '023c0100-0000-4000-8000-000000000001','023c0200-0000-4000-8000-000000000002',
           '023c0300-0000-4000-8000-000000000003','023c0400-0000-4000-8000-000000000004',
           '023c0500-0000-4000-8000-000000000005','023c0600-0000-4000-8000-000000000006',
           '023c0700-0000-4000-8000-000000000071','023c0700-0000-4000-8000-000000000072'))=8
         and (select count(*) from s2t_fhir.baseline_version where baseline_version_id in (
           '023c0101-0000-4000-8000-000000000001','023c0111-0000-4000-8000-000000000001',
           '023c0201-0000-4000-8000-000000000001','023c0211-0000-4000-8000-000000000001','023c0221-0000-4000-8000-000000000001',
           '023c0301-0000-4000-8000-000000000001','023c0311-0000-4000-8000-000000000001',
           '023c0401-0000-4000-8000-000000000001','023c0411-0000-4000-8000-000000000001',
           '023c0501-0000-4000-8000-000000000001','023c0511-0000-4000-8000-000000000001',
           '023c0601-0000-4000-8000-000000000001','023c0611-0000-4000-8000-000000000001','023c0621-0000-4000-8000-000000000001',
           '023c0701-0000-4000-8000-000000000001','023c0711-0000-4000-8000-000000000001',
           '023c0781-0000-4000-8000-000000000001','023c0791-0000-4000-8000-000000000001'))=18
         and (select count(*) from s2t_fhir.baseline_activation_context where baseline_version_id in ('023c0501-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001'))=2
         and (select count(*) from s2t_fhir.baseline_candidate_context where baseline_version_id in ('023c0511-0000-4000-8000-000000000001','023c0611-0000-4000-8000-000000000001'))=2
       then 'COMPLETE' else 'PARTIAL_OR_AMBIGUOUS' end state,
       'T023-CONC-PACK-20261009-R1' pack_id,
       (select md5(coalesce(string_agg(baseline_series_id::text||':'||baseline_version_id::text||':'||version_label,'|' order by baseline_series_id,version_label),''))
        from s2t_fhir.baseline_version where baseline_version_id in (
          '023c0101-0000-4000-8000-000000000001','023c0111-0000-4000-8000-000000000001','023c0201-0000-4000-8000-000000000001',
          '023c0211-0000-4000-8000-000000000001','023c0221-0000-4000-8000-000000000001','023c0301-0000-4000-8000-000000000001',
          '023c0311-0000-4000-8000-000000000001','023c0401-0000-4000-8000-000000000001','023c0411-0000-4000-8000-000000000001',
          '023c0501-0000-4000-8000-000000000001','023c0511-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001',
          '023c0611-0000-4000-8000-000000000001','023c0621-0000-4000-8000-000000000001','023c0701-0000-4000-8000-000000000001',
          '023c0711-0000-4000-8000-000000000001','023c0781-0000-4000-8000-000000000001','023c0791-0000-4000-8000-000000000001')) scoped_baseline_fingerprint,
       (select md5(coalesce(string_agg(baseline_version_id::text||':'||candidate_lifecycle_event_id::text,'|' order by baseline_version_id),''))
        from s2t_fhir.baseline_candidate_context where baseline_version_id in (
          '023c0201-0000-4000-8000-000000000001','023c0301-0000-4000-8000-000000000001','023c0401-0000-4000-8000-000000000001',
          '023c0501-0000-4000-8000-000000000001','023c0511-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001',
          '023c0611-0000-4000-8000-000000000001','023c0701-0000-4000-8000-000000000001','023c0781-0000-4000-8000-000000000001')) scoped_candidate_projection_fingerprint,
       (select md5(coalesce(string_agg(baseline_version_id::text||':'||active_lifecycle_event_id::text,'|' order by baseline_version_id),''))
        from s2t_fhir.baseline_activation_context where baseline_version_id in (
          '023c0501-0000-4000-8000-000000000001','023c0601-0000-4000-8000-000000000001')) scoped_active_projection_fingerprint;

-- End of provisioning package. Do not append decommissioning to this file.

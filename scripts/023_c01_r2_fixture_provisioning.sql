-- Migration 023 C01-R2 incremental retained fixture provisioning.
-- Target: S2T-FHIR-DDL-Test. Manual Supabase SQL Editor execution only.
-- Fixture identity: T023-CONC-PACK-20261010-R2-C01
--
-- This package deliberately reuses the existing active C01 worker principals
-- and their existing S2T_BASELINE_UPLOAD authorizations. It creates no principal
-- or authorization history and does not touch T023-CONC-PACK-20261009-R1.
-- Run each marked transaction separately and retain every result grid.

-- ---------------------------------------------------------------------------
-- C01-R2-PRE (READ ONLY) - environment, retained-evidence, and collision guard
-- ---------------------------------------------------------------------------
do $c01_r2_preflight$
declare
  v_count integer;
begin
  if pg_catalog.to_regprocedure(
       's2t_fhir_api.publish_candidate_baseline(uuid,uuid,uuid,uuid,timestamptz,text)'
     ) is null then
    raise exception 'C01-R2 preflight: publish_candidate_baseline is missing'
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from s2t_fhir.principal p
  where (p.principal_id, p.external_subject) in (
    ('023c01a0-0000-4000-8000-000000000001'::uuid,'023c01a1-0000-4000-8000-000000000001'),
    ('023c01b0-0000-4000-8000-000000000001'::uuid,'023c01b1-0000-4000-8000-000000000001')
  )
    and p.external_issuer = 'supabase-auth'
    and p.disabled_at is null;
  if v_count <> 2 then
    raise exception 'C01-R2 preflight: expected both existing active C01 worker principals; found %', v_count
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from s2t_fhir.baseline_action_authorization a
  where a.principal_id in (
    '023c01a0-0000-4000-8000-000000000001',
    '023c01b0-0000-4000-8000-000000000001'
  )
    and a.capability_code = 'S2T_BASELINE_UPLOAD'
    and a.effective_at <= pg_catalog.transaction_timestamp()
    and a.revoked_at is null;
  if v_count <> 2 then
    raise exception 'C01-R2 preflight: expected two existing active upload authorizations; found %', v_count
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from s2t_fhir.baseline_lifecycle_event e
    where e.baseline_lifecycle_event_id = '9cfbebbe-7597-47f8-bef2-4e6b2b2b3cd7'
      and e.baseline_version_id = '023c0101-0000-4000-8000-000000000001'
  )
     or not exists (
       select 1
       from s2t_fhir.baseline_candidate_context c
       where c.baseline_version_id = '023c0101-0000-4000-8000-000000000001'
         and c.candidate_lifecycle_event_id = '9cfbebbe-7597-47f8-bef2-4e6b2b2b3cd7'
     )
     or exists (
       select 1
       from s2t_fhir.baseline_lifecycle_event e
       where e.baseline_version_id = '023c0111-0000-4000-8000-000000000001'
     ) then
    raise exception 'C01-R2 preflight: retained original C01 evidence is not in the documented state'
      using errcode = '55000';
  end if;

  if exists (
    select 1 from s2t_fhir.baseline_series s
    where s.baseline_series_id = '023c0100-2026-4010-8000-000000000002'
       or s.source_system = 'T023-CONC-PACK-20261010-R2-C01'
  ) or exists (
    select 1 from s2t_fhir.baseline_version b
    where b.baseline_version_id in (
      '023c0101-2026-4010-8000-000000000002',
      '023c0111-2026-4010-8000-000000000002'
    )
       or b.baseline_code in (
         'T023-CONC-PACK-20261010-R2-C01-A',
         'T023-CONC-PACK-20261010-R2-C01-B'
       )
  ) or exists (
    select 1 from s2t_fhir.artifact a
    where a.artifact_id in (
      '023c0102-2026-4010-8000-000000000002',
      '023c0112-2026-4010-8000-000000000002'
    )
  ) or exists (
    select 1 from s2t_fhir.baseline_artifact ba
    where ba.baseline_artifact_id in (
      '023c0104-2026-4010-8000-000000000002',
      '023c0114-2026-4010-8000-000000000002'
    )
  ) or exists (
    select 1 from s2t_fhir.import_run i
    where i.import_run_id in (
      '023c0103-2026-4010-8000-000000000002',
      '023c0113-2026-4010-8000-000000000002'
    )
  ) then
    raise exception 'C01-R2 preflight: exact fixture or partial fixture already exists; verify and do not restart'
      using errcode = '55000';
  end if;

  select count(*) into v_count
  from (values
    ('BASELINE_TYPE','HUMAN_WORKING_DRAFT'),
    ('ARTIFACT_KIND','WORKBOOK'),
    ('ARTIFACT_ROLE','AUTHORITATIVE_SOURCE'),
    ('IMPORT_POLICY','CLEAN_IMPORT'),
    ('IMPORT_RUN_STATUS','COMMITTED')
  ) expected(domain_code, value_code)
  cross join lateral (
    select count(*) as match_count
    from s2t_fhir.reference_value v
    join s2t_fhir.reference_domain d using (reference_domain_id)
    where d.domain_code = expected.domain_code
      and v.value_code = expected.value_code
  ) actual
  where actual.match_count <> 1;
  if v_count <> 0 then
    raise exception 'C01-R2 preflight: % required reference values are missing or ambiguous', v_count
      using errcode = '55000';
  end if;
end
$c01_r2_preflight$;

select 'C01-R2-PRE' as checkpoint, 'NEW_FIXTURE' as state,
       'T023-CONC-PACK-20261010-R2-C01' as fixture_id;

-- ---------------------------------------------------------------------------
-- C01-R2-01 - create the lifecycle-empty dedicated series
-- ---------------------------------------------------------------------------
begin;
set local role s2t_fhir_owner;
set constraints all deferred;

insert into s2t_fhir.baseline_series
  (baseline_series_id, source_system, fhir_resource, baseline_type_value_id, description)
select
  '023c0100-2026-4010-8000-000000000002',
  'T023-CONC-PACK-20261010-R2-C01',
  'MedicationRequest',
  v.reference_value_id,
  'T023-CONC-PACK-20261010-R2-C01 dedicated rollback-only concurrency series'
from s2t_fhir.reference_value v
join s2t_fhir.reference_domain d using (reference_domain_id)
where d.domain_code = 'BASELINE_TYPE'
  and v.value_code = 'HUMAN_WORKING_DRAFT';

commit;

select 'C01-R2-01' as checkpoint, 'COMPLETE' as state,
       '023c0100-2026-4010-8000-000000000002'::uuid as baseline_series_id;

-- ---------------------------------------------------------------------------
-- C01-R2-02 - baseline A, authoritative artifact A, committed import A
-- Exactly one import is finalized in this transaction.
-- ---------------------------------------------------------------------------
begin;
set local role s2t_fhir_owner;
set constraints all deferred;

do $c01_r2_a_guard$
begin
  if not exists (
    select 1 from s2t_fhir.baseline_series
    where baseline_series_id = '023c0100-2026-4010-8000-000000000002'
      and source_system = 'T023-CONC-PACK-20261010-R2-C01'
  ) or exists (
    select 1 from s2t_fhir.baseline_version
    where baseline_version_id = '023c0101-2026-4010-8000-000000000002'
  ) or exists (
    select 1 from s2t_fhir.artifact
    where artifact_id = '023c0102-2026-4010-8000-000000000002'
  ) or exists (
    select 1 from s2t_fhir.baseline_artifact
    where baseline_artifact_id = '023c0104-2026-4010-8000-000000000002'
  ) or exists (
    select 1 from s2t_fhir.import_run
    where import_run_id = '023c0103-2026-4010-8000-000000000002'
  ) then
    raise exception 'C01-R2-02: prerequisite missing or checkpoint already/partially present'
      using errcode = '55000';
  end if;
end
$c01_r2_a_guard$;

insert into s2t_fhir.baseline_version
  (baseline_version_id, baseline_series_id, baseline_code, version_label,
   is_gold_standard, import_specification_version, description,
   created_by_principal_id)
values
  ('023c0101-2026-4010-8000-000000000002',
   '023c0100-2026-4010-8000-000000000002',
   'T023-CONC-PACK-20261010-R2-C01-A',
   'T023-CONC-PACK-20261010-R2-C01-A', false,
   'T023-CONC-PACK-20261010-R2-C01-v1',
   'T023-CONC-PACK-20261010-R2-C01 unpublished baseline A',
   '023c01a0-0000-4000-8000-000000000001');

insert into s2t_fhir.artifact
  (artifact_id, artifact_kind_value_id, sha256_digest, byte_size, media_type,
   physical_filename, captured_at, description, created_by_principal_id)
select
  '023c0102-2026-4010-8000-000000000002', v.reference_value_id,
  decode(md5('T023-CONC-PACK-20261010-R2-C01-A-artifact-1') ||
         md5('T023-CONC-PACK-20261010-R2-C01-A-artifact-2'), 'hex'),
  1, 'application/test', 'T023-CONC-PACK-20261010-R2-C01-A.xlsx',
  transaction_timestamp(), 'T023-CONC-PACK-20261010-R2-C01 authoritative artifact A',
  '023c01a0-0000-4000-8000-000000000001'
from s2t_fhir.reference_value v
join s2t_fhir.reference_domain d using (reference_domain_id)
where d.domain_code = 'ARTIFACT_KIND' and v.value_code = 'WORKBOOK';

insert into s2t_fhir.baseline_artifact
  (baseline_artifact_id, baseline_version_id, artifact_id,
   artifact_role_value_id, note, created_by_principal_id)
select
  '023c0104-2026-4010-8000-000000000002',
  '023c0101-2026-4010-8000-000000000002',
  '023c0102-2026-4010-8000-000000000002', v.reference_value_id,
  'T023-CONC-PACK-20261010-R2-C01 authoritative A',
  '023c01a0-0000-4000-8000-000000000001'
from s2t_fhir.reference_value v
join s2t_fhir.reference_domain d using (reference_domain_id)
where d.domain_code = 'ARTIFACT_ROLE' and v.value_code = 'AUTHORITATIVE_SOURCE';

insert into s2t_fhir.import_run
  (import_run_id, baseline_version_id, artifact_id, import_policy_value_id,
   import_specification_version, importer_version, configuration_digest,
   started_at, completed_at, terminal_status_value_id, actor_principal_id)
select
  '023c0103-2026-4010-8000-000000000002',
  '023c0101-2026-4010-8000-000000000002',
  '023c0102-2026-4010-8000-000000000002', policy.reference_value_id,
  'T023-CONC-PACK-20261010-R2-C01-v1',
  'T023-CONC-PACK-20261010-R2-C01-importer',
  decode(md5('T023-CONC-PACK-20261010-R2-C01-A-config-1') ||
         md5('T023-CONC-PACK-20261010-R2-C01-A-config-2'), 'hex'),
  transaction_timestamp() - interval '2 seconds',
  transaction_timestamp() - interval '1 second', status.reference_value_id,
  '023c01a0-0000-4000-8000-000000000001'
from s2t_fhir.reference_value policy
join s2t_fhir.reference_domain pd
  on pd.reference_domain_id = policy.reference_domain_id
cross join s2t_fhir.reference_value status
join s2t_fhir.reference_domain sd
  on sd.reference_domain_id = status.reference_domain_id
where pd.domain_code = 'IMPORT_POLICY' and policy.value_code = 'CLEAN_IMPORT'
  and sd.domain_code = 'IMPORT_RUN_STATUS' and status.value_code = 'COMMITTED';

commit;

select 'C01-R2-02' as checkpoint, 'COMPLETE' as state,
       '023c0101-2026-4010-8000-000000000002'::uuid as baseline_version_id,
       '023c0102-2026-4010-8000-000000000002'::uuid as artifact_id,
       '023c0104-2026-4010-8000-000000000002'::uuid as baseline_artifact_id,
       '023c0103-2026-4010-8000-000000000002'::uuid as import_run_id;

-- ---------------------------------------------------------------------------
-- C01-R2-03 - baseline B, authoritative artifact B, committed import B
-- Exactly one import is finalized in this transaction.
-- ---------------------------------------------------------------------------
begin;
set local role s2t_fhir_owner;
set constraints all deferred;

do $c01_r2_b_guard$
begin
  if not exists (
    select 1
    from s2t_fhir.import_run i
    join s2t_fhir.reference_value status
      on status.reference_value_id = i.terminal_status_value_id
    join s2t_fhir.reference_domain d
      on d.reference_domain_id = status.reference_domain_id
    where i.import_run_id = '023c0103-2026-4010-8000-000000000002'
      and i.baseline_version_id = '023c0101-2026-4010-8000-000000000002'
      and d.domain_code = 'IMPORT_RUN_STATUS'
      and status.value_code = 'COMMITTED'
  ) or exists (
    select 1 from s2t_fhir.baseline_version
    where baseline_version_id = '023c0111-2026-4010-8000-000000000002'
  ) or exists (
    select 1 from s2t_fhir.artifact
    where artifact_id = '023c0112-2026-4010-8000-000000000002'
  ) or exists (
    select 1 from s2t_fhir.baseline_artifact
    where baseline_artifact_id = '023c0114-2026-4010-8000-000000000002'
  ) or exists (
    select 1 from s2t_fhir.import_run
    where import_run_id = '023c0113-2026-4010-8000-000000000002'
  ) then
    raise exception 'C01-R2-03: prerequisite missing or checkpoint already/partially present'
      using errcode = '55000';
  end if;
end
$c01_r2_b_guard$;

insert into s2t_fhir.baseline_version
  (baseline_version_id, baseline_series_id, baseline_code, version_label,
   is_gold_standard, import_specification_version, description,
   created_by_principal_id)
values
  ('023c0111-2026-4010-8000-000000000002',
   '023c0100-2026-4010-8000-000000000002',
   'T023-CONC-PACK-20261010-R2-C01-B',
   'T023-CONC-PACK-20261010-R2-C01-B', false,
   'T023-CONC-PACK-20261010-R2-C01-v1',
   'T023-CONC-PACK-20261010-R2-C01 unpublished baseline B',
   '023c01b0-0000-4000-8000-000000000001');

insert into s2t_fhir.artifact
  (artifact_id, artifact_kind_value_id, sha256_digest, byte_size, media_type,
   physical_filename, captured_at, description, created_by_principal_id)
select
  '023c0112-2026-4010-8000-000000000002', v.reference_value_id,
  decode(md5('T023-CONC-PACK-20261010-R2-C01-B-artifact-1') ||
         md5('T023-CONC-PACK-20261010-R2-C01-B-artifact-2'), 'hex'),
  1, 'application/test', 'T023-CONC-PACK-20261010-R2-C01-B.xlsx',
  transaction_timestamp(), 'T023-CONC-PACK-20261010-R2-C01 authoritative artifact B',
  '023c01b0-0000-4000-8000-000000000001'
from s2t_fhir.reference_value v
join s2t_fhir.reference_domain d using (reference_domain_id)
where d.domain_code = 'ARTIFACT_KIND' and v.value_code = 'WORKBOOK';

insert into s2t_fhir.baseline_artifact
  (baseline_artifact_id, baseline_version_id, artifact_id,
   artifact_role_value_id, note, created_by_principal_id)
select
  '023c0114-2026-4010-8000-000000000002',
  '023c0111-2026-4010-8000-000000000002',
  '023c0112-2026-4010-8000-000000000002', v.reference_value_id,
  'T023-CONC-PACK-20261010-R2-C01 authoritative B',
  '023c01b0-0000-4000-8000-000000000001'
from s2t_fhir.reference_value v
join s2t_fhir.reference_domain d using (reference_domain_id)
where d.domain_code = 'ARTIFACT_ROLE' and v.value_code = 'AUTHORITATIVE_SOURCE';

insert into s2t_fhir.import_run
  (import_run_id, baseline_version_id, artifact_id, import_policy_value_id,
   import_specification_version, importer_version, configuration_digest,
   started_at, completed_at, terminal_status_value_id, actor_principal_id)
select
  '023c0113-2026-4010-8000-000000000002',
  '023c0111-2026-4010-8000-000000000002',
  '023c0112-2026-4010-8000-000000000002', policy.reference_value_id,
  'T023-CONC-PACK-20261010-R2-C01-v1',
  'T023-CONC-PACK-20261010-R2-C01-importer',
  decode(md5('T023-CONC-PACK-20261010-R2-C01-B-config-1') ||
         md5('T023-CONC-PACK-20261010-R2-C01-B-config-2'), 'hex'),
  transaction_timestamp() - interval '2 seconds',
  transaction_timestamp() - interval '1 second', status.reference_value_id,
  '023c01b0-0000-4000-8000-000000000001'
from s2t_fhir.reference_value policy
join s2t_fhir.reference_domain pd
  on pd.reference_domain_id = policy.reference_domain_id
cross join s2t_fhir.reference_value status
join s2t_fhir.reference_domain sd
  on sd.reference_domain_id = status.reference_domain_id
where pd.domain_code = 'IMPORT_POLICY' and policy.value_code = 'CLEAN_IMPORT'
  and sd.domain_code = 'IMPORT_RUN_STATUS' and status.value_code = 'COMMITTED';

commit;

select 'C01-R2-03' as checkpoint, 'COMPLETE' as state,
       '023c0111-2026-4010-8000-000000000002'::uuid as baseline_version_id,
       '023c0112-2026-4010-8000-000000000002'::uuid as artifact_id,
       '023c0114-2026-4010-8000-000000000002'::uuid as baseline_artifact_id,
       '023c0113-2026-4010-8000-000000000002'::uuid as import_run_id;

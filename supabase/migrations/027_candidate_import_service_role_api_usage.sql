-- Migration 027: make the five Migration 026 Candidate-import service helpers
-- callable by service_role without broadening table or browser access.

begin;

set role s2t_fhir_owner;

do $precondition$
declare
  v_signature text;
  v_oid oid;
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role') then
    raise exception '027 precondition: required role service_role is absent'
      using errcode = '55000';
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 's2t_fhir_importer') then
    raise exception '027 precondition: required role s2t_fhir_importer is absent'
      using errcode = '55000';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_namespace n
    join pg_catalog.pg_roles owner on owner.oid = n.nspowner
    where n.nspname = 's2t_fhir_api' and owner.rolname = 's2t_fhir_owner'
  ) then
    raise exception '027 precondition: s2t_fhir_api schema is absent or has unexpected owner'
      using errcode = '55000';
  end if;

  foreach v_signature in array array[
    's2t_fhir_api._service_accept_candidate_import_upload(uuid,bytea,bigint,text,timestamp with time zone,uuid,uuid)',
    's2t_fhir_api._service_begin_candidate_import_validation(uuid,text,text,text,bytea,uuid,timestamp with time zone,uuid,uuid)',
    's2t_fhir_api._service_stage_candidate_import_batch(uuid,uuid,integer,bytea,jsonb,uuid,uuid)',
    's2t_fhir_api._service_complete_candidate_import_validation(uuid,uuid,jsonb,jsonb,jsonb,bytea,uuid,uuid)',
    's2t_fhir_api._service_fail_candidate_import(uuid,uuid,text,uuid,text,uuid,uuid)'
  ] loop
    v_oid := pg_catalog.to_regprocedure(v_signature);
    if v_oid is null then
      raise exception '027 precondition: required service helper % is absent', v_signature
        using errcode = '55000';
    end if;
    if not exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_roles owner on owner.oid = p.proowner
      where p.oid = v_oid
        and owner.rolname = 's2t_fhir_owner'
        and p.prosecdef
        and p.provolatile = 'v'
        and p.prokind = 'f'
        and p.proconfig is not distinct from array['search_path=""']
        and pg_catalog.pg_get_function_result(p.oid) = 'jsonb'
    ) then
      raise exception '027 precondition: service helper metadata drift for %', v_signature
        using errcode = '55000';
    end if;
    if not pg_catalog.has_function_privilege('service_role', v_oid, 'EXECUTE')
       or not pg_catalog.has_function_privilege('s2t_fhir_importer', v_oid, 'EXECUTE')
       or pg_catalog.has_function_privilege('authenticated', v_oid, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', v_oid, 'EXECUTE') then
      raise exception '027 precondition: service helper effective ACL drift for %', v_signature
        using errcode = '55000';
    end if;
    if exists (
      select 1
      from pg_catalog.pg_proc p
      cross join lateral pg_catalog.aclexplode(coalesce(
        p.proacl, pg_catalog.acldefault('f', p.proowner))) acl
      where p.oid = v_oid
        and acl.privilege_type = 'EXECUTE'
        and acl.grantee not in (
          p.proowner,
          (select oid from pg_catalog.pg_roles where rolname = 'service_role'),
          (select oid from pg_catalog.pg_roles where rolname = 's2t_fhir_importer')
        )
    ) then
      raise exception '027 precondition: service helper direct ACL drift for %', v_signature
        using errcode = '55000';
    end if;
  end loop;

  if exists (
    select 1
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 's2t_fhir'
      and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and pg_catalog.has_table_privilege(
        'service_role', c.oid,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
      )
  ) then
    raise exception '027 precondition: service_role has unexpected s2t_fhir table privilege'
      using errcode = '55000';
  end if;
end
$precondition$;

grant usage on schema s2t_fhir_api to service_role;

do $postcondition$
begin
  if not pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'USAGE')
     or pg_catalog.has_schema_privilege('service_role', 's2t_fhir_api', 'CREATE') then
    raise exception '027 postcondition: service_role schema privilege is not USAGE-only'
      using errcode = '55000';
  end if;
  if exists (
    select 1
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 's2t_fhir'
      and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and pg_catalog.has_table_privilege(
        'service_role', c.oid,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
      )
  ) then
    raise exception '027 postcondition: service_role gained an s2t_fhir table privilege'
      using errcode = '55000';
  end if;
end
$postcondition$;

reset role;

commit;

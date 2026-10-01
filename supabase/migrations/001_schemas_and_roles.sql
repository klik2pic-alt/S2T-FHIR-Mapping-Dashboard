-- Requires execution by a Supabase/PostgreSQL administrative role with CREATEROLE.
do $block$
begin
  if not exists (select 1 from pg_roles where rolname = 's2t_fhir_owner') then
    execute 'create role s2t_fhir_owner noinherit nologin nosuperuser nocreatedb nocreaterole noreplication';
  end if;
  if not exists (select 1 from pg_roles where rolname = 's2t_fhir_migrator') then
    execute 'create role s2t_fhir_migrator noinherit nologin nosuperuser nocreatedb nocreaterole noreplication';
  end if;
  if not exists (select 1 from pg_roles where rolname = 's2t_fhir_importer') then
    execute 'create role s2t_fhir_importer noinherit nologin nosuperuser nocreatedb nocreaterole noreplication';
  end if;
  if not exists (select 1 from pg_roles where rolname = 's2t_fhir_api_reader') then
    execute 'create role s2t_fhir_api_reader noinherit nologin nosuperuser nocreatedb nocreaterole noreplication';
  end if;
  if not exists (select 1 from pg_roles where rolname = 's2t_fhir_governance_reader') then
    execute 'create role s2t_fhir_governance_reader noinherit nologin nosuperuser nocreatedb nocreaterole noreplication';
  end if;
end
$block$;

grant s2t_fhir_owner to s2t_fhir_migrator;

do $block$
begin
  if current_user <> 's2t_fhir_owner' then
    execute format('grant s2t_fhir_owner to %I', current_user);
  end if;
end
$block$;

create schema if not exists s2t_fhir authorization s2t_fhir_owner;
create schema if not exists s2t_fhir_api authorization s2t_fhir_owner;

revoke all on schema s2t_fhir from public;
revoke all on schema s2t_fhir_api from public;

-- PostgreSQL 13+ provides this in core; fail early on an unsupported server.
do $block$
begin
  if to_regprocedure('pg_catalog.gen_random_uuid()') is null then
    raise exception 'Required built-in function pg_catalog.gen_random_uuid() is unavailable';
  end if;
end
$block$;

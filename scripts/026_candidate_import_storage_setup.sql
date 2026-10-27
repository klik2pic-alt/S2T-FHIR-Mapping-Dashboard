-- F4C.4 deployment artifact. DO NOT run as part of a database migration.
-- Execute once, separately, only during the approved TEST Storage deployment.
-- The Edge service role is the sole object-management principal; this script
-- intentionally creates no browser storage.objects policy.

begin;

do $storage_bucket$
declare
  v_public boolean;
  v_limit bigint;
  v_mimes text[];
begin
  select public, file_size_limit, allowed_mime_types
    into v_public, v_limit, v_mimes
  from storage.buckets
  where id = 's2t-candidate-imports';

  if found then
    if v_public is distinct from false
       or v_limit is distinct from 10485760
       or v_mimes is distinct from array[
         'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
       ]::text[] then
      raise exception 's2t-candidate-imports exists with conflicting configuration';
    end if;
  else
    insert into storage.buckets (
      id, name, public, file_size_limit, allowed_mime_types
    ) values (
      's2t-candidate-imports',
      's2t-candidate-imports',
      false,
      10485760,
      array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']::text[]
    );
  end if;

  if exists (
    select 1
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid = p.polrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'storage' and c.relname = 'objects'
      and (pg_catalog.pg_get_expr(p.polqual, p.polrelid) ilike '%s2t-candidate-imports%'
        or pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) ilike '%s2t-candidate-imports%')
  ) then
    raise exception 'bucket-specific storage.objects policy already exists; review before deployment';
  end if;
end
$storage_bucket$;

commit;

select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 's2t-candidate-imports';

select p.polname,
       pg_catalog.pg_get_expr(p.polqual, p.polrelid) as using_expression,
       pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) as check_expression
from pg_catalog.pg_policy p
join pg_catalog.pg_class c on c.oid = p.polrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'storage' and c.relname = 'objects'
order by p.polname;

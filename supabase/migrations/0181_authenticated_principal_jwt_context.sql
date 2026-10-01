-- Correct authenticated principal resolution without depending on auth schema ACLs.
-- The auth schema is Supabase-managed. This resolver intentionally reads the same
-- trusted request JWT settings used by the deployed auth.uid() implementation, so
-- s2t_fhir_owner does not require USAGE on schema auth.

set role s2t_fhir_owner;

create or replace function s2t_fhir_api._resolve_authenticated_principal()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  auth_user_id uuid;
  resolved_principal_id uuid;
  match_count integer;
begin
  auth_user_id :=
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (
        nullif(
          current_setting('request.jwt.claims', true),
          ''
        )::jsonb ->> 'sub'
      )
    )::uuid;

  if auth_user_id is null then
    raise exception 'an authenticated Supabase user is required' using errcode = '42501';
  end if;

  select count(*), min(p.principal_id::text)::uuid
    into match_count, resolved_principal_id
  from s2t_fhir.principal p
  where p.external_issuer = 'supabase-auth'
    and p.external_subject = auth_user_id::text
    and p.disabled_at is null;

  if match_count = 0 then
    raise exception 'authenticated user has no active governed principal mapping'
      using errcode = '42501';
  elsif match_count <> 1 then
    raise exception 'authenticated user principal mapping is ambiguous'
      using errcode = '42501';
  end if;

  return resolved_principal_id;
end
$function$;

-- CREATE OR REPLACE preserves the existing owner and execution privileges. Keep
-- the private resolver closed to PUBLIC explicitly, matching migration 018.
revoke all on function s2t_fhir_api._resolve_authenticated_principal() from public;

reset role;

-- Runtime verification (review/run separately; not executed by this migration):
--
-- A. Inspect the corrected definition. Expected: both current_setting calls below
--    are present and there is no auth.uid() reference.
-- select pg_get_functiondef(
--   's2t_fhir_api._resolve_authenticated_principal()'::regprocedure
-- );
--
-- B. With no JWT context, call an authenticated wrapper. Expected SQLSTATE 42501
--    and message "an authenticated Supabase user is required", not an auth schema
--    permission error.
-- select s2t_fhir_api.start_authenticated_mapping_review_session(
--   'No JWT verification',
--   null
-- );
--
-- C. Confirm the auth schema ACL is unchanged. Expected: false (intentional).
-- select has_schema_privilege('s2t_fhir_owner', 'auth', 'USAGE');
--
-- D. If direct claim simulation is supported, run in a transaction and substitute
--    a test Supabase Auth user UUID. Verify the governed principal resolves.
-- begin;
-- select set_config(
--   'request.jwt.claim.sub',
--   '<test-auth-user-uuid>',
--   true
-- );
-- select s2t_fhir_api._resolve_authenticated_principal();
-- rollback;
--
-- E. Test the JSON claims fallback for the same user.
-- begin;
-- select set_config('request.jwt.claim.sub', '', true);
-- select set_config(
--   'request.jwt.claims',
--   '{"sub":"<test-auth-user-uuid>"}',
--   true
-- );
-- select s2t_fhir_api._resolve_authenticated_principal();
-- rollback;
--
-- F. Set either JWT subject form to a valid UUID with no principal mapping.
--    Expected SQLSTATE 42501 and "authenticated user has no active governed
--    principal mapping".
--
-- G. Use a mapped active principal without S2T_REVIEW_WRITE authorization and call
--    start_authenticated_mapping_review_session. Expected authorization failure.
--
-- H. Use a mapped active principal with S2T_REVIEW_WRITE authorization and call
--    start_authenticated_mapping_review_session. Expected success without any
--    principal_id input.
--
-- Also verify a malformed subject fails at the uuid cast rather than being ignored.

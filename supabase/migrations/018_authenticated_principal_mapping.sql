-- Governed Supabase Auth user -> principal mapping and browser-safe review writes.
--
-- Identity is derived exclusively from auth.uid().  Provisioning and review-write
-- authorization remain explicit importer/admin operations; no auth.users trigger is
-- created and browser callers never supply a principal identifier.

set role s2t_fhir_owner;

-- This table is deliberately specific to the single capability introduced here.
-- Keeping capability_code on each grant makes the authorization decision and its
-- audit history self-describing without introducing a general-purpose RBAC model.
create table s2t_fhir.review_actor_authorization (
  review_actor_authorization_id uuid primary key default gen_random_uuid(),
  principal_id uuid not null references s2t_fhir.principal(principal_id),
  capability_code text not null default 'S2T_REVIEW_WRITE',
  effective_at timestamptz not null default transaction_timestamp(),
  revoked_at timestamptz,
  granted_by_principal_id uuid not null references s2t_fhir.principal(principal_id),
  revoked_by_principal_id uuid references s2t_fhir.principal(principal_id),
  created_at timestamptz not null default transaction_timestamp(),
  constraint review_actor_authorization_capability_ck check (
    capability_code = 'S2T_REVIEW_WRITE'
  ),
  constraint review_actor_authorization_revoke_pair_ck check (
    (revoked_at is null) = (revoked_by_principal_id is null)
  ),
  constraint review_actor_authorization_time_ck check (
    revoked_at is null or revoked_at >= effective_at
  ),
  constraint review_actor_authorization_created_ck check (
    created_at >= effective_at
  )
);

-- One current grant per principal.  Revoked grants remain as immutable history and
-- a later, explicit grant can create a new current row.
create unique index review_actor_authorization_active_uq
  on s2t_fhir.review_actor_authorization (principal_id, capability_code)
  where revoked_at is null;

create index review_actor_authorization_lookup_idx
  on s2t_fhir.review_actor_authorization
  (principal_id, capability_code, effective_at, revoked_at);

create function s2t_fhir.protect_review_actor_authorization_update()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if old.revoked_at is not null then
    raise exception 'revoked review authorization is immutable' using errcode = '55000';
  end if;

  if new.review_actor_authorization_id is distinct from old.review_actor_authorization_id
     or new.principal_id is distinct from old.principal_id
     or new.capability_code is distinct from old.capability_code
     or new.effective_at is distinct from old.effective_at
     or new.granted_by_principal_id is distinct from old.granted_by_principal_id
     or new.created_at is distinct from old.created_at then
    raise exception 'immutable review authorization fields cannot be changed'
      using errcode = '55000';
  end if;

  if new.revoked_at is null or new.revoked_by_principal_id is null then
    raise exception 'a review authorization update must revoke the grant once'
      using errcode = '55000';
  end if;

  return new;
end
$function$;

create trigger review_actor_authorization_protect_update_trg
before update on s2t_fhir.review_actor_authorization
for each row execute function s2t_fhir.protect_review_actor_authorization_update();

create trigger review_actor_authorization_reject_delete_trg
before delete on s2t_fhir.review_actor_authorization
for each row execute function s2t_fhir.reject_append_only_change();

-- Resolve exactly one enabled principal from the trusted Supabase Auth subject.
-- The count check is intentional defense in depth even though migration 002 has a
-- unique constraint on (external_issuer, external_subject).
create function s2t_fhir_api._resolve_authenticated_principal()
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
  auth_user_id := auth.uid();
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

create function s2t_fhir_api._require_authenticated_review_principal()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  resolved_principal_id uuid;
  grant_count integer;
begin
  resolved_principal_id := s2t_fhir_api._resolve_authenticated_principal();

  select count(*) into grant_count
  from s2t_fhir.review_actor_authorization a
  where a.principal_id = resolved_principal_id
    and a.capability_code = 'S2T_REVIEW_WRITE'
    and a.effective_at <= transaction_timestamp()
    and a.revoked_at is null;

  if grant_count = 0 then
    raise exception 'authenticated principal is not authorized for S2T review writes'
      using errcode = '42501';
  elsif grant_count <> 1 then
    raise exception 'authenticated principal review authorization is ambiguous'
      using errcode = '42501';
  end if;

  return resolved_principal_id;
end
$function$;

-- Explicit, non-browser provisioning.  The issuer and HUMAN kind are selected
-- server-side.  Existing (including disabled) mappings are never reused/reactivated.
create function s2t_fhir.provision_authenticated_principal(
  p_auth_user_id uuid,
  p_display_name text,
  p_created_by_principal_id uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  human_kind_id uuid;
  kind_count integer;
  new_principal_id uuid;
begin
  perform s2t_fhir_api._assert_review_actor(p_created_by_principal_id);

  if p_auth_user_id is null
     or p_auth_user_id = '00000000-0000-0000-0000-000000000000'::uuid then
    raise exception 'auth user ID must be a nonzero UUID' using errcode = '22023';
  end if;
  if nullif(btrim(p_display_name), '') is null then
    raise exception 'display name must be nonblank' using errcode = '22023';
  end if;
  if exists (
    select 1 from s2t_fhir.principal p
    where p.external_issuer = 'supabase-auth'
      and p.external_subject = p_auth_user_id::text
  ) then
    raise exception 'a governed principal mapping already exists for this auth user'
      using errcode = '23505';
  end if;

  select count(*), min(rv.reference_value_id::text)::uuid
    into kind_count, human_kind_id
  from s2t_fhir.reference_value rv
  join s2t_fhir.reference_domain rd
    on rd.reference_domain_id = rv.reference_domain_id
  where rd.domain_code = 'PRINCIPAL_KIND'
    and rv.value_code = 'HUMAN'
    and rv.effective_at <= transaction_timestamp()
    and (rv.retired_at is null or rv.retired_at > transaction_timestamp());

  if kind_count <> 1 then
    raise exception 'exactly one current HUMAN principal kind is required'
      using errcode = 'P0002';
  end if;

  insert into s2t_fhir.principal
    (principal_kind_value_id, external_issuer, external_subject, display_name)
  values
    (human_kind_id, 'supabase-auth', p_auth_user_id::text, btrim(p_display_name))
  returning principal_id into new_principal_id;

  return new_principal_id;
end
$function$;

create function s2t_fhir.grant_review_write(
  p_principal_id uuid,
  p_granted_by_principal_id uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  new_authorization_id uuid;
begin
  perform s2t_fhir_api._assert_review_actor(p_granted_by_principal_id);

  if not exists (
    select 1 from s2t_fhir.principal p
    where p.principal_id = p_principal_id
      and p.external_issuer = 'supabase-auth'
      and p.disabled_at is null
  ) then
    raise exception 'target must be an active Supabase-authenticated principal'
      using errcode = 'P0002';
  end if;
  if exists (
    select 1 from s2t_fhir.review_actor_authorization a
    where a.principal_id = p_principal_id
      and a.capability_code = 'S2T_REVIEW_WRITE'
      and a.revoked_at is null
  ) then
    raise exception 'principal already has active S2T_REVIEW_WRITE authorization'
      using errcode = '23505';
  end if;

  insert into s2t_fhir.review_actor_authorization
    (principal_id, capability_code, effective_at, granted_by_principal_id)
  values
    (p_principal_id, 'S2T_REVIEW_WRITE', transaction_timestamp(),
     p_granted_by_principal_id)
  returning review_actor_authorization_id into new_authorization_id;

  return new_authorization_id;
end
$function$;

create function s2t_fhir.revoke_review_write(
  p_principal_id uuid,
  p_revoked_by_principal_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
begin
  perform s2t_fhir_api._assert_review_actor(p_revoked_by_principal_id);

  update s2t_fhir.review_actor_authorization a
  set revoked_at = transaction_timestamp(),
      revoked_by_principal_id = p_revoked_by_principal_id
  where a.principal_id = p_principal_id
    and a.capability_code = 'S2T_REVIEW_WRITE'
    and a.revoked_at is null;

  if not found then
    raise exception 'active S2T_REVIEW_WRITE authorization not found'
      using errcode = 'P0002';
  end if;
end
$function$;

-- Shared implementation for both importer and authenticated entry points.
create function s2t_fhir_api._start_mapping_review_session(
  p_session_name text,
  p_actor_principal_id uuid,
  p_notes text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  baseline_id uuid;
  context_count integer;
  new_session_id uuid;
begin
  if nullif(btrim(p_session_name), '') is null then
    raise exception 'session name must be nonblank' using errcode = '22023';
  end if;
  if p_notes is not null and nullif(btrim(p_notes), '') is null then
    raise exception 'session notes must be nonblank when supplied' using errcode = '22023';
  end if;

  select count(*) into context_count
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';
  if context_count <> 1 then
    raise exception 'exactly one active governed CATO MedicationRequest baseline is required'
      using errcode = 'P0002';
  end if;

  select c.baseline_version_id into strict baseline_id
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  insert into s2t_fhir.review_session
    (baseline_version_id, session_name, started_at, created_by_principal_id, notes)
  values
    (baseline_id, btrim(p_session_name), transaction_timestamp(),
     p_actor_principal_id, p_notes)
  returning review_session_id into new_session_id;

  return new_session_id;
end
$function$;

create function s2t_fhir_api._end_mapping_review_session(
  p_session_id uuid,
  p_actor_principal_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  baseline_id uuid;
  context_count integer;
begin
  select count(*) into context_count
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';
  if context_count <> 1 then
    raise exception 'exactly one active governed CATO MedicationRequest baseline is required'
      using errcode = 'P0002';
  end if;

  select c.baseline_version_id into strict baseline_id
  from s2t_fhir_api._active_release_context c
  where c.source_system = 'CATO'
    and c.fhir_resource = 'MedicationRequest';

  update s2t_fhir.review_session rs
  set ended_at = transaction_timestamp(),
      ended_by_principal_id = p_actor_principal_id
  where rs.review_session_id = p_session_id
    and rs.baseline_version_id = baseline_id
    and rs.created_by_principal_id = p_actor_principal_id
    and rs.ended_at is null;

  if not found then
    raise exception 'open review session owned by this actor not found in the active baseline'
      using errcode = 'P0002';
  end if;
end
$function$;

create function s2t_fhir_api._record_mapping_review_core(
  p_node_id text,
  p_review_status text,
  p_actor_principal_id uuid,
  p_session_id uuid default null,
  p_note text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare
  target_baseline_id uuid;
  target_mapping_record_id uuid;
  target_count integer;
  status_id uuid;
  previous_event_id uuid;
begin
  if p_note is not null and nullif(btrim(p_note), '') is null then
    raise exception 'review note must be nonblank when supplied' using errcode = '22023';
  end if;

  select count(*) into target_count
  from s2t_fhir_api._active_release_context ctx
  join s2t_fhir_api._lovable_mapping_node n
    on n.baseline_code = ctx.baseline_code and n.node_id = p_node_id
  join s2t_fhir.logical_mapping_identity lmi
    on lmi.logical_key = n.mapping_key
   and lmi.source_system = ctx.source_system
   and lmi.fhir_resource = ctx.fhir_resource
  join s2t_fhir.mapping_record mr
    on mr.baseline_version_id = ctx.baseline_version_id
   and mr.logical_mapping_identity_id = lmi.logical_mapping_identity_id
  where ctx.source_system = 'CATO'
    and ctx.fhir_resource = 'MedicationRequest';

  if target_count <> 1 then
    raise exception 'node ID does not resolve uniquely in the active accepted governed mapping set'
      using errcode = 'P0002';
  end if;

  select ctx.baseline_version_id, mr.mapping_record_id
    into strict target_baseline_id, target_mapping_record_id
  from s2t_fhir_api._active_release_context ctx
  join s2t_fhir_api._lovable_mapping_node n
    on n.baseline_code = ctx.baseline_code and n.node_id = p_node_id
  join s2t_fhir.logical_mapping_identity lmi
    on lmi.logical_key = n.mapping_key
   and lmi.source_system = ctx.source_system
   and lmi.fhir_resource = ctx.fhir_resource
  join s2t_fhir.mapping_record mr
    on mr.baseline_version_id = ctx.baseline_version_id
   and mr.logical_mapping_identity_id = lmi.logical_mapping_identity_id
  where ctx.source_system = 'CATO'
    and ctx.fhir_resource = 'MedicationRequest';

  perform 1 from s2t_fhir.mapping_record mr
  where mr.mapping_record_id = target_mapping_record_id
  for update;

  if p_session_id is not null and not exists (
    select 1 from s2t_fhir.review_session rs
    where rs.review_session_id = p_session_id
      and rs.baseline_version_id = target_baseline_id
      and rs.created_by_principal_id = p_actor_principal_id
      and rs.ended_at is null
  ) then
    raise exception 'review session is not open, active-baseline, and owned by this actor'
      using errcode = '23514';
  end if;

  select rv.reference_value_id into strict status_id
  from s2t_fhir.reference_value rv
  join s2t_fhir.reference_domain rd
    on rd.reference_domain_id = rv.reference_domain_id
  where rd.domain_code = 'REVIEW_STATUS'
    and rv.value_code = p_review_status
    and rv.effective_at <= transaction_timestamp()
    and (rv.retired_at is null or rv.retired_at > transaction_timestamp());

  select cmr.mapping_review_event_id into previous_event_id
  from s2t_fhir.current_mapping_review cmr
  where cmr.baseline_version_id = target_baseline_id
    and cmr.mapping_record_id = target_mapping_record_id;

  insert into s2t_fhir.mapping_review_event
    (baseline_version_id, mapping_record_id, review_session_id,
     review_status_value_id, occurred_at, actor_principal_id,
     review_note, supersedes_event_id)
  values
    (target_baseline_id, target_mapping_record_id, p_session_id,
     status_id, transaction_timestamp(), p_actor_principal_id,
     p_note, previous_event_id);
end
$function$;

-- Preserve migration 017 importer signatures and authorization while routing to
-- the shared implementations.
create or replace function s2t_fhir_api.start_mapping_review_session(
  p_session_name text,
  p_actor_principal_id uuid,
  p_notes text default null
)
returns uuid language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);
  return s2t_fhir_api._start_mapping_review_session(
    p_session_name, p_actor_principal_id, p_notes
  );
end
$function$;

create or replace function s2t_fhir_api.end_mapping_review_session(
  p_session_id uuid,
  p_actor_principal_id uuid
)
returns void language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);
  perform s2t_fhir_api._end_mapping_review_session(p_session_id, p_actor_principal_id);
end
$function$;

create or replace function s2t_fhir_api._record_mapping_review(
  p_node_id text,
  p_review_status text,
  p_actor_principal_id uuid,
  p_session_id uuid default null,
  p_note text default null
)
returns void language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
begin
  perform s2t_fhir_api._assert_review_actor(p_actor_principal_id);
  perform s2t_fhir_api._record_mapping_review_core(
    p_node_id, p_review_status, p_actor_principal_id, p_session_id, p_note
  );
end
$function$;

-- Browser-safe authenticated entry points.  Their response types expose no UUID
-- except the session handle required to continue/end a session.
create function s2t_fhir_api.start_authenticated_mapping_review_session(
  p_session_name text,
  p_notes text default null
)
returns uuid language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare actor_id uuid;
begin
  actor_id := s2t_fhir_api._require_authenticated_review_principal();
  return s2t_fhir_api._start_mapping_review_session(p_session_name, actor_id, p_notes);
end
$function$;

create function s2t_fhir_api.end_authenticated_mapping_review_session(
  p_session_id uuid
)
returns void language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare actor_id uuid;
begin
  actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._end_mapping_review_session(p_session_id, actor_id);
end
$function$;

create function s2t_fhir_api.mark_authenticated_mapping_reviewed(
  p_node_id text,
  p_session_id uuid default null,
  p_note text default null
)
returns void language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare actor_id uuid;
begin
  actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._record_mapping_review_core(
    p_node_id, 'REVIEWED', actor_id, p_session_id, p_note
  );
end
$function$;

create function s2t_fhir_api.mark_authenticated_mapping_needs_follow_up(
  p_node_id text,
  p_session_id uuid default null,
  p_note text default null
)
returns void language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare actor_id uuid;
begin
  actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._record_mapping_review_core(
    p_node_id, 'NEEDS_FOLLOW_UP', actor_id, p_session_id, p_note
  );
end
$function$;

create function s2t_fhir_api.clear_authenticated_mapping_review(
  p_node_id text,
  p_session_id uuid default null,
  p_note text default null
)
returns void language plpgsql volatile security definer
set search_path = pg_catalog, s2t_fhir_api
as $function$
declare actor_id uuid;
begin
  actor_id := s2t_fhir_api._require_authenticated_review_principal();
  perform s2t_fhir_api._record_mapping_review_core(
    p_node_id, 'NOT_REVIEWED', actor_id, p_session_id, p_note
  );
end
$function$;

-- Private/admin functions are closed by default.
revoke all on function s2t_fhir.protect_review_actor_authorization_update() from public;
revoke all on function s2t_fhir.provision_authenticated_principal(uuid, text, uuid) from public;
revoke all on function s2t_fhir.grant_review_write(uuid, uuid) from public;
revoke all on function s2t_fhir.revoke_review_write(uuid, uuid) from public;
revoke all on function s2t_fhir_api._resolve_authenticated_principal() from public;
revoke all on function s2t_fhir_api._require_authenticated_review_principal() from public;
revoke all on function s2t_fhir_api._start_mapping_review_session(text, uuid, text) from public;
revoke all on function s2t_fhir_api._end_mapping_review_session(uuid, uuid) from public;
revoke all on function s2t_fhir_api._record_mapping_review_core(text, text, uuid, uuid, text) from public;
revoke all on function s2t_fhir_api.start_authenticated_mapping_review_session(text, text) from public;
revoke all on function s2t_fhir_api.end_authenticated_mapping_review_session(uuid) from public;
revoke all on function s2t_fhir_api.mark_authenticated_mapping_reviewed(text, uuid, text) from public;
revoke all on function s2t_fhir_api.mark_authenticated_mapping_needs_follow_up(text, uuid, text) from public;
revoke all on function s2t_fhir_api.clear_authenticated_mapping_review(text, uuid, text) from public;
revoke all on s2t_fhir.review_actor_authorization from public;

-- Explicit governed provisioning/authorization remains importer-only.
grant execute on function s2t_fhir.provision_authenticated_principal(uuid, text, uuid)
  to s2t_fhir_importer;
grant execute on function s2t_fhir.grant_review_write(uuid, uuid)
  to s2t_fhir_importer;
grant execute on function s2t_fhir.revoke_review_write(uuid, uuid)
  to s2t_fhir_importer;

do $block$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function s2t_fhir_api.start_authenticated_mapping_review_session(text, text) to authenticated';
    execute 'grant execute on function s2t_fhir_api.end_authenticated_mapping_review_session(uuid) to authenticated';
    execute 'grant execute on function s2t_fhir_api.mark_authenticated_mapping_reviewed(text, uuid, text) to authenticated';
    execute 'grant execute on function s2t_fhir_api.mark_authenticated_mapping_needs_follow_up(text, uuid, text) to authenticated';
    execute 'grant execute on function s2t_fhir_api.clear_authenticated_mapping_review(text, uuid, text) to authenticated';
    execute 'revoke all on s2t_fhir.review_actor_authorization from authenticated';
    execute 'revoke all on function s2t_fhir.provision_authenticated_principal(uuid, text, uuid) from authenticated';
    execute 'revoke all on function s2t_fhir.grant_review_write(uuid, uuid) from authenticated';
    execute 'revoke all on function s2t_fhir.revoke_review_write(uuid, uuid) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on s2t_fhir.review_actor_authorization from anon';
    execute 'revoke all on function s2t_fhir_api.start_authenticated_mapping_review_session(text, text) from anon';
    execute 'revoke all on function s2t_fhir_api.end_authenticated_mapping_review_session(uuid) from anon';
    execute 'revoke all on function s2t_fhir_api.mark_authenticated_mapping_reviewed(text, uuid, text) from anon';
    execute 'revoke all on function s2t_fhir_api.mark_authenticated_mapping_needs_follow_up(text, uuid, text) from anon';
    execute 'revoke all on function s2t_fhir_api.clear_authenticated_mapping_review(text, uuid, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke all on s2t_fhir.review_actor_authorization from service_role';
    execute 'revoke all on function s2t_fhir_api.start_authenticated_mapping_review_session(text, text) from service_role';
    execute 'revoke all on function s2t_fhir_api.end_authenticated_mapping_review_session(uuid) from service_role';
    execute 'revoke all on function s2t_fhir_api.mark_authenticated_mapping_reviewed(text, uuid, text) from service_role';
    execute 'revoke all on function s2t_fhir_api.mark_authenticated_mapping_needs_follow_up(text, uuid, text) from service_role';
    execute 'revoke all on function s2t_fhir_api.clear_authenticated_mapping_review(text, uuid, text) from service_role';
    execute 'revoke all on function s2t_fhir.provision_authenticated_principal(uuid, text, uuid) from service_role';
    execute 'revoke all on function s2t_fhir.grant_review_write(uuid, uuid) from service_role';
    execute 'revoke all on function s2t_fhir.revoke_review_write(uuid, uuid) from service_role';
  end if;
end
$block$;

reset role;

-- Runtime verification plan (review/run separately; not executed by this migration):
--
-- Setup is an explicit importer/admin act:
--   select s2t_fhir.provision_authenticated_principal(
--     :auth_user_id, 'Reviewer name', :importer_principal_id);
--   select s2t_fhir.grant_review_write(:reviewer_principal_id, :importer_principal_id);
--
-- A. With no authenticated JWT context, every authenticated wrapper fails 42501.
-- B. A real auth user with no supabase-auth principal mapping fails 42501.
-- C. A mapped principal without an active S2T_REVIEW_WRITE grant fails 42501.
-- D. A mapped + authorized principal can start a session; retain :session_id.
-- E. mark_authenticated_mapping_reviewed(:node_id, :session_id, null) succeeds
--    without accepting any principal parameter.
-- F. Inspect the private event as an admin: actor_principal_id equals the principal
--    resolved from ('supabase-auth', auth.uid()::text).
-- G. mark_authenticated_mapping_needs_follow_up succeeds and records that status.
-- H. clear_authenticated_mapping_review appends NOT_REVIEWED and supersedes the
--    current event; it does not update/delete history.
-- I. End the session, then verify a supplied ended :session_id is rejected (23514).
-- J. A second authorized principal cannot end or use another principal's session.
-- K. Set principal.disabled_at as an admin and verify all wrappers fail 42501.
-- L. Revoke with revoke_review_write and verify the next write fails immediately.
-- M. A nonexistent node ID fails P0002.
-- N. A quarantined source row/node fails P0002 through the existing governed resolver.
-- O/P/Q/R. Use has_function_privilege for anon/authenticated/service_role/public:
--    authenticated=true only for the five authenticated wrappers; all others=false.
-- S. Use has_table_privilege to verify anon/authenticated/service_role have no
--    INSERT/UPDATE/DELETE on principal, review_actor_authorization, review_session,
--    or mapping_review_event.
-- T. As s2t_fhir_importer, repeat migration 017's importer RPC tests unchanged.
-- U. Re-run active_mapping_review_status and
--    get_active_medication_request_cato_review_progress(); results remain compatible.
-- V. Inspect authenticated RPC signatures/results: no principal_id or mapping_record_id
--    is accepted/returned.  start returns only the opaque session UUID needed by UI.
--
-- Supabase Auth simulation note:
-- auth.uid() is the authoritative interface.  This repository does not define its
-- implementation, so do not assume direct SQL claim injection works in the deployed
-- Supabase version.  First verify in a transaction that:
--   select set_config('request.jwt.claim.sub', :auth_user_id::text, true);
--   select auth.uid();
-- returns :auth_user_id.  If it does not, validate A-L through an authenticated
-- Supabase API request carrying a real user JWT.  Do not replace auth.uid() with a
-- caller-supplied claim or function argument.

-- =====================================================================
-- 021_governance_phase1_COMBINED_TEST_DRY_RUN_REV7_T20_T21_FIX.sql
-- TEST ONLY — S2T-FHIR-DDL-Test
--
-- Candidate unchanged from Revision 7.
-- Test-only fixes:
--   T20/T21 use POSIX [[:space:]] regex classes for pg_get_functiondef()
--   assertions, avoiding backslash-escape ambiguity.
--
-- Candidate source SHA256:
-- 0905B43EA8206937A9EC64AD0155FB2E1DEBDE599F6114A5C92320DE0B42E140
-- Fixed test source SHA256:
-- DD406E0FD20E0BD395340BFC6197D04DD376D82320A6BEDF02983BEDA83AD7AC
--
-- Verified TEST UIDs are populated. One outer transaction only.
-- Expected final result: AGGREGATE = ALL PASS.
-- =====================================================================

begin;

-- =====================================================================
-- PART A — Governance Revision 7 candidate (UNCHANGED)
-- =====================================================================
-- =====================================================================
-- 016_governance_phase1_DRAFT.sql — REVISION 7
-- STATUS: DRAFT FOR PRODUCT-OWNER REVIEW — DO NOT EXECUTE.
-- Target: external governed database (S2T-FHIR-DDL-Test), NOT Lovable Cloud.
-- Stored outside supabase/migrations/ so no tooling can apply it.
--
-- Gate-2 dependencies are resolved and verified:
--   DEP-AUTH  = s2t_fhir_api._require_authenticated_review_principal()
--   DEP-MAPID = s2t_fhir_api.governed_mapping_identity (migration 020, verified in TEST)
-- Revision 7 keeps the reviewed Governance contract unchanged and fixes the runtime
-- read-path privilege boundary: authenticated clients execute only guarded read wrappers
-- in s2t_fhir_api; no direct EXECUTE is granted on private s2t_governance helpers.
--
-- Invariants:
--   * Profile/resource agnostic. No resource-specific branches anywhere in Governance.
--   * Governance never writes mapping, Baseline, or review objects.
--   * No active Review Session required.
--   * Reads and writes require a signed-in principal with active S2T_REVIEW_WRITE,
--     resolved ONLY through the existing governed resolver.
--   * Append-only events / links / audit. recorded_at = server time, immutable.
--   * recording_seq is an immutable server-side causal tie-breaker for equal effective_at.
--   * effective_at may be backdated: opened_at <= effective_at <= now(). No monotonic rule.
--   * Every event INSERT is serialized per question and replay-validated in the same
--     statement; an invalid history aborts the INSERT (§5).
--   * Response != Decision. Decisions are never retracted, only superseded.
--   * Carry-forward to a new Baseline: deferred, never automatic.
--   * "Recorded later" DB fact = recorded_at > effective_at (UI decides presentation).
--   * Requires READ COMMITTED isolation for writers (PostgREST default).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Preflight — fail closed on dependency/schema contract drift.
-- Runs as the migration runner before role reduction so a new Governance
-- schema can be bootstrapped without granting database-wide CREATE to
-- s2t_fhir_owner.
-- ---------------------------------------------------------------------
do $$
declare
  v_api_owner text;
  v_gov_owner text;
  v_auth_owner text;
  v_auth_returns text;
  v_auth_prosecdef boolean;
  v_auth_volatility "char";
  v_auth_config text;
  v_map_owner text;
  r record;
  v_actual_type text;
begin
  if to_regprocedure('s2t_fhir_api._require_authenticated_review_principal()') is null then
    raise exception 'DEP-AUTH missing: s2t_fhir_api._require_authenticated_review_principal()';
  end if;
  if to_regclass('s2t_fhir_api.governed_mapping_identity') is null then
    raise exception 'DEP-MAPID missing: s2t_fhir_api.governed_mapping_identity';
  end if;

  select pg_get_userbyid(n.nspowner) into v_api_owner
  from pg_namespace n where n.nspname = 's2t_fhir_api';
  if v_api_owner is distinct from 's2t_fhir_owner' then
    raise exception 'unexpected owner for s2t_fhir_api schema: %', v_api_owner
      using errcode = '42501';
  end if;

  select pg_get_userbyid(n.nspowner) into v_gov_owner
  from pg_namespace n where n.nspname = 's2t_governance';
  if v_gov_owner is not null and v_gov_owner <> 's2t_fhir_owner' then
    raise exception 'unexpected owner for pre-existing s2t_governance schema: %', v_gov_owner
      using errcode = '42501';
  end if;

  select pg_get_userbyid(p.proowner),
         format_type(p.prorettype, null),
         p.prosecdef,
         p.provolatile,
         coalesce(array_to_string(p.proconfig, ','), '')
    into v_auth_owner, v_auth_returns, v_auth_prosecdef, v_auth_volatility, v_auth_config
  from pg_proc p
  where p.oid = 's2t_fhir_api._require_authenticated_review_principal()'::regprocedure;

  if v_auth_owner <> 's2t_fhir_owner'
     or v_auth_returns <> 'uuid'
     or not v_auth_prosecdef
     or v_auth_volatility <> 's'
     or v_auth_config not like '%search_path=pg_catalog, s2t_fhir_api%' then
    raise exception
      'DEP-AUTH contract drift: owner=%, returns=%, security_definer=%, volatility=%, config=%',
      v_auth_owner, v_auth_returns, v_auth_prosecdef, v_auth_volatility, v_auth_config;
  end if;

  select pg_get_userbyid(c.relowner) into v_map_owner
  from pg_class c
  where c.oid = 's2t_fhir_api.governed_mapping_identity'::regclass;
  if v_map_owner <> 's2t_fhir_owner' then
    raise exception 'unexpected owner for governed_mapping_identity: %', v_map_owner
      using errcode = '42501';
  end if;

  for r in
    select * from (values
      ('resource_config_id','text'),
      ('baseline_code','text'),
      ('node_id','text'),
      ('mapping_kind','text'),
      ('element_path','text[]'),
      ('is_active_baseline','boolean'),
      ('fhir_resource_type','text'),
      ('version_label','text'),
      ('target_element','text'),
      ('profile_label','text'),
      ('decision_status','text'),
      ('source_sheet','text'),
      ('source_row','integer'),
      ('source_cell_range','text'),
      ('artifact_sha256','text')
    ) as x(column_name, expected_type)
  loop
    select format_type(a.atttypid, a.atttypmod)
      into v_actual_type
    from pg_attribute a
    where a.attrelid = 's2t_fhir_api.governed_mapping_identity'::regclass
      and a.attname = r.column_name
      and a.attnum > 0
      and not a.attisdropped;

    if v_actual_type is distinct from r.expected_type then
      raise exception 'DEP-MAPID contract drift for %: expected %, found %',
        r.column_name, r.expected_type, coalesce(v_actual_type,'<missing>');
    end if;
  end loop;
end $$;

-- Bootstrap the private Governance schema as the migration runner.
-- s2t_fhir_owner intentionally does NOT require CREATE on database postgres.
create schema if not exists s2t_governance authorization s2t_fhir_owner;

-- Fail closed even after CREATE IF NOT EXISTS: the schema must be owner-controlled.
do $$
declare v_owner text;
begin
  select pg_get_userbyid(n.nspowner) into v_owner
  from pg_namespace n
  where n.nspname = 's2t_governance';

  if v_owner is distinct from 's2t_fhir_owner' then
    raise exception 'unexpected owner for s2t_governance schema after bootstrap: %', v_owner
      using errcode = '42501';
  end if;
end $$;

-- Reduce privileges for all subsequent Governance object creation.
set local role s2t_fhir_owner;

revoke all on schema s2t_governance from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 1. DEP-AUTH — reviewer authorization (single verified path, reused)
-- ---------------------------------------------------------------------
-- Verified in governed TEST:
--   s2t_fhir_api._require_authenticated_review_principal() returns uuid,
--   is SECURITY DEFINER, owned by s2t_fhir_owner, and requires exactly one active
--   S2T_REVIEW_WRITE authorization for the JWT principal. Authorization failures use 42501.
-- Governance delegates to that existing review-layer function; no auth logic is duplicated.
create or replace function s2t_governance._current_reviewer_principal()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_governance
as $$
begin
  return s2t_fhir_api._require_authenticated_review_principal();
end $$;

-- Non-raising variant for read views: true only for an authorized reviewer.
create or replace function s2t_governance._is_reviewer()
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_governance
as $$
begin
  perform s2t_governance._current_reviewer_principal();
  return true;
exception when others then
  return false;
end $$;

-- ---------------------------------------------------------------------
-- 2. DEP-MAPID — generic governed mapping-identity contract
-- ---------------------------------------------------------------------
-- Resolved by migration 020 and verified in S2T-FHIR-DDL-Test.
-- s2t_fhir_api.governed_mapping_identity is mapping-layer owned, generic across resources,
-- and keyed by (resource_config_id, baseline_code, node_id).
-- New Governance links are permitted only when is_active_baseline = true.
-- element_path is root-first for ELEMENT_MAPPING, single-item for STATUS_MAPPING_RULE,
-- and NULL for GOVERNANCE_GUIDANCE. Governance preserves that NULL exactly in its snapshot.
-- Governance uses one lookup against this contract; no per-resource branches.
create or replace function s2t_governance._resolve_mapping_identity(
  p_resource_config_id text, p_baseline_code text, p_node_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_governance, s2t_fhir_api
as $$
declare v jsonb;
begin
  select to_jsonb(m) into strict v
  from s2t_fhir_api.governed_mapping_identity m
  where m.resource_config_id = p_resource_config_id
    and m.baseline_code      = p_baseline_code
    and m.node_id            = p_node_id
    and m.is_active_baseline = true;

  if v->>'mapping_kind' = 'GOVERNANCE_GUIDANCE' then
    if jsonb_typeof(v->'element_path') <> 'null' then
      raise exception 'invalid mapping identity: GOVERNANCE_GUIDANCE element_path must be NULL'
        using errcode = '23514';
    end if;
  elsif jsonb_typeof(v->'element_path') <> 'array' then
    raise exception 'invalid mapping identity: non-guidance element_path must be an array'
      using errcode = '23514';
  end if;

  return v;
exception
  when no_data_found then
    raise exception 'invalid link: active mapping node not found for resource/baseline'
      using errcode = '23503';
  when too_many_rows then
    raise exception 'invalid link: mapping identity is not unique for resource/baseline/node'
      using errcode = '21000';
end $$;

-- ---------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------
create sequence s2t_governance.gov_number_seq start 1 increment 1 no cycle;

create table s2t_governance.governance_party (
  party_id              uuid primary key default gen_random_uuid(),
  party_code            text not null unique check (party_code ~ '^[A-Z][A-Z0-9_]{1,39}$'),
  party_kind            text not null check (party_kind in (
                          'MAPPING_TEAM','CLINICAL','PHARMACY','TERMINOLOGY',
                          'STANDARDS_BODY','REGULATOR','VENDOR','OTHER')),
  category              text not null check (category in ('INTERNAL','EXTERNAL')),
  label_he              text not null check (length(btrim(label_he)) between 1 and 120),
  label_en              text not null check (length(btrim(label_en)) between 1 and 120),
  is_active             boolean not null default true,
  created_by_principal  uuid,
  created_at            timestamptz not null default now()
);

create table s2t_governance.governance_party_audit (
  audit_id              bigint generated always as identity primary key,
  party_id              uuid not null references s2t_governance.governance_party(party_id),
  action                text not null check (action in ('CREATED','DEACTIVATED','REACTIVATED')),
  recorded_by_principal uuid,
  recorded_at           timestamptz not null default now(),
  snapshot              jsonb not null
);

create table s2t_governance.governance_question (
  question_id           uuid primary key default gen_random_uuid(),
  gov_number            integer not null unique default nextval('s2t_governance.gov_number_seq'),
  title                 text not null check (length(btrim(title)) between 3 and 300),
  question_text         text not null check (length(btrim(question_text)) between 3 and 10000),
  opened_at             timestamptz not null,
  recorded_at           timestamptz not null default now(),
  opened_by_principal   uuid not null,
  constraint opened_not_future check (opened_at <= recorded_at)
);

create table s2t_governance.governance_mapping_link (
  link_id                  uuid primary key default gen_random_uuid(),
  question_id              uuid not null references s2t_governance.governance_question(question_id),
  resource_config_id       text not null,
  baseline_code            text not null,
  node_id                  text not null,
  mapping_kind             text not null check (mapping_kind in (
                            'ELEMENT_MAPPING','STATUS_MAPPING_RULE','GOVERNANCE_GUIDANCE')),
  fhir_resource_type       text not null,
  version_label            text,
  target_element           text not null,
  element_path             text[],
  profile_label            text,
  decision_status_at_link  text,
  source_sheet             text,
  source_row               integer,
  source_cell_range        text,
  artifact_sha256          text,
  linked_by_principal      uuid not null,
  recorded_at              timestamptz not null default now()
);
create unique index governance_link_unique_node
  on s2t_governance.governance_mapping_link (question_id, resource_config_id, baseline_code, node_id);

create table s2t_governance.governance_event (
  event_id                      uuid primary key default gen_random_uuid(),
  recording_seq                 bigint generated always as identity unique,
  question_id                   uuid not null references s2t_governance.governance_question(question_id),
  event_type                    text not null check (event_type in (
                                  'QUESTION_CREATED','MAPPING_LINKED','MAPPING_UNLINKED','NOTE_ADDED',
                                  'REQUEST_SENT','RESPONSE_RECEIVED','HOLD_STARTED','HOLD_ENDED',
                                  'DECISION_RECORDED','REOPENED','CLOSED','EVENT_RETRACTED')),
  effective_at                  timestamptz not null,
  recorded_at                   timestamptz not null default now(),
  recorded_by_principal         uuid not null,
  party_id                      uuid references s2t_governance.governance_party(party_id),
  party_code                    text,
  party_label_he                text,
  party_label_en                text,
  party_category                text,
  party_kind                    text,
  response_kind                 text check (response_kind in ('INTERIM','FINAL')),
  related_request_event_id      uuid references s2t_governance.governance_event(event_id),
  reason                        text check (reason is null or length(btrim(reason)) between 1 and 2000),
  note                          text check (note is null or length(btrim(note)) between 1 and 10000),
  decision_text                 text check (decision_text is null or length(btrim(decision_text)) between 3 and 10000),
  mapping_impact                text check (mapping_impact in ('NO_CHANGE','MAPPING_CHANGE_REQUIRED','DOCUMENTATION_ONLY')),
  supersedes_decision_event_id  uuid references s2t_governance.governance_event(event_id),
  link_id                       uuid references s2t_governance.governance_mapping_link(link_id),
  retracts_event_id             uuid references s2t_governance.governance_event(event_id),

  constraint ev_party_shape check (
    event_type not in ('REQUEST_SENT','RESPONSE_RECEIVED') or (party_id is not null and party_code is not null)),
  constraint ev_response_shape check (
    (event_type = 'RESPONSE_RECEIVED') = (response_kind is not null and related_request_event_id is not null)),
  constraint ev_decision_shape check (
    (event_type = 'DECISION_RECORDED') = (decision_text is not null and mapping_impact is not null)),
  constraint ev_supersede_only_decision check (supersedes_decision_event_id is null or event_type = 'DECISION_RECORDED'),
  constraint ev_reason_required check (
    event_type not in ('HOLD_STARTED','REOPENED','EVENT_RETRACTED','MAPPING_UNLINKED') or reason is not null),
  constraint ev_note_required check (event_type <> 'NOTE_ADDED' or note is not null),
  constraint ev_retract_shape check ((event_type = 'EVENT_RETRACTED') = (retracts_event_id is not null)),
  constraint ev_link_shape check ((event_type in ('MAPPING_LINKED','MAPPING_UNLINKED')) = (link_id is not null))
);
create index on s2t_governance.governance_event (question_id, effective_at, recording_seq);
create unique index governance_event_one_created on s2t_governance.governance_event (question_id) where event_type = 'QUESTION_CREATED';
create unique index governance_event_retract_once on s2t_governance.governance_event (retracts_event_id) where retracts_event_id is not null;
create unique index governance_event_supersede_once on s2t_governance.governance_event (supersedes_decision_event_id) where supersedes_decision_event_id is not null;
create unique index governance_event_link_once on s2t_governance.governance_event (link_id) where event_type = 'MAPPING_LINKED';

-- ---------------------------------------------------------------------
-- 4. Append-only protection
-- ---------------------------------------------------------------------
create or replace function s2t_governance._deny_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'append-only: % on %.% is not allowed', tg_op, tg_table_schema, tg_table_name
    using errcode = '42501';
end $$;

do $$
declare t text;
begin
  foreach t in array array['governance_event','governance_mapping_link','governance_question','governance_party_audit'] loop
    execute format('create trigger no_update_delete before update or delete on s2t_governance.%I
                    for each row execute function s2t_governance._deny_mutation()', t);
    execute format('create trigger no_truncate before truncate on s2t_governance.%I
                    for each statement execute function s2t_governance._deny_mutation()', t);
  end loop;
end $$;

create or replace function s2t_governance._party_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'append-only: parties are deactivated, never deleted' using errcode = '42501';
  end if;
  if (new.party_id, new.party_code, new.party_kind, new.category, new.label_he, new.label_en,
      new.created_by_principal, new.created_at)
     is distinct from
     (old.party_id, old.party_code, old.party_kind, old.category, old.label_he, old.label_en,
      old.created_by_principal, old.created_at) then
    raise exception 'append-only: only is_active may change on a party' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger party_guard before update or delete on s2t_governance.governance_party
  for each row execute function s2t_governance._party_guard();
create trigger no_truncate before truncate on s2t_governance.governance_party
  for each statement execute function s2t_governance._deny_mutation();

create or replace function s2t_governance._stamp_recorded_at()
returns trigger language plpgsql as $$
begin new.recorded_at := now(); return new; end $$;
create trigger stamp before insert on s2t_governance.governance_question
  for each row execute function s2t_governance._stamp_recorded_at();
create trigger stamp before insert on s2t_governance.governance_mapping_link
  for each row execute function s2t_governance._stamp_recorded_at();

-- ---------------------------------------------------------------------
-- 5. Central event enforcement
-- recording_seq is assigned by PostgreSQL on INSERT and is immutable because governance_event
-- is append-only. Replay is ordered by (effective_at, recording_seq): business-effective time
-- first, server recording order as the deterministic causal tie-breaker for equal timestamps.
-- ---------------------------------------------------------------------
create or replace function s2t_governance._lock_question(p_question_id uuid)
returns void language sql volatile as $$
  select pg_advisory_xact_lock(hashtextextended('s2t_governance:' || p_question_id::text, 0));
$$;

create or replace function s2t_governance._event_validate()
returns trigger
language plpgsql
set search_path = pg_catalog, s2t_governance
as $$
declare
  v_opened timestamptz;
  v_req governance_event;
  v_tgt governance_event;
begin
  perform _lock_question(new.question_id);
  new.recorded_at := now();

  if new.event_type = 'EVENT_RETRACTED' then
    new.effective_at := now();
  end if;

  select opened_at into v_opened from governance_question where question_id = new.question_id;
  if new.effective_at > now() then
    raise exception 'invalid effective_at: in the future' using errcode = '22007';
  end if;
  if new.effective_at < v_opened then
    raise exception 'invalid effective_at: before question opened_at' using errcode = '22007';
  end if;

  if new.event_type = 'RESPONSE_RECEIVED' then
    select * into v_req from governance_event where event_id = new.related_request_event_id;
    if v_req.event_id is null or v_req.event_type <> 'REQUEST_SENT' or v_req.question_id <> new.question_id then
      raise exception 'invalid response: related request must be a REQUEST_SENT on the same question' using errcode = '23514';
    end if;
    if exists (
      select 1 from governance_event r
      where r.retracts_event_id = v_req.event_id
    ) then
      raise exception 'invalid response: related request is retracted' using errcode = '23514';
    end if;
    if new.effective_at < v_req.effective_at then
      raise exception 'invalid response: effective_at before its request' using errcode = '22007';
    end if;
    if new.party_id is distinct from v_req.party_id then
      raise exception 'invalid response: party must match the request party' using errcode = '23514';
    end if;
    if exists (
      select 1
      from governance_event f
      where f.related_request_event_id = new.related_request_event_id
        and f.response_kind = 'FINAL'
        and f.event_type = 'RESPONSE_RECEIVED'
        and not exists (
          select 1 from governance_event rr where rr.retracts_event_id = f.event_id
        )
    ) then
      raise exception 'invalid response: request already has a live FINAL response' using errcode = '23514';
    end if;
  end if;

  if new.event_type in ('MAPPING_LINKED','MAPPING_UNLINKED') then
    if not exists (select 1 from governance_mapping_link l where l.link_id = new.link_id and l.question_id = new.question_id) then
      raise exception 'invalid link event: link not on this question' using errcode = '23503';
    end if;
  end if;

  if new.event_type = 'MAPPING_UNLINKED' and exists (
       select 1 from governance_event u where u.link_id = new.link_id and u.event_type = 'MAPPING_UNLINKED'
         and not exists (select 1 from governance_event r where r.retracts_event_id = u.event_id)) then
    raise exception 'invalid unlink: link already unlinked' using errcode = '23514';
  end if;

  if new.event_type = 'EVENT_RETRACTED' then
    select * into v_tgt from governance_event where event_id = new.retracts_event_id;
    if v_tgt.event_id is null or v_tgt.question_id <> new.question_id then
      raise exception 'invalid retraction: target event not on this question' using errcode = '23514';
    end if;
    if v_tgt.event_type in ('QUESTION_CREATED','DECISION_RECORDED','EVENT_RETRACTED') then
      raise exception 'invalid retraction: % events cannot be retracted', v_tgt.event_type using errcode = '42501';
    end if;
  end if;

  return new;
end $$;
create trigger event_validate before insert on s2t_governance.governance_event
  for each row execute function s2t_governance._event_validate();

create or replace function s2t_governance._replay_state(p_question_id uuid, p_raise boolean default false)
returns table (
  derived_status            text,
  is_on_hold                boolean,
  current_decision_id       uuid,
  reconsidered_decision_id  uuid,
  open_request_count        integer
)
language plpgsql
stable
set search_path = pg_catalog, s2t_governance
as $$
declare
  e record;
  v_hold boolean := false;
  v_closed boolean := false;
  v_cur uuid;
  v_recon uuid;
  v_err text;
  v_requests jsonb := '{}'::jsonb; -- request event id -> OPEN|FINAL
  v_links jsonb := '{}'::jsonb;    -- link id -> ACTIVE|INACTIVE
  v_open_requests integer := 0;
begin
  for e in
    select ev.* from governance_event ev
    where ev.question_id = p_question_id
      and ev.event_type <> 'EVENT_RETRACTED'
      and not exists (select 1 from governance_event r where r.retracts_event_id = ev.event_id)
    order by ev.effective_at, ev.recording_seq
  loop
    v_err := null;

    case e.event_type
      when 'QUESTION_CREATED' then
        null;

      when 'REQUEST_SENT' then
        if v_closed then
          v_err := 'question is CLOSED';
        else
          v_requests := v_requests || jsonb_build_object(e.event_id::text, 'OPEN');
        end if;

      when 'RESPONSE_RECEIVED' then
        if v_closed then
          v_err := 'question is CLOSED';
        elsif not (v_requests ? e.related_request_event_id::text) then
          v_err := 'response requires a live earlier request';
        elsif v_requests->>e.related_request_event_id::text <> 'OPEN' then
          v_err := 'response cannot follow a FINAL response';
        elsif e.response_kind = 'FINAL' then
          v_requests := jsonb_set(v_requests, array[e.related_request_event_id::text], '"FINAL"'::jsonb);
        end if;

      when 'HOLD_STARTED' then
        if v_hold then v_err := 'hold already active';
        elsif v_closed or v_cur is not null then v_err := 'cannot hold a DECIDED/CLOSED question';
        else v_hold := true; end if;

      when 'HOLD_ENDED' then
        if not v_hold then v_err := 'no active hold'; else v_hold := false; end if;

      when 'DECISION_RECORDED' then
        if v_hold then v_err := 'cannot record a decision while ON_HOLD';
        elsif v_closed then v_err := 'question is CLOSED; reopen first';
        elsif e.supersedes_decision_event_id is distinct from coalesce(v_cur, v_recon) then
          v_err := 'decision must supersede the current/reconsidered decision';
        else
          v_cur := e.event_id;
          v_recon := null;
        end if;

      when 'REOPENED' then
        if v_cur is null then v_err := 'reopen allowed only from DECIDED/CLOSED';
        else
          v_recon := v_cur;
          v_cur := null;
          v_closed := false;
        end if;

      when 'CLOSED' then
        select count(*)::int into v_open_requests
        from jsonb_each_text(v_requests) x
        where x.value = 'OPEN';

        if v_closed then v_err := 'already CLOSED';
        elsif v_cur is null then v_err := 'CLOSED requires a current decision';
        elsif v_open_requests > 0 then v_err := 'CLOSED requires all requests to have FINAL responses';
        else v_closed := true; end if;

      when 'MAPPING_LINKED' then
        if v_closed then
          v_err := 'question is CLOSED';
        elsif v_links ? e.link_id::text then
          v_err := 'mapping link already has a live link event';
        else
          v_links := v_links || jsonb_build_object(e.link_id::text, 'ACTIVE');
        end if;

      when 'MAPPING_UNLINKED' then
        if v_closed then
          v_err := 'question is CLOSED';
        elsif not (v_links ? e.link_id::text) then
          v_err := 'mapping unlink requires a live link event';
        elsif v_links->>e.link_id::text <> 'ACTIVE' then
          v_err := 'mapping link already inactive';
        else
          v_links := jsonb_set(v_links, array[e.link_id::text], '"INACTIVE"'::jsonb);
        end if;

      when 'NOTE_ADDED' then
        null; -- audit notes remain allowed after CLOSED.

      else
        null;
    end case;

    if v_err is not null and p_raise then
      raise exception 'invalid governance transition at % (%): %', e.effective_at, e.event_type, v_err
        using errcode = '23514';
    end if;
  end loop;

  select count(*)::int into v_open_requests
  from jsonb_each_text(v_requests) x
  where x.value = 'OPEN';

  return query
  select
    case when v_closed then 'CLOSED'
         when v_hold then 'ON_HOLD'
         when v_cur is not null then 'DECIDED'
         when v_recon is not null then 'REOPENED'
         when v_open_requests > 0 then 'AWAITING_RESPONSE'
         else 'OPEN' end,
    v_hold, v_cur, v_recon, v_open_requests;
end $$;

create or replace function s2t_governance._after_event_validate_sequence()
returns trigger language plpgsql
set search_path = pg_catalog, s2t_governance
as $$
begin
  perform * from _replay_state(new.question_id, true);
  return null;
end $$;
create constraint trigger event_sequence_valid
  after insert on s2t_governance.governance_event
  not deferrable
  for each row execute function s2t_governance._after_event_validate_sequence();

-- ---------------------------------------------------------------------
-- 6. Timing
-- ---------------------------------------------------------------------
create or replace function s2t_governance._question_timing(p_question_id uuid)
returns table (
  total_elapsed interval,
  external_waiting interval,
  on_hold interval,
  internal_handling interval,
  time_to_decision interval
)
language sql
stable
set search_path = pg_catalog, s2t_governance
as $$
  with live as (
    select ev.* from governance_event ev
    where ev.question_id = p_question_id
      and ev.event_type <> 'EVENT_RETRACTED'
      and not exists (select 1 from governance_event r where r.retracts_event_id = ev.event_id)
  ),
  b as (
    select g.opened_at as t0,
           d.effective_at as decided_at,
           coalesce(d.effective_at, now()) as t1
    from governance_question g
    cross join lateral _replay_state(g.question_id) s
    left join live d on d.event_id = s.current_decision_id
    where g.question_id = p_question_id
  ),
  w as (select tstzrange(t0, t1, '[)') as win from b),
  waits as (
    select coalesce(range_agg(tstzrange(rq.effective_at,
             coalesce((select min(f.effective_at) from live f
                       where f.related_request_event_id = rq.event_id and f.response_kind = 'FINAL'), 'infinity'), '[)')
             * (select win from w)), '{}'::tstzmultirange) as mr
    from live rq where rq.event_type = 'REQUEST_SENT'
  ),
  holds as (
    select coalesce(range_agg(tstzrange(h.effective_at,
             coalesce((select min(x.effective_at) from live x
                       where x.event_type = 'HOLD_ENDED' and x.effective_at >= h.effective_at), 'infinity'), '[)')
             * (select win from w)), '{}'::tstzmultirange) as mr
    from live h where h.event_type = 'HOLD_STARTED'
  ),
  dur as (
    select (select t1 - t0 from b) as total,
           (select coalesce(sum(upper(r) - lower(r)), interval '0')
              from unnest((select mr from waits) - (select mr from holds)) r) as ext,
           (select coalesce(sum(upper(r) - lower(r)), interval '0')
              from unnest((select mr from holds)) r) as hold
  )
  select total, ext, hold, total - ext - hold, (select decided_at - t0 from b)
  from dur;
$$;

-- ---------------------------------------------------------------------
-- 7. Seed parties
-- ---------------------------------------------------------------------
insert into s2t_governance.governance_party (party_code, party_kind, category, label_he, label_en) values
  ('MAPPING_TEAM',       'MAPPING_TEAM',   'INTERNAL', 'צוות מיפוי',      'Mapping Team'),
  ('CLINICAL_TEAM',      'CLINICAL',       'INTERNAL', 'צוות קליני',      'Clinical Team'),
  ('PHARMACY',           'PHARMACY',       'INTERNAL', 'רוקחות',          'Pharmacy'),
  ('TERMINOLOGY',        'TERMINOLOGY',    'INTERNAL', 'טרמינולוגיה',     'Terminology'),
  ('IL_CORE',            'STANDARDS_BODY', 'EXTERNAL', 'IL-CORE',         'IL-CORE'),
  ('MINISTRY_OF_HEALTH', 'REGULATOR',      'EXTERNAL', 'משרד הבריאות',    'Ministry of Health'),
  ('VENDOR',             'VENDOR',         'EXTERNAL', 'ספק',             'Vendor'),
  ('OTHER_EXTERNAL',     'OTHER',          'EXTERNAL', 'גורם חיצוני אחר', 'Other External');
insert into s2t_governance.governance_party_audit (party_id, action, recorded_by_principal, snapshot)
  select party_id, 'CREATED', null, to_jsonb(p) from s2t_governance.governance_party p;

-- ---------------------------------------------------------------------
-- 8. Read contract
-- ---------------------------------------------------------------------
-- Public views must not require direct EXECUTE on private s2t_governance helpers.
-- Three guarded SECURITY DEFINER wrappers form the read boundary:
--   _governance_read_allowed()
--   _governance_replay_state(uuid)
--   _governance_question_timing(uuid)
-- They are owned by s2t_fhir_owner, expose no mutation path, and return false/zero rows
-- when the current JWT principal is not an authorized reviewer.

create or replace function s2t_fhir_api._governance_read_allowed()
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_governance
as $$
begin
  return s2t_governance._is_reviewer();
end $$;

create or replace function s2t_fhir_api._governance_replay_state(p_question_id uuid)
returns table (
  derived_status            text,
  is_on_hold                boolean,
  current_decision_id       uuid,
  reconsidered_decision_id  uuid,
  open_request_count        integer
)
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_governance
as $$
begin
  if not s2t_governance._is_reviewer() then
    return;
  end if;

  return query
    select *
    from s2t_governance._replay_state(p_question_id);
end $$;

create or replace function s2t_fhir_api._governance_question_timing(p_question_id uuid)
returns table (
  total_elapsed     interval,
  external_waiting  interval,
  on_hold           interval,
  internal_handling interval,
  time_to_decision  interval
)
language plpgsql
stable
security definer
set search_path = pg_catalog, s2t_governance
as $$
begin
  if not s2t_governance._is_reviewer() then
    return;
  end if;

  return query
    select *
    from s2t_governance._question_timing(p_question_id);
end $$;

create view s2t_fhir_api.governance_parties as
  select party_id, party_code, party_kind, category, label_he, label_en, is_active, created_at
  from s2t_governance.governance_party
  where s2t_fhir_api._governance_read_allowed();

create view s2t_fhir_api.governance_question_timeline as
  select ev.event_id, ev.recording_seq, ev.question_id, q.gov_number,
         'GOV-' || lpad(q.gov_number::text, 3, '0') as gov_code,
         ev.event_type, ev.effective_at, ev.recorded_at,
         (ev.recorded_at > ev.effective_at) as recorded_later,
         ev.recorded_by_principal,
         ev.party_id, ev.party_code, ev.party_label_he, ev.party_label_en,
         ev.party_category, ev.party_kind,
         ev.response_kind, ev.related_request_event_id,
         ev.reason, ev.note, ev.decision_text, ev.mapping_impact,
         ev.supersedes_decision_event_id,
         ev.link_id, ev.retracts_event_id,
         exists (
           select 1
           from s2t_governance.governance_event r
           where r.retracts_event_id = ev.event_id
         ) as is_retracted,
         (
           ev.event_type = 'DECISION_RECORDED'
           and exists (
             select 1
             from s2t_governance.governance_event s
             where s.supersedes_decision_event_id = ev.event_id
           )
         ) as is_superseded
  from s2t_governance.governance_event ev
  join s2t_governance.governance_question q using (question_id)
  where s2t_fhir_api._governance_read_allowed();

create view s2t_fhir_api.governance_mapping_links as
  select l.*,
         (
           le.event_id is not null
           and not exists (
             select 1 from s2t_governance.governance_event r
             where r.retracts_event_id = le.event_id
           )
           and not exists (
             select 1
             from s2t_governance.governance_event u
             where u.link_id = l.link_id
               and u.event_type = 'MAPPING_UNLINKED'
               and not exists (
                 select 1 from s2t_governance.governance_event r
                 where r.retracts_event_id = u.event_id
               )
           )
         ) as is_active
  from s2t_governance.governance_mapping_link l
  left join s2t_governance.governance_event le
    on le.link_id = l.link_id
   and le.event_type = 'MAPPING_LINKED'
  where s2t_fhir_api._governance_read_allowed();

create view s2t_fhir_api.governance_open_requests as
  select rq.event_id as request_event_id, rq.question_id, rq.party_id,
         rq.party_code, rq.party_kind, rq.party_label_he, rq.party_label_en,
         rq.party_category, rq.effective_at as sent_at,
         (
           select count(*)
           from s2t_governance.governance_event i
           where i.related_request_event_id = rq.event_id
             and i.event_type = 'RESPONSE_RECEIVED'
             and i.response_kind = 'INTERIM'
             and not exists (
               select 1 from s2t_governance.governance_event r
               where r.retracts_event_id = i.event_id
             )
         ) as interim_count
  from s2t_governance.governance_event rq
  where rq.event_type = 'REQUEST_SENT'
    and not exists (
      select 1 from s2t_governance.governance_event r
      where r.retracts_event_id = rq.event_id
    )
    and not exists (
      select 1
      from s2t_governance.governance_event f
      where f.related_request_event_id = rq.event_id
        and f.event_type = 'RESPONSE_RECEIVED'
        and f.response_kind = 'FINAL'
        and not exists (
          select 1 from s2t_governance.governance_event rr
          where rr.retracts_event_id = f.event_id
        )
    )
    and s2t_fhir_api._governance_read_allowed();

create view s2t_fhir_api.governance_question_timing as
  select q.question_id, t.*
  from s2t_governance.governance_question q
  cross join lateral s2t_fhir_api._governance_question_timing(q.question_id) t
  where s2t_fhir_api._governance_read_allowed();

create view s2t_fhir_api.governance_questions as
  select q.question_id, q.gov_number,
         'GOV-' || lpad(q.gov_number::text, 3, '0') as gov_code,
         q.title, q.question_text, q.opened_at, q.recorded_at, q.opened_by_principal,
         s.derived_status, s.is_on_hold, s.open_request_count,
         s.current_decision_id,
         cd.decision_text as current_decision_text,
         cd.mapping_impact as current_mapping_impact,
         s.reconsidered_decision_id,
         rd.decision_text as reconsidered_decision_text,
         rd.mapping_impact as reconsidered_mapping_impact,
         t.total_elapsed, t.external_waiting, t.on_hold,
         t.internal_handling, t.time_to_decision,
         (
           select max(ev.recorded_at)
           from s2t_governance.governance_event ev
           where ev.question_id = q.question_id
         ) as last_activity_at,
         (
           select array_agg(distinct l.resource_config_id)
           from s2t_governance.governance_mapping_link l
           where l.question_id = q.question_id
         ) as resource_config_ids,
         (
           select array_agg(distinct l.fhir_resource_type)
           from s2t_governance.governance_mapping_link l
           where l.question_id = q.question_id
         ) as fhir_resource_types,
         (
           select array_agg(distinct l.profile_label)
           from s2t_governance.governance_mapping_link l
           where l.question_id = q.question_id
         ) as profile_labels
  from s2t_governance.governance_question q
  cross join lateral s2t_fhir_api._governance_replay_state(q.question_id) s
  cross join lateral s2t_fhir_api._governance_question_timing(q.question_id) t
  left join s2t_governance.governance_event cd
    on cd.event_id = s.current_decision_id
  left join s2t_governance.governance_event rd
    on rd.event_id = s.reconsidered_decision_id
  where s2t_fhir_api._governance_read_allowed();

-- ---------------------------------------------------------------------
-- 9. Write contract (SECURITY DEFINER; verified reviewer auth; no review session)
-- ---------------------------------------------------------------------
create or replace function s2t_governance._party_snapshot(p_party_id uuid)
returns s2t_governance.governance_party
language plpgsql stable set search_path = pg_catalog, s2t_governance as $$
declare p governance_party;
begin
  select * into p from governance_party where party_id = p_party_id;
  if p.party_id is null then raise exception 'unknown party' using errcode = '23503'; end if;
  return p;
end $$;

create or replace function s2t_governance._insert_link(p_question_id uuid, p_link jsonb, p_principal uuid, p_effective timestamptz)
returns uuid language plpgsql set search_path = pg_catalog, s2t_governance as $$
declare v_link uuid; m jsonb;
begin
  m := _resolve_mapping_identity(p_link->>'resource_config_id', p_link->>'baseline_code', p_link->>'node_id');
  insert into governance_mapping_link (question_id, resource_config_id, baseline_code, node_id,
    mapping_kind, fhir_resource_type, version_label, target_element, element_path,
    profile_label, decision_status_at_link,
    source_sheet, source_row, source_cell_range, artifact_sha256, linked_by_principal)
  values (p_question_id, m->>'resource_config_id', m->>'baseline_code', m->>'node_id',
    m->>'mapping_kind', m->>'fhir_resource_type', m->>'version_label', m->>'target_element',
    case
      when m->'element_path' is null or jsonb_typeof(m->'element_path') = 'null' then null
      when jsonb_typeof(m->'element_path') = 'array'
        then array(select jsonb_array_elements_text(m->'element_path'))
      else
        null
    end,
    m->>'profile_label', m->>'decision_status',
    m->>'source_sheet', (m->>'source_row')::int, m->>'source_cell_range', m->>'artifact_sha256', p_principal)
  returning link_id into v_link;
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, link_id)
  values (p_question_id, 'MAPPING_LINKED', p_effective, p_principal, v_link);
  return v_link;
end $$;

create or replace function s2t_fhir_api.gov_open_question(p_title text, p_question_text text, p_opened_at timestamptz, p_links jsonb default '[]')
returns jsonb language plpgsql security definer
set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_q governance_question; l jsonb;
begin
  if p_opened_at > now() then raise exception 'invalid opened_at: in the future' using errcode = '22007'; end if;
  insert into governance_question (title, question_text, opened_at, opened_by_principal)
  values (btrim(p_title), btrim(p_question_text), p_opened_at, v_pr) returning * into v_q;
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal)
  values (v_q.question_id, 'QUESTION_CREATED', p_opened_at, v_pr);
  for l in select * from jsonb_array_elements(coalesce(p_links, '[]')) loop
    perform _insert_link(v_q.question_id, l, v_pr, p_opened_at);
  end loop;
  return jsonb_build_object('question_id', v_q.question_id, 'gov_number', v_q.gov_number);
end $$;

create or replace function s2t_fhir_api.gov_link_mapping(p_question_id uuid, p_link jsonb, p_effective_at timestamptz default now())
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal();
begin
  perform _lock_question(p_question_id);
  return _insert_link(p_question_id, p_link, v_pr, p_effective_at);
end $$;

create or replace function s2t_fhir_api.gov_unlink_mapping(p_question_id uuid, p_link_id uuid, p_reason text, p_effective_at timestamptz default now())
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_id uuid;
begin
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, link_id, reason)
  values (p_question_id, 'MAPPING_UNLINKED', p_effective_at, v_pr, p_link_id, btrim(p_reason)) returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_add_note(p_question_id uuid, p_note text, p_effective_at timestamptz default now(), p_party_id uuid default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_p governance_party; v_id uuid;
begin
  if p_party_id is not null then v_p := _party_snapshot(p_party_id); end if;
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, note,
    party_id, party_code, party_label_he, party_label_en, party_category, party_kind)
  values (p_question_id, 'NOTE_ADDED', p_effective_at, v_pr, btrim(p_note),
    v_p.party_id, v_p.party_code, v_p.label_he, v_p.label_en, v_p.category, v_p.party_kind)
  returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_record_request(p_question_id uuid, p_party_id uuid, p_effective_at timestamptz, p_note text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_p governance_party := _party_snapshot(p_party_id); v_id uuid;
begin
  if not v_p.is_active then raise exception 'invalid party: inactive' using errcode = '23514'; end if;
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, note,
    party_id, party_code, party_label_he, party_label_en, party_category, party_kind)
  values (p_question_id, 'REQUEST_SENT', p_effective_at, v_pr, nullif(btrim(p_note), ''),
    v_p.party_id, v_p.party_code, v_p.label_he, v_p.label_en, v_p.category, v_p.party_kind)
  returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_record_response(p_question_id uuid, p_request_event_id uuid, p_response_kind text, p_effective_at timestamptz, p_note text)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_r governance_event; v_id uuid;
begin
  select * into v_r from governance_event where event_id = p_request_event_id and question_id = p_question_id and event_type = 'REQUEST_SENT';
  if v_r.event_id is null then
    raise exception 'invalid response: related request must be a REQUEST_SENT on the same question' using errcode = '23514';
  end if;
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, note,
    response_kind, related_request_event_id,
    party_id, party_code, party_label_he, party_label_en, party_category, party_kind)
  values (p_question_id, 'RESPONSE_RECEIVED', p_effective_at, v_pr, btrim(p_note),
    p_response_kind, p_request_event_id,
    v_r.party_id, v_r.party_code, v_r.party_label_he, v_r.party_label_en, v_r.party_category, v_r.party_kind)
  returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_start_hold(p_question_id uuid, p_reason text, p_effective_at timestamptz)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_id uuid;
begin
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, reason)
  values (p_question_id, 'HOLD_STARTED', p_effective_at, _current_reviewer_principal(), btrim(p_reason)) returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_end_hold(p_question_id uuid, p_effective_at timestamptz, p_note text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_id uuid;
begin
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, note)
  values (p_question_id, 'HOLD_ENDED', p_effective_at, _current_reviewer_principal(), nullif(btrim(p_note), '')) returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_record_decision(p_question_id uuid, p_decision_text text, p_mapping_impact text, p_effective_at timestamptz)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); s record; v_id uuid;
begin
  perform _lock_question(p_question_id);
  select * into s from _replay_state(p_question_id);
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal,
    decision_text, mapping_impact, supersedes_decision_event_id)
  values (p_question_id, 'DECISION_RECORDED', p_effective_at, v_pr,
    btrim(p_decision_text), p_mapping_impact, coalesce(s.current_decision_id, s.reconsidered_decision_id))
  returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_reopen(p_question_id uuid, p_reason text, p_effective_at timestamptz)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_id uuid;
begin
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, reason)
  values (p_question_id, 'REOPENED', p_effective_at, _current_reviewer_principal(), btrim(p_reason)) returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_close(p_question_id uuid, p_effective_at timestamptz, p_note text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_id uuid;
begin
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, note)
  values (p_question_id, 'CLOSED', p_effective_at, _current_reviewer_principal(), nullif(btrim(p_note), '')) returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_retract_event(p_event_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_q uuid; v_id uuid;
begin
  select question_id into v_q from governance_event where event_id = p_event_id;
  if v_q is null then raise exception 'invalid retraction: unknown event' using errcode = '23503'; end if;
  insert into governance_event (question_id, event_type, effective_at, recorded_by_principal, retracts_event_id, reason)
  values (v_q, 'EVENT_RETRACTED', now(), v_pr, p_event_id, btrim(p_reason)) returning event_id into v_id;
  return v_id;
end $$;

create or replace function s2t_fhir_api.gov_add_party(p_code text, p_kind text, p_category text, p_label_he text, p_label_en text)
returns uuid language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_p governance_party;
begin
  insert into governance_party (party_code, party_kind, category, label_he, label_en, created_by_principal)
  values (upper(btrim(p_code)), p_kind, p_category, btrim(p_label_he), btrim(p_label_en), v_pr) returning * into v_p;
  insert into governance_party_audit (party_id, action, recorded_by_principal, snapshot)
  values (v_p.party_id, 'CREATED', v_pr, to_jsonb(v_p));
  return v_p.party_id;
end $$;

create or replace function s2t_fhir_api.gov_set_party_active(p_party_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = pg_catalog, s2t_governance as $$
declare v_pr uuid := _current_reviewer_principal(); v_p governance_party;
begin
  update governance_party set is_active = p_active where party_id = p_party_id and is_active <> p_active returning * into v_p;
  if v_p.party_id is null then raise exception 'party not found or unchanged' using errcode = '23503'; end if;
  insert into governance_party_audit (party_id, action, recorded_by_principal, snapshot)
  values (v_p.party_id, case when p_active then 'REACTIVATED' else 'DEACTIVATED' end, v_pr, to_jsonb(v_p));
end $$;

-- ---------------------------------------------------------------------
-- 10. Grants / revokes
-- ---------------------------------------------------------------------
revoke all on all tables    in schema s2t_governance from public, anon, authenticated;
revoke all on all sequences in schema s2t_governance from public, anon, authenticated;
revoke all on all functions in schema s2t_governance from public, anon, authenticated;

-- Read wrappers are the only executable bridge from authenticated views into
-- private Governance read helpers.
revoke all on function s2t_fhir_api._governance_read_allowed() from public, anon;
revoke all on function s2t_fhir_api._governance_replay_state(uuid) from public, anon;
revoke all on function s2t_fhir_api._governance_question_timing(uuid) from public, anon;
grant execute on function s2t_fhir_api._governance_read_allowed() to authenticated;
grant execute on function s2t_fhir_api._governance_replay_state(uuid) to authenticated;
grant execute on function s2t_fhir_api._governance_question_timing(uuid) to authenticated;

revoke all on s2t_fhir_api.governance_parties, s2t_fhir_api.governance_question_timeline,
  s2t_fhir_api.governance_mapping_links, s2t_fhir_api.governance_open_requests,
  s2t_fhir_api.governance_question_timing, s2t_fhir_api.governance_questions
  from public, anon;
grant select on s2t_fhir_api.governance_parties, s2t_fhir_api.governance_question_timeline,
  s2t_fhir_api.governance_mapping_links, s2t_fhir_api.governance_open_requests,
  s2t_fhir_api.governance_question_timing, s2t_fhir_api.governance_questions
  to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'gov_open_question(text,text,timestamptz,jsonb)',
    'gov_link_mapping(uuid,jsonb,timestamptz)',
    'gov_unlink_mapping(uuid,uuid,text,timestamptz)',
    'gov_add_note(uuid,text,timestamptz,uuid)',
    'gov_record_request(uuid,uuid,timestamptz,text)',
    'gov_record_response(uuid,uuid,text,timestamptz,text)',
    'gov_start_hold(uuid,text,timestamptz)',
    'gov_end_hold(uuid,timestamptz,text)',
    'gov_record_decision(uuid,text,text,timestamptz)',
    'gov_reopen(uuid,text,timestamptz)',
    'gov_close(uuid,timestamptz,text)',
    'gov_retract_event(uuid,text)',
    'gov_add_party(text,text,text,text,text)',
    'gov_set_party_active(uuid,boolean)'
  ] loop
    execute format('revoke all on function s2t_fhir_api.%s from public, anon', f);
    execute format('grant execute on function s2t_fhir_api.%s to authenticated', f);
  end loop;
end $$;

-- =====================================================================
-- ROLLBACK GUIDANCE (do not execute; only valid before any real governance data exists)
-- =====================================================================
-- begin; set local role s2t_fhir_owner;
-- drop view if exists s2t_fhir_api.governance_questions, s2t_fhir_api.governance_question_timing,
--   s2t_fhir_api.governance_open_requests, s2t_fhir_api.governance_mapping_links,
--   s2t_fhir_api.governance_question_timeline, s2t_fhir_api.governance_parties;
-- drop function if exists s2t_fhir_api._governance_read_allowed(),
--   s2t_fhir_api._governance_replay_state(uuid),
--   s2t_fhir_api._governance_question_timing(uuid);
-- drop function if exists  -- all 14 s2t_fhir_api.gov_* signatures listed in §10
--   s2t_fhir_api.gov_open_question(text,text,timestamptz,jsonb), ...;
-- drop schema s2t_governance cascade;
-- commit;
-- Auth and mapping-identity dependencies belong to the review/mapping layers and are NOT dropped here.
-- No mapping / Baseline / review objects are modified by this candidate.
-- Revision 7 deliberately preserves GOVERNANCE_GUIDANCE element_path as NULL.
-- recording_seq belongs only to Governance and does not mutate mapping/Baseline/review data.


-- =====================================================================
-- PART B — Governance Revision 7 tests with T18 + T20/T21 harness fixes
-- =====================================================================
-- =====================================================================
-- Governance Phase 1 — REVISION 7 TESTS
-- STATUS: REVIEW CANDIDATE — DO NOT EXECUTE UNTIL REVISION 7 IS APPROVED/APPLIED IN TEST.
-- Target: S2T-FHIR-DDL-Test.
--
-- Supabase SQL Editor compatible:
--   * no psql meta-commands
--   * no direct authenticated SELECT from governed_mapping_identity
--   * owner pre-resolves mapping identity keys, then authenticated receives only those keys
--   * temporary harness tables have explicit minimal grants across SET ROLE
--
-- Test data is wrapped in one transaction and rolled back.
-- If a runtime/syntax/permission error aborts before final ROLLBACK, issue ROLLBACK;
-- or close/reopen the SQL Editor connection before retry.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Editable parameters
-- ---------------------------------------------------------------------
create temp table _gov_test_params (
  reviewer_uid       text not null,
  noperm_uid         text not null,
  resource_config_id text not null
) on commit drop;

insert into _gov_test_params(reviewer_uid, noperm_uid, resource_config_id)
values (
  '1f60579c-5450-4ff7-a2a9-d6f0f4b91dbb',
  '11111111-1111-1111-1111-111111111111',
  'medication-request-cato'
);

do $$
begin
  if exists (
    select 1 from _gov_test_params
    where reviewer_uid like '<%' or noperm_uid like '<%'
  ) then
    raise exception 'TEST PARAMETERS NOT SET: replace the two UID placeholders before running';
  end if;
end $$;

create temp table _gov_test_result (
  seq integer primary key,
  test_name text not null,
  result text not null check (result in ('PASS','FAIL')),
  details text
) on commit drop;

create temp table _ids (
  name text primary key,
  id uuid not null
) on commit drop;

-- Owner-only setup: pre-resolve ONLY the permitted three mapping identity keys.
create temp table _gov_test_mapping_keys (
  mapping_kind text primary key,
  resource_config_id text not null,
  baseline_code text not null,
  node_id text not null
) on commit drop;

insert into _gov_test_mapping_keys(mapping_kind, resource_config_id, baseline_code, node_id)
select distinct on (m.mapping_kind)
       m.mapping_kind, m.resource_config_id, m.baseline_code, m.node_id
from s2t_fhir_api.governed_mapping_identity m
where m.resource_config_id = (select resource_config_id from _gov_test_params)
  and m.is_active_baseline
  and m.mapping_kind in ('ELEMENT_MAPPING','GOVERNANCE_GUIDANCE')
order by m.mapping_kind, m.node_id;

do $$
begin
  if not exists (select 1 from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING') then
    raise exception 'TEST DATASET ERROR: no active ELEMENT_MAPPING row';
  end if;
  if not exists (select 1 from _gov_test_mapping_keys where mapping_kind='GOVERNANCE_GUIDANCE') then
    raise exception 'TEST DATASET ERROR: no active GOVERNANCE_GUIDANCE row';
  end if;
end $$;

-- Minimal harness privileges needed after SET ROLE authenticated.
grant select on _gov_test_params, _gov_test_mapping_keys to authenticated;
grant select, insert on _ids to authenticated;
grant insert on _gov_test_result to authenticated;

create function pg_temp.claims(p_uid text) returns void language sql as $$
  select set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text,
    true
  );
$$;

-- Narrow non-interference fingerprints.
create temp table _fp_before on commit drop as
select 'active_mapping_record' k,
       md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.mapping_key), '')) v
from s2t_fhir_api.active_mapping_record x
union all
select 'active_baseline',
       md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.source_system, x.fhir_resource, x.baseline_code), ''))
from s2t_fhir_api.active_baseline x
union all
select 'review',
       md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.node_id), ''))
from s2t_fhir_api.active_mapping_review_status x;

-- ---------------------------------------------------------------------
-- T01 dependency contracts + schema ownership
-- ---------------------------------------------------------------------
do $$
declare
  bad int := 0;
  p record;
begin
  if to_regprocedure('s2t_fhir_api._require_authenticated_review_principal()') is null
     or to_regclass('s2t_fhir_api.governed_mapping_identity') is null then
    bad := bad + 1;
  end if;

  if (select pg_get_userbyid(nspowner) from pg_namespace where nspname='s2t_fhir_api')
       is distinct from 's2t_fhir_owner' then bad := bad + 1; end if;
  if (select pg_get_userbyid(nspowner) from pg_namespace where nspname='s2t_governance')
       is distinct from 's2t_fhir_owner' then bad := bad + 1; end if;

  select pg_get_userbyid(pr.proowner) owner_name,
         format_type(pr.prorettype,null) return_type,
         pr.prosecdef,
         pr.provolatile,
         coalesce(array_to_string(pr.proconfig,','),'') config
    into p
  from pg_proc pr
  where pr.oid='s2t_fhir_api._require_authenticated_review_principal()'::regprocedure;

  if p.owner_name <> 's2t_fhir_owner'
     or p.return_type <> 'uuid'
     or not p.prosecdef
     or p.provolatile <> 's'
     or p.config not like '%search_path=pg_catalog, s2t_fhir_api%' then
    bad := bad + 1;
  end if;

  -- Least-privilege bootstrap invariant: s2t_fhir_owner may lack database CREATE.
  -- The migration runner is responsible for CREATE SCHEMA ... AUTHORIZATION.
  if has_database_privilege('s2t_fhir_owner', current_database(), 'CREATE') then
    null; -- Allowed, but not required.
  end if;

  insert into _gov_test_result values
    (1,'T01 dependency contracts + API/Governance schema ownership',
     case when bad=0 then 'PASS' else 'FAIL' end,
     'bad='||bad||', owner_db_create='||
       has_database_privilege('s2t_fhir_owner', current_database(), 'CREATE'));
end $$;

-- ---------------------------------------------------------------------
-- T02 ownership of Governance relations, sequences and functions
-- ---------------------------------------------------------------------
do $$
declare bad_rel int; bad_fn int;
begin
  select count(*) into bad_rel
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and c.relname like 'governance_%')
    )
    and pg_get_userbyid(c.relowner) <> 's2t_fhir_owner';

  select count(*) into bad_fn
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and (
            p.proname like 'gov\_%'
            or p.proname like '\_governance\_%'
          ))
    )
    and pg_get_userbyid(p.proowner) <> 's2t_fhir_owner';

  insert into _gov_test_result values
    (2,'T02 Governance relations/sequences/functions owned by s2t_fhir_owner',
     case when bad_rel=0 and bad_fn=0 then 'PASS' else 'FAIL' end,
     'bad_rel='||bad_rel||', bad_fn='||bad_fn);
end $$;

-- ---------------------------------------------------------------------
-- T03 private helpers denied; guarded public read wrappers executable
-- ---------------------------------------------------------------------
select pg_temp.claims((select reviewer_uid from _gov_test_params));
set local role authenticated;
do $$
declare
  private_denied boolean := false;
  wrapper_ok boolean := false;
begin
  begin
    perform s2t_governance._replay_state(gen_random_uuid());
  exception when insufficient_privilege then
    private_denied := true;
  end;

  begin
    perform s2t_fhir_api._governance_read_allowed();
    perform * from s2t_fhir_api._governance_replay_state(gen_random_uuid());
    perform * from s2t_fhir_api._governance_question_timing(gen_random_uuid());
    wrapper_ok := true;
  exception when others then
    wrapper_ok := false;
  end;

  insert into _gov_test_result values
    (3,'T03 private helpers denied; guarded API read wrappers executable',
     case when private_denied and wrapper_ok then 'PASS' else 'FAIL' end,
     'private_denied='||private_denied||', wrapper_ok='||wrapper_ok);
end $$;
reset role;

-- ---------------------------------------------------------------------
-- T04 non-reviewer public contract
-- ---------------------------------------------------------------------
select pg_temp.claims((select noperm_uid from _gov_test_params));
set local role authenticated;
do $$
declare ok boolean := true; c int;
begin
  select count(*) into c from s2t_fhir_api.governance_questions;
  if c <> 0 then ok := false; end if;

  if s2t_fhir_api._governance_read_allowed() then
    ok := false;
  end if;

  select count(*) into c
  from s2t_fhir_api._governance_replay_state(gen_random_uuid());
  if c <> 0 then ok := false; end if;

  select count(*) into c
  from s2t_fhir_api._governance_question_timing(gen_random_uuid());
  if c <> 0 then ok := false; end if;

  begin
    perform s2t_fhir_api.gov_open_question('No permission','Synthetic test',now(),'[]');
    ok := false;
  exception when insufficient_privilege then null;
  end;

  insert into _gov_test_result values
    (4,'T04 non-reviewer sees no governed rows and cannot write',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Reviewer tests
-- ---------------------------------------------------------------------
select pg_temp.claims((select reviewer_uid from _gov_test_params));
set local role authenticated;

-- T05 open question
do $$
declare q uuid;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Governance R5 test','Synthetic reviewer flow',
          now()-interval '40 days','[]'
       )->>'question_id')::uuid;
  insert into _ids values ('q',q);
  insert into _gov_test_result values (5,'T05 reviewer opens question','PASS',q::text);
end $$;

-- T06 response lifecycle
do $$
declare q uuid; party uuid; r uuid; ok boolean := true;
begin
  select id into q from _ids where name='q';
  select party_id into party from s2t_fhir_api.governance_parties where party_code='IL_CORE';

  r := s2t_fhir_api.gov_record_request(q,party,now()-interval '30 days','request');
  insert into _ids values ('request_final',r);

  perform s2t_fhir_api.gov_record_response(q,r,'INTERIM',now()-interval '29 days','interim 1');
  perform s2t_fhir_api.gov_record_response(q,r,'INTERIM',now()-interval '28 days','interim 2');
  perform s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '27 days','final');

  begin
    perform s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '26 days','duplicate final');
    ok := false;
  exception when check_violation then null; end;

  begin
    perform s2t_fhir_api.gov_record_response(q,r,'INTERIM',now()-interval '25 days','late interim');
    ok := false;
  exception when check_violation then null; end;

  insert into _gov_test_result values
    (6,'T06 INTERIM* then one FINAL; nothing after FINAL',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T07 cannot retract request beneath live responses
do $$
declare r uuid; ok boolean := false;
begin
  select id into r from _ids where name='request_final';
  begin
    perform s2t_fhir_api.gov_retract_event(r,'must fail');
  exception when check_violation then ok := true; end;

  insert into _gov_test_result values
    (7,'T07 request retraction cannot orphan live responses',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T08 unknown/inactive mapping fails closed
do $$
declare q uuid; ok boolean := false;
begin
  select id into q from _ids where name='q';
  begin
    perform s2t_fhir_api.gov_link_mapping(
      q,
      jsonb_build_object(
        'resource_config_id',(select resource_config_id from _gov_test_params),
        'baseline_code','NO-SUCH-BASELINE',
        'node_id','map-v1-does-not-exist'
      ),
      now()
    );
  exception when foreign_key_violation then ok := true; end;

  insert into _gov_test_result values
    (8,'T08 unknown/inactive mapping identity fails closed',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T09 client sends only identity keys; server snapshots metadata
do $$
declare q uuid; lk uuid; k record; ok boolean;
begin
  select id into q from _ids where name='q';
  select * into k from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING';

  lk := s2t_fhir_api.gov_link_mapping(
    q,
    jsonb_build_object(
      'resource_config_id',k.resource_config_id,
      'baseline_code',k.baseline_code,
      'node_id',k.node_id,
      'target_element','CLIENT-SUPPLIED-IGNORED',
      'mapping_kind','CLIENT-SUPPLIED-IGNORED'
    ),
    now()
  );
  insert into _ids values ('element_link',lk);

  select target_element <> 'CLIENT-SUPPLIED-IGNORED'
     and mapping_kind='ELEMENT_MAPPING'
  into ok
  from s2t_fhir_api.governance_mapping_links
  where link_id=lk;

  insert into _gov_test_result values
    (9,'T09 server snapshots mapping metadata; client extras ignored',
     case when coalesce(ok,false) then 'PASS' else 'FAIL' end,null);
end $$;

-- T10 guidance NULL element_path preserved
do $$
declare q uuid; lk uuid; k record; ok boolean;
begin
  select id into q from _ids where name='q';
  select * into k from _gov_test_mapping_keys where mapping_kind='GOVERNANCE_GUIDANCE';

  lk := s2t_fhir_api.gov_link_mapping(
    q,
    jsonb_build_object(
      'resource_config_id',k.resource_config_id,
      'baseline_code',k.baseline_code,
      'node_id',k.node_id
    ),
    now()
  );

  select mapping_kind='GOVERNANCE_GUIDANCE' and element_path is null
  into ok
  from s2t_fhir_api.governance_mapping_links
  where link_id=lk;

  insert into _gov_test_result values
    (10,'T10 GOVERNANCE_GUIDANCE preserves element_path NULL',
     case when coalesce(ok,false) then 'PASS' else 'FAIL' end,null);
end $$;

-- T11 link -> unlink causal chain; cannot retract link beneath live unlink
do $$
declare q uuid; lk uuid; le uuid; ok boolean := false;
begin
  select id into q from _ids where name='q';
  select id into lk from _ids where name='element_link';

  select event_id into le
  from s2t_fhir_api.governance_question_timeline
  where question_id=q and link_id=lk and event_type='MAPPING_LINKED';

  perform s2t_fhir_api.gov_unlink_mapping(q,lk,'synthetic unlink',now());

  begin
    perform s2t_fhir_api.gov_retract_event(le,'must fail');
  exception when check_violation then ok := true; end;

  insert into _gov_test_result values
    (11,'T11 MAPPING_LINKED cannot be retracted beneath live unlink',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T12 deterministic equal-effective-time order:
-- request->response, hold-start->hold-end, link->unlink all share one effective timestamp.
do $$
declare
  q uuid; p uuid; r uuid; lk uuid; k record;
  t0 timestamptz := now()-interval '1 day';
  ok boolean := true;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Equal-time ordering','Deterministic sequence test',
          now()-interval '2 days','[]'
       )->>'question_id')::uuid;

  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';

  r := s2t_fhir_api.gov_record_request(q,p,t0,null);
  perform s2t_fhir_api.gov_record_response(q,r,'FINAL',t0,'same effective time');

  perform s2t_fhir_api.gov_start_hold(q,'same-time hold',t0);
  perform s2t_fhir_api.gov_end_hold(q,t0,'same effective time');

  select * into k from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING';
  lk := s2t_fhir_api.gov_link_mapping(
    q,
    jsonb_build_object(
      'resource_config_id',k.resource_config_id,
      'baseline_code',k.baseline_code,
      'node_id',k.node_id
    ),
    t0
  );
  perform s2t_fhir_api.gov_unlink_mapping(q,lk,'same effective time',t0);

  if exists (
    select 1
    from (
      select event_type, recording_seq,
             lag(recording_seq) over(order by effective_at, recording_seq) prev_seq
      from s2t_fhir_api.governance_question_timeline
      where question_id=q
    ) s
    where prev_seq is not null and recording_seq <= prev_seq
  ) then
    ok := false;
  end if;

  insert into _gov_test_result values
    (12,'T12 equal-effective-time causal order uses immutable recording_seq',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T13 exact timing with overlapping waits and hold
do $$
declare q uuid; il uuid; term uuid; r1 uuid; r2 uuid; t record; ok boolean;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Timing test','Synthetic timing flow',
          now()-interval '40 days','[]'
       )->>'question_id')::uuid;

  select party_id into il from s2t_fhir_api.governance_parties where party_code='IL_CORE';
  select party_id into term from s2t_fhir_api.governance_parties where party_code='TERMINOLOGY';

  r1 := s2t_fhir_api.gov_record_request(q,il,now()-interval '30 days',null);
  r2 := s2t_fhir_api.gov_record_request(q,term,now()-interval '25 days',null);
  perform s2t_fhir_api.gov_record_response(q,r1,'FINAL',now()-interval '22 days','final');
  perform s2t_fhir_api.gov_record_response(q,r2,'FINAL',now()-interval '20 days','final');
  perform s2t_fhir_api.gov_start_hold(q,'hold',now()-interval '15 days');
  perform s2t_fhir_api.gov_end_hold(q,now()-interval '10 days');
  perform s2t_fhir_api.gov_record_decision(q,'decision','DOCUMENTATION_ONLY',now()-interval '5 days');

  select * into t from s2t_fhir_api.governance_question_timing where question_id=q;

  ok := round(extract(epoch from t.total_elapsed)/86400)=35
    and round(extract(epoch from t.external_waiting)/86400)=10
    and round(extract(epoch from t.on_hold)/86400)=5
    and round(extract(epoch from t.internal_handling)/86400)=20
    and round(extract(epoch from t.time_to_decision)/86400)=35;

  insert into _gov_test_result values
    (13,'T13 timing unions waits, excludes holds, preserves totals',
     case when ok then 'PASS' else 'FAIL' end,
     'total='||t.total_elapsed||', external='||t.external_waiting||
     ', hold='||t.on_hold||', internal='||t.internal_handling||
     ', ttd='||t.time_to_decision);
end $$;

-- T14 CLOSED rejects open request
do $$
declare q uuid; p uuid; r uuid; ok boolean := false;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Close guard','Synthetic close guard',
          now()-interval '3 days','[]'
       )->>'question_id')::uuid;
  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';
  r := s2t_fhir_api.gov_record_request(q,p,now()-interval '2 days',null);
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '1 day');

  begin
    perform s2t_fhir_api.gov_close(q,now(),null);
  exception when check_violation then ok := true; end;

  insert into _gov_test_result values
    (14,'T14 CLOSED rejected while request lacks FINAL',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T15 CLOSED operation contract + REOPEN success
do $$
declare
  q uuid; p uuid; r uuid; k record; lk uuid;
  note_ok boolean := false;
  request_reject boolean := false;
  hold_reject boolean := false;
  decision_reject boolean := false;
  link_reject boolean := false;
  close_reject boolean := false;
  reopen_ok boolean := false;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Closed operations','Synthetic closed flow',
          now()-interval '5 days','[]'
       )->>'question_id')::uuid;
  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';

  r := s2t_fhir_api.gov_record_request(q,p,now()-interval '4 days',null);
  perform s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '3 days','final');
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '2 days');
  perform s2t_fhir_api.gov_close(q,now()-interval '1 day',null);

  perform s2t_fhir_api.gov_add_note(q,'audit note after close',now(),null);
  note_ok := true;

  begin perform s2t_fhir_api.gov_record_request(q,p,now(),null);
  exception when check_violation then request_reject := true; end;

  begin perform s2t_fhir_api.gov_start_hold(q,'not allowed',now());
  exception when check_violation then hold_reject := true; end;

  begin perform s2t_fhir_api.gov_record_decision(q,'not allowed','NO_CHANGE',now());
  exception when check_violation then decision_reject := true; end;

  select * into k from _gov_test_mapping_keys where mapping_kind='ELEMENT_MAPPING';
  begin
    lk := s2t_fhir_api.gov_link_mapping(
      q,
      jsonb_build_object(
        'resource_config_id',k.resource_config_id,
        'baseline_code',k.baseline_code,
        'node_id',k.node_id
      ),
      now()
    );
  exception when check_violation then link_reject := true; end;

  begin perform s2t_fhir_api.gov_close(q,now(),null);
  exception when check_violation then close_reject := true; end;

  perform s2t_fhir_api.gov_reopen(q,'new evidence',now());
  reopen_ok := (select derived_status='REOPENED'
                from s2t_fhir_api.governance_questions where question_id=q);

  insert into _gov_test_result values
    (15,'T15 CLOSED contract: note allowed, lifecycle writes rejected, REOPEN succeeds',
     case when note_ok and request_reject and hold_reject and decision_reject
                    and link_reject and close_reject and reopen_ok
          then 'PASS' else 'FAIL' end,null);
end $$;

-- T16 causal retraction cases
do $$
declare
  q uuid; p uuid; r uuid; final_ev uuid;
  hs uuid; he uuid;
  ok_final boolean := false;
  ok_hs boolean := false;
  ok_he boolean := false;
begin
  -- FINAL beneath CLOSED
  q := (s2t_fhir_api.gov_open_question(
          'Retraction final','Synthetic',
          now()-interval '5 days','[]'
       )->>'question_id')::uuid;
  select party_id into p from s2t_fhir_api.governance_parties where party_code='IL_CORE';
  r := s2t_fhir_api.gov_record_request(q,p,now()-interval '4 days',null);
  final_ev := s2t_fhir_api.gov_record_response(q,r,'FINAL',now()-interval '3 days','final');
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '2 days');
  perform s2t_fhir_api.gov_close(q,now()-interval '1 day',null);
  begin perform s2t_fhir_api.gov_retract_event(final_ev,'must fail');
  exception when check_violation then ok_final := true; end;

  -- HOLD_STARTED beneath HOLD_ENDED
  q := (s2t_fhir_api.gov_open_question(
          'Retraction hold start','Synthetic',
          now()-interval '5 days','[]'
       )->>'question_id')::uuid;
  hs := s2t_fhir_api.gov_start_hold(q,'hold',now()-interval '4 days');
  he := s2t_fhir_api.gov_end_hold(q,now()-interval '3 days');
  begin perform s2t_fhir_api.gov_retract_event(hs,'must fail');
  exception when check_violation then ok_hs := true; end;

  -- HOLD_ENDED beneath later decision
  perform s2t_fhir_api.gov_record_decision(q,'decision','NO_CHANGE',now()-interval '2 days');
  begin perform s2t_fhir_api.gov_retract_event(he,'must fail');
  exception when check_violation then ok_he := true; end;

  insert into _gov_test_result values
    (16,'T16 causal retractions cannot invalidate FINAL/hold dependencies',
     case when ok_final and ok_hs and ok_he then 'PASS' else 'FAIL' end,null);
end $$;

-- T17 invalid backdated event is rejected and absent
do $$
declare q uuid; before_n int; after_n int; ok boolean := false;
begin
  q := (s2t_fhir_api.gov_open_question(
          'Backdated replay','Synthetic',
          now()-interval '10 days','[]'
       )->>'question_id')::uuid;

  perform s2t_fhir_api.gov_start_hold(q,'hold',now()-interval '5 days');
  perform s2t_fhir_api.gov_end_hold(q,now()-interval '3 days');

  select count(*) into before_n
  from s2t_fhir_api.governance_question_timeline where question_id=q;

  begin
    perform s2t_fhir_api.gov_end_hold(q,now()-interval '7 days','invalid backdate');
  exception when check_violation then ok := true; end;

  select count(*) into after_n
  from s2t_fhir_api.governance_question_timeline where question_id=q;

  if before_n <> after_n then ok := false; end if;

  insert into _gov_test_result values
    (17,'T17 replay rejects invalid backdated history with no residue',
     case when ok then 'PASS' else 'FAIL' end,
     'before='||before_n||', after='||after_n);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Owner/static tests after reviewer flow
-- ---------------------------------------------------------------------

-- T18 append-only protection
-- TRUNCATE targets governance_event so FK topology does not mask the append-only trigger.
do $$
declare ok boolean := true;
begin
  begin update s2t_governance.governance_event set note='x'; ok:=false;
  exception when insufficient_privilege then null; end;
  begin delete from s2t_governance.governance_question; ok:=false;
  exception when insufficient_privilege then null; end;
  begin truncate s2t_governance.governance_event; ok:=false;
  exception when insufficient_privilege then null; end;

  insert into _gov_test_result values
    (18,'T18 append-only UPDATE/DELETE/TRUNCATE protection',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T19 client privilege model
do $$
declare bad_table int; bad_fn int;
begin
  select count(*) into bad_table
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='s2t_governance'
    and (
      has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE')
      or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE')
    );

  select count(*) into bad_fn
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='s2t_governance'
    and (
      has_function_privilege('anon',p.oid,'EXECUTE')
      or has_function_privilege('authenticated',p.oid,'EXECUTE')
    );

  insert into _gov_test_result values
    (19,'T19 private Governance inaccessible; read wrappers are API-only bridge',
     case when bad_table=0 and bad_fn=0
       and has_function_privilege('authenticated',
           's2t_fhir_api._governance_read_allowed()'::regprocedure,'EXECUTE')
       and has_function_privilege('authenticated',
           's2t_fhir_api._governance_replay_state(uuid)'::regprocedure,'EXECUTE')
       and has_function_privilege('authenticated',
           's2t_fhir_api._governance_question_timing(uuid)'::regprocedure,'EXECUTE')
       and not has_function_privilege('anon',
           's2t_fhir_api._governance_read_allowed()'::regprocedure,'EXECUTE')
       and not has_function_privilege('anon',
           's2t_fhir_api._governance_replay_state(uuid)'::regprocedure,'EXECUTE')
       and not has_function_privilege('anon',
           's2t_fhir_api._governance_question_timing(uuid)'::regprocedure,'EXECUTE')
     then 'PASS' else 'FAIL' end,
     'bad_table='||bad_table||', bad_private_fn='||bad_fn);
end $$;

-- T20 resolver source is active-only + STRICT + TOO_MANY_ROWS handling
-- POSIX [[:space:]] is used intentionally for pg_get_functiondef() text matching.
do $$
declare d text; ok boolean;
begin
  select pg_get_functiondef(
    's2t_governance._resolve_mapping_identity(text,text,text)'::regprocedure
  ) into d;

  ok := d ~* 'into[[:space:]]+strict'
    and d ~* 'is_active_baseline[[:space:]]*=[[:space:]]*true'
    and d ~* 'too_many_rows';

  insert into _gov_test_result values
    (20,'T20 mapping resolver fails closed on 0 or >1 active matches',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T21 deterministic ordering definition + immutable recording_seq
-- POSIX [[:space:]] avoids backslash-escape ambiguity in PostgreSQL regex strings.
do $$
declare d text; ok boolean; col_ok boolean;
begin
  select pg_get_functiondef(
    's2t_governance._replay_state(uuid,boolean)'::regprocedure
  ) into d;

  select a.attidentity='a' and a.attnotnull
    into col_ok
  from pg_attribute a
  where a.attrelid='s2t_governance.governance_event'::regclass
    and a.attname='recording_seq'
    and a.attnum>0 and not a.attisdropped;

  ok := coalesce(col_ok,false)
    and d ~* 'order[[:space:]]+by[[:space:]]+ev[.]effective_at[[:space:]]*,[[:space:]]*ev[.]recording_seq';

  insert into _gov_test_result values
    (21,'T21 replay uses identity recording_seq as deterministic causal tie-breaker',
     case when ok then 'PASS' else 'FAIL' end,null);
end $$;

-- T22 governance_open_requests contains only genuinely open requests
do $$
declare bad int;
begin
  select count(*) into bad
  from s2t_fhir_api.governance_open_requests o
  where exists (
    select 1
    from s2t_fhir_api.governance_question_timeline f
    where f.question_id=o.question_id
      and f.related_request_event_id=o.request_event_id
      and f.event_type='RESPONSE_RECEIVED'
      and f.response_kind='FINAL'
      and not f.is_retracted
  );

  insert into _gov_test_result values
    (22,'T22 governance_open_requests excludes requests with live FINAL',
     case when bad=0 then 'PASS' else 'FAIL' end,'bad='||bad);
end $$;

-- T23 no resource-specific Governance branches
do $$
declare bad int;
begin
  select count(*) into bad
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and p.proname like 'gov\\_%')
    )
    and p.prosrc ~* '(medication-request-cato|MedicationRequest|CATO|_lovable_mapping_node)';

  insert into _gov_test_result values
    (23,'T23 no resource-specific Governance branches',
     case when bad=0 then 'PASS' else 'FAIL' end,'bad='||bad);
end $$;

-- T24 no mapping/Baseline/review writes
do $$
declare bad int;
begin
  select count(*) into bad
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where (
      n.nspname='s2t_governance'
      or (n.nspname='s2t_fhir_api' and p.proname like 'gov\\_%')
    )
    and p.prosrc ~* '(insert\\s+into|update|delete\\s+from)\\s+s2t_fhir\\.';

  insert into _gov_test_result values
    (24,'T24 Governance functions do not write mapping/Baseline/review schemas',
     case when bad=0 then 'PASS' else 'FAIL' end,'bad='||bad);
end $$;

-- T25 narrow non-interference fingerprint
do $$
declare bad int;
begin
  with fp_after as (
    select 'active_mapping_record' k,
           md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.mapping_key), '')) v
    from s2t_fhir_api.active_mapping_record x
    union all
    select 'active_baseline',
           md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.source_system, x.fhir_resource, x.baseline_code), ''))
    from s2t_fhir_api.active_baseline x
    union all
    select 'review',
           md5(coalesce(string_agg(to_jsonb(x)::text, '' order by x.node_id), ''))
    from s2t_fhir_api.active_mapping_review_status x
  )
  select count(*) into bad
  from _fp_before b join fp_after a using(k)
  where a.v is distinct from b.v;

  insert into _gov_test_result values
    (25,'T25 mapping/Baseline/review fingerprints unchanged',
     case when bad=0 then 'PASS' else 'FAIL' end,'changed='||bad);
end $$;

-- Manual two-session concurrency checks still required after automated dry-run:
-- C1 HOLD_STARTED vs HOLD_STARTED on same question.
-- C2 DECISION_RECORDED vs DECISION_RECORDED on same question.
-- C3 FINAL response vs FINAL response on same request.
-- C4 request retraction vs FINAL response.
-- C5 MAPPING_UNLINKED vs MAPPING_UNLINKED.
-- C6 MAPPING_LINKED vs CLOSE on same question.
-- C7 REQUEST_SENT vs CLOSE on same question.
-- Expected in every case: second writer blocks on the per-question advisory lock, then
-- replays committed history and either fails 23514 or records the single valid successor.

select seq, test_name, result, details
from _gov_test_result
order by seq;

select
  999999 as seq,
  'AGGREGATE' as test_name,
  case when count(*) filter (where result='FAIL')=0 then 'ALL PASS' else 'FAIL' end as result,
  'pass='||count(*) filter (where result='PASS')||
  ', fail='||count(*) filter (where result='FAIL') as details
from _gov_test_result;


-- =====================================================================
-- PART C — Roll back candidate + synthetic test data
-- =====================================================================

rollback;

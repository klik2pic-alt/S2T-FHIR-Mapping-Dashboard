-- Migration 019
-- Require an active review session for authenticated human review actions.
--
-- Governance rule:
--   Authenticated Supabase reviewers must perform review actions within
--   an explicit review session.
--
-- Internal/service review through _record_mapping_review remains compatible
-- with NULL review_session_id.
--
-- Runtime evidence prior to migration:
--   - authenticated human review with NULL session succeeded
--   - internal service review with NULL session succeeded
--
-- Expected behavior after migration:
--   - authenticated human review + NULL session -> SQLSTATE 22023
--   - authenticated human review + valid open owned session -> succeeds
--   - internal/service review + NULL session -> remains supported

BEGIN;

CREATE OR REPLACE FUNCTION s2t_fhir_api.mark_authenticated_mapping_reviewed(
    p_node_id text,
    p_session_id uuid DEFAULT NULL::uuid,
    p_note text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 's2t_fhir_api'
AS $function$
DECLARE
    actor_id uuid;
BEGIN
    actor_id := s2t_fhir_api._require_authenticated_review_principal();

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION
            'review session is required for authenticated review actions'
            USING ERRCODE = '22023';
    END IF;

    PERFORM s2t_fhir_api._record_mapping_review_core(
        p_node_id,
        'REVIEWED',
        actor_id,
        p_session_id,
        p_note
    );
END
$function$;


CREATE OR REPLACE FUNCTION s2t_fhir_api.mark_authenticated_mapping_needs_follow_up(
    p_node_id text,
    p_session_id uuid DEFAULT NULL::uuid,
    p_note text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 's2t_fhir_api'
AS $function$
DECLARE
    actor_id uuid;
BEGIN
    actor_id := s2t_fhir_api._require_authenticated_review_principal();

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION
            'review session is required for authenticated review actions'
            USING ERRCODE = '22023';
    END IF;

    PERFORM s2t_fhir_api._record_mapping_review_core(
        p_node_id,
        'NEEDS_FOLLOW_UP',
        actor_id,
        p_session_id,
        p_note
    );
END
$function$;


CREATE OR REPLACE FUNCTION s2t_fhir_api.clear_authenticated_mapping_review(
    p_node_id text,
    p_session_id uuid DEFAULT NULL::uuid,
    p_note text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 's2t_fhir_api'
AS $function$
DECLARE
    actor_id uuid;
BEGIN
    actor_id := s2t_fhir_api._require_authenticated_review_principal();

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION
            'review session is required for authenticated review actions'
            USING ERRCODE = '22023';
    END IF;

    PERFORM s2t_fhir_api._record_mapping_review_core(
        p_node_id,
        'NOT_REVIEWED',
        actor_id,
        p_session_id,
        p_note
    );
END
$function$;

COMMIT;

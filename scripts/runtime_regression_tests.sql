-- ============================================================================
-- S2T FHIR Mapping Dashboard
-- Runtime Regression Test Suite
--
-- Scope:
--   S2T FHIR Mapping Review Governance
--   CATO -> MedicationRequest
--
-- Properties:
--   - Non-destructive
--   - Executes inside a transaction
--   - Ends with ROLLBACK
--   - Tests authenticated human review workflow
--   - Tests internal/service backward compatibility
--   - Tests event-chain integrity
--
-- Baseline established: 2026-09-27
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE runtime_test_results (
    test_id      text primary key,
    result       text not null,
    description  text not null,
    detail       text
) ON COMMIT DROP;

DO $test$
DECLARE
    reviewer_a_principal uuid :=
        '6637fe25-a71d-46f2-be18-32c994769ea4'::uuid;

    reviewer_a_auth uuid :=
        '11111111-1111-1111-1111-111111111111'::uuid;

    reviewer_b_auth uuid :=
        '22222222-2222-2222-2222-222222222222'::uuid;

    importer_principal uuid :=
        '2fb03b24-4795-4b19-bf54-b1359593e0d0'::uuid;

    reviewer_b_principal uuid;

    test_node_id text;
    test_mapping_record_id uuid;
    active_baseline_id uuid;

    session_a uuid;

    event_reviewed uuid;
    event_follow_up uuid;
    event_cleared uuid;

    resolved_principal uuid;
    current_status text;
    current_actor uuid;
    current_session uuid;
    current_supersedes uuid;

    n integer;
BEGIN

    -- ------------------------------------------------------------------------
    -- Resolve one valid node dynamically from the active governed baseline
    -- ------------------------------------------------------------------------

    SELECT
        ctx.baseline_version_id,
        n.node_id,
        mr.mapping_record_id
    INTO STRICT
        active_baseline_id,
        test_node_id,
        test_mapping_record_id
    FROM s2t_fhir_api._active_release_context ctx
    JOIN s2t_fhir_api._lovable_mapping_node n
      ON n.baseline_code = ctx.baseline_code
    JOIN s2t_fhir.logical_mapping_identity lmi
      ON lmi.logical_key = n.mapping_key
     AND lmi.source_system = ctx.source_system
     AND lmi.fhir_resource = ctx.fhir_resource
    JOIN s2t_fhir.mapping_record mr
      ON mr.baseline_version_id = ctx.baseline_version_id
     AND mr.logical_mapping_identity_id = lmi.logical_mapping_identity_id
    WHERE ctx.source_system = 'CATO'
      AND ctx.fhir_resource = 'MedicationRequest'
    ORDER BY n.node_id
    LIMIT 1;


    -- ========================================================================
    -- AUTHENTICATION / AUTHORIZATION
    -- ========================================================================

    -- AUTH-01: Missing Supabase identity must be rejected
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '', true);

    BEGIN
        PERFORM s2t_fhir_api._resolve_authenticated_principal();

        INSERT INTO runtime_test_results
        VALUES (
            'AUTH-01',
            'FAIL',
            'Missing authenticated Supabase identity is rejected',
            'Resolver unexpectedly succeeded'
        );

    EXCEPTION
        WHEN SQLSTATE '42501' THEN
            INSERT INTO runtime_test_results
            VALUES (
                'AUTH-01',
                'PASS',
                'Missing authenticated Supabase identity is rejected',
                SQLERRM
            );
    END;


    -- AUTH-02: Authenticated reviewer without active write grant must fail
    PERFORM set_config(
        'request.jwt.claim.sub',
        reviewer_a_auth::text,
        true
    );

    BEGIN
        PERFORM s2t_fhir_api._require_authenticated_review_principal();

        INSERT INTO runtime_test_results
        VALUES (
            'AUTH-02',
            'FAIL',
            'Authenticated reviewer without active S2T_REVIEW_WRITE is rejected',
            'Authorization guard unexpectedly succeeded'
        );

    EXCEPTION
        WHEN SQLSTATE '42501' THEN
            INSERT INTO runtime_test_results
            VALUES (
                'AUTH-02',
                'PASS',
                'Authenticated reviewer without active S2T_REVIEW_WRITE is rejected',
                SQLERRM
            );
    END;


    -- Create temporary active write grant
    PERFORM s2t_fhir.grant_review_write(
        reviewer_a_principal,
        importer_principal
    );


    -- AUTH-03: Active reviewer must resolve successfully
    resolved_principal :=
        s2t_fhir_api._require_authenticated_review_principal();

    IF resolved_principal = reviewer_a_principal THEN
        INSERT INTO runtime_test_results
        VALUES (
            'AUTH-03',
            'PASS',
            'Authenticated reviewer with active S2T_REVIEW_WRITE is accepted',
            resolved_principal::text
        );
    ELSE
        INSERT INTO runtime_test_results
        VALUES (
            'AUTH-03',
            'FAIL',
            'Authenticated reviewer with active S2T_REVIEW_WRITE is accepted',
            coalesce(resolved_principal::text, 'NULL')
        );
    END IF;


    -- ========================================================================
    -- SESSION
    -- ========================================================================

    session_a :=
        s2t_fhir_api.start_authenticated_mapping_review_session(
            'Automated runtime regression',
            'Regression suite session'
        );

    IF session_a IS NOT NULL THEN
        INSERT INTO runtime_test_results
        VALUES (
            'SESSION-01',
            'PASS',
            'Authenticated reviewer can open review session',
            session_a::text
        );
    ELSE
        INSERT INTO runtime_test_results
        VALUES (
            'SESSION-01',
            'FAIL',
            'Authenticated reviewer can open review session',
            'No session UUID returned'
        );
    END IF;


    -- ========================================================================
    -- GOVERNANCE
    -- ========================================================================

    -- GOV-01: Authenticated human review MUST require a session
    BEGIN
        PERFORM s2t_fhir_api.mark_authenticated_mapping_reviewed(
            test_node_id,
            NULL,
            'NULL session regression test'
        );

        INSERT INTO runtime_test_results
        VALUES (
            'GOV-01',
            'FAIL',
            'Authenticated human review without session is rejected',
            'Review unexpectedly succeeded'
        );

    EXCEPTION
        WHEN SQLSTATE '22023' THEN
            INSERT INTO runtime_test_results
            VALUES (
                'GOV-01',
                'PASS',
                'Authenticated human review without session is rejected',
                SQLERRM
            );
    END;


    -- ========================================================================
    -- REVIEW WORKFLOW
    -- ========================================================================

    -- REVIEW-01: REVIEWED
    PERFORM s2t_fhir_api.mark_authenticated_mapping_reviewed(
        test_node_id,
        session_a,
        'Regression suite - reviewed'
    );

    SELECT
        mapping_review_event_id,
        review_status,
        actor_principal_id,
        review_session_id,
        supersedes_event_id
    INTO
        event_reviewed,
        current_status,
        current_actor,
        current_session,
        current_supersedes
    FROM s2t_fhir.current_mapping_review
    WHERE baseline_version_id = active_baseline_id
      AND mapping_record_id = test_mapping_record_id;

    IF current_status = 'REVIEWED'
       AND current_actor = reviewer_a_principal
       AND current_session = session_a THEN

        INSERT INTO runtime_test_results
        VALUES (
            'REVIEW-01',
            'PASS',
            'REVIEWED event becomes current review state',
            event_reviewed::text
        );
    ELSE
        INSERT INTO runtime_test_results
        VALUES (
            'REVIEW-01',
            'FAIL',
            'REVIEWED event becomes current review state',
            'Current review projection did not match expected values'
        );
    END IF;


    -- REVIEW-02: NEEDS_FOLLOW_UP supersedes REVIEWED
    PERFORM s2t_fhir_api.mark_authenticated_mapping_needs_follow_up(
        test_node_id,
        session_a,
        'Regression suite - needs follow up'
    );

    SELECT
        mapping_review_event_id,
        review_status,
        supersedes_event_id
    INTO
        event_follow_up,
        current_status,
        current_supersedes
    FROM s2t_fhir.current_mapping_review
    WHERE baseline_version_id = active_baseline_id
      AND mapping_record_id = test_mapping_record_id;

    IF current_status = 'NEEDS_FOLLOW_UP'
       AND current_supersedes = event_reviewed THEN

        INSERT INTO runtime_test_results
        VALUES (
            'REVIEW-02',
            'PASS',
            'NEEDS_FOLLOW_UP supersedes REVIEWED',
            event_follow_up::text
        );
    ELSE
        INSERT INTO runtime_test_results
        VALUES (
            'REVIEW-02',
            'FAIL',
            'NEEDS_FOLLOW_UP supersedes REVIEWED',
            'Incorrect status or supersedes_event_id'
        );
    END IF;


    -- REVIEW-03: CLEAR -> NOT_REVIEWED
    PERFORM s2t_fhir_api.clear_authenticated_mapping_review(
        test_node_id,
        session_a,
        'Regression suite - cleared'
    );

    SELECT
        mapping_review_event_id,
        review_status,
        supersedes_event_id
    INTO
        event_cleared,
        current_status,
        current_supersedes
    FROM s2t_fhir.current_mapping_review
    WHERE baseline_version_id = active_baseline_id
      AND mapping_record_id = test_mapping_record_id;

    IF current_status = 'NOT_REVIEWED'
       AND current_supersedes = event_follow_up THEN

        INSERT INTO runtime_test_results
        VALUES (
            'REVIEW-03',
            'PASS',
            'Clear review creates NOT_REVIEWED event',
            event_cleared::text
        );
    ELSE
        INSERT INTO runtime_test_results
        VALUES (
            'REVIEW-03',
            'FAIL',
            'Clear review creates NOT_REVIEWED event',
            'Incorrect status or supersedes_event_id'
        );
    END IF;


    -- REVIEW-04: Blank note must be rejected
    BEGIN
        PERFORM s2t_fhir_api.mark_authenticated_mapping_reviewed(
            test_node_id,
            session_a,
            '   '
        );

        INSERT INTO runtime_test_results
        VALUES (
            'REVIEW-04',
            'FAIL',
            'Blank review note is rejected',
            'Blank note unexpectedly accepted'
        );

    EXCEPTION
        WHEN SQLSTATE '22023' THEN
            INSERT INTO runtime_test_results
            VALUES (
                'REVIEW-04',
                'PASS',
                'Blank review note is rejected',
                SQLERRM
            );
    END;


    -- ========================================================================
    -- SESSION LIFECYCLE
    -- ========================================================================

    PERFORM s2t_fhir_api.end_authenticated_mapping_review_session(
        session_a
    );

    INSERT INTO runtime_test_results
    VALUES (
        'SESSION-02',
        'PASS',
        'Owner can close open review session',
        session_a::text
    );


    -- SESSION-03: Double close must fail
    BEGIN
        PERFORM s2t_fhir_api.end_authenticated_mapping_review_session(
            session_a
        );

        INSERT INTO runtime_test_results
        VALUES (
            'SESSION-03',
            'FAIL',
            'Closed review session cannot be closed twice',
            'Second close unexpectedly succeeded'
        );

    EXCEPTION
        WHEN SQLSTATE 'P0002' THEN
            INSERT INTO runtime_test_results
            VALUES (
                'SESSION-03',
                'PASS',
                'Closed review session cannot be closed twice',
                SQLERRM
            );
    END;


    -- SESSION-04: Closed session cannot receive review actions
    BEGIN
        PERFORM s2t_fhir_api.mark_authenticated_mapping_reviewed(
            test_node_id,
            session_a,
            'Closed session reuse test'
        );

        INSERT INTO runtime_test_results
        VALUES (
            'SESSION-04',
            'FAIL',
            'Closed review session cannot be reused',
            'Review unexpectedly succeeded'
        );

    EXCEPTION
        WHEN SQLSTATE '23514' THEN
            INSERT INTO runtime_test_results
            VALUES (
                'SESSION-04',
                'PASS',
                'Closed review session cannot be reused',
                SQLERRM
            );
    END;


    -- ========================================================================
    -- SESSION OWNERSHIP
    -- ========================================================================

    reviewer_b_principal :=
        s2t_fhir.provision_authenticated_principal(
            reviewer_b_auth,
            'Runtime Regression Reviewer B',
            importer_principal
        );

    PERFORM s2t_fhir.grant_review_write(
        reviewer_b_principal,
        importer_principal
    );

    -- Switch back to Actor A and create another session
    PERFORM set_config(
        'request.jwt.claim.sub',
        reviewer_a_auth::text,
        true
    );

    session_a :=
        s2t_fhir_api.start_authenticated_mapping_review_session(
            'Ownership regression test',
            'Owned by reviewer A'
        );

    -- Switch to Actor B
    PERFORM set_config(
        'request.jwt.claim.sub',
        reviewer_b_auth::text,
        true
    );

    resolved_principal :=
        s2t_fhir_api._require_authenticated_review_principal();

    BEGIN
        PERFORM s2t_fhir_api.end_authenticated_mapping_review_session(
            session_a
        );

        INSERT INTO runtime_test_results
        VALUES (
            'SESSION-05',
            'FAIL',
            'Reviewer cannot close another reviewer session',
            'Cross-actor close unexpectedly succeeded'
        );

    EXCEPTION
        WHEN SQLSTATE 'P0002' THEN
            INSERT INTO runtime_test_results
            VALUES (
                'SESSION-05',
                'PASS',
                'Reviewer cannot close another reviewer session',
                SQLERRM
            );
    END;


    -- ========================================================================
    -- INTERNAL / SERVICE BACKWARD COMPATIBILITY
    -- ========================================================================

    PERFORM s2t_fhir_api._record_mapping_review(
        test_node_id,
        'REVIEWED',
        importer_principal,
        NULL,
        'Internal service NULL-session compatibility test'
    );

    SELECT
        review_status,
        actor_principal_id,
        review_session_id
    INTO
        current_status,
        current_actor,
        current_session
    FROM s2t_fhir.current_mapping_review
    WHERE baseline_version_id = active_baseline_id
      AND mapping_record_id = test_mapping_record_id;

    IF current_status = 'REVIEWED'
       AND current_actor = importer_principal
       AND current_session IS NULL THEN

        INSERT INTO runtime_test_results
        VALUES (
            'GOV-02',
            'PASS',
            'Internal service review remains compatible with NULL session',
            importer_principal::text
        );
    ELSE
        INSERT INTO runtime_test_results
        VALUES (
            'GOV-02',
            'FAIL',
            'Internal service review remains compatible with NULL session',
            'Unexpected current review projection'
        );
    END IF;


    -- ========================================================================
    -- DATA INTEGRITY
    -- ========================================================================

    SELECT count(*)
    INTO n
    FROM (
        SELECT
            baseline_version_id,
            mapping_record_id
        FROM s2t_fhir.current_mapping_review
        GROUP BY
            baseline_version_id,
            mapping_record_id
        HAVING count(*) > 1
    ) x;

    INSERT INTO runtime_test_results
    VALUES (
        'CHAIN-01',
        CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
        'At most one current review exists per baseline/mapping',
        'violations=' || n
    );


    SELECT count(*)
    INTO n
    FROM s2t_fhir.mapping_review_event child
    JOIN s2t_fhir.mapping_review_event parent
      ON parent.mapping_review_event_id = child.supersedes_event_id
    WHERE child.mapping_record_id <> parent.mapping_record_id;

    INSERT INTO runtime_test_results
    VALUES (
        'CHAIN-02',
        CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
        'Supersedes chain never crosses mapping records',
        'violations=' || n
    );


    SELECT count(*)
    INTO n
    FROM s2t_fhir.mapping_review_event child
    JOIN s2t_fhir.mapping_review_event parent
      ON parent.mapping_review_event_id = child.supersedes_event_id
    WHERE child.baseline_version_id <> parent.baseline_version_id;

    INSERT INTO runtime_test_results
    VALUES (
        'CHAIN-03',
        CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
        'Supersedes chain never crosses baseline versions',
        'violations=' || n
    );


    WITH RECURSIVE review_chain AS (
        SELECT
            e.mapping_review_event_id AS start_event_id,
            e.mapping_review_event_id AS current_event_id,
            e.supersedes_event_id,
            ARRAY[e.mapping_review_event_id]::uuid[] AS visited,
            false AS has_cycle
        FROM s2t_fhir.mapping_review_event e

        UNION ALL

        SELECT
            rc.start_event_id,
            parent.mapping_review_event_id,
            parent.supersedes_event_id,
            rc.visited || parent.mapping_review_event_id,
            parent.mapping_review_event_id = ANY(rc.visited)
        FROM review_chain rc
        JOIN s2t_fhir.mapping_review_event parent
          ON parent.mapping_review_event_id = rc.supersedes_event_id
        WHERE NOT rc.has_cycle
    )
    SELECT count(DISTINCT start_event_id)
    INTO n
    FROM review_chain
    WHERE has_cycle;

    INSERT INTO runtime_test_results
    VALUES (
        'CHAIN-04',
        CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
        'Review event chain contains no cycles',
        'cycles=' || n
    );


    SELECT count(*)
    INTO n
    FROM (
        SELECT supersedes_event_id
        FROM s2t_fhir.mapping_review_event
        WHERE supersedes_event_id IS NOT NULL
        GROUP BY supersedes_event_id
        HAVING count(*) > 1
    ) branch;

    INSERT INTO runtime_test_results
    VALUES (
        'CHAIN-05',
        CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
        'Review event chain contains no branching',
        'branch_points=' || n
    );


    SELECT count(*)
    INTO n
    FROM pg_indexes
    WHERE schemaname = 's2t_fhir'
      AND tablename = 'mapping_review_event'
      AND indexname = 'mapping_review_event_superseded_once_uq'
      AND indexdef ILIKE '%UNIQUE%'
      AND indexdef ILIKE '%supersedes_event_id%';

    INSERT INTO runtime_test_results
    VALUES (
        'CHAIN-06',
        CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END,
        'Database enforces single successor for superseded event',
        'matching_unique_indexes=' || n
    );

END
$test$;


-- ============================================================================
-- RESULTS
-- ============================================================================

SELECT
    test_id,
    result,
    description,
    detail
FROM runtime_test_results
ORDER BY test_id;


-- Overall result
SELECT
    CASE
        WHEN count(*) FILTER (WHERE result = 'FAIL') = 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS overall_result,
    count(*) FILTER (WHERE result = 'PASS') AS passed,
    count(*) FILTER (WHERE result = 'FAIL') AS failed,
    count(*) AS total
FROM runtime_test_results;


-- IMPORTANT:
-- All test data created above is temporary and must not persist.
ROLLBACK;
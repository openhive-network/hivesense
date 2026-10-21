-- HAF early block processing: hivesense_app is delivered blocks while hived
-- replays with psql-massive-index-policy = keep-monotonic, needs none of the
-- core indexes HAF defers to the end of the replay, and does not finalize its
-- massive sync (build the HNSW index) before HAF's own massive sync ends.
-- Run as haf_admin against an installed database:
--   psql ... -v ON_ERROR_STOP=on -f tests/test_early_block_processing.sql
-- The replay state is HAF's own: the deferred indexes and the foreign keys are
-- dropped inside a transaction that is rolled back.
DO $$
DECLARE
    __offenders TEXT;
BEGIN
    ASSERT (SELECT early_block_processing FROM hafd.contexts WHERE name = 'hivesense_app'),
        'hivesense_app did not opt into early block processing';

    -- Block processing must not read a table whose core indexes a keep-monotonic
    -- replay defers (trx_hash, producer, account_operations, operation body
    -- expressions): add a hive.wait_for_core_indexes call before such a step
    -- and exempt it here.
    SELECT string_agg(p.oid::regprocedure::TEXT, ', ') INTO __offenders
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'hivesense_app'
      AND p.prosrc ~* '(account_operations|operations_view|hafd\.operations|transactions_view|hafd\.transactions|trx_hash|producer_account_id)';
    ASSERT __offenders IS NULL, format('hivesense_app functions read tables with deferred core indexes: %s', __offenders);
END
$$;

-- hived replays, the irreversible head so far at block 100. The head is
-- pinned without the block row its foreign key wants (the test database may
-- hold no blocks), hence replica mode for the rolled-back update.
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE hafd.hive_state SET consistent_block = 100;
SET LOCAL session_replication_role = origin;
SELECT hive.disable_fk_of_irreversible();
SELECT hive.disable_indexes_of_irreversible('keep-monotonic');
DO $$
BEGIN
    ASSERT NOT hive.is_instance_ready(), 'deferred indexes are missing, the instance must not be ready';
    ASSERT hive.is_instance_ready_for_block_processing(), 'kept indexes exist, block processing must be possible';
    -- the readiness hive.app_next_iteration delivers blocks on
    ASSERT hive.is_instance_ready_for_contexts(ARRAY['hivesense_app']::hive.contexts_group),
        'hivesense_app is not delivered blocks while hived replays';
    ASSERT NOT hivesense_app.massive_sync_finished('hivesense_app', 100),
        'hivesense_app would finalize its massive sync while hived replays';

    -- without the opt-in a context keeps waiting for the full index restore
    PERFORM hive.app_context_set_early_block_processing(ARRAY['hivesense_app']::hive.contexts_group, FALSE);
    ASSERT NOT hive.is_instance_ready_for_contexts(ARRAY['hivesense_app']::hive.contexts_group),
        'a context that did not opt in is delivered blocks while hived replays';
END
$$;
ROLLBACK;

-- a ready instance: finalize on reaching HAF's irreversible head, not before
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE hafd.hive_state SET consistent_block = 100;
SET LOCAL session_replication_role = origin;
DO $$
BEGIN
    ASSERT (SELECT early_block_processing FROM hafd.contexts WHERE name = 'hivesense_app'),
        'the rollback did not restore the opt-in';
    ASSERT hive.is_instance_ready(), 'the rollback did not restore the indexes';
    ASSERT hivesense_app.massive_sync_finished('hivesense_app', 100),
        'hivesense_app does not finalize its massive sync on reaching the head of a ready instance';
    ASSERT NOT hivesense_app.massive_sync_finished('hivesense_app', 99),
        'hivesense_app finalizes its massive sync before reaching the head';
    RAISE NOTICE 'test_early_block_processing: PASS';
END
$$;
ROLLBACK;

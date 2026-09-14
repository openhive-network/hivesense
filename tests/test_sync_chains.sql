-- /sync-chains ordering: the primary chain first, then hivesense_app.sync_chains
-- rows by priority. Run against an installed database:
--   psql ... -v ON_ERROR_STOP=on -f tests/test_sync_chains.sql
SET ROLE hivesense_owner;
-- the endpoints resolve hivesense_app_status through PostgREST's extra search path
SET search_path TO hivesense_app, public;
BEGIN;
DELETE FROM hivesense_app.sync_chains;  -- rolled back below
INSERT INTO hivesense_app.sync_chains (sync_uuid, priority, base_url, llm, embedding_dimensionality,
    tokens_per_chunk, overlap_amount, min_token_threshold)
VALUES ('00000000-0000-0000-0000-00000000000b', 20, 'https://b.example/hivesense-api', 'model-b', 4, 512, 0.15, 75),
       ('00000000-0000-0000-0000-00000000000a', 10, NULL, 'model-a', 4, 512, 0.15, 75);
DO $$
DECLARE
    __uuids TEXT[];
    __primary TEXT := (SELECT sync_uuid::TEXT FROM hivesense_app.hivesense_app_status WHERE id = 1);
BEGIN
    SELECT array_agg(sync_uuid) INTO __uuids FROM hivesense_endpoints.get_sync_chains();
    ASSERT __uuids[1] = __primary, format('primary chain first: %s', __uuids);
    ASSERT __uuids[2] = '00000000-0000-0000-0000-00000000000a', format('priority order: %s', __uuids);
    ASSERT __uuids[3] = '00000000-0000-0000-0000-00000000000b', format('priority order: %s', __uuids);
    ASSERT (SELECT base_url FROM hivesense_endpoints.get_sync_chains() OFFSET 2 LIMIT 1) = 'https://b.example/hivesense-api';
    ASSERT (SELECT base_url FROM hivesense_endpoints.get_sync_chains() LIMIT 1) IS NULL;
    ASSERT (SELECT sync_uuid FROM hivesense_endpoints.get_sync_settings()) = __primary;
    RAISE NOTICE 'test_sync_chains: PASS';
END
$$;
ROLLBACK;
RESET ROLE;

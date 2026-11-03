-- Posts hivemind deletes (counter_deleted > 0, block_num moved to the deleting
-- block) lose their vectors in block processing and in the one-time purge
-- (hivesense_app.purge_deleted_post_vectors). Run as haf_admin against an
-- installed database whose block processor has minted its sync identity:
--   psql ... -v ON_ERROR_STOP=on -f tests/test_deleted_posts.sql
-- Everything, including the seeded hivemind rows, is rolled back. No embedding
-- server is needed: the posts processed here are deleted, so none is embedded.
BEGIN;

-- Written outside hivemind's block processing: none of its table triggers
-- (HAF fork bookkeeping, deferred foreign keys) may fire on these rows.
SET LOCAL session_replication_role = replica;

INSERT INTO hivemind_app.hive_accounts (id, name, created_at) VALUES
(9201, 'aidev-deleter', '2026-01-01 00:00:00'),
(9202, 'aidev-regretter', '2026-01-01 00:00:00'),
(9203, 'aidev-purged', '2026-01-01 00:00:00'),
(9204, 'aidev-keeper', '2026-01-01 00:00:00');

INSERT INTO hivemind_app.hive_permlink_data (id, permlink) VALUES
(900201, 'deleted-after-embedding'),
(900202, 'deleted-before-processing'),
(900203, 'deleted-long-ago'),
(900204, 'deleted-long-ago-too'),
(900205, 'still-alive');

-- 900201: embedded at block 99000000, deleted at 99000001
-- 900202: created and deleted at 99000001, before the node processed the block
-- 900203, 900204: embedded, deleted in a block processed before deletions were
--                 handled (the purge's job); 900205: live and embedded
INSERT INTO hivemind_app.hive_posts (
    id, root_id, parent_id, author_id, permlink_id, category_id, created_at, depth, block_num, block_num_created, counter_deleted
) VALUES
(900201, 900201, 0, 9201, 900201, 0, '2026-01-01 00:00:00', 0, 99000000, 99000000, 0),
(900202, 900202, 0, 9202, 900202, 0, '2026-01-01 00:00:03', 0, 99000001, 99000001, 1),
(900203, 900203, 0, 9203, 900203, 0, '2026-01-01 00:00:00', 0, 98000001, 98000000, 1),
(900204, 900204, 0, 9203, 900204, 0, '2026-01-01 00:00:00', 0, 98000001, 98000000, 1),
(900205, 900205, 0, 9204, 900205, 0, '2026-01-01 00:00:00', 0, 98000000, 98000000, 0);

INSERT INTO hivemind_app.hive_post_data (id, title, body, json)
SELECT
    id,
    'title' AS title,
    'A body that is never sent to the embedding server.' AS body,
    '{}' AS json_metadata
FROM generate_series(900201, 900205) AS id;

-- hivesense's own writes run as in production: posts_vectors_reduced follows
-- posts_vectors by an ON DELETE CASCADE foreign key, a trigger the replica
-- role would skip
SET LOCAL session_replication_role = origin;

INSERT INTO hivesense_app.post_data (post_id, number_of_tokens, last_vectors_block) VALUES
(900201, 300, 99000000),
(900203, 300, 98000000),
(900204, 300, 98000000),
(900205, 300, 98000000);

-- chunk 0 of each embedded post, with a fresh sync_seq per post (newest last)
CREATE TEMP TABLE tmp_test_dims ON COMMIT DROP AS
SELECT a.atttypmod AS dims
FROM pg_attribute AS a
WHERE a.attrelid = 'hivesense_app.posts_vectors'::REGCLASS AND a.attname = 'embedding';

INSERT INTO hivesense_app.posts_vectors (post_id, chunk_number, embedding, sync_seq)
SELECT
    p.post_id,
    0 AS chunk_number,
    array_fill(0.5::REAL, ARRAY[(SELECT d.dims FROM tmp_test_dims AS d)])::PUBLIC.VECTOR AS embedding,
    nextval('hivesense_app.sync_seq') AS sync_seq
FROM (VALUES (900205), (900201), (900203), (900204)) AS p (post_id);

DO $$
DECLARE
    __reduced_dims INT;
BEGIN
    IF to_regclass('hivesense_app.posts_vectors_reduced') IS NOT NULL THEN
        SELECT a.atttypmod INTO __reduced_dims
          FROM pg_attribute a
         WHERE a.attrelid = 'hivesense_app.posts_vectors_reduced'::regclass AND a.attname = 'reduced_embedding';
        INSERT INTO hivesense_app.posts_vectors_reduced (post_id, chunk_number, reduced_embedding)
        SELECT pv.post_id, 0, array_fill(0.5::REAL, ARRAY[__reduced_dims])::public.vector
          FROM hivesense_app.posts_vectors pv
         WHERE pv.post_id BETWEEN 900201 AND 900205;
    END IF;
END
$$;

-- block processing of block 99000001, as scripts/hivesense_block_processor.py
-- runs it (posts_in_range -> prepare_post_chunks -> embed -> store)
SAVEPOINT block_processing;
DO $$
DECLARE
    __ids       INT[];
    __chunks    INT;
    __seq_before INT := (SELECT MAX(sync_seq) FROM hivesense_app.posts_vectors);
    __uuid      TEXT := (SELECT sync_uuid::TEXT FROM hivesense_app.hivesense_app_status WHERE id = 1);
    __op        RECORD;
BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE hivemind_app.hive_posts SET counter_deleted = 1, block_num = 99000001 WHERE id = 900201;
    SET LOCAL session_replication_role = origin;

    __ids := hivesense_app.posts_in_range(99000001, 99000001);
    ASSERT __ids = ARRAY[900201, 900202], format('posts_in_range(99000001, 99000001) = %s', __ids);

    SELECT COUNT(*) INTO __chunks FROM hivesense_app.prepare_post_chunks(__ids);
    ASSERT __chunks = 0, format('prepare_post_chunks returned %s chunk(s) of deleted posts', __chunks);

    CREATE TEMP TABLE tmp_vectors (post_id INT, chunk_number INT, vec PUBLIC.VECTOR) ON COMMIT DROP;
    PERFORM * FROM hivesense_app.store_post_embeddings();

    ASSERT NOT EXISTS (SELECT 1 FROM hivesense_app.posts_vectors WHERE post_id = 900201),
        'vectors of the deleted post survived block processing';
    IF to_regclass('hivesense_app.posts_vectors_reduced') IS NOT NULL THEN
        ASSERT NOT EXISTS (SELECT 1 FROM hivesense_app.posts_vectors_reduced WHERE post_id = 900201),
            'reduced vectors of the deleted post survived block processing';
    END IF;
    ASSERT (SELECT COUNT(*) FROM hivesense_app.deleted_embeddings WHERE post_id = 900201 AND sync_seq > __seq_before) = 1,
        'no single fresh tombstone for the deleted post';
    ASSERT NOT EXISTS (SELECT 1 FROM hivesense_app.deleted_embeddings WHERE post_id = 900202),
        'tombstone written for a post deleted before it was ever embedded';
    ASSERT EXISTS (SELECT 1 FROM hivesense_app.posts_vectors WHERE post_id = 900205),
        'block processing of deleted posts touched a live post';

    PERFORM hivesense_app.publish_visible_sync_seq();
    SELECT u.* INTO __op FROM hivesense_endpoints.embedding_updates(__seq_before, 100, __uuid) AS u;
    ASSERT __op.op = 'delete' AND __op.author = 'aidev-deleter' AND __op.permlink = 'deleted-after-embedding' AND __op.post_deleted,
        format('embedding_updates after the deletion: %s', __op);
    RAISE NOTICE 'test_deleted_posts block processing: PASS';
END
$$;
ROLLBACK TO SAVEPOINT block_processing;

-- the one-time purge on a chain primary: one tombstone per purged post
SAVEPOINT purge_primary;
DO $$
DECLARE
    __seq_before INT := (SELECT MAX(sync_seq) FROM hivesense_app.posts_vectors);
    __tombstones BIGINT;
    __purged     INT;
BEGIN
    UPDATE hivesense_app.hivesense_app_status SET syncing_embeddings = FALSE, deleted_posts_purged = FALSE WHERE id = 1;
    -- 900201 too, deleted here outside any processed range
    SET LOCAL session_replication_role = replica;
    UPDATE hivemind_app.hive_posts SET counter_deleted = 1 WHERE id = 900201;
    SET LOCAL session_replication_role = origin;

    -- batch size 2 makes the three dead posts take two batches
    __purged := hivesense_app.purge_deleted_post_vectors(2);
    ASSERT __purged >= 3, format('first purge reported %s posts', __purged);
    ASSERT NOT EXISTS (
        SELECT 1 FROM hivesense_app.posts_vectors pv JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
         WHERE hp.counter_deleted > 0
    ), 'vectors of deleted posts survived the purge';
    ASSERT EXISTS (SELECT 1 FROM hivesense_app.posts_vectors WHERE post_id = 900205), 'the purge removed a live post''s vectors';
    ASSERT (
        SELECT COUNT(*) FROM hivesense_app.deleted_embeddings
         WHERE post_id IN (900201, 900203, 900204) AND sync_seq > __seq_before
    ) = 3, 'the purge did not write one fresh tombstone per purged post';
    ASSERT (SELECT deleted_posts_purged FROM hivesense_app.hivesense_app_status WHERE id = 1), 'purge marker not set';

    SELECT COUNT(*) INTO __tombstones FROM hivesense_app.deleted_embeddings;
    __purged := hivesense_app.purge_deleted_post_vectors(2);
    ASSERT __purged = 0, format('second purge reported %s posts', __purged);
    ASSERT (SELECT COUNT(*) FROM hivesense_app.deleted_embeddings) = __tombstones, 'second purge wrote tombstones';
    RAISE NOTICE 'test_deleted_posts purge on a primary: PASS';
END
$$;
ROLLBACK TO SAVEPOINT purge_primary;

-- the purge on a replica: no tombstones, and the syncer's cursor (the
-- get_last_seq() query of scripts/sync_embeddings.py) does not move although
-- the newest vectors (900204's) go
SAVEPOINT purge_replica;
CREATE FUNCTION pg_temp.syncer_cursor() RETURNS INT LANGUAGE sql AS $$
    SELECT GREATEST(
        COALESCE(MAX(t.sync_seq), 0),
        COALESCE((SELECT s.max_visible_sync_seq FROM hivesense_app.hivesense_app_status AS s WHERE s.id = 1), 0)
    ) FROM (
        SELECT MAX(pv.sync_seq) AS sync_seq FROM hivesense_app.posts_vectors AS pv
        UNION ALL
        SELECT MAX(de.sync_seq) FROM hivesense_app.deleted_embeddings AS de
    ) AS t
$$;
DO $$
DECLARE
    __cursor     INT;
    __tombstones BIGINT := (SELECT COUNT(*) FROM hivesense_app.deleted_embeddings);
    __purged     INT;
BEGIN
    UPDATE hivesense_app.hivesense_app_status SET syncing_embeddings = NULL, deleted_posts_purged = FALSE WHERE id = 1;
    __cursor := pg_temp.syncer_cursor();
    ASSERT __cursor = (SELECT sync_seq FROM hivesense_app.posts_vectors WHERE post_id = 900204),
        'test setup: the newest vectors are not the dead post''s';

    __purged := hivesense_app.purge_deleted_post_vectors(2);
    ASSERT __purged >= 2, format('replica purge reported %s posts', __purged);
    ASSERT NOT EXISTS (SELECT 1 FROM hivesense_app.posts_vectors WHERE post_id IN (900203, 900204)),
        'vectors of deleted posts survived the replica purge';
    ASSERT (SELECT COUNT(*) FROM hivesense_app.deleted_embeddings) = __tombstones, 'a replica purge wrote tombstones';
    ASSERT pg_temp.syncer_cursor() = __cursor, format('replica purge moved the syncer cursor from %s to %s', __cursor, pg_temp.syncer_cursor());

    ASSERT hivesense_app.purge_deleted_post_vectors(2) = 0, 'second replica purge did something';
    ASSERT pg_temp.syncer_cursor() = __cursor, 'second replica purge moved the syncer cursor';
    RAISE NOTICE 'test_deleted_posts purge on a replica: PASS';
END
$$;
ROLLBACK TO SAVEPOINT purge_replica;

ROLLBACK;

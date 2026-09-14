-- noqa: disable=CP03
SET ROLE hivesense_owner;

/*
 * Rebase an old embedding chain onto this node.
 *
 * Downstream nodes follow our /embedding-updates stream by sync_uuid; a
 * regeneration (new splitter, same model) would mint a new uuid and force
 * every downstream to wipe and re-download. Instead: freeze the old stack and
 * this one at the same block, dump the old chain's tables, load them here,
 * diff them against our freshly generated embeddings, and build a merged
 * table set -- old rows (old sync_seq) for posts whose embeddings are the
 * same, our rows with sync_seq after the old tail for posts that differ,
 * delete markers for posts that vanished. Swap the merged tables in, take
 * over the old uuid and tail seq, unfreeze. Downstreams see one batch of
 * edits and continue; the old chain's full history is preserved.
 *
 * Step order (each a separate psql call, see docs/sync_chain_rebase.md and
 * scripts/legacy_chain/):
 *   rebase_create_staging()   -> load_old_chain.sh COPYs the dump in
 *   rebase_set_old_status(...)
 *   rebase_resolve(freeze_block)      report hivemind divergence, stop if any
 *   rebase_diff([max_cos_distance])   report merge-set sizes + distance histogram
 *   rebase_build_tables()
 *   rebase_build_indexes()            the long one (HNSW)
 *   rebase_swap()                     block processing must be stopped
 *   rebase_verify()
 *   rebase_cleanup()                  days later
 *
 * Run as hivesense_owner (SET ROLE hivesense_owner from haf_admin).
 */

-- Progress of the current rebase (one row); exists permanently so the
-- functions below can be compiled at install time.
CREATE TABLE IF NOT EXISTS hivesense_app.legacy_rebase_state (
    id           INT PRIMARY KEY CHECK (id = 1),
    old_uuid     UUID,
    old_tail_seq INT,
    old_skipped  INT,
    old_block    INT,
    freeze_block INT,
    merge_count  INT,
    phase        TEXT,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 0. staging tables filled by scripts/legacy_chain/load_old_chain.sh
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION hivesense_app.rebase_create_staging()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
BEGIN
    DROP TABLE IF EXISTS legacy_vectors_raw, legacy_deleted_raw,
                         legacy_post_data_raw, legacy_root_posts_raw;
    CREATE TABLE legacy_vectors_raw (
        author       TEXT NOT NULL,
        permlink     TEXT NOT NULL,
        chunk_number INT  NOT NULL,
        embedding    TEXT NOT NULL,   -- pgvector text form '[...]', cast in rebase_resolve
        sync_seq     INT  NOT NULL
    );
    CREATE TABLE legacy_deleted_raw (
        author   TEXT NOT NULL,
        permlink TEXT NOT NULL,
        sync_seq INT  NOT NULL
    );
    CREATE TABLE legacy_post_data_raw (
        author             TEXT NOT NULL,
        permlink           TEXT NOT NULL,
        number_of_tokens   INT  NOT NULL,
        last_vectors_block INT  NOT NULL
    );
    -- every live root post of the OLD hivemind (consistency check only)
    CREATE TABLE legacy_root_posts_raw (
        author   TEXT NOT NULL,
        permlink TEXT NOT NULL
    );
    DELETE FROM legacy_rebase_state;
    INSERT INTO legacy_rebase_state (id, phase) VALUES (1, 'staging');
END;
$$;

-- Old chain identity, from old_status.txt of the dump: the old sync_uuid, its
-- max_visible_sync_seq (the tail every downstream has reached), its advertised
-- skipped-op count (our stream inherits that incompleteness) and the block the
-- old block processor stopped at.
CREATE OR REPLACE FUNCTION hivesense_app.rebase_set_old_status(
    _old_uuid     UUID,
    _old_tail_seq INT,
    _old_skipped  INT,
    _old_block    INT
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
BEGIN
    UPDATE legacy_rebase_state
       SET old_uuid = _old_uuid, old_tail_seq = _old_tail_seq,
           old_skipped = _old_skipped, old_block = _old_block, updated_at = now()
     WHERE id = 1;
END;
$$;

CREATE OR REPLACE FUNCTION hivesense_app.rebase_phase_is(_expected TEXT)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = hivesense_app, public
AS $$
DECLARE
    __phase TEXT;
BEGIN
    SELECT phase INTO __phase FROM legacy_rebase_state WHERE id = 1;
    IF __phase IS DISTINCT FROM _expected THEN
        RAISE EXCEPTION 'rebase step out of order: state is % but this step expects %', COALESCE(__phase, '<none>'), _expected;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION hivesense_app.rebase_set_phase(_phase TEXT)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
BEGIN
    UPDATE legacy_rebase_state SET phase = _phase, updated_at = now() WHERE id = 1;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 1. resolve (author, permlink) -> post_id on THIS hivemind, and report how
--    far the two hivemind databases disagree about which posts exist
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION hivesense_app.rebase_resolve(_freeze_block INT)
RETURNS TABLE (metric TEXT, value BIGINT)
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    __vec_type TEXT;
BEGIN
    PERFORM rebase_phase_is('staging');
    UPDATE legacy_rebase_state SET freeze_block = _freeze_block WHERE id = 1;

    -- one row per distinct name across all staging tables; a name can match
    -- several hive_posts rows (deleted-then-recreated permlinks keep the old
    -- row with counter_deleted > 0) -- prefer the live one, then the newest
    DROP TABLE IF EXISTS legacy_posts, legacy_unresolved;
    CREATE TABLE legacy_posts AS
    WITH names AS (
        SELECT author, permlink FROM legacy_vectors_raw
        UNION
        SELECT author, permlink FROM legacy_deleted_raw
        UNION
        SELECT author, permlink FROM legacy_post_data_raw
        UNION
        SELECT author, permlink FROM legacy_root_posts_raw
    ),
    resolved AS (
        SELECT DISTINCT ON (n.author, n.permlink)
               n.author, n.permlink, hp.id AS post_id
          FROM names n
          JOIN hivemind_app.hive_accounts      ha  ON ha.name = n.author
          JOIN hivemind_app.hive_permlink_data hpd ON hpd.permlink = n.permlink
          JOIN hivemind_app.hive_posts         hp  ON hp.author_id = ha.id AND hp.permlink_id = hpd.id
         ORDER BY n.author, n.permlink, (hp.counter_deleted = 0) DESC, hp.id DESC
    )
    SELECT n.author, n.permlink, r.post_id
      FROM names n
      LEFT JOIN resolved r USING (author, permlink);
    CREATE UNIQUE INDEX ON legacy_posts (author, permlink);
    CREATE INDEX ON legacy_posts (post_id);

    CREATE TABLE legacy_unresolved AS
    SELECT lp.author, lp.permlink,
           EXISTS (SELECT 1 FROM legacy_vectors_raw r WHERE r.author = lp.author AND r.permlink = lp.permlink) AS had_vectors
      FROM legacy_posts lp
     WHERE lp.post_id IS NULL;

    -- typed copies keyed by post_id; embedding cast to the live column type
    __vec_type := CASE WHEN store_halfvec_embeddings()
                       THEN format('public.halfvec(%s)', embedding_dims())
                       ELSE format('public.vector(%s)', embedding_dims())
                  END;
    DROP TABLE IF EXISTS legacy_vectors, legacy_deleted, legacy_post_data;
    EXECUTE format($q$
        CREATE TABLE legacy_vectors (
            post_id      INT NOT NULL,
            chunk_number INT NOT NULL,
            embedding    %s  NOT NULL,
            sync_seq     INT NOT NULL,
            PRIMARY KEY (post_id, chunk_number)
        )$q$, __vec_type);
    EXECUTE format($q$
        INSERT INTO legacy_vectors (post_id, chunk_number, embedding, sync_seq)
        SELECT lp.post_id, r.chunk_number, r.embedding::%s, r.sync_seq
          FROM legacy_vectors_raw r
          JOIN legacy_posts lp USING (author, permlink)
         WHERE lp.post_id IS NOT NULL$q$, __vec_type);

    CREATE TABLE legacy_deleted (
        post_id  INT NOT NULL,
        sync_seq INT NOT NULL,
        PRIMARY KEY (post_id, sync_seq)
    );
    INSERT INTO legacy_deleted (post_id, sync_seq)
    SELECT lp.post_id, r.sync_seq
      FROM legacy_deleted_raw r
      JOIN legacy_posts lp USING (author, permlink)
     WHERE lp.post_id IS NOT NULL;

    CREATE TABLE legacy_post_data (
        post_id            INT PRIMARY KEY,
        number_of_tokens   INT NOT NULL,
        last_vectors_block INT NOT NULL
    );
    INSERT INTO legacy_post_data (post_id, number_of_tokens, last_vectors_block)
    SELECT lp.post_id, r.number_of_tokens, r.last_vectors_block
      FROM legacy_post_data_raw r
      JOIN legacy_posts lp USING (author, permlink)
     WHERE lp.post_id IS NOT NULL;

    PERFORM rebase_set_phase('resolved');

    RETURN QUERY
    SELECT 'old_vector_rows'::TEXT, count(*) FROM legacy_vectors_raw
    UNION ALL
    SELECT 'old_vector_rows_resolved', count(*) FROM legacy_vectors
    UNION ALL
    SELECT 'old_posts_with_vectors', count(DISTINCT (author, permlink)) FROM legacy_vectors_raw
    UNION ALL
    -- nonzero: posts the old node embedded that THIS hivemind does not have
    SELECT 'old_posts_with_vectors_unresolved', count(*) FROM legacy_unresolved WHERE had_vectors
    UNION ALL
    SELECT 'old_delete_markers_unresolved',
           count(*) FROM legacy_deleted_raw r
           JOIN legacy_posts lp USING (author, permlink) WHERE lp.post_id IS NULL
    UNION ALL
    SELECT 'old_root_posts', count(*) FROM legacy_root_posts_raw
    UNION ALL
    -- nonzero: live root posts of the old hivemind missing here
    SELECT 'old_root_posts_missing_here',
           count(*) FROM legacy_root_posts_raw r
           JOIN legacy_posts lp USING (author, permlink) WHERE lp.post_id IS NULL
    UNION ALL
    -- nonzero: root posts THIS hivemind has (created by the freeze block) that
    -- the old one did not list -- ops for them would hit old-hivemind
    -- downstreams as "missing post" (exit-mode syncers halt). NULL when the
    -- old root-post list was not dumped.
    SELECT 'new_root_posts_missing_in_old',
           CASE WHEN (SELECT count(*) FROM legacy_root_posts_raw) = 0 THEN NULL
                ELSE (
                    SELECT count(*)
                      FROM hivemind_app.hive_posts hp
                      JOIN hivemind_app.hive_accounts      ha  ON ha.id  = hp.author_id
                      JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
                     WHERE (hp.root_id = hp.id OR hp.root_id = 0)
                       AND hp.counter_deleted = 0
                       AND hp.block_num_created <= _freeze_block
                       AND NOT EXISTS (SELECT 1 FROM legacy_root_posts_raw r
                                        WHERE r.author = ha.name AND r.permlink = hpd.permlink)
                )
           END;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. diff: which posts must be re-sent on the old chain
-- ─────────────────────────────────────────────────────────────────────────
-- A post is unchanged when it has the same chunk numbers here as on the old
-- chain and every chunk pair is within _max_cos_distance (cosine): the model
-- is the same, so identical chunking gives near-identical vectors (halfvec
-- rounding and GPU batch nondeterminism keep pairs well below 1e-3), while a
-- different split moves at least one chunk far away. Inspect
-- legacy_diff_histogram to confirm the threshold sits in the gap.
CREATE OR REPLACE FUNCTION hivesense_app.rebase_diff(_max_cos_distance REAL DEFAULT 0.001)
RETURNS TABLE (reason TEXT, posts BIGINT)
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
BEGIN
    PERFORM rebase_phase_is('resolved');

    DROP TABLE IF EXISTS legacy_merge_set, legacy_diff_histogram;
    CREATE TABLE legacy_merge_set (
        post_id INT  PRIMARY KEY,
        reason  TEXT NOT NULL   -- gone | new | rechunked
    );

    CREATE TEMP TABLE tmp_old ON COMMIT DROP AS
    SELECT post_id, count(*) AS n FROM legacy_vectors GROUP BY post_id;
    CREATE TEMP TABLE tmp_new ON COMMIT DROP AS
    SELECT post_id, count(*) AS n FROM posts_vectors GROUP BY post_id;
    ALTER TABLE tmp_old ADD PRIMARY KEY (post_id);
    ALTER TABLE tmp_new ADD PRIMARY KEY (post_id);

    INSERT INTO legacy_merge_set (post_id, reason)
    SELECT o.post_id, 'gone' FROM tmp_old o
     WHERE NOT EXISTS (SELECT 1 FROM tmp_new n WHERE n.post_id = o.post_id);

    INSERT INTO legacy_merge_set (post_id, reason)
    SELECT n.post_id, 'new' FROM tmp_new n
     WHERE NOT EXISTS (SELECT 1 FROM tmp_old o WHERE o.post_id = n.post_id);

    INSERT INTO legacy_merge_set (post_id, reason)
    SELECT o.post_id, 'rechunked'
      FROM tmp_old o JOIN tmp_new n USING (post_id)
     WHERE o.n <> n.n;

    -- chunk-pair distances for posts with equal chunk counts
    CREATE TEMP TABLE tmp_pairs ON COMMIT DROP AS
    SELECT lv.post_id, lv.chunk_number,
           (lv.embedding OPERATOR(public.<=>) pv.embedding)::REAL AS dist   -- NULL = chunk number absent here
      FROM legacy_vectors lv
      JOIN tmp_old o USING (post_id)
      JOIN tmp_new n USING (post_id)
      LEFT JOIN posts_vectors pv ON pv.post_id = lv.post_id AND pv.chunk_number = lv.chunk_number
     WHERE o.n = n.n;

    INSERT INTO legacy_merge_set (post_id, reason)
    SELECT DISTINCT p.post_id, 'rechunked'
      FROM tmp_pairs p
     WHERE p.dist IS NULL OR p.dist > _max_cos_distance
    ON CONFLICT (post_id) DO NOTHING;

    CREATE TABLE legacy_diff_histogram AS
    SELECT CASE
             WHEN dist IS NULL  THEN '0 chunk missing'
             WHEN dist <= 1e-6  THEN '1 <= 1e-6'
             WHEN dist <= 1e-5  THEN '2 <= 1e-5'
             WHEN dist <= 1e-4  THEN '3 <= 1e-4'
             WHEN dist <= 1e-3  THEN '4 <= 1e-3'
             WHEN dist <= 1e-2  THEN '5 <= 1e-2'
             WHEN dist <= 1e-1  THEN '6 <= 1e-1'
             ELSE                    '7 > 1e-1'
           END AS bucket,
           count(*) AS chunk_pairs
      FROM tmp_pairs
     GROUP BY 1
     ORDER BY 1;

    PERFORM rebase_set_phase('diffed');

    RETURN QUERY
    SELECT m.reason, count(*) FROM legacy_merge_set m GROUP BY m.reason
    UNION ALL
    SELECT 'total', count(*) FROM legacy_merge_set
    UNION ALL
    SELECT 'unchanged', count(*) FROM tmp_old o
     WHERE NOT EXISTS (SELECT 1 FROM legacy_merge_set m WHERE m.post_id = o.post_id)
    ORDER BY 1;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. build the merged table set (no indexes yet)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION hivesense_app.rebase_build_tables()
RETURNS TABLE (metric TEXT, value BIGINT)
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    __st           legacy_rebase_state%ROWTYPE;
    __legacy_max   INT;
    __merge_count  INT;
BEGIN
    PERFORM rebase_phase_is('diffed');
    SELECT * INTO __st FROM legacy_rebase_state WHERE id = 1;
    IF __st.old_uuid IS NULL OR __st.old_tail_seq IS NULL THEN
        RAISE EXCEPTION 'old chain identity not set: call rebase_set_old_status() first';
    END IF;
    IF use_reduced_embeddings() AND reduction_mode() <> 'slice' THEN
        RAISE EXCEPTION 'rebase does not support reduction_mode=pca (posts_vectors_reduced would need rebuilding)';
    END IF;

    SELECT GREATEST(COALESCE((SELECT max(sync_seq) FROM legacy_vectors), 0),
                    COALESCE((SELECT max(sync_seq) FROM legacy_deleted), 0))
      INTO __legacy_max;
    IF __st.old_tail_seq < __legacy_max THEN
        RAISE EXCEPTION 'old_tail_seq % is below the highest sync_seq in the dump (%): the dump is newer than old_status.txt', __st.old_tail_seq, __legacy_max;
    END IF;

    -- merge ops get consecutive seqs after the old tail, in post_id order
    DROP TABLE IF EXISTS legacy_merge_seq;
    CREATE TABLE legacy_merge_seq AS
    SELECT post_id, reason,
           __st.old_tail_seq + row_number() OVER (ORDER BY post_id) AS sync_seq
      FROM legacy_merge_set;
    ALTER TABLE legacy_merge_seq ADD PRIMARY KEY (post_id);
    SELECT count(*) INTO __merge_count FROM legacy_merge_seq;

    DROP TABLE IF EXISTS posts_vectors_merged, deleted_embeddings_merged, post_data_merged;

    -- post_data: old rows for untouched posts; our rows for merged posts
    -- (falling back to the old row, then a stub, for 'gone' posts we never
    -- had), plus stubs for anything referenced below without a row
    CREATE TABLE post_data_merged (LIKE post_data INCLUDING DEFAULTS);
    INSERT INTO post_data_merged (post_id, number_of_tokens, last_vectors_block)
    SELECT l.post_id, l.number_of_tokens, l.last_vectors_block
      FROM legacy_post_data l
     WHERE NOT EXISTS (SELECT 1 FROM legacy_merge_seq m WHERE m.post_id = l.post_id);
    INSERT INTO post_data_merged (post_id, number_of_tokens, last_vectors_block)
    SELECT m.post_id,
           COALESCE(pd.number_of_tokens,   l.number_of_tokens,   0),
           COALESCE(pd.last_vectors_block, l.last_vectors_block, COALESCE(__st.freeze_block, -1))
      FROM legacy_merge_seq m
      LEFT JOIN post_data        pd ON pd.post_id = m.post_id
      LEFT JOIN legacy_post_data l  ON l.post_id  = m.post_id;

    -- vectors
    CREATE TABLE posts_vectors_merged (LIKE posts_vectors INCLUDING DEFAULTS);
    INSERT INTO posts_vectors_merged (post_id, chunk_number, embedding, sync_seq)
    SELECT lv.post_id, lv.chunk_number, lv.embedding, lv.sync_seq
      FROM legacy_vectors lv
     WHERE NOT EXISTS (SELECT 1 FROM legacy_merge_seq m WHERE m.post_id = lv.post_id);
    INSERT INTO posts_vectors_merged (post_id, chunk_number, embedding, sync_seq)
    SELECT pv.post_id, pv.chunk_number, pv.embedding, m.sync_seq
      FROM posts_vectors pv
      JOIN legacy_merge_seq m ON m.post_id = pv.post_id;

    -- delete markers: the old chain's history, plus one per merged post that
    -- had vectors on the old chain (mirrors store_post_embeddings(): an
    -- update is a delete marker and new rows under the same seq)
    CREATE TABLE deleted_embeddings_merged (LIKE deleted_embeddings INCLUDING DEFAULTS);
    INSERT INTO deleted_embeddings_merged (post_id, sync_seq)
    SELECT post_id, sync_seq FROM legacy_deleted;
    INSERT INTO deleted_embeddings_merged (post_id, sync_seq)
    SELECT m.post_id, m.sync_seq
      FROM legacy_merge_seq m
     WHERE m.reason IN ('gone', 'rechunked');

    -- referential completeness for the FKs added in rebase_build_indexes()
    INSERT INTO post_data_merged (post_id, number_of_tokens, last_vectors_block)
    SELECT DISTINCT x.post_id, 0, -1
      FROM (SELECT post_id FROM posts_vectors_merged
            UNION
            SELECT post_id FROM deleted_embeddings_merged) x
     WHERE NOT EXISTS (SELECT 1 FROM post_data_merged p WHERE p.post_id = x.post_id);

    GRANT SELECT ON posts_vectors_merged, deleted_embeddings_merged, post_data_merged TO hivesense_user;
    BEGIN
        EXECUTE 'GRANT MAINTAIN ON posts_vectors_merged, deleted_embeddings_merged, post_data_merged TO hived_group';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'GRANT MAINTAIN skipped: %', SQLERRM;
    END;

    UPDATE legacy_rebase_state SET merge_count = __merge_count WHERE id = 1;
    PERFORM rebase_set_phase('tables_built');

    RETURN QUERY
    SELECT 'merge_ops'::TEXT, __merge_count::BIGINT
    UNION ALL
    SELECT 'first_merge_seq', __st.old_tail_seq + 1
    UNION ALL
    SELECT 'last_merge_seq', __st.old_tail_seq + __merge_count
    UNION ALL
    SELECT 'merged_vector_rows', count(*) FROM posts_vectors_merged
    UNION ALL
    SELECT 'merged_posts_with_vectors', count(DISTINCT post_id) FROM posts_vectors_merged
    UNION ALL
    SELECT 'merged_delete_markers', count(*) FROM deleted_embeddings_merged
    UNION ALL
    SELECT 'merged_post_data_rows', count(*) FROM post_data_merged;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. constraints and indexes on the merged tables (the HNSW build is the
--    long step; it happens here, before the swap, so the swap is instant)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION hivesense_app.rebase_build_indexes()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    __idx_name TEXT := get_hnsw_index_name() || '_merged';
    __t0       TIMESTAMPTZ;
    __desired_gb INT := (SELECT desired_maintenance_work_mem_gb FROM hivesense_app_status WHERE id = 1);
BEGIN
    PERFORM rebase_phase_is('tables_built');

    ALTER TABLE post_data_merged ADD PRIMARY KEY (post_id);

    ALTER TABLE posts_vectors_merged ADD PRIMARY KEY (post_id, chunk_number);
    ALTER TABLE posts_vectors_merged
        ADD CONSTRAINT posts_vectors_merged_post_id_fkey
        FOREIGN KEY (post_id) REFERENCES post_data_merged (post_id);
    CREATE INDEX posts_vectors_merged_sync_seq_post_id_idx
        ON posts_vectors_merged (sync_seq, post_id);

    ALTER TABLE deleted_embeddings_merged ADD PRIMARY KEY (post_id, sync_seq);
    ALTER TABLE deleted_embeddings_merged
        ADD CONSTRAINT deleted_embeddings_merged_sync_seq_key UNIQUE (sync_seq);
    ALTER TABLE deleted_embeddings_merged
        ADD CONSTRAINT deleted_embeddings_merged_post_id_fkey
        FOREIGN KEY (post_id) REFERENCES post_data_merged (post_id);
    CREATE INDEX deleted_embeddings_merged_sync_seq_post_id_idx
        ON deleted_embeddings_merged (sync_seq, post_id);

    -- same knobs ensure_indexes_are_created() turns for the regular build
    BEGIN
        EXECUTE format('SET max_parallel_maintenance_workers TO %s',
                       LEAST(32, current_setting('max_parallel_workers')::INT));
        IF __desired_gb IS NOT NULL AND __desired_gb > 0 THEN
            EXECUTE format('SET maintenance_work_mem TO %L', __desired_gb || 'GB');
        END IF;
        EXECUTE 'SET work_mem TO ''512MB''';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Could not raise index build settings: %', SQLERRM;
    END;

    __t0 := clock_timestamp();
    RAISE NOTICE 'Building HNSW index % (maintenance_work_mem=%, workers=%) ...',
                 __idx_name, current_setting('maintenance_work_mem'),
                 current_setting('max_parallel_maintenance_workers');
    EXECUTE hnsw_index_statement(__idx_name, 'hivesense_app.posts_vectors_merged', 'embedding');
    RAISE NOTICE 'HNSW index built in %', clock_timestamp() - __t0;

    PERFORM rebase_set_phase('indexes_built');
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. swap: merged tables become live, this node takes over the old chain
-- ─────────────────────────────────────────────────────────────────────────
-- Renames every index/constraint of _table by applying replace(name, _from,
-- _to), so the pre-rebase objects free the canonical names and the merged
-- objects take them.
CREATE OR REPLACE FUNCTION hivesense_app.rebase_rename_dependents(_table TEXT, _from TEXT, _to TEXT)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    r RECORD;
BEGIN
    -- FK constraints have no index of their own
    FOR r IN
        SELECT conname
          FROM pg_constraint
         WHERE conrelid = ('hivesense_app.' || quote_ident(_table))::regclass
           AND contype = 'f'
    LOOP
        EXECUTE format('ALTER TABLE hivesense_app.%I RENAME CONSTRAINT %I TO %I',
                       _table, r.conname, replace(r.conname, _from, _to));
    END LOOP;
    -- indexes; renaming a constraint's index renames the constraint too
    FOR r IN
        SELECT c.relname AS idxname
          FROM pg_index i
          JOIN pg_class c ON c.oid = i.indexrelid
         WHERE i.indrelid = ('hivesense_app.' || quote_ident(_table))::regclass
    LOOP
        EXECUTE format('ALTER INDEX hivesense_app.%I RENAME TO %I',
                       r.idxname, replace(r.idxname, _from, _to));
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION hivesense_app.rebase_swap(_force BOOLEAN DEFAULT FALSE)
RETURNS TABLE (metric TEXT, value TEXT)
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    __st      legacy_rebase_state%ROWTYPE;
    __new_max INT;
    __bp      INT;
    __t       TEXT;
BEGIN
    PERFORM rebase_phase_is('indexes_built');
    SELECT * INTO __st FROM legacy_rebase_state WHERE id = 1;

    -- the block processor must be stopped: it allocates sync_seq values and
    -- publishes max_visible_sync_seq, both of which we reset below
    SELECT count(*) INTO __bp
      FROM pg_stat_activity
     WHERE application_name LIKE 'hivesense_block_processing%'
       AND pid <> pg_backend_pid();
    IF __bp > 0 AND NOT _force THEN
        RAISE EXCEPTION '% hivesense block-processing session(s) connected; stop the block processor first (or rebase_swap(_force => true))', __bp;
    END IF;

    __new_max := __st.old_tail_seq + __st.merge_count;

    FOREACH __t IN ARRAY ARRAY['posts_vectors', 'deleted_embeddings', 'post_data'] LOOP
        EXECUTE format('ALTER TABLE hivesense_app.%I RENAME TO %I', __t, __t || '_pre_rebase');
        PERFORM rebase_rename_dependents(__t || '_pre_rebase', __t, __t || '_pre_rebase');
        EXECUTE format('ALTER TABLE hivesense_app.%I RENAME TO %I', __t || '_merged', __t);
        PERFORM rebase_rename_dependents(__t, '_merged', '');
    END LOOP;

    UPDATE hivesense_app_status
       SET sync_uuid                 = __st.old_uuid,
           syncing_embeddings        = FALSE,
           max_visible_sync_seq      = __new_max,
           skipped_op_count          = COALESCE(__st.old_skipped, 0),
           upstream_skipped_op_count = 0
     WHERE id = 1;
    PERFORM setval('hivesense_app.sync_seq', __new_max, true);

    PERFORM rebase_set_phase('swapped');

    RETURN QUERY
    SELECT 'sync_uuid'::TEXT, __st.old_uuid::TEXT
    UNION ALL
    SELECT 'max_visible_sync_seq', __new_max::TEXT
    UNION ALL
    SELECT 'merge_ops', __st.merge_count::TEXT
    UNION ALL
    SELECT 'hnsw_index', get_hnsw_index_name();
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. verify what a downstream at the old tail will now receive
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION hivesense_app.rebase_verify()
RETURNS TABLE (check_name TEXT, ok BOOLEAN, detail TEXT)
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    __st        legacy_rebase_state%ROWTYPE;
    __status    hivesense_app_status%ROWTYPE;
    __expected  INT;
    __n         BIGINT;
    __s         TEXT;
    __idx       TEXT;
BEGIN
    PERFORM rebase_phase_is('swapped');
    SELECT * INTO __st FROM legacy_rebase_state WHERE id = 1;
    SELECT * INTO __status FROM hivesense_app_status WHERE id = 1;
    __expected := __st.old_tail_seq + __st.merge_count;

    RETURN QUERY SELECT 'status.sync_uuid = old uuid', __status.sync_uuid = __st.old_uuid,
                        __status.sync_uuid::TEXT;
    RETURN QUERY SELECT 'status.max_visible_sync_seq = old tail + merge ops',
                        __status.max_visible_sync_seq = __expected,
                        __status.max_visible_sync_seq::TEXT;
    RETURN QUERY SELECT 'sequence at or past max visible',
                        (SELECT last_value >= __expected FROM hivesense_app.sync_seq),
                        (SELECT last_value::TEXT FROM hivesense_app.sync_seq);

    -- the ops a downstream at the old tail receives: exactly the merge set,
    -- consecutive seqs, op kind by reason
    CREATE TEMP TABLE tmp_ops ON COMMIT DROP AS
    SELECT u.sync_seq, u.op, u.author, u.permlink
      FROM hivesense_endpoints.embedding_updates(__st.old_tail_seq, __st.merge_count + 1, __st.old_uuid::TEXT) u;
    -- resolve the served names the way rebase_resolve() does ('new' posts are
    -- not in legacy_posts, so go to hivemind directly)
    CREATE TEMP TABLE tmp_ops_posts ON COMMIT DROP AS
    SELECT DISTINCT ON (o.sync_seq, o.author, o.permlink)
           o.sync_seq, o.op, hp.id AS post_id
      FROM tmp_ops o
      JOIN hivemind_app.hive_accounts      ha  ON ha.name = o.author
      JOIN hivemind_app.hive_permlink_data hpd ON hpd.permlink = o.permlink
      JOIN hivemind_app.hive_posts         hp  ON hp.author_id = ha.id AND hp.permlink_id = hpd.id
     ORDER BY o.sync_seq, o.author, o.permlink, (hp.counter_deleted = 0) DESC, hp.id DESC;

    SELECT count(*) INTO __n FROM tmp_ops;
    RETURN QUERY SELECT 'ops after old tail = merge ops', __n = __st.merge_count, __n::TEXT;
    RETURN QUERY SELECT 'merge seqs consecutive',
                        COALESCE((SELECT min(sync_seq) = __st.old_tail_seq + 1
                                     AND max(sync_seq) = __expected
                                     AND count(DISTINCT sync_seq) = __st.merge_count FROM tmp_ops), __st.merge_count = 0),
                        (SELECT min(sync_seq)::TEXT || '..' || max(sync_seq)::TEXT FROM tmp_ops);
    SELECT count(*) INTO __n
      FROM tmp_ops_posts o
      JOIN legacy_merge_seq m ON m.post_id = o.post_id AND m.sync_seq = o.sync_seq
     WHERE (m.reason = 'gone'      AND o.op = 'delete')
        OR (m.reason = 'new'       AND o.op = 'insert')
        OR (m.reason = 'rechunked' AND o.op = 'update');
    RETURN QUERY SELECT 'every merge op matches its post and reason', __n = __st.merge_count, __n::TEXT;
    SELECT count(*) INTO __n
      FROM hivesense_endpoints.embedding_updates(__expected, 10, __st.old_uuid::TEXT);
    RETURN QUERY SELECT 'nothing beyond max visible', __n = 0, __n::TEXT;

    -- posts with vectors now = old posts that still have them + new ones
    SELECT count(*) INTO __n FROM (
        SELECT post_id FROM legacy_vectors
        EXCEPT
        SELECT post_id FROM legacy_merge_set WHERE reason = 'gone'
        UNION
        SELECT post_id FROM legacy_merge_set WHERE reason = 'new') x;
    RETURN QUERY SELECT 'posts with vectors as expected',
                        __n = (SELECT count(DISTINCT post_id) FROM posts_vectors),
                        (SELECT count(DISTINCT post_id) FROM posts_vectors)::TEXT || ' (expected ' || __n || ')';

    RETURN QUERY SELECT '/sync-chains lists the old uuid first',
                        (SELECT c.sync_uuid = __st.old_uuid::TEXT
                           FROM hivesense_endpoints.get_sync_chains() c LIMIT 1),
                        (SELECT c.sync_uuid FROM hivesense_endpoints.get_sync_chains() c LIMIT 1);

    __idx := get_hnsw_index_name();
    RETURN QUERY SELECT 'HNSW index present under its canonical name',
                        EXISTS (SELECT 1 FROM pg_indexes
                                 WHERE schemaname = 'hivesense_app' AND tablename = 'posts_vectors' AND indexname = __idx),
                        __idx;
    BEGIN
        SELECT count(*) INTO __n
          FROM find_nearest_posts_with_embedding_one_shot(
                   (SELECT embedding::public.vector FROM posts_vectors ORDER BY post_id, chunk_number LIMIT 1), 5);
        __s := __n::TEXT || ' rows';
    EXCEPTION WHEN OTHERS THEN
        __n := 0;
        __s := SQLERRM;
    END;
    RETURN QUERY SELECT 'search works on the merged table', __n >= 1, __s;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. cleanup, once the rebase has proven itself
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION hivesense_app.rebase_cleanup()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
BEGIN
    PERFORM rebase_phase_is('swapped');
    DROP TABLE IF EXISTS posts_vectors_pre_rebase, deleted_embeddings_pre_rebase, post_data_pre_rebase;
    DROP TABLE IF EXISTS legacy_vectors_raw, legacy_deleted_raw, legacy_post_data_raw, legacy_root_posts_raw,
                         legacy_posts, legacy_unresolved, legacy_vectors, legacy_deleted, legacy_post_data,
                         legacy_merge_set, legacy_merge_seq, legacy_diff_histogram;
    PERFORM rebase_set_phase('cleaned');
END;
$$;

RESET ROLE;

SET ROLE hivesense_owner;

DO $BODY$
DECLARE
    __llm     TEXT := current_setting('pg_temp.LLM',        TRUE);
    __ollama  TEXT := current_setting('pg_temp.OLLAMA_HOST', TRUE);
    __num_ctx INT  := NULLIF(current_setting('pg_temp.NUM_CTX', TRUE)::INT, 0);
    __opts    TEXT := '';
BEGIN
    -- When num_ctx is set, pass it as embedding_options so Ollama
    -- allocates enough context for large-chunk models (e.g. Jina v5 small
    -- with tokens_per_chunk=2048 exceeds Ollama's default num_ctx of 2048)
    IF __num_ctx IS NOT NULL THEN
        __opts := format($$, embedding_options => '{"num_ctx": %s}'::jsonb$$, __num_ctx);
    END IF;

    EXECUTE format($$
        CREATE OR REPLACE FUNCTION hivesense_embed(_post TEXT)
            RETURNS vector
            IMMUTABLE
            LANGUAGE plpgsql
            PARALLEL SAFE
        AS
        $BODY2$
        BEGIN
            RETURN hivesense_app.ollama_embed('%s', _post, host => '%s'%s);
        END;
        $BODY2$
    $$, __llm, __ollama, __opts);

    EXECUTE format($$
        CREATE OR REPLACE FUNCTION hivesense_embed(_posts hivesense_app.id_and_post_chunk[])
            RETURNS hivesense_app.post_and_vector_chunk[]
            IMMUTABLE
            LANGUAGE plpgsql
            PARALLEL SAFE
        AS
        $BODY2$
        BEGIN
            RETURN hivesense_app.ollama_embed('%s', _posts, host => '%s'%s);
        END;
        $BODY2$
    $$, __llm, __ollama, __opts);
END;
$BODY$;

DROP TYPE IF EXISTS hivesense_app.embedding_stats CASCADE;
CREATE TYPE hivesense_app.embedding_stats AS (
    discarded_posts       INT,
    processed_posts       INT,
    embedding_chunks      INT,
    total_tokens          INT,
    prep_time_secs        DOUBLE PRECISION,
    embed_time_secs       DOUBLE PRECISION
);

-- ============================================================================
-- RANGE PROCESSING PRIMITIVES (haf#341 python block processor)
-- ============================================================================
-- The embedding pipeline is split around the HTTP call so that a client-side
-- processor (scripts/hivesense_block_processor.py, run by haf_app_driver.py)
-- can do the network work outside PostgreSQL:
--
--   1. hivesense_app.posts_in_range(first, last)   -> post ids to (re)vectorize
--   2. hivesense_app.prepare_post_chunks(ids)      -> chunk texts (and session
--      temp tables tmp_pre / tmp_chunks for step 4)
--   3. the client embeds the chunks over HTTP and fills a session temp table
--      tmp_vectors(post_id INT, chunk_number INT, vec public.vector)
--   4. hivesense_app.store_post_embeddings()       -> deletions, vectors,
--      reduced vectors, post_data, sync_seq bookkeeping
--
-- All four run on one connection inside one transaction (the driver's), so the
-- ON COMMIT DROP temp tables carry state between the steps and everything
-- becomes durable together with the context position.
-- generate_embeddings_for_posts() (the in-database path used by the legacy
-- scheduler/workers) is built from the same pieces with hivesense_embed()
-- filling tmp_vectors in place of the client.

-- Ordered ids of root posts created or edited in a block range (the same
-- selection the scheduler used when building worker tasks).
CREATE OR REPLACE FUNCTION hivesense_app.posts_in_range(_first_block INT, _last_block INT)
RETURNS INT[]
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(ARRAY_AGG(post_id ORDER BY blk, post_id), ARRAY[]::INT[])
    FROM (
        SELECT hp.id AS post_id,
               GREATEST(hp.block_num_created, hp.block_num) AS blk
        FROM hivemind_app.hive_posts hp
        JOIN hivemind_app.hive_post_data hpd USING(id)
        WHERE (hp.root_id = hp.id OR hp.root_id = 0)
          AND (
                hp.block_num_created BETWEEN _first_block AND _last_block
             OR hp.block_num          BETWEEN _first_block AND _last_block
          )
    ) p
$$;

-- Preprocess and chunk the posts; leaves tmp_pre and tmp_chunks (ON COMMIT
-- DROP) behind for store_post_embeddings() and returns the chunks to embed.
CREATE OR REPLACE FUNCTION hivesense_app.prepare_post_chunks(_post_ids INT[])
RETURNS TABLE(post_id INT, chunk_number INT, chunk_text TEXT)
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    __tokenizer_name          TEXT;
    __max_tokens              INT;
    __min_new_ratio           REAL;
    __doc_prefix              TEXT;
    __min_token_threshold     INT;
    __max_embeddings_per_post INT;
BEGIN
    SELECT tokenizer_model,
           tokens_per_chunk,
           1 - overlap_amount,
           document_prefix,
           min_token_threshold,
           max_embeddings_per_post
      INTO __tokenizer_name,
           __max_tokens,
           __min_new_ratio,
           __doc_prefix,
           __min_token_threshold,
           __max_embeddings_per_post
    FROM hivesense_app.hivesense_app_status
    WHERE id = 1;

    -- fresh per transaction (ON COMMIT DROP); drop quietly if the caller runs
    -- twice in one transaction
    IF to_regclass('pg_temp.tmp_pre') IS NOT NULL THEN DROP TABLE tmp_pre; END IF;
    IF to_regclass('pg_temp.tmp_chunks') IS NOT NULL THEN DROP TABLE tmp_chunks; END IF;

    -- preprocess with threshold 0 so short posts are kept: they drive the
    -- "post now produces zero chunks" deletion bookkeeping in the store step
    CREATE TEMP TABLE tmp_pre ON COMMIT DROP AS
    SELECT
        hp.id        AS post_id,
        hp.block_num,
        COALESCE(pp.token_count, 0)            AS token_count,
        COALESCE(pp.chunks, ARRAY[]::TEXT[])   AS chunks
    FROM   unnest(_post_ids)          AS sel(id)
    JOIN   hivemind_app.hive_posts     hp  ON hp.id = sel.id
    LEFT   JOIN LATERAL preprocess_post(
               (SELECT hpd.title || E'.\n\n' || hpd.body
                  FROM hivemind_app.hive_post_data hpd
                  WHERE hpd.id = hp.id),
               hp.id,
               '[permlink disabled]',
               __tokenizer_name,
               __max_tokens,
               __min_new_ratio,
               __max_embeddings_per_post,
               TRUE,
               __doc_prefix,
               0
           ) AS pp
           ON TRUE;

    CREATE TEMP TABLE tmp_chunks ON COMMIT DROP AS
    SELECT
        p.post_id,
        generate_subscripts(p.chunks, 1) - 1          AS chunk_number,
        p.chunks[generate_subscripts(p.chunks, 1)]    AS chunk_text,
        p.token_count,
        p.block_num
    FROM tmp_pre p
    WHERE p.token_count >= __min_token_threshold
      AND array_length(p.chunks, 1) IS NOT NULL;

    RETURN QUERY
    SELECT c.post_id, c.chunk_number, c.chunk_text
    FROM tmp_chunks c
    ORDER BY c.post_id, c.chunk_number;
END;
$$;

-- Store the embeddings the caller placed in tmp_vectors (and the deletion
-- bookkeeping for posts that produced no chunks), using the tmp_pre/tmp_chunks
-- state from prepare_post_chunks(). Returns (discarded, processed, chunks).
CREATE OR REPLACE FUNCTION hivesense_app.store_post_embeddings()
RETURNS TABLE(discarded_posts INT, processed_posts INT, embedding_chunks INT, total_tokens INT)
LANGUAGE plpgsql
VOLATILE
SET search_path = hivesense_app, public
AS $$
DECLARE
    rec        RECORD;
    __sync_seq INT;
BEGIN
    /* posts that now produce zero chunks (true deletions / under-threshold edits) */
    CREATE TEMP TABLE tmp_empty_posts ON COMMIT DROP AS
    SELECT p.post_id,
           p.block_num,
           p.token_count
    FROM   tmp_pre p
    LEFT   JOIN tmp_chunks c USING (post_id)
    WHERE  c.post_id IS NULL;

    IF EXISTS (SELECT 1 FROM tmp_empty_posts) THEN
        CREATE TEMP TABLE tmp_empty_seq ON COMMIT DROP AS
        SELECT ep.post_id,
               nextval('hivesense_app.sync_seq') AS sync_seq
        FROM   tmp_empty_posts ep;

        -- post_data first: posts_vectors and deleted_embeddings reference it
        -- (the scheduler used to pre-insert placeholder rows for this)
        INSERT INTO hivesense_app.post_data(post_id, number_of_tokens, last_vectors_block)
        SELECT ep.post_id, ep.token_count, ep.block_num
        FROM   tmp_empty_posts ep
        ON CONFLICT (post_id) DO UPDATE
            SET number_of_tokens   = EXCLUDED.number_of_tokens,
                last_vectors_block = EXCLUDED.last_vectors_block;

        DELETE FROM hivesense_app.posts_vectors pv
        USING  tmp_empty_posts ep
        WHERE  pv.post_id = ep.post_id;

        INSERT INTO hivesense_app.deleted_embeddings(post_id, sync_seq)
        SELECT es.post_id, es.sync_seq
        FROM   tmp_empty_seq es;

        DROP TABLE tmp_empty_seq;
    END IF;

    /* per-post sync_seq, delete & insert */
    FOR rec IN
      SELECT DISTINCT c.post_id, c.block_num,
             MAX(c.token_count) AS tcnt
        FROM tmp_chunks c
       GROUP BY c.post_id, c.block_num
    LOOP
        SELECT nextval('hivesense_app.sync_seq') INTO __sync_seq;

        -- post_data first: posts_vectors references it
        INSERT INTO hivesense_app.post_data(post_id, number_of_tokens, last_vectors_block)
        VALUES (rec.post_id, rec.tcnt, rec.block_num)
        ON CONFLICT (post_id) DO UPDATE
            SET number_of_tokens   = EXCLUDED.number_of_tokens,
                last_vectors_block = EXCLUDED.last_vectors_block;

        IF EXISTS (
           SELECT 1 FROM hivesense_app.posts_vectors pv
            WHERE pv.post_id = rec.post_id
        ) THEN
            DELETE FROM hivesense_app.posts_vectors
             WHERE posts_vectors.post_id = rec.post_id;
            INSERT INTO hivesense_app.deleted_embeddings(post_id, sync_seq)
            VALUES (rec.post_id, __sync_seq);
        END IF;

        INSERT INTO hivesense_app.posts_vectors(
            post_id, chunk_number, embedding, sync_seq
        )
        SELECT
          v.post_id,
          v.chunk_number,
          CASE WHEN hivesense_app.store_halfvec_embeddings()
               THEN v.vec::public.halfvec
               ELSE v.vec
          END,
          __sync_seq
        FROM tmp_vectors v
        WHERE v.post_id = rec.post_id
        ORDER BY v.chunk_number;

        IF hivesense_app.use_reduced_embeddings()
           AND hivesense_app.reduction_mode() <> 'slice' THEN
            INSERT INTO hivesense_app.posts_vectors_reduced(
                post_id, chunk_number, reduced_embedding
            )
            SELECT
                v.post_id,
                v.chunk_number,
                CASE
                    WHEN hivesense_app.store_halfvec_embeddings()
                         THEN hivesense_app.reduce_embedding(v.vec::public.vector)::public.halfvec
                    ELSE hivesense_app.reduce_embedding(v.vec::public.vector)
                END
            FROM tmp_vectors v
            WHERE v.post_id = rec.post_id
            ORDER BY v.chunk_number;
        END IF;

    END LOOP;

    RETURN QUERY
    SELECT
        (SELECT COUNT(*)::INT FROM tmp_empty_posts),
        (SELECT COUNT(DISTINCT c.post_id)::INT FROM tmp_chunks c),
        (SELECT COUNT(*)::INT FROM tmp_vectors),
        (SELECT COALESCE(SUM(p.token_count),0)::INT FROM tmp_pre p
          WHERE EXISTS (SELECT 1 FROM tmp_chunks c WHERE c.post_id = p.post_id));

    DROP TABLE tmp_empty_posts;
END;
$$;

-- Publish everything stored so far to the remote-sync API (the syncers pull
-- only up to max_visible_sync_seq; higher sequences may still have gaps).
CREATE OR REPLACE FUNCTION hivesense_app.publish_visible_sync_seq()
RETURNS void
LANGUAGE sql
VOLATILE
AS $$
    UPDATE hivesense_app.hivesense_app_status
       SET max_visible_sync_seq = GREATEST(
         COALESCE((SELECT MAX(sync_seq) FROM hivesense_app.posts_vectors),0),
         COALESCE((SELECT MAX(sync_seq) FROM hivesense_app.deleted_embeddings),0)
       )
     WHERE id = 1
$$;

DROP FUNCTION IF EXISTS generate_embeddings_for_posts(integer[],boolean,integer);
CREATE OR REPLACE FUNCTION generate_embeddings_for_posts(
    _post_ids INT[],
    _logs     BOOLEAN,
    _worker   INT
)
RETURNS hivesense_app.embedding_stats
LANGUAGE plpgsql
VOLATILE
PARALLEL SAFE
SET search_path = hivesense_app, public
AS $$
DECLARE
    -- Legacy in-database path (scheduler/worker sessions): the same
    -- prepare -> embed -> store pipeline as the python block processor, with
    -- hivesense_app.hivesense_embed() (plpython HTTP) doing the embedding here.
    __start_prep  TIMESTAMP := clock_timestamp();
    __start_embed TIMESTAMP;
    __prep_time   DOUBLE PRECISION;
    __embed_time  DOUBLE PRECISION;
    __stats       RECORD;
BEGIN
    PERFORM hivesense_app.prepare_post_chunks(_post_ids);
    __prep_time := EXTRACT(EPOCH FROM clock_timestamp() - __start_prep);

    __start_embed := clock_timestamp();
    CREATE TEMP TABLE tmp_vectors ON COMMIT DROP AS
    WITH all_chunks AS (
        SELECT ARRAY_AGG(
                   (c.post_id, c.chunk_text, c.chunk_number)
                     ::hivesense_app.id_and_post_chunk
                   ORDER BY c.post_id, c.chunk_number
               ) AS arr
        FROM tmp_chunks c
    )
    SELECT
        pv.post_id,
        pv.chunk_number,
        pv.vec
    FROM all_chunks
    CROSS JOIN LATERAL UNNEST(hivesense_app.hivesense_embed(all_chunks.arr)) AS pv;
    __embed_time := EXTRACT(EPOCH FROM clock_timestamp() - __start_embed);

    SELECT * INTO __stats FROM hivesense_app.store_post_embeddings();

    DROP TABLE tmp_vectors;
    DROP TABLE tmp_chunks;
    DROP TABLE tmp_pre;

    RETURN (__stats.discarded_posts, __stats.processed_posts, __stats.embedding_chunks,
            __stats.total_tokens, __prep_time, __embed_time);
END;
$$;

CREATE OR REPLACE PROCEDURE hivesense_massive_processing(
    IN _from INT, IN _to INT, IN _logs BOOLEAN, IN _worker INT, OUT _done INT
)
LANGUAGE plpgsql
AS
$$
BEGIN
  PERFORM set_config('synchronous_commit', 'OFF', false);

  SELECT hivesense_block_range_data(_from, _to, _logs, _worker) INTO _done;
END
$$;

CREATE OR REPLACE PROCEDURE hivesense_single_processing(
    IN _from INT, IN _to INT, IN _logs BOOLEAN, IN _worker INT, _done OUT INT
)
LANGUAGE plpgsql
AS
$$
BEGIN
  PERFORM set_config('synchronous_commit', 'ON', false);

  SELECT hivesense_block_range_data(_from, _to, _logs, _worker) INTO _done;
END
$$;

DROP TYPE IF EXISTS BREAK_REASON CASCADE;
CREATE TYPE break_reason AS ENUM (
    'BLOCK_LIMIT_REACHED',
    'BREAK_ON_USER_REQUEST'
);

CREATE OR REPLACE FUNCTION isbreakingpending(
    _appContext hive.CONTEXT_NAME,
    _maxBlockLimit INT,
    _blocks_range hive.BLOCKS_RANGE
)
RETURNS BREAK_REASON -- NULL means no break
LANGUAGE plpgsql
PARALLEL SAFE
AS
$$
BEGIN
    IF _blocks_range IS NULL AND _maxBlockLimit IS NOT NULL THEN
        IF hive.app_get_current_block_num(_appContext) >= _maxBlockLimit THEN
            RAISE NOTICE 'Worker % reached blocks limit. Exiting application main loop at processed block: %.', _appContext, hive.app_get_current_block_num(_appContext);
            RETURN 'BLOCK_LIMIT_REACHED';
        END IF;
    END IF;

    IF NOT continueProcessing() THEN
        RAISE NOTICE 'Worker % exiting application main loop at processed block: %.', _appContext, hive.app_get_current_block_num(_appContext);
        RETURN 'BREAK_ON_USER_REQUEST';
    END IF;

    RETURN NULL;
END
$$;

CREATE OR REPLACE PROCEDURE hivesense_process_blocks(_context_name hive.CONTEXT_NAME, _block_range hive.BLOCKS_RANGE, IN _worker INT, OUT _done INT, _logs BOOLEAN = true)
LANGUAGE plpgsql
AS
$$
BEGIN
    IF hive.get_current_stage_name(_context_name) = 'MASSIVE_PROCESSING' THEN
        CALL hivesense_massive_processing(_block_range.first_block, _block_range.last_block, _logs, _worker, _done);
        RETURN;
    END IF;

    CALL hivesense_single_processing(_block_range.first_block, _block_range.last_block, _logs, _worker, _done);
END
$$;

CREATE OR REPLACE FUNCTION wait_for_start_block(_start_block INT, _worker INT, _context hafd.CONTEXT_NAME)
RETURNS BOOLEAN -- true: not waiting, false: waiting
LANGUAGE plpgsql
PARALLEL SAFE
STABLE
AS
$$
DECLARE
  __head_of_irreversible_block BIGINT;
BEGIN


    IF _start_block != 0 THEN
        SELECT hir.consistent_block INTO __head_of_irreversible_block
        FROM hafd.hive_state hir;

        IF _start_block > __head_of_irreversible_block THEN
            PERFORM pg_sleep( 5 );
            IF _worker = 1 THEN
                RAISE INFO 'Waiting for the first block(%) to vectorize. Current HAF head block is %', _start_block, __head_of_irreversible_block;
            END IF;
            RETURN FALSE;
        END IF;
    END IF;

    RETURN TRUE;
END
$$;

-- Dropped: the advisory-lock based scheduler/worker handshake has been replaced
-- by state-based coordination through hivesense_app.block_tasks (see scheduler()
-- and worker_loop() below).  The old unlock/relock "pulse" protocol could lose a
-- wakeup whenever the peer was not already blocked in the lock wait-queue,
-- eventually leaving every worker parked while the scheduler polled a queue that
-- nobody could ever drain.
DROP PROCEDURE IF EXISTS hivesense_app.wait_for_advisory_lock(INT, INT, INT);


/** Application entry point, which starts application main-loop (which iterates infinitely).
  To stop it call `stopProcessing();` from another session and commit its trasaction.
*/
CREATE OR REPLACE PROCEDURE hivesense_app.scheduler(
    IN  _app_context_base_name  hive.context_name,
    IN  _workers                INT,
    IN  _max_block_limit        INT      DEFAULT null
)
LANGUAGE plpgsql
AS $$
DECLARE
    __hivemind_current_block        INT;
    __context_name                  hive.context_name := _app_context_base_name; -- single context
    __start_block                   INT               := 0;
    __blocks_range                  hive.blocks_range := (0,0);
    __planned_range                 hive.blocks_range;
    __batch_id                      BIGINT;
    __todo                          INT;
    __breaking_reason               break_reason      := null;
    __blocks                        INT;
    __blocks_per_chunk              INT;
    __number_of_chunks              INT;
    __chunks_per_worker             INT;
    __extra                         INT;
    __from_block                    INT;
    __to_block                      INT;
    __posts_per_chunk      CONSTANT INT := 100;

    -- progress tracking for the batch-completion wait
    __last_todo                     INT;
    __last_progress                 TIMESTAMPTZ;
    __last_warning                  TIMESTAMPTZ;

    __current_syncing               BOOLEAN;
    __current_uuid                  UUID;
    __new_uuid                      UUID;
BEGIN
    -- Block until any active hivemind/hivesense installer releases its
    -- exclusive lock; held by this session until the scheduler returns.
    PERFORM hive.acquire_app_block_processor_locks(ARRAY['hivemind', 'hivesense']);

    -- Check our sync UUID -- if we're just starting out (empty database), or if we were downloading pre-computed embeddings
    -- from another server but are now switching to computing them locally, generate a new UUID here
    SELECT syncing_embeddings, sync_uuid INTO __current_syncing, __current_uuid FROM hivesense_app.hivesense_app_status WHERE id = 1;

    IF __current_syncing IS NULL OR __current_syncing THEN
        -- First run or switching from remote sync to local processing
        __new_uuid := gen_random_uuid();
        UPDATE hivesense_app.hivesense_app_status SET sync_uuid = __new_uuid, syncing_embeddings = FALSE WHERE id = 1;
        RAISE NOTICE 'Sync init: set sync_uuid=%, syncing_embeddings=FALSE', __new_uuid;
    ELSE
        -- Already initialized; nothing to do
        RAISE NOTICE 'Sync init: existing sync_uuid=% (syncing_embeddings=FALSE)', __current_uuid;
    END IF;

    -- read configured start_block
    SELECT start_block INTO __start_block
    FROM   hivesense_app.hivesense_app_status;

    --------------------------------------------------------------------------------
    -- Discard any tasks left over from an unclean shutdown.  The main loop below
    -- re-dispatches starting from the context's current block, so stale tasks
    -- would only duplicate work.
    --------------------------------------------------------------------------------
    TRUNCATE hivesense_app.block_tasks;
    COMMIT;

    RAISE NOTICE 'Scheduler: entering main loop (% workers expected)...', _workers;

    IF _max_block_limit IS NOT NULL THEN
        RAISE NOTICE 'Max block limit is specified as: %', _max_block_limit;
    END IF;

    PERFORM allowprocessing();

    RAISE NOTICE 'Last block processed by application %: %',
                 __context_name,
                 hive.app_get_current_block_num(__context_name);

    IF hive.app_get_current_block_num(__context_name) < __start_block - 1 THEN
        PERFORM hive.app_set_current_block_num(__context_name, __start_block - 1);
    END IF;



    RAISE NOTICE 'Entering scheduler main loop...';

    LOOP
        -- honour start-block (wait until irreversible head reaches it)
        IF NOT wait_for_start_block(__start_block, 1, __context_name) THEN
            RAISE NOTICE 'Waiting for start block...';
            PERFORM pg_sleep(0.1);
            CONTINUE;
        END IF;

        -- RAISE NOTICE 'Past start block...';
        -- request the next range from HAF *inside a tx* …
        -- … but roll it back immediately so we don’t keep xmin.
        CALL hive.app_next_iteration(
            __context_name,
            __blocks_range,
            _override_max_batch => NULL,
            _limit              => _max_block_limit
        );

        -- keep a copy across the ROLLBACK
        __planned_range := __blocks_range;

        ROLLBACK;                       -- <<< frees RowExclusiveLock on context & xmin
        -- pl/pgsql variables survive the ROLLBACK, so __planned_range is safe

        -- nothing to do yet
        IF __blocks_range IS NULL THEN
            __breaking_reason := isbreakingpending(__context_name, _max_block_limit, NULL);
            IF __breaking_reason IS NOT NULL THEN
                IF __breaking_reason = 'BLOCK_LIMIT_REACHED'
                   AND _max_block_limit IS NOT NULL
                   AND hive.app_get_current_block_num(__context_name) >= _max_block_limit THEN
                    CALL ensure_indexes_are_created();
                END IF;
                RETURN;
            END IF;
            PERFORM pg_sleep(1);
            CONTINUE;
        END IF;

        ------------------------------------------------------------------
        -- Wait for hivemind in a *read-only* loop (no open tx)
        ------------------------------------------------------------------
        LOOP
            SELECT hive.app_get_current_block_num('hivemind_app')
              INTO __hivemind_current_block;

            EXIT WHEN __hivemind_current_block >= __planned_range.last_block;

            RAISE NOTICE 'Waiting for hivemind to reach block % (currently at %) [not in transaction]',
                         __planned_range.last_block,
                         __hivemind_current_block;
            ----------------------------------------------------------------
            -- finish the txn *immediately* so backend_xmin is released
            ----------------------------------------------------------------
            COMMIT;

            PERFORM pg_sleep(1);

            __breaking_reason := isbreakingpending(__context_name, _max_block_limit, NULL);
            IF __breaking_reason IS NOT NULL THEN
                RETURN;
            END IF;
        END LOOP;

        ------------------------------------------------------------------
        -- Re-enter a write tx and (re)claim the same block range.
        -- This updates hafd.contexts correctly *after* the long wait.
        ------------------------------------------------------------------
        CALL hive.app_next_iteration(
                __context_name,
                __blocks_range,
                _override_max_batch => NULL,
                _limit              => _max_block_limit
        );

        -- RAISE NOTICE 'App_next_iteration returned';

        -- check global break conditions
        __breaking_reason := isbreakingpending(__context_name, _max_block_limit, __blocks_range);
        IF __breaking_reason IS NOT NULL THEN
            ROLLBACK;
            IF __breaking_reason = 'BLOCK_LIMIT_REACHED'
               AND _max_block_limit IS NOT NULL
               AND hive.app_get_current_block_num(__context_name) >= _max_block_limit THEN
                CALL ensure_indexes_are_created();
            END IF;
            RETURN;
        END IF;

        -- nothing to do yet
        IF __blocks_range IS NULL THEN
            RAISE NOTICE '__blocks_range IS NULL';
            CONTINUE;
        END IF;

        -- wait until hivemind has processed through this range
        LOOP
            SELECT hive.app_get_current_block_num('hivemind_app')
              INTO __hivemind_current_block;
            EXIT WHEN __hivemind_current_block >= __blocks_range.last_block;
            RAISE NOTICE 'Waiting for hivemind to reach block % (currently at %) [in transaction]',
                         __blocks_range.last_block,
                         __hivemind_current_block;
            PERFORM pg_sleep(1);
            __breaking_reason := isbreakingpending(__context_name, _max_block_limit, NULL);
            IF __breaking_reason IS NOT NULL THEN
              RETURN;
            END IF;
        END LOOP;

        /* ------------------------------------------------------------------
         * Build ordered list of posts in this range
         * ----------------------------------------------------------------*/
        __batch_id := nextval('hivesense_app.batch_seq');
        WITH posts AS (
          SELECT hp.id AS post_id,
                 GREATEST(hp.block_num_created, hp.block_num) AS blk
            FROM hivemind_app.hive_posts hp
            JOIN hivemind_app.hive_post_data hpd USING(id)
           WHERE (hp.root_id = hp.id OR hp.root_id = 0)
             AND (
                   hp.block_num_created BETWEEN __blocks_range.first_block AND __blocks_range.last_block
                OR hp.block_num          BETWEEN __blocks_range.first_block AND __blocks_range.last_block
             )
        ),
        numbered AS (
          SELECT
            post_id,
            blk,
            ROW_NUMBER() OVER (ORDER BY blk)  AS rn
          FROM posts
        ),
        chunked AS (
          SELECT
            post_id,
            blk,
            ((rn - 1) / __posts_per_chunk)::INT AS chunk_idx
          FROM numbered
        ),
        grouped AS (
          SELECT
            chunk_idx,
            ARRAY_AGG(post_id ORDER BY post_id) AS pids,
            MIN(blk) AS first_blk,
            MAX(blk) AS last_blk
          FROM chunked
          GROUP BY chunk_idx
        )
        INSERT INTO hivesense_app.block_tasks(
            batch_id, shard, post_ids, first_block, last_block
        )
        SELECT
            __batch_id,
            NULL,
            pids,
            first_blk,
            last_blk
        FROM grouped;

        LOCK TABLE hivemind_app.hive_posts IN SHARE MODE;

        /* bulk-upsert post_data for this batch (unchanged but re-uses grouped) */
        INSERT INTO hivesense_app.post_data (post_id, number_of_tokens, last_vectors_block)
        SELECT id, 0, -1
        FROM (
            SELECT DISTINCT UNNEST(post_ids) AS id
            FROM   hivesense_app.block_tasks
            WHERE  batch_id = __batch_id
        ) AS src
        ORDER BY id                                -- ☚ guarantees lock order
        ON CONFLICT (post_id) DO NOTHING;

        COMMIT;            -- publish the batch: from this moment the tasks are
                           -- visible to the workers, which poll block_tasks and
                           -- claim pending rows on their own

        --------------------------------------------------------------------------------
        -- Wait until every task of this batch is done.
        --
        -- All scheduler/worker coordination happens through the committed state
        -- of hivesense_app.block_tasks (level-triggered), so no wakeup can be
        -- lost: a worker that was busy or slow at publish time simply sees the
        -- pending rows on its next poll.  A task abandoned by a failed worker
        -- rolls back to 'pending', where any other worker will pick it up.
        --------------------------------------------------------------------------------
        __last_todo     := NULL;
        __last_progress := clock_timestamp();
        __last_warning  := NULL;
        LOOP
            SELECT COUNT(*) INTO __todo
            FROM   hivesense_app.block_tasks
            WHERE  batch_id = __batch_id
              AND  status  <> 'done';

            EXIT WHEN __todo = 0;

            IF __todo IS DISTINCT FROM __last_todo THEN
                __last_todo     := __todo;
                __last_progress := clock_timestamp();
            END IF;

            -- A long time without progress is not necessarily fatal (a single
            -- large task can keep a worker embedding for minutes), but it is
            -- worth reporting.
            IF clock_timestamp() - __last_progress > interval '120 seconds'
               AND (__last_warning IS NULL
                    OR clock_timestamp() - __last_warning > interval '120 seconds') THEN
                RAISE WARNING 'SCHEDULER: batch % has % unfinished task(s) with no progress for %; a large task may still be embedding, or workers may have failed',
                              __batch_id, __todo, clock_timestamp() - __last_progress;
                __last_warning := clock_timestamp();
            END IF;

            COMMIT;   -- do not hold a transaction (and xmin) open while waiting
            PERFORM pg_sleep(0.1);
        END LOOP;

        -- clean up the tasks table, the tasks are all done, we don't need to keep that info around forever
        TRUNCATE hivesense_app.block_tasks;

        -- mark all new sync_seq as visible only after batch completion
        UPDATE hivesense_app.hivesense_app_status
           SET max_visible_sync_seq = GREATEST(
             COALESCE((SELECT MAX(sync_seq) FROM hivesense_app.posts_vectors),0),
             COALESCE((SELECT MAX(sync_seq) FROM hivesense_app.deleted_embeddings),0)
           )
         WHERE id = 1;

        -------------------------------------------------------------------
        -- After the batch, create indexes when appropriate
        -------------------------------------------------------------------
        IF hive.get_current_stage_name(__context_name) = 'live' THEN
            CALL ensure_indexes_are_created();
        END IF;
    END LOOP;

    ASSERT FALSE, 'Scheduler: unreachable';
END
$$;


CREATE OR REPLACE PROCEDURE hivesense_app.worker_loop(
    IN _worker            INT,
    IN _app_context_name  hive.context_name,
    IN _max_block_limit   INT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    __task                          RECORD;
    __stats                         hivesense_app.embedding_stats;
    __breaking_reason               break_reason := NULL;
BEGIN
    -- Block until any active hivemind/hivesense installer releases its
    -- exclusive lock; held by this session until the worker loop returns.
    PERFORM hive.acquire_app_block_processor_locks(ARRAY['hivemind', 'hivesense']);

    -- workers run forever until break conditions tell them to exit
    LOOP
        --------------------------------------------------------------------
        -- Wait for work.  The scheduler publishes a batch by COMMITting
        -- rows into hivesense_app.block_tasks; the committed queue is the
        -- only signal, so a wakeup can never be lost.
        --
        -- Break conditions are evaluated *before* the queue check and only
        -- honoured while the queue is empty: when the scheduler publishes a
        -- final batch atomically with state that satisfies a break condition
        -- (e.g. the context reaching _max_block_limit), the batch is drained
        -- before the worker exits.
        --------------------------------------------------------------------
        LOOP
            COMMIT;   -- close out any open tx so xmin can advance while idle
            __breaking_reason := isbreakingpending(_app_context_name, _max_block_limit, NULL);
            EXIT WHEN EXISTS (SELECT FROM hivesense_app.block_tasks WHERE status = 'pending');
            IF __breaking_reason IS NOT NULL THEN
                RETURN;
            END IF;
            PERFORM pg_sleep(0.1);
        END LOOP;

        LOOP
            ------------------------------------------------------------------
            -- Try to claim a pending task for this shard
            ------------------------------------------------------------------
            -- RAISE NOTICE 'getting new task for worker %', _worker;
            SELECT task_id,
                   post_ids,
                   first_block,
                   last_block
              INTO __task
            FROM hivesense_app.block_tasks
            WHERE status = 'pending'
            FOR UPDATE SKIP LOCKED
            LIMIT 1;

            IF NOT FOUND THEN
                ROLLBACK;
                EXIT;
            END IF;

            -- IF _blocks_range IS NULL THEN
            --     RAISE INFO 'block range is null...';
            --     CONTINUE;
            -- END IF;

            ------------------------------------------------------------------
            -- Mark task running
            ------------------------------------------------------------------
            -- RAISE NOTICE 'worker % marking task as running', _worker;
            UPDATE hivesense_app.block_tasks
               SET status     = 'running',
                   shard      = _worker,
                   claimed_at = clock_timestamp()
             WHERE task_id    = __task.task_id;

            ------------------------------------------------------------------
            -- Execute the heavy work for this block sub-range
            ------------------------------------------------------------------
            -- RAISE NOTICE 'worker % processing block range % to %', _worker, __task.first_block, __task.last_block;
            IF __task.last_block = __task.first_block THEN
                RAISE NOTICE 'worker % processing block % (% posts)',
                             _worker,
                             __task.first_block,
                             array_length(__task.post_ids,1);
            ELSE
                RAISE NOTICE 'worker % processing blocks % to % (% blocks, % posts)',
                             LPAD(_worker::text, 2),
                             __task.first_block,
                             __task.last_block,
                             __task.last_block - __task.first_block + 1,
                             array_length(__task.post_ids,1);
            END IF;

            __stats := generate_embeddings_for_posts(__task.post_ids, TRUE, _worker);

            RAISE NOTICE
              'worker % profile: discarded_posts=% processed_posts=% embedding_chunks=% total_tokens=% prep_time=%s embed_time=%s chunks_per_sec=%',
              _worker,
              __stats.discarded_posts,
              __stats.processed_posts,
              __stats.embedding_chunks,
              __stats.total_tokens,
              ROUND(__stats.prep_time_secs::numeric, 3),
              ROUND(__stats.embed_time_secs::numeric, 3),
              ROUND(__stats.embedding_chunks::numeric / NULLIF(__stats.embed_time_secs::numeric, 0), 2);

            ------------------------------------------------------------------
            -- Mark task finished
            ------------------------------------------------------------------
            UPDATE hivesense_app.block_tasks
               SET status      = 'done',
                   finished_at = clock_timestamp()
             WHERE task_id = __task.task_id;

            COMMIT; -- to let the scheduler and other workers see our progress
        END LOOP;

        -- Queue drained; loop back to waiting for the next batch.  Break
        -- conditions are evaluated in the wait loop above.
    END LOOP;

    ASSERT FALSE, 'Worker loop: unreachable';
END
$$;


RESET ROLE;

-- ============================================================================
-- HAF APPLICATION REGISTRY (haf#341)
-- ============================================================================
-- hivesense drives its own loop (the scheduler above, or the remote-sync
-- process), so it is registered without a process procedure. The dependency on
-- hivemind_app makes hive.app_next_iteration withhold every block hivemind has
-- not committed (hivemind reports its committed position through its
-- completed-block function, exact during massive sync as well), so the
-- scheduler's own hivemind wait loops normally find hivemind already there.
-- hivemind must already be registered (its install runs first).
SELECT hive.app_register( 'hivesense_app', ARRAY[ 'hivesense_app' ]::hive.contexts_group, NULL );
DO $$
BEGIN
  IF EXISTS ( SELECT 1 FROM hafd.applications WHERE name = 'hivemind_app' ) THEN
    PERFORM hive.app_add_dependency( 'hivesense_app', 'hivemind_app' );
  ELSE
    -- older hivemind: the scheduler's own hivemind wait loops still apply
    RAISE WARNING 'hivemind_app is not registered in the HAF application registry; hivesense_app runs without the dependency gate';
  END IF;
END
$$;

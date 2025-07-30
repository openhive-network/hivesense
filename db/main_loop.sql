SET ROLE hivesense_owner;

DO $BODY$
DECLARE
    __llm    TEXT := current_setting('pg_temp.LLM',       TRUE);
    __ollama TEXT := current_setting('pg_temp.OLLAMA_HOST', TRUE);
BEGIN
    EXECUTE format($$
        CREATE OR REPLACE FUNCTION hivesense_embed(_post TEXT)
            RETURNS vector
            IMMUTABLE
            LANGUAGE plpgsql
            PARALLEL SAFE
        AS
        $BODY2$
        BEGIN
            RETURN hivesense_app.ollama_embed('%s', _post, host => '%s');
        END;
        $BODY2$
    $$, __llm, __ollama);

    EXECUTE format($$
        CREATE OR REPLACE FUNCTION hivesense_embed(_posts hivesense_app.id_and_post_chunk[])
            RETURNS hivesense_app.post_and_vector_chunk[]
            IMMUTABLE
            LANGUAGE plpgsql
            PARALLEL SAFE
        AS
        $BODY2$
        BEGIN
            RETURN hivesense_app.ollama_embed('%s', _posts, host => '%s');
        END;
        $BODY2$
    $$, __llm, __ollama);
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
AS $$
DECLARE
    -- profiling variables
    __start_prep      TIMESTAMP := clock_timestamp();
    __start_embed     TIMESTAMP;
    __prep_time       DOUBLE PRECISION;
    __embed_time      DOUBLE PRECISION;

    -- stats
    __num_discards    INT;
    __processed_posts INT;
    __num_chunks      INT;
    __total_tokens    INT;

    __c                      INT;
    __tokenizer_name         TEXT;
    __max_tokens             INT;
    __min_new_ratio          REAL;
    __doc_prefix             TEXT;
    __min_token_threshold    INT;
    __max_embeddings_per_post INT;
    rec RECORD;
    __sync_seq INT;
BEGIN
    SET search_path = hivesense_app, public;
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

    /* =====================================================================
     * 0️⃣  PRE-PROCESS EVERY POST ONCE
     *     ---------------------------------
     *     We call preprocess_post with _min_token_threshold = 0 so we
     *     *always* get (token_count, chunks[]).  Later we decide whether
     *     the post is “big enough” (token_count ≥ __min_token_threshold).
     * ====================================================================*/
    CREATE TEMP TABLE tmp_pre ON COMMIT DROP AS
    SELECT
        hp.id        AS post_id,
        hp.block_num,
        COALESCE(pp.token_count, 0)            AS token_count,
        COALESCE(pp.chunks, ARRAY[]::TEXT[])   AS chunks
    FROM   unnest(_post_ids)          AS sel(id)
    JOIN   hivemind_app.hive_posts     hp  ON hp.id = sel.id
    LEFT   JOIN LATERAL preprocess_post(
               /* body ---------------------------------------------------- */
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
               0                      -- ← return *even if very short*
           ) AS pp
           ON TRUE;

    /* =====================================================================
     * CREATE CHUNKS FOR POSTS THAT ARE STILL “BIG ENOUGH”
     * ====================================================================*/
    CREATE TEMP TABLE tmp_chunks ON COMMIT DROP AS
    SELECT
        post_id,
        generate_subscripts(chunks, 1) - 1          AS chunk_number,
        chunks[generate_subscripts(chunks, 1)]      AS chunk_text,
        token_count,
        block_num
    FROM tmp_pre
    WHERE token_count >= __min_token_threshold
      AND array_length(chunks, 1) IS NOT NULL;


    -- measure prep time
    __prep_time := EXTRACT(EPOCH FROM clock_timestamp() - __start_prep);

    -- measure embed start
    __start_embed := clock_timestamp();

    /* =====================================================================
     * EMBED THOSE CHUNKSS
     * ====================================================================*/
    CREATE TEMP TABLE tmp_vectors ON COMMIT DROP AS
    WITH all_chunks AS (
        SELECT ARRAY_AGG(
                   (post_id, chunk_text, chunk_number)
                     ::hivesense_app.id_and_post_chunk
                   ORDER BY post_id, chunk_number
               ) AS arr
        FROM tmp_chunks
    )
    SELECT
        pv.post_id,
        pv.chunk_number,
        pv.vec
    FROM all_chunks
    CROSS JOIN LATERAL UNNEST(hivesense_app.hivesense_embed(all_chunks.arr)) AS pv;


    -- measure embed time
    __embed_time := EXTRACT(EPOCH FROM clock_timestamp() - __start_embed);

    /* COUNT STATISTICS */
    SELECT COUNT(*) INTO __num_discards FROM tmp_pre WHERE token_count < __min_token_threshold OR array_length(chunks, 1) IS NULL;
    SELECT COUNT(DISTINCT post_id) INTO __processed_posts FROM tmp_chunks;
    SELECT COUNT(*) INTO __num_chunks FROM tmp_vectors;
    SELECT COALESCE(SUM(token_count),0) INTO __total_tokens FROM tmp_pre WHERE token_count >= __min_token_threshold;

    /* =====================================================================
     * POSTS THAT NOW PRODUCE ZERO CHUNKS
     * (true deletions / under-threshold edits)
     * ====================================================================*/
    CREATE TEMP TABLE tmp_empty_posts ON COMMIT DROP AS
    SELECT post_id,
           block_num,
           token_count
    FROM   tmp_pre
    WHERE  token_count <  __min_token_threshold
       OR  array_length(chunks,1) IS NULL;

    /* nothing to do if no deletions */
    IF EXISTS (SELECT 1 FROM tmp_empty_posts) THEN

        /* ➤ fresh sync_seq for every empty post */
        CREATE TEMP TABLE tmp_empty_seq ON COMMIT DROP AS
        SELECT post_id,
               nextval('hivesense_app.sync_seq') AS sync_seq
        FROM   tmp_empty_posts;

        /* ➤ delete lingering vectors */
        DELETE FROM hivesense_app.posts_vectors pv
        USING  tmp_empty_posts ep
        WHERE  pv.post_id = ep.post_id;

        /* ➤ record the logical deletion */
        INSERT INTO hivesense_app.deleted_embeddings(post_id, sync_seq)
        SELECT post_id, sync_seq
        FROM   tmp_empty_seq;

        /* ➤ bring post_data up to date */
        INSERT INTO hivesense_app.post_data(post_id, number_of_tokens, last_vectors_block)
        SELECT post_id, token_count, block_num
        FROM   tmp_empty_posts
        ON CONFLICT (post_id) DO UPDATE
            SET number_of_tokens   = EXCLUDED.number_of_tokens,
                last_vectors_block = EXCLUDED.last_vectors_block;
    END IF;

    -- 3) per-post sync_seq, delete & insert
    FOR rec IN
      SELECT DISTINCT post_id, block_num,
             MAX(token_count) AS tcnt
        FROM tmp_chunks
       GROUP BY post_id, block_num
    LOOP
        SELECT nextval('hivesense_app.sync_seq') INTO __sync_seq;

        IF EXISTS (
           SELECT 1 FROM hivesense_app.posts_vectors
            WHERE post_id = rec.post_id
        ) THEN
            DELETE FROM hivesense_app.posts_vectors
             WHERE post_id = rec.post_id;
            INSERT INTO hivesense_app.deleted_embeddings(post_id, sync_seq)
            VALUES (rec.post_id, __sync_seq);
        END IF;

        INSERT INTO hivesense_app.posts_vectors(
            post_id, chunk_number, embedding, sync_seq
        )
        SELECT
          post_id,
          chunk_number,
          CASE WHEN hivesense_app.store_halfvec_embeddings()
               THEN vec::public.halfvec
               ELSE vec
          END,
          __sync_seq
        FROM tmp_vectors
        WHERE post_id = rec.post_id
        ORDER BY chunk_number;

        IF hivesense_app.use_reduced_embeddings() THEN
            INSERT INTO hivesense_app.posts_vectors_reduced(
                post_id, chunk_number, reduced_embedding
            )
            SELECT
                post_id,
                chunk_number,
                CASE
                    WHEN hivesense_app.store_halfvec_embeddings()
                         THEN hivesense_app.reduce_embedding(vec::public.vector)::public.halfvec
                    ELSE hivesense_app.reduce_embedding(vec::public.vector)
                END
            FROM tmp_vectors
            WHERE post_id = rec.post_id
            ORDER BY chunk_number;
        END IF;

        GET DIAGNOSTICS __c = ROW_COUNT;

        UPDATE hivesense_app.post_data
           SET number_of_tokens   = rec.tcnt,
               last_vectors_block = rec.block_num
         WHERE post_id = rec.post_id;
    END LOOP;

    /* RETURN PROFILING STATS */
    RETURN (__num_discards, __processed_posts, __num_chunks, __total_tokens, __prep_time, __embed_time);
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
  __head_of_irreversible_block INT;
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

CREATE OR REPLACE PROCEDURE hivesense_app.wait_for_advisory_lock(_namespace INT, _worker INT, _timeout_ms INT DEFAULT 5000)
LANGUAGE plpgsql
AS $$
BEGIN
  LOOP
    -- a) close out any open tx so xmin can advance
    COMMIT;
    -- b) bound our blocking lock to _timeout_ms
    PERFORM set_config('lock_timeout', _timeout_ms::text, true);

    BEGIN
      -- c) normal blocking advisory lock
      PERFORM pg_advisory_lock(_namespace, _worker);
      -- d) on success, clear the timeout and stop looping
      PERFORM set_config('lock_timeout', '0', true);
      EXIT;
    EXCEPTION
      WHEN SQLSTATE '55P03'  -- lock_timeout
       OR  SQLSTATE '57014'  -- statement_timeout
      THEN
        -- If the race gave us the lock just as the timeout fired,
        -- detect it in pg_locks, clear timeout, and exit.
        IF EXISTS (SELECT FROM pg_locks
           WHERE locktype = 'advisory'
             AND classid  = _namespace
             AND objid    = _worker
             AND pid      = pg_backend_pid()
        ) THEN
          PERFORM set_config('lock_timeout', '0', true);
          EXIT;
        END IF;
        -- otherwise fall through to retry
    END;
  END LOOP;
END;
$$;


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
    __advisory_lock_namespace_begin INT;
    __start_key_namespace           INT;
    __done_key_namespace            INT;
    __ack_key_namespace             INT;
    __shard                         INT;
    __posts_per_chunk      CONSTANT INT := 100;

    __current_syncing               BOOLEAN;
    __current_uuid                  UUID;
    __new_uuid                      UUID;
BEGIN
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
    SELECT start_block, advisory_lock_namespace_begin INTO __start_block, __advisory_lock_namespace_begin
    FROM   hivesense_app.hivesense_app_status;

    __start_key_namespace := __advisory_lock_namespace_begin;
    __done_key_namespace := __advisory_lock_namespace_begin + 1;
    __ack_key_namespace := __advisory_lock_namespace_begin + 2;

    --------------------------------------------------------------------------------
    -- **At initialization: acquire every start_key_i** so that workers block.
    --
    --     Here, we grab start_key_i and ack_key_i.  done_key_i is left unlocked,
    --     so that as soon as a worker tries to lock it at loop-top, it succeeds.
    --------------------------------------------------------------------------------
    FOR __shard IN 1.._workers LOOP
        PERFORM pg_advisory_lock(__start_key_namespace, __shard);  -- hold start_key_i
        PERFORM pg_advisory_lock(__ack_key_namespace, __shard);  -- hold ack_key_i
    END LOOP;

    RAISE NOTICE 'Scheduler: start_keys locked for all % workers; entering main loop...', _workers;

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
            -- RAISE NOTICE '__blocks_range IS NULL';
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

        COMMIT;            -- let workers see tasks

        --------------------------------------------------------------------------------
        -- WAKE ALL WORKERS by dropping each start_key_i
        --
        -- After that, each worker will:
        --   • acquire start_key_i (unblocks them)
        --   • then (below) will do their FCFS pulls until the queue is empty,
        --   • then signal back on done_key_i.
        --------------------------------------------------------------------------------
        FOR __shard IN 1.._workers LOOP
            PERFORM pg_advisory_unlock(__start_key_namespace, __shard);
        END LOOP;

        --------------------------------------------------------------------------------
        -- Wait for each worker to finish, then ACK it, all in one consistent order:
        --   1) BLOCK on done_key_i   (i.e. wait until worker UNLOCKs it)
        --   2) immediately UNLOCK done_key_i  (reset it for next iteration)
        --   3) UNLOCK  ack_key_i   (tell the worker “I saw your done”)
        --   4) BLOCK on ack_key_i   (re‐grab it so it’s once again held by scheduler)
        --   5) Now lock start_key_i so that worker will block at next loop
        --
        -- At no point do we do “LOCK(done_key_i); LOCK(start_key_i);”.
        -- We do it in the order:  LOCK(done_key_i) → UNLOCK(done_key_i) → UNLOCK(ack_key_i) → LOCK(ack_key_i) → LOCK(start_key_i)
        --------------------------------------------------------------------------------
        FOR __shard IN 1.._workers LOOP

          -- Wait for worker_i to signal “done”:
          -- PERFORM pg_advisory_lock(__done_key_namespace, __shard);
          CALL hivesense_app.wait_for_advisory_lock(__done_key_namespace, __shard);

          -- Immediately drop done_key_i so that next time the worker can LOCK it:
          PERFORM pg_advisory_unlock(__done_key_namespace, __shard);

          -- ACK the worker’s “done” by unlocking ack_key_i
          PERFORM pg_advisory_unlock(__ack_key_namespace, __shard);

          -- re‐grab ack_key_i so that the next time the worker tries to LOCK it, it will block
          PERFORM pg_advisory_lock(__ack_key_namespace, __shard);

          -- Pre‐lock start_key_i again so that the worker will block on it next loop
          PERFORM pg_advisory_lock(__start_key_namespace, __shard);
        END LOOP;

        -------------------------------------------------------------------
        -- Wait until the whole batch finishes
        -- the locks should guarantee that the batch has already finished,
        -- this is a double-check
        -------------------------------------------------------------------
        LOOP
            -- RAISE NOTICE 'SCHEDULER: checking whether all shards are done...';
            SELECT COUNT(*) INTO __todo
            FROM   hivesense_app.block_tasks
            WHERE  batch_id = __batch_id
              AND  status  <> 'done';

            EXIT WHEN __todo = 0;
            RAISE NOTICE 'SCHEDULER: Error -- scheduler was woken up but job queue is not empty...';
            RAISE NOTICE 'SCHEDULER: switching to polling...';
            PERFORM pg_sleep(0.1);
            --PERFORM pg_sleep(5);
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

        -- At this point, for EVERY i:
        --   • start_key_i is back under scheduler’s control (since the worker did UNLOCK then we never dropped it again),
        --   • done_key_i is free (we just dropped it in step 3.E.2),
        --   • ack_key_i is back under scheduler’s control (we locked it again in 3.E.4).
        -- Everything is reset for the next side‐by‐side handshake.
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
    __advisory_lock_namespace_begin INT;
    __start_key_namespace           INT;
    __done_key_namespace            INT;
    __ack_key_namespace             INT;
BEGIN
    SELECT advisory_lock_namespace_begin INTO __advisory_lock_namespace_begin
    FROM   hivesense_app.hivesense_app_status;

    __start_key_namespace := __advisory_lock_namespace_begin;
    __done_key_namespace := __advisory_lock_namespace_begin + 1;
    __ack_key_namespace := __advisory_lock_namespace_begin + 2;

    -- by default, postgresql logs when threads are blocked on a lock for more than a second.
    -- we use locks for synchronization, and expect threads to be blocked for at least 3s
    -- at a time.  Disable that logging to avoid spamming the log file
    --
    -- turns out we need higher privileges to do this, skip for now
    --
    -- PERFORM set_config('deadlock_timeout', '5s', true);
    -- PERFORM set_config('log_lock_waits',    'off',  true);
    -- workers run forever until break conditions tell them to exit
    LOOP
        --------------------------------------------------------------------
        -- Take done_key_i (never blocks for long)
        --------------------------------------------------------------------
        PERFORM pg_advisory_lock(__done_key_namespace, _worker);

        --------------------------------------------------------------------------------
        -- Now block until the scheduler says “go” by unlocking start_key_i.
        -- As soon as that happens, we acquire start_key_i.
        --------------------------------------------------------------------------------
        CALL hivesense_app.wait_for_advisory_lock(__start_key_namespace, _worker);

        --------------------------------------------------------------------------------
        -- Immediately release start_key_i so it’s available for the next batch.
        --------------------------------------------------------------------------------
        PERFORM pg_advisory_unlock(__start_key_namespace, _worker);

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
              'worker % profile: discarded_posts=% processed_posts=% embedding_chunks=% total_tokens=% prep_time=%s embed_time=%s tokens_per_sec=%',
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

        --------------------------------------------------------------------------------
        -- We have emptied the queue (or hit break conditions).
        --     Signal “I’m done” by UNLOCKing done_key_i.
        --------------------------------------------------------------------------------
        PERFORM pg_advisory_unlock(__done_key_namespace, _worker);

        -- Now block on ack_key_i until the scheduler “acks” our done_key_i.
        CALL hivesense_app.wait_for_advisory_lock(__ack_key_namespace, _worker);
        -- As soon as the scheduler does `UNLOCK(ack_key_i)`, this returns.

        --------------------------------------------------------------------------------
        -- Immediately release ack_key_i so that the scheduler can lock it for the next iteration
        --------------------------------------------------------------------------------
        PERFORM pg_advisory_unlock(__ack_key_namespace, _worker);

        __breaking_reason := isbreakingpending(_app_context_name, _max_block_limit, NULL);
        IF __breaking_reason IS NOT NULL THEN
          RETURN;
        END IF;
    END LOOP;

    ASSERT FALSE, 'Worker loop: unreachable';
END
$$;


RESET ROLE;

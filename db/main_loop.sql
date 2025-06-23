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

CREATE OR REPLACE FUNCTION hivesense_block_range_data(
    _first_block_num INT,
    _last_block_num  INT,
    _logs            BOOLEAN,
    _worker          INT
)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
PARALLEL SAFE
AS $$
DECLARE
    __start_ts               timestamptz;
    __end_ts                 timestamptz;
    __number_of_posts        INT := 0;    -- counter for this run
    __number_of_chunks       INT := 0;    -- counter for this run
    __c                      INT;        -- temp for ROW_COUNT

    __number_of_workers             INT;
    __tokenizer_name                TEXT;
    __max_tokens                    INT;
    __min_new_ratio                 REAL;
    __lang_model                    TEXT;
    __doc_prefix                    TEXT;
    __min_token_threshold           INT;
    __max_embeddings_per_post       INT;
    __advisory_lock_namespace_begin INT;

    __post_id_lock_namespace        INT;

    -- for the FOR loop
    rec RECORD;
    __prev_block INT;
    __sync_seq            INT;        -- seq that orders insert / delete ops

    __lock_start    timestamptz;
    __lock_end      timestamptz;
    __wait_interval interval;
BEGIN
    ASSERT _first_block_num <= _last_block_num, 'Invalid range of blocks';

    SELECT parallel_workers,
           tokenizer_model,
           tokens_per_chunk,
           1 - overlap_amount,
           sentence_language_model,
           document_prefix,
           min_token_threshold,
           max_embeddings_per_post,
           advisory_lock_namespace_begin
      INTO __number_of_workers,
           __tokenizer_name,
           __max_tokens,
           __min_new_ratio,
           __lang_model,
           __doc_prefix,
           __min_token_threshold,
           __max_embeddings_per_post,
          __advisory_lock_namespace_begin
    FROM hivesense_app.hivesense_app_status
    WHERE id = 1;

    ASSERT __number_of_workers IS NOT NULL, 'NULL number of workers';
    ASSERT __number_of_workers > 0 , 'number of workers less than 1';

    __post_id_lock_namespace := __advisory_lock_namespace_begin + 3;

    -- TODO(mickiewicz@syncad.com) when hivemind is not in a live stage then do not process
    -- maybe it is not required because last_completed in enough ?
    -- but last completed does not guaranteen index on block_num_created, but maybe this is an edge case
    --IF hive.get_current_stage_name( 'hivemind_app' ) != 'live' THEN
    --    RETURN NULL;
    --END IF;

    IF _logs THEN
        IF _first_block_num = _last_block_num THEN
            RAISE NOTICE 'worker % is processing block %', _worker, _first_block_num;
        ELSE
            RAISE NOTICE 'worker % is processing block range: <%, %>', _worker, _first_block_num, _last_block_num;
        END IF;
        __start_ts := clock_timestamp();
    END IF;

    -- The preprocessing step is pretty expensive.  Way cheaper than generating embeddings, of course, but 
    -- still more expensive than postgres thinks.  If we're not really careful about our CTEs below, 
    -- postgresql will happily preprocess posts multiple times.  Instead, we don't let it, explicitly
    -- preprocessing into a temp table here
    CREATE TEMP TABLE tmp_posts_to_vectorize (
        post_id      INT   PRIMARY KEY,
        bodies       TEXT[],
        token_count  INT,
        block_num    INT
    ) ON COMMIT DROP;

    INSERT INTO tmp_posts_to_vectorize(post_id, bodies, token_count, block_num)
    SELECT
      hp.id,
      pp.chunks,
      pp.token_count,
      hp.block_num
    FROM hivemind_app.hive_posts   AS hp
    JOIN hivemind_app.hive_post_data AS hpd ON hpd.id = hp.id
    CROSS JOIN LATERAL (
      SELECT *
      FROM preprocess_post(
               hpd.title || '.\n\n' || hpd.body,
               hp.id,
               '[permlink disabled]',
               __tokenizer_name,
               __max_tokens,
               __min_new_ratio,
               __lang_model,
               __max_embeddings_per_post,
               TRUE,               -- _truncate_long_sentences
               __doc_prefix,
               __min_token_threshold
             )
    ) AS pp(chunks, token_count)
    WHERE (hp.root_id = hp.id OR hp.root_id = 0)
      AND (
           hp.block_num_created BETWEEN _first_block_num AND _last_block_num
        OR hp.block_num          BETWEEN _first_block_num AND _last_block_num
      );

    -- ◉◉◉ PER-POST LOOP WITH SERIALIZATION ◉◉◉
    FOR rec IN
      SELECT post_id, bodies, token_count, block_num
        FROM tmp_posts_to_vectorize
       ORDER BY post_id
    LOOP
      -- grab an transaction‐scoped advisory lock in our own namespace to ensure no other workers
      -- are working on this same post while we are
      -- Try to grab the lock immediately
      IF NOT pg_try_advisory_xact_lock(__post_id_lock_namespace, rec.post_id) THEN
          -- If it failed, we know there’s contention: measure how long it takes to acquire
          __lock_start := clock_timestamp();
          PERFORM pg_advisory_xact_lock(__post_id_lock_namespace, rec.post_id);
          __lock_end := clock_timestamp();

          -- Compute and log any non-zero wait
          __wait_interval := __lock_end - __lock_start;
          IF __wait_interval > '0s' THEN
              RAISE NOTICE
                'worker % was blocked waiting to work on post % for %s seconds',
                _worker,
                rec.post_id,
                to_char(EXTRACT(EPOCH FROM __wait_interval), 'FM999999.000');
          END IF;
      END IF;

      SELECT last_vectors_block
        INTO __prev_block
        FROM hivesense_app.post_data
       WHERE post_id = rec.post_id;

      IF rec.block_num > COALESCE(__prev_block, -1) THEN
        -- Reserve a sequence value that will identify this logical operation
        SELECT nextval('hivesense_app.sync_seq') INTO __sync_seq;

        __number_of_posts := __number_of_posts + 1;

        -- Was the post previously embedded?  If so, log a delete operation
        IF EXISTS (
            SELECT 1 FROM hivesense_app.posts_vectors
             WHERE post_id = rec.post_id
        ) THEN
            DELETE FROM hivesense_app.posts_vectors
             WHERE post_id = rec.post_id;

            INSERT INTO hivesense_app.deleted_embeddings(post_id, sync_seq)
            VALUES (rec.post_id, __sync_seq);
        END IF;

        -- generate & insert new embeddings
        INSERT INTO hivesense_app.posts_vectors(post_id, chunk_number, embedding, sync_seq)
        SELECT
          (pv).post_id,
          (pv).chunk_number,
          CASE
            WHEN hivesense_app.store_halfvec_embeddings()
            THEN (pv).vec::public.halfvec
            ELSE (pv).vec
          END,
          __sync_seq
        FROM (
          SELECT UNNEST(
            hivesense_app.hivesense_embed(
              ARRAY(
                SELECT (rec.post_id, rec.bodies[idx], idx-1)
                       ::hivesense_app.id_and_post_chunk
                  FROM generate_subscripts(rec.bodies,1) AS idx
              )
            )
          ) AS pv
        ) AS sub;

        -- count how many chunks we just wrote
        GET DIAGNOSTICS __c = ROW_COUNT;
        __number_of_chunks := __number_of_chunks + __c;

        -- bump metadata to block_num
        UPDATE hivesense_app.post_data
           SET number_of_tokens   = COALESCE(rec.token_count, 0),
               last_vectors_block = rec.block_num
         WHERE post_id = rec.post_id;
      END IF;
    END LOOP;

    DROP TABLE tmp_posts_to_vectorize;

    RETURN COALESCE(__number_of_posts, 0);
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

/** Application entry point, which starts application main-loop (which iterates infinitely).
  To stop it call `stopProcessing();` from another session and commit its trasaction.
*/
CREATE OR REPLACE PROCEDURE hivesense_app.scheduler(
    IN  _app_context_base_name  hive.context_name,
    IN  _workers                INT,
    IN  _max_block_limit        INT      DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    __hivemind_current_block        INT;
    __context_name                  hive.context_name := _app_context_base_name; -- single context
    __start_block                   INT               := 0;
    __blocks_range                  hive.blocks_range := (0,0);
    __batch_id                      BIGINT;
    __todo                          INT;
    __breaking_reason               break_reason      := NULL;
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
BEGIN
    -- by default, postgresql logs when threads are blocked on a lock for more than a second.
    -- we use locks for synchronization, and expect threads to be blocked for at least 3s
    -- at a time.  Disable that logging to avoid spamming the log file
    --
    -- turns out we need higher privileges to do this, skip for now
    --
    -- PERFORM set_config('deadlock_timeout', '5s', true);
    -- PERFORM set_config('log_lock_waits',    'off',  true);

    -- read configured start_block
    SELECT start_block, advisory_lock_namespace_begin INTO __start_block, __advisory_lock_namespace_begin
    FROM   hivesense_app.hivesense_app_status;

    __start_key_namespace := __advisory_lock_namespace_begin;
    __done_key_namespace := __advisory_lock_namespace_begin + 1;
    __ack_key_namespace := __advisory_lock_namespace_begin + 2;

    --------------------------------------------------------------------------------
    -- **At initialization: acquire every start_key_i** so that workers block.
    --
    --     We'll define:
    --       start_key_i := 10_000_000 + i
    --       done_key_i  := 20_000_000 + i
    --       ack_key_i   := 30_000_000 + i

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
        -- request the next range from HAF
        CALL hive.app_next_iteration(
            __context_name,
            __blocks_range,
            _override_max_batch => NULL,
            _limit              => _max_block_limit
        );

        -- RAISE NOTICE 'App_next_iteration returned';

        -- check global break conditions
        __breaking_reason := isbreakingpending(
                                 __context_name,
                                 _max_block_limit,
                                 __blocks_range);
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

        -- ── NEW: wait until hivemind has processed through this range ───────────────
        LOOP
            SELECT hive.app_get_current_block_num('hivemind_app')
              INTO __hivemind_current_block;
            EXIT WHEN __hivemind_current_block >= __blocks_range.last_block;
            RAISE NOTICE 'Waiting for hivemind to reach block % (currently at %)',
                         __blocks_range.last_block,
                         __hivemind_current_block;
            PERFORM pg_sleep(1);
        END LOOP;

        -------------------------------------------------------------------
        -- Split the range into contiguous slices and enqueue one per shard
        -------------------------------------------------------------------
        __blocks             := __blocks_range.last_block - __blocks_range.first_block + 1;
        __chunks_per_worker  := 50;
        __number_of_chunks   := _workers * __chunks_per_worker;
        __blocks_per_chunk   := GREATEST(1, CEILING(__blocks / (_workers * __chunks_per_worker)));
        __extra              := __blocks % __number_of_chunks;      -- first ⟂extra⟂ chunks get +1

        __batch_id := nextval('hivesense_app.batch_seq');
        __from_block := __blocks_range.first_block;

        IF __blocks_range.last_block <> __blocks_range.first_block THEN
            RAISE NOTICE 'Splitting range % to %', __blocks_range.first_block, __blocks_range.last_block;
        END IF;

        WHILE __from_block <= __blocks_range.last_block LOOP
            -- RAISE NOTICE 'SCHEDULER: computing work for';
            __to_block := __from_block + __blocks_per_chunk - 1;
            IF __extra > 0 THEN
                __to_block := __to_block + 1;
                __extra := __extra - 1;
            END IF;

            IF __to_block > __blocks_range.last_block THEN
                __to_block := __blocks_range.last_block;
            END IF;

            -- only insert if this worker actually has work
            IF __to_block >= __from_block THEN
                -- RAISE NOTICE 'SCHEDULER: enqueuing work [%, %]', __from_block, __to_block;
                INSERT INTO hivesense_app.block_tasks(
                    batch_id,
                    shard,
                    first_block,
                    last_block
                )
                VALUES (
                    __batch_id,
                    NULL, -- unclaimed
                    __from_block,
                    __to_block
                );
            END IF;

            __from_block := __to_block + 1;
        END LOOP;
        --------------------------------------------------------------------------------
        -- bulk-upsert post_data for every post in this batch
        --------------------------------------------------------------------------------
        WITH posts_to_seed AS (
          SELECT DISTINCT hp.id AS post_id
          FROM   hivemind_app.hive_posts    hp
          JOIN   hivemind_app.hive_post_data hpd ON hpd.id = hp.id
          WHERE  (hp.root_id = hp.id OR hp.root_id = 0)
            AND (
                 hp.block_num_created BETWEEN __blocks_range.first_block AND __blocks_range.last_block
              OR hp.block_num          BETWEEN __blocks_range.first_block AND __blocks_range.last_block
            )
        )
        INSERT INTO hivesense_app.post_data(post_id, number_of_tokens, last_vectors_block)
        SELECT post_id, 0, -1
          FROM posts_to_seed
        ON CONFLICT (post_id) DO NOTHING;

        COMMIT; -- we have to commit here so the workers can pick up the tasks

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
          PERFORM pg_advisory_lock(__done_key_namespace, __shard);

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
    __done_posts                    INT;
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
        --------------------------------------------------------------------------------
        -- Grab done_key_i so scheduler can wait on it later.  This succeeds 
        -- immediately the very first time (because we left done_key_i unlocked).
        --------------------------------------------------------------------------------
        PERFORM pg_advisory_lock(__done_key_namespace, _worker);

        --------------------------------------------------------------------------------
        -- Now block until the scheduler says “go” by unlocking start_key_i.
        -- As soon as that happens, we acquire start_key_i.
        --------------------------------------------------------------------------------
        PERFORM pg_advisory_lock(__start_key_namespace, _worker);

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
                   first_block,
                   last_block
            INTO   __task
            FROM   hivesense_app.block_tasks
            WHERE  status = 'pending'
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
            SELECT hivesense_block_range_data(
                       __task.first_block,
                       __task.last_block,
                       TRUE,             -- logs
                       _worker           -- keep original param order
                   )
                   INTO __done_posts;

            IF __task.last_block = __task.first_block THEN
                RAISE NOTICE 'worker % processed block % containing % posts', _worker, __task.first_block, __done_posts;
            ELSE
                RAISE NOTICE 'worker % processed block range % to % (% blocks) containing % posts', _worker, __task.first_block, __task.last_block, __task.last_block - __task.first_block + 1, __done_posts;
            END IF;

            -- If Hivemind isn’t caught up yet → rollback & wait0
            IF __done_posts IS NULL THEN
                ROLLBACK;
                PERFORM pg_sleep(5);
                CONTINUE;
            END IF;

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
        PERFORM pg_advisory_lock(__ack_key_namespace, _worker);
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

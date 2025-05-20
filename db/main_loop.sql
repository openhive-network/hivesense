SET ROLE hivesense_owner;

DO $BODY$
    DECLARE
        __llm TEXT := current_setting('pg_temp.LLM', TRUE);
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
        CREATE OR REPLACE FUNCTION hivesense_embed(_posts hivesense_app.id_and_post[])
        RETURNS hivesense_app.post_and_vector[]
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
END $BODY$;



CREATE OR REPLACE FUNCTION hivesense_block_range_data(
    _first_block_num INT,
    _last_block_num INT,
    _logs BOOLEAN,
    _worker INT
)
RETURNS INT  -- NULL need to wait for hivemind, otherwise number of vectorized posts
LANGUAGE plpgsql
VOLATILE
PARALLEL SAFE
AS $$
DECLARE
    __hivemind_current_block INT;
    __start_ts timestamptz;
    __end_ts   timestamptz;
    __number_of_posts INT;
    __number_of_chunks INT;

    __number_of_workers INT;
    __tokenizer_name TEXT;
    __max_tokens INT;
    __min_new_ratio REAL;
    __lang_model TEXT;
BEGIN
    ASSERT _first_block_num <= _last_block_num, 'Invalid range of blocks';

    -- will RAISE when hivemind context does not exist
    SELECT last_completed_block_num FROM hivemind_app.hive_state INTO __hivemind_current_block;
    SELECT parallel_workers FROM hivesense_app_status INTO __number_of_workers;

    SELECT tokenizer_model FROM hivesense_app_status INTO __tokenizer_name;
    SELECT tokens_per_chunk FROM hivesense_app_status INTO __max_tokens;
    SELECT 1 - overlap_amount FROM hivesense_app_status INTO __min_new_ratio;
    SELECT sentence_language_model FROM hivesense_app_status INTO __lang_model;

    ASSERT __number_of_workers IS NOT NULL, 'NULL number of workers';
    ASSERT __number_of_workers > 0 , 'number of workers less than 1';


    -- hivemind exists
    IF __hivemind_current_block < _first_block_num THEN
        RETURN NULL;
    END IF;

    IF __hivemind_current_block < _last_block_num THEN
        RETURN NULL;
    END IF;

    -- TODO(mickiewicz@syncad.com) when hivemind is not in a live stage then do not process
    -- maybe it is not required because last_completed in enough ?
    -- but last completed does not guaranteen index on block_num_created, but maybe this is an edge case
    --IF hive.get_current_stage_name( 'hivemind_app' ) != 'live' THEN
    --    RETURN NULL;
    --END IF;

    IF _logs THEN
        RAISE NOTICE 'Hivesense % is attempting to process a block range: <%, %>', _worker, _first_block_num, _last_block_num;
        __start_ts := clock_timestamp();
    END IF;

    WITH posts AS (
        SELECT hp.id as post_id, preprocess_post( hpd.title || '.\n\n' || hpd.body, __tokenizer_name, __max_tokens, __min_new_ratio, __lang_model, 3 ) as bodies
        FROM hivemind_app.hive_posts as hp
                 JOIN hivemind_app.hive_post_data as hpd ON hpd.id = hp.id
        WHERE hp.id=hp.root_id
        AND hp.block_num_created BETWEEN _first_block_num AND _last_block_num
        AND __number_of_workers - (hp.id % __number_of_workers )  = _worker
    ), id_and_body_agg AS (
        SELECT ARRAY_AGG( (p.post_id, p.bodies)::hivesense_app.id_and_post ) as id_and_body
        FROM posts p
        WHERE p.bodies IS NOT NULL
    ), embeddings AS (
        SELECT (id_vector).post_id as post_id, (id_vector).vec as embedding
        FROM (
                 SELECT UNNEST(hivesense_embed(ibagg.id_and_body)) AS id_vector
                 FROM id_and_body_agg ibagg
                 WHERE CARDINALITY(ibagg.id_and_body) > 0
             ) AS subquery
    ), insert_to AS (
        INSERT INTO hivesense_app.posts_vectors (post_id, embedding)
            SELECT emb.post_id, emb.embedding
            FROM embeddings emb
    ) SELECT (SELECT CARDINALITY(id_and_body) FROM id_and_body_agg ), (SELECT COUNT(*) FROM embeddings) INTO __number_of_posts, __number_of_chunks;

    __number_of_posts = COALESCE( __number_of_posts, 0 );
    __number_of_chunks = COALESCE( __number_of_chunks, 0 );

    IF _logs THEN
        __end_ts := clock_timestamp();
        RAISE NOTICE 'Hivesense % processed block range: <%, %> with % roots posts and % total chunks successfully in % s
    ', _worker, _first_block_num, _last_block_num, __number_of_posts, __number_of_chunks, (extract(epoch FROM __end_ts - __start_ts));
    END IF;

    RETURN __number_of_posts;
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

/** Application entry point, which:
  - defines its data schema,
  - creates HAF application context,
  - starts application main-loop (which iterates infinitely).
  - To stop it call `stopProcessing();` from another session and commit its trasaction.
*/
CREATE OR REPLACE PROCEDURE main(
    IN _appContextBaseName hive.CONTEXT_NAME,
    IN _worker INT,
    IN _maxBlockLimit INT = null
)
LANGUAGE plpgsql
AS
$$
DECLARE
  _blocks_range hive.blocks_range := (0,0);
  __number_of_posts INT;
  __context_name hive.context_name := _appContextBaseName || _worker;
  __start_block INT := 0;
  __breaking_reason break_reason := NULL;
BEGIN
  SELECT start_block INTO __start_block
  FROM hivesense_app_status;

  IF _maxBlockLimit != NULL THEN
    RAISE NOTICE 'Max block limit is specified as: %', _maxBlockLimit;
  END IF;

  PERFORM allowProcessing();
  
  RAISE NOTICE 'Last block processed by application %: %', __context_name, hive.app_get_current_block_num(__context_name);

  RAISE NOTICE 'Entering application main loop...';

  IF hive.app_get_current_block_num(__context_name) < __start_block - 1 THEN
    PERFORM hive.app_set_current_block_num( __context_name, __start_block - 1 );
  END IF;

  LOOP

    IF NOT wait_for_start_block( __start_block, _worker, __context_name ) THEN
        CONTINUE;
    END IF;

    CALL hive.app_next_iteration(
      __context_name,
      _blocks_range, 
      _override_max_batch => NULL, 
      _limit => _maxBlockLimit);

    __breaking_reason = isBreakingPending( __context_name, _maxBlockLimit, _blocks_range );
    IF __breaking_reason IS NOT NULL THEN
        ROLLBACK;
        IF __breaking_reason = 'BLOCK_LIMIT_REACHED' THEN
            IF _worker = 1 AND _maxBlockLimit IS NOT NULL AND hive.app_get_current_block_num(__context_name) >= _maxBlockLimit THEN
                CALL ensure_indexes_are_created();
            END IF;
        END IF;
        RETURN;
    END IF;

    -- some global actions are reserved only for the first worker
    IF _worker = 1 THEN
        IF hive.get_current_stage_name(__context_name) = 'live'  THEN
            CALL ensure_indexes_are_created();
        END IF;

        IF _blocks_range IS NULL THEN
            -- avoid logging from all workers because it is to verbose
            RAISE INFO 'Waiting for next block...';
        END IF;
    END IF;

    IF _blocks_range IS NULL THEN
        CONTINUE;
    END IF;

    CALL hivesense_process_blocks(__context_name, _blocks_range, _worker, __number_of_posts);
    IF  __number_of_posts IS NULL  THEN
        ROLLBACK;
        PERFORM pg_sleep( 5 ); -- wait for hivemind
    END IF;
  END LOOP;

  ASSERT FALSE, 'Cannot reach this point';
END
$$;


RESET ROLE;

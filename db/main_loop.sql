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
        AS
		$BODY2$
        BEGIN
            RETURN ai.ollama_embed('%s', _post, host => '%s');
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
    LANGUAGE 'plpgsql'
    VOLATILE
AS $$
DECLARE
    __hivemind_current_block INT;
    __start_ts timestamptz;
    __end_ts   timestamptz;
    __number_of_posts INT;
    __number_of_workers INT;
BEGIN
    ASSERT _first_block_num <= _last_block_num, 'Invalid range of blocks';

    -- will RAISE when hivemind context does not exist
    -- TODO(mickiewicz@syncad.com): customize hivemind context
    SELECT last_completed_block_num FROM hivemind_app.hive_state INTO __hivemind_current_block;
    SELECT parallel_workers FROM hivesense_app_status INTO __number_of_workers;

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

    -- TODO(mickiewicz@syncad.com): parametrize ollama address
    -- TODO(mickiewicz@syncad.com): parametrize hivemind schema
    -- TODO(mickiewicz@syncad.com): parametrize LLM model

    WITH vectorize AS(
            INSERT INTO posts_vectors (post_id, embedding)
            SELECT
                posts.id,
                hivesense_embed( posts.body )
            FROM (
                     SELECT ROW_NUMBER() OVER (ORDER BY hp.id) AS row_id, hp.id, clean_content( hpd.body ) as body
                     FROM hivemind_app.hive_posts as hp
                     JOIN hivemind_app.hive_post_data as hpd ON hpd.id = hp.id
                     WHERE hp.id=hp.root_id
                     AND hp.block_num_created BETWEEN _first_block_num AND _last_block_num
                     ORDER by hp.id
            ) AS posts
            WHERE __number_of_workers - (posts.row_id % __number_of_workers )  = _worker
            AND posts.body IS NOT NULL
            AND posts.body != ''
            RETURNING 1
    )
    SELECT COUNT(*) FROM vectorize INTO __number_of_posts;

    __number_of_posts = COALESCE( __number_of_posts, 0 );

    IF _logs THEN
        __end_ts := clock_timestamp();
        RAISE NOTICE 'Hivesense % processed block range: <%, %> with % roots posts successfully in % s
    ', _worker, _first_block_num, _last_block_num, __number_of_posts, (extract(epoch FROM __end_ts - __start_ts));
    END IF;

    RETURN __number_of_posts;
END;
$$;



CREATE OR REPLACE PROCEDURE hivesense_massive_processing(
    IN _from INT, IN _to INT, IN _logs BOOLEAN, IN _worker INT, OUT _done INT
)
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  PERFORM set_config('synchronous_commit', 'OFF', false);

  SELECT hivesense_block_range_data(_from, _to, _logs, _worker) INTO _done;
END
$$;

CREATE OR REPLACE PROCEDURE hivesense_single_processing(
    in _from INT, in _to INT, IN _logs BOOLEAN,  IN _worker INT, _done OUT INT)
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  PERFORM set_config('synchronous_commit', 'ON', false);

  SELECT hivesense_block_range_data(_from, _to, _logs, _worker) INTO _done;
END
$$;

CREATE OR REPLACE FUNCTION continueProcessingLoop(
    _appContext hive.context_name,
    _maxBlockLimit INT,
    _blocks_range hive.blocks_range
)
RETURNS BOOLEAN
LANGUAGE 'plpgsql'
AS
$$
BEGIN
    IF _blocks_range IS NULL AND _maxBlockLimit IS NOT NULL THEN
        IF hive.app_get_current_block_num(_appContext) >= _maxBlockLimit THEN
            RAISE NOTICE 'Blocks limit reached. Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
            RETURN FALSE;
        END IF;
    END IF;

    IF NOT continueProcessing() THEN
        RAISE NOTICE 'Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
        RETURN FALSE;
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
    IN _appContextBaseName hive.context_name,
    IN _worker INT,
    IN _maxBlockLimit INT = NULL
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  _blocks_range hive.blocks_range := (0,0);
  __number_of_posts INT;
  __context_name hive.context_name := _appContextBaseName || _worker;
BEGIN
  IF _maxBlockLimit != NULL THEN
    RAISE NOTICE 'Max block limit is specified as: %', _maxBlockLimit;
  END IF;

  PERFORM allowProcessing();
  
  RAISE NOTICE 'Last block processed by application %: %', __context_name, hive.app_get_current_block_num(__context_name);

  RAISE NOTICE 'Entering application main loop...';

  LOOP
    CALL hive.app_next_iteration(
      __context_name,
      _blocks_range, 
      _override_max_batch => NULL, 
      _limit => _maxBlockLimit);

    IF NOT continueProcessingLoop( __context_name, _maxBlockLimit, _blocks_range ) THEN
        ROLLBACK;
        RETURN;
    END IF;

    IF _blocks_range IS NULL THEN
      RAISE INFO 'Waiting for next block...';
      CONTINUE;
    END IF;

    CALL hivesense_process_blocks(__context_name, _blocks_range, _worker, __number_of_posts);
    IF  __number_of_posts IS NULL  THEN
        ROLLBACK;
        PERFORM pg_sleep( 1.5 ); -- wait for hivemind
    END IF;
  END LOOP;

  ASSERT FALSE, 'Cannot reach this point';
END
$$;


RESET ROLE;

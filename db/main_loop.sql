SET ROLE hivesense_owner;

DO $BODY$
    DECLARE
        __llm TEXT := current_setting('pg_temp.LLM', TRUE);
        __ollama TEXT := current_setting('pg_temp.OLLAMA_HOST', TRUE);
    BEGIN
        EXECUTE format($$
        CREATE OR REPLACE FUNCTION hivesense_embed(_post TEXT)
        RETURNS vector(1024)
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
    _logs BOOLEAN
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
    __workers_number INT;
BEGIN
    ASSERT _first_block_num <= _last_block_num, 'Invalid range of blocks';

    -- will RAISE when hivemind context does not exist
    -- TODO(mickiewicz@syncad.com): customize hivemind context
    SELECT hive.app_get_current_block_num( 'hivemind_app' ) INTO __hivemind_current_block;

    -- hivemind exists
    IF __hivemind_current_block < _first_block_num THEN
        RETURN NULL;
    END IF;

    IF __hivemind_current_block < _last_block_num THEN
        RETURN NULL;
    END IF;

    IF _logs THEN
        RAISE NOTICE 'Hivesense is attempting to process a block range: <%, %>', _first_block_num, _last_block_num;
        __start_ts := clock_timestamp();
    END IF;

    -- TODO(mickiewicz@syncad.com): parametrize ollama address
    -- TODO(mickiewicz@syncad.com): parametrize hivemind schema
    -- TODO(mickiewicz@syncad.com): parametrize LLM model

    -- bge-m3:latest
    -- yxchia/multilingual-e5-base:F16 2xfaster
    WITH vectorize AS(
            INSERT INTO posts_vectors (post_id, embedding)
            SELECT
                posts.id,
                     hivesense_embed(posts.body) FROM (
                     SELECT hp.id, hpd.body
                     FROM hivemind_app.hive_posts as hp
                     JOIN hivemind_app.hive_post_data as hpd ON hpd.id = hp.id
                     WHERE hp.id=hp.root_id
                     AND hp.block_num BETWEEN _first_block_num AND _last_block_num
                     ORDER by hp.id
            ) AS posts
            RETURNING 1
    )
    SELECT COUNT(*) FROM vectorize INTO __number_of_posts;

    __number_of_posts = COALESCE( __number_of_posts, 0 );

    IF _logs THEN
        __end_ts := clock_timestamp();
        RAISE NOTICE 'Hivesense processed block range: <%, %> with % roots posts successfully in % s
    ', _first_block_num, _last_block_num, __number_of_posts, (extract(epoch FROM __end_ts - __start_ts));
    END IF;

    RETURN __number_of_posts;
END;
$$;



CREATE OR REPLACE PROCEDURE hivesense_massive_processing(
    IN _from INT, IN _to INT, IN _logs BOOLEAN, OUT _done INT
)
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  PERFORM set_config('synchronous_commit', 'OFF', false);

  SELECT hivesense_block_range_data(_from, _to, _logs) INTO _done;
END
$$;

CREATE OR REPLACE PROCEDURE hivesense_single_processing(
    in _from INT, in _to INT, IN _logs BOOLEAN, _done OUT INT)
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  PERFORM set_config('synchronous_commit', 'ON', false);

  SELECT hivesense_block_range_data(_from, _to, _logs) INTO _done;
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
    IN _appContext hive.context_name,
    IN _maxBlockLimit INT = NULL
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  _blocks_range hive.blocks_range := (0,0);
  __number_of_posts INT;
BEGIN
  IF _maxBlockLimit != NULL THEN
    RAISE NOTICE 'Max block limit is specified as: %', _maxBlockLimit;
  END IF;

  PERFORM allowProcessing();
  
  RAISE NOTICE 'Last block processed by application: %', hive.app_get_current_block_num(_appContext);

  RAISE NOTICE 'Entering application main loop...';

  LOOP
    CALL hive.app_next_iteration(
      _appContext,
      _blocks_range, 
      _override_max_batch => NULL, 
      _limit => _maxBlockLimit);

    IF NOT continueProcessingLoop( _appContext, _maxBlockLimit, _blocks_range ) THEN
        ROLLBACK;
        RETURN;
    END IF;

    IF _blocks_range IS NULL THEN
      RAISE INFO 'Waiting for next block...';
      CONTINUE;
    END IF;

    CALL hivesense_process_blocks(_appContext, _blocks_range, __number_of_posts);
    IF  __number_of_posts IS NULL  THEN
        ROLLBACK;
        PERFORM pg_sleep( 1.5 ); -- wait for hivemind
    END IF;
  END LOOP;

  ASSERT FALSE, 'Cannot reach this point';
END
$$;


RESET ROLE;

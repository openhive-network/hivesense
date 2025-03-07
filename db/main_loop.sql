DROP TYPE iF EXISTS hivesense_app.id_and_post CASCADE;
CREATE TYPE hivesense_app.id_and_post AS(
      post_id INTEGER
    , body TEXT
);


DROP TYPE iF EXISTS hivesense_app.post_and_vector CASCADE;
CREATE TYPE hivesense_app.post_and_vector AS(
      t INTEGER
    , vec vector
);

DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text,hivesense_app.id_and_post[],text,text,jsonb);
CREATE FUNCTION hivesense_app.ollama_embed(
    model text,
    posts hivesense_app.id_and_post[],
    host text DEFAULT NULL::text,
    keep_alive text DEFAULT NULL::text,
    embedding_options jsonb DEFAULT NULL::jsonb)
    RETURNS hivesense_app.post_and_vector[]
    LANGUAGE 'plpython3u'
    IMMUTABLE PARALLEL SAFE
    SET search_path=pg_catalog, pg_temp
AS $BODY$
    if "ai.version" not in GD:
        r = plpy.execute("select coalesce(pg_catalog.current_setting('ai.python_lib_dir', true), '/usr/local/lib/pgai') as python_lib_dir")
        python_lib_dir = r[0]["python_lib_dir"]
        from pathlib import Path
        import sys
        import sysconfig
        # Note: the "old" (pre-0.4.0) packages are installed as system-level python packages
        # and take precedence over our extension-version specific packages.
        # By removing the whole thing from the path we won't run into package conflicts.
        if "purelib" in sysconfig.get_path_names() and sysconfig.get_path("purelib") in sys.path:
            sys.path.remove(sysconfig.get_path("purelib"))
        python_lib_dir = Path(python_lib_dir).joinpath("0.8.0")
        import site
        site.addsitedir(str(python_lib_dir))
        from ai import __version__ as ai_version
        assert("0.8.0" == ai_version)
        GD["ai.version"] = "0.8.0"
    else:
        if GD["ai.version"] != "0.8.0":
            plpy.fatal("the pgai extension version has changed. start a new session")
    import ai.ollama
    client = ai.ollama.make_client(plpy, host)
    embedding_options_1 = None
    if embedding_options is not None:
        import json
        embedding_options_1 = {k: v for k, v in json.loads(embedding_options).items()}

    embeddings = []
    for post in posts:
        resp = client.embeddings(model, post['body'], options=embedding_options_1, keep_alive=keep_alive)
        embedding = resp.get("embedding")
        if embedding is not None:
            embeddings.append((post['post_id'], embedding))
    return embeddings;
$BODY$;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post[], text, text, jsonb) TO haf_admin WITH GRANT OPTION;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post[], text, text, jsonb) TO hivesense_user;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post[], text, text, jsonb) TO pg_database_owner WITH GRANT OPTION;


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
            RETURN ai.ollama_embed('%s', _post, host => '%s');
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
    LANGUAGE 'plpgsql'
    VOLATILE
    PARALLEL SAFE
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

    WITH posts AS (
        SELECT ROW_NUMBER() OVER (ORDER BY hp.id) AS row_id, hp.id, clean_content( hpd.body ) as body
        FROM hivemind_app.hive_posts as hp
                 JOIN hivemind_app.hive_post_data as hpd ON hpd.id = hp.id
        WHERE hp.id=hp.root_id
        AND hp.block_num_created BETWEEN _first_block_num AND _last_block_num
        ORDER by hp.id
    ), id_and_body_agg AS (
        SELECT ARRAY_AGG( (p.id, p.body)::hivesense_app.id_and_post ) as id_and_body
        FROM posts p
        WHERE p.body != ''
        AND p.body IS NOT NULL
        AND __number_of_workers - (p.row_id % __number_of_workers )  = _worker
    ), embeddings AS (
        SELECT (id_vector).t as post_id, (id_vector).vec as embedding
        FROM (
                 SELECT UNNEST(hivesense_embed(ibagg.id_and_body)) AS id_vector
                 FROM id_and_body_agg ibagg
                 WHERE CARDINALITY(ibagg.id_and_body) > 0
             ) AS subquery
    ), insert_to AS (
        INSERT INTO hivesense_app.posts_vectors (post_id, embedding)
            SELECT emb.post_id, emb.embedding
            FROM embeddings emb
    ) SELECT COUNT(*) FROM embeddings INTO __number_of_posts;

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
PARALLEL SAFE
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

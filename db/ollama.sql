-- improves ai.ollama_embedd for reuse already initialized connection
-- it ist 2x faster now than ai.ollama_embed
-- It fits our needs, the ollama connection object is saved in python globals and will be destroyed together with postgres session
-- In our architecture the postgres session is associated with a connection between postgrest server and postgresql server.
-- These connections (postgrest<->postgresql) are held in a pool by the postgrest
CREATE OR REPLACE FUNCTION hivesense_app.ollama_embed(
    model text,
    input_text text,
    host text DEFAULT NULL::text,
    keep_alive text DEFAULT NULL::text,
    embedding_options jsonb DEFAULT NULL::jsonb
)
RETURNS vector
LANGUAGE 'plpython3u'
COST 100
IMMUTABLE PARALLEL UNSAFE
SET search_path=pg_catalog, pg_temp
AS $BODY$
    try:
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
        if "ai.ollama_client" not in GD:
            GD["ai.ollama_client"] = ai.ollama.make_client(plpy, host)
        client = GD["ai.ollama_client"]
        embedding_options_1 = None
        if embedding_options is not None:
            import json
            embedding_options_1 = {k: v for k, v in json.loads(embedding_options).items()}
        resp = client.embeddings(model, input_text, options=embedding_options_1, keep_alive=keep_alive)
        return resp.get("embedding")
    except Exception as e:
        if "ai.ollama_client" in GD:
            del GD["ai.ollama_client"]
        plpy.error(f"Error during embedding operation: {str(e)}")
$BODY$;


DROP TYPE IF EXISTS hivesense_app.id_and_post CASCADE;
CREATE TYPE hivesense_app.id_and_post AS (
    post_id INTEGER,
    body TEXT [] -- chunked post body
);


DROP TYPE IF EXISTS hivesense_app.post_and_vector CASCADE;
CREATE TYPE hivesense_app.post_and_vector AS (
    post_id INTEGER,
    vec vector
);

-- batch version of pga ollama embed
-- because it uses python, then only super user can be owner
-- TODO(mickiewicz@syncad.com) create pull request with the function for pgai
DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text, hivesense_app.id_and_post [], text, text, jsonb);
CREATE FUNCTION hivesense_app.ollama_embed(
    model               TEXT,
    posts               hivesense_app.id_and_post[],
    host                TEXT          DEFAULT NULL::text,
    keep_alive          TEXT          DEFAULT NULL::text,
    embedding_options   JSONB         DEFAULT NULL::jsonb
)
RETURNS hivesense_app.post_and_vector[]
LANGUAGE plpython3u
IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $BODY$
    if "ai.version" not in GD:
        r = plpy.execute(
            "SELECT coalesce(current_setting('ai.python_lib_dir', true), "
            "'/usr/local/lib/pgai') AS python_lib_dir"
        )
        python_lib_dir = r[0]["python_lib_dir"]
        from pathlib import Path
        import sys, sysconfig, site
        if "purelib" in sysconfig.get_path_names() and \
           sysconfig.get_path("purelib") in sys.path:
            sys.path.remove(sysconfig.get_path("purelib"))
        python_lib_dir = Path(python_lib_dir).joinpath("0.8.0")
        site.addsitedir(str(python_lib_dir))
        from ai import __version__ as ai_version
        assert("0.8.0" == ai_version)
        GD["ai.version"] = "0.8.0"
    else:
        if GD["ai.version"] != "0.8.0":
            plpy.fatal("the pgai extension version has changed. start a new session")

    import ai.ollama, time, json
    client = ai.ollama.make_client(plpy, host)

    embedding_options_1 = None
    if embedding_options is not None:
        embedding_options_1 = {k: v for k, v in json.loads(embedding_options).items()}

    # — read batch size from the fully-qualified status table —
    r = plpy.execute(
        "SELECT embedding_batch_size "
        "FROM hivesense_app.hivesense_app_status "
        "LIMIT 1"
    )
    max_batch = r[0].get("embedding_batch_size", 100)

    # — flatten all (post_id, chunk) pairs —
    flat_texts    = []
    flat_post_ids = []
    for post in posts:
        pid = post['post_id']
        for chunk in post['body']:
            flat_texts.append(chunk)
            flat_post_ids.append(pid)

    embeddings  = []
    total       = len(flat_texts)
    max_retries = 120

    # — process in slices of up to max_batch —
    for start in range(0, total, max_batch):
        end         = min(start + max_batch, total)
        batch_texts = flat_texts[start:end]
        batch_pids  = flat_post_ids[start:end]

        # retry the entire batch up to max_retries
        resp = None
        for attempt in range(max_retries):
            try:
                resp = client.embed(
                    model,
                    batch_texts,
                    options=embedding_options_1,
                    keep_alive=keep_alive
                )
                break
            except Exception as error:
                plpy.notice(f"[Batch {start}:{end} Attempt {attempt+1}] {error}")
                time.sleep(5)

        if resp is None:
            plpy.error(
                f"Could not embed batch {start}:{end} "
                f"after {max_retries} attempts"
            )

        # unpack the embeddings array
        for idx, emb in enumerate(resp.get("embeddings", [])):
            embeddings.append((batch_pids[idx], emb))

    return embeddings
$BODY$;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post [], text, text, jsonb) TO haf_admin WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post [], text, text, jsonb) TO hivesense_user;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post [], text, text, jsonb) TO pg_database_owner WITH GRANT OPTION;

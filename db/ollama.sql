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

DROP TYPE IF EXISTS hivesense_app.id_and_post_chunk CASCADE;
CREATE TYPE hivesense_app.id_and_post_chunk AS (
    post_id     INT,
    chunk_text  TEXT,
    chunk_number INT
);

DROP TYPE IF EXISTS hivesense_app.post_and_vector_chunk CASCADE;
CREATE TYPE hivesense_app.post_and_vector_chunk AS (
    post_id      INT,
    chunk_number INT,
    vec          vector -- same dimension as before
);

CREATE OR REPLACE FUNCTION hivesense_app.ollama_embed(
    model             TEXT,
    input_text        TEXT,
    host              TEXT    DEFAULT NULL::text,
    keep_alive        TEXT    DEFAULT NULL::text,
    embedding_options JSONB   DEFAULT NULL::jsonb
)
RETURNS vector
IMMUTABLE
PARALLEL SAFE
LANGUAGE plpgsql
AS $$
DECLARE
    batch_in  hivesense_app.id_and_post_chunk[];
    batch_out hivesense_app.post_and_vector_chunk[];
BEGIN
    -- wrap into a single-element id_and_post_chunk[] (post_id and chunk_number are ignored downstream)
    batch_in := ARRAY[
        ROW(1, input_text, 1)::hivesense_app.id_and_post_chunk
    ];

    -- call the batch endpoint (which always normalizes)
    batch_out := hivesense_app.ollama_embed(
        model,
        batch_in,
        host              => host,
        keep_alive        => keep_alive,
        embedding_options => embedding_options
    );

    -- extract and return the single vector
    RETURN batch_out[1].vec;
END;
$$;

-- batch version of pga ollama embed
-- because it uses python, then only super user can be owner
-- TODO(mickiewicz@syncad.com) create pull request with the function for pgai
DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, text, jsonb);
CREATE FUNCTION hivesense_app.ollama_embed(
    model               TEXT,
    posts               hivesense_app.id_and_post_chunk[],
    host                TEXT          DEFAULT NULL::text,
    keep_alive          TEXT          DEFAULT NULL::text,
    embedding_options   JSONB         DEFAULT NULL::jsonb
)
RETURNS hivesense_app.post_and_vector_chunk[]
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
    flat_chunk_numbers = []
    if posts is not None:
        for post in posts:
            pid     = post['post_id']
            ctext   = post['chunk_text']
            cnumber = post['chunk_number']
            flat_texts.append(ctext)
            flat_post_ids.append(pid)
            flat_chunk_numbers.append(cnumber)

    embeddings  = []
    total       = len(flat_texts)
    max_retries = 120

    # — process in slices of up to max_batch —
    for start in range(0, total, max_batch):
        end         = min(start + max_batch, total)
        batch_texts = flat_texts[start:end]
        batch_pids  = flat_post_ids[start:end]
        batch_nums  = flat_chunk_numbers[start:end]

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
            pid   = batch_pids[idx]
            cnum  = batch_nums[idx]
            # append a triple (post_id, chunk_number, emb_vector)
            embeddings.append((pid, cnum, emb))

    return embeddings
$BODY$;

DROP FUNCTION IF EXISTS hivesense_app.pgai_initialize();
CREATE FUNCTION hivesense_app.pgai_initialize()
    RETURNS void
    LANGUAGE plpython3u
AS $BODY$
    if "ai.version" not in GD:
        r = plpy.execute(
            "SELECT coalesce(current_setting('ai.python_lib_dir', true), "
            "'/usr/local/lib/pgai') AS python_lib_dir"
        )
        python_lib_dir = r[0]["python_lib_dir"]
        from pathlib import Path
        import sys, sysconfig, site
        if "purelib" in sysconfig.get_path_names() and sysconfig.get_path("purelib") in sys.path:
            sys.path.remove(sysconfig.get_path("purelib"))
        python_lib_dir = Path(python_lib_dir).joinpath("0.8.0")
        site.addsitedir(str(python_lib_dir))
        from ai import __version__ as ai_version
        assert("0.8.0" == ai_version)
        GD["ai.version"] = "0.8.0"
    else:
        if GD["ai.version"] != "0.8.0":
            plpy.fatal("the pgai extension version has changed. start a new session")
$BODY$;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, text, jsonb) TO haf_admin WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, text, jsonb) TO hivesense_user;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, text, jsonb) TO pg_database_owner WITH GRANT OPTION;

GRANT EXECUTE ON FUNCTION hivesense_app.pgai_initialize() TO haf_admin WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION hivesense_app.pgai_initialize() TO hivesense_user;
GRANT EXECUTE ON FUNCTION hivesense_app.pgai_initialize() TO pg_database_owner WITH GRANT OPTION;

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

DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text, text, text, text, jsonb);
DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text, text, text, jsonb);
CREATE OR REPLACE FUNCTION hivesense_app.ollama_embed(
    model             TEXT,
    input_text        TEXT,
    host              TEXT    DEFAULT NULL::text,
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
        embedding_options => embedding_options
    );

    -- extract and return the single vector
    RETURN batch_out[1].vec;
END;
$$;

-- batch version of pga ollama embed
-- because it uses python, then only super user can be owner
DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, text, jsonb);
DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb);
CREATE OR REPLACE FUNCTION hivesense_app.ollama_embed(
    model             TEXT,
    posts             hivesense_app.id_and_post_chunk[],
    host              TEXT           DEFAULT NULL::text,
    embedding_options JSONB          DEFAULT NULL::jsonb
)
RETURNS hivesense_app.post_and_vector_chunk[]
LANGUAGE plpython3u
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $BODY$
    import json, requests, time, plpy

    # Resolve host URL
    if host is None:
        r = plpy.execute(
          "SELECT coalesce(current_setting('pg_temp.OLLAMA_HOST', true), 'http://localhost:11434') AS host"
        )
        host_url = r[0]['host']
    else:
        host_url = host

    # Batch size from config
    r = plpy.execute(
      "SELECT embedding_batch_size FROM hivesense_app.hivesense_app_status LIMIT 1"
    )
    max_batch = r[0].get('embedding_batch_size', 100)

    # Flatten inputs
    flat_texts, flat_pids, flat_nums = [], [], []
    if posts is not None:
        for p in posts:
            flat_pids.append(p['post_id'])
            flat_nums.append(p['chunk_number'])
            flat_texts.append(p['chunk_text'])

    # Parse options
    opts = json.loads(embedding_options) if embedding_options is not None else None

    embeddings = []
    total = len(flat_texts)
    # exponential backoff parameters
    initial_delay = 5
    max_delay     = 120
    delay_secs    = initial_delay

    for start in range(0, total, max_batch):
        end = min(start + max_batch, total)
        batch_texts = flat_texts[start:end]
        batch_pids  = flat_pids[start:end]
        batch_nums  = flat_nums[start:end]

        payload = {"model": model, "input": batch_texts}
        if opts is not None:
            payload["options"] = opts

        url = host_url.rstrip('/') + "/api/embed"
        while True:
            try:
                resp = requests.post(url, json=payload, timeout=300)
                if resp.status_code == 200:
                    break
                plpy.notice(f"[Batch {start}:{end}] HTTP {resp.status_code}, retrying in {delay_secs}s")
            except Exception as e:
                plpy.notice(f"[Batch {start}:{end}] Exception: {e}, retrying in {delay_secs}s")
            time.sleep(delay_secs)
            delay_secs = min(delay_secs * 2, max_delay)
        # reset backoff for next batch
        delay_secs = initial_delay

        data = resp.json()
        for idx, vec in enumerate(data.get("embeddings", [])):
            embeddings.append((batch_pids[idx], batch_nums[idx], vec))

    return embeddings
$BODY$;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb) TO haf_admin WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb) TO hivesense_user;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb) TO pg_database_owner WITH GRANT OPTION;

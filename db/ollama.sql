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
    embedding_options JSONB   DEFAULT NULL::jsonb,
    max_retries       INTEGER DEFAULT 3
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

    -- Single-text path is used by interactive search (find_nearest_posts).
    -- Bound the retries so a broken/slow ollama fails fast instead of
    -- holding a snapshot open and starving autovacuum across the DB.
    batch_out := hivesense_app.ollama_embed(
        model,
        batch_in,
        host              => host,
        embedding_options => embedding_options,
        max_retries       => max_retries
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
    embedding_options JSONB          DEFAULT NULL::jsonb,
    max_retries       INTEGER        DEFAULT NULL
)
RETURNS hivesense_app.post_and_vector_chunk[]
LANGUAGE plpython3u
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $BODY$
    import json, time, plpy
    from urllib.request import Request, urlopen
    from urllib.error import URLError, HTTPError

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

    # max_retries=None means infinite retries (sync path: never drop posts).
    # A finite max_retries (search path) bounds the wait so a broken/slow
    # ollama can't hold a snapshot open and starve autovacuum DB-wide.
    retry_label = max_retries if max_retries is not None else 'inf'

    for start in range(0, total, max_batch):
        end = min(start + max_batch, total)
        batch_texts = flat_texts[start:end]
        batch_pids  = flat_pids[start:end]
        batch_nums  = flat_nums[start:end]

        payload = {"model": model, "input": batch_texts}
        if opts is not None:
            payload["options"] = opts

        url = host_url.rstrip('/') + "/api/embed"
        body = json.dumps(payload).encode('utf-8')
        attempts = 0
        while True:
            last_err = None
            # Only catch network-layer errors. plpy.QueryCanceledError and
            # other plpy exceptions must propagate so pg_terminate_backend /
            # pg_cancel_backend actually work — a bare `except Exception`
            # here will silently swallow cancellation.
            try:
                req = Request(url, data=body, headers={'Content-Type': 'application/json'})
                resp = urlopen(req, timeout=30)
                status_code = resp.getcode()
                if status_code == 200:
                    break
                last_err = f"HTTP {status_code}"
            except HTTPError as e:
                last_err = f"HTTP {e.code}"
            except (URLError, OSError) as e:
                last_err = f"network error: {e}"
            attempts += 1
            if max_retries is not None and attempts >= max_retries:
                plpy.error(f"[Batch {start}:{end}] giving up after {attempts} attempts: {last_err}")
            plpy.notice(f"[Batch {start}:{end}] {last_err}, retrying in {delay_secs}s ({attempts}/{retry_label})")
            time.sleep(delay_secs)
            delay_secs = min(delay_secs * 2, max_delay)
        # reset backoff for next batch
        delay_secs = initial_delay

        data = json.loads(resp.read().decode('utf-8'))
        for idx, vec in enumerate(data.get("embeddings", [])):
            embeddings.append((batch_pids[idx], batch_nums[idx], vec))

    return embeddings
$BODY$;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb, integer) TO haf_admin WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb, integer) TO hivesense_user;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb, integer) TO pg_database_owner WITH GRANT OPTION;

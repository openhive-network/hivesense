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
    import json, socket, time, plpy
    from http.client import HTTPException
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

    # Batch size and embedding-API style from config.
    # embedding_api selects the wire protocol:
    #   'ollama' (default) -> native /api/embed, response {"embeddings":[[...]]}
    #   'openai'           -> /v1/embeddings, response {"data":[{"index","embedding"}]}
    #                         (e.g. llama-swap / llama.cpp server). Used for the
    #                         local-network GPU pool; ollama remains the default so
    #                         existing/legacy deployments are unaffected.
    r = plpy.execute(
      "SELECT embedding_batch_size, coalesce(embedding_api, 'ollama') AS embedding_api, "
      "embedding_timeout_base, embedding_timeout_per_text, embedding_timeout_max "
      "FROM hivesense_app.hivesense_app_status LIMIT 1"
    )
    max_batch = r[0].get('embedding_batch_size', 100)
    api_style = (r[0].get('embedding_api') or 'ollama').lower()
    timeout_base     = r[0]['embedding_timeout_base']
    timeout_per_text = r[0]['embedding_timeout_per_text']
    timeout_max      = r[0]['embedding_timeout_max']

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

    # max_retries=None means infinite retries (sync path: never drop posts).
    # A finite max_retries (search path) bounds the wait so a broken/slow
    # ollama can't hold a snapshot open and starve autovacuum DB-wide.
    retry_label = max_retries if max_retries is not None else 'inf'

    # Per-attempt request timeout. A batch starts at
    # max(timeout_base, timeout_per_text * len(batch)); after an attempt that
    # timed out, the next one waits twice as long, up to the cap. Other errors
    # (refused, HTTP 5xx) keep the timeout, waiting longer can't fix them.
    # The bounded search path caps growth at 60s, so with its default
    # max_retries=3 the worst case is 30+60+60s of requests plus 15s of backoff.
    if max_retries is not None:
        timeout_max = min(timeout_max, 60)

    if api_style == 'openai':
        # llama-server ignores an ollama-style "options" block; context size
        # is fixed at server launch, so num_ctx et al. are not sent.
        url = host_url.rstrip('/') + "/v1/embeddings"
        reply_key = "data"
    else:
        url = host_url.rstrip('/') + "/api/embed"
        reply_key = "embeddings"

    class Rejected(Exception):
        """args: (status, response body). A 4xx other than 408/429 is
        deterministic: the same request fails the same way every time."""

    def response_body(e):
        try:
            text = e.read().decode('utf-8', errors='replace').strip()
        except (OSError, HTTPException):
            text = ''
        finally:
            e.close()
        return text[:500] or '(empty body)'

    def embed_request(texts, label):
        """POST texts to the embedding server and return its decoded answer.
        Transient failures (network, 5xx, 408, 429) are retried with backoff,
        up to max_retries; any other 4xx raises Rejected at once."""
        payload = {"model": model, "input": texts}
        if api_style != 'openai' and opts is not None:
            payload["options"] = opts
        body = json.dumps(payload).encode('utf-8')
        # Built before the retry loop: a URL urllib cannot use is a
        # configuration error, raised at once rather than retried.
        req = Request(url, data=body, headers={'Content-Type': 'application/json'})
        if req.type not in ('http', 'https'):
            raise ValueError(f"unknown url type: {req.type!r} in embedding URL {url!r}")
        timeout_secs = max(timeout_base, timeout_per_text * len(texts))
        request_timeout_max = max(timeout_max, timeout_secs)
        delay_secs = initial_delay
        attempts = 0
        while True:
            last_err = None
            timed_out = False
            # The body is read inside the try: a reply can stall or break off
            # after its status line, which is as transient as a failed connect.
            # Only catch network-layer errors. plpy.QueryCanceledError and
            # other plpy exceptions must propagate so pg_terminate_backend /
            # pg_cancel_backend actually work — a bare `except Exception`
            # here will silently swallow cancellation.
            try:
                with urlopen(req, timeout=timeout_secs) as resp:
                    status_code = resp.getcode()
                    if status_code == 200:
                        data = json.loads(resp.read().decode('utf-8'))
                        if isinstance(data, dict) and reply_key in data:
                            return data
                        last_err = f"malformed reply: no {reply_key!r} in the JSON body"
                    else:
                        last_err = f"HTTP {status_code}"
            except HTTPError as e:
                reply = response_body(e)
                if 400 <= e.code < 500 and e.code not in (408, 429):
                    plpy.warning(f"[{label}] HTTP {e.code}, not retrying: {reply}")
                    raise Rejected(e.code, reply)
                last_err = f"HTTP {e.code} ({reply})"
            except (URLError, OSError, HTTPException) as e:
                # A timeout while connecting arrives wrapped in URLError, one
                # while waiting for or reading the response arrives bare.
                timed_out = isinstance(e, socket.timeout) or isinstance(getattr(e, 'reason', None), socket.timeout)
                if timed_out:
                    last_err = f"network error: timed out after {timeout_secs:g}s"
                else:
                    last_err = f"network error: {str(e) or repr(e)}"
            except ValueError as e:
                # Not UTF-8 or not JSON: most likely a reply cut short.
                last_err = f"malformed reply: {e}"
            attempts += 1
            if max_retries is not None and attempts >= max_retries:
                plpy.error(f"[{label}] giving up after {attempts} attempts: {last_err}")
            plpy.notice(f"[{label}] {last_err}, retrying in {delay_secs}s ({attempts}/{retry_label})")
            time.sleep(delay_secs)
            delay_secs = min(delay_secs * 2, max_delay)
            if timed_out:
                timeout_secs = min(timeout_secs * 2, request_timeout_max)

    for start in range(0, total, max_batch):
        end = min(start + max_batch, total)
        batch_texts = flat_texts[start:end]
        batch_pids  = flat_pids[start:end]
        batch_nums  = flat_nums[start:end]
        label = f"Batch {start}:{end}"

        try:
            data = embed_request(batch_texts, label)
        except Rejected as rejected:
            # Never drop a post: name the rejected text and fail. In a batch,
            # resend its texts one by one to find which one the server refuses.
            status, reply = rejected.args
            if len(batch_texts) == 1:
                plpy.error(f"[{label}] embedding server rejected post_id {batch_pids[0]} "
                           f"chunk_number {batch_nums[0]}: HTTP {status}: {reply}")
            for pid, num, text in zip(batch_pids, batch_nums, batch_texts):
                try:
                    embed_request([text], f"{label} post_id {pid} chunk_number {num}")
                except Rejected as single:
                    status, reply = single.args
                    plpy.error(f"[{label}] embedding server rejected post_id {pid} "
                               f"chunk_number {num}: HTTP {status}: {reply}")
            plpy.error(f"[{label}] embedding server rejected the batch with HTTP {status}: {reply}, "
                       f"yet accepted each of its {len(batch_texts)} texts alone")

        if api_style == 'openai':
            # OpenAI /v1/embeddings: {"data":[{"index":i,"embedding":[...]}, ...]}.
            # Sort by index to guarantee alignment with the input order.
            batch_vecs = [it["embedding"]
                          for it in sorted(data.get("data", []),
                                           key=lambda o: o.get("index", 0))]
        else:
            # ollama /api/embed: {"embeddings":[[...], ...]} in input order.
            batch_vecs = data.get("embeddings", [])
        for idx, vec in enumerate(batch_vecs):
            embeddings.append((batch_pids[idx], batch_nums[idx], vec))

    return embeddings
$BODY$;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb, integer) TO haf_admin WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb, integer) TO hivesense_user;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post_chunk [], text, jsonb, integer) TO pg_database_owner WITH GRANT OPTION;

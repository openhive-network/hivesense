#!/usr/bin/env python3
"""
hivesense_block_processor - client-side range processor for haf_app_driver.py.

Run as:  haf_app_driver.py --app=hivesense_app \
             --process-python hivesense_block_processor [...]

For each block range delivered by hive.app_next_iteration (inside the driver's
transaction, on the driver's connection):

    1. SELECT hivesense_app.posts_in_range(first, last)
    2. SELECT ... FROM hivesense_app.prepare_post_chunks(ids)
       (leaves session temp tables behind for step 4)
    3. embed the chunk texts over HTTP - concurrently, from THIS process,
       replacing the scheduler/worker sessions that used to block PostgreSQL
       backends on network I/O via plpython (haf#341)
    4. fill temp table tmp_vectors and SELECT hivesense_app.store_post_embeddings()
    5. SELECT hivesense_app.publish_visible_sync_seq()

The driver then commits: vectors, bookkeeping and the context position become
durable atomically, so a crash re-delivers (at most) the current range.
Re-processing a post is idempotent - store_post_embeddings replaces its
vectors under a fresh sync_seq, exactly like an edit.

At the massive -> live transition the HNSW index build
(hivesense_app.ensure_indexes_are_created) is triggered once.

Configuration (model, server, api style, batch size, parallelism) comes from
hivesense_app.hivesense_app_status, read once per process.
"""

import json
import logging
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from psycopg2.extras import execute_values

log = logging.getLogger("hivesense")
if not logging.getLogger().handlers:
    # match the driver's timestamp format (ISO-8601 UTC, ms) so interleaved
    # driver and processor lines read as one log
    class _UtcIsoFormatter(logging.Formatter):
        def formatTime(self, record, datefmt=None):
            import datetime
            return datetime.datetime.fromtimestamp(record.created, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(record.msecs):03d}Z"
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(_UtcIsoFormatter("%(asctime)s %(levelname)s %(message)s"))
    logging.getLogger().addHandler(_handler)
    logging.getLogger().setLevel(logging.INFO)

_CONFIG = None
_INDEXES_ENSURED = False

INITIAL_RETRY_DELAY = 5
MAX_RETRY_DELAY = 120


def _load_config(conn):
    global _CONFIG
    if _CONFIG is not None:
        return _CONFIG
    with conn.cursor() as cur:
        cur.execute(
            """SELECT llm, ollama, coalesce(embedding_api, 'ollama'),
                      embedding_batch_size, parallel_workers, NULLIF(num_ctx, 0)
               FROM hivesense_app.hivesense_app_status WHERE id = 1"""
        )
        llm, host, api_style, batch_size, workers, num_ctx = cur.fetchone()
    _CONFIG = {
        "model": llm,
        "host": (host or "http://localhost:11434").rstrip("/"),
        "api_style": (api_style or "ollama").lower(),
        "batch_size": batch_size or 100,
        "workers": max(1, workers or 1),
        "options": {"num_ctx": num_ctx} if num_ctx else None,
    }
    log.info(
        "embedding config: model=%(model)s host=%(host)s api=%(api_style)s "
        "batch=%(batch_size)s workers=%(workers)s", _CONFIG
    )
    return _CONFIG


def _embed_batch(cfg, texts, label):
    """One HTTP embedding request; retries forever with backoff (the sync path
    must never drop posts - same policy as the old in-database embedder)."""
    payload = {"model": cfg["model"], "input": texts}
    if cfg["api_style"] == "openai":
        url = cfg["host"] + "/v1/embeddings"
    else:
        if cfg["options"]:
            payload["options"] = cfg["options"]
        url = cfg["host"] + "/api/embed"
    body = json.dumps(payload).encode()
    delay = INITIAL_RETRY_DELAY
    attempts = 0
    while True:
        try:
            resp = urlopen(Request(url, data=body, headers={"Content-Type": "application/json"}), timeout=300)
            if resp.getcode() == 200:
                data = json.loads(resp.read().decode())
                break
            last_err = f"HTTP {resp.getcode()}"
        except HTTPError as e:
            last_err = f"HTTP {e.code}"
        except (URLError, OSError) as e:
            last_err = f"network error: {e}"
        attempts += 1
        log.warning("[%s] %s, retrying in %ss (attempt %s)", label, last_err, delay, attempts)
        time.sleep(delay)
        delay = min(delay * 2, MAX_RETRY_DELAY)
    if cfg["api_style"] == "openai":
        return [item["embedding"] for item in sorted(data.get("data", []), key=lambda o: o.get("index", 0))]
    return data.get("embeddings", [])


def _embed_chunks(cfg, chunks):
    """chunks: [(post_id, chunk_number, text)] -> [(post_id, chunk_number, vec_text)]"""
    batches = [chunks[i:i + cfg["batch_size"]] for i in range(0, len(chunks), cfg["batch_size"])]
    results = [None] * len(batches)

    def run(idx):
        batch = batches[idx]
        vecs = _embed_batch(cfg, [c[2] for c in batch], f"batch {idx + 1}/{len(batches)}")
        if len(vecs) != len(batch):
            raise RuntimeError(f"embedding server returned {len(vecs)} vectors for {len(batch)} inputs")
        results[idx] = [
            (c[0], c[1], "[" + ",".join(map(str, v)) + "]") for c, v in zip(batch, vecs)
        ]

    with ThreadPoolExecutor(max_workers=cfg["workers"]) as pool:
        list(pool.map(run, range(len(batches))))  # list() re-raises worker errors
    return [row for batch in results for row in batch]


def process_blocks(conn, first_block, last_block):
    """Entry point called by haf_app_driver.py inside its transaction."""
    global _INDEXES_ENSURED
    cfg = _load_config(conn)
    cur = conn.cursor()
    # hivemind's pg_search BM25 index on hive_post_data makes paradedb emit
    # "Aggregate Scan (DataFusion) not used" warnings for our joins on every
    # range; not actionable here, so silence it (placeholder GUC, harmless
    # when pg_search isn't installed)
    cur.execute("SET paradedb.check_aggregate_scan = off")

    cur.execute("SELECT hive.get_current_stage_name('hivesense_app')")
    stage = cur.fetchone()[0]
    # massive sync tolerates redoing the range after a crash; skip the WAL flush wait
    cur.execute("SET LOCAL synchronous_commit = %s", ("off" if stage == "MASSIVE_PROCESSING" else "on",))

    if not _INDEXES_ENSURED:
        # Build the HNSW indexes at the massive -> live transition, or as soon as
        # this range reaches HAF's synced head (covers a --stop-at-block run that
        # ends inside the massive stage - the legacy scheduler built them on its
        # block-limit exit).
        cur.execute("SELECT consistent_block FROM hafd.hive_state")
        haf_head = cur.fetchone()[0]
        if stage == "live" or last_block >= haf_head:
            log.info("caught up (stage %s, block %s/%s): ensuring HNSW indexes exist "
                     "(may take a while the first time)", stage, last_block, haf_head)
            cur.execute("CALL hivesense_app.ensure_indexes_are_created()")
            _INDEXES_ENSURED = True

    cur.execute("SELECT hivesense_app.posts_in_range(%s, %s)", (first_block, last_block))
    post_ids = cur.fetchone()[0]
    if not post_ids:
        return

    t0 = time.monotonic()
    cur.execute("SELECT post_id, chunk_number, chunk_text FROM hivesense_app.prepare_post_chunks(%s)", (post_ids,))
    chunks = cur.fetchall()
    prep_secs = time.monotonic() - t0

    t1 = time.monotonic()
    vectors = _embed_chunks(cfg, chunks) if chunks else []
    embed_secs = time.monotonic() - t1

    cur.execute("CREATE TEMP TABLE tmp_vectors(post_id INT, chunk_number INT, vec public.vector) ON COMMIT DROP")
    if vectors:
        execute_values(
            cur,
            "INSERT INTO tmp_vectors(post_id, chunk_number, vec) VALUES %s",
            vectors,
            template="(%s, %s, %s::public.vector)",
            page_size=500,
        )
    cur.execute("SELECT * FROM hivesense_app.store_post_embeddings()")
    discarded, processed, stored_chunks, total_tokens = cur.fetchone()
    cur.execute("SELECT hivesense_app.publish_visible_sync_seq()")
    cur.execute("DROP TABLE tmp_vectors")
    cur.execute("DROP TABLE tmp_chunks")
    cur.execute("DROP TABLE tmp_pre")

    log.info(
        "blocks %s..%s: %s post(s), %s chunk(s), %s discarded, %s tokens; "
        "prep %.2fs, embed %.2fs (%.1f chunks/s)",
        first_block, last_block, processed, stored_chunks, discarded, total_tokens,
        prep_secs, embed_secs, (stored_chunks / embed_secs) if embed_secs > 0 else 0.0,
    )

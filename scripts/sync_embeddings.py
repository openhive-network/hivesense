import sys
import os
import time
import logging
import requests
import json
import asyncio
from requests.exceptions import RequestException
import psycopg
from psycopg.rows import dict_row
from datetime import datetime, timezone

API_URL = os.environ.get("HIVESENSE_API")   # e.g. https://upstream/
DB_DSN  = os.environ.get("POSTGRES_URI")         # postgres://…  (same schema names)


# Endpoints
STATUS_URL = f"{API_URL}/sync-settings"
EMBEDS_URL = f"{API_URL}/embedding-updates"

BATCH = 1000
RETRY_SLEEP = 3
MAX_BACKOFF = 60

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s"
)

def notice_processor(diag):
    """Process PostgreSQL NOTICE messages and log them."""
    msg = diag.message_primary
    if msg:
        logging.info("PG NOTICE: %s", msg)
        if diag.message_detail:
            logging.info("  DETAIL: %s", diag.message_detail)
        if diag.message_hint:
            logging.info("  HINT: %s", diag.message_hint)

def setup_notice_handler(conn):
    """Attach notice processor to connection."""
    conn.add_notice_handler(notice_processor)
    return conn

def ensure_connection_alive(conn):
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        return conn
    except (psycopg.OperationalError, psycopg.DatabaseError) as e:
        logging.warning("PostgreSQL connection was lost (%s). Reconnecting.", type(e).__name__)
        try:
            conn.close()
        except Exception:
            pass
        new_conn = psycopg.connect(DB_DSN)
        return setup_notice_handler(new_conn)

def fetch_server_status():
    backoff = RETRY_SLEEP
    while True:
        try:
            resp = requests.get(STATUS_URL, timeout=30)
            if not resp.ok:
                logging.warning("Server status API returned %s; retrying in %s s", resp.status_code, backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, MAX_BACKOFF)
                continue
            resp.raise_for_status()
            data = resp.json()
            break
        except (RequestException, json.JSONDecodeError) as e:
            logging.warning("Error fetching server status: %s; retrying in %s s", e, backoff)
            time.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF)

    # Unwrap list response from PostgREST composite function
    if isinstance(data, list):
        if not data:
            logging.error("Server status endpoint returned an empty list")
            sys.exit(1)
        data = data[0]
    return data


def validate_local_state(conn, server):
    with conn.cursor(row_factory=dict_row) as cur:
        # select all relevant config fields plus sync_uuid and syncing_embeddings
        cur.execute(
            "SELECT llm, embedding_dimensionality, document_prefix, query_prefix, "
            "tokens_per_chunk, overlap_amount, min_token_threshold, max_embeddings_per_post, "
            "syncing_embeddings, sync_uuid "
            "FROM hivesense_app.hivesense_app_status WHERE id = 1"
        )
        local = cur.fetchone()

        # Compare config keys (excluding sync_uuid)
        config_keys = [
            'llm', 'embedding_dimensionality', 'document_prefix', 'query_prefix',
            'tokens_per_chunk', 'overlap_amount', 'min_token_threshold', 'max_embeddings_per_post'
        ]
        errors = []
        for k in config_keys:
            # Special handling for float comparisons
            if k == 'overlap_amount':
                # Compare floats with tolerance
                if abs(float(local[k]) - float(server[k])) > 1e-6:
                    errors.append(k)
            else:
                if local[k] != server[k]:
                    errors.append(k)
        if errors:
            logging.error("Configuration mismatch for keys: %s", errors)
            sys.exit(1)

        local_uuid = local['sync_uuid']
        server_uuid = server['sync_uuid']
        # Initialize or validate sync_uuid
        if local_uuid is None:
            cur.execute(
                "UPDATE hivesense_app.hivesense_app_status SET sync_uuid = %s WHERE id = 1",
                (server_uuid,)
            )
            conn.commit()
            logging.info("Set initial sync_uuid to %s", server_uuid)
            return server_uuid
        elif str(local_uuid) != str(server_uuid):
            logging.error("sync_uuid mismatch (local=%s server=%s)", local_uuid, server_uuid)
            sys.exit(1)
        else:
            logging.info("sync_uuid matches server: %s", local_uuid)
            return str(local_uuid)


def get_last_seq(cur) -> int:
    cur.execute("""
        SELECT COALESCE(MAX(sync_seq), 0) FROM (
          SELECT MAX(sync_seq) AS sync_seq FROM hivesense_app.posts_vectors
          UNION ALL
          SELECT MAX(sync_seq)           FROM hivesense_app.deleted_embeddings
        ) AS t;
    """)
    return cur.fetchone()[0] or 0


POST_LOOKUP_SQL = """
SELECT hp.id
  FROM hivemind_app.hive_posts       hp
  JOIN hivemind_app.hive_accounts    ha  ON ha.id  = hp.author_id
  JOIN hivemind_app.hive_permlink_data pd ON pd.id = hp.permlink_id
 WHERE ha.name = %s
   AND pd.permlink = %s
 LIMIT 1;
"""


def resolve_post_id(cur, author, permlink):
    cur.execute(POST_LOOKUP_SQL, (author, permlink))
    row = cur.fetchone()
    return row[0] if row else None

def upsert_vectors(cur, post_id, sync_seq, embeddings):
    # Ensure all embedding values are floats (psycopg3 requires type consistency)
    rows = [
        (sync_seq, post_id, idx, [float(x) for x in emb])
        for idx, emb in enumerate(embeddings)
    ]
    # Use executemany for batch insert
    cur.executemany(
        """
        INSERT INTO hivesense_app.posts_vectors
          (sync_seq, post_id, chunk_number, embedding)
        VALUES (%s, %s, %s, %s)
        """,
        rows
    )

def apply_op(cur, op, post_id):
    """
    Apply a single operation; assumes post_id already resolved.
    """
    # ① always ensure metadata row exists before touching any FKs
    cur.execute(
        """
        INSERT INTO hivesense_app.post_data
          (post_id, number_of_tokens, last_vectors_block)
        VALUES (%s, %s, %s)
        ON CONFLICT (post_id) DO UPDATE
          SET number_of_tokens   = EXCLUDED.number_of_tokens,
              last_vectors_block = EXCLUDED.last_vectors_block
        """,
        (post_id,
         op.get("number_of_tokens", 0),
         op.get("last_vectors_block", 0))
    )
    cur.execute("""
        SELECT hivesense_app.use_reduced_embeddings()
    """)
    use_reduced_embeddings = cur.fetchone()[0]
    if op["op"] == "delete":
        cur.execute(
            "DELETE FROM hivesense_app.posts_vectors WHERE post_id = %s",
            (post_id,)
        )
        if use_reduced_embeddings:
            cur.execute(
                "DELETE FROM hivesense_app.posts_vectors_reduced WHERE post_id = %s",
                (post_id,)
            )
        cur.execute(
            """
            INSERT INTO hivesense_app.deleted_embeddings(post_id, sync_seq)
            VALUES (%s, %s)
            ON CONFLICT (sync_seq, post_id) DO NOTHING
            """,
            (post_id, op["sync_seq"])
        )
    else:
        cur.execute(
            "DELETE FROM hivesense_app.posts_vectors WHERE post_id = %s",
            (post_id,)
        )
        if use_reduced_embeddings:
            cur.execute(
                "DELETE FROM hivesense_app.posts_vectors_reduced WHERE post_id = %s",
                (post_id,)
            )
        upsert_vectors(cur, post_id, op["sync_seq"], op["embeddings"])
        # insert reduced vectors
        if use_reduced_embeddings:
            cur.execute("""
                INSERT INTO hivesense_app.posts_vectors_reduced
                    (post_id, chunk_number, reduced_embedding)
                SELECT
                    post_id,
                    chunk_number,
                    CASE
                        WHEN hivesense_app.store_halfvec_embeddings()
                             THEN hivesense_app.reduce_embedding(embedding::public.vector)::public.halfvec
                        ELSE hivesense_app.reduce_embedding(embedding::public.vector)
                    END
                FROM hivesense_app.posts_vectors
                WHERE post_id = %s
                ORDER BY chunk_number
            """, (post_id,))


async def create_indexes_with_live_notices(dsn):
    """Run index creation in async mode with live notice output."""
    async with await psycopg.AsyncConnection.connect(dsn) as aconn:
        # Register notice handler for async connection
        aconn.add_notice_handler(notice_processor)

        async with aconn.cursor() as acur:
            await acur.execute("CALL hivesense_app.ensure_indexes_are_created()")

        await aconn.commit()


def main():
    conn = psycopg.connect(DB_DSN)
    conn = setup_notice_handler(conn)

    # fetch server status and validate
    server_status = fetch_server_status()

    conn = ensure_connection_alive(conn)
    sync_uuid = validate_local_state(conn, server_status)

    with conn.cursor() as cur:
        cur.execute("""SELECT hive.app_context_is_attached('hivesense_app')""")
        if cur.fetchone()[0]:
            cur.execute("""SELECT hive.app_context_detach('hivesense_app')""")
        conn.commit()

    last_seen_current_block_num = None
    while True:
        conn = ensure_connection_alive(conn)

        # determine how far we've synced
        with conn.cursor() as cur:
            after_seq = get_last_seq(cur)
        # we may sleep just below, so rollback to avoid holding any locks
        conn.rollback()

        # fetch ops
        backoff = RETRY_SLEEP
        while True:
            try:
                response = requests.get(
                    EMBEDS_URL,
                    params={"after_seq": after_seq, "page_size": BATCH, "sync_uuid": sync_uuid},
                    timeout=60
                )
                if not response.ok:
                    logging.warning("Embedding-updates API returned %s; retrying in %s s",
                                     response.status_code, backoff)
                    time.sleep(backoff)
                    backoff = min(backoff * 2, MAX_BACKOFF)
                    continue
                response.raise_for_status()
                try:
                    ops = response.json()
                except (ValueError, json.JSONDecodeError) as e:
                    logging.warning("Invalid JSON from embedding-updates: %s; retrying in %s s", e, backoff)
                    time.sleep(backoff)
                    backoff = min(backoff * 2, MAX_BACKOFF)
                    continue
                break
            except RequestException as e:
                logging.warning("Error fetching embeddings: %s; retrying in %s s", e, backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, MAX_BACKOFF)

        # Make sure the DB handle is still alive after the (potentially long) HTTP loop above
        conn = ensure_connection_alive(conn)

        # manage the current_block_num stored in the context.  The way we manage it isn't perfect, but it's
        # probably fine for our usage.
        # When we get a list of ops from the server, we set our current_block_num to the higest one in the
        # list of ops.
        # When we get an empty list, we update the current_block_num to match the API server's.
        # That way, when we're well out-of-sync, we'll keep our current_block_num matching the last embedding
        # we've synced.  Once we're in sync, we'll advance our current_block_num to match the server, even if
        # blocks are going by without generating any new embedding-related events.
        if not ops:
            header_block = response.headers.get("X-Current-Block-Num")
            if header_block is None:
                logging.error("Missing X-Current-Block-Num header")
                sys.exit(1)
            current_block = int(header_block)
            if current_block != last_seen_current_block_num:
                with conn.cursor() as cur:
                    cur.execute("SELECT hive.app_set_current_block_num('hivesense_app', %s)", (current_block,))
                conn.commit()
                # Advance hivesense_app events_id so HAF can clean up events_queue
                with conn.cursor() as cur:
                    cur.execute("""
                        UPDATE hafd.contexts
                        SET events_id = sub.max_event_id
                        FROM (
                            SELECT COALESCE(MAX(id), 0) AS max_event_id
                            FROM hafd.events_queue
                            WHERE block_num <= %s
                              AND event != 'BACK_FROM_FORK'
                        ) sub
                        WHERE name = 'hivesense_app'
                          AND events_id < sub.max_event_id
                    """, (current_block,))
                conn.commit()
                last_seen_current_block_num = current_block
            time.sleep(3)
            continue

        # wait until hivemind has caught up to the highest block in this batch
        # deletes can have last_vectors_blocks that are higher than the block where the deletion took place
        block_nums = [op.get('last_vectors_block') for op in ops if op.get('last_vectors_block') is not None and op.get('op') != 'delete']
        max_block = max(block_nums) if block_nums else None
        if max_block is not None:
            while True:
                conn = ensure_connection_alive(conn)
                with conn.cursor() as cur:
                    cur.execute("SELECT hive.app_get_current_block_num('hivemind_app')")
                    head = cur.fetchone()[0]

                # rollback to avoid hold any locks on the context if we sleep below
                conn.rollback()

                if head >= max_block:
                    break
                logging.info(
                    "Waiting for hivemind head block %s (currently at %s)",
                    max_block, head
                )
                time.sleep(1)

        # resolve all post_ids (retry on missing posts)
        resolved = []  # list of tuples (op, post_id)
        with conn.cursor() as cur:
            for op in ops:
                post_id = resolve_post_id(cur, op["author"], op["permlink"])
                while post_id is None:
                    logging.warning(
                        "Post %s/%s not found after block %s; retrying in 1s",
                        op["author"], op["permlink"], max_block
                    )
                    # rollback to close the transaction and release the lock on hive_posts
                    conn.rollback()
                    time.sleep(1)
                    post_id = resolve_post_id(cur, op["author"], op["permlink"])
                resolved.append((op, post_id))

        max_last_vectors_block = 0
        # apply each operation in one batch transaction
        with conn.cursor() as cur:
            for op, post_id in resolved:
                last_vectors_block = op.get("last_vectors_block")
                if last_vectors_block > max_last_vectors_block:
                    max_last_vectors_block = last_vectors_block
                logging.info(
                    "Applying %s %s/%s (seq %s, block %s)",
                    op["op"], op["author"], op["permlink"],
                    op["sync_seq"], last_vectors_block
                )
                apply_op(cur, op, post_id)

            # advance local sequence & visibility
            max_seq = max(op["sync_seq"] for op, _ in resolved)
            cur.execute(
                "SELECT setval('hivesense_app.sync_seq', %s, true)",
                (max_seq,)
            )
            cur.execute(
                "UPDATE hivesense_app.hivesense_app_status SET max_visible_sync_seq = %s WHERE id = 1",
                (max_seq,)
            )
            if max_last_vectors_block != last_seen_current_block_num:
                cur.execute("SELECT hive.app_set_current_block_num('hivesense_app', %s)", (max_last_vectors_block,))
                last_seen_current_block_num = max_last_vectors_block

        conn.commit()
        # Advance hivesense_app events_id so HAF can clean up events_queue
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE hafd.contexts
                SET events_id = sub.max_event_id
                FROM (
                    SELECT COALESCE(MAX(id), 0) AS max_event_id
                    FROM hafd.events_queue
                    WHERE block_num <= %s
                      AND event != 'BACK_FROM_FORK'
                ) sub
                WHERE name = 'hivesense_app'
                  AND events_id < sub.max_event_id
            """, (max_last_vectors_block,))
        conn.commit()

        # Optionally create indexes if caught up
        if max_block is not None:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT created_at FROM hafd.blocks WHERE num = %s",
                    (max_block,)
                )
                row = cur.fetchone()
                if row:
                    created_at = row[0].replace(tzinfo=timezone.utc)
                    age = datetime.now(timezone.utc) - created_at
                    if age.total_seconds() <= 60:
                        logging.debug(
                            "Latest block %s is recent (%.1fs old); creating indexes",
                            max_block, age.total_seconds()
                        )
                        # Use async function for index creation with live notices
                        asyncio.run(create_indexes_with_live_notices(DB_DSN))

                        # Ensure main connection is still alive after long async operation
                        conn = ensure_connection_alive(conn)


if __name__ == "__main__":
    main()

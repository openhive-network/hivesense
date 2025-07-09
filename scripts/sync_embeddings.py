import os
import time
import logging
import requests
import psycopg2
from psycopg2.extras import execute_values, RealDictCursor
from datetime import datetime, timezone

API_URL = os.environ.get("HIVESENSE_API")   # e.g. https://upstream/
DB_DSN  = os.environ.get("POSTGRES_URI")         # postgres://…  (same schema names)


# Endpoints
STATUS_URL = f"{API_URL}/sync_settings"
EMBEDS_URL = f"{API_URL}/embedding-updates"

BATCH = 1000
RETRY_SLEEP = 3

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s"
)


def fetch_server_status():
    resp = requests.get(STATUS_URL, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    # Unwrap list response from PostgREST composite function
    if isinstance(data, list):
        if not data:
            logging.error("Server status endpoint returned an empty list")
            sys.exit(1)
        data = data[0]
    return data


def validate_local_state(conn, server):
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
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
        errors = [k for k in config_keys if local[k] != server[k]]
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
        elif local_uuid != server_uuid:
            logging.error("sync_uuid mismatch (local=%s server=%s)", local_uuid, server_uuid)
            sys.exit(1)
        else:
            logging.info("sync_uuid matches server: %s", local_uuid)
            return local_uuid


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
    rows = [
        (sync_seq, post_id, idx, emb)
        for idx, emb in enumerate(embeddings)
    ]
    psycopg2.extras.execute_values(
        cur,
        """
        INSERT INTO hivesense_app.posts_vectors
          (sync_seq, post_id, chunk_number, embedding)
        VALUES %s
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
    if op["op"] == "delete":
        cur.execute(
            "DELETE FROM hivesense_app.posts_vectors WHERE post_id = %s",
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
        upsert_vectors(cur, post_id, op["sync_seq"], op["embeddings"])


def main():
    conn = psycopg2.connect(DB_DSN)

    # fetch server status and validate
    server_status = fetch_server_status()
    sync_uuid = validate_local_state(conn, server_status)

    while True:
        # determine how far we've synced
        with conn.cursor() as cur:
            after_seq = get_last_seq(cur)

        response = requests.get(
            EMBEDS_URL,
            params={"after_seq": after_seq, "page_size": BATCH, "sync_uuid": sync_uuid},
            timeout=60
        )
        response.raise_for_status()
        ops = response.json()
        if not ops:
            time.sleep(5)
            continue

        # wait until hivemind has caught up to the highest block in this batch
        block_nums = [op.get('last_vectors_block') for op in ops if op.get('last_vectors_block') is not None]
        max_block = max(block_nums) if block_nums else None
        if max_block is not None:
            while True:
                with conn.cursor() as cur:
                    cur.execute("SELECT last_completed_block_num FROM hivemind_app.hive_state")
                    head = cur.fetchone()[0]
                if head >= max_block:
                    break
                logging.info(
                    "Waiting for hivemind head block %s (currently at %s)",
                    max_block, head
                )
                time.sleep(1)

        # resolve all post_ids (should now exist)
        resolved = []  # list of tuples (op, post_id)
        with conn.cursor() as cur:
            for op in ops:
                post_id = resolve_post_id(cur, op["author"], op["permlink"])
                if post_id is None:
                    raise RuntimeError(
                        f"Post {op['author']}/{op['permlink']} not found after block {max_block}"
                    )
                resolved.append((op, post_id))

        # apply each operation in one batch transaction
        with conn.cursor() as cur:
            for op, post_id in resolved:
                logging.info(
                    "Applying %s %s/%s (seq %s, block %s)",
                    op["op"], op["author"], op["permlink"],
                    op["sync_seq"], op.get("last_vectors_block")
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
                        logging.info(
                            "Latest block %s is recent (%.1fs old); creating indexes",
                            max_block, age.total_seconds()
                        )
                        cur.execute("CALL hivesense_app.ensure_indexes_are_created()")
                        conn.commit()


if __name__ == "__main__":
    main()

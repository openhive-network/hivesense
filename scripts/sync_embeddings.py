#! /usr/bin/env python3
"""
sync_embeddings.py  –  pull /embedding-updates and mirror them locally
"""

import os
import time
import logging
import requests
import psycopg2
from psycopg2.extras import execute_values
from datetime import datetime, timezone

API_URL = os.environ.get("HIVESENSE_EMBED_API")   # e.g. https://upstream/embedding-updates
DB_DSN  = os.environ.get("POSTGRES_URI")         # postgres://…  (same schema names)

BATCH = 1000
RETRY_SLEEP = 3

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s"
)


def get_last_seq(cur) -> int:
    cur.execute("""
        SELECT COALESCE(MAX(sync_seq), 0) FROM (
          SELECT MAX(sync_seq) AS sync_seq FROM hivesense_app.posts_vectors
          UNION ALL
          SELECT MAX(sync_seq)           FROM hivesense_app.deleted_embeddings
        ) AS t;
    """
    )
    return cur.fetchone()[0] or 0


POST_LOOKUP_SQL = """
SELECT hp.id
  FROM hivemind_app.hive_posts       hp
  JOIN hivemind_app.hive_accounts    ha  ON ha.id  = hp.author_id
  JOIN hivemind_app.hive_permlink_data pd ON pd.id = hp.permlink_id
 WHERE ha.name = %s
   AND pd.permlink = %s
   AND hp.counter_deleted = 0
 LIMIT 1;
"""


def resolve_post_id(cur, author, permlink):
    cur.execute(POST_LOOKUP_SQL, (author, permlink))
    row = cur.fetchone()
    return row[0] if row else None


def upsert_vectors(cur, post_id, sync_seq, embeddings):
    """
    embeddings: list of numeric lists, in chunk order.
    """
    rows = [
        (sync_seq, post_id, idx, emb)
        for idx, emb in enumerate(embeddings)
    ]
    execute_values(
        cur,
        """
        INSERT INTO hivesense_app.posts_vectors
          (sync_seq, post_id, chunk_number, embedding)
        VALUES %s
        """,
        rows
    )


def apply_op(conn, op):
    """Apply a single operation; block-retry until the post_id is resolvable."""
    while True:
        with conn.cursor() as cur:
            post_id = resolve_post_id(cur, op["author"], op["permlink"])
            if post_id is None:
                logging.info(
                    "Post %s/%s not yet present locally – retry in %ds",
                    op["author"], op["permlink"], RETRY_SLEEP
                )
                conn.rollback()
                time.sleep(RETRY_SLEEP)
                continue

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
            else:  # insert | update
                cur.execute(
                    "DELETE FROM hivesense_app.posts_vectors WHERE post_id = %s",
                    (post_id,)
                )
                upsert_vectors(cur, post_id, op["sync_seq"], op["embeddings"])
                cur.execute(
                    """
                    INSERT INTO hivesense_app.post_data
                      (post_id, number_of_tokens, last_vectors_block)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (post_id) DO UPDATE
                      SET number_of_tokens   = EXCLUDED.number_of_tokens,
                          last_vectors_block = EXCLUDED.last_vectors_block
                    """,
                    (post_id, op["number_of_tokens"], op["last_vectors_block"])
                )
            return  # success – caller will COMMIT


def main():
    conn = psycopg2.connect(DB_DSN, autocommit=False)

    while True:
        # determine how far we've synced
        with conn.cursor() as cur:
            after_seq = get_last_seq(cur)

        response = requests.get(
            API_URL,
            params={"after_seq": after_seq, "limit": BATCH},
            timeout=60
        )
        response.raise_for_status()
        ops = response.json()
        if not ops:
            time.sleep(5)
            continue

        # Track highest block seen
        block_nums = [op.get('last_vectors_block') for op in ops]
        max_block = max(block_nums) if block_nums else None

        # apply each operation
        for op in ops:
            logging.info(
                "Applying %s %s/%s (seq %s, block %s)",
                op["op"], op["author"], op["permlink"],
                op["sync_seq"], op.get("last_vectors_block")
            )
            apply_op(conn, op)
            conn.commit()

        # Advance local sequence & visibility
        max_seq = max(op["sync_seq"] for op in ops)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT setval('hivesense_app.sync_seq', %s, true)",
                (max_seq,)
            )
            cur.execute(
                "UPDATE hivesense_app.hivesense_app_status
                   SET max_visible_sync_seq = %s
                 WHERE id = 1",
                (max_seq,)
            )
        conn.commit()

        # If we're caught up, create indexes
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
                        cur.execute("CALL ensure_indexes_are_created()")
                        conn.commit()

if __name__ == "__main__":
    main()

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
    """)
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


def apply_op(cur, op, post_id):
    """
    Apply a single operation; assumes post_id already resolved.
    Uses a savepoint so individual ops can roll back without aborting the whole batch.
    """
    cur.execute("SAVEPOINT op_sp")
    try:
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
    except Exception:
        cur.execute("ROLLBACK TO SAVEPOINT op_sp")
        raise
    finally:
        cur.execute("RELEASE SAVEPOINT op_sp")


def main():
    conn = psycopg2.connect(DB_DSN, autocommit=False)
    # Fast-fail on deadlocks
    with conn.cursor() as cur:
        cur.execute("SET deadlock_timeout = '1s'")

    while True:
        # determine how far we've synced
        with conn.cursor() as cur:
            after_seq = get_last_seq(cur)

        response = requests.get(
            API_URL,
            params={"after_seq": after_seq, "page_size": BATCH},
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
                    cur.execute("SELECT hive.app_get_current_block_num('hivemind_app')")
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
                "UPDATE hivesense_app.hivesense_app_status
                   SET max_visible_sync_seq = %s
                 WHERE id = 1",
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

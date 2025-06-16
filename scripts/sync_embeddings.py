#! /usr/bin/env python3
"""
sync_embeddings.py  –  pull /embedding-updates and mirror them locally
"""

import os, time, json, logging, requests, psycopg2
from psycopg2.extras import execute_values

API_URL = os.environ["HS_EMBED_API"]   # e.g. https://upstream/embedding-updates
DB_DSN  = os.environ["LOCAL_PG_DSN"]   # postgres://…  (same schema names)

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


def upsert_vectors(cur, post_id, sync_seq, rows):
    payload = [
        (sync_seq, post_id, r["chunk_number"], r["embedding"])
        for r in rows
    ]
    execute_values(
        cur,
        """INSERT INTO hivesense_app.posts_vectors
           (sync_seq, post_id, chunk_number, embedding)
           VALUES %s""",
        payload
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
                continue  # try again
            # ---- we have a post_id ----
            if op["op"] == "delete":
                cur.execute(
                    "DELETE FROM hivesense_app.posts_vectors WHERE post_id = %s",
                    (post_id,)
                )
                cur.execute(
                    """INSERT INTO hivesense_app.deleted_embeddings(post_id, sync_seq)
                       VALUES (%s, %s)
                       ON CONFLICT (sync_seq, post_id) DO NOTHING""",
                    (post_id, op["sync_seq"])
                )
            else:  # insert  | update
                cur.execute(
                    "DELETE FROM hivesense_app.posts_vectors WHERE post_id = %s",
                    (post_id,)
                )
                upsert_vectors(cur, post_id, op["sync_seq"], op["embedding_rows"])
            return  # success – caller will COMMIT


def main():
    conn = psycopg2.connect(DB_DSN, autocommit=False)

    while True:
        with conn.cursor() as cur:
            after_seq = get_last_seq(cur)
        params = {"after_seq": after_seq, "limit": BATCH}
        r = requests.get(API_URL, params=params, timeout=60)
        r.raise_for_status()
        ops = r.json()
        if not ops:
            time.sleep(5)
            continue

        for op in ops:
            logging.info("Applying %s %s/%s (seq %s)",
                         op["op"], op["author"], op["permlink"], op["sync_seq"])
            apply_op(conn, op)
            conn.commit()    # durable after every logical op

if __name__ == "__main__":
    main()

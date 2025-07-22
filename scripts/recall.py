#!/usr/bin/env python3
import os
import json
import ast
import argparse
import psycopg2

def get_conn():
    uri = os.getenv("POSTGRES_URI")
    if not uri:
        raise RuntimeError("POSTGRES_URI must be set")
    return psycopg2.connect(uri)

def sample(args):
    """Sample N query vectors and dump to JSON."""
    N = args.num_queries
    out = args.output
    table = args.table
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(f"""
            WITH sample_vectors AS MATERIALIZED (
              SELECT post_id, chunk_number
              FROM {table}
              ORDER BY random()
              LIMIT %s
            )
            SELECT ha.name AS author,
                   hpl.permlink AS permlink,
                   sv.chunk_number AS chunk_number
            FROM sample_vectors sv
            JOIN hivemind_app.hive_posts hp ON sv.post_id = hp.id
            JOIN hivemind_app.hive_accounts ha ON hp.author_id = ha.id
            JOIN hivemind_app.hive_permlink_data hpl ON hp.permlink_id = hpl.id
        """, (N,))
        rows = cur.fetchall()

    queries = [{"author": a, "permlink": p, "chunk_number": c} for a,p,c in rows]
    with open(out, "w") as f:
        json.dump(queries, f)
    print(f"Saved {len(queries)} queries to {out}")

def search(args):
    """Run nearest-neighbor search in Postgres for each query."""
    import json

    # load queries
    with open(args.queries, "r") as f:
        queries = json.load(f)

    table     = args.table
    K         = args.topk
    disable_index = args.disable_index
    out       = args.output

    conn = get_conn()
    # 1) enable autocommit so parallel plans are allowed
    conn.autocommit = True
    cur = conn.cursor()

    # Force Postgres to always build a custom (parallel‐capable) plan,
    # even for extended‐protocol/prepared statements.
    cur.execute("SET plan_cache_mode = force_custom_plan;")

    # 2) tune parallel settings aggressively
    cur.execute(f"""
        SET max_parallel_workers_per_gather = {args.parallel_workers};
        SET parallel_setup_cost = 0;
        SET parallel_tuple_cost = 0;
    """)

    if disable_index:
        cur.execute("""
            SET enable_indexscan = off;
            SET enable_indexonlyscan = off;
            SET enable_bitmapscan = off;
        """)
        print("Index scans disabled (exact search).")

    # 3) use MATERIALIZED to force a single eval of the target vector
    sql = f"""
    WITH target_post AS MATERIALIZED (
      SELECT pv.post_id, pv.embedding
      FROM {table} pv
      JOIN hivemind_app.hive_posts hp  ON pv.post_id   = hp.id
      JOIN hivemind_app.hive_accounts ha ON hp.author_id = ha.id
      JOIN hivemind_app.hive_permlink_data hpl ON hp.permlink_id = hpl.id
      WHERE ha.name     = %s
        AND hpl.permlink = %s
        AND pv.chunk_number = %s
    ),
    best_matches AS (
      SELECT
        pv.post_id,
        pv.chunk_number,
        pv.embedding <=> tp.embedding AS distance
      FROM {table} pv
      CROSS JOIN target_post tp
      WHERE NOT (
        pv.post_id     = tp.post_id
        AND pv.chunk_number = %s
      )
      ORDER BY distance
      LIMIT %s
    )
    SELECT
      ha.name        AS author,
      hpl.permlink,
      bm.chunk_number,
      bm.distance
    FROM best_matches bm
    JOIN hivemind_app.hive_posts hp  ON bm.post_id   = hp.id
    JOIN hivemind_app.hive_accounts ha ON hp.author_id = ha.id
    JOIN hivemind_app.hive_permlink_data hpl ON hp.permlink_id = hpl.id
    ORDER BY bm.distance;
    """

    results = []
    for idx, q in enumerate(queries, start=1):
        author, permlink, chunk = q["author"], q["permlink"], q["chunk_number"]
        print(f"[{idx}/{len(queries)}] @{author}/{permlink} chunk {chunk}")
        cur.execute(sql, (author, permlink, chunk, chunk, K))

        neigh = [
            {"author": row[0], "permlink": row[1],
             "chunk_number": row[2], "distance": row[3]}
            for row in cur.fetchall()
        ]
        results.append({"query": q, "neighbors": neigh})

        # keep the output file live
        with open(out, "w") as f:
            json.dump(results, f)

    print(f"Saved {len(results)} queries × top {K} to {out}")

def analyze(args):
    """Compute recall@k between two result files."""
    gt = json.load(open(args.gt))
    ann = json.load(open(args.ann))

    def key_of(entry):
        q = entry["query"]
        return f"{q['author']}:{q['permlink']}:{q['chunk_number']}"

    def neighbor_keys(entry):
        return [f"{n['author']}:{n['permlink']}:{n['chunk_number']}"
                for n in entry["neighbors"]]

    gt_map  = {key_of(e): neighbor_keys(e) for e in gt}
    ann_map = {key_of(e): neighbor_keys(e) for e in ann}

    for k in args.k:
        vals = []
        for key, true_list in gt_map.items():
            pred = ann_map.get(key, [])
            vals.append(len(set(true_list[:k]) & set(pred[:k])) / k)
        avg = sum(vals) / len(vals) if vals else 0.0
        print(f"recall@{k}: {avg:.4f} (n={len(vals)})")

def main():
    p = argparse.ArgumentParser("Recall@k tool")
    p.add_argument("-t", "--table",
                   default=os.getenv("VECTOR_TABLE", "hivesense_app.posts_vectors"),
                   help="Source vector table (schema.table)")
    sub = p.add_subparsers(dest="cmd", required=True)

    samp = sub.add_parser("sample", help="Sample random queries")
    samp.add_argument("--num-queries", type=int,
                      default=int(os.getenv("RECALL_SAMPLE_SIZE","1000")))
    samp.add_argument("--output", "-o", required=True)
    samp.set_defaults(func=sample)

    sch = sub.add_parser("search", help="Run search in Postgres")
    sch.add_argument("--queries", "-i", required=True)
    sch.add_argument("--topk", type=int, default=20)
    sch.add_argument("--disable-index", action="store_true")
    sch.add_argument("--output", "-o", required=True)
    sch.add_argument("-p","--parallel-workers", type=int,
                     default=int(os.getenv("PARALLEL_WORKERS","8")),
                     help="GUC max_parallel_workers_per_gather")
    sch.set_defaults(func=search)

    an = sub.add_parser("analyze", help="Compute recall@k")
    an.add_argument("--gt", required=True)
    an.add_argument("--ann", required=True)
    an.add_argument("-k", type=int, nargs="+", default=[1,5,10,20])
    an.set_defaults(func=analyze)

    args = p.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()


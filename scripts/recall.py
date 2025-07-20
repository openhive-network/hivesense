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
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(f"""
            WITH sample_vectors as MATERIALIZED (
              SELECT post_id, chunk_number
              FROM hivesense_app.posts_vectors
              ORDER BY random()
              LIMIT %s
            )
            SELECT ha.name as author, hpl.permlink as permlink, sv.chunk_number as chunk
            FROM sample_vectors sv
            JOIN hivemind_app.hive_posts hp on sv.post_id = hp.id
            JOIN hivemind_app.hive_accounts ha on hp.author_id = ha.id
            JOIN hivemind_app.hive_permlink_data hpl on hp.permlink_id = hpl.id
        """, (N,))
        rows = cur.fetchall()

    queries = []
    for author, permlink, chunk in rows:
        queries.append({
            "author": author,
            "permlink": permlink,
            "chunk_number": chunk
        })

    with open(out, "w") as f:
        json.dump(queries, f)
    print(f"Saved {len(queries)} queries to {out}")

def search(args):
    """Run nearest-neighbor search in Postgres for each query (by author+permlink+chunk)."""
    import json

    # load queries (author, permlink, chunk_number)
    with open(args.queries, "r") as f:
        queries = json.load(f)

    K = args.topk
    disable_index = args.disable_index
    out = args.output

    conn = get_conn()
    cur = conn.cursor()
    if disable_index:
        cur.execute("""
            SET enable_indexscan = off;
            SET enable_indexonlyscan = off;
            SET enable_bitmapscan = off;
        """)
        print("Index scans disabled (exact search).")

    sql = """
    WITH target_post AS (
      SELECT pv.post_id, pv.embedding
      FROM hivesense_app.posts_vectors pv
      JOIN hivemind_app.hive_posts hp ON pv.post_id = hp.id
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
        pv.embedding <=> tgt.embedding AS distance
      FROM hivesense_app.posts_vectors pv
      CROSS JOIN target_post AS tgt
      WHERE NOT (
        pv.post_id     = tgt.post_id
        AND pv.chunk_number = %s
      )
      ORDER BY distance
      LIMIT %s
    )
    SELECT
      ha.name   AS author,
      hpl.permlink,
      bm.chunk_number AS chunk_number,
      bm.distance
    FROM best_matches bm
    JOIN hivemind_app.hive_posts hp ON bm.post_id = hp.id
    JOIN hivemind_app.hive_accounts ha ON hp.author_id = ha.id
    JOIN hivemind_app.hive_permlink_data hpl ON hp.permlink_id = hpl.id
    ORDER BY bm.distance;
    """

    results = []
    for idx, q in enumerate(queries, start = 1):
        author   = q["author"]
        permlink = q["permlink"]
        chunk    = q["chunk_number"]

        print(f"Getting top {K} exact nearest neighbors for embedding {idx}/{len(queries)}: @{author}/{permlink} chunk {chunk}")

        # execute with params: author, permlink, chunk, chunk (for self-exclude), K
        cur.execute(sql, (author, permlink, chunk, chunk, K))
        neigh = [
            {
              "author":  row[0],
              "permlink":row[1],
              "chunk_number": row[2],
              "distance": row[3]
            }
            for row in cur.fetchall()
        ]

        results.append({
            "query": {
              "author": author,
              "permlink": permlink,
              "chunk_number": chunk
            },
            "neighbors": neigh
        })

        with open(out, "w") as f:
            json.dump(results, f)
    print(f"Saved search results ({len(results)} queries × top {K}) to {out}")

def analyze(args):
    """Compute recall@k between two result files (using author/permlink/chunk keys)."""
    import json

    with open(args.gt, "r") as f:
        gt = json.load(f)
    with open(args.ann, "r") as f:
        ann = json.load(f)

    # build mapping: key -> list of neighbor keys
    def key_of(entry):
        q = entry["query"]
        return f"{q['author']}:{q['permlink']}:{q['chunk_number']}"

    def neighbor_keys(entry):
        return [
            f"{n['author']}:{n['permlink']}:{n['chunk_number']}"
            for n in entry["neighbors"]
        ]

    gt_map  = { key_of(e): neighbor_keys(e) for e in gt  }
    ann_map = { key_of(e): neighbor_keys(e) for e in ann }

    ks = args.k
    recalls = {k: [] for k in ks}

    for key, true_list in gt_map.items():
        pred_list = ann_map.get(key, [])
        for k in ks:
            top_true = set(true_list[:k])
            top_pred = set(pred_list[:k])
            recalls[k].append(len(top_true & top_pred) / k)

    print("recall@k results:")
    for k in ks:
        vals = recalls[k]
        avg = sum(vals) / len(vals) if vals else 0.0
        print(f"  @ {k:3d}: {avg:.4f}  (n={len(vals)})")

def main():
    p = argparse.ArgumentParser(description="Recall@k benchmarking tool")
    sub = p.add_subparsers(dest="cmd", required=True)

    # sample
    samp = sub.add_parser("sample", help="Sample random queries")
    samp.add_argument("--num-queries", type=int, default=int(os.getenv("RECALL_SAMPLE_SIZE", "1000")),
                      help="Number of queries to sample (default 1000 or RECALL_SAMPLE_SIZE)")
    samp.add_argument("--output", "-o", required=True, help="Output JSON file for sample")
    samp.set_defaults(func=sample)

    # search
    sch = sub.add_parser("search", help="Run search (exact or indexed) in Postgres")
    sch.add_argument("--queries", "-i", required=True, help="Input JSON file of queries")
    sch.add_argument("--topk", type=int, default=20, help="How many neighbors to fetch per query")
    sch.add_argument("--disable-index", action="store_true",
                     help="Disable Postgres index usage (force full scan)")
    sch.add_argument("--output", "-o", required=True, help="Output JSON file for search results")
    sch.set_defaults(func=search)

    # analyze
    an = sub.add_parser("analyze", help="Compute recall@k between two result sets")
    an.add_argument("--gt", required=True, help="Ground-truth JSON (exact search)")
    an.add_argument("--ann", required=True, help="ANN/indexed JSON")
    an.add_argument("-k", type=int, nargs="+", default=[1,5,10,20],
                    help="List of k values for recall@k")
    an.set_defaults(func=analyze)

    args = p.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()

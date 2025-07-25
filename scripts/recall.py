#!/usr/bin/env python3
import os
import json
import ast
import argparse
import psycopg2
import time

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
    import json, time
    from psycopg2 import sql

    conn = get_conn()
    conn.autocommit = True
    cur = conn.cursor()

    # force custom plans + parallel as before
    cur.execute("SET plan_cache_mode = force_custom_plan;")
    cur.execute(f"""
        SET max_parallel_workers_per_gather = {args.parallel_workers};
        SET parallel_setup_cost = 0;
        SET parallel_tuple_cost = 0;
    """)

    results = []
    queries = json.load(open(args.queries))
    for idx, q in enumerate(queries, start=1):
        author, permlink, chunk = q["author"], q["permlink"], q["chunk_number"]
        print(f"[{idx}/{len(queries)}] @{author}/{permlink} chunk {chunk}")

        schema, tbl = args.table.split(".", 1)
        tbl_ident = sql.Identifier(schema, tbl)
        qualified = f"{schema}.{tbl}"

        # 1) Fetch the target embedding AS TEXT
        cur.execute(sql.SQL("""
            SELECT embedding::text, post_id
              FROM {table}
             WHERE post_id = (
               SELECT hp.id
                 FROM hivemind_app.hive_accounts ha
                 JOIN hivemind_app.hive_posts hp
                   ON ha.id = hp.author_id
                 JOIN hivemind_app.hive_permlink_data hpl
                   ON hp.permlink_id = hpl.id
                WHERE ha.name     = %s
                  AND hpl.permlink = %s
             )
               AND chunk_number = %s
        """).format(table=tbl_ident),
        (author, permlink, chunk))
        (vect, post_id) = cur.fetchone()  # vect is "[0.1,-0.2,…]"

        # 2) Do the ANN scan, either forcing a full scan (disable-index)
        #    or forcing index usage (default)
        if args.disable_index:
            cur.execute(
                "SET enable_indexscan = off; "
                "SET enable_indexonlyscan = off; "
                "SET enable_bitmapscan = off;"
            )
            print("  → index scans disabled; doing full scan for ground truth")
        else:
            cur.execute(
                "SET enable_seqscan = off; "
                "SET enable_bitmapscan = off;"
            )
            print("  → seqscan disabled; will use HNSW index")

        cur.execute(f"SET hnsw.ef_search = {args.ef_search};")

        start = time.perf_counter()
        cur.execute(f"""
            WITH best AS (
              SELECT post_id, chunk_number,
                     embedding::halfvec(128) <=> '{vect}'::halfvec(128) AS distance
                FROM {qualified}
               WHERE NOT (post_id = %s AND chunk_number = %s)
               ORDER BY distance
               LIMIT %s
            )
            SELECT post_id, chunk_number, distance
              FROM best
        """, (post_id, chunk, args.topk))
        neighbors = cur.fetchall()
        elapsed = time.perf_counter() - start
        print(f"    ANN scan took {elapsed:.3f}s")

        # 3) Reset all planner tweaks so the join uses normal indexes again
        cur.execute(
            "RESET enable_indexscan; "
            "RESET enable_indexonlyscan; "
            "RESET enable_bitmapscan; "
            "RESET enable_seqscan;"
        )

        # normalize to Python types
        neighbors = [(pid, ch, float(dist)) for (pid, ch, dist) in neighbors]

        # 4) Join just those rows back to names/permlinks via B-trees
        vals = sql.SQL(",").join(sql.SQL("(%s,%s,%s)") for _ in neighbors)
        flat = [col for row in neighbors for col in row]
        join_q = sql.SQL("""
            SELECT ha.name,
                   hpl.permlink,
                   b.chunk_number,
                   b.distance
              FROM (VALUES {vals}) AS b(post_id,chunk_number,distance)
              JOIN hivemind_app.hive_posts          hp  ON b.post_id    = hp.id
              JOIN hivemind_app.hive_permlink_data hpl ON hp.permlink_id = hpl.id
              JOIN hivemind_app.hive_accounts      ha  ON hp.author_id  = ha.id
             ORDER BY b.distance;
        """).format(vals=vals)
        cur.execute(join_q, flat)

        final = [
            {"author": a, "permlink": p, "chunk_number": c, "distance": float(d)}
            for (a, p, c, d) in cur.fetchall()
        ]

        results.append({"query": q, "neighbors": final})
        with open(args.output, "w") as f:
            json.dump(results, f)

    print(f"Saved {len(results)} queries × top {args.topk} to {args.output}")

def analyze(args):
    """Compute recall@k and simulated reranking recall@k@c between two result files."""
    import json

    # Load ground truth and ANN results
    gt = json.load(open(args.gt))
    ann = json.load(open(args.ann))

    # Helper to build a unique key for each query
    def key_of(entry):
        q = entry["query"]
        return f"{q['author']}:{q['permlink']}:{q['chunk_number']}"

    # Helper to extract the neighbor keys from an entry
    def neighbor_keys(entry):
        return [
            f"{n['author']}:{n['permlink']}:{n['chunk_number']}"
            for n in entry["neighbors"]
        ]

    # Build maps: query key -> list of true neighbor keys / ANN neighbor keys
    gt_map  = { key_of(e): neighbor_keys(e) for e in gt  }
    ann_map = { key_of(e): neighbor_keys(e) for e in ann }

    ks = args.k
    cs = sorted(args.candidates)

    # Prepare storage: for each k, a base list and one list per candidate-pool c
    # results[k]["base"] = [recall@k for each query]
    # results[k][c]    = [simulated recall@k@c for each query]
    results = {
        k: {"base": [], **{c: [] for c in cs}}
        for k in ks
    }

    # Compute recalls
    for key, true_list in gt_map.items():
        pred_list = ann_map.get(key, [])
        for k in ks:
            top_true = set(true_list[:k])

            # base recall@k using the ANN top-k
            top_pred_k = set(pred_list[:k])
            results[k]["base"].append(len(top_true & top_pred_k) / k)

            # simulated rerank: true@k within ANN top-c
            for c in cs:
                candidate_set = set(pred_list[:c])
                results[k][c].append(len(top_true & candidate_set) / k)

    # Print a table:
    #    k   base   @c100   @c500   @c1000   ...
    header = ["k", "base"] + [f"@c{c}" for c in cs]
    print("  ".join(f"{h:>7}" for h in header))

    for k in ks:
        line = [str(k)]
        # base recall
        base_vals = results[k]["base"]
        base_avg  = sum(base_vals) / len(base_vals) if base_vals else 0.0
        line.append(f"{base_avg:.4f}")
        # each candidate-pool recall
        for c in cs:
            vals = results[k][c]
            avg  = sum(vals) / len(vals) if vals else 0.0
            line.append(f"{avg:.4f}")
        print("  ".join(f"{v:>7}" for v in line))

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
    sch.add_argument("--ef-search", type=int, default=40)
    sch.add_argument("--disable-index", action="store_true")
    sch.add_argument("--output", "-o", required=True)
    sch.add_argument("-p","--parallel-workers", type=int,
                     default=int(os.getenv("PARALLEL_WORKERS","8")),
                     help="GUC max_parallel_workers_per_gather")
    sch.set_defaults(func=search)

    an = sub.add_parser("analyze", help="Compute recall@k")
    an.add_argument("--gt", required=True)
    an.add_argument("--ann", required=True)
    an.add_argument("-k", type=int, nargs="+", default=[1,5,10,20],
                    help="List of k values for recall@k")
    an.add_argument("-c","--candidates", type=int, nargs="+",
                    default=[100,500,1000],
                    help="Candidate-pool sizes to simulate reranking (default: 100 500 1000)")

    an.set_defaults(func=analyze)

    args = p.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()


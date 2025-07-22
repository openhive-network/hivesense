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
    import json, os
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

        # split schema and table so Identifier() works correctly
        schema, tbl = args.table.split(".", 1)
        tbl_ident = sql.Identifier(schema, tbl)

        # 1) Fetch target embedding
        cur.execute(sql.SQL("""
            SELECT embedding
              FROM {table}
             WHERE post_id = (
               SELECT hp.id
               FROM hivemind_app.hive_accounts ha
               JOIN hivemind_app.hive_posts hp
                 ON ha.id = hp.author_id
               JOIN hivemind_app.hive_permlink_data hpl
                 ON hp.permlink_id = hpl.id
               WHERE ha.name = %s
                 AND hpl.permlink = %s
             )
               AND chunk_number = %s
        """).format(table=tbl_ident),
        (author, permlink, chunk))
        (emb,) = cur.fetchone()

        # 2) Nearest‐neighbor brute‐force over vectors only
        cur.execute("SET enable_indexscan = off; SET enable_indexonlyscan = off;")
        cur.execute(sql.SQL("""
            WITH best AS (
              SELECT post_id, chunk_number,
                     embedding <=> %s AS distance
                FROM {table}
               WHERE NOT (post_id = (
                   SELECT hp.id
                     FROM hivemind_app.hive_accounts ha
                     JOIN hivemind_app.hive_posts hp
                       ON ha.id = hp.author_id
                     JOIN hivemind_app.hive_permlink_data hpl
                       ON hp.permlink_id = hpl.id
                    WHERE ha.name = %s
                      AND hpl.permlink = %s
                 )
                 AND chunk_number = %s)
               ORDER BY distance
               LIMIT %s
            )
            SELECT post_id, chunk_number, distance FROM best
        """).format(table=tbl_ident),
        (emb, author, permlink, chunk, args.topk))
        neighbors = cur.fetchall()
        # make sure the distance is a float
        neighbors = [(pid, chunk, float(dist)) for (pid,chunk,dist) in neighbors]

        # re-enable index scans for the join
        cur.execute("RESET enable_indexscan; RESET enable_indexonlyscan;")

        # 3) Join just those K rows back to names & permlinks via B-trees
        vals = sql.SQL(',').join(sql.SQL("(%s,%s,%s)") for _ in neighbors)
        flat = [col for row in neighbors for col in row]
        cur.execute(sql.SQL("""
            SELECT ha.name, hpl.permlink, b.chunk_number, b.distance
              FROM (VALUES {vals}) AS b(post_id,chunk_number,distance)
              JOIN hivemind_app.hive_posts       hp  ON b.post_id = hp.id
              JOIN hivemind_app.hive_permlink_data hpl ON hp.permlink_id = hpl.id
              JOIN hivemind_app.hive_accounts   ha  ON hp.author_id = ha.id
             ORDER BY b.distance;
        """).format(vals=vals), flat)

        final = [
          {"author": a, "permlink": p, "chunk_number": c, "distance": float(d)}
          for (a,p,c,d) in cur.fetchall()
        ]

        results.append({"query": q, "neighbors": final})
        with open(args.output, "w") as f:
            json.dump(results, f)

    print(f"Saved {len(results)} queries × top {args.topk} to {args.output}")

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


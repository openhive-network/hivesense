#!/usr/bin/env python3
import os
import sys
import ast
import argparse
import psycopg2
from psycopg2.extras import DictCursor, execute_values
import numpy as np
import json
import time
import datetime

def parse_embedding(raw):
    if isinstance(raw, (bytes, memoryview)):
        buf = raw if isinstance(raw, (bytes, bytearray)) else raw.tobytes()
        return np.frombuffer(buf, dtype=np.float16).astype(np.float32)
    if isinstance(raw, str):
        return np.array(ast.literal_eval(raw), dtype=np.float32)
    raise TypeError(f"Unrecognized embedding type: {type(raw)}")

def main():
    p = argparse.ArgumentParser(description="Convert embeddings via PCA to a new table")
    p.add_argument("-m","--matrix-path",
                   default=os.getenv("PCA_MATRIX_PATH","pca_projection_matrix.npy"),
                   help="Path to PCA projection matrix (.npy)")
    p.add_argument("-b","--batch-size", type=int,
                   default=int(os.getenv("BATCH_SIZE","100000")),
                   help="Number of vectors to process per batch")
    p.add_argument("-i","--input-table",
                   default=os.getenv("INPUT_TABLE","hivesense_app.posts_vectors"),
                   help="Source table with original embeddings")
    p.add_argument("-o","--output-table",
                   default=os.getenv("OUTPUT_TABLE","hivesense_app.posts_vectors_reduced"),
                   help="Destination table for reduced embeddings")
    args = p.parse_args()

    DB = os.getenv("POSTGRES_URI")
    if not DB:
        print("ERROR: POSTGRES_URI must be set", file=sys.stderr)
        sys.exit(1)

    print(f"Loading PCA matrix from {args.matrix_path}...")
    proj = np.load(args.matrix_path).astype(np.float32)
    M, D = proj.shape
    print(f"Projecting {D}-dim -> {M}-dim")

    # Connect for metadata and writes
    writer = psycopg2.connect(DB)
    writer.autocommit = True
    with writer.cursor() as c:
        c.execute(f"""
           CREATE TABLE IF NOT EXISTS {args.output_table} (
             post_id int not null,
             chunk_number int not null,
             embedding public.halfvec({M}) not null,
             sync_seq int not null,
             primary key(post_id,chunk_number)
           )
        """)

        # count total rows for ETA
        c.execute(f"SELECT count(*) FROM {args.input_table}")
        total_rows = c.fetchone()[0]
    print(f"Table ready: {args.output_table} ({total_rows:,} total embeddings)")

    # Reader connection for streaming
    reader = psycopg2.connect(DB)
    reader.autocommit = False
    src = reader.cursor(name="reader", cursor_factory=DictCursor)
    src.itersize = args.batch_size
    src.execute(f"SELECT post_id,chunk_number,sync_seq,embedding FROM {args.input_table} ORDER BY post_id,chunk_number")

    total = 0
    start = time.time()

    while True:
        batch = src.fetchmany(args.batch_size)
        if not batch:
            break

        ids = [(r["post_id"], r["chunk_number"], r["sync_seq"]) for r in batch]
        X = np.stack([parse_embedding(r["embedding"]) for r in batch])
        Y = X.dot(proj.T)
        norms = np.linalg.norm(Y, axis=1, keepdims=True)
        Y = np.divide(Y, norms, where=(norms > 0))

        rows = []
        for (pid,chunk,sync), vec in zip(ids, Y):
            rows.append((pid, chunk, json.dumps(vec.tolist()), sync))

        with writer.cursor() as ins_cur:
            execute_values(
                ins_cur,
                f"INSERT INTO {args.output_table} (post_id,chunk_number,embedding,sync_seq) VALUES %s",
                rows,
                template=f"(%s,%s,%s::halfvec({M}),%s)"
            )

        total += len(batch)
        elapsed = time.time() - start
        rps = total / elapsed if elapsed > 0 else 0
        remaining = total_rows - total
        eta = remaining / rps if rps > 0 else 0
        eta_str = str(datetime.timedelta(seconds=int(eta)))

        print(f"Processed {total:,}/{total_rows:,} rows "
              f"({rps:,.0f} rows/s, ETA {eta_str})")

    print(f"Done. {total:,} embeddings written to {args.output_table}")

if __name__=="__main__":
    main()


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
import multiprocessing

def parse_embedding(raw):
    if isinstance(raw, (bytes, memoryview)):
        buf = raw if isinstance(raw, (bytes, bytearray)) else raw.tobytes()
        return np.frombuffer(buf, dtype=np.float16).astype(np.float32)
    if isinstance(raw, str):
        return np.array(ast.literal_eval(raw), dtype=np.float32)
    raise TypeError(f"Unrecognized embedding type: {type(raw)}")

def worker_main(worker_id, seq_start, seq_end, args, proj, M, total_rows, start_time):
    """Process a sync_seq range [seq_start, seq_end]."""
    DB = os.getenv("POSTGRES_URI")
    reader = psycopg2.connect(DB)
    reader.autocommit = False
    src = reader.cursor(name=f"reader_{worker_id}", cursor_factory=DictCursor)
    src.itersize = args.batch_size
    writer = psycopg2.connect(DB)
    writer.autocommit = True

    # Stream only rows in this worker's range
    src.execute(f"""
        SELECT post_id, chunk_number, sync_seq, embedding
        FROM {args.input_table}
        WHERE sync_seq BETWEEN %s AND %s
        ORDER BY sync_seq
    """, (seq_start, seq_end))

    processed = 0
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
        for (pid, chunk, sync), vec in zip(ids, Y):
            rows.append((pid, chunk, json.dumps(vec.tolist()), sync))

        with writer.cursor() as ins_cur:
            execute_values(
                ins_cur,
                f"INSERT INTO {args.output_table} (post_id,chunk_number,embedding,sync_seq) VALUES %s",
                rows,
                template=f"(%s,%s,%s::halfvec({M}),%s)"
            )

        processed += len(batch)
        # compute overall stats
        total_done = worker_main.shared_processed.add_and_get(len(batch))
        elapsed = time.time() - start_time.value
        rps = total_done / elapsed if elapsed > 0 else 0
        remaining = total_rows - total_done
        eta = remaining / rps if rps > 0 else 0
        eta_str = str(datetime.timedelta(seconds=int(eta)))
        print(f"[W{worker_id}] Batch {processed:,} rows processed, " +
              f"TOTAL {total_done:,}/{total_rows:,} rows ({rps:,.0f} rows/s, ETA {eta_str})")
    reader.close()
    writer.close()

class SharedCounter:
    """A synchronized shared counter."""
    def __init__(self, initial=0):
        self.val = multiprocessing.Value('i', initial)
        self.lock = multiprocessing.Lock()
    def add_and_get(self, delta):
        with self.lock:
            self.val.value += delta
            return self.val.value

def main():
    p = argparse.ArgumentParser(description="Convert embeddings via PCA to a new table (parallel)")
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
    p.add_argument("-w","--workers", type=int,
                   default=int(os.getenv("WORKERS", multiprocessing.cpu_count())),
                   help="Number of parallel worker processes")
    args = p.parse_args()

    DB = os.getenv("POSTGRES_URI")
    if not DB:
        print("ERROR: POSTGRES_URI must be set", file=sys.stderr)
        sys.exit(1)

    print(f"Loading PCA matrix from {args.matrix_path}...")
    proj = np.load(args.matrix_path).astype(np.float32)
    M, D = proj.shape
    print(f"Projecting {D}-dim -> {M}-dim")

    # Ensure output table exists
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
    print("Ensured table:", args.output_table)

    # Fetch global sync_seq min/max and total rows
    with writer.cursor() as c:
        c.execute(f"SELECT MIN(sync_seq), MAX(sync_seq), COUNT(*) FROM {args.input_table}")
        min_seq, max_seq, total_rows = c.fetchone()
    print(f"Total embeddings: {total_rows:,}, sync_seq range [{min_seq}..{max_seq}]")

    # Prepare shared counter and start time
    worker_main.shared_processed = SharedCounter(0)
    start_time = multiprocessing.Value('d', time.time())

    # Divide the sync_seq range among workers
    seq_range = max_seq - min_seq + 1
    jobs = []
    for i in range(args.workers):
        start = min_seq + (i * seq_range) // args.workers
        end = min_seq + ((i + 1) * seq_range) // args.workers - 1
        if i == args.workers - 1:
            end = max_seq
        p = multiprocessing.Process(target=worker_main,
                                    args=(i, start, end, args, proj, M, total_rows, start_time))
        p.start()
        jobs.append(p)

    # Wait for completion
    for p in jobs:
        p.join()

    print("All workers complete.")

if __name__=="__main__":
    main()

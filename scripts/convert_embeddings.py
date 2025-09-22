#!/usr/bin/env python3
import os
import sys
import ast
import argparse
import psycopg2
from psycopg2.extras import DictCursor, execute_values
import numpy as np
import json
import gzip
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

def worker_main(worker_id, seq_start, seq_end, args, proj, M, total_rows, start_time, store_halfvec):
    """Process a sync_seq range [seq_start, seq_end]."""
    DB = os.getenv("POSTGRES_URI")
    reader = psycopg2.connect(DB)
    reader.autocommit = False
    src = reader.cursor(name=f"reader_{worker_id}", cursor_factory=DictCursor)
    src.itersize = args.batch_size
    writer = psycopg2.connect(DB)
    writer.autocommit = True

    # Determine the correct type cast based on store_halfvec setting
    type_cast = f"halfvec({M})" if store_halfvec else f"vector({M})"

    # Stream only rows in this worker's range (using sync_seq for ordering but not storing it)
    src.execute(f"""
        SELECT post_id, chunk_number, embedding
        FROM {args.input_table}
        WHERE sync_seq BETWEEN %s AND %s
        ORDER BY sync_seq
    """, (seq_start, seq_end))

    processed = 0
    while True:
        batch = src.fetchmany(args.batch_size)
        if not batch:
            break

        # Extract embeddings and compute projections
        X = np.stack([parse_embedding(r["embedding"]) for r in batch])
        Y = X.dot(proj.T)
        norms = np.linalg.norm(Y, axis=1, keepdims=True)
        Y = np.divide(Y, norms, where=(norms > 0))

        rows = []
        for r, vec in zip(batch, Y):
            rows.append((r["post_id"], r["chunk_number"], json.dumps(vec.tolist())))

        with writer.cursor() as ins_cur:
            execute_values(
                ins_cur,
                f"INSERT INTO {args.output_table} (post_id,chunk_number,reduced_embedding) VALUES %s",
                rows,
                template=f"(%s,%s,%s::{type_cast})"
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

def load_matrix(matrix_path):
    """Load projection matrix from JSON or numpy format."""
    print(f"Loading projection matrix from {matrix_path}...")

    if matrix_path.endswith('.json') or matrix_path.endswith('.json.gz'):
        # Load JSON format (same as install script uses)
        if matrix_path.endswith('.gz'):
            print("Decompressing gzipped JSON matrix...")
            with gzip.open(matrix_path, 'rt') as f:
                proj = np.array(json.load(f), dtype=np.float32)
        else:
            with open(matrix_path, 'r') as f:
                proj = np.array(json.load(f), dtype=np.float32)
        print(f"Loaded JSON matrix: shape {proj.shape}")
    else:
        # Original numpy format
        proj = np.load(matrix_path).astype(np.float32)
        print(f"Loaded numpy matrix: shape {proj.shape}")

    return proj

def main():
    p = argparse.ArgumentParser(description="Convert embeddings via PCA to reduced dimensions (parallel)")
    p.add_argument("-m","--matrix-path",
                   required=True,
                   help="Path to projection matrix (.json, .json.gz, or .npy)")
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
    p.add_argument("--update-config", action="store_true",
                   help="Update database configuration to use reduced embeddings")
    p.add_argument("--load-matrix-to-db", action="store_true",
                   help="Load the projection matrix into the database reducing_matrix table")
    p.add_argument("--create-index", action="store_true",
                   help="Create HNSW index after conversion")
    args = p.parse_args()

    DB = os.getenv("POSTGRES_URI")
    if not DB:
        print("ERROR: POSTGRES_URI must be set", file=sys.stderr)
        sys.exit(1)

    # Load projection matrix
    proj = load_matrix(args.matrix_path)
    M, D = proj.shape
    print(f"Projecting {D}-dim -> {M}-dim")

    # Ensure output table exists
    writer = psycopg2.connect(DB)
    writer.autocommit = True

    # Check current configuration
    with writer.cursor() as c:
        c.execute("SELECT store_halfvec_embeddings FROM hivesense_app.hivesense_app_status LIMIT 1")
        store_halfvec = c.fetchone()[0]

    # Create table with appropriate type (matching database_schema.sql structure)
    with writer.cursor() as c:
        type_spec = f"public.halfvec({M})" if store_halfvec else f"public.vector({M})"

        c.execute(f"""
           CREATE TABLE IF NOT EXISTS {args.output_table} (
             post_id int not null,
             chunk_number int not null,
             reduced_embedding {type_spec} not null,
             primary key(post_id,chunk_number),
             FOREIGN KEY (post_id, chunk_number)
               REFERENCES hivesense_app.posts_vectors(post_id, chunk_number)
               ON DELETE CASCADE
           )
        """)

    print(f"Ensured table: {args.output_table} with {'halfvec' if store_halfvec else 'vector'} type")

    # Fetch global sync_seq min/max and total rows
    with writer.cursor() as c:
        c.execute(f"SELECT MIN(sync_seq), MAX(sync_seq), COUNT(*) FROM {args.input_table}")
        min_seq, max_seq, total_rows = c.fetchone()
    print(f"Total embeddings: {total_rows:,}, sync_seq range [{min_seq}..{max_seq}]")

    # Load matrix into database if requested
    if args.load_matrix_to_db:
        print("Loading projection matrix into database...")
        with writer.cursor() as c:
            c.execute("TRUNCATE hivesense_app.reducing_matrix")
            for i, row in enumerate(proj):
                c.execute(
                    "INSERT INTO hivesense_app.reducing_matrix(row_idx, row_vec) VALUES (%s, %s::public.vector)",
                    (i, json.dumps(row.tolist()))
                )
            writer.commit()
        print(f"Loaded {M} projection vectors into reducing_matrix table")

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
                                    args=(i, start, end, args, proj, M, total_rows, start_time, store_halfvec))
        p.start()
        jobs.append(p)

    # Wait for completion
    for p in jobs:
        p.join()

    print("All workers complete.")

    # Update configuration if requested
    if args.update_config:
        print("Updating database configuration...")
        with writer.cursor() as c:
            c.execute("""
                UPDATE hivesense_app.hivesense_app_status
                SET use_reduced_embeddings = true,
                    reduced_dim = %s
                WHERE id = 1
            """, (M,))
            writer.commit()
        print(f"Configuration updated: use_reduced_embeddings=true, reduced_dim={M}")

    # Create index if requested
    if args.create_index:
        print("Creating HNSW index...")
        with writer.cursor() as c:
            c.execute("CALL hivesense_app.ENSURE_INDEXES_ARE_CREATED()")
            writer.commit()
        print("HNSW index creation complete")

    writer.close()
    print("\nConversion complete!")
    print(f"Reduced embeddings are now in {args.output_table}")
    if args.update_config:
        print("Database is configured to use reduced embeddings")
    if args.create_index:
        print("HNSW index has been created")

if __name__=="__main__":
    main()
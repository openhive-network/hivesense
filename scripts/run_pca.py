import json
import os
from urllib.parse import urlparse
import psycopg2
import numpy as np
from sklearn.decomposition import PCA, IncrementalPCA
import matplotlib.pyplot as plt
import ast

DB_URI = os.getenv("POSTGRES_URI")
if not DB_URI:
    raise RuntimeError("POSTGRES_URI environment variable is required")


SAMPLE_SIZE = int(os.getenv("SAMPLE_SIZE", default = "1000000"))
REDUCED_DIM =  int(os.getenv("REDUCED_DIM", default = "384"))

def run_pca_streaming_from_db(sample_size, batch_size=10000, n_components=256):
    ipca = IncrementalPCA(n_components=n_components, batch_size=batch_size)
    buffer = []

    with psycopg2.connect(DB_URI) as conn:
        with conn.cursor(name='stream_cursor') as cur:
            cur.execute(f"""
                SELECT embedding
                FROM hivesense_app.posts_vectors
                LIMIT {sample_size}
            """)
            count = 0
            for row in cur:
                if isinstance(row[0], str):
                    vec = np.array(ast.literal_eval(row[0]), dtype=np.float32)
                    buffer.append(vec)
                    count += 1

                if len(buffer) == batch_size:
                    ipca.partial_fit(np.stack(buffer))
                    buffer.clear()
                    print(f"Processed {count} of {sample_size} vectors")

            # Final chunk
            if buffer:
                ipca.partial_fit(np.stack(buffer))

    return ipca

def main():
    print("Running streaming PCA...")

    ipca = run_pca_streaming_from_db(
        sample_size=SAMPLE_SIZE,
        batch_size=10000,
        n_components=REDUCED_DIM
    )

    # Print cumulative explained variance
    cum_var = np.cumsum(ipca.explained_variance_ratio_)
    print(f"Explained variance by first {REDUCED_DIM} components: {cum_var[-1]:.4f}")

    # Plot
    import matplotlib.pyplot as plt
    plt.plot(cum_var)
    plt.xlabel("Number of components")
    plt.ylabel("Cumulative explained variance")
    plt.title("PCA Variance (Incremental)")
    plt.grid()
    os.makedirs('output', exist_ok = True)
    plt.savefig("output/explained_variance.png")
    print("Saved explained_variance.png")

    # Save the projection matrix
    np.save("output/pca_projection_matrix.npy", ipca.components_)
    print("Saved projection matrix as pca_projection_matrix.npy")

    # Save as JSON for PostgreSQL
    with open("output/pca_projection_matrix.json", "w") as f:
        json.dump(ipca.components_.tolist(), f)
    print("Saved projection matrix as pca_projection_matrix.json")

if __name__ == "__main__":
    main()

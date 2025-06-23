SET ROLE hivesense_owner;

CREATE OR REPLACE FUNCTION CONTINUEPROCESSING()
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS
$$
BEGIN
  RETURN continue_processing FROM hivesense_app_status LIMIT 1;
END
$$;

CREATE OR REPLACE FUNCTION ALLOWPROCESSING()
RETURNS VOID
LANGUAGE plpgsql VOLATILE
AS
$$
BEGIN
  UPDATE hivesense_app_status SET continue_processing = True;
END
$$;

--- Helper function to be called from separate transaction 
--- (must be committed) to safely stop execution of the application.
CREATE OR REPLACE FUNCTION STOPPROCESSING()
RETURNS VOID
LANGUAGE plpgsql VOLATILE
AS
$$
BEGIN
  UPDATE hivesense_app_status SET continue_processing = False;
END
$$;


CREATE OR REPLACE FUNCTION GET_VERSION()
RETURNS TEXT
LANGUAGE plpgsql STABLE
AS
$$
BEGIN
  RETURN runtime_hash FROM version LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION SET_VERSION(_git_hash TEXT)
RETURNS VOID
LANGUAGE plpgsql VOLATILE
AS
$$
DECLARE
  _schema_hash TEXT := (SELECT schema_hash FROM version LIMIT 1);
BEGIN
TRUNCATE TABLE version;

IF _schema_hash IS NULL THEN
  INSERT INTO version(schema_hash, runtime_hash) VALUES (_git_hash, _git_hash);
ELSE
  INSERT INTO version(schema_hash, runtime_hash) VALUES (_schema_hash, _git_hash);
END IF;

END
$$;

CREATE OR REPLACE FUNCTION hivesense_app.use_halfvec_index()
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT use_halfvec_index FROM hivesense_app.hivesense_app_status LIMIT 1 $$;

CREATE OR REPLACE FUNCTION hivesense_app.store_halfvec_embeddings()
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT store_halfvec_embeddings FROM hivesense_app.hivesense_app_status LIMIT 1 $$;

CREATE OR REPLACE FUNCTION hivesense_app.embedding_dims()
RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT embedding_dimensionality FROM hivesense_app.hivesense_app_status LIMIT 1 $$;

CREATE OR REPLACE FUNCTION hivesense_app.distance_clause(param_pos int)
RETURNS text LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$$
DECLARE
    dim int := hivesense_app.embedding_dims();
BEGIN
    IF hivesense_app.store_halfvec_embeddings() THEN
        -- column already halfvec
        RETURN format('embedding <=> $%s::halfvec(%s)', param_pos, dim);
    ELSIF hivesense_app.use_halfvec_index() THEN
        RETURN format('embedding::halfvec(%1$s) <=> $%2$s::halfvec(%1$s)', dim, param_pos);
    ELSE
        RETURN format('embedding <=> $%s', param_pos);
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE ENSURE_INDEXES_ARE_CREATED()
LANGUAGE plpgsql
AS $$
DECLARE
    dim   int     := hivesense_app.embedding_dims();
    half  boolean := hivesense_app.use_halfvec_index();
    store boolean := hivesense_app.store_halfvec_embeddings();
    idx_exists boolean;
BEGIN
    IF store THEN
        -- half‐precision on‐disk embedding index
        SELECT EXISTS(
           SELECT 1
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'hivesense_app'
              AND c.relname  = 'posts_vectors_embedding_half_hnsw'
        ) INTO idx_exists;

        IF NOT idx_exists THEN
            RAISE NOTICE 'Creating half-precision HNSW index (%s-d)…', dim;
            CREATE INDEX posts_vectors_embedding_half_hnsw
              ON hivesense_app.posts_vectors
            USING hnsw (embedding public.halfvec_cosine_ops)
            WITH (m = 32, ef_construction = 400);
        END IF;

    ELSIF half THEN
        -- half‐precision casted at index time
        SELECT EXISTS(
           SELECT 1
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'hivesense_app'
              AND c.relname  = 'posts_vectors_embedding_half_hnsw'
        ) INTO idx_exists;

        IF NOT idx_exists THEN
            RAISE NOTICE 'Creating half-precision HNSW index (%s-d)…', dim;
            EXECUTE format(
              'CREATE INDEX posts_vectors_embedding_half_hnsw
                 ON hivesense_app.posts_vectors
               USING hnsw ((embedding::public.halfvec(%1$s)) public.halfvec_cosine_ops)
               WITH (m = 32, ef_construction = 400)',
              dim
            );
        END IF;

    ELSE
        -- full‐precision embedding index
        SELECT EXISTS(
           SELECT 1
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'hivesense_app'
              AND c.relname  = 'posts_vectors_embedding_hnsw'
        ) INTO idx_exists;

        IF NOT idx_exists THEN
            RAISE NOTICE 'Creating full-precision HNSW index (%s-d)…', dim;
            CREATE INDEX posts_vectors_embedding_hnsw
              ON hivesense_app.posts_vectors
            USING hnsw (embedding public.vector_cosine_ops)
            WITH (m = 32, ef_construction = 400);
        END IF;
    END IF;
END;
$$;


RESET ROLE;

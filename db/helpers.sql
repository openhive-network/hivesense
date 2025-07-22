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

CREATE OR REPLACE PROCEDURE CREATE_HNSW_INDEX()
LANGUAGE plpgsql
AS $$
DECLARE
    dim   int     := hivesense_app.EMBEDDING_DIMS();
    half  boolean := hivesense_app.USE_HALFVEC_INDEX();
    store boolean := hivesense_app.STORE_HALFVEC_EMBEDDINGS();
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

CREATE OR REPLACE PROCEDURE ENSURE_INDEXES_ARE_CREATED()
LANGUAGE plpgsql
AS
$$
DECLARE
    __max_parallel_workers INT;
    __current_maintenance_work_mem TEXT;
    __original_maintenance_work_mem TEXT;
    __start_time TIMESTAMPTZ;
    __end_time TIMESTAMPTZ;
    __duration INTERVAL;
    __index_exists BOOLEAN;
    __table_size BIGINT;
    __row_count BIGINT;
    __index_size BIGINT;
    __creation_rate NUMERIC;
    __creation_time_info TEXT;
    __vector_dimensions INT;
BEGIN
    -- Check if index already exists
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = 'hivensense_vectors_embed_hnsw_idxs'
    ) INTO __index_exists;
    
    IF __index_exists THEN
        -- If index exists, get its size and report
        SELECT PG_SIZE_PRETTY(PG_RELATION_SIZE(oid)) 
        FROM pg_class 
        WHERE relname = 'hivensense_vectors_embed_hnsw_idxs'
        INTO __creation_time_info;
        
        RAISE NOTICE 'Index hivensense_vectors_embed_hnsw_idxs already exists (size: %). Skipping creation.', __creation_time_info;
        RETURN;
    END IF;

    -- Get table size and row count before index creation
    SELECT 
        PG_RELATION_SIZE('hivesense_app.posts_vectors') AS table_size, 
        COUNT(*) AS row_count
    FROM hivesense_app.posts_vectors 
    INTO __table_size, __row_count;
    
    -- Get vector dimension
    SELECT VECTOR_DIMS(embedding) AS vector_dimensions FROM hivesense_app.posts_vectors LIMIT 1 INTO __vector_dimensions;
    
    -- Get current parallel workers and maintenance work mem settings
    DECLARE
        __max_parallel_maintenance_workers INT;
        __original_maintenance_workers INT;
        __system_memory_gb NUMERIC;
        __memory_check_result TEXT;
        __new_maintenance_work_mem TEXT;
    BEGIN
        -- Check system memory availability
        BEGIN
            -- Read /proc/meminfo to get total memory
            SELECT SPLIT_PART(pg_read_file('/proc/meminfo', 0, 200), ' kB', 1) INTO __memory_check_result;
            SELECT SPLIT_PART(__memory_check_result, 'MemTotal:', 2) INTO __memory_check_result;
            SELECT TRIM(__memory_check_result)::BIGINT / 1024 / 1024 INTO __system_memory_gb;
            
            RAISE NOTICE 'System total memory: % GB', ROUND(__system_memory_gb, 1);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Could not determine system memory: %. Using conservative settings.', SQLERRM;
            __system_memory_gb := 0;
        END;
        
        -- Get available worker settings
        SELECT CURRENT_SETTING('max_parallel_workers')::INT INTO __max_parallel_workers;
        SELECT CURRENT_SETTING('maintenance_work_mem') INTO __current_maintenance_work_mem;
        
        -- Get current maintenance workers setting (this is what actually controls index creation)
        SELECT COALESCE(CURRENT_SETTING('max_parallel_maintenance_workers', true)::INT, 2) INTO __original_maintenance_workers;
        
        -- Store the original maintenance_work_mem value to restore later
        __original_maintenance_work_mem := __current_maintenance_work_mem;
        
        -- Use minimum of 32 and max_parallel_workers for our target
        __max_parallel_maintenance_workers := LEAST(32, __max_parallel_workers);
        
        -- Determine appropriate maintenance_work_mem based on system memory
        IF __system_memory_gb >= 120 THEN
            __new_maintenance_work_mem := '90GB';
            RAISE NOTICE 'System has sufficient memory (% GB >= 120 GB). Setting maintenance_work_mem to %', 
                        ROUND(__system_memory_gb, 1), __new_maintenance_work_mem;
        ELSE
            __new_maintenance_work_mem := __current_maintenance_work_mem;
            RAISE NOTICE 'System has limited memory (% GB < 120 GB). Keeping maintenance_work_mem at current value: %', 
                        ROUND(__system_memory_gb, 1), __new_maintenance_work_mem;
        END IF;
        
        -- Set maintenance_work_mem based on memory check
        EXECUTE FORMAT('SET maintenance_work_mem TO %L', __new_maintenance_work_mem);
        
        -- Set the appropriate parameter for controlling parallelism in index creation
        EXECUTE format('SET max_parallel_maintenance_workers TO %s', __max_parallel_maintenance_workers);
        
        -- Log the settings being used
        RAISE NOTICE 'Setting maintenance_work_mem to % (was: %)', __new_maintenance_work_mem, __original_maintenance_work_mem;
        RAISE NOTICE 'Setting max_parallel_maintenance_workers to % (was: %)', 
                    __max_parallel_maintenance_workers, __original_maintenance_workers;
    EXCEPTION WHEN OTHERS THEN
        -- In case of any error, continue with default settings
        RAISE NOTICE 'Could not set parallel workers settings: %', SQLERRM;
    END;
    
    -- Set work_mem higher for index creation operations
    EXECUTE 'SET work_mem TO ''512MB''';
    
    -- Check actual workers that will be used
    DECLARE
        __actual_workers INT;
    BEGIN
        SELECT current_setting('max_parallel_maintenance_workers')::INT INTO __actual_workers;
        RAISE NOTICE 'Creating HNSW index hivensense_vectors_embed_hnsw_idxs for searching embeddings with % parallel workers', __actual_workers;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Creating HNSW index hivensense_vectors_embed_hnsw_idxs (could not determine worker count)';
    END;

    -- Record start time
    __start_time := CLOCK_TIMESTAMP();
    RAISE NOTICE 'Starting HNSW index creation at %', __start_time;
    
    CALL hivesense_app.CREATE_HNSW_INDEX();
    
    -- Record end time and calculate duration
    __end_time := CLOCK_TIMESTAMP();
    __duration := __end_time - __start_time;
    
    -- Get the index size
    SELECT PG_RELATION_SIZE(oid) 
    FROM pg_class 
    WHERE relname = 'hivensense_vectors_embed_hnsw_idxs'
    INTO __index_size;
    
    -- Calculate index creation rate (vectors/second)
    __creation_rate := CASE WHEN EXTRACT(EPOCH FROM __duration) > 0 
                           THEN __row_count / EXTRACT(EPOCH FROM __duration)
                           ELSE 0 END;
    
    -- Format creation time details
    __creation_time_info := FORMAT(
        E'=== HNSW Index Creation Results ===\n' 
        'Index creation completed at: %s\n' 
        'Total creation time: %s (%s seconds)\n' 
        'Index size: %s\n' 
        'Average creation rate: %s vectors/second\n' 
        'Size ratio (index/table): %s\n' 
        '==================================',
        __end_time,
        __duration,
        ROUND(EXTRACT(EPOCH FROM __duration)::numeric, 2),
        PG_SIZE_PRETTY(__index_size),
        ROUND(__creation_rate::numeric, 2),
        ROUND((CASE WHEN __table_size > 0 THEN __index_size::numeric / __table_size ELSE 0 END), 2)
    );

    RAISE NOTICE '%', __creation_time_info;
    
    -- Reset all the settings we changed
    EXECUTE 'RESET work_mem';
    
    -- Try to reset maintenance workers setting
    BEGIN
        EXECUTE 'RESET max_parallel_maintenance_workers';
    EXCEPTION WHEN OTHERS THEN
        NULL; -- Ignore errors
    END;
        
    -- Restore the original maintenance_work_mem value
    EXECUTE FORMAT('SET maintenance_work_mem TO %L', __original_maintenance_work_mem);
    RAISE NOTICE 'Restored maintenance_work_mem to original value: %', __original_maintenance_work_mem;
END;
$$;

RESET ROLE;

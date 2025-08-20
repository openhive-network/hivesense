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

CREATE OR REPLACE FUNCTION hivesense_app.get_hnsw_index_name()
RETURNS text LANGUAGE plpgsql STABLE AS
$$
DECLARE
    use_reduced boolean := hivesense_app.use_reduced_embeddings();
    half        boolean := hivesense_app.use_halfvec_index();
    store       boolean := hivesense_app.store_halfvec_embeddings();
    tgt_table   text;
    tgt_col     text;
    idx_name    text;
BEGIN
    /* -----------------------------------------------------------
     * Decide which table/column we are indexing
     * ----------------------------------------------------------*/
    IF use_reduced THEN
        tgt_table := 'hivesense_app.posts_vectors_reduced';
        tgt_col   := 'reduced_embedding';
    ELSE
        tgt_table := 'hivesense_app.posts_vectors';
        tgt_col   := 'embedding';
    END IF;

    /* -----------------------------------------------------------
     * Build index name and existence check
     * ----------------------------------------------------------*/
    RETURN format(
       '%s_%s_%s_hnsw',
       substring(tgt_table from '[^.]+$'),        -- strip schema
       tgt_col,
       CASE
         WHEN store OR half THEN 'half' ELSE 'full'
       END
    );
END;
$$;

CREATE OR REPLACE PROCEDURE CREATE_HNSW_INDEX()
LANGUAGE plpgsql
AS $$
DECLARE
    use_reduced boolean := hivesense_app.use_reduced_embeddings();
    dim         int     := CASE WHEN use_reduced
                                THEN hivesense_app.reduced_dims()
                                ELSE hivesense_app.embedding_dims()
                           END;
    half        boolean := hivesense_app.use_halfvec_index();
    store       boolean := hivesense_app.store_halfvec_embeddings();
    m           int     := (SELECT hnsw_m              FROM hivesense_app.hivesense_app_status LIMIT 1);
    efc         int     := (SELECT hnsw_ef_construction FROM hivesense_app.hivesense_app_status LIMIT 1);
    idx_exists  boolean;
    tgt_table   text;
    tgt_col     text;
    idx_name    text;
BEGIN
    /* -----------------------------------------------------------
     * Decide which table/column we are indexing
     * ----------------------------------------------------------*/
    IF use_reduced THEN
        tgt_table := 'hivesense_app.posts_vectors_reduced';
        tgt_col   := 'reduced_embedding';
    ELSE
        tgt_table := 'hivesense_app.posts_vectors';
        tgt_col   := 'embedding';
    END IF;

    /* -----------------------------------------------------------
     * Get index name from shared function
     * ----------------------------------------------------------*/
    idx_name := hivesense_app.get_hnsw_index_name();

    SELECT EXISTS(
       SELECT 1
         FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'hivesense_app'
          AND c.relname  = idx_name
    ) INTO idx_exists;

    IF idx_exists THEN
        RETURN;
    END IF;

    /* -----------------------------------------------------------
     * Compose CREATE INDEX statement
     * ----------------------------------------------------------*/

    IF store THEN
        EXECUTE format(
          'CREATE INDEX %I ON %s USING hnsw (%I public.halfvec_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, m, efc
        );
    ELSIF half THEN
        EXECUTE format(
          'CREATE INDEX %I ON %s USING hnsw ((%I::public.halfvec(%s)) public.halfvec_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, dim, m, efc
        );
    ELSE
        EXECUTE format(
          'CREATE INDEX %I ON %s USING hnsw (%I public.vector_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, m, efc
        );
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
    __index_name TEXT;
    __index_exists BOOLEAN;
    __table_size BIGINT;
    __row_count BIGINT;
    __index_size BIGINT;
    __creation_rate NUMERIC;
    __creation_time_info TEXT;
    __vector_dimensions INT := CASE
          WHEN hivesense_app.use_reduced_embeddings()
               THEN hivesense_app.reduced_dims()
          ELSE hivesense_app.embedding_dims()
         END;
    __desired_work_mem_gb INT := (SELECT desired_maintenance_work_mem_gb
                                  FROM   hivesense_app.hivesense_app_status
                                  LIMIT  1);
BEGIN
    -- Check if index already exists
    SELECT hivesense_app.get_hnsw_index_name() INTO __index_name;
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = __index_name
    ) INTO __index_exists;
    
    IF __index_exists THEN
        -- If index exists, get its size and report
        SELECT PG_SIZE_PRETTY(PG_RELATION_SIZE(oid)) 
        FROM pg_class 
        WHERE relname = __index_name
        INTO __creation_time_info;
        
        RAISE NOTICE 'HNSW index already exists (size: %). Skipping creation.', __creation_time_info;
        RETURN;
    END IF;

    -- Get table size and row count before index creation (use correct table based on configuration)
    IF hivesense_app.use_reduced_embeddings() THEN
        SELECT 
            PG_RELATION_SIZE('hivesense_app.posts_vectors_reduced') AS table_size, 
            COUNT(*) AS row_count
        FROM hivesense_app.posts_vectors_reduced 
        INTO __table_size, __row_count;
        
        -- Get vector dimension from reduced embedding
        SELECT VECTOR_DIMS(reduced_embedding) AS vector_dimensions 
        FROM hivesense_app.posts_vectors_reduced 
        LIMIT 1 INTO __vector_dimensions;
    ELSE
        SELECT 
            PG_RELATION_SIZE('hivesense_app.posts_vectors') AS table_size, 
            COUNT(*) AS row_count
        FROM hivesense_app.posts_vectors 
        INTO __table_size, __row_count;
        
        -- Get vector dimension from full embedding
        SELECT VECTOR_DIMS(embedding) AS vector_dimensions 
        FROM hivesense_app.posts_vectors 
        LIMIT 1 INTO __vector_dimensions;
    END IF;
    
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
        IF __system_memory_gb >= (__desired_work_mem_gb + 30) THEN
            __new_maintenance_work_mem := __desired_work_mem_gb || 'GB';
            RAISE NOTICE 'System has ≥ desired + 30 GB (%.1f GB).  Setting maintenance_work_mem to %',
                        __system_memory_gb, __new_maintenance_work_mem;
        ELSE
            __new_maintenance_work_mem := __current_maintenance_work_mem;
            RAISE NOTICE 'System memory (%.1f GB) < desired + 30 GB (target %.0f GB + 30).  Leaving maintenance_work_mem at %',
                        __system_memory_gb, __desired_work_mem_gb, __new_maintenance_work_mem;
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
        RAISE NOTICE 'Creating HNSW index for searching embeddings with % parallel workers', __actual_workers;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Creating HNSW index (could not determine worker count)';
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
    WHERE relname = __index_name
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

/* ---------- explode a JSON matrix [[…],[…],…] into reducing_matrix ---------- */
CREATE OR REPLACE FUNCTION hivesense_app.load_reducing_matrix(_json jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    i  INT := 0;
    v  jsonb;
BEGIN
    TRUNCATE hivesense_app.reducing_matrix;
    FOR v IN SELECT * FROM jsonb_array_elements(_json)
    LOOP
        INSERT INTO hivesense_app.reducing_matrix(row_idx, row_vec)
        VALUES (i, (v::text)::public.vector);
        i := i + 1;
    END LOOP;
END;
$$;

/* ---------- compute reduced vector (always returns FP32) ---------- */
CREATE OR REPLACE FUNCTION hivesense_app.reduce_embedding(_emb public.vector)
RETURNS public.vector
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
AS $$
DECLARE
    proj  float4[];
BEGIN
    SELECT array_agg((row_vec::public.vector) <#> (_emb::public.vector) ORDER BY row_idx)
      INTO proj
      FROM hivesense_app.reducing_matrix;
    RETURN proj::public.vector;
END;
$$;

CREATE OR REPLACE FUNCTION hivesense_app.use_reduced_embeddings()
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT use_reduced_embeddings FROM hivesense_app.hivesense_app_status LIMIT 1 $$;

CREATE OR REPLACE FUNCTION hivesense_app.reduced_dims()
RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT reduced_dim FROM hivesense_app.hivesense_app_status LIMIT 1 $$;

CREATE OR REPLACE FUNCTION hivesense_app.allow_debugging()
RETURNS boolean IMMUTABLE PARALLEL SAFE LANGUAGE sql AS
$$ SELECT allow_debugging FROM hivesense_app.hivesense_app_status LIMIT 1 $$;



RESET ROLE;

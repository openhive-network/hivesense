-- Create a SECURITY DEFINER wrapper for reading /proc/meminfo
-- This must be created as superuser (haf_admin) before SET ROLE
CREATE OR REPLACE FUNCTION hivesense_app.read_proc_meminfo()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN pg_read_file('/proc/meminfo', 0, 200);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

-- Grant execute permission to hivesense_owner while still running as haf_admin
GRANT EXECUTE ON FUNCTION hivesense_app.read_proc_meminfo() TO hivesense_owner;

-- Create a SECURITY DEFINER wrapper for getting /dev/shm size
-- This must be created as superuser (haf_admin) before SET ROLE
CREATE OR REPLACE FUNCTION hivesense_app.get_shm_size_gb()
RETURNS NUMERIC
LANGUAGE plpython3u
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
import os
try:
    # Get the size of /dev/shm in bytes
    stat = os.statvfs('/dev/shm')
    total_bytes = stat.f_blocks * stat.f_frsize
    # Convert to GB
    total_gb = total_bytes / (1024 * 1024 * 1024)
    return round(total_gb, 2)
except Exception as e:
    plpy.notice(f"Could not determine /dev/shm size: {e}")
    return None
$$;

-- Grant execute permission to hivesense_owner while still running as haf_admin
GRANT EXECUTE ON FUNCTION hivesense_app.get_shm_size_gb() TO hivesense_owner;

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
    red_mode    text    := hivesense_app.reduction_mode();
    half        boolean := hivesense_app.use_halfvec_index();
    store       boolean := hivesense_app.store_halfvec_embeddings();
    tgt_table   text;
    tgt_col     text;
    idx_name    text;
BEGIN
    /* -----------------------------------------------------------
     * Decide which table/column we are indexing
     * ----------------------------------------------------------*/
    IF use_reduced AND red_mode = 'slice' THEN
        -- Matryoshka: expression index on main table
        tgt_table := 'hivesense_app.posts_vectors';
        tgt_col   := 'embedding';
    ELSIF use_reduced THEN
        -- PCA: index on reduced table
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
         WHEN use_reduced AND red_mode = 'slice' THEN 'slice'
         WHEN store OR half THEN 'half'
         ELSE 'full'
       END
    );
END;
$$;

-- The CREATE INDEX statement for this configuration's HNSW index on
-- tgt_table(tgt_col), named idx_name. Shared by CREATE_HNSW_INDEX() and the
-- chain-rebase tooling (db/legacy_rebase.sql builds the same index on a
-- staging table before swapping it in).
CREATE OR REPLACE FUNCTION hivesense_app.hnsw_index_statement(idx_name text, tgt_table text, tgt_col text)
RETURNS text LANGUAGE plpgsql STABLE AS
$$
DECLARE
    use_reduced boolean := hivesense_app.use_reduced_embeddings();
    red_mode    text    := hivesense_app.reduction_mode();
    dim         int     := CASE WHEN use_reduced
                                THEN hivesense_app.reduced_dims()
                                ELSE hivesense_app.embedding_dims()
                           END;
    half        boolean := hivesense_app.use_halfvec_index();
    store       boolean := hivesense_app.store_halfvec_embeddings();
    m           int     := (SELECT hnsw_m              FROM hivesense_app.hivesense_app_status LIMIT 1);
    efc         int     := (SELECT hnsw_ef_construction FROM hivesense_app.hivesense_app_status LIMIT 1);
BEGIN
    IF use_reduced AND red_mode = 'slice' AND store THEN
        -- Matryoshka on halfvec column: subvector returns halfvec
        RETURN format(
          'CREATE INDEX %I ON %s USING hnsw ((public.subvector(%I, 1, %s)::public.halfvec(%s)) public.halfvec_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, dim, dim, m, efc
        );
    ELSIF use_reduced AND red_mode = 'slice' THEN
        -- Matryoshka on vector column: subvector returns vector
        RETURN format(
          'CREATE INDEX %I ON %s USING hnsw ((public.subvector(%I, 1, %s)::public.vector(%s)) public.vector_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, dim, dim, m, efc
        );
    ELSIF store THEN
        RETURN format(
          'CREATE INDEX %I ON %s USING hnsw (%I public.halfvec_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, m, efc
        );
    ELSIF half THEN
        RETURN format(
          'CREATE INDEX %I ON %s USING hnsw ((%I::public.halfvec(%s)) public.halfvec_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, dim, m, efc
        );
    ELSE
        RETURN format(
          'CREATE INDEX %I ON %s USING hnsw (%I public.vector_cosine_ops) WITH (m=%s, ef_construction=%s)',
          idx_name, tgt_table, tgt_col, m, efc
        );
    END IF;
END;
$$;

-- The memory pgvector's HNSW build needs to keep the graph of _rows vectors of
-- this configuration's index (hnsw_index_statement()) in maintenance_work_mem,
-- per element as pgvector (0.8) counts it: the element (128 bytes), its
-- neighbour-list pointers, a 2*m-entry layer-0 list (16 bytes per entry), on
-- average 1/(m-1) upper m-entry lists, and the indexed value (8-byte header).
CREATE OR REPLACE FUNCTION hivesense_app.hnsw_graph_bytes(_rows BIGINT)
RETURNS BIGINT LANGUAGE plpgsql STABLE AS
$$
DECLARE
    use_reduced boolean := hivesense_app.use_reduced_embeddings();
    red_mode    text    := hivesense_app.reduction_mode();
    dim         int     := CASE WHEN use_reduced
                                THEN hivesense_app.reduced_dims()
                                ELSE hivesense_app.embedding_dims()
                           END;
    half        boolean := hivesense_app.use_halfvec_index();
    store       boolean := hivesense_app.store_halfvec_embeddings();
    m           int     := (SELECT hnsw_m FROM hivesense_app.hivesense_app_status LIMIT 1);
    value_bytes int     := 8 + dim * CASE WHEN store OR (half AND NOT (use_reduced AND red_mode = 'slice'))
                                          THEN 2 ELSE 4 END;
    element_bytes numeric;
BEGIN
    element_bytes := 128
                   + 8 + 8.0 / (m - 1)
                   + 8 + 16 * 2 * m
                   + (8 + 16 * m)::numeric / (m - 1)
                   + (value_bytes + 7) / 8 * 8;
    RETURN CEIL(_rows * element_bytes)::BIGINT;
END;
$$;

CREATE OR REPLACE PROCEDURE CREATE_HNSW_INDEX()
LANGUAGE plpgsql
AS $$
DECLARE
    use_reduced boolean := hivesense_app.use_reduced_embeddings();
    red_mode    text    := hivesense_app.reduction_mode();
    idx_exists  boolean;
    tgt_table   text;
    tgt_col     text;
    idx_name    text;
BEGIN
    /* -----------------------------------------------------------
     * Decide which table/column we are indexing
     * ----------------------------------------------------------*/
    IF use_reduced AND red_mode = 'slice' THEN
        tgt_table := 'hivesense_app.posts_vectors';
        tgt_col   := 'embedding';
    ELSIF use_reduced THEN
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

    EXECUTE hivesense_app.hnsw_index_statement(idx_name, tgt_table, tgt_col);
END;
$$;

-- The maintenance_work_mem an HNSW build over _rows vectors should SET: the
-- graph's estimate (hnsw_graph_bytes()) plus 10 %, when that is above the
-- current setting and within every limit: desired_maintenance_work_mem_gb, a
-- quarter of system memory and, with posix dynamic shared memory (where a
-- parallel build keeps its graph), 90 % of /dev/shm. Otherwise the current
-- setting. NOTICEs give the estimate, the limits and the choice.
DROP FUNCTION IF EXISTS hivesense_app.index_build_maintenance_work_mem();
CREATE OR REPLACE FUNCTION hivesense_app.index_build_maintenance_work_mem(_rows BIGINT)
RETURNS TEXT
LANGUAGE plpgsql VOLATILE
AS
$$
DECLARE
    __cap_bytes BIGINT := (SELECT desired_maintenance_work_mem_gb
                           FROM   hivesense_app.hivesense_app_status
                           LIMIT  1)::BIGINT * 1024 * 1024 * 1024;
    __current_maintenance_work_mem TEXT := CURRENT_SETTING('maintenance_work_mem');
    __current_bytes BIGINT := PG_SIZE_BYTES(__current_maintenance_work_mem);
    __graph_bytes BIGINT := hivesense_app.hnsw_graph_bytes(_rows);
    __wanted_bytes BIGINT;
    __memory_check_result TEXT;
    __system_memory_bytes BIGINT := 0;
    __shm_size_gb NUMERIC;
    __ram_limit_bytes BIGINT;
    __shm_limit_bytes BIGINT;
    __shm_limit TEXT;
BEGIN
    -- rounded up to whole MB, the unit it is set in
    __wanted_bytes := CEIL(__graph_bytes * 1.1 / (1024 * 1024))::BIGINT * 1024 * 1024;

    BEGIN
        -- Read /proc/meminfo to get total memory using SECURITY DEFINER wrapper
        SELECT SPLIT_PART(hivesense_app.read_proc_meminfo(), ' kB', 1) INTO __memory_check_result;
        SELECT SPLIT_PART(__memory_check_result, 'MemTotal:', 2) INTO __memory_check_result;
        __system_memory_bytes := TRIM(__memory_check_result)::BIGINT * 1024;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Could not determine system memory: %. Using conservative settings.', SQLERRM;
    END;
    __ram_limit_bytes := __system_memory_bytes / 4;

    IF CURRENT_SETTING('dynamic_shared_memory_type') = 'posix' THEN
        BEGIN
            __shm_size_gb := hivesense_app.get_shm_size_gb();
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error checking shared memory: %. Using conservative settings.', SQLERRM;
        END;
        __shm_limit_bytes := COALESCE(__shm_size_gb * 1024 * 1024 * 1024 * 0.9, 0)::BIGINT;
        __shm_limit := FORMAT('%s (90%% of /dev/shm, %s)', PG_SIZE_PRETTY(__shm_limit_bytes),
                              COALESCE(__shm_size_gb || ' GB', 'unknown'));
    ELSE
        __shm_limit := FORMAT('none (dynamic_shared_memory_type = %s)', CURRENT_SETTING('dynamic_shared_memory_type'));
    END IF;

    RAISE NOTICE 'HNSW graph of % vectors: estimated %, % with a 10%% margin. Limits: % (desired_maintenance_work_mem_gb), % (25%% of system memory, %), %',
                 _rows, PG_SIZE_PRETTY(__graph_bytes), PG_SIZE_PRETTY(__wanted_bytes),
                 PG_SIZE_PRETTY(__cap_bytes), PG_SIZE_PRETTY(__ram_limit_bytes),
                 PG_SIZE_PRETTY(__system_memory_bytes), __shm_limit;

    IF __wanted_bytes <= __current_bytes THEN
        RAISE NOTICE 'The graph fits the current maintenance_work_mem (%): keeping it', __current_maintenance_work_mem;
        RETURN __current_maintenance_work_mem;
    END IF;

    IF __wanted_bytes > __cap_bytes THEN
        RAISE NOTICE 'The graph needs more than desired_maintenance_work_mem_gb (%): keeping maintenance_work_mem %, the build will spill to disk',
                     PG_SIZE_PRETTY(__cap_bytes), __current_maintenance_work_mem;
    ELSIF __wanted_bytes > __ram_limit_bytes THEN
        RAISE NOTICE 'The graph needs more than 25%% of system memory (%): keeping maintenance_work_mem %, the build will spill to disk',
                     PG_SIZE_PRETTY(__ram_limit_bytes), __current_maintenance_work_mem;
    ELSIF __wanted_bytes > __shm_limit_bytes THEN
        RAISE NOTICE 'The graph needs more than 90%% of /dev/shm (%): keeping maintenance_work_mem %, the build will spill to disk; raise the HAF container''s shm_size to at least % for an in-memory build',
                     PG_SIZE_PRETTY(__shm_limit_bytes), __current_maintenance_work_mem,
                     PG_SIZE_PRETTY(CEIL(__wanted_bytes / 0.9)::BIGINT);
    ELSE
        RAISE NOTICE 'Setting maintenance_work_mem for the HNSW build to % (the graph''s estimate plus 10%%)',
                     __wanted_bytes / (1024 * 1024) || 'MB';
        RETURN __wanted_bytes / (1024 * 1024) || 'MB';
    END IF;
    RETURN __current_maintenance_work_mem;
END;
$$;

-- Why an index build must not start yet, or NULL once it may. The HNSW build is
-- one statement that holds its snapshot, and so the database's xmin horizon, for
-- up to hours; run while hivemind finalizes its massive sync or catches up after
-- downtime, it keeps hivemind's vacuums from removing dead rows and stalls its
-- CREATE INDEX CONCURRENTLY steps. hivemind has finished its first finalization
-- once hive_state.last_completed_block_num leaves its seed value 1
-- (SEED_LAST_COMPLETED_BLOCK, hivemind's hive/db/schema.py), and is live once its
-- context is within 100 blocks of HAF's head.
CREATE OR REPLACE FUNCTION hivesense_app.index_build_wait_reason()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS
$$
DECLARE
    __last_completed_block INT := (SELECT last_completed_block_num FROM hivemind_app.hive_state LIMIT 1);
    __hivemind_block INT := hive.app_get_current_block_num('hivemind_app');
    __head_block INT := (SELECT consistent_block FROM hafd.hive_state);
BEGIN
    IF COALESCE(__last_completed_block, 1) <= 1 THEN
        RETURN FORMAT('hivemind has not completed its first massive-sync finalization (hive_state.last_completed_block_num = %s)',
                      COALESCE(__last_completed_block::TEXT, 'no row'));
    END IF;
    IF __hivemind_block < __head_block - 100 THEN
        RETURN FORMAT('hivemind is at block %s, %s blocks behind HAF''s head block %s',
                      __hivemind_block, __head_block - __hivemind_block, __head_block);
    END IF;
    RETURN NULL;
END;
$$;

-- Builds the HNSW index unless it exists, after waiting for hivemind to be live
-- (index_build_wait_reason()). Commits between its steps, so it must be called
-- outside an explicit transaction block (autocommit, or from a procedure itself
-- called that way): the build then runs in a transaction of its own.
CREATE OR REPLACE PROCEDURE ENSURE_INDEXES_ARE_CREATED()
LANGUAGE plpgsql
AS
$$
DECLARE
    __wait_reason TEXT;
    __wait_started TIMESTAMPTZ;
    __last_wait_notice TIMESTAMPTZ;
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
         END;  -- for slice mode, reduced_dims is the index dimension
BEGIN
    -- Check if index already exists
    SELECT hivesense_app.get_hnsw_index_name() INTO __index_name;
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = __index_name
    ) INTO __index_exists;
    
    IF __index_exists THEN
        -- this function is called by the sync script on every block during livesync.  We don't want to 
        -- spam the logs with this message, so it's commented out for now
        -- -- If index exists, get its size and report
        -- SELECT PG_SIZE_PRETTY(PG_RELATION_SIZE(oid)) 
        -- FROM pg_class 
        -- WHERE relname = __index_name
        -- INTO __creation_time_info;
        -- 
        -- RAISE NOTICE 'HNSW index already exists (size: %). Skipping creation.', __creation_time_info;
        RETURN;
    END IF;

    -- Each wait step commits, so no transaction (or snapshot) outlives one poll.
    LOOP
        __wait_reason := hivesense_app.index_build_wait_reason();
        EXIT WHEN __wait_reason IS NULL;
        IF __wait_started IS NULL THEN
            __wait_started := CLOCK_TIMESTAMP();
        END IF;
        IF __last_wait_notice IS NULL OR CLOCK_TIMESTAMP() - __last_wait_notice >= INTERVAL '5 minutes' THEN
            RAISE NOTICE 'Waiting to build the HNSW index (for %): %',
                         DATE_TRUNC('second', CLOCK_TIMESTAMP() - __wait_started), __wait_reason;
            __last_wait_notice := CLOCK_TIMESTAMP();
        END IF;
        COMMIT;
        PERFORM PG_SLEEP(10);
    END LOOP;
    IF __wait_started IS NOT NULL THEN
        RAISE NOTICE 'hivemind is live: building the HNSW index after waiting %',
                     DATE_TRUNC('second', CLOCK_TIMESTAMP() - __wait_started);
    END IF;

    -- Get table size and row count before index creation (use correct table based on configuration)
    IF hivesense_app.use_reduced_embeddings()
       AND hivesense_app.reduction_mode() <> 'slice' THEN
        SELECT
            PG_RELATION_SIZE('hivesense_app.posts_vectors_reduced') AS table_size,
            COUNT(*) AS row_count
        FROM hivesense_app.posts_vectors_reduced
        INTO __table_size, __row_count;
    ELSE
        SELECT
            PG_RELATION_SIZE('hivesense_app.posts_vectors') AS table_size,
            COUNT(*) AS row_count
        FROM hivesense_app.posts_vectors
        INTO __table_size, __row_count;
    END IF;
    
    -- Get current parallel workers and maintenance work mem settings
    DECLARE
        __max_parallel_maintenance_workers INT;
        __original_maintenance_workers INT;
        __new_maintenance_work_mem TEXT;
    BEGIN
        -- Get available worker settings
        SELECT CURRENT_SETTING('max_parallel_workers')::INT INTO __max_parallel_workers;
        SELECT CURRENT_SETTING('maintenance_work_mem') INTO __current_maintenance_work_mem;

        -- Get current maintenance workers setting (this is what actually controls index creation)
        SELECT COALESCE(CURRENT_SETTING('max_parallel_maintenance_workers', true)::INT, 2) INTO __original_maintenance_workers;

        -- Store the original maintenance_work_mem value to restore later
        __original_maintenance_work_mem := __current_maintenance_work_mem;

        -- Use minimum of 32 and max_parallel_workers for our target
        __max_parallel_maintenance_workers := LEAST(32, __max_parallel_workers);

        __new_maintenance_work_mem := hivesense_app.index_build_maintenance_work_mem(__row_count);

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

    -- The build gets a transaction of its own (the settings above are session-level
    -- and survive the COMMIT)
    COMMIT;

    -- Record start time
    __start_time := CLOCK_TIMESTAMP();
    RAISE NOTICE 'Starting HNSW index creation at %', __start_time;

    -- Try to create index with current settings, with fallback on failure
    BEGIN
        CALL hivesense_app.CREATE_HNSW_INDEX();

        -- Success - record end time and calculate duration
        __end_time := CLOCK_TIMESTAMP();
        __duration := __end_time - __start_time;

    EXCEPTION
        WHEN SQLSTATE '53100' THEN  -- disk_full (includes shared memory exhaustion)
            RAISE NOTICE 'Index creation failed with error: %', SQLERRM;
            RAISE NOTICE 'This is likely due to insufficient shared memory. Retrying with original settings...';
            RAISE NOTICE 'Resetting maintenance_work_mem to % (was: %)',
                        __original_maintenance_work_mem, __new_maintenance_work_mem;
            RAISE NOTICE 'Resetting max_parallel_maintenance_workers to % (was: %)',
                        __original_maintenance_workers, __max_parallel_maintenance_workers;

            -- Reset to original settings
            EXECUTE FORMAT('SET maintenance_work_mem TO %L', __original_maintenance_work_mem);
            BEGIN
                EXECUTE FORMAT('SET max_parallel_maintenance_workers TO %s', __original_maintenance_workers);
            EXCEPTION WHEN OTHERS THEN
                NULL; -- Ignore errors resetting workers
            END;

            -- Retry with original settings
            CALL hivesense_app.CREATE_HNSW_INDEX();

            -- Record end time for the successful retry
            __end_time := CLOCK_TIMESTAMP();
            __duration := __end_time - __start_time;

            RAISE NOTICE 'Index creation succeeded with fallback settings';
    END;
    COMMIT;
    
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

CREATE OR REPLACE FUNCTION hivesense_app.reduction_mode()
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT reduction_mode FROM hivesense_app.hivesense_app_status LIMIT 1 $$;

CREATE OR REPLACE FUNCTION hivesense_app.allow_debugging()
RETURNS boolean IMMUTABLE PARALLEL SAFE LANGUAGE sql AS
$$ SELECT allow_debugging FROM hivesense_app.hivesense_app_status LIMIT 1 $$;


RESET ROLE;

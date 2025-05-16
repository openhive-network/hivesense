-- noqa: disable=CP03
SET ROLE hivesense_owner;

DO $BODY$
DECLARE 
  __schema_name VARCHAR;
  __vector_size INT := current_setting('PG_TEMP.VECTOR_SIZE', TRUE)::INT;
  __parallel_workers INT := current_setting('PG_TEMP.PARALLEL_WORKERS', TRUE)::INT;
  synchronization_stages hive.application_stages;
  __worker INT;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  ASSERT __parallel_workers IS NOT NULL, 'No parallel_workers';
  ASSERT __parallel_workers > 0, 'Parallel workers less than 0';

  synchronization_stages := ARRAY[( 'MASSIVE_PROCESSING', 11, 10000, '30 seconds' ), hive.live_stage()]::hive.application_stages;

  RAISE NOTICE 'HiveSense will be installed in schema % with context %', __schema_name, __schema_name;

  FOR __worker IN 1..__parallel_workers LOOP
          IF hive.app_context_exists(__schema_name || __worker) THEN
              RAISE NOTICE 'Context % already exists, it means all tables are already created and data installing is skipped', __schema_name || __worker;
              CONTINUE;
          END IF;

          PERFORM hive.app_create_context(
                  _name => __schema_name || __worker ,
                  _schema => __schema_name || __worker,
                  _is_forking => False,
                  _stages => synchronization_stages
             );
  END LOOP;

CREATE TABLE IF NOT EXISTS hivesense_app_status
(
  id SERIAL PRIMARY KEY,
  continue_processing BOOLEAN NOT NULL,
  parallel_workers INT,
  llm TEXT,
  ollama TEXT,
  start_block INT
);

CREATE TABLE IF NOT EXISTS version(
  schema_hash TEXT,
  runtime_hash TEXT
);

-- extend to public, to find vector from pgvector
EXECUTE format( 'SET SEARCH_PATH TO %s, public', __schema_name );

EXECUTE format($$
            CREATE TABLE IF NOT EXISTS posts_vectors
            (
                post_id INT NOT NULL,
                embedding vector( %s ) NOT NULL
            );
            $$, __vector_size
);

-- the current version of sqlfluff doesn't understand 'GRANT MAINTAIN'
EXECUTE format( 'GRANT MAINTAIN ON ALL TABLES IN SCHEMA %s TO hived_group' , __schema_name );
EXECUTE format( 'GRANT ALL ON SCHEMA %s TO hived_group' , __schema_name );

  END
$BODY$;

INSERT INTO hivesense_app_status
(id, continue_processing, parallel_workers, llm, ollama, start_block)
VALUES
(
    1,
    TRUE,
    current_setting('PG_TEMP.PARALLEL_WORKERS', TRUE)::INT,
    current_setting('PG_TEMP.LLM', TRUE)::TEXT,
    current_setting('PG_TEMP.OLLAMA_HOST', TRUE)::TEXT,
    current_setting('PG_TEMP.START_BLOCK', TRUE)::INT
)
ON CONFLICT (id)
DO UPDATE SET
ollama = excluded.ollama;
-- only ollama host can be overridden by subsequent install
-- changing llm model or number of host requires resync

RESET ROLE;

-- noqa: disable=CP03
SET ROLE hivesense_owner;

DO $$
DECLARE 
  __schema_name VARCHAR;
  synchronization_stages hive.application_stages;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  synchronization_stages := ARRAY[( 'MASSIVE_PROCESSING', 11, 10000 ), hive.live_stage()]::hive.application_stages;

  RAISE NOTICE 'HiveSense will be installed in schema % with context %', __schema_name, __schema_name;

  IF hive.app_context_exists(__schema_name) THEN
      RAISE NOTICE 'Context % already exists, it means all tables are already created and data installing is skipped', __schema_name;
      RETURN;
  END IF;

  PERFORM hive.app_create_context(
    _name =>__schema_name,
    _schema => __schema_name,
    _is_forking => False,
    _stages => synchronization_stages
  );

CREATE TABLE IF NOT EXISTS hivesense_app_status
(
  continue_processing BOOLEAN NOT NULL,
  is_accounts_copied BOOLEAN
);

CREATE TABLE IF NOT EXISTS version(
  schema_hash TEXT,
  runtime_hash TEXT
);

-- extend to public, to find vector from pgvector
EXECUTE format( 'SET SEARCH_PATH TO %s, public', __schema_name );
CREATE TABLE IF NOT EXISTS posts_vectors
(
    post_id INT NOT NULL,
    embedding vector(1024),
    CONSTRAINT PK_posts_vectors PRIMARY KEY (post_id)
);

-- the current version of sqlfluff doesn't understand 'GRANT MAINTAIN'
EXECUTE format( 'GRANT MAINTAIN ON ALL TABLES IN SCHEMA %s TO hived_group' , __schema_name );
EXECUTE format( 'GRANT ALL ON SCHEMA %s TO hived_group' , __schema_name );

  END
$$;

INSERT INTO hivesense_app_status
(continue_processing)
VALUES
(True)
;

RESET ROLE;

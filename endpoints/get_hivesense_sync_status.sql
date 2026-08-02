SET ROLE hivesense_owner;

-- The HAF context name equals the install schema name, so it is not known until
-- install time. Bake it into the function body via format(), exactly as balance
-- tracker does, so the endpoint is correct even under a non-default --schema.
DO $$
DECLARE
  __schema_name VARCHAR;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;
  EXECUTE format(
$BODY$

/** openapi:paths
/sync-status:
  get:
    tags:
      - Other
    summary: Get HiveSense''s sync status
    description: |
      Get the last block whose embeddings HiveSense has applied, as an object
      containing both the block number and its timestamp (UTC). This is the
      uniform HAF-app sync/health endpoint: the timestamp lets a consumer
      compute staleness with a single call (`age = now() - last_block_time`)
      without needing a separate head-block reference.

      HiveSense syncs embeddings out of band from a remote embedding API, so
      this value may lag chain head during catch-up.

      SQL example
      * `SELECT hivesense_endpoints.get_hivesense_sync_status();`

      REST call example
      * `GET ''/hivesense-api/sync-status''`
    operationId: hivesense_endpoints.get_hivesense_sync_status
    responses:
      '200':
        description: |
          Last block synced by HiveSense together with its timestamp.
          `last_block_time` is null if no block has been processed yet.
          While the HAF instance is still in massive sync (indexes not yet
          built) the call fails fast with an error rather than executing an
          unindexed lookup.

          * Returns `JSON`
        content:
          application/json:
            schema:
              type: object
              properties:
                last_block_num:
                  type: integer
                  description: highest block number whose embeddings HiveSense has applied
                last_block_time:
                  type: string
                  format: date-time
                  description: UTC timestamp of that block
            example:
              last_block_num: 5000000
              last_block_time: '2016-09-15T19:47:21'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.get_hivesense_sync_status;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_hivesense_sync_status()
RETURNS JSON
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS
$pb$
BEGIN
  -- Fail fast during HAF massive sync: hafd.blocks' PK is dropped for the
  -- duration (hive.disable_indexes_of_irreversible), so the join below would
  -- seq-scan the largest table in the database. Health-check agents gate on
  -- is_instance_ready() before calling APIs; this guard protects any caller
  -- that does not by erroring in milliseconds instead of stalling.
  IF NOT hive.is_instance_ready() THEN
    RAISE EXCEPTION 'HAF instance is not ready (massive sync in progress)'
      USING ERRCODE = '55000';
  END IF;

  -- No cache: sync status must be read in real time by monitors / freshness checks.
  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=0"}]', true);

  -- LEFT JOIN so the pre-sync case (no processed block yet) still yields an
  -- object with a null timestamp instead of no row.
  RETURN (
    SELECT json_build_object(
      'last_block_num', c.current_block_num,
      'last_block_time', to_char(b.created_at, 'YYYY-MM-DD"T"HH24:MI:SS')
    )
    FROM hafd.contexts c
    LEFT JOIN hafd.blocks b ON b.num = c.current_block_num
    WHERE c.name = '%1$s'
  );
END
$pb$;

$BODY$,
  __schema_name);
END
$$;

RESET ROLE;

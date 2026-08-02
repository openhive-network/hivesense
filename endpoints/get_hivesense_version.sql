SET ROLE hivesense_owner;

/** openapi:paths
/version:
  get:
    tags:
      - Other
    summary: Get HiveSense''s version
    description: |
      Get the git commit hash of the deployed HiveSense version.
      Returns `unspecified` when the image was built without a git hash.

      SQL example
      * `SELECT hivesense_endpoints.get_hivesense_version();`

      REST call example
      * `GET ''/hivesense-api/version''`
    operationId: hivesense_endpoints.get_hivesense_version
    responses:
      '200':
        description: |
          HiveSense version (git commit hash)

          * Returns `TEXT`
        content:
          application/json:
            schema:
              type: string
            example: c2fed8958584511ef1a66dab3dbac8c40f3518f0
      '404':
        description: App not installed
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.get_hivesense_version;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_hivesense_version()
RETURNS TEXT 
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS
$$
BEGIN
  -- Long cache: the version only changes on deployment.
  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=86400"}]', true);

  -- `version` resolves via PGRST_DB_EXTRA_SEARCH_PATH (hivesense_app); the table
  -- is populated at install time by SET_VERSION() (see install_app.sh). COALESCE
  -- guards the pre-population / empty-table case so the endpoint never returns null.
  RETURN COALESCE((SELECT runtime_hash FROM version LIMIT 1), 'unspecified');
END
$$;

RESET ROLE;

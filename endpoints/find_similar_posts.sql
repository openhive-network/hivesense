SET ROLE hivesense_owner;

/** openapi:paths
/similarposts:
  get:
    tags:
        - AI
    summary: List of posts semantic similar to a given pattern
    description: |
      Make a semantic search for a posts similar to a pattern text given as a parameter

      SQL example
      * `SELECT * FROM hivesense_endpoints.get_similar_posts(''astronauts on moon'', 10);`

      REST call example
      * `GET ''https://%1$s/hivesense-api/similarposts/''`
    operationId: hivesense_endpoints.get_similar_posts
    parameters:
      - in: query
        name: pattern
        required: true
        schema:
          type: string
        description: pattern to search in posts
      - in: query
        name: pagesize
        required: true
    responses:
      '200':
        description: |
            Returns an array of similar posts to the given pattern, sorted in ascending order by similarity.

          * Returns:  An array (`array`) of strings (`string[]`).
        content:
          application/json:
            schema:
                type: array
                items:
                    type: string
            example: [ '@bob/my_introduction_post', '@alice/intro' ]
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.get_similar_posts;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_similar_posts(
    pattern TEXT, pagesize INT
)
    RETURNS JSON -- sorted array of @<author>/<permlink>
-- openapi-generated-code-end
    LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
    __result JSON;
BEGIN

    SELECT TO_JSON(ARRAY_AGG('@' || ha.name || '/' || hpd.permlink ORDER BY search.similarity_order))
    FROM find_nearest_posts( pattern, pagesize ) as search
    JOIN hivemind_app.hive_posts hp ON hp.id = search.post_id
    JOIN hivemind_app.hive_accounts ha ON hp.author_id = ha.id
    JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
    INTO __result;

    RETURN COALESCE( __result, '{}'::JSON);
END
$$;

RESET ROLE;

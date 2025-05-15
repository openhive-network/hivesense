SET ROLE hivesense_owner;

/** openapi:paths
/thematiccontributors:
  get:
    tags:
      - AI
    summary: List of Hive accounts thematically aligned with a given pattern, ranked by the semantic similarity of their posts.
    description: |
      This endpoint returns a JSON array of author names ranked by their thematic alignment
      with a given text pattern. The ranking is based on the semantic similarity of their
      posts to the input pattern, with higher-ranked posts contributing more to the author’s score.
      Each authors score is computed as the sum of 1 / sqrt(r), where r is the rank of each post
      associated with the author. Authors with more frequent and higher-ranked posts receive higher scores.
      The result is a sorted list of author names, from most to least thematically aligned.

    operationId: hivesense_endpoints.find_thematic_contributors
    parameters:
      - in: query
        name: thematic
        required: true
        schema:
          type: string
        description: Text pattern used for semantic search. The query text (e.g., "astronauts on moon", "climate change") to find contributors.
        example: "Make witness node secure against hackers attack and emergency situations"
      - in: query
        name: authors_limit
        required: true
        schema:
          type: integer
        description: Specifies how many authors to return in the results.
        example: 10
      - in: query
        name: observer
        required: false
        schema:
          type: string
          default: ''
        description: Observer (hive account name) whose settings (such as muted lists) are used to filter out excluded posts from the search results
    responses:
      '200':
        description: |
          * Returns  JSON with a sorted list of Hive accounts
        content:
          application/json:
            schema:
              type: string
              x-sql-datatype: JSON
            example: [
              "dele-puppy",
              "nextgencrypto",
              "xeroc",
              "steemed",
              "tuck-fheman",
              "dantheman",
              "salvation",
              "pharesim",
              "masteryoda",
              "ihashfury"
            ]
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.find_thematic_contributors;
CREATE OR REPLACE FUNCTION hivesense_endpoints.find_thematic_contributors(
    "thematic" TEXT,
    "authors_limit" INT,
    "observer" TEXT = ''
)
RETURNS JSON 
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS
$$
DECLARE
    __result JSON;
    __observer_id INT := 0;
BEGIN
    IF observer != '' THEN
        __observer_id = hivemind_postgrest_utilities.find_account_id(
                hivemind_postgrest_utilities.valid_account( observer ),
                True);
    END IF;

    SELECT jsonb_agg (
            ha.name ORDER BY search.rank ASC
    ) FROM find_thematic_contributors_with_embedding(
                   hivesense_embed(thematic)
                 , authors_limit
                 , _observer_id => __observer_id
    ) as search
    JOIN hivemind_app.hive_accounts ha ON ha.id = search.author_id
    INTO __result;

    RETURN COALESCE( __result, '{}'::JSON);
END
$$;

RESET ROLE;

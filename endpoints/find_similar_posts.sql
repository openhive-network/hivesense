SET ROLE hivesense_owner;

/** openapi:paths
/similarposts:
  get:
    tags:
      - AI
    summary: List of posts semantic similar to a given pattern
    description: |
      Make a semantic search for a posts similar to a pattern text given as a parameter. Returns max first 50 most similar posts.

      SQL example
      * `SELECT * FROM hivesense_endpoints.get_similar_posts(''astronauts on moon'', 0);`

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
        name: tr_body
        required: true
        schema:
          type: integer
        description: 0 means no truncate, other return post shrinked to given value
      - in: query
        name: posts_limit
        required: true
        schema:
          type: integer
        description: limit for number of posts, cannot be grater than 50
      - in: query
        name: observer
        required: false
        schema:
          type: string
          default: ''
        description: account name to use its blacklists
    responses:
      '200':
        description: |
          * Returns  JSON
        content:
          application/json:
            schema:
              type: string
              x-sql-datatype: JSON
            example: { }
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.get_similar_posts;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_similar_posts(
    "pattern" TEXT,
    "tr_body" INT,
    "posts_limit" INT,
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
    IF posts_limit > 50 THEN
        RAISE EXCEPTION 'Limit of posts: % is grater than allowed maximum: 50', posts_limit;
    END IF;

    IF observer != '' THEN
        __observer_id = hivemind_postgrest_utilities.find_account_id(
                hivemind_postgrest_utilities.valid_account( observer ),
                True);
    END IF;

    SELECT jsonb_agg (
            hivemind_postgrest_utilities.create_bridge_post_object(row, tr_body, NULL, row.is_pinned, True) ORDER BY row.similarity_order ASC
    ) FROM (
       SELECT
           hp.id,
           hp.author,
           hp.parent_author,
           hp.author_rep,
           hp.root_title,
           hp.beneficiaries,
           hp.max_accepted_payout,
           hp.percent_hbd,
           hp.url,
           hp.permlink,
           hp.parent_permlink_or_category,
           hp.title,
           hp.body,
           hp.category,
           hp.depth,
           hp.payout,
           hp.pending_payout,
           hp.payout_at,
           hp.is_paidout,
           hp.children,
           hp.votes,
           hp.created_at,
           hp.updated_at,
           hp.rshares,
           hp.abs_rshares,
           hp.json,
           hp.is_hidden,
           hp.is_grayed,
           hp.total_votes,
           hp.sc_trend,
           hp.role_title,
           hp.community_title,
           hp.role_id,
           hp.is_pinned,
           hp.curator_payout_value,
           hp.is_muted,
           hp.source AS blacklists,
           hp.muted_reasons,
           search.similarity_order
        FROM find_nearest_posts(pattern, posts_limit, 0, _observer_id => __observer_id) as search,
        LATERAL hivemind_app.get_full_post_view_by_id(search.post_id, __observer_id) hp
    ) row
    INTO __result;

    RETURN COALESCE( __result, '{}'::JSON);
END
$$;

RESET ROLE;

SET ROLE hivesense_owner;

/** openapi:paths
/similarpostsbypost:
  get:
    tags:
      - AI
    summary: List of posts semantic similar to a given post described by author and permlink
    description: |
      Make a semantic search for a posts similar to a given post as a parameter. Returns max. first 50 most similar posts.

      SQL example
      * `SELECT * FROM hivesense_endpoints.get_similar_posts_by_post(''bue-witness'',''bue-witness-post'', 20, 10);`

      REST call example
      * `GET ''https://%1$s/hivesense-api/similarpoststsbypost/''`
    operationId: hivesense_endpoints.get_similar_posts_by_post
    parameters:
      - in: query
        name: author
        required: true
        schema:
          type: string
        description: post author name
      - in: query
        name: permlink
        required: true
        schema:
          type: string
        description: permlink of a post
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
DROP FUNCTION IF EXISTS hivesense_endpoints.get_similar_posts_by_post;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_similar_posts_by_post(
    "author" TEXT,
    "permlink" TEXT,
    "tr_body" INT,
    "posts_limit" INT
)
RETURNS JSON
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS
$$
DECLARE
    __result JSON;
    __post_id INT;
BEGIN
    IF posts_limit > 50 THEN
        RAISE EXCEPTION 'Limit of posts: % is grater than allowed maximum: 50', posts_limit;
    END IF;

    __post_id = hivemind_app.find_comment_id( author, permlink, True );

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
                      FROM find_nearest_posts_to_post(author, permlink, posts_limit, 0) as search,
                        LATERAL hivemind_app.get_full_post_view_by_id(search.post_id, NULL) hp --TODO(mickiewicz@syncad.com): observer is NULL is it ok ?
                  ) row
    INTO __result;

    RETURN COALESCE( __result, '{}'::JSON);
END
$$;

RESET ROLE;

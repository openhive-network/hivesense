SET ROLE hivesense_owner;

/** openapi:paths
/similarposts:
  get:
    tags:
      - AI
    summary: List of posts semantic similar to a given pattern
    description: |
      Semantic search endpoint designed to find posts based on their semantic
      similarity to a provided text pattern. It allows users to search for
      content that is contextually and meaningfully similar to their search
      query, going beyond simple keyword matching.

      The API returns results in JSON format, containing comprehensive post information
      including author details, title, body content, category, voting data, and various metadata.
      Results are automatically ranked by their semantic relevance to the search pattern,
      ensuring the most relevant content appears first.

    operationId: hivesense_endpoints.get_similar_posts
    parameters:
      - in: query
        name: pattern
        required: true
        schema:
          type: string
        description: Text pattern used for semantic search. The query text (e.g., "astronauts on moon", "climate change") to find semantically similar posts.
      - in: query
        name: tr_body
        required: true
        schema:
          type: integer
        description: Truncation length for post bodies. Use 0 for full content, or specify character limit.
      - in: query
        name: posts_limit
        required: true
        schema:
          type: integer
        description: Specifies how many posts to return in the results.
      - in: query
        name: observer
        required: false
        schema:
          type: string
          default: ''
        description: Observer (hive account name) whose settings (such as muted lists) are used to filter out excluded posts from the search results
      - in: query
        name: start_author
        required: false
        schema:
          type: string
          default: ''
        description: |
          Together with start_permlink, identifies the last post from the previous page. These two parameters combined
          define the starting point for pagination when fetching the next set of results.
      - in: query
        name: start_permlink
        required: false
        schema:
          type: string
          default: ''
        description: |
          Together with start_author, identifies the last post from the previous page. The permlink is
          the unique identifier (slug) of the post. These two parameters combined define the starting point
          for pagination when fetching the next set of results.
    responses:
      '200':
        description: |
          * Returns  JSON with a sorted list of posts
        content:
          application/json:
            schema:
              type: string
              x-sql-datatype: JSON
            example: {}
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.get_similar_posts;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_similar_posts(
    "pattern" TEXT,
    "tr_body" INT,
    "posts_limit" INT,
    "observer" TEXT = '',
    "start_author" TEXT = '',
    "start_permlink" TEXT = ''
)
RETURNS JSON 
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS
$$
DECLARE
    __result JSON;
    __observer_id INT := 0;
    __start_post_id INT := 0;
BEGIN
    IF observer != '' THEN
        __observer_id = hivemind_postgrest_utilities.find_account_id(
                hivemind_postgrest_utilities.valid_account( observer ),
                True);
    END IF;

    IF start_author != '' OR start_permlink != '' THEN
        __start_post_id = hivemind_postgrest_utilities.find_comment_id(
            start_author, start_permlink, True);
    END IF;

    SELECT jsonb_agg (
            hivemind_postgrest_utilities.create_bridge_post_object(__observer_id, row, tr_body, NULL, row.is_pinned, True) ORDER BY row.similarity_order ASC
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
        FROM hivesense_app.find_nearest_posts(
                   pattern
                 , posts_limit
                 , _observer_id => __observer_id
                 , _start_post_id => __start_post_id
             ) as search,
        LATERAL hivemind_app.get_full_post_view_by_id(search.post_id, __observer_id) hp
    ) row
    INTO __result;

    RETURN COALESCE( __result, '{}'::JSON);
END
$$;

RESET ROLE;

SET ROLE hivesense_owner;

/** openapi:paths
/similarpostsbypost:
  get:
    tags:
      - AI
    summary: Get semantically similar posts to a given Hive post
    description: |
      Performs semantic similarity search to find posts that are contextually
      similar to a specified Hive post. The endpoint analyzes the content and
      context of the target post and returns up to 50 related posts, ranked by
      their similarity score.

      Key features:
      - Semantic analysis considers post content and context
      - Results are ordered by similarity (most similar first)
      - Optional content filtering through observer blacklists
      - Configurable body length truncation for preview purposes
      - Maximum of 50 posts returned to ensure performance
    
      The similarity analysis takes into account:
      - Post content and context
      - Semantic relationships between posts
      - Topic relevance and contextual meaning

      SQL example:
      SELECT * FROM hivesense_endpoints.get_similar_posts_by_post(''bue-witness'', ''bue-witness-post'', 20, 10);

      REST call example:
      GET ''https://%1$s/hivesense-api/similarpostsbypost?author=bue-witness&permlink=my-blog-post&tr_body=20&posts_limit=10''
    operationId: hivesense_endpoints.get_similar_posts_by_post
    parameters:
      - in: query
        name: author
        required: true
        schema:
          type: string
        description: |
          The Hive username of the post author. This is the account name that
          created the original post for which you want to find similar content.
          Must be a valid Hive account name.
        example: "bue-witness"
      - in: query
        name: permlink
        required: true
        schema:
          type: string
        description: |
          The unique permlink identifier of the post. This is the URL-friendly
          version of the post title that appears in the post URL on Hive.
          Together with the author name, it uniquely identifies the post.
        example: "my-blog-post"
      - in: query
        name: tr_body
        required: true
        schema:
          type: integer
          minimum: 0
          maximum: 65535
        description: |
          Controls the length of returned post bodies in the results. When set to 0,
          returns complete post content. Any other positive value will truncate the
          post body to that many characters. Useful for generating previews or
          reducing response size. Maximum value is 65535 characters.
        example: 20
      - in: query
        name: posts_limit
        required: true
        schema:
          type: integer
          minimum: 1
          maximum: 50
        description: |
          Specifies the maximum number of similar posts to return. Must be between
          1 and 50. The posts are returned in order of similarity, with the most
          similar posts first. Setting a lower limit can improve response times
          and reduce data transfer.
        example: 10
      - in: query
        name: observer
        required: false
        schema:
          type: string
          default: ''
        description: |
          Optional Hive account name with blacklists that will be used to filter the
          results. When provided, any posts from authors in the observer
          blacklist will be excluded from the results. Leave empty to disable
          blacklist filtering. Useful for content moderation and personalization.
        example: "hive.blog"
    responses:
      '200':
        description: Successful response with JSON that contains a list of similar posts
        content:
          application/json:
            schema:
              type: string
              x-sql-datatype: JSON
            example: {}
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.get_similar_posts_by_post;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_similar_posts_by_post(
    "author" TEXT,
    "permlink" TEXT,
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
    __post_id INT;
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
                      FROM find_nearest_posts_to_post(author, permlink, posts_limit, _observer_id => __observer_id) as search,
                        LATERAL hivemind_app.get_full_post_view_by_id(search.post_id, __observer_id) hp --TODO(mickiewicz@syncad.com): observer is NULL is it ok ?
                  ) row
    INTO __result;

    RETURN COALESCE( __result, '{}'::JSON);
END
$$;

RESET ROLE;

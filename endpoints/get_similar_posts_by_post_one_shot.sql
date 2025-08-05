SET ROLE hivesense_owner;
/** openapi:paths
/similarpostsbypost-one-shot:
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
    operationId: hivesense_endpoints.get_similar_posts_by_post_one_shot
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
          maximum: 100
        description: |
          Specifies the maximum number of similar posts to return. Must be between
          1 and 50. The posts are returned in order of similarity, with the most
          similar posts first. Setting a lower limit can improve response times
          and reduce data transfer.
        example: 10
      - in: query
        name: full_posts
        required: true
        schema:
          type: integer
          minimum: 0
          maximum: 50
        description: |
          Specifies the maximum number of posts to return full data for, any 
          remaining posts will simply be author & permlink.  Set this to the size
          of your first page of results, then make another call passing the 
          author/permlinks for subsequent pages
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
DROP FUNCTION IF EXISTS hivesense_endpoints.get_similar_posts_by_post_one_shot;
CREATE FUNCTION hivesense_endpoints.get_similar_posts_by_post_one_shot(
    "author"      TEXT,
    "permlink"    TEXT,
    "tr_body"     INT,
    "posts_limit" INT = 100,
    "full_posts"  INT = 10,
    "observer"    TEXT = ''
)
RETURNS JSON
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    __observer_id INT := 0;
    __result      JSON;
BEGIN
    /* validate args */
    IF posts_limit < 1 OR posts_limit > 1000 THEN
        RAISE EXCEPTION 'posts_limit must be between 1 and 1000';
    END IF;
    IF full_posts < 0 OR full_posts > 50 THEN
        RAISE EXCEPTION 'full_posts must be between 0 and 50';
    END IF;
    IF full_posts > posts_limit THEN
        RAISE EXCEPTION 'full_posts (%s) cannot exceed posts_limit (%s)',
                        full_posts, posts_limit;
    END IF;

    /* observer → id */
    IF observer <> '' THEN
        __observer_id :=
            hivemind_postgrest_utilities.find_account_id(
                hivemind_postgrest_utilities.valid_account(observer), TRUE);
    END IF;

    /* main flow */
    WITH ranked AS (
        SELECT *
          FROM hivesense_app.find_nearest_posts_to_post_one_shot(
                   author, permlink, posts_limit, __observer_id)
    ),

    top_full AS (
        SELECT bp.obj
          FROM (
            SELECT post_id
              FROM ranked
             ORDER BY similarity_order
             LIMIT full_posts
          ) lim
          /* ① fetch full-post view, add blacklists alias */
          JOIN LATERAL (
                SELECT fv.*, fv.source AS blacklists
                  FROM hivemind_app.get_full_post_view_by_id(
                           lim.post_id, __observer_id) fv
          ) fpv ON TRUE
          /* ② build bridge-post JSON using the augmented record */
          JOIN LATERAL (
                SELECT hivemind_postgrest_utilities.create_bridge_post_object(
                           __observer_id,
                           fpv.*,
                           tr_body,
                           NULL,
                           fpv.is_pinned,
                           TRUE) AS obj
          ) bp ON TRUE
    ),

    rest_stub AS (
        SELECT jsonb_build_object(
                 'author',   ha.name,
                 'permlink', hpd.permlink)
                 AS obj
          FROM (
            SELECT post_id
              FROM ranked
             ORDER BY similarity_order
             OFFSET full_posts
             LIMIT (posts_limit - full_posts)
          ) lim
          JOIN hivemind_app.hive_posts         hp  ON hp.id  = lim.post_id
          JOIN hivemind_app.hive_accounts      ha  ON ha.id  = hp.author_id
          JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
    )

    SELECT jsonb_agg(obj ORDER BY 1)
      INTO __result
      FROM (
         SELECT obj FROM top_full
         UNION ALL
         SELECT obj FROM rest_stub
      ) t;

    RETURN COALESCE(__result, '[]'::JSON);
END;
$$;

RESET ROLE;

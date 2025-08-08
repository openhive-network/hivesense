SET ROLE hivesense_owner;
/** openapi:paths
/posts/{author}/{permlink}/similar:
  get:
    tags:
      - AI
    summary: Full semantic search results for similar posts in a single call
    description: |
      Performs semantic similarity search to find posts that are contextually
      similar to a specified Hive post. Returns an ordered list of posts most 
      similar to the given post.
      
      The first **N** results (default 10, max 50) are returned as full
      bridge-post JSON objects; the remaining results (up to **posts_limit**,
      default 100, max 1000) are stub entries containing only *author* and
      *permlink*. Paging is done entirely on the client side.

      Key features:
      - Semantic analysis considers post content and context
      - Results are ordered by similarity (most similar first)
      - Optional content filtering through observer blacklists
      - Configurable body length truncation for preview purposes
      - Split response: full data for top results, stubs for remainder
    
      The similarity analysis takes into account:
      - Post content and context
      - Semantic relationships between posts
      - Topic relevance and contextual meaning

      SQL example:
      SELECT * FROM hivesense_endpoints.posts_similar(''bue-witness'', ''bue-witness-post'', 20, 100, 10);

      REST call example:
      GET ''https://%1$s/hivesense-api/posts/bue-witness/my-blog-post/similar?truncate=20&limit=100&full_posts=10''
    operationId: hivesense_endpoints.posts_similar
    parameters:
      - in: path
        name: author
        required: true
        schema:
          type: string
        description: |
          The Hive username of the post author. This is the account name that
          created the original post for which you want to find similar content.
          Must be a valid Hive account name.
        example: "bue-witness"
      - in: path
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
        name: truncate
        required: false
        schema:
          type: integer
          minimum: 0
          maximum: 65535
          default: 0
        description: |
          Controls the length of returned post bodies in the results. When set to 0,
          returns complete post content. Any other positive value will truncate the
          post body to that many characters. Useful for generating previews or
          reducing response size. Maximum value is 65535 characters.
        example: 20
      - in: query
        name: limit
        required: false
        schema:
          type: integer
          default: 100
          minimum: 1
          maximum: 1000
        description: |
          Total number of posts (full + stub) to return. Must be between
          1 and 1000. The posts are returned in order of similarity, with the most
          similar posts first. Setting a lower limit can improve response times
          and reduce data transfer.
        example: 100
      - in: query
        name: full_posts
        required: false
        schema:
          type: integer
          default: 10
          minimum: 0
          maximum: 50
        description: |
          How many of the top results should include full post data. Any 
          remaining posts (up to limit) will be stub entries with only 
          author & permlink. Set this to the size of your first page of results.
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
DROP FUNCTION IF EXISTS hivesense_endpoints.posts_similar;
CREATE OR REPLACE FUNCTION hivesense_endpoints.posts_similar(
    "author" TEXT,
    "permlink" TEXT,
    "truncate" INT = 0,
    "limit" INT = 100,
    "full_posts" INT = 10,
    "observer" TEXT = ''
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
    IF "limit" < 1 OR "limit" > 1000 THEN
        RAISE EXCEPTION 'limit must be between 1 and 1000';
    END IF;
    IF full_posts < 0 OR full_posts > 50 THEN
        RAISE EXCEPTION 'full_posts must be between 0 and 50';
    END IF;
    IF full_posts > "limit" THEN
        RAISE EXCEPTION 'full_posts (%s) cannot exceed limit (%s)',
                        full_posts, "limit";
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
                   author, permlink, "limit", __observer_id)
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
                           "truncate",
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
             LIMIT ("limit" - full_posts)
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

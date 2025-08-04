/** openapi:paths
/similarposts_one_shot:
  get:
    tags: [AI]
    summary: Full semantic search results in a single call
    description: |
      Returns an ordered list of posts most similar to a given query.
      The first **N** results (default 10, max 50) are returned as full
      bridge-post JSON objects; the remaining results (up to **posts_limit**,
      default 100, max 1000) are stub entries containing only *author* and
      *permlink*.  Paging is now done entirely on the client side.
    operationId: hivesense_endpoints.get_similar_posts_one_shot
    parameters:
      - in: query
        name: pattern
        required: true
        schema: {type: string}
        description: Query text, e.g. `"vector databases"`
      - in: query
        name: tr_body
        required: true
        schema: {type: integer}
        description: 0 = full body, otherwise truncate to this many chars
      - in: query
        name: posts_limit
        required: false
        schema: {type: integer, default: 100, minimum: 1, maximum: 1000}
        description: Total number of posts (full + stub) to return
      - in: query
        name: full_posts
        required: false
        schema: {type: integer, default: 10, minimum: 0, maximum: 50}
        description: How many of the top results should include full post data
      - in: query
        name: observer
        required: false
        schema: {type: string, default: ''}
        description: Hive account whose mute lists etc. will be respected
    responses:
      '200':
        description: JSON array of result objects
        content:
          application/json:
            schema: {type: string, x-sql-datatype: JSON}
            example: {}
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.get_similar_posts_one_shot;
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_similar_posts_one_shot(
    "pattern"      TEXT,
    "tr_body"      INT,
    "posts_limit"  INT = 100,
    "full_posts"   INT = 10,
    "observer"     TEXT = ''
)
RETURNS JSON
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    __observer_id      INT := 0;
    __result           JSON;
BEGIN
    /* ─── validate parameters ─────────────────────────────── */
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

    /* ─── observer handling ──────────────────────────────── */
    IF observer <> '' THEN
        __observer_id := hivemind_postgrest_utilities.find_account_id(
                           hivemind_postgrest_utilities.valid_account(observer),
                           TRUE);
    END IF;

    /* ─── main query: ANN + (optional) full-post join ────── */
    SELECT jsonb_agg(obj ORDER BY similarity_order)
      INTO __result
      FROM (
        SELECT
            sr.similarity_order,
            CASE
              WHEN sr.similarity_order <= full_posts THEN
                   hivemind_postgrest_utilities.create_bridge_post_object(
                       __observer_id, hp, tr_body, NULL, hp.is_pinned, TRUE)
              ELSE
                   jsonb_build_object(
                       'author',  hp.author,
                       'permlink',hp.permlink)
            END AS obj
        FROM hivesense_app.find_nearest_posts_one_shot(
                 pattern,
                 posts_limit,
                 __observer_id
             ) AS sr
JOIN LATERAL (
    SELECT fv.*, fv.source AS blacklists
      FROM hivemind_app.get_full_post_view_by_id(
               sr.post_id, __observer_id) fv
) hp ON TRUE
      ) sub;

    RETURN COALESCE(__result, '[]'::JSON);
END
$$;

/** openapi:paths
/similarposts-one-shot:
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
    __observer_id INT := 0;
    __result      JSON;
BEGIN
    /* ─── validate parameters ───────────────────────────── */
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

    /* ─── observer ⇒ id ─────────────────────────────────── */
    IF observer <> '' THEN
        __observer_id := hivemind_postgrest_utilities.find_account_id(
                           hivemind_postgrest_utilities.valid_account(observer),
                           TRUE);
    END IF;

    /* ─── CORE query once; slice in SQL, not PL/pgSQL —— */
    WITH ranked AS (
        SELECT *
          FROM hivesense_app.find_nearest_posts_one_shot(
                   pattern,
                   posts_limit,
                   __observer_id
               )
    ),

    /* ---------- 1️⃣  full objects for top N ---------- */
    top_full AS (
        SELECT hbpo.obj
          FROM (
            SELECT sr.post_id
              FROM ranked sr
             ORDER BY sr.similarity_order
             LIMIT full_posts
          ) lim
          JOIN LATERAL (SELECT fv.*, fv.source AS blacklists
                        FROM hivemind_app.get_full_post_view_by_id(lim.post_id, __observer_id) fv) fpv ON TRUE
          JOIN LATERAL (
                SELECT hivemind_postgrest_utilities.create_bridge_post_object(
                           __observer_id,
                           fpv.*,
                           tr_body,
                           NULL,
                           fpv.is_pinned,
                           TRUE
                       ) AS obj
          ) hbpo ON TRUE
    ),

    /* ---------- 2️⃣  lightweight stubs for the rest ---------- */
    rest_stub AS (
        SELECT jsonb_build_object(
                   'author',   ha.name,
                   'permlink', hpd.permlink
               ) AS obj
          FROM (
            SELECT sr.post_id
              FROM ranked sr
             ORDER BY sr.similarity_order
             OFFSET full_posts
             LIMIT  (posts_limit - full_posts)
          ) lim
          JOIN hivemind_app.hive_posts         hp  ON hp.id  = lim.post_id
          JOIN hivemind_app.hive_accounts      ha  ON ha.id  = hp.author_id
          JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
    )

    /* ---------- aggregate in original order ---------- */
    SELECT jsonb_agg(obj)  /* order already preserved */
      INTO __result
      FROM (
        SELECT obj FROM top_full
        UNION ALL
        SELECT obj FROM rest_stub
      ) unioned
      ORDER BY 1;   -- UNION ALL keeps original order, but ORDER BY makes it explicit

    RETURN COALESCE(__result, '[]'::JSON);
END;
$$;

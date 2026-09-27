/** openapi:paths
/posts/search:
  get:
    tags: [AI]
    summary: Full semantic search results in a single call
    description: |
      Returns an ordered list of posts most similar to a given query.
      The first **N** results (default 10, max 50) are returned as full
      bridge-post JSON objects; the remaining results (up to **posts_limit**,
      default 100, max 1000) are stub entries containing only *author* and
      *permlink*.  Paging is now done entirely on the client side.
      Deleted posts are never returned.
    operationId: hivesense_endpoints.posts_search
    parameters:
      - in: query
        name: q
        required: true
        schema: {type: string}
        description: Search query text for semantic similarity, e.g. `"vector databases"`
      - in: query
        name: truncate
        required: false
        schema: {type: integer, default: 0}
        description: Body truncation length (0 = full content, >0 = truncate to N chars)
      - in: query
        name: result_limit
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
      - in: query
        name: author
        required: false
        schema: {type: string, default: ''}
        description: |
          Only return posts by this Hive account (a bare account name, without `@`).
          The ranking is exact across all embedded posts of that author rather than
          approximate. An unknown account is an error; an author with no embedded
          posts, or one muted by `observer`, returns an empty array.
      - in: query
        name: from-block
        required: false
        schema:
          type: string
          default: NULL
        description: |
          Only return posts created at or after this point, given as in the other HAF APIs:
          a block number, or a timestamp in the format YYYY-MM-DD HH:MI:SS, which is converted
          to the first block created at or after it. It is the block that created the post,
          not the block of its last edit.

          Within the range the ranking is exact across all embedded posts rather than
          approximate. Without `author`, the range may span at most 5270400 blocks (about
          six months), measured to the newest block when `to-block` is omitted; a missing
          `from-block` means genesis, so `to-block` alone is only accepted early in the
          chain. The range, padded by about 10000 blocks on each side, may also hold at
          most a server-configured number of embedded post chunks (300000 by default,
          enough for the latest six months but only about ten days of 2018). A larger or
          denser range is an error, so narrow it. With `author`, neither limit applies.
          Combines with `observer`.

          * `2026-09-01 00:00:00`

          * `109000000`
      - in: query
        name: to-block
        required: false
        schema:
          type: string
          default: NULL
        description: |
          Only return posts created at or before this point: a block number (inclusive), or a
          timestamp in the format YYYY-MM-DD HH:MI:SS, which HAF converts to the last block
          created before it (a block created exactly at that second is not included).
          Without it the range runs to the newest post.
    responses:
      '200':
        description: JSON array of result objects
        content:
          application/json:
            schema: {type: string, x-sql-datatype: JSON}
            example: {}
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.posts_search;
CREATE OR REPLACE FUNCTION hivesense_endpoints.posts_search(
    "q" TEXT,
    "truncate" INT = 0,
    "result_limit" INT = 100,
    "full_posts" INT = 10,
    "observer" TEXT = '',
    "author" TEXT = '',
    "from-block" TEXT = NULL,
    "to-block" TEXT = NULL
)
RETURNS JSON 
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    __observer_id INT := 0;
    __author_id   INT := NULL;
    __range       hive.blocks_range;
    __first_block INT := NULL;
    __last_block  INT := NULL;
    __span        BIGINT;
    __max_span    CONSTANT INT := 5270400;  -- 183 days of 3-second blocks
    __result      JSON;
BEGIN
    /* ─── validate parameters ───────────────────────────── */
    IF result_limit < 1 OR result_limit > 1000 THEN
        RAISE EXCEPTION 'result_limit must be between 1 and 1000';
    END IF;
    IF full_posts < 0 OR full_posts > 50 THEN
        RAISE EXCEPTION 'full_posts must be between 0 and 50';
    END IF;
    /* Clamp full_posts to result_limit if it exceeds */
    IF full_posts > result_limit THEN
        full_posts := result_limit;
    END IF;

    /* ─── observer ⇒ id ─────────────────────────────────── */
    IF observer <> '' THEN
        __observer_id := hivemind_postgrest_utilities.find_account_id(
                           hivemind_postgrest_utilities.valid_account(observer),
                           TRUE);
    END IF;

    /* ─── author filter ⇒ id (#47) ──────────────────────── */
    IF author <> '' THEN
        __author_id := hivemind_postgrest_utilities.find_account_id(
                         hivemind_postgrest_utilities.valid_account(author),
                         TRUE);
    END IF;

    /* ─── block range ⇒ first/last block (#13) ───────────── */
    -- Same inputs as the other HAF APIs (a block number or a timestamp),
    -- converted by HAF itself, which also rejects malformed values, future
    -- timestamps and a reversed range. An empty value means no bound; a
    -- missing from-block means genesis, as in the other HAF APIs.
    IF NULLIF(btrim("from-block"), '') IS NOT NULL OR NULLIF(btrim("to-block"), '') IS NOT NULL THEN
        __range := hive.convert_to_blocks_range(NULLIF(btrim("from-block"), ''),
                                                NULLIF(btrim("to-block"), ''));
        __first_block := COALESCE(__range.first_block, 1);
        __last_block  := __range.last_block;   -- NULL: up to the newest post

        -- Both limits are checked here, before the query is embedded, so an
        -- oversized range costs no call to the embedding server. With an
        -- author the ranking covers only that author's posts, so neither
        -- limit applies.
        IF __author_id IS NULL THEN
            -- An open end is measured to the current block; if that is
            -- unknown, fail closed rather than skip the check.
            __span := COALESCE(__last_block, hive.app_get_current_block_num('hivesense_app'), 2147483647)::BIGINT
                      - __first_block + 1;
            IF __span > __max_span THEN
                RAISE EXCEPTION 'from-block/to-block may span at most % blocks (about six months); this range spans % blocks',
                      __max_span, __span;
            END IF;
            PERFORM hivesense_app.window_post_bounds(__first_block, __last_block);
        END IF;
    END IF;

    /* ─── CORE query once; slice in SQL, not PL/pgSQL —— */
    WITH ranked AS (
        SELECT *
          FROM hivesense_app.find_nearest_posts(
                   q,
                   result_limit,
                   __observer_id,
                   __author_id
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
                           "truncate",
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
             LIMIT  (result_limit - full_posts)
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

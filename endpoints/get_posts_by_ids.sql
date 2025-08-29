SET ROLE hivesense_owner;

/** openapi:paths
/posts/by-ids:
  post:
    tags:
      - AI
    summary: Fetch full post details for multiple posts by their IDs
    description: |
      Retrieves complete post information for a batch of posts identified by
      their author/permlink pairs. This endpoint is designed to work with the
      new paging model where search results return mostly stub entries, and
      clients fetch full details as needed for display.

      Key features:
      - Accepts up to 50 post identifiers in a single request
      - Returns posts in the same order as requested
      - Supports body truncation for preview mode
      - Respects observer mute lists and blacklists
      - Returns null for non-existent posts while preserving order

      This endpoint is typically used after calling /posts/search or
      /posts/{author}/{permlink}/similar, which return full data for only
      the first N posts. When the user scrolls or pages through results,
      the client calls this endpoint with the next batch of author/permlink
      pairs to get their full details.

      Example workflow:
      1. Call /posts/search with result_limit=1000, full_posts=10
      2. Display first 10 posts immediately (already have full data)
      3. When user scrolls to post 11, call this endpoint with posts 11-20
      4. Continue fetching batches as user scrolls

    operationId: hivesense_endpoints.posts_by_ids
    requestBody:
      required: true
      content:
        application/json:
          schema:
            type: object
            required:
              - posts
            properties:
              posts:
                type: array
                description: |
                  Array of post identifiers. Each item must have both 'author' 
                  and 'permlink' fields. Maximum 50 posts per request.
                minItems: 1
                maxItems: 50
                items:
                  type: object
                  required:
                    - author
                    - permlink
                  properties:
                    author:
                      type: string
                      description: The Hive username of the post author
                    permlink:
                      type: string
                      description: The unique permlink identifier of the post
                example:
                  - author: "bue-witness"
                    permlink: "my-first-post"
                  - author: "another-user"
                    permlink: "interesting-topic"
              truncate:
                type: integer
                minimum: 0
                maximum: 65535
                default: 0
                description: |
                  Body truncation length. 0 returns full content, positive values
                  truncate to N characters. Useful for preview mode.
              observer:
                type: string
                default: ''
                description: |
                  Optional Hive account whose mute lists and blacklists will be
                  applied to filter results. Leave empty to disable filtering.
    responses:
      '200':
        description: |
          JSON array of post objects in the same order as requested.
          Non-existent posts are returned as null to preserve array indices.
        content:
          application/json:
            schema:
              type: string
              x-sql-datatype: JSON
            example: {}
      '400':
        description: Invalid request (e.g., too many posts, invalid format)
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.posts_by_ids;
CREATE OR REPLACE FUNCTION hivesense_endpoints.posts_by_ids(
    body JSON
)
RETURNS JSON
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    __observer_id INT := 0;
    __result JSON;
    __posts JSON;
    __truncate INT;
    __observer TEXT;
    __post_count INT;
BEGIN
    /* Extract parameters from JSON body */
    __posts := body->'posts';
    __truncate := COALESCE((body->>'truncate')::INT, 0);
    __observer := COALESCE(body->>'observer', '');
    
    /* Validate posts array */
    IF __posts IS NULL OR jsonb_typeof(__posts::jsonb) != 'array' THEN
        RAISE EXCEPTION 'posts parameter must be an array';
    END IF;
    
    __post_count := jsonb_array_length(__posts::jsonb);
    
    IF __post_count < 1 THEN
        RAISE EXCEPTION 'posts array must contain at least one item';
    END IF;
    
    IF __post_count > 50 THEN
        RAISE EXCEPTION 'posts array cannot contain more than 50 items (got %)', __post_count;
    END IF;
    
    /* Resolve observer account */
    IF __observer <> '' THEN
        __observer_id := hivemind_postgrest_utilities.find_account_id(
            hivemind_postgrest_utilities.valid_account(__observer),
            TRUE
        );
    END IF;
    
    /* Build result array maintaining order */
    WITH post_ids AS (
        SELECT 
            ordinality,
            post_data->>'author' AS author,
            post_data->>'permlink' AS permlink
        FROM jsonb_array_elements(__posts::jsonb) WITH ORDINALITY AS post_data
    ),
    resolved_ids AS (
        SELECT
            pi.ordinality,
            pi.author,
            pi.permlink,
            hivemind_app.find_comment_id(pi.author, pi.permlink, FALSE) AS post_id
        FROM post_ids pi
    ),
    full_posts AS (
        SELECT
            ri.ordinality,
            CASE 
                WHEN ri.post_id IS NOT NULL THEN
                    hivemind_postgrest_utilities.create_bridge_post_object(
                        __observer_id,
                        fpv,
                        __truncate,
                        NULL,
                        fpv.is_pinned,
                        TRUE
                    )
                ELSE
                    NULL::JSON
            END AS post_obj
        FROM resolved_ids ri
        LEFT JOIN LATERAL (
            SELECT fv.*, fv.source AS blacklists
            FROM hivemind_app.get_full_post_view_by_id(ri.post_id, __observer_id) fv
        ) fpv ON ri.post_id IS NOT NULL
    )
    SELECT jsonb_agg(post_obj ORDER BY ordinality)
    INTO __result
    FROM full_posts;
    
    RETURN COALESCE(__result, '[]'::JSON);
END;
$$;

-- Alternative GET endpoint accepting query parameters
-- This provides compatibility with REST clients that prefer GET requests
/** openapi:paths
/posts/by-ids-query:
  get:
    tags:
      - AI
    summary: Fetch full post details for multiple posts (GET variant)
    description: |
      GET variant of /posts/by-ids that accepts post identifiers as query
      parameters. Limited to fetching fewer posts due to URL length constraints.
      
      For larger batches, use the POST /posts/by-ids endpoint instead.
      
      The posts parameter should be a URL-encoded JSON array.
      
      Example:
      GET /posts/by-ids-query?posts=[{"author":"user1","permlink":"post1"}]&truncate=500
      
    operationId: hivesense_endpoints.posts_by_ids_query
    parameters:
      - in: query
        name: posts
        required: true
        schema:
          type: string
        description: |
          URL-encoded JSON array of post identifiers. Each object must have
          'author' and 'permlink' fields. Maximum 10 posts for GET requests.
        example: '[{"author":"bue-witness","permlink":"my-post"}]'
      - in: query
        name: truncate
        required: false
        schema:
          type: integer
          minimum: 0
          maximum: 65535
          default: 0
        description: Body truncation length (0 = full content)
      - in: query
        name: observer
        required: false
        schema:
          type: string
          default: ''
        description: Optional Hive account for filtering
    responses:
      '200':
        description: JSON array of post objects
        content:
          application/json:
            schema:
              type: string
              x-sql-datatype: JSON
            example: {}
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.posts_by_ids_query;
CREATE OR REPLACE FUNCTION hivesense_endpoints.posts_by_ids_query(
    posts TEXT,
    truncate INT = 0,
    observer TEXT = ''
)
RETURNS JSON
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    __body JSON;
    __result JSON;
BEGIN
    /* Parse the JSON string and validate */
    BEGIN
        __body := posts::JSON;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid JSON in posts parameter: %', SQLERRM;
    END;
    
    /* Limit GET requests to 10 posts for URL length safety */
    IF jsonb_array_length(__body::jsonb) > 10 THEN
        RAISE EXCEPTION 'GET endpoint limited to 10 posts. Use POST /posts/by-ids for larger batches';
    END IF;
    
    /* Construct body and delegate to main function */
    __body := jsonb_build_object(
        'posts', __body,
        'truncate', truncate,
        'observer', observer
    );
    
    __result := hivesense_endpoints.posts_by_ids(__body);
    
    RETURN __result;
END;
$$;

RESET ROLE;
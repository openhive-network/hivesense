SET ROLE hivesense_owner;

DROP TYPE IF EXISTS similar_post_result CASCADE;
CREATE TYPE similar_post_result AS (
    similarity_order INT,
    post_id INT
);

DROP FUNCTION IF EXISTS find_nearest_posts_with_embedding;
CREATE OR REPLACE FUNCTION find_nearest_posts_with_embedding(
    _embedding          vector,
    _limit              int     DEFAULT 1,
    _exclude_post_id    int     DEFAULT NULL,
    _observer_id        int     DEFAULT 0,
    _start_post_id      int     DEFAULT 0
)
RETURNS SETOF similar_post_result
LANGUAGE plpgsql STABLE PARALLEL SAFE AS
$$
DECLARE
    __total_limit INT := 3000; -- because there are max 3 chunks per post we are sure to  check min. 1000 posts
    dist_clause   text := hivesense_app.distance_clause(6);  -- $6 below
BEGIN
    PERFORM set_config('ivfflat.probes', '4',  true);
    PERFORM set_config('hnsw.ef_search', '1000', true);

    RETURN QUERY EXECUTE format($q$
        WITH similar_posts AS MATERIALIZED (
            SELECT hpv.post_id,
                   %s AS similarity                -- << distance here
            FROM   hivesense_app.posts_vectors hpv
            ORDER  BY similarity
            LIMIT  $1                              -- __total_limit
        ),
        unique_posts AS (
            SELECT DISTINCT ON (post_id) post_id, similarity
            FROM   similar_posts
            ORDER  BY post_id, similarity
        ),
        not_muted_posts AS (
            SELECT up.post_id, up.similarity
            FROM   unique_posts up
                   JOIN hivemind_app.hive_posts hp ON hp.id = up.post_id
            WHERE  ($3 = 0 OR NOT EXISTS (
                     SELECT 1
                     FROM   hivemind_app.muted_accounts_by_id_view
                     WHERE  observer_id = $3 AND muted_id = hp.author_id))
              AND  ($2 IS NULL OR $2 <> up.post_id)
        ),
        ordered_posts AS (
            SELECT post_id,
                   ROW_NUMBER() OVER (ORDER BY similarity)::int AS similarity_order,
                   similarity
            FROM   not_muted_posts
        ),
        upper_bound AS (
            SELECT similarity_order AS from_order
            FROM   ordered_posts
            WHERE  post_id = $4
        )
        SELECT similarity_order, post_id
        FROM   ordered_posts
        WHERE  similarity_order >
               COALESCE((SELECT from_order FROM upper_bound),0)
        ORDER  BY similarity_order
        LIMIT  $5
    $q$, dist_clause)
    USING __total_limit,          -- $1
          _exclude_post_id,       -- $2
          _observer_id,           -- $3
          _start_post_id,         -- $4
          _limit,                 -- $5
          _embedding;             -- $6  (used in distance clause)
END;
$$;


DROP FUNCTION IF EXISTS find_nearest_posts;
CREATE FUNCTION find_nearest_posts(
    _query text,
    _limit integer DEFAULT 1,
    _observer_id int = 0,
    _start_post_id int = 0
)
RETURNS SETOF similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $BODY$
DECLARE
    __query_prefix TEXT;
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    SELECT query_prefix INTO __query_prefix FROM hivesense_app.hivesense_app_status WHERE id = 1;

    RETURN QUERY SELECT similarity_order, post_id FROM hivesense_app.find_nearest_posts_with_embedding(
           hivesense_app.hivesense_embed(__query_prefix || _query)
         , _limit
         , _observer_id => _observer_id
         , _start_post_id => _start_post_id
     );
END;
$BODY$;


DROP FUNCTION IF EXISTS find_nearest_posts_to_post;
CREATE FUNCTION find_nearest_posts_to_post(
    _author text,
    _permlink text,
    _limit integer DEFAULT 1,
    _observer_id int = 0
)
RETURNS SETOF similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $BODY$
DECLARE
    __post_id INT := hivemind_app.find_comment_id( _author, _permlink, True );
    __post_embedding public.vector;
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);

    SELECT embedding
    FROM hivesense_app.posts_vectors
    WHERE post_id = __post_id
    INTO __post_embedding;

    -- TODO(mickiewicz@syncad.com): maybe vectorize posts here ? but then we got two point of posts vectorization
    IF __post_embedding IS NULL THEN
        RAISE EXCEPTION 'Post @%/% is not vectorized yet or was discarded because is to short', _author, _permlink;
    END IF;

    RETURN QUERY SELECT similarity_order, post_id FROM hivesense_app.find_nearest_posts_with_embedding(
         __post_embedding
        , _limit
        , __post_id
        , _observer_id => _observer_id
        , _start_post_id => 0
    );
END;
$BODY$;

DROP TYPE IF EXISTS contributors_result CASCADE;
CREATE TYPE contributors_result AS (
   rank INT,
   author_id INT
);

CREATE OR REPLACE FUNCTION hivesense_app.find_thematic_contributors_with_embedding(
    _embedding vector, -- embedding for a thematic
    _limit integer DEFAULT 1,
    _observer_id integer DEFAULT 0)
    RETURNS SETOF hivesense_app.contributors_result
    LANGUAGE 'plpgsql'
    COST 100
    STABLE PARALLEL SAFE
    ROWS 1000

AS $BODY$
DECLARE
    __total_limit INT := 300000; -- because there are max 3 chunks per post we are sure to  check min. 100000 posts
    dist_clause   text := hivesense_app.distance_clause(4);   -- $4 below
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    PERFORM set_config('hnsw.ef_search', '1000', true);

    RETURN QUERY EXECUTE format($q$
        WITH similar_posts AS MATERIALIZED (
            SELECT hpv.post_id,
                   %s AS similarity
            FROM   hivesense_app.posts_vectors hpv
            ORDER  BY similarity
            LIMIT  $1
        ),
        unique_posts AS (
            SELECT DISTINCT ON (post_id) post_id, similarity
            FROM   similar_posts
            ORDER  BY post_id, similarity
        ),
        not_muted_posts AS (
            SELECT up.post_id, up.similarity, hp.author_id
            FROM   unique_posts up
                   JOIN hivemind_app.hive_posts hp ON hp.id = up.post_id
            WHERE  ($3 = 0 OR NOT EXISTS (
                     SELECT 1
                     FROM   hivemind_app.muted_accounts_by_id_view
                     WHERE  observer_id = $3 AND muted_id  = hp.author_id))
        ),
        ordered_posts AS (
            SELECT post_id,
                   author_id,
                   ROW_NUMBER() OVER (ORDER BY similarity)::int AS similarity_order,
                   similarity
            FROM   not_muted_posts
        ),
        authors_rank AS (
            SELECT author_id,
                   RANK() OVER (ORDER BY SUM(1.0 / sqrt(similarity_order)) DESC) AS author_rank
            FROM   ordered_posts
            GROUP  BY author_id
        )
        SELECT author_rank::int, author_id
        FROM   authors_rank
        ORDER  BY author_rank
        LIMIT  $2
    $q$, dist_clause)
    USING __total_limit,              -- $1
          _limit,                     -- $2
          _observer_id,               -- $3
          _embedding;                 -- $4  (distance clause)
END;
$BODY$;

RESET ROLE

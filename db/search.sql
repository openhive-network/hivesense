SET ROLE hivesense_owner;

DROP TYPE IF EXISTS similar_post_result CASCADE;
CREATE TYPE similar_post_result AS (
    similarity_order INT,
    post_id INT
);

DROP FUNCTION IF EXISTS find_nearest_posts_with_embedding;
CREATE FUNCTION find_nearest_posts_with_embedding(
    _embedding public.vector,
    _limit integer DEFAULT 1,
    _from_order int = 0,
    _exclude_post_id int = NULL,
    _observer_id int = 0
)
RETURNS SETOF similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $BODY$
DECLARE
    __total_limit INT = 3000; -- because there are max 3 chunks per post we are sure to  check min. 1000 posts
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    PERFORM set_config('ivfflat.probes', '4', true);
    PERFORM set_config('hnsw.ef_search', '1000', true);

    RETURN QUERY WITH similar_posts AS MATERIALIZED ( -- materialized to fore use index for searching among vectors
        SELECT
               hpv.post_id as post_id
             , embedding <=> _embedding AS similarity
        FROM posts_vectors hpv
        ORDER BY similarity ASC
        LIMIT __total_limit
    ), unique_posts AS (SELECT DISTINCT ON (post_id) po.post_id as post_id, po.similarity as similarity
                        FROM similar_posts po
                        ORDER BY po.post_id, po.similarity
    ), not_muted_posts AS (
        SELECT up.post_id, up.similarity
        FROM unique_posts up
        JOIN hivemind_app.hive_posts hp ON hp.id = up.post_id
        AND (
            _observer_id = 0
            OR NOT EXISTS (
               SELECT 1
               FROM hivemind_app.muted_accounts_by_id_view
               WHERE observer_id = _observer_id AND muted_id = hp.author_id
            )
        )
        AND ( _exclude_post_id IS NULL OR _exclude_post_id != up.post_id )
    ), ordered_posts AS (
        SELECT nmp.post_id
             , ROW_NUMBER() OVER (ORDER BY nmp.similarity)::INTEGER as similarity_order
             , nmp.similarity
        FROM not_muted_posts nmp
    )
    SELECT op.similarity_order, op.post_id as post_id
    FROM ordered_posts op
    WHERE op.similarity_order > _from_order
    ORDER BY op.similarity_order ASC
    LIMIT _limit;
END;
$BODY$;


DROP FUNCTION IF EXISTS find_nearest_posts;
CREATE FUNCTION find_nearest_posts(
    _query text,
    _limit integer DEFAULT 1,
    _from_order int = 0,
    _observer_id int = 0
)
RETURNS SETOF similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $BODY$
BEGIN

    RETURN QUERY SELECT similarity_order, post_id FROM find_nearest_posts_with_embedding(
             hivesense_embed(_query)
         , _limit
         , _from_order
         , _observer_id => _observer_id
     );
END;
$BODY$;


DROP FUNCTION IF EXISTS find_nearest_posts_to_post;
CREATE FUNCTION find_nearest_posts_to_post(
    _author text,
    _permlink text,
    _limit integer DEFAULT 1,
    _from_order int = 0,
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
    FROM posts_vectors
    WHERE post_id = __post_id
    INTO __post_embedding;

    -- TODO(mickiewicz@syncad.com): maybe vectorize posts here ? but then we got two point of posts vectorization
    IF __post_embedding IS NULL THEN
        RAISE EXCEPTION 'Post @%/% is not vectorized yet or was discarded because is to short', _author, _permlink;
    END IF;

    RETURN QUERY SELECT similarity_order, post_id FROM find_nearest_posts_with_embedding(
         __post_embedding
        , _limit
        , _from_order
        , __post_id
        , _observer_id => _observer_id
    );
END;
$BODY$;

RESET ROLE

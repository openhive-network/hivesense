SET ROLE hivesense_owner;

DROP TYPE IF EXISTS similar_post_result CASCADE;
CREATE TYPE similar_post_result AS (
      similarity_order INT
    , post_id INT
);

DROP FUNCTION IF EXISTS find_nearest_posts_with_embedding;
CREATE FUNCTION find_nearest_posts_with_embedding(
    _embedding public.vector,
    _limit integer DEFAULT 1,
    _from_order INT = 0,
    _exclude_post_id INT = NULL
)
    RETURNS SETOF similar_post_result
    LANGUAGE 'plpgsql'
    STABLE PARALLEL SAFE
AS $BODY$
DECLARE
    __total_limit INT = 50; -- no more than 50 of post can be returned
    -- TODO(mickiewicz@syncad.com): change limit for 1000 after first demo
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    PERFORM set_config('ivfflat.probes', '4', true);

    RETURN QUERY WITH similar_posts AS MATERIALIZED (
        SELECT
               hpv.post_id as post_id
             , ROW_NUMBER() OVER()::INTEGER as similarity_order
             , embedding <=> _embedding AS similarity
        FROM posts_vectors hpv
        WHERE _exclude_post_id IS NULL OR  hpv.post_id != _exclude_post_id
        ORDER BY similarity ASC
        LIMIT __total_limit
    )
                 SELECT po.similarity_order, po.post_id as post_id
                 FROM similar_posts po
                 WHERE po.similarity_order > _from_order
                 ORDER BY po.similarity_order ASC
                 LIMIT _limit;
END;
$BODY$;


DROP FUNCTION IF EXISTS find_nearest_posts;
CREATE FUNCTION find_nearest_posts(
    _query text,
    _limit integer DEFAULT 1,
    _from_order INT = 0
)
    RETURNS SETOF similar_post_result
    LANGUAGE 'plpgsql'
    STABLE PARALLEL SAFE
AS $BODY$
BEGIN

    RETURN QUERY SELECT similarity_order, post_id FROM find_nearest_posts_with_embedding(
             hivesense_embed(_query)
         , _limit
         , _from_order
     );
END;
$BODY$;


DROP FUNCTION IF EXISTS find_nearest_posts_to_post;
CREATE FUNCTION find_nearest_posts_to_post(
    _author text,
    _permlink text,
    _limit integer DEFAULT 1,
    _from_order INT = 0
)
    RETURNS SETOF similar_post_result
    LANGUAGE 'plpgsql'
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
    );
END;
$BODY$;

RESET ROLE


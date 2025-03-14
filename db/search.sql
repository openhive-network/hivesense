SET ROLE hivesense_owner;

DROP TYPE IF EXISTS similar_post_result CASCADE;
CREATE TYPE similar_post_result AS (
      similarity_order INT
    , post_id INT
);

DROP FUNCTION IF EXISTS find_nearest_posts;
CREATE FUNCTION hivesense_app.find_nearest_posts(
    _query text,
    _limit integer DEFAULT 1,
    _from_order INT = 0
)
    RETURNS SETOF similar_post_result
    LANGUAGE 'plpgsql'
    STABLE PARALLEL SAFE
AS $BODY$
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);

    RETURN QUERY WITH similar_posts AS (
        SELECT
               hpv.post_id as post_id
             , embedding <=> hivesense_embed(_query) AS similarity
        FROM posts_vectors hpv
    ), posts_order AS (
        SELECT
               ROW_NUMBER() OVER(ORDER BY sp.similarity ASC )::INTEGER as similarity_order
             , sp.post_id
        FROM similar_posts sp
        ORDER BY sp.similarity ASC
    )
    SELECT po.similarity_order, po.post_id as post_id
    FROM posts_order po
    WHERE po.similarity_order > _from_order
    ORDER BY po.similarity_order ASC
    LIMIT _limit;
END;
$BODY$;

RESET ROLE


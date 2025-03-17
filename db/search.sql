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
DECLARE
    __total_limit INT = 1000; -- no more than 1000 of post can be returned
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    PERFORM set_config('ivfflat.probes', '8', true);

    RETURN QUERY WITH similar_posts AS MATERIALIZED (
        SELECT
               hpv.post_id as post_id
             , ROW_NUMBER() OVER()::INTEGER as similarity_order
             , embedding <=> hivesense_embed(_query) AS similarity
        FROM posts_vectors hpv
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

RESET ROLE


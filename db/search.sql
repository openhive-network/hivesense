SET ROLE hivesense_owner;


DROP TYPE IF EXISTS similar_post_result CASCADE;
CREATE TYPE similar_post_result AS (
                                       similarity_order INT
    , post_id INT
                                   );

DROP FUNCTION IF EXISTS find_nearest_posts;
CREATE FUNCTION hivesense_app.find_nearest_posts(
    _query text,
    _limit integer DEFAULT 1)
    RETURNS SETOF similar_post_result
    LANGUAGE 'plpgsql'
    STABLE PARALLEL SAFE
AS $BODY$
DECLARE
    __llm TEXT;
    __ollama_host TEXT;
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);

    SELECT llm, ollama FROM hivesense_app_status INTO __llm, __ollama_host;

    RETURN QUERY WITH similar_posts AS (
        SELECT hpv.post_id, embedding <=> hivesense_embed(_query) AS similarity
        FROM posts_vectors hpv
        ORDER BY similarity ASC
        LIMIT _limit
    )
                 SELECT ROW_NUMBER() OVER()::INTEGER as similarity_order
                      , sp.post_id as post_id
                 FROM similar_posts sp;
END;
$BODY$;

RESET ROLE


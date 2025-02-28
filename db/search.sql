SET ROLE hivesense_owner;


CREATE OR REPLACE FUNCTION find_nearest_post(_query TEXT)
    RETURNS INT
    LANGUAGE 'plpgsql'
    STABLE
AS
$FUN$
DECLARE
    __result INT;
    __llm TEXT;
    __ollama_host TEXT;
BEGIN
    SELECT llm, ollama FROM hivesense_app_status INTO __llm, __ollama_host;
    SELECT hpv.post_id, embedding <=> ai.ollama_embed(
            __llm,
            _query,
            host => __ollama_host) AS similarity
    FROM posts_vectors hpv
    ORDER BY similarity ASC
    LIMIT 1 INTO __result;

    ASSERT __result IS NOT NULL, 'Asking not filled vectors';

    RETURN __result;
END;
$FUN$;


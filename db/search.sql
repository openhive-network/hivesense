SET ROLE hivesense_owner;

DROP TYPE IF EXISTS similar_post_result CASCADE;
CREATE TYPE similar_post_result AS (
    similarity_order INT,
    post_id INT
);

DROP FUNCTION IF EXISTS find_nearest_posts_with_embedding;
CREATE OR REPLACE FUNCTION hivesense_app.find_nearest_posts_with_embedding(
  _embedding       vector,
  _limit           int     DEFAULT 10,
  _exclude_post_id int     DEFAULT NULL,
  _observer_id     int     DEFAULT 0,
  _start_post_id   int     DEFAULT 0
)
RETURNS SETOF similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    -- Build the distance expression against $1 (our _embedding)
    dist_clause   text := hivesense_app.distance_clause(1);
    rec           RECORD;
    -- track which post_ids we’ve already returned
    seen_ids      int[] := ARRAY[]::int[];
    -- how many DISTINCT posts we’ve returned so far
    count_posts   int   := 0;
    -- we stop once we’ve hit either _limit or 1000, whichever is smaller
    max_posts     int   := LEAST(_limit, 1000);
    -- if _start_post_id=0 we collect immediately; otherwise skip until we see it
    collecting    bool  := (_start_post_id = 0);
    batch_size    int   := GREATEST(_limit * 5, 50);  -- start with 5×
    sql           text;
BEGIN
    -- tune pgvector index parameters
    PERFORM set_config('ivfflat.probes', '4',    true);
    PERFORM set_config('hnsw.ef_search',    '1000', true);

    LOOP
        sql := format($q$
            SELECT hpv.post_id, %s AS similarity
              FROM hivesense_app.posts_vectors hpv
              JOIN hivemind_app.hive_posts hp
                ON hp.id = hpv.post_id
             WHERE ($2 IS NULL OR hpv.post_id <> $2)
               AND ($3 = 0 OR NOT EXISTS (
                     SELECT 1
                       FROM hivemind_app.muted_accounts_by_id_view m
                      WHERE m.observer_id = $3
                        AND m.muted_id    = hp.author_id
                   ))
             ORDER BY similarity
             LIMIT %s
        $q$, dist_clause, batch_size);

        FOR rec IN EXECUTE sql
            USING _embedding, _exclude_post_id, _observer_id
        LOOP
            -- handle start_post_id: skip everything until we see that post_id
            IF NOT collecting THEN
                IF rec.post_id = _start_post_id THEN
                    collecting := true;
                END IF;
                CONTINUE;
            END IF;
            -- never return the start_post_id itself
            IF rec.post_id = _start_post_id THEN
                CONTINUE;
            END IF;
            -- skip duplicates
            IF rec.post_id = ANY(seen_ids) THEN
                CONTINUE;
            END IF;

            -- emit this post
            seen_ids      := array_append(seen_ids, rec.post_id);
            count_posts   := count_posts + 1;
            RETURN NEXT (count_posts, rec.post_id)::hivesense_app.similar_post_result;

            -- stop once we’ve emitted enough
            EXIT WHEN count_posts >= max_posts;
        END LOOP;

        EXIT WHEN count_posts >= max_posts;

        -- if we ran out of rows (batch too small), double it and try again
        batch_size := batch_size * 2;
    END LOOP;
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

    SELECT CASE
             WHEN hivesense_app.store_halfvec_embeddings()
                  THEN embedding::public.vector
             ELSE embedding
           END
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
    _embedding   vector,      -- embedding for a thematic
    _limit       integer DEFAULT 1,
    _observer_id integer DEFAULT 0
)
RETURNS SETOF hivesense_app.contributors_result
LANGUAGE plpgsql
COST 100
STABLE
PARALLEL SAFE
ROWS 1000
AS $BODY$
DECLARE
    __max_embedding_limit INT    := 300000;
    dist_clause           TEXT   := hivesense_app.distance_clause(1);
    rec                   RECORD;
    recs_seen             INT    := 0;
    author_ids            INT[]  := ARRAY[]::INT[];
    authors_found         INT    := 0;
    contributor_rank      INT;
    batch_size            INT    := GREATEST(_limit * 5, 50);
BEGIN
    -- ensure we can see both schemas
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    -- tune pgvector search
    PERFORM set_config('hnsw.ef_search', '1000', true);

    LOOP
        FOR rec IN
            EXECUTE format($qry$
                SELECT
                    hpv.post_id,
                    hp.author_id,
                    %s AS similarity
                FROM   hivesense_app.posts_vectors hpv
                JOIN   hivemind_app.hive_posts hp
                  ON hp.id = hpv.post_id
                WHERE  ($2 = 0 OR NOT EXISTS (
                           SELECT 1
                             FROM hivemind_app.muted_accounts_by_id_view m
                            WHERE m.observer_id = $2
                              AND m.muted_id    = hp.author_id
                       ))
                ORDER  BY similarity
                LIMIT %s
            $qry$, dist_clause, batch_size)
        USING _embedding, _observer_id
        LOOP
            recs_seen := recs_seen + 1;
            -- stop if we've looked at too many embeddings or found enough authors
            EXIT WHEN recs_seen >= __max_embedding_limit
                     OR authors_found >= _limit;

            -- skip authors we've already returned
            IF rec.author_id = ANY(author_ids) THEN
                CONTINUE;
            END IF;

            -- new author!
            authors_found    := authors_found + 1;
            contributor_rank := authors_found;
            author_ids       := array_append(author_ids, rec.author_id);

            RETURN NEXT ROW(contributor_rank, rec.author_id);
        END LOOP;

        EXIT WHEN authors_found >= _limit;

        -- increase batch size and try again
        batch_size := LEAST(batch_size * 2, __max_embedding_limit);
    END LOOP;
END;
$BODY$;

RESET ROLE

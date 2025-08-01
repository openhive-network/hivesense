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
    _num_tokens   int;
    -- track which post_ids we’ve already returned
    seen_ids      int[] := ARRAY[]::int[];
    -- how many DISTINCT posts we’ve returned so far
    count_posts   int   := 0;
    -- we stop once we’ve hit either _limit or 1000, whichever is smaller
    max_posts     int   := LEAST(_limit, 1000);
    -- if _start_post_id=0 we collect immediately; otherwise skip until we see it
    collecting    bool  := (_start_post_id = 0);

    -- pull headers and defaults
    req_headers        json;
    batch_multiplier   int   := 5;     -- default multiplier
    exploratory_factor int   := 1000;  -- default ef_search

    -- batch size will be set in BEGIN
    batch_size         int;
    sql                text;
    __min_search_tokens int;

    use_reduced boolean := hivesense_app.use_reduced_embeddings();
    tgt_table   text    := CASE WHEN use_reduced
                                THEN 'hivesense_app.posts_vectors_reduced'
                                ELSE 'hivesense_app.posts_vectors'
                           END;
    tgt_column  text    := CASE WHEN use_reduced
                                THEN 'reduced_embedding'
                                ELSE 'embedding'
                           END;
    -- when reduced, we’ll keep ANN distance in a CTE column “d” (float4)
    prv_clause  text;   -- prepared ORDER BY clause
BEGIN
    -- grab the incoming headers JSON (if any)
    SELECT current_setting('request.headers', true)::json
      INTO req_headers;

    -- override defaults if headers are present
    batch_multiplier := COALESCE(
        (req_headers->>'x-batch-size-multiplier')::int,
        batch_multiplier
    );
    exploratory_factor := COALESCE(
        (req_headers->>'x-exploratory-factor')::int,
        exploratory_factor
    );

    -- initialize batch_size using the (possibly overridden) multiplier
    batch_size := GREATEST(_limit * batch_multiplier, 50);

    -- tune pgvector index parameters
    PERFORM set_config('ivfflat.probes',    '4',                        true);
    PERFORM set_config('hnsw.ef_search',    exploratory_factor::text,   true);

    SELECT min_token_search_threshold
      INTO __min_search_tokens
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    RAISE NOTICE 'In find_nearest_posts_with_embedding(vec, %, %, %, %)', _limit, _exclude_post_id, _observer_id, _start_post_id;
    
    /* ------------------------------------------------------------
     * Compose column list for ANN search
     * -----------------------------------------------------------*/
    IF use_reduced THEN
        -- ANN on reduced_embedding; we’ll later JOIN to full table for rerank
        prv_clause := format('%I <#> $1', tgt_column);   -- distance on reduced
    ELSE
        prv_clause := dist_clause;                       -- existing helper (full)
    END IF;

    LOOP
        RAISE NOTICE 'Getting % posts (batch_size: %)', batch_size, batch_size;
        sql := format($q$
            WITH ann AS (
                SELECT hpv.post_id,
                       %s AS d
                  FROM %s hpv
                  JOIN hivemind_app.hive_posts hp ON hp.id = hpv.post_id
             WHERE ($2 IS NULL OR hpv.post_id <> $2)
               AND ($3 = 0 OR NOT EXISTS (
                     SELECT 1
                       FROM hivemind_app.muted_accounts_by_id_view m
                      WHERE m.observer_id = $3
                        AND m.muted_id    = hp.author_id
                   ))
                ORDER BY d, hpv.post_id
                LIMIT %s
            )
            SELECT ann.post_id,
                   CASE
                       WHEN %L THEN  -- use_reduced?  (passed as literal)
                         -- compute **true** cosine distance with full embedding
                         (pv.embedding <=> $1)::float4
                       ELSE ann.d
                   END AS similarity
            FROM ann
            JOIN hivesense_app.posts_vectors pv
              ON pv.post_id = ann.post_id
        $q$,
          prv_clause,               -- %s 1
          tgt_table,                -- %s 2
          batch_size,               -- %s 3
          use_reduced               -- %L literal
        );

        FOR rec IN EXECUTE sql
            USING _embedding, _exclude_post_id, _observer_id
        LOOP
            -- global duplicate filter
            IF rec.post_id = ANY(seen_ids) THEN
                CONTINUE;
            END IF;
            -- mark as seen
            seen_ids := array_append(seen_ids, rec.post_id);

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

            -- skip posts below the token threshold
            IF __min_search_tokens > 0 THEN
              SELECT number_of_tokens
                INTO _num_tokens
                FROM hivesense_app.post_data
               WHERE post_id = rec.post_id;
              IF _num_tokens < __min_search_tokens THEN
                CONTINUE;
              END IF;
            END IF;

            -- emit this post
            count_posts   := count_posts + 1;
            RAISE NOTICE 'Adding post with similarity %', rec.similarity;
            RETURN NEXT (count_posts, rec.post_id)::hivesense_app.similar_post_result;

            -- stop once we’ve emitted enough
            EXIT WHEN count_posts >= max_posts;
        END LOOP;

        EXIT WHEN count_posts >= max_posts;

        -- if we ran out of rows (batch too small), double it and try again
        batch_size := batch_size * 2;
        RAISE NOTICE 'Doubling batch size to %, count_posts is %, still less than max_posts %', batch_size, count_posts, max_posts;
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
    _num_tokens           INT;
    recs_seen             INT    := 0;
    author_ids            INT[]  := ARRAY[]::INT[];
    authors_found         INT    := 0;
    contributor_rank      INT;
    batch_size            INT    := GREATEST(_limit * 5, 50);
    __min_search_tokens   INT;
BEGIN
    -- ensure we can see both schemas
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    -- tune pgvector search
    PERFORM set_config('hnsw.ef_search', '1000', true);

    SELECT min_token_search_threshold
      INTO __min_search_tokens
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    LOOP
        FOR rec IN
            EXECUTE format($qry$
                SELECT
                    hpv.post_id,
                    hp.author_id,
                    %s AS similarity
                FROM   hivesense_app.posts_vectors hpv
                JOIN   hivemind_app.hive_posts hp ON hp.id = hpv.post_id
                WHERE  ($2 = 0 OR NOT EXISTS (
                           SELECT 1
                             FROM hivemind_app.muted_accounts_by_id_view m
                            WHERE m.observer_id = $2
                              AND m.muted_id    = hp.author_id
                       ))
                ORDER  BY similarity, hpv.post_id
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

            -- skip posts below the token threshold
            IF __min_search_tokens > 0 THEN
              SELECT number_of_tokens
                INTO _num_tokens
                FROM hivesense_app.post_data
               WHERE post_id = rec.post_id;
              IF _num_tokens < __min_search_tokens THEN
                CONTINUE;
              END IF;
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

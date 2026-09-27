SET ROLE hivesense_owner;

DROP TYPE IF EXISTS hivesense_app.similar_post_result CASCADE;
CREATE TYPE hivesense_app.similar_post_result AS (
    similarity_order INT,     -- 1-based rank
    similarity       REAL,    -- cosine distance (smaller = closer)
    post_id          INT,
    chunk_number     INT      -- chunk with best similarity
);

/* ────────────────────────────────────────────────────────────────
 * 1.  ANN sizing and candidate filters shared by the searches
 * ────────────────────────────────────────────────────────────────
 * hnsw.ef_search = clamp(_limit * ef_multiplier, ef_floor, ef_ceiling),
 * and the ANN candidate LIMIT is ef_search: with hnsw.iterative_scan off
 * the index returns at most ef_search rows, so a larger LIMIT never binds.
 *
 * Defaults (floor 60, multiplier 10, ceiling 500) from steem-16, 2026-10-28:
 * jina-embeddings-v5-text-small, 1024-dim halfvec, 128-dim Matryoshka slice
 * HNSW (m=16, ef_construction=200), full-vector rerank; 24 posts spread
 * across posts_vectors against their exact brute-force top-50. Buffers per
 * call measured with EXPLAIN (ANALYZE, BUFFERS) on hbt5.
 *
 *   ef_search  recall@10  recall@20  top-1 same  +mean cos dist of top-10  buffers/call
 *   1000       0.988      0.973      24/24       0.0001                    ~40,000
 *    500       0.979      0.950      24/24       0.0003                     20,500
 *    200       0.933      0.900      23/24       0.0011                      9,000
 *    100       0.896      0.838      23/24       0.0023                      4,800
 *     60       0.821      0.752      23/24       0.0046
 *     40       0.771      0.675      22/24       0.0187
 *
 * The exact top-1/top-10/top-50 sit at mean cosine distance 0.164/0.265/0.322,
 * so neighbours swapped in at ef 60-200 are invisible to a reader; ef 40 is
 * where results get visibly worse. Rank of the exact top-10 in the 128-dim
 * candidate ordering: median 8, p90 103, p99 522, max 669, 1.2% beyond 1,000;
 * the slice ordering, not HNSW, is what needs the wide pool on large limits.
 * Result: result_limit 3 -> ef 60, 10 -> 100, 20 -> 200, >= 50 -> 500.
 */
CREATE OR REPLACE FUNCTION hivesense_app.ann_search_size(
    _limit             int,
    OUT ef_search      int,
    OUT ann_candidates int
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    allow_dbg   boolean := hivesense_app.allow_debugging();
    req_headers jsonb   := current_setting('request.headers', true)::jsonb;
    __floor      int;
    __multiplier int;
    __ceiling    int;
BEGIN
    SELECT ef_floor, ef_multiplier, ef_ceiling
      INTO __floor, __multiplier, __ceiling
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    IF allow_dbg THEN
        __multiplier := COALESCE((req_headers->>'x-batch-size-multiplier')::int, __multiplier);
    END IF;

    ef_search := LEAST(GREATEST(_limit * __multiplier, __floor), __ceiling);

    IF allow_dbg THEN
        ef_search := COALESCE((req_headers->>'x-exploratory-factor')::int, ef_search);
    END IF;

    ann_candidates := ef_search;
    IF allow_dbg THEN
        ann_candidates := LEAST(COALESCE((req_headers->>'x-ann-candidates')::int, ef_search), ef_search);
    END IF;
END;
$$;

/* WHERE-clause fragment (starting with AND) restricting the ANN candidates
 * of table alias _alias. Every search probes hive_posts once per candidate to
 * skip deleted posts: a deleted post keeps its embeddings, but hivemind's
 * full-post view returns no row for it, so one ranked into /posts/search's
 * full_posts slots was silently dropped (fewer full objects than requested)
 * while one ranked lower came back as a bare author/permlink stub. The
 * observer's mute check rides on that same probe, and the post_data lookup is
 * only added when a token threshold can remove a row. */
CREATE OR REPLACE FUNCTION hivesense_app.ann_candidate_filter(
    _alias           text,
    _exclude_post_id int,
    _observer_id     int
)
RETURNS text
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    __min_tokens int;
    __filter     text := '';
BEGIN
    SELECT min_token_search_threshold
      INTO __min_tokens
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    IF __min_tokens > 0 THEN
        __filter := __filter || format(
          ' AND EXISTS (SELECT 1 FROM hivesense_app.post_data pd'
          ' WHERE pd.post_id = %1$I.post_id AND pd.number_of_tokens >= %2$s)',
          _alias, __min_tokens);
    END IF;

    IF _exclude_post_id IS NOT NULL THEN
        __filter := __filter || format(' AND %I.post_id <> %s', _alias, _exclude_post_id);
    END IF;

    IF _observer_id <> 0 AND EXISTS (
           SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
            WHERE m.observer_id = _observer_id) THEN
        __filter := __filter || format(
          ' AND EXISTS (SELECT 1 FROM hivemind_app.hive_posts hp'
          ' WHERE hp.id = %1$I.post_id AND hp.counter_deleted = 0'
          ' AND NOT EXISTS (SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m'
          ' WHERE m.observer_id = %2$s AND m.muted_id = hp.author_id))',
          _alias, _observer_id);
    ELSE
        __filter := __filter || format(
          ' AND EXISTS (SELECT 1 FROM hivemind_app.hive_posts hp'
          ' WHERE hp.id = %1$I.post_id AND hp.counter_deleted = 0)',
          _alias);
    END IF;

    RETURN __filter;
END;
$$;

/* ────────────────────────────────────────────────────────────────
 * 2.  One-shot nearest-posts function
 * ────────────────────────────────────────────────────────────────*/
CREATE OR REPLACE FUNCTION hivesense_app.find_nearest_posts_with_embedding_one_shot(
    _embedding       public.vector,      -- full-size query embedding (768-d)
    _limit           int     DEFAULT 1000,
    _exclude_post_id int     DEFAULT NULL,
    _observer_id     int     DEFAULT 0
)
RETURNS SETOF hivesense_app.similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    /* ───────── flags & dims ───────── */
    use_reduced   boolean := hivesense_app.use_reduced_embeddings();
    red_mode      text    := hivesense_app.reduction_mode();
    store_half    boolean := hivesense_app.store_halfvec_embeddings();
    half_index    boolean := hivesense_app.use_halfvec_index();

    full_dim int := hivesense_app.embedding_dims();
    red_dim  int := hivesense_app.reduced_dims();

    query_red public.vector;          -- reduced query when needed

    /* ───────── distance clauses ───────── */
    dist_full text := hivesense_app.distance_clause(1);    -- uses $1
    dist_red  text;                                        -- uses $2 when reduced

    /* ───────── runtime tunables ───────── */
    allow_dbg    boolean := hivesense_app.allow_debugging();
    req_headers        jsonb := current_setting('request.headers', true)::jsonb;
    exploratory_factor int;             -- computed below
    ann_candidates     int;             -- computed below
    exhaustive boolean := false;

    /* ───────── misc ───────── */
    __min_tokens int;

    /* ------ for exhaustive ------ */
    post_ids      int[];    -- candidate post_ids
    chunk_numbers int[];    -- their chunk_numbers
    sims          real[];   -- their similarity scores
BEGIN
    /* — clamp limit to 1000 — */
    _limit := LEAST(GREATEST(_limit,1), 1000);


    /* ─── detect debug headers ─── */
    IF NOT allow_dbg AND (
           req_headers ? 'x-batch-size-multiplier' OR
           req_headers ? 'x-exploratory-factor' OR
           req_headers ? 'x-ann-candidates' OR
           req_headers ? 'x-exhaustive-search'
       ) THEN
        RAISE EXCEPTION 'Debugging headers are disabled on this server'
              USING ERRCODE = '42504';  -- insufficient_privilege (4xx style)
    END IF;

    /* ─── apply overrides only if allowed ─── */
    IF allow_dbg THEN
        exhaustive := lower(coalesce(req_headers->>'x-exhaustive-search','false')) = 'true';
    END IF;

    SELECT s.ef_search, s.ann_candidates
      INTO exploratory_factor, ann_candidates
      FROM hivesense_app.ann_search_size(_limit) s;


    /* — apply tunables — */
    PERFORM set_config('ivfflat.probes', '4', true);
    PERFORM set_config('hnsw.ef_search', exploratory_factor::text, true);

    /* — token threshold — */
    SELECT min_token_search_threshold
      INTO __min_tokens
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    /* — build reduced query vector & distance clause — */
    IF use_reduced AND red_mode = 'slice' THEN
        -- Matryoshka: truncate the query vector to reduced dims
        EXECUTE format('SELECT public.subvector($1, 1, %s)', red_dim)
          USING _embedding INTO query_red;
        -- Expression distance on posts_vectors.embedding truncated to reduced dims
        IF store_half THEN
            dist_red := format(
              'public.subvector(embedding, 1, %s)::public.halfvec(%s) <=> $2::public.halfvec(%s)', red_dim, red_dim, red_dim);
        ELSE
            dist_red := format(
              'public.subvector(embedding, 1, %s)::public.vector(%s) <=> $2', red_dim, red_dim);
        END IF;
    ELSIF use_reduced THEN
        query_red := hivesense_app.reduce_embedding(_embedding);

        IF store_half THEN
            dist_red := format(
              'reduced_embedding <=> $2::public.halfvec(%s)', red_dim);
        ELSIF half_index THEN
            dist_red := format(
              '(reduced_embedding::public.halfvec(%1$s)) <=> $2::public.halfvec(%1$s)',
              red_dim);
        ELSE
            dist_red := 'reduced_embedding <=> $2';
        END IF;
    END IF;

    /* ────────────────────────────────────────────────────────────
     *  MAIN one-shot query (three variants)
     *
     *  Every variant skips deleted posts: the ANN variants through
     *  ann_candidate_filter, the exhaustive one explicitly.
     * ────────────────────────────────────────────────────────────*/
    IF exhaustive THEN
        -- note: this branch is only used for benchmarking debugging
        -- and will be very slow (20s+)
        ----------------------------------------------------------------
        -- 1️⃣ Disable only vector index scans, enable parallel seqscans
        ----------------------------------------------------------------
        PERFORM set_config('enable_indexscan',      'off', TRUE);
        PERFORM set_config('enable_bitmapscan',     'off', TRUE);
        PERFORM set_config('enable_indexonlyscan',  'off', TRUE);
        PERFORM set_config('max_parallel_workers_per_gather', '4', TRUE);

        ----------------------------------------------------------------
        -- 2️⃣ Brute‐force gather top (limit×10) embeddings into arrays
        ----------------------------------------------------------------
        SELECT
          array_agg(b.post_id     ORDER BY b.sim),
          array_agg(b.chunk_number ORDER BY b.sim),
          array_agg(b.sim         ORDER BY b.sim)
        INTO post_ids, chunk_numbers, sims
        FROM (
          SELECT
            pv.post_id,
            pv.chunk_number,
            (pv.embedding <=> _embedding)::real AS sim
          FROM hivesense_app.posts_vectors pv
          ORDER  BY sim
          LIMIT LEAST(_limit * 10, 100000)
        ) AS b;

        ----------------------------------------------------------------
        -- 3️⃣ Re‐enable all index scans for the joins & filtering below
        ----------------------------------------------------------------
        PERFORM set_config('enable_indexscan',     'on', TRUE);
        PERFORM set_config('enable_bitmapscan',    'on', TRUE);
        PERFORM set_config('enable_indexonlyscan', 'on', TRUE);

        ----------------------------------------------------------------
        -- 4️⃣ Filter, DISTINCT‐ON, rank, and LIMIT to _limit
        ----------------------------------------------------------------
        RETURN QUERY
        WITH brute AS (
            SELECT
              post_ids[i]      AS post_id,
              chunk_numbers[i] AS chunk_number,
              sims[i]          AS sim
            FROM generate_subscripts(post_ids,1) AS s(i)
        ),
        filtered AS (
            SELECT b.post_id, b.chunk_number, b.sim
              FROM brute b
              JOIN hivemind_app.hive_posts      hp ON hp.id      = b.post_id
              JOIN hivesense_app.post_data      pd ON pd.post_id = b.post_id
             WHERE (__min_tokens = 0 OR pd.number_of_tokens >= __min_tokens)
               AND hp.counter_deleted = 0
               AND (_exclude_post_id IS NULL OR b.post_id <> _exclude_post_id)
               AND (_observer_id = 0 OR NOT EXISTS (
                     SELECT 1
                       FROM hivemind_app.muted_accounts_by_id_view m
                      WHERE m.observer_id = _observer_id
                        AND m.muted_id    = hp.author_id
                   ))
        ),
        best AS (
            SELECT DISTINCT ON (post_id)
              post_id,
              chunk_number,
              sim
            FROM filtered
            ORDER BY post_id, sim
        )
        SELECT
          (row_number() OVER (ORDER BY sim, post_id))::int AS similarity_order,
          sim        AS similarity,
          post_id,
          chunk_number
        FROM best
        ORDER BY sim, post_id
        LIMIT _limit;
	RETURN;
    ELSIF use_reduced AND red_mode = 'slice' THEN
        -- Matryoshka slicing: ANN on posts_vectors with expression distance, rerank with full embedding
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pv.post_id,
                       pv.chunk_number,
                       %s                           AS ann_dist
                  FROM hivesense_app.posts_vectors pv
                 WHERE TRUE%s
                 ORDER BY ann_dist, pv.post_id
                 LIMIT %s
            ),
            best_chunk AS (
                SELECT DISTINCT ON (pv.post_id)
                       pv.post_id,
                       pv.chunk_number,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM ann
                  JOIN hivesense_app.posts_vectors pv
                    ON pv.post_id     = ann.post_id
                   AND pv.chunk_number = ann.chunk_number
                 ORDER BY pv.post_id, sim
            )
            SELECT ((row_number() OVER (ORDER BY sim, post_id))::int) AS similarity_order,
                   sim::real AS similarity,
                   post_id,
                   chunk_number
              FROM best_chunk
             ORDER BY sim, post_id
             LIMIT %s
        $q$,
          dist_red,                     -- %s  ann distance expr (expression on embedding)
          hivesense_app.ann_candidate_filter('pv', _exclude_post_id, _observer_id),  -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red;

    ELSIF use_reduced THEN
        -- PCA: ANN on posts_vectors_reduced, rerank with full embedding
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pr.post_id,
                       pr.chunk_number,
                       %s                           AS ann_dist
                  FROM hivesense_app.posts_vectors_reduced pr
                 WHERE TRUE%s
                 ORDER BY ann_dist, pr.post_id
                 LIMIT %s
            ),
            best_chunk AS (
                SELECT DISTINCT ON (pv.post_id)
                       pv.post_id,
                       pv.chunk_number,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM ann
                  JOIN hivesense_app.posts_vectors pv
                    ON pv.post_id     = ann.post_id
                   AND pv.chunk_number = ann.chunk_number
                 ORDER BY pv.post_id, sim
            )
            SELECT ((row_number() OVER (ORDER BY sim, post_id))::int) AS similarity_order,
                   sim::real AS similarity,
                   post_id,
                   chunk_number
              FROM best_chunk
             ORDER BY sim, post_id
             LIMIT %s
        $q$,
          dist_red,                     -- %s  ann distance expr
          hivesense_app.ann_candidate_filter('pr', _exclude_post_id, _observer_id),  -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red;

    ELSE   /* ───────── full-vector path ───────── */
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pv.post_id,
                       pv.chunk_number,
                       %s                           AS sim
                  FROM hivesense_app.posts_vectors pv
                 WHERE TRUE%s
                 ORDER BY sim, pv.post_id
                 LIMIT %s
            ),
            best_chunk AS (
                SELECT DISTINCT ON (post_id)
                       post_id, chunk_number, sim
                  FROM ann
                 ORDER BY post_id, sim
            )
            SELECT ((row_number() OVER (ORDER BY sim, post_id))::int) AS similarity_order,
                   sim::real  AS similarity,
                   post_id,
                   chunk_number
              FROM best_chunk
             ORDER BY sim, post_id
             LIMIT %s
        $q$,
          dist_full,                  -- %s
          hivesense_app.ann_candidate_filter('pv', _exclude_post_id, _observer_id),  -- %s
          ann_candidates,             -- %s
          _limit                      -- %s
        )
        USING _embedding;

    END IF;
END;
$$;

DROP FUNCTION IF EXISTS hivesense_app.find_nearest_posts_with_embedding(public.vector, int, int, int, int);


/*───────────────────────────────────────────────────────────────*
 * Wrapper that embeds the query prefix and observer filtering   *
 *───────────────────────────────────────────────────────────────*/
DROP FUNCTION IF EXISTS hivesense_app.find_nearest_posts;
CREATE FUNCTION hivesense_app.find_nearest_posts(
    _query        text,
    _limit        int   DEFAULT 1000,
    _observer_id  int   DEFAULT 0
)
RETURNS SETOF hivesense_app.similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    __query_prefix text;
BEGIN
    -- ensure pgvector ops visible
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);

    SELECT query_prefix INTO __query_prefix
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    RETURN QUERY
      SELECT similarity_order, similarity, post_id, chunk_number
        FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(
               hivesense_app.hivesense_embed(__query_prefix || _query),
               _limit,
               _observer_id => _observer_id
           );
END;
$$;


DROP FUNCTION IF EXISTS hivesense_app.find_nearest_posts_to_post;
CREATE FUNCTION hivesense_app.find_nearest_posts_to_post(
    _author      text,
    _permlink    text,
    _limit       int  DEFAULT 1000,
    _observer_id int  DEFAULT 0
)
RETURNS SETOF hivesense_app.similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    __post_id        int;
    __post_embedding public.vector;
BEGIN
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);

    _limit := LEAST(GREATEST(_limit,1), 1000);  -- clamp

    -- resolve post ID & embedding
    __post_id := hivemind_app.find_comment_id(_author, _permlink, TRUE);

    SELECT CASE
             WHEN hivesense_app.store_halfvec_embeddings()
                  THEN embedding::public.vector
             ELSE embedding
           END
      INTO __post_embedding
      FROM hivesense_app.posts_vectors
     WHERE post_id = __post_id
     ORDER BY chunk_number
     LIMIT 1;

    -- Short and not-yet-processed posts have no embedding; that is a normal
    -- state, so answer with no similar posts rather than an error.
    IF __post_embedding IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
      SELECT similarity_order, similarity, post_id, chunk_number
        FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(
                 __post_embedding,
                 _limit,
                 _exclude_post_id => __post_id,
                 _observer_id     => _observer_id
             );
END;
$$;


DROP TYPE IF EXISTS contributors_result CASCADE;
CREATE TYPE contributors_result AS (
   rank INT,
   author_id INT,
   similarity REAL
);


CREATE OR REPLACE FUNCTION hivesense_app.find_thematic_contributors_with_embedding(
    _embedding   vector,      -- full-size query embedding
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
    /* ───────── flags & dims ───────── */
    use_reduced   boolean := hivesense_app.use_reduced_embeddings();
    red_mode      text    := hivesense_app.reduction_mode();
    store_half    boolean := hivesense_app.store_halfvec_embeddings();
    half_index    boolean := hivesense_app.use_halfvec_index();

    full_dim int := hivesense_app.embedding_dims();
    red_dim  int := hivesense_app.reduced_dims();

    query_red public.vector;          -- reduced query when needed

    /* ───────── distance clauses ───────── */
    dist_full text := hivesense_app.distance_clause(1);    -- uses $1
    dist_red  text;                                        -- uses $2 when reduced

    /* ───────── runtime tunables ───────── */
    allow_dbg    boolean := hivesense_app.allow_debugging();
    req_headers        jsonb := current_setting('request.headers', true)::jsonb;
    exploratory_factor int;             -- computed below
    ann_candidates     int;             -- computed below
    exhaustive boolean := false;

    /* ───────── author tracking ───────── */
    __max_embedding_limit INT    := 300000;
    author_scores  jsonb := '{}'::jsonb;  -- track best score per author
    authors_found  INT    := 0;
    __min_search_tokens   INT;

    /* ------ for exhaustive ------ */
    post_ids      int[];    -- candidate post_ids
    chunk_numbers int[];    -- their chunk_numbers
    sims          real[];   -- their similarity scores
    author_ids    int[];    -- their author_ids
BEGIN
    /* — ensure pgvector ops visible — */
    PERFORM set_config('search_path', current_setting('search_path') || ', public', TRUE);
    
    /* — clamp limit — */
    _limit := LEAST(GREATEST(_limit,1), 100);

    /* ─── detect debug headers ─── */
    IF NOT allow_dbg AND (
           req_headers ? 'x-batch-size-multiplier' OR
           req_headers ? 'x-exploratory-factor' OR
           req_headers ? 'x-ann-candidates' OR
           req_headers ? 'x-exhaustive-search'
       ) THEN
        RAISE EXCEPTION 'Debugging headers are disabled on this server'
              USING ERRCODE = '42504';  -- insufficient_privilege
    END IF;

    /* ─── apply overrides only if allowed ─── */
    IF allow_dbg THEN
        exhaustive := lower(coalesce(req_headers->>'x-exhaustive-search','false')) = 'true';
    END IF;

    SELECT s.ef_search, s.ann_candidates
      INTO exploratory_factor, ann_candidates
      FROM hivesense_app.ann_search_size(_limit) s;

    /* — apply tunables — */
    PERFORM set_config('ivfflat.probes', '4', true);
    PERFORM set_config('hnsw.ef_search', exploratory_factor::text, true);

    /* — token threshold — */
    SELECT min_token_search_threshold
      INTO __min_search_tokens
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    /* — build reduced query vector & distance clause — */
    IF use_reduced AND red_mode = 'slice' THEN
        -- Matryoshka: truncate the query vector to reduced dims
        EXECUTE format('SELECT public.subvector($1, 1, %s)', red_dim)
          USING _embedding INTO query_red;
        IF store_half THEN
            dist_red := format(
              'public.subvector(embedding, 1, %s)::public.halfvec(%s) <=> $2::public.halfvec(%s)', red_dim, red_dim, red_dim);
        ELSE
            dist_red := format(
              'public.subvector(embedding, 1, %s)::public.vector(%s) <=> $2', red_dim, red_dim);
        END IF;
    ELSIF use_reduced THEN
        query_red := hivesense_app.reduce_embedding(_embedding);

        IF store_half THEN
            dist_red := format(
              'reduced_embedding <=> $2::public.halfvec(%s)', red_dim);
        ELSIF half_index THEN
            dist_red := format(
              '(reduced_embedding::public.halfvec(%1$s)) <=> $2::public.halfvec(%1$s)',
              red_dim);
        ELSE
            dist_red := 'reduced_embedding <=> $2';
        END IF;
    END IF;

    /* ────────────────────────────────────────────────────────────
     *  MAIN query (three variants like posts search)
     * ────────────────────────────────────────────────────────────*/
    IF exhaustive THEN
        -- Exhaustive search for benchmarking
        PERFORM set_config('enable_indexscan',      'off', TRUE);
        PERFORM set_config('enable_bitmapscan',     'off', TRUE);
        PERFORM set_config('enable_indexonlyscan',  'off', TRUE);
        PERFORM set_config('max_parallel_workers_per_gather', '4', TRUE);

        SELECT
          array_agg(b.post_id     ORDER BY b.sim),
          array_agg(b.chunk_number ORDER BY b.sim),
          array_agg(b.sim         ORDER BY b.sim),
          array_agg(b.author_id   ORDER BY b.sim)
        INTO post_ids, chunk_numbers, sims, author_ids
        FROM (
          SELECT
            pv.post_id,
            pv.chunk_number,
            hp.author_id,
            (pv.embedding <=> _embedding)::real AS sim
          FROM hivesense_app.posts_vectors pv
          JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
          ORDER BY sim
          LIMIT LEAST(ann_candidates, 100000)
        ) AS b;

        PERFORM set_config('enable_indexscan',     'on', TRUE);
        PERFORM set_config('enable_bitmapscan',    'on', TRUE);
        PERFORM set_config('enable_indexonlyscan', 'on', TRUE);

        RETURN QUERY
        WITH candidates AS (
            SELECT
              author_ids[i]    AS author_id,
              sims[i]          AS sim,
              post_ids[i]      AS post_id
            FROM generate_subscripts(author_ids,1) AS s(i)
        ),
        filtered AS (
            SELECT c.author_id, c.sim, c.post_id
              FROM candidates c
              JOIN hivesense_app.post_data pd ON pd.post_id = c.post_id
             WHERE (__min_search_tokens = 0 OR pd.number_of_tokens >= __min_search_tokens)
               AND (_observer_id = 0 OR NOT EXISTS (
                     SELECT 1
                       FROM hivemind_app.muted_accounts_by_id_view m
                      WHERE m.observer_id = _observer_id
                        AND m.muted_id    = c.author_id
                   ))
        ),
        ranked AS (
            SELECT author_id,
                   sim,
                   row_number() OVER (ORDER BY sim) AS rn
              FROM filtered
        ),
        author_best AS (
            SELECT author_id,
                   MIN(sim) AS best_sim,
                   SUM(1.0 / sqrt(rn)) AS score
              FROM ranked
             GROUP BY author_id
        )
        SELECT
          (row_number() OVER (ORDER BY score DESC, author_id))::int AS rank,
          author_id,
          best_sim::real AS similarity
        FROM author_best
        ORDER BY score DESC, author_id
        LIMIT _limit;
        RETURN;

    ELSIF use_reduced AND red_mode = 'slice' THEN
        -- Matryoshka slicing: ANN on posts_vectors with expression distance
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pv.post_id,
                       pv.chunk_number,
                       %s AS ann_dist
                  FROM hivesense_app.posts_vectors pv
                 WHERE TRUE%s
                 ORDER BY ann_dist, pv.post_id
                 LIMIT %s
            ),
            reranked AS (
                SELECT hp.author_id,
                       ann.post_id,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM ann
                  JOIN hivesense_app.posts_vectors pv
                    ON pv.post_id = ann.post_id
                   AND pv.chunk_number = ann.chunk_number
                  JOIN hivemind_app.hive_posts hp ON hp.id = ann.post_id
            ),
            ranked AS (
                SELECT author_id,
                       sim,
                       row_number() OVER (ORDER BY sim) AS rn
                  FROM reranked
            ),
            author_best AS (
                SELECT author_id,
                       MIN(sim) AS best_sim,
                       SUM(1.0 / sqrt(rn)) AS score
                  FROM ranked
                 GROUP BY author_id
            )
            SELECT ((row_number() OVER (ORDER BY score DESC, author_id))::int) AS rank,
                   author_id,
                   best_sim::real AS similarity
              FROM author_best
             ORDER BY score DESC, author_id
             LIMIT %s
        $q$,
          dist_red,                     -- %s  ann distance expr
          hivesense_app.ann_candidate_filter('pv', NULL, _observer_id),  -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red;

    ELSIF use_reduced THEN
        -- PCA: ANN on posts_vectors_reduced, rerank with full embedding
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pr.post_id,
                       pr.chunk_number,
                       %s AS ann_dist
                  FROM hivesense_app.posts_vectors_reduced pr
                 WHERE TRUE%s
                 ORDER BY ann_dist, pr.post_id
                 LIMIT %s
            ),
            reranked AS (
                SELECT hp.author_id,
                       ann.post_id,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM ann
                  JOIN hivesense_app.posts_vectors pv
                    ON pv.post_id = ann.post_id
                   AND pv.chunk_number = ann.chunk_number
                  JOIN hivemind_app.hive_posts hp ON hp.id = ann.post_id
            ),
            ranked AS (
                SELECT author_id,
                       sim,
                       row_number() OVER (ORDER BY sim) AS rn
                  FROM reranked
            ),
            author_best AS (
                SELECT author_id,
                       MIN(sim) AS best_sim,
                       SUM(1.0 / sqrt(rn)) AS score
                  FROM ranked
                 GROUP BY author_id
            )
            SELECT ((row_number() OVER (ORDER BY score DESC, author_id))::int) AS rank,
                   author_id,
                   best_sim::real AS similarity
              FROM author_best
             ORDER BY score DESC, author_id
             LIMIT %s
        $q$,
          dist_red,                     -- %s  ann distance expr
          hivesense_app.ann_candidate_filter('pr', NULL, _observer_id),  -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red;

    ELSE   /* ───────── full-vector path ───────── */
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pv.post_id,
                       pv.chunk_number,
                       %s AS sim
                  FROM hivesense_app.posts_vectors pv
                 WHERE TRUE%s
                 ORDER BY sim, pv.post_id
                 LIMIT %s
            ),
            ranked AS (
                SELECT hp.author_id,
                       ann.sim,
                       row_number() OVER (ORDER BY ann.sim) AS rn
                  FROM ann
                  JOIN hivemind_app.hive_posts hp ON hp.id = ann.post_id
            ),
            author_best AS (
                SELECT author_id,
                       MIN(sim) AS best_sim,
                       SUM(1.0 / sqrt(rn)) AS score
                  FROM ranked
                 GROUP BY author_id
            )
            SELECT ((row_number() OVER (ORDER BY score DESC, author_id))::int) AS rank,
                   author_id,
                   best_sim::real AS similarity
              FROM author_best
             ORDER BY score DESC, author_id
             LIMIT %s
        $q$,
          dist_full,                    -- %s  distance expr
          hivesense_app.ann_candidate_filter('pv', NULL, _observer_id),  -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding;
    END IF;
END;
$BODY$;

RESET ROLE

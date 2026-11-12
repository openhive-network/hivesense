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
 * of table alias _alias: the excluded post, and the post_data lookup only when
 * a token threshold can remove a row. Liveness is checked separately, by
 * live_post_filter. */
DROP FUNCTION IF EXISTS hivesense_app.ann_candidate_filter(text, int, int);
CREATE OR REPLACE FUNCTION hivesense_app.ann_candidate_filter(
    _alias           text,
    _exclude_post_id int
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

    RETURN __filter;
END;
$$;

/* WHERE-clause fragment (starting with AND) keeping only the rows of table
 * alias _alias whose post is live: one hive_posts probe per row. A deleted
 * post keeps its embeddings, but hivemind's full-post view returns no row for
 * it, so one ranked into /posts/search's full_posts slots was silently dropped
 * (fewer full objects than requested) while one ranked lower came back as a
 * bare author/permlink stub. The observer's mute check rides on that same
 * probe. */
CREATE OR REPLACE FUNCTION hivesense_app.live_post_filter(
    _alias       text,
    _observer_id int
)
RETURNS text
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
BEGIN
    IF _observer_id <> 0 AND EXISTS (
           SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
            WHERE m.observer_id = _observer_id) THEN
        RETURN format(
          ' AND EXISTS (SELECT 1 FROM hivemind_app.hive_posts hp'
          ' WHERE hp.id = %1$I.post_id AND hp.counter_deleted = 0'
          ' AND NOT EXISTS (SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m'
          ' WHERE m.observer_id = %2$s AND m.muted_id = hp.author_id))',
          _alias, _observer_id);
    END IF;

    RETURN format(
      ' AND EXISTS (SELECT 1 FROM hivemind_app.hive_posts hp'
      ' WHERE hp.id = %1$I.post_id AND hp.counter_deleted = 0)',
      _alias);
END;
$$;

/* ────────────────────────────────────────────────────────────────
 * 1b. Block-range (time window) filter support (#13)
 *
 *  post_id cannot stand in for the creation block directly: in 300k-id
 *  samples from three older eras, ids were up to 999 blocks out of
 *  creation order (all hive_posts rows; likely hivemind's massive-sync
 *  batches), while a recent sample was in order. A row created more than
 *  that many blocks before the window therefore has a smaller id than
 *  every post in it, and one created that far after has a larger id.
 *  These bounds take one such row on each side, with a 10,000-block
 *  margin; callers re-check block_num_created exactly, so the margin only
 *  costs a few hours of extra candidates and never changes the result.
 *
 *  The window's size is capped (max_window_chunks): exact ranking cost
 *  grows with the chunk count, and older eras are far denser (the busiest
 *  6 months, Jan-Jun 2018, hold ~4.6M chunks against ~0.2M for the latest
 *  6). The count covers the padded id range and stops at the cap. The
 *  endpoint calls this before embedding the query, so an oversized window
 *  is refused without touching the embedding server.
 * ────────────────────────────────────────────────────────────────*/
CREATE OR REPLACE FUNCTION hivesense_app.window_post_bounds(
    _first_block int,           -- NULL = from genesis
    _last_block  int,           -- NULL = up to the newest post
    OUT lo int,                 -- exclusive post_id bounds that surely
    OUT hi int                  --   enclose every post created in the window
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    first_blk int := COALESCE(_first_block, 0);
    last_blk  int := COALESCE(_last_block, 2147483647);
    max_chunks bigint := GREATEST(COALESCE(
        (SELECT max_window_chunks FROM hivesense_app.hivesense_app_status WHERE id = 1), 300000), 1);
    n bigint;
BEGIN
    IF first_blk > 10000 THEN
        SELECT hp.id INTO lo
          FROM hivemind_app.hive_posts hp
         WHERE hp.block_num_created < first_blk - 10000
         ORDER BY hp.block_num_created DESC
         LIMIT 1;
    END IF;
    IF last_blk < 2147483647 - 10000 THEN
        SELECT hp.id INTO hi
          FROM hivemind_app.hive_posts hp
         WHERE hp.block_num_created > last_blk + 10000
         ORDER BY hp.block_num_created
         LIMIT 1;
    END IF;
    lo := COALESCE(lo, 0);
    hi := COALESCE(hi, 2147483647);

    SELECT count(*) INTO n
      FROM (SELECT 1 FROM hivesense_app.posts_vectors pv
             WHERE pv.post_id > lo AND pv.post_id < hi
             LIMIT max_chunks + 1) c;
    IF n > max_chunks THEN
        RAISE EXCEPTION 'The requested block range holds more than % embedded post chunks; narrow from-block/to-block', max_chunks;
    END IF;
END;
$$;

/* ────────────────────────────────────────────────────────────────
 * 2.  One-shot nearest-posts function
 * ────────────────────────────────────────────────────────────────*/
CREATE OR REPLACE FUNCTION hivesense_app.find_nearest_posts_with_embedding_one_shot(
    _embedding       public.vector,      -- full-size query embedding (768-d)
    _limit           int     DEFAULT 1000,
    _exclude_post_id int     DEFAULT NULL,
    _observer_id     int     DEFAULT 0,
    _author_id       int     DEFAULT NULL, -- restrict to one author's posts (#47)
    _first_block     int     DEFAULT NULL, -- restrict to posts created in blocks
    _last_block      int     DEFAULT NULL  --   [_first_block, _last_block] (#13); NULL = open end
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
    author_post_ids int[];  -- author filter: that author's live root posts

    /* ------ block-range (time window) filter ------ */
    has_window    boolean := _first_block IS NOT NULL OR _last_block IS NOT NULL;
    first_blk     int     := COALESCE(_first_block, 0);
    last_blk      int     := COALESCE(_last_block, 2147483647);
    window_lo     int;      -- exclusive post_id bounds, see window_post_bounds
    window_hi     int;

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
     *  AUTHOR filter (#47): rank ALL of one author's chunks exactly
     *
     *  Never goes through the vector index. An HNSW scan returns only
     *  its nearest few hundred candidates and the author predicate would
     *  be applied afterwards, so a filtered author who is not among them
     *  gets few or no results -- measured: 0 rows for an account with
     *  179 embedded chunks, and still 0 rows with iterative scan, which
     *  gave up after 12-14 s at its 20,000-tuple cap.
     *  Instead: collect the author's post ids, then compute the distance
     *  for every one of their chunks. The query orders chunks by post_id
     *  first (for DISTINCT ON) and by distance only after that, so no plan
     *  can serve it from an index-ordered vector scan.
     *
     *  It sits ahead of the exhaustive debug branch so that header can
     *  never silently drop the filter; this branch is already exact.
     * ────────────────────────────────────────────────────────────*/
    IF _author_id IS NOT NULL THEN
        -- A muted author yields nothing, as in the unfiltered search.
        IF _observer_id <> 0 AND EXISTS (
               SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                WHERE m.observer_id = _observer_id
                  AND m.muted_id    = _author_id) THEN
            RETURN;
        END IF;

        -- Only root posts are embedded, and these literal predicates match
        -- hivemind's partial index (author_id, id DESC) WHERE depth = 0 AND
        -- counter_deleted = 0 -- so an account with millions of comments
        -- costs nothing extra. Deleted posts are excluded, as below. A
        -- block range (#13) narrows the same list, so author + window stays
        -- exact too; it is a separate statement so the author-only lookup
        -- keeps its index-only scan (block_num_created is not in that index).
        IF has_window THEN
            SELECT array_agg(hp.id)
              INTO author_post_ids
              FROM hivemind_app.hive_posts hp
             WHERE hp.author_id = _author_id
               AND hp.depth = 0
               AND hp.counter_deleted = 0
               AND hp.block_num_created BETWEEN first_blk AND last_blk;
        ELSE
            SELECT array_agg(hp.id)
              INTO author_post_ids
              FROM hivemind_app.hive_posts hp
             WHERE hp.author_id = _author_id
               AND hp.depth = 0
               AND hp.counter_deleted = 0;
        END IF;

        IF author_post_ids IS NULL THEN
            RETURN;
        END IF;

        -- The ids go in as a bound array, not a join: EXECUTE plans with the
        -- real value, so the planner sees the true row count. Behind a CTE,
        -- prolific commenters were misestimated at ~500k rows and the plan
        -- seq-scanned all of posts_vectors (seconds instead of milliseconds).
        RETURN QUERY EXECUTE format($q$
            WITH best_chunk AS (
                SELECT DISTINCT ON (pv.post_id)
                       pv.post_id,
                       pv.chunk_number,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM hivesense_app.posts_vectors pv
                  JOIN hivesense_app.post_data pd ON pd.post_id = pv.post_id
                 WHERE pv.post_id = ANY($3)
                   AND (%L OR pd.number_of_tokens >= %s)
                   AND ($2 IS NULL OR pv.post_id <> $2)
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
          (__min_tokens = 0),           -- %L  token filter off?
          __min_tokens,                 -- %s
          _limit                        -- %s
        )
        USING _embedding, _exclude_post_id, author_post_ids;
        RETURN;
    END IF;

    /* ────────────────────────────────────────────────────────────
     *  BLOCK-RANGE filter (#13): rank ALL posts created in the window
     *  exactly, for the same reason as the author filter. Every useful
     *  window is a sliver of the corpus (6 months = ~1.2% of chunks on a
     *  full node), so "ANN + WHERE block" returns almost nothing: measured
     *  106, 4 and 0 posts out of 1,000 asked for a 6-month window.
     *
     *  window_post_bounds gives post_id bounds that surely enclose the
     *  window (and refuses an oversized one); the query re-checks the
     *  creation block exactly. The id bounds are applied to hive_posts too,
     *  so the join cannot be driven from the block index over every comment
     *  in the window.
     * ────────────────────────────────────────────────────────────*/
    IF has_window THEN
        SELECT b.lo, b.hi INTO window_lo, window_hi
          FROM hivesense_app.window_post_bounds(_first_block, _last_block) b;

        RETURN QUERY EXECUTE format($q$
            WITH best_chunk AS (
                SELECT DISTINCT ON (pv.post_id)
                       pv.post_id,
                       pv.chunk_number,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM hivesense_app.posts_vectors pv
                  JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
                  JOIN hivesense_app.post_data pd ON pd.post_id = pv.post_id
                 WHERE pv.post_id > $3 AND pv.post_id < $4
                   AND hp.id > $3 AND hp.id < $4
                   AND hp.block_num_created BETWEEN $5 AND $6
                   AND hp.counter_deleted = 0
                   AND (%L OR pd.number_of_tokens >= %s)
                   AND ($2 IS NULL OR pv.post_id <> $2)
                   AND ($7 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $7
                            AND m.muted_id    = hp.author_id))
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
          (__min_tokens = 0),           -- %L  token filter off?
          __min_tokens,                 -- %s
          _limit                        -- %s
        )
        USING _embedding, _exclude_post_id, window_lo, window_hi, first_blk, last_blk, _observer_id;
        RETURN;
    END IF;

    /* ────────────────────────────────────────────────────────────
     *  MAIN one-shot query (three variants)
     *
     *  Every variant skips deleted posts (and posts of authors the observer
     *  mutes): the exhaustive one explicitly, the ANN variants through
     *  live_post_filter, applied only after the re-rank. The re-ranked posts
     *  come out of a fenced subquery (OFFSET 0 keeps the filter from being
     *  pushed into it) in final order, so the hive_posts probe runs lazily
     *  under the LIMIT: once per returned post plus once per rejected one,
     *  not once per ANN candidate (e.g. 8 rather than ~60 at result_limit 8).
     *
     *  This returns what probing every ANN candidate did: with
     *  hnsw.iterative_scan off the index yields at most ef_search rows
     *  whatever the filter, so the ANN LIMIT (= ef_search) never binds and
     *  the live posts among the candidates, their best chunks and their
     *  order are the same; the probe now only drops the dead ones later.
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
            ),
            reranked AS (
                SELECT post_id, chunk_number, sim
                  FROM best_chunk
                 ORDER BY sim, post_id
                OFFSET 0
            )
            SELECT ((row_number() OVER (ORDER BY sim, post_id))::int) AS similarity_order,
                   sim::real AS similarity,
                   post_id,
                   chunk_number
              FROM reranked
             WHERE TRUE%s
             ORDER BY sim, post_id
             LIMIT %s
        $q$,
          dist_red,                     -- %s  ann distance expr (expression on embedding)
          hivesense_app.ann_candidate_filter('pv', _exclude_post_id),  -- %s
          ann_candidates,               -- %s
          hivesense_app.live_post_filter('reranked', _observer_id),  -- %s
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
            ),
            reranked AS (
                SELECT post_id, chunk_number, sim
                  FROM best_chunk
                 ORDER BY sim, post_id
                OFFSET 0
            )
            SELECT ((row_number() OVER (ORDER BY sim, post_id))::int) AS similarity_order,
                   sim::real AS similarity,
                   post_id,
                   chunk_number
              FROM reranked
             WHERE TRUE%s
             ORDER BY sim, post_id
             LIMIT %s
        $q$,
          dist_red,                     -- %s  ann distance expr
          hivesense_app.ann_candidate_filter('pr', _exclude_post_id),  -- %s
          ann_candidates,               -- %s
          hivesense_app.live_post_filter('reranked', _observer_id),  -- %s
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
            ),
            reranked AS (
                SELECT post_id, chunk_number, sim
                  FROM best_chunk
                 ORDER BY sim, post_id
                OFFSET 0
            )
            SELECT ((row_number() OVER (ORDER BY sim, post_id))::int) AS similarity_order,
                   sim::real  AS similarity,
                   post_id,
                   chunk_number
              FROM reranked
             WHERE TRUE%s
             ORDER BY sim, post_id
             LIMIT %s
        $q$,
          dist_full,                  -- %s
          hivesense_app.ann_candidate_filter('pv', _exclude_post_id),  -- %s
          ann_candidates,             -- %s
          hivesense_app.live_post_filter('reranked', _observer_id),  -- %s
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
    _observer_id  int   DEFAULT 0,
    _author_id    int   DEFAULT NULL,
    _first_block  int   DEFAULT NULL,
    _last_block   int   DEFAULT NULL
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
               _observer_id => _observer_id,
               _author_id   => _author_id,
               _first_block => _first_block,
               _last_block  => _last_block
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


-- The SET clause below names pgvector settings, which a non-superuser may
-- attach only once the library has defined them in this session: reading a
-- vector value loads it.
DO $$
BEGIN
    PERFORM '[1]'::public.vector;
END
$$;

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
SET hnsw.iterative_scan = relaxed_order
SET hnsw.max_scan_tuples = 20000
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
    __ef_ceiling          INT;

    /* ------ iterative ANN scan ------ */
    ann_cursor    refcursor;
    cand          record;
    __max_fetch   int;          -- cap on rows read from the cursor
    __seqscan     text;         -- caller's enable_seqscan
    fetched       int     := 0;
    pool_authors  int[]    := '{}';  -- live candidates: author ...
    pool_sims     float8[] := '{}';  --   ... and re-ranked distance
    found_authors int[]    := '{}';

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
    SELECT min_token_search_threshold, ef_ceiling
      INTO __min_search_tokens, __ef_ceiling
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
    END IF;

    /* ────────────────────────────────────────────────────────────
     *  ANN candidates: an iterative index scan read through a cursor
     *
     *  One author can own most of the nearest chunks, so a pool sized
     *  like the post search's (ef_search chunks) can collapse to a single
     *  author. The function's SET clause turns on relaxed_order iterative
     *  scan, and the cursor reads until both hold:
     *   - the fixed pool is taken: ef_search index rows (or ann_candidates
     *     live ones, when a debug header lowers it). pgvector's first batch
     *     is the same ef_search search a scan without iteration runs, so
     *     where that pool already holds _limit authors the pool, and the
     *     result, are the ones a one-shot LIMIT ann_candidates query gives;
     *   - the live candidates cover _limit distinct authors.
     *  Liveness, mutes and the token threshold are computed per row (the
     *  same predicates as the posts search) and count toward the authors.
     *
     *  Cap: 10 * max(ef_ceiling, ef_search, 100) rows, 5,000 at the default
     *  ceiling of 500 -- ten chunks per author at the largest result_limit
     *  (100), never fewer than 1,000 so a tiny configured ceiling still
     *  leaves room to find distinct authors, and never below the fixed pool. The same value is hnsw.max_scan_tuples,
     *  which pgvector counts in visited graph elements, so the graph walk
     *  stops near it too (the scan then hands out the candidates it already
     *  holds). Measured for "landscape photography" at ef 100: 109 rows on
     *  hbt5 (5 ms), 46 on shed14 (3 ms), where a fixed pool of 500 took
     *  804 ms and still depended on how far one author's posts reach. At the
     *  cap the authors found so far are returned.
     *
     *  Both pgvector settings stay inside this call: they are named in the
     *  function's SET clause, which restores them at exit even after a local
     *  change below, so a posts search later in the same transaction still
     *  runs without iterative scan.
     * ────────────────────────────────────────────────────────────*/
    __max_fetch := GREATEST(__ef_ceiling, exploratory_factor, 100) * 10;
    PERFORM set_config('hnsw.max_scan_tuples', __max_fetch::text, true);
    -- planned at OPEN: without a LIMIT, never let a sort of the table win
    __seqscan := current_setting('enable_seqscan');
    PERFORM set_config('enable_seqscan', 'off', true);

    IF use_reduced AND red_mode = 'slice' THEN
        -- Matryoshka slicing: ANN on posts_vectors with expression distance,
        -- full embedding of the same row for the re-rank
        OPEN ann_cursor NO SCROLL FOR EXECUTE format($q$
            SELECT (SELECT hp.author_id FROM hivemind_app.hive_posts hp
                     WHERE hp.id = pv.post_id) AS author_id,
                   (TRUE%s) AS live,
                   (pv.embedding <=> $1)::float4::float8 AS sim
              FROM hivesense_app.posts_vectors pv
             ORDER BY %s
        $q$,
          hivesense_app.ann_candidate_filter('pv', NULL)
            || hivesense_app.live_post_filter('pv', _observer_id),  -- %s
          dist_red                      -- %s  ann distance expr
        )
        USING _embedding, query_red;

    ELSIF use_reduced THEN
        -- PCA: ANN on posts_vectors_reduced, re-rank with full embedding
        OPEN ann_cursor NO SCROLL FOR EXECUTE format($q$
            SELECT (SELECT hp.author_id FROM hivemind_app.hive_posts hp
                     WHERE hp.id = pr.post_id) AS author_id,
                   (TRUE%s) AS live,
                   (SELECT (pv.embedding <=> $1)::float4::float8
                      FROM hivesense_app.posts_vectors pv
                     WHERE pv.post_id = pr.post_id
                       AND pv.chunk_number = pr.chunk_number) AS sim
              FROM hivesense_app.posts_vectors_reduced pr
             ORDER BY %s
        $q$,
          hivesense_app.ann_candidate_filter('pr', NULL)
            || hivesense_app.live_post_filter('pr', _observer_id),  -- %s
          dist_red                      -- %s  ann distance expr
        )
        USING _embedding, query_red;

    ELSE   /* ───────── full-vector path ───────── */
        OPEN ann_cursor NO SCROLL FOR EXECUTE format($q$
            SELECT (SELECT hp.author_id FROM hivemind_app.hive_posts hp
                     WHERE hp.id = pv.post_id) AS author_id,
                   (TRUE%s) AS live,
                   %s AS sim
              FROM hivesense_app.posts_vectors pv
             ORDER BY sim
        $q$,
          hivesense_app.ann_candidate_filter('pv', NULL)
            || hivesense_app.live_post_filter('pv', _observer_id),  -- %s
          dist_full                     -- %s  distance expr
        )
        USING _embedding, query_red;
    END IF;
    PERFORM set_config('enable_seqscan', __seqscan, true);

    LOOP
        FETCH ann_cursor INTO cand;
        EXIT WHEN NOT FOUND;
        fetched := fetched + 1;

        IF cand.live THEN
            pool_authors := pool_authors || cand.author_id;
            pool_sims    := pool_sims    || cand.sim;
            IF NOT cand.author_id = ANY(found_authors) THEN
                found_authors := found_authors || cand.author_id;
            END IF;
        END IF;

        EXIT WHEN (fetched >= exploratory_factor OR cardinality(pool_sims) >= ann_candidates)
              AND cardinality(found_authors) >= _limit;
        EXIT WHEN fetched >= __max_fetch;
    END LOOP;
    CLOSE ann_cursor;

    RETURN QUERY
    WITH ranked AS (
        SELECT c.author_id,
               c.sim,
               row_number() OVER (ORDER BY c.sim) AS rn
          FROM unnest(pool_authors, pool_sims) AS c(author_id, sim)
    ),
    author_best AS (
        SELECT ranked.author_id,
               MIN(ranked.sim) AS best_sim,
               SUM(1.0 / sqrt(ranked.rn)) AS score
          FROM ranked
         GROUP BY ranked.author_id
    )
    SELECT (row_number() OVER (ORDER BY ab.score DESC, ab.author_id))::int AS rank,
           ab.author_id,
           ab.best_sim::real AS similarity
      FROM author_best ab
     ORDER BY ab.score DESC, ab.author_id
     LIMIT _limit;
END;
$BODY$;

RESET ROLE

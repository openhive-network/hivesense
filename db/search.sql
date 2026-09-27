SET ROLE hivesense_owner;

DROP TYPE IF EXISTS hivesense_app.similar_post_result CASCADE;
CREATE TYPE hivesense_app.similar_post_result AS (
    similarity_order INT,     -- 1-based rank
    similarity       REAL,    -- cosine distance (smaller = closer)
    post_id          INT,
    chunk_number     INT      -- chunk with best similarity
);

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
         ORDER BY hp.block_num_created
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
    default_ef   int := (SELECT default_ef_search FROM hivesense_app.hivesense_app_status LIMIT 1);
    minimum_ann_candidates int := (SELECT minimum_ann_candidates FROM hivesense_app.hivesense_app_status LIMIT 1);
    allow_dbg    boolean := hivesense_app.allow_debugging();
    req_headers        jsonb := current_setting('request.headers', true)::jsonb;
    batch_multiplier   int := 5;
    exploratory_factor int := default_ef;
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
        batch_multiplier   := COALESCE((req_headers->>'x-batch-size-multiplier')::int,
                                       batch_multiplier);
        exploratory_factor := COALESCE((req_headers->>'x-exploratory-factor')::int,
                                       exploratory_factor);

        exhaustive := lower(coalesce(req_headers->>'x-exhaustive-search','false')) = 'true';
    END IF;

    ann_candidates := LEAST(_limit * batch_multiplier, 50000);
    IF allow_dbg THEN
        ann_candidates := COALESCE((req_headers->>'x-ann-candidates')::int,
                                   ann_candidates);
    END IF;
    ann_candidates := GREATEST(ann_candidates, minimum_ann_candidates);


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
     *  Every variant skips deleted posts (hp.counter_deleted = 0). Their
     *  embeddings stay in posts_vectors, but hivemind's full-post view
     *  returns no row for them, so a deleted post ranked into the
     *  full_posts slots of /posts/search was silently dropped (fewer full
     *  objects than requested) while one ranked lower came back as a bare
     *  author/permlink stub.
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
                  JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
                  JOIN hivesense_app.post_data pd ON pd.post_id = pv.post_id
                 WHERE (%L OR pd.number_of_tokens >= %s)
                   AND hp.counter_deleted = 0
                   AND ($3 IS NULL OR pv.post_id <> $3)
                   AND ($4 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $4
                            AND m.muted_id    = hp.author_id))
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
          (__min_tokens = 0),           -- %L  token filter off?
          __min_tokens,                 -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red, _exclude_post_id, _observer_id;

    ELSIF use_reduced THEN
        -- PCA: ANN on posts_vectors_reduced, rerank with full embedding
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pr.post_id,
                       pr.chunk_number,
                       %s                           AS ann_dist
                  FROM hivesense_app.posts_vectors_reduced pr
                  JOIN hivemind_app.hive_posts hp ON hp.id = pr.post_id
                  JOIN hivesense_app.post_data pd ON pd.post_id = pr.post_id
                 WHERE (%L OR pd.number_of_tokens >= %s)
                   AND hp.counter_deleted = 0
                   AND ($3 IS NULL OR pr.post_id <> $3)
                   AND ($4 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $4
                            AND m.muted_id    = hp.author_id))
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
          (__min_tokens = 0),           -- %L  token filter off?
          __min_tokens,                 -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red, _exclude_post_id, _observer_id;

    ELSE   /* ───────── full-vector path ───────── */
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pv.post_id,
                       pv.chunk_number,
                       %s                           AS sim
                  FROM hivesense_app.posts_vectors pv
                  JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
                  JOIN hivesense_app.post_data pd ON pd.post_id = pv.post_id
                 WHERE (%L OR pd.number_of_tokens >= %s)
                   AND hp.counter_deleted = 0
                   AND ($2 IS NULL OR pv.post_id <> $2)
                   AND ($3 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $3
                            AND m.muted_id    = hp.author_id))
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
          (__min_tokens = 0),         -- %L
          __min_tokens,               -- %s
          ann_candidates,             -- %s
          _limit                      -- %s
        )
        USING _embedding, _exclude_post_id, _observer_id;

    END IF;
END;
$$;

DROP FUNCTION IF EXISTS find_nearest_posts_with_embedding;
CREATE OR REPLACE FUNCTION hivesense_app.find_nearest_posts_with_embedding(
  _embedding       public.vector,  -- full-size query embedding
  _limit           int     DEFAULT 10,
  _exclude_post_id int     DEFAULT NULL,
  _observer_id     int     DEFAULT 0,
  _start_post_id   int     DEFAULT 0
)
RETURNS SETOF hivesense_app.similar_post_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    ----------------------------------------------------------------
    -- global flags & dimensions
    ----------------------------------------------------------------
    use_reduced boolean := hivesense_app.use_reduced_embeddings();
    red_mode    text    := hivesense_app.reduction_mode();
    store_half  boolean := hivesense_app.store_halfvec_embeddings();
    half_index  boolean := hivesense_app.use_halfvec_index();

    full_dim    int := hivesense_app.embedding_dims();
    red_dim     int := hivesense_app.reduced_dims();

    -- reduced query vector (only used when use_reduced)
    query_red   public.vector;

    ----------------------------------------------------------------
    -- dynamic clauses
    ----------------------------------------------------------------
    dist_full   text := hivesense_app.distance_clause(1);  -- for rerank
    dist_red    text;                                      -- for ANN

    tgt_tbl     text := CASE WHEN use_reduced AND red_mode <> 'slice'
                              THEN 'hivesense_app.posts_vectors_reduced'
                              ELSE 'hivesense_app.posts_vectors'
                         END;
    tgt_col     text := CASE WHEN use_reduced AND red_mode <> 'slice'
                              THEN 'reduced_embedding'
                              ELSE 'embedding'
                         END;

    ----------------------------------------------------------------
    -- legacy variables (unchanged)
    ----------------------------------------------------------------
    rec           RECORD;
    seen_ids      int[] := ARRAY[]::int[];
    count_posts   int   := 0;
    max_posts     int   := LEAST(_limit, 1000);
    collecting    bool  := (_start_post_id = 0);

    req_headers        json;
    batch_multiplier   int := 5;
    exploratory_factor int := 1000;
    batch_size         int;
    rows_fetched       int;
    sql                text;
    __min_search_tokens int;
    _num_tokens         int;
BEGIN
    ----------------------------------------------------------------
    -- Build reduced query once (if needed)
    ----------------------------------------------------------------
    IF use_reduced AND red_mode = 'slice' THEN
        EXECUTE format('SELECT public.subvector($1, 1, %s)', red_dim)
          USING _embedding INTO query_red;
    ELSIF use_reduced THEN
        query_red := hivesense_app.reduce_embedding(_embedding);
    END IF;

    ----------------------------------------------------------------
    -- Build ANN distance clause for reduced or full path
    ----------------------------------------------------------------
    IF NOT use_reduced THEN
        dist_red := dist_full;        -- same column & same param pos
    ELSIF red_mode = 'slice' THEN
        IF store_half THEN
            dist_red := format(
              'public.subvector(embedding, 1, %s)::public.halfvec(%s) <=> $2::public.halfvec(%s)', red_dim, red_dim, red_dim);
        ELSE
            dist_red := format(
              'public.subvector(embedding, 1, %s)::public.vector(%s) <=> $2', red_dim, red_dim);
        END IF;
    ELSE
        IF store_half THEN
            dist_red := format('%I <=> $2::public.halfvec(%s)', tgt_col, red_dim);
        ELSIF half_index THEN
            dist_red := format('(%I::public.halfvec(%2$s)) <=> $2::public.halfvec(%2$s)',
                                tgt_col, red_dim);
        ELSE
            dist_red := format('%I <=> $2', tgt_col);
        END IF;
    END IF;

    ----------------------------------------------------------------
    -- operator tuning & header overrides (unchanged)
    ----------------------------------------------------------------
    SELECT current_setting('request.headers', true)::json INTO req_headers;
    batch_multiplier := COALESCE((req_headers->>'x-batch-size-multiplier')::int,
                                 batch_multiplier);
    exploratory_factor := COALESCE((req_headers->>'x-exploratory-factor')::int,
                                   exploratory_factor);
    batch_size := GREATEST(_limit * batch_multiplier, 50);

    PERFORM set_config('ivfflat.probes', '4', true);
    PERFORM set_config('hnsw.ef_search', exploratory_factor::text, true);

    SELECT min_token_search_threshold
      INTO __min_search_tokens
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    RAISE NOTICE 'In find_nearest_posts_with_embedding(vec, %, %, %, %)', _limit, _exclude_post_id, _observer_id, _start_post_id;
    

    ----------------------------------------------------------------
    -- MAIN retrieval loop
    ----------------------------------------------------------------
    LOOP
        rows_fetched := 0;

        /* ============== 1️⃣  compose & run the ANN query ============== */
        IF use_reduced THEN
            IF red_mode = 'slice' THEN
                -- Matryoshka: ANN on posts_vectors with expression distance
                sql := format($q$
                    WITH ann AS (
                        SELECT hpv.post_id,
                               hpv.chunk_number,
                               %s AS ann_dist
                          FROM hivesense_app.posts_vectors hpv
                          JOIN hivemind_app.hive_posts hp ON hp.id = hpv.post_id
                         WHERE ($3 IS NULL OR hpv.post_id <> $3)
                           AND ($4 = 0 OR NOT EXISTS (
                                 SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                                  WHERE m.observer_id = $4
                                    AND m.muted_id    = hp.author_id))
                         ORDER BY ann_dist, hpv.post_id
                         LIMIT %s
                    )
                    SELECT ann.post_id,
                           ann.chunk_number,
                           (pv.embedding <=> $1)::float4 AS similarity
                      FROM ann
                      JOIN hivesense_app.posts_vectors pv
                        ON pv.post_id = ann.post_id
                $q$, dist_red, batch_size);
            ELSE
                -- PCA: ANN on posts_vectors_reduced
                sql := format($q$
                    WITH ann AS (
                        SELECT hpv.post_id,
                               hpv.chunk_number,
                               %s AS ann_dist
                          FROM hivesense_app.posts_vectors_reduced hpv
                          JOIN hivemind_app.hive_posts hp ON hp.id = hpv.post_id
                         WHERE ($3 IS NULL OR hpv.post_id <> $3)
                           AND ($4 = 0 OR NOT EXISTS (
                                 SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                                  WHERE m.observer_id = $4
                                    AND m.muted_id    = hp.author_id))
                         ORDER BY ann_dist, hpv.post_id
                         LIMIT %s
                    )
                    SELECT ann.post_id,
                           ann.chunk_number,
                           (pv.embedding <=> $1)::float4 AS similarity
                      FROM ann
                      JOIN hivesense_app.posts_vectors pv
                        ON pv.post_id = ann.post_id
                $q$, dist_red, batch_size);
            END IF;

            -- both reduced queries use the same parameter layout
            FOR rec IN EXECUTE sql
                USING _embedding,               -- $1  full-dim (rerank)
                      query_red,                -- $2  reduced/sliced query
                      _exclude_post_id,         -- $3
                      _observer_id              -- $4
            LOOP
                rows_fetched := rows_fetched + 1;

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
                RETURN NEXT (count_posts, rec.similarity, rec.post_id, rec.chunk_number)::hivesense_app.similar_post_result;

                -- stop once we've emitted enough
                EXIT WHEN count_posts >= max_posts;
            END LOOP;

        ELSE   /* ---------- full-vector path (original query) ---------- */

            sql := format($q$
                SELECT hpv.post_id, hpv.chunk_number, %s AS similarity
                  FROM hivesense_app.posts_vectors hpv
                  JOIN hivemind_app.hive_posts hp ON hp.id = hpv.post_id
                 WHERE ($2 IS NULL OR hpv.post_id <> $2)
                   AND ($3 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $3
                            AND m.muted_id    = hp.author_id))
                 ORDER BY similarity, hpv.post_id
                 LIMIT %s
            $q$, dist_full, batch_size);

            FOR rec IN EXECUTE sql
                USING _embedding,               -- $1
                      _exclude_post_id,         -- $2
                      _observer_id              -- $3
            LOOP
                rows_fetched := rows_fetched + 1;

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
                RETURN NEXT (count_posts, rec.similarity, rec.post_id, rec.chunk_number)::hivesense_app.similar_post_result;

                -- stop once we've emitted enough
                EXIT WHEN count_posts >= max_posts;
            END LOOP;

        END IF;

        /* ---------- stop / expand batch logic ---------- */
        EXIT WHEN count_posts >= max_posts;
        -- fewer rows than requested means the candidate set is exhausted
        -- (or capped by ef_search); a larger batch cannot yield new rows
        -- and doubling would run until integer overflow
        EXIT WHEN rows_fetched < batch_size;
        batch_size := batch_size * 2;
    END LOOP;
END;
$$;


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

    IF __post_embedding IS NULL THEN
        RAISE EXCEPTION
          'Post @%/% has no stored embedding (too short or not yet processed)',
          _author, _permlink;
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
    default_ef   int := (SELECT default_ef_search FROM hivesense_app.hivesense_app_status LIMIT 1);
    minimum_ann_candidates int := (SELECT minimum_ann_candidates FROM hivesense_app.hivesense_app_status LIMIT 1);
    allow_dbg    boolean := hivesense_app.allow_debugging();
    req_headers        jsonb := current_setting('request.headers', true)::jsonb;
    batch_multiplier   int := 10;  -- higher for authors since we need more candidates
    exploratory_factor int := default_ef;
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
        batch_multiplier   := COALESCE((req_headers->>'x-batch-size-multiplier')::int,
                                       batch_multiplier);
        exploratory_factor := COALESCE((req_headers->>'x-exploratory-factor')::int,
                                       exploratory_factor);
        exhaustive := lower(coalesce(req_headers->>'x-exhaustive-search','false')) = 'true';
    END IF;

    ann_candidates := LEAST(_limit * batch_multiplier, 50000);
    IF allow_dbg THEN
        ann_candidates := COALESCE((req_headers->>'x-ann-candidates')::int,
                                   ann_candidates);
    END IF;
    ann_candidates := GREATEST(ann_candidates, minimum_ann_candidates);

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
                       hp.author_id,
                       %s AS ann_dist
                  FROM hivesense_app.posts_vectors pv
                  JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
                  JOIN hivesense_app.post_data pd ON pd.post_id = pv.post_id
                 WHERE (%L OR pd.number_of_tokens >= %s)
                   AND ($3 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $3
                            AND m.muted_id    = hp.author_id))
                 ORDER BY ann_dist, pv.post_id
                 LIMIT %s
            ),
            reranked AS (
                SELECT ann.author_id,
                       ann.post_id,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM ann
                  JOIN hivesense_app.posts_vectors pv
                    ON pv.post_id = ann.post_id
                   AND pv.chunk_number = ann.chunk_number
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
          (__min_search_tokens = 0),    -- %L  token filter off?
          __min_search_tokens,          -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red, _observer_id;

    ELSIF use_reduced THEN
        -- PCA: ANN on posts_vectors_reduced, rerank with full embedding
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pr.post_id,
                       pr.chunk_number,
                       hp.author_id,
                       %s AS ann_dist
                  FROM hivesense_app.posts_vectors_reduced pr
                  JOIN hivemind_app.hive_posts hp ON hp.id = pr.post_id
                  JOIN hivesense_app.post_data pd ON pd.post_id = pr.post_id
                 WHERE (%L OR pd.number_of_tokens >= %s)
                   AND ($3 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $3
                            AND m.muted_id    = hp.author_id))
                 ORDER BY ann_dist, pr.post_id
                 LIMIT %s
            ),
            reranked AS (
                SELECT ann.author_id,
                       ann.post_id,
                       (pv.embedding <=> $1)::float4 AS sim
                  FROM ann
                  JOIN hivesense_app.posts_vectors pv
                    ON pv.post_id = ann.post_id
                   AND pv.chunk_number = ann.chunk_number
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
          (__min_search_tokens = 0),    -- %L  token filter off?
          __min_search_tokens,          -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, query_red, _observer_id;

    ELSE   /* ───────── full-vector path ───────── */
        RETURN QUERY EXECUTE format($q$
            WITH ann AS (
                SELECT pv.post_id,
                       pv.chunk_number,
                       hp.author_id,
                       %s AS sim
                  FROM hivesense_app.posts_vectors pv
                  JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
                  JOIN hivesense_app.post_data pd ON pd.post_id = pv.post_id
                 WHERE (%L OR pd.number_of_tokens >= %s)
                   AND ($2 = 0 OR NOT EXISTS (
                         SELECT 1 FROM hivemind_app.muted_accounts_by_id_view m
                          WHERE m.observer_id = $2
                            AND m.muted_id    = hp.author_id))
                 ORDER BY sim, pv.post_id
                 LIMIT %s
            ),
            ranked AS (
                SELECT author_id,
                       sim,
                       row_number() OVER (ORDER BY sim) AS rn
                  FROM ann
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
          (__min_search_tokens = 0),    -- %L  token filter off?
          __min_search_tokens,          -- %s
          ann_candidates,               -- %s
          _limit                        -- %s
        )
        USING _embedding, _observer_id;
    END IF;
END;
$BODY$;

RESET ROLE

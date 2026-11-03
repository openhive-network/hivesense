#!/bin/sh

# Functional search tests for hivesense in the CI test environment.
# Exercises the public API endpoints and the internal search functions
# under the currently-installed embedding configuration. Run once per
# configuration after the app is synced (see reconfigure-hivesense.sh).
#
# Usage: hivesense_search_test.sh --mode=none|pca|slice
#
# All checks are executed even if earlier ones fail; the script exits
# nonzero at the end if any check failed.

SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)
COMPOSE_DIR="${SCRIPTPATH}/../../../docker/ci"

MODE=""
for arg in "$@"; do
  case "$arg" in
    --mode=*)
        MODE="${arg#*=}"
        ;;
    *)
        echo "Usage: $0 --mode=none|pca|slice"
        exit 2
        ;;
  esac
done

case "$MODE" in
  none|pca|slice) ;;
  *)
    echo "Usage: $0 --mode=none|pca|slice"
    exit 2
    ;;
esac

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES+1))
}

pass() {
  echo "ok: $1"
}

query_database() {
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf \
    psql -U haf_admin -q -A -t -d haf_block_log -c "$1" | tr -d '[:space:]'
}

# Endpoint requests go through the postgrest rewriter, same as production
# traffic; issued from the caddy container which is on the compose network.
http_get() {
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy \
    wget -qO - "http://hivesense-postgrest-rewriter${1}"
}

# Status line and headers of a response, for any status code. Not `nc`:
# busybox nc exits as soon as its stdin reaches EOF, before the reply arrives,
# so the request pipe reads nothing. Not `wget -S`: busybox wget stops before
# printing the headers of a 4xx/5xx response, which would make the error-case
# check pass vacuously.
http_head() {
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy \
    curl -s -m 60 -D - -o /dev/null "http://hivesense-postgrest-rewriter:80${1}" |
    tr -d '\r' | sed '/^$/q'
}

# expect_cache_control NAME PATH STATUS_PATTERN CACHE_CONTROL
# An empty CACHE_CONTROL asserts the header is absent.
expect_cache_control() {
  response_head=$(http_head "$2")
  status=$(echo "$response_head" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')
  actual=$(echo "$response_head" | sed -n 's/^[Cc]ache-[Cc]ontrol:[[:space:]]*//p')
  # shellcheck disable=SC2254
  case "$status" in
    $3) ;;
    *)
      fail "$1 answered HTTP '${status}', expected ${3}"
      return
      ;;
  esac
  if [ "$actual" = "$4" ]; then
    pass "$1 (HTTP ${status}) sends Cache-Control '${4}'"
  else
    fail "$1 (HTTP ${status}) sends Cache-Control '${actual}', expected '${4}'"
  fi
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

echo "=== hivesense search tests (mode: ${MODE}) ==="

# ─── 1. installed configuration matches the expectation ───────────────
actual_mode=$(query_database "SELECT hivesense_app.reduction_mode()")
if [ "$actual_mode" = "$MODE" ]; then
  pass "reduction_mode() = ${MODE}"
else
  fail "reduction_mode() is '${actual_mode}', expected '${MODE}'"
fi

expected_reduced=t
if [ "$MODE" = "none" ]; then
  expected_reduced=f
fi
actual_reduced=$(query_database "SELECT hivesense_app.use_reduced_embeddings()")
if [ "$actual_reduced" = "$expected_reduced" ]; then
  pass "use_reduced_embeddings() = ${expected_reduced}"
else
  fail "use_reduced_embeddings() is '${actual_reduced}', expected '${expected_reduced}'"
fi

# ─── 2. the HNSW index for this configuration exists ──────────────────
case "$MODE" in
  none)  expected_index=posts_vectors_embedding_full_hnsw ;;
  pca)   expected_index=posts_vectors_reduced_reduced_embedding_full_hnsw ;;
  slice) expected_index=posts_vectors_embedding_slice_hnsw ;;
esac
index_name=$(query_database "SELECT hivesense_app.get_hnsw_index_name()")
if [ "$index_name" = "$expected_index" ]; then
  pass "index name is ${expected_index}"
else
  fail "get_hnsw_index_name() is '${index_name}', expected '${expected_index}'"
fi

index_exists=$(query_database "SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'i' AND n.nspname = 'hivesense_app' AND c.relname = '${expected_index}')")
if [ "$index_exists" = "t" ]; then
  pass "index ${expected_index} exists"
else
  fail "index ${expected_index} does not exist"
fi

# ─── 3. mode-specific storage assertions ───────────────────────────────
chunk_count=$(query_database "SELECT count(*) FROM hivesense_app.posts_vectors")
if [ "$MODE" = "pca" ]; then
  reduced_count=$(query_database "SELECT count(*) FROM hivesense_app.posts_vectors_reduced")
  if [ "$reduced_count" = "$chunk_count" ]; then
    pass "posts_vectors_reduced has all ${chunk_count} chunks"
  else
    fail "posts_vectors_reduced has ${reduced_count} rows, expected ${chunk_count}"
  fi
  matrix_rows=$(query_database "SELECT count(*) FROM hivesense_app.reducing_matrix")
  reduced_dims=$(query_database "SELECT hivesense_app.reduced_dims()")
  if [ "$matrix_rows" = "$reduced_dims" ]; then
    pass "reducing_matrix has ${reduced_dims} rows"
  else
    fail "reducing_matrix has ${matrix_rows} rows, expected ${reduced_dims}"
  fi
fi

# ─── 4. public API endpoints return results ────────────────────────────
body=$(http_get "/posts/search?q=introduce%20yourself&result_limit=10")
if echo "$body" | grep -q '"author"'; then
  pass "/posts/search returns posts"
else
  fail "/posts/search returned no posts: $(echo "$body" | head -c 300)"
fi

sample_post_query="
  SELECT ha.name || '/' || hpd.permlink
    FROM hivesense_app.posts_vectors pv
    JOIN hivemind_app.hive_posts hp          ON hp.id  = pv.post_id
    JOIN hivemind_app.hive_accounts ha       ON ha.id  = hp.author_id
    JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
   ORDER BY pv.post_id
   LIMIT 1"
sample_post=$(query_database "$sample_post_query")
body=$(http_get "/posts/${sample_post}/similar?result_limit=5")
if echo "$body" | grep -q '"author"'; then
  pass "/posts/{author}/{permlink}/similar returns posts"
else
  fail "/posts/${sample_post}/similar returned no posts: $(echo "$body" | head -c 300)"
fi

body=$(http_get "/authors/search?topic=blockchain&result_limit=5")
if echo "$body" | grep -q '"'; then
  pass "/authors/search returns authors"
else
  fail "/authors/search returned no authors: $(echo "$body" | head -c 300)"
fi

# ─── 5. edge-cache headers ─────────────────────────────────────────────
expect_cache_control "/posts/search" "/posts/search?q=hive&result_limit=1&full_posts=0" 200 "public, max-age=60"
expect_cache_control "/posts/{author}/{permlink}/similar" "/posts/${sample_post}/similar?result_limit=5" 200 "public, max-age=300"
expect_cache_control "/authors/search" "/authors/search?topic=blockchain&result_limit=5" 200 "public, max-age=60"
expect_cache_control "/posts/search error response" "/posts/search?q=hive&result_limit=0" "[45]??" ""
expect_cache_control "/posts/{author}/{permlink}/similar error response" "/posts/${sample_post}/similar?result_limit=0" "[45]??" ""
expect_cache_control "/sync-status" "/sync-status" 200 "public, max-age=0"

# ─── 6. internal search functions ──────────────────────────────────────
# Reference embedding for the check below (store_halfvec is off in CI)
ref_embedding="(SELECT embedding::public.vector FROM hivesense_app.posts_vectors ORDER BY post_id, chunk_number LIMIT 1)"

count=$(query_database "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 10)")
if is_number "$count" && [ "$count" -ge 1 ]; then
  pass "one-shot search returns results (${count})"
else
  fail "one-shot search returned '${count}', expected >= 1"
fi

# ─── 7. ANN sized to the requested limit ───────────────────────────────
# Default tunables: ef_search = clamp(limit * 10, 60, 500), candidates = ef.
for pair in 3:60 10:100 20:200 100:500 1000:500; do
  limit=${pair%:*}
  expected_ef=${pair#*:}
  sizing=$(query_database "SELECT ef_search || ',' || ann_candidates FROM hivesense_app.ann_search_size(${limit})")
  if [ "$sizing" = "${expected_ef},${expected_ef}" ]; then
    pass "limit ${limit} sizes ef_search and candidates to ${expected_ef}"
  else
    fail "limit ${limit} sizes ef_search,candidates to '${sizing}', expected ${expected_ef},${expected_ef}"
  fi
done

# The search must run with that ef_search, and return no more than asked for.
for pair in 3:60 100:500; do
  limit=${pair%:*}
  expected_ef=${pair#*:}
  got=$(query_database "
    WITH r AS MATERIALIZED (
      SELECT * FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, ${limit}))
    SELECT (SELECT count(*) FROM r) || ',' || current_setting('hnsw.ef_search')")
  count=${got%,*}
  ef=${got#*,}
  if is_number "$count" && [ "$count" -ge 1 ] && [ "$count" -le "$limit" ] && [ "$ef" = "$expected_ef" ]; then
    pass "one-shot search with limit ${limit} returns ${count} results at ef_search ${ef}"
  else
    fail "one-shot search with limit ${limit} returned count,ef_search '${got}', expected 1..${limit},${expected_ef}"
  fi
done

# ─── 8. candidate filters are only built when they can remove a row ────
token_threshold=$(query_database "SELECT min_token_search_threshold FROM hivesense_app.hivesense_app_status WHERE id = 1")
if [ "$token_threshold" = "0" ]; then
  filter=$(query_database "SELECT hivesense_app.ann_candidate_filter('pv', NULL, 0)")
  if [ -z "$filter" ]; then
    pass "anonymous search without a token threshold filters nothing"
  else
    fail "anonymous search without a token threshold filters '${filter}'"
  fi
fi

# An observer that mutes the author of the reference post never sees it,
# although it is the post's own nearest neighbour.
muted_pair=$(query_database "
  SELECT m.observer_id || ',' || pv.post_id || ':' || pv.chunk_number
    FROM hivemind_app.muted_accounts_by_id_view m
    JOIN hivemind_app.hive_posts hp ON hp.author_id = m.muted_id
    JOIN hivesense_app.posts_vectors pv ON pv.post_id = hp.id
   LIMIT 1")
if [ -n "$muted_pair" ]; then
  observer=${muted_pair%,*}
  muted_chunk=${muted_pair#*,}
  muted_post=${muted_chunk%:*}
  muted_embedding="(SELECT embedding::public.vector FROM hivesense_app.posts_vectors WHERE post_id = ${muted_post} AND chunk_number = ${muted_chunk#*:})"
  unmuted=$(query_database "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${muted_embedding}, 3) WHERE post_id = ${muted_post}")
  muted=$(query_database "
    SELECT count(*)
      FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${muted_embedding}, 3, _observer_id => ${observer}) r
      JOIN hivemind_app.hive_posts hp ON hp.id = r.post_id
      JOIN hivemind_app.muted_accounts_by_id_view m ON m.muted_id = hp.author_id AND m.observer_id = ${observer}")
  if [ "$unmuted" = "1" ] && [ "$muted" = "0" ]; then
    pass "observer ${observer} does not see posts of accounts it mutes"
  else
    fail "post ${muted_post}: found ${unmuted} time(s) without observer (expected 1), ${muted} muted result(s) for observer ${observer} (expected 0)"
  fi
else
  echo "skip: no observer mutes an author of an embedded post"
fi

# ─── 9. block processing drops the vectors of a post hivemind deleted ──
# Rolled back: an embedded post is deleted the way hivemind does it
# (counter_deleted > 0, block_num = the deleting block, kept as it is here) and
# put through the block processor's prepare/store steps with nothing embedded.
# Prints in_range,chunks,vectors_left,fresh_tombstones.
deleted=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf \
  psql -U haf_admin -q -A -t -v ON_ERROR_STOP=on -d haf_block_log <<'SQL' | tr -d '[:space:]'
BEGIN;
SET LOCAL session_replication_role = replica;
CREATE TEMP TABLE t_victim ON COMMIT DROP AS
SELECT
    pv.post_id,
    GREATEST(hp.block_num_created, hp.block_num) AS blk,
    (SELECT MAX(sync_seq) FROM hivesense_app.posts_vectors) AS seq_before
FROM hivesense_app.posts_vectors AS pv
INNER JOIN hivemind_app.hive_posts AS hp ON pv.post_id = hp.id
ORDER BY pv.post_id
LIMIT 1;
UPDATE hivemind_app.hive_posts AS hp SET counter_deleted = 1
FROM t_victim AS v WHERE hp.id = v.post_id;
SET LOCAL session_replication_role = origin;
CREATE TEMP TABLE t_chunks ON COMMIT DROP AS
SELECT c.* FROM t_victim AS v
CROSS JOIN LATERAL hivesense_app.prepare_post_chunks(ARRAY[v.post_id]) AS c;
CREATE TEMP TABLE tmp_vectors (post_id INT, chunk_number INT, vec PUBLIC.VECTOR) ON COMMIT DROP;
SELECT COUNT(*) FROM hivesense_app.store_post_embeddings() \g /dev/null
SELECT
    (v.post_id = ANY(hivesense_app.posts_in_range(v.blk, v.blk)))::TEXT
    || ',' || (SELECT COUNT(*) FROM t_chunks)
    || ',' || (SELECT COUNT(*) FROM hivesense_app.posts_vectors AS pv WHERE pv.post_id = v.post_id)
    || ',' || (SELECT COUNT(*) FROM hivesense_app.deleted_embeddings AS de WHERE de.post_id = v.post_id AND de.sync_seq > v.seq_before)
FROM t_victim AS v;
ROLLBACK;
SQL
)
if [ "$deleted" = "true,0,0,1" ]; then
  pass "a deleted post yields no chunks, loses its vectors and gets one fresh tombstone"
else
  fail "deleted post in block processing: in_range,chunks,vectors_left,fresh_tombstones = '${deleted}', expected true,0,0,1"
fi

# ─── summary ───────────────────────────────────────────────────────────
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} search test(s) failed (mode: ${MODE})" >&2
  exit 1
fi
echo "All search tests passed (mode: ${MODE})"

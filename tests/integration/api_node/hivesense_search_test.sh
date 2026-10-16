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

# ─── 5. internal search functions ──────────────────────────────────────
# Reference embedding for the check below (store_halfvec is off in CI)
ref_embedding="(SELECT embedding::public.vector FROM hivesense_app.posts_vectors ORDER BY post_id, chunk_number LIMIT 1)"

count=$(query_database "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 10)")
if is_number "$count" && [ "$count" -ge 1 ]; then
  pass "one-shot search returns results (${count})"
else
  fail "one-shot search returned '${count}', expected >= 1"
fi

# ─── summary ───────────────────────────────────────────────────────────
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} search test(s) failed (mode: ${MODE})" >&2
  exit 1
fi
echo "All search tests passed (mode: ${MODE})"

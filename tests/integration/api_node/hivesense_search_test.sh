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

# Runs $1 (setup statements) and then $2 (a SELECT) in ONE transaction that is
# always rolled back, so a check can squeeze a tunable or mark a post deleted
# without leaving a trace. Prints only the SELECT's result (-q hides command
# tags); ON_ERROR_STOP makes a failing setup yield empty output, which every
# caller treats as a failure. lock_timeout bounds any wait for a lock (some
# setups take an exclusive lock on hive_posts): a busy table fails the check
# instead of hanging the job.
query_database_rolled_back() {
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf \
    psql -U haf_admin -q -A -t -d haf_block_log -v ON_ERROR_STOP=1 \
      -c "BEGIN" -c "SET LOCAL lock_timeout = '15s'" -c "$1" -c "$2" -c "ROLLBACK" | tr -d '[:space:]'
}

# Like query_database, but keeps stderr, so a check can assert on the error
# text itself rather than on an empty result.
query_database_with_errors() {
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf \
    psql -U haf_admin -q -A -t -d haf_block_log -c "$1" 2>&1
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
# Reference embedding reused by all checks below (store_halfvec is off in CI)
ref_embedding="(SELECT embedding::public.vector FROM hivesense_app.posts_vectors ORDER BY post_id, chunk_number LIMIT 1)"

count=$(query_database "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 10)")
if is_number "$count" && [ "$count" -ge 1 ]; then
  pass "one-shot search returns results (${count})"
else
  fail "one-shot search returned '${count}', expected >= 1"
fi

# Paging variant, small limit. In slice mode this is the issue #56
# regression: the slice branch was missing its execution loop, so the call
# errored with 'integer out of range' instead of returning rows.
count=$(query_database "SET statement_timeout = '300s'; SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding(${ref_embedding}, 10)")
if is_number "$count" && [ "$count" -eq 10 ]; then
  pass "paging search returns results (${count}) [issue #56]"
else
  fail "paging search returned '${count}', expected 10 [issue #56 regression]"
fi

# Paging variant with a limit larger than the corpus: the batch-doubling
# retry loop must detect that the candidate set is exhausted and return
# what exists instead of doubling batch_size until integer overflow.
post_count=$(query_database "SELECT count(DISTINCT post_id) FROM hivesense_app.posts_vectors")
count=$(query_database "SET statement_timeout = '300s'; SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding(${ref_embedding}, 1000)")
if is_number "$count" && [ "$count" -ge 1 ] && [ "$count" -le "$post_count" ]; then
  pass "paging search with limit > corpus returns results (${count} of ${post_count} posts)"
else
  fail "paging search with limit > corpus returned '${count}' (${post_count} posts exist): batch-size overflow?"
fi

# Paging continuation: page 2 starting after the 2nd result must equal
# results 3-5 of page 1 (the ANN ordering is deterministic).
page1=$(query_database "SELECT string_agg(post_id::text, ',' ORDER BY similarity_order) FROM hivesense_app.find_nearest_posts_with_embedding(${ref_embedding}, 5)")
start_id=$(echo "$page1" | cut -d, -f2)
expected_page2=$(echo "$page1" | cut -d, -f3-5)
page2=$(query_database "SELECT string_agg(post_id::text, ',' ORDER BY similarity_order) FROM hivesense_app.find_nearest_posts_with_embedding(${ref_embedding}, 3, NULL, 0, ${start_id:-0})")
if [ -n "$expected_page2" ] && [ "$page2" = "$expected_page2" ]; then
  pass "paging continuation from post ${start_id} returns [${page2}]"
else
  fail "paging continuation returned [${page2}], expected [${expected_page2}]"
fi

# ─── 6. author filter on /posts/search (#47) ──────────────────────────
# The author branch must rank ALL of one author's posts, not filter the
# vector index's candidates: an HNSW scan returns only its nearest few
# hundred chunks, so "ANN + WHERE author" silently loses posts. Every
# check compares against an oracle computed straight from the tables.
test_author_id=$(query_database "
  SELECT hp.author_id
    FROM hivemind_app.hive_posts hp
   WHERE hp.depth = 0 AND hp.counter_deleted = 0
     AND EXISTS (SELECT 1 FROM hivesense_app.posts_vectors pv WHERE pv.post_id = hp.id)
   GROUP BY hp.author_id
   ORDER BY count(*) DESC, hp.author_id
   LIMIT 1")
test_author=$(query_database "SELECT name FROM hivemind_app.hive_accounts WHERE id = ${test_author_id:-0}")
# Posts of that author the filter must return: live root posts with an
# embedding that pass the same token threshold as the search itself.
author_oracle=$(query_database "
  SELECT count(*)
    FROM hivemind_app.hive_posts hp
    JOIN hivesense_app.post_data pd ON pd.post_id = hp.id
   WHERE hp.author_id = ${test_author_id:-0} AND hp.depth = 0 AND hp.counter_deleted = 0
     AND EXISTS (SELECT 1 FROM hivesense_app.posts_vectors pv WHERE pv.post_id = hp.id)
     AND pd.number_of_tokens >= (SELECT min_token_search_threshold
                                   FROM hivesense_app.hivesense_app_status WHERE id = 1)")

if ! is_number "$test_author_id" || [ -z "$test_author" ] || ! is_number "$author_oracle" || [ "$author_oracle" -lt 2 ]; then
  fail "author filter: no test author with >= 2 embedded posts (id '${test_author_id}', name '${test_author}', posts '${author_oracle}') -- the checks below could not run"
else
  # count / distinct posts / rows by anyone else
  author_rows="SELECT count(*) || '/' || count(DISTINCT r.post_id) || '/' || count(*) FILTER (WHERE hp.author_id <> ${test_author_id})
                 FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 1000, NULL, 0, ${test_author_id}) r
                 JOIN hivemind_app.hive_posts hp ON hp.id = r.post_id"
  expected="${author_oracle}/${author_oracle}/0"

  got=$(query_database "$author_rows")
  if [ "$got" = "$expected" ]; then
    pass "author filter returns exactly @${test_author}'s ${author_oracle} posts, once each"
  else
    fail "author filter for @${test_author}: count/distinct/others = '${got}', expected '${expected}'"
  fi

  # Same call with the planner pushed onto the vector index and that index
  # squeezed to one candidate, so a filter bolted onto the ANN stage would
  # see at most one chunk. On this small corpus the planner otherwise
  # answers "ANN + WHERE author" exactly by walking hivemind's author index
  # -- a naive version passes the check above -- so, inside the rolled-back
  # transaction, every hive_posts index containing author_id is dropped,
  # seq scans and sorts are penalised, and pgvector's iterative scan is
  # capped at one tuple (with iterative scan the index would walk this whole
  # small graph and answer exactly again). The author branch stays exact (it
  # just scans hive_posts for the ids); the ANN path cannot.
  force_ann="UPDATE hivesense_app.hivesense_app_status SET default_ef_search = 1, minimum_ann_candidates = 1 WHERE id = 1;
    DO \$\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT i.indexrelid::regclass::text AS idx, c.conname
                 FROM pg_index i
                 JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                 LEFT JOIN pg_constraint c ON c.conindid = i.indexrelid AND c.conrelid = i.indrelid
                WHERE i.indrelid = 'hivemind_app.hive_posts'::regclass AND a.attname = 'author_id'
      LOOP
        IF r.conname IS NOT NULL THEN
          EXECUTE format('ALTER TABLE hivemind_app.hive_posts DROP CONSTRAINT %I', r.conname);
        ELSE
          EXECUTE 'DROP INDEX ' || r.idx;
        END IF;
      END LOOP;
    END \$\$;
    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_sort = off;
    SET LOCAL hnsw.max_scan_tuples = 1"

  # The forcing has to work, or the check proves nothing: under it the
  # unfiltered search must come back with at most one post.
  forced=$(query_database_rolled_back "$force_ann" \
    "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 5)")
  if ! is_number "$forced" || [ "$forced" -gt 1 ]; then
    fail "could not force the vector index for the budget check (unfiltered search returned '${forced}' under a 1-candidate budget, expected <= 1)"
  else
    got=$(query_database_rolled_back "$force_ann" "$author_rows")
    if [ "$got" = "$expected" ]; then
      pass "author filter stays exact with the planner forced onto a 1-candidate vector index"
    else
      fail "author filter with the planner forced onto a 1-candidate vector index: '${got}', expected '${expected}' -- it is going through the vector index"
    fi
  fi

  # Exact ranking: top 3 equal a brute-force ranking by best chunk.
  top3=$(query_database "SELECT string_agg(post_id::text, ',' ORDER BY similarity_order)
                           FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 3, NULL, 0, ${test_author_id})")
  expected_top=$(query_database "
    SELECT string_agg(post_id::text, ',' ORDER BY d, post_id) FROM (
      SELECT pv.post_id, min((pv.embedding <=> ${ref_embedding})::float4) AS d
        FROM hivemind_app.hive_posts hp
        JOIN hivesense_app.posts_vectors pv ON pv.post_id = hp.id
        JOIN hivesense_app.post_data pd     ON pd.post_id = hp.id
       WHERE hp.author_id = ${test_author_id} AND hp.depth = 0 AND hp.counter_deleted = 0
         AND pd.number_of_tokens >= (SELECT min_token_search_threshold
                                       FROM hivesense_app.hivesense_app_status WHERE id = 1)
       GROUP BY pv.post_id ORDER BY d, pv.post_id LIMIT 3) x")
  if [ -n "$expected_top" ] && [ "$top3" = "$expected_top" ]; then
    pass "author filter ranks exactly (top 3: ${top3})"
  else
    fail "author filter top 3 = '${top3}', brute force says '${expected_top}'"
  fi

  # A deleted post disappears from the author filter. The CI corpus has no
  # deleted posts, so the author's best match is marked deleted inside a
  # rolled-back transaction.
  top_post=$(echo "$top3" | cut -d, -f1)
  if is_number "$top_post"; then
    got=$(query_database_rolled_back \
      "UPDATE hivemind_app.hive_posts SET counter_deleted = 1 WHERE id = ${top_post}" \
      "SELECT count(*) || '/' || count(*) FILTER (WHERE post_id = ${top_post})
         FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 1000, NULL, 0, ${test_author_id})")
    if [ "$got" = "$((author_oracle - 1))/0" ]; then
      pass "author filter drops a deleted post"
    else
      fail "author filter with post ${top_post} deleted: count/that-post = '${got}', expected '$((author_oracle - 1))/0'"
    fi
  else
    fail "author filter: no top post to delete ('${top3}')"
  fi

  # The token threshold applies inside the author branch too. CI runs with a
  # threshold of 0, which makes the clause vacuous, so it is raised (rolled
  # back) to the author's largest token count and compared with an oracle at
  # that threshold -- which must keep some posts and drop others.
  token_max=$(query_database "
    SELECT max(pd.number_of_tokens)
      FROM hivemind_app.hive_posts hp JOIN hivesense_app.post_data pd ON pd.post_id = hp.id
     WHERE hp.author_id = ${test_author_id} AND hp.depth = 0 AND hp.counter_deleted = 0
       AND EXISTS (SELECT 1 FROM hivesense_app.posts_vectors pv WHERE pv.post_id = hp.id)")
  token_oracle=$(query_database "
    SELECT count(*)
      FROM hivemind_app.hive_posts hp JOIN hivesense_app.post_data pd ON pd.post_id = hp.id
     WHERE hp.author_id = ${test_author_id} AND hp.depth = 0 AND hp.counter_deleted = 0
       AND EXISTS (SELECT 1 FROM hivesense_app.posts_vectors pv WHERE pv.post_id = hp.id)
       AND pd.number_of_tokens >= ${token_max:-0}")
  if ! is_number "$token_max" || ! is_number "$token_oracle" || [ "$token_oracle" -lt 1 ] || [ "$token_oracle" -ge "$author_oracle" ]; then
    fail "token-threshold check could not be set up (threshold '${token_max}' keeps '${token_oracle}' of ${author_oracle} posts; need 1..$((author_oracle - 1)))"
  else
    got=$(query_database_rolled_back \
      "UPDATE hivesense_app.hivesense_app_status SET min_token_search_threshold = ${token_max} WHERE id = 1" \
      "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 1000, NULL, 0, ${test_author_id})")
    if [ "$got" = "$token_oracle" ]; then
      pass "author filter applies the token threshold (${token_oracle} of ${author_oracle} posts at ${token_max} tokens)"
    else
      fail "author filter at a ${token_max}-token threshold returned '${got}', expected ${token_oracle}"
    fi
  fi

  # Mutes: an observer who has not muted the author gets every post, one who
  # has gets nothing. The CI corpus has no mutes, so the mute row is inserted
  # inside a rolled-back transaction.
  observer_id=$(query_database "SELECT id FROM hivemind_app.hive_accounts WHERE id > 0 AND id <> ${test_author_id} ORDER BY id LIMIT 1")
  pre_muted=$(query_database "SELECT count(*) FROM hivemind_app.muted_accounts_by_id_view WHERE observer_id = ${observer_id:-0} AND muted_id = ${test_author_id}")
  if ! is_number "$observer_id" || [ "$pre_muted" != "0" ]; then
    fail "mute checks could not be set up (observer '${observer_id}', already muted: '${pre_muted}')"
  else
    got=$(query_database "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 1000, NULL, ${observer_id}, ${test_author_id})")
    if [ "$got" = "$author_oracle" ]; then
      pass "author filter is unaffected by an observer who has not muted the author"
    else
      fail "author filter with a non-muting observer returned '${got}', expected ${author_oracle}"
    fi
    got=$(query_database_rolled_back \
      "INSERT INTO hivemind_app.muted (follower, following, block_num) VALUES (${observer_id}, ${test_author_id}, 1)" \
      "SELECT count(*) FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 1000, NULL, ${observer_id}, ${test_author_id})")
    if [ "$got" = "0" ]; then
      pass "author filter returns nothing to an observer who muted the author"
    else
      fail "author filter for an observer who muted the author returned '${got}', expected 0"
    fi
  fi

  # Through the rewriter: author= reaches the function, and with full_posts=0
  # every entry is an author/permlink stub by the requested author.
  author_re=$(printf '%s' "$test_author" | sed 's/[.]/\\./g')
  body=$(http_get "/posts/search?q=introduce%20yourself&author=${test_author}&result_limit=1000&full_posts=0")
  all_entries=$(printf '%s' "$body" | grep -o '"author": *"[^"]*"' | wc -l | tr -d '[:space:]')
  own_entries=$(printf '%s' "$body" | grep -o "\"author\": *\"${author_re}\"" | wc -l | tr -d '[:space:]')
  if [ "$all_entries" = "$author_oracle" ] && [ "$own_entries" = "$author_oracle" ]; then
    pass "/posts/search?author=${test_author} returns ${own_entries} stubs, all by that author"
  else
    fail "/posts/search?author=${test_author}: ${all_entries} entries, ${own_entries} by the author, expected ${author_oracle}: $(printf '%s' "$body" | head -c 300)"
  fi

  body=$(http_get "/posts/search?q=introduce%20yourself&author=${test_author}&result_limit=2&full_posts=2")
  full_own=$(printf '%s' "$body" | grep -o "\"author\": *\"${author_re}\"" | wc -l | tr -d '[:space:]')
  full_bodies=$(printf '%s' "$body" | grep -o '"body": *"' | wc -l | tr -d '[:space:]')
  if [ "$full_bodies" = "2" ] && is_number "$full_own" && [ "$full_own" -ge 2 ]; then
    pass "/posts/search?author=... returns 2 full post objects when full_posts=2"
  else
    fail "/posts/search?author=${test_author}&full_posts=2 returned: $(printf '%s' "$body" | head -c 300)"
  fi
fi

# An existing account with nothing embedded: exactly [], not an error.
quiet_author=$(query_database "
  SELECT ha.name FROM hivemind_app.hive_accounts ha
   WHERE ha.name ~ '^[a-z][a-z0-9.-]{2,15}$'
     AND NOT EXISTS (SELECT 1 FROM hivemind_app.hive_posts hp
                       JOIN hivesense_app.posts_vectors pv ON pv.post_id = hp.id
                      WHERE hp.author_id = ha.id)
   ORDER BY ha.id LIMIT 1")
if [ -z "$quiet_author" ]; then
  fail "author filter: found no existing account without embedded posts to test []"
else
  body=$(http_get "/posts/search?q=introduce%20yourself&author=${quiet_author}" | tr -d '[:space:]')
  if [ "$body" = "[]" ]; then
    pass "/posts/search?author=${quiet_author} (nothing embedded) returns []"
  else
    fail "/posts/search?author=${quiet_author} (nothing embedded) returned '$(printf '%s' "$body" | head -c 300)', expected []"
  fi
fi

# An unknown account is an error naming it. Asserted on the SQL error text:
# the HTTP helper prints nothing for any non-2xx response, so an empty body
# would "pass" for a missing function or a crashed rewriter too.
missing_author="hivesense-nx"
exists=$(query_database "SELECT count(*) FROM hivemind_app.hive_accounts WHERE name = '${missing_author}'")
err=$(query_database_with_errors "SELECT hivesense_endpoints.posts_search(q => 'introduce yourself', author => '${missing_author}')")
if [ "$exists" = "0" ] && echo "$err" | grep -q "Account ${missing_author} does not exist"; then
  pass "author filter rejects an unknown account"
else
  fail "author filter, unknown account '${missing_author}' (exists: '${exists}'): $(echo "$err" | head -c 300)"
fi

# ... and through the rewriter that is a client error, not a 2xx or a 5xx.
status=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy \
  wget -S -q -O /dev/null "http://hivesense-postgrest-rewriter/posts/search?q=x&author=${missing_author}" 2>&1 \
  | grep -o 'HTTP/1\.[01] [0-9][0-9][0-9]' | tail -1)
case "$status" in
  HTTP/1.[01]\ 4[0-9][0-9]) pass "/posts/search?author=${missing_author} returns ${status#* }" ;;
  *) fail "/posts/search?author=${missing_author} returned status '${status}', expected 4xx" ;;
esac

# ─── 7. deleted posts are excluded from the unfiltered search ────────────
# Mark the unfiltered search's own best match deleted (rolled back) and it
# must drop out; first prove it is returned while live, or the check is empty.
top_live=$(query_database "SELECT post_id FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 10) ORDER BY similarity_order LIMIT 1")
if ! is_number "$top_live"; then
  fail "unfiltered search returned no top post to delete ('${top_live}')"
else
  got=$(query_database_rolled_back \
    "UPDATE hivemind_app.hive_posts SET counter_deleted = 1 WHERE id = ${top_live}" \
    "SELECT count(*) || '/' || count(*) FILTER (WHERE post_id = ${top_live})
       FROM hivesense_app.find_nearest_posts_with_embedding_one_shot(${ref_embedding}, 10)")
  if [ "${got#*/}" = "0" ] && is_number "${got%/*}" && [ "${got%/*}" -ge 1 ]; then
    pass "unfiltered search drops a deleted post (post ${top_live})"
  else
    fail "unfiltered search with post ${top_live} deleted: count/that-post = '${got}', expected N/0"
  fi
fi

# ─── summary ───────────────────────────────────────────────────────────
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} search test(s) failed (mode: ${MODE})" >&2
  exit 1
fi
echo "All search tests passed (mode: ${MODE})"

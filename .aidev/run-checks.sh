#!/usr/bin/env bash
# The step functions are called indirectly, through `step`.
# shellcheck disable=SC2317,SC2329
# The checks AIDEV's verification slots run (.aidev/project.yaml), as one junit
# report per suite: each named step is a test case, its log the failure body.
#
#   .aidev/run-checks.sh <suite> <step>...
#
#   - shellcheck      ShellCheck at warning severity on every *.sh (the files CI's
#                     lint_bash_scripts checks), at default severity on .aidev/'s own
#   - sqlfluff        `sqlfluff lint` with the repository's .sqlfluff (CI's
#                     lint_sql_scripts, which fails on any violation)
#   - unit            tests/unit with python's unittest (no database, no network)
#   - sql-registered  every .sql file under db/ and endpoints/ is applied by
#                     scripts/install_app.sh (a file it misses never reaches a database)
#   - install         scripts/install_app.sh into the stack's HAF database
#                     (HIVESENSE_TEST_DB_HOST, default `haf`), which already has
#                     hivemind installed; then the block processor's start-up identity
#                     (init_local_sync_identity) and tests/test_sync_chains.sql
#   - reinstall       scripts/uninstall_app.sh, then install again
#   - embed-search    reinstall configured as CI's sync job (all-minilm:l6-v2, 384
#                     dims, the stack's `ollama`; token threshold 200), seed
#                     .aidev/seed_posts.sql, embed the seeded posts with
#                     generate_embeddings_for_posts, check what posts_vectors
#                     holds, then the embedding-backed calls of
#                     .aidev/hivesense_smoke.py (one junit case per call); finally
#                     reinstall as `install` does, so the steps after it see that state
#   - api-smoke       PostgREST over the installed schema, the calls in
#                     .aidev/hivesense_smoke.py; one junit case per call
#
# install, reinstall, embed-search and api-smoke need the HAF stack
# (.aidev/test-stack.compose.yml). Reports go to test-results/<suite>/: junit.xml
# (one case per step) plus embed-search.xml and api-smoke.xml.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

suite="${1:?usage: $0 <suite> <step>...}"; shift
out="test-results/$suite"
rm -rf "$out"; mkdir -p "$out"
cases="$out/cases.tsv"; : > "$cases"

DB_HOST="${HIVESENSE_TEST_DB_HOST:-haf}"
ADMIN_URL="postgresql://haf_admin@$DB_HOST/haf_block_log"
export HIVESENSE_TEST_USER_URL="postgresql://hivesense_user@$DB_HOST/haf_block_log"

status=0
# record CASES_FILE NAME RC SECONDS LOG
record() {
    if [ "$3" -eq 0 ]; then
        printf 'case\t%s\tpass\t%s\t\n' "$2" "$4" >> "$1"
    else
        printf 'case\t%s\tfail\t%s\texit %s\t%s\n' "$2" "$4" "$3" "$5" >> "$1"
    fi
}

step() {
    local name="$1"; shift
    local log="$out/$name.log" t0=$SECONDS rc=0
    echo "== $name" >&2
    "$@" > "$log" 2>&1 < /dev/null || rc=$?
    [ "$rc" -eq 0 ] || { status=1; tail -40 "$log" >&2; }
    record "$cases" "$name" "$rc" "$((SECONDS - t0))" "$log"
}

run_shellcheck() {
    shellcheck --version | head -2
    # The project's scripts carry notes (SC2015) today; warnings are the floor.
    find . -name .git -prune -o -name .aidev -prune -o -name test-results -prune -o -type f -name '*.sh' -print0 \
        | xargs -0 shellcheck -S warning -f gcc || return 1
    shellcheck -f gcc .aidev/*.sh .aidev/runtime/*.sh
}

run_sqlfluff() {
    sqlfluff --version
    sqlfluff lint --dialect postgres --nofail --format yaml --write-output "$out/sqlfluff.yaml" . || return 1
    if grep -q 'code:' "$out/sqlfluff.yaml"; then
        cat "$out/sqlfluff.yaml"
        return 1
    fi
    echo "no sqlfluff violations"
}

run_unit() {
    python3 -m unittest discover -v -s tests/unit -p 'test_*.py'
}

sql_registered() {
    local f missing=0
    while IFS= read -r f; do
        if ! grep -qF "\$SRCPATH/$f\"" scripts/install_app.sh; then
            echo "not applied by scripts/install_app.sh: $f"
            missing=1
        fi
    done < <(find db endpoints -name '*.sql' | sort)
    [ "$missing" -eq 0 ] && echo "every .sql file under db/ and endpoints/ is applied"
    return "$missing"
}

wait_for_db() {
    local i
    for i in $(seq 60); do
        psql "$ADMIN_URL" -Atc "select 1 from pg_namespace where nspname = 'hivemind_endpoints'" 2>/dev/null | grep -qx 1 && return 0
        echo "waiting for hivemind in $ADMIN_URL ($i)"
        sleep 5
    done
    echo "no hivemind_endpoints schema in $ADMIN_URL: is the stack up?"
    return 1
}

# install [INSTALL_APP_OPTION]...
install() {
    wait_for_db || return 1
    HIVESENSE_GIT_HASH="$(git rev-parse HEAD 2>/dev/null || echo aidev)" \
        bash scripts/install_app.sh --postgres-url="$ADMIN_URL" "$@" || return 1
    # What the block processor does at start-up; tests/test_sync_chains.sql
    # expects the primary chain's sync_uuid it mints.
    psql "$ADMIN_URL" -v ON_ERROR_STOP=on -Atc "select hivesense_app.init_local_sync_identity()" || return 1
    psql "$ADMIN_URL" -v ON_ERROR_STOP=on -f tests/test_sync_chains.sql
}

# reinstall [INSTALL_APP_OPTION]...
reinstall() {
    wait_for_db || return 1
    bash scripts/uninstall_app.sh --postgres-url="$ADMIN_URL" || return 1
    install "$@"
}

# The seeded posts (.aidev/seed_posts.sql) in block order; the last one is below
# the token threshold.
SEEDED_POSTS="{900101,900102,900103,900104,900105}"
EMBEDDED_POSTS="900101,900102,900103,900105"
OLLAMA_URL="http://ollama:11434"
EMBEDDING_MODEL="all-minilm:l6-v2"

# The runtime image has no curl. Without this, a dead server only shows as the
# sync path's unbounded retries in generate_embeddings_for_posts.
probe_embedding_server() {
    python3 - "$OLLAMA_URL" "$EMBEDDING_MODEL" <<'PY'
import json, sys, urllib.error, urllib.request
url, model = sys.argv[1:]
try:
    with urllib.request.urlopen(url + "/api/tags", timeout=10) as resp:
        names = [m.get("name") for m in json.load(resp).get("models", [])]
except (urllib.error.URLError, OSError, ValueError) as e:
    sys.exit(f"embedding server {url} did not answer: {e}")
if model not in names:
    sys.exit(f"embedding server {url} did not answer with {model}: it serves {names}")
print(f"embedding server {url} serves {model}")
PY
}

embed_seeded_posts() {
    local ids got
    probe_embedding_server || return 1
    # CI's embedding configuration (docker/ci/compose.yml hivesense-install-schema)
    # except the token threshold. all-MiniLM-L6-v2's tokenizer.json pads every
    # encode to 128 tokens and chunk_post counts per sentence, so no post counts
    # below CI's 75. 200 lies above a one-sentence post (128 padded, ~13 unpadded)
    # and below the long seeded posts (>= 2048 padded, >= 253 unpadded).
    reinstall --llm="$EMBEDDING_MODEL" --vector_size=384 --tokenizer-model=all-MiniLM-L6-v2 \
        --ollama="$OLLAMA_URL" --document-prefix= --query-prefix= --min-token-threshold=200 || return 1
    psql "$ADMIN_URL" -v ON_ERROR_STOP=on -f .aidev/seed_posts.sql || return 1
    ids="$(psql "$ADMIN_URL" -v ON_ERROR_STOP=on -Atc "select hivesense_app.posts_in_range(101, 105)")" || return 1
    if [ "$ids" != "$SEEDED_POSTS" ]; then
        echo "posts_in_range(101, 105) = $ids, expected the seeded posts $SEEDED_POSTS"
        return 1
    fi
    # The sync path retries a dead embedding server forever (ollama_embed with
    # max_retries => NULL). PL/Python only sees the cancel at its next retry
    # notice, so the step can end up to one retry cycle after the timeout.
    psql "$ADMIN_URL" -v ON_ERROR_STOP=on \
        -c "set statement_timeout = '120s'" \
        -c "select * from hivesense_app.generate_embeddings_for_posts('$ids'::int[], false, 0)" \
        -c "select hivesense_app.publish_visible_sync_seq()" || {
        echo "embedding the seeded posts failed or hit the 120s statement_timeout: is the embedding server $OLLAMA_URL answering?"
        return 1
    }
    # Posts with a non-zero 384-dim embedding: every long seeded post, not the short one.
    got="$(psql "$ADMIN_URL" -v ON_ERROR_STOP=on -Atc "
        select string_agg(post_id::text, ',' order by post_id) from (
            select post_id from hivesense_app.posts_vectors
             where post_id = any('$ids'::int[])
             group by post_id
            having bool_and(vector_dims(embedding) = 384 and vector_norm(embedding) > 0)
        ) embedded")" || return 1
    if [ "$got" != "$EMBEDDED_POSTS" ]; then
        echo "posts with non-zero 384-dim embeddings: '$got', expected $EMBEDDED_POSTS"
        psql "$ADMIN_URL" -c "select post_id, chunk_number, vector_dims(embedding), vector_norm(embedding)
                                from hivesense_app.posts_vectors order by post_id, chunk_number"
        return 1
    fi
    echo "embedded the seeded posts: $got"
    python3 .aidev/hivesense_smoke.py "$out" embed-search
}

embed_search() {
    local rc=0
    embed_seeded_posts || rc=$?
    echo "== restoring the default installation"
    reinstall || return 1
    return "$rc"
}

for s in "$@"; do
    case "$s" in
        shellcheck) step shellcheck run_shellcheck ;;
        sqlfluff) step sqlfluff run_sqlfluff ;;
        unit) step unit run_unit ;;
        sql-registered) step sql-registered sql_registered ;;
        install) step install install ;;
        reinstall) step reinstall reinstall ;;
        embed-search) step embed-search embed_search ;;
        api-smoke) step api-smoke python3 .aidev/hivesense_smoke.py "$out" api-smoke ;;
        *) echo "unknown step: $s" >&2; exit 2 ;;
    esac
done
python3 .aidev/junit_cases.py "$out/junit.xml" "$suite" "$cases"
exit "$status"

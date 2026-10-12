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
#   - api-smoke       PostgREST over the installed schema, the calls in
#                     .aidev/hivesense_smoke.py; one junit case per call
#
# install, reinstall and api-smoke need the HAF stack (.aidev/test-stack.compose.yml).
# Reports go to test-results/<suite>/: junit.xml (one case per step) plus
# api-smoke.xml.
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

install() {
    wait_for_db || return 1
    HIVESENSE_GIT_HASH="$(git rev-parse HEAD 2>/dev/null || echo aidev)" \
        bash scripts/install_app.sh --postgres-url="$ADMIN_URL" || return 1
    # What the block processor does at start-up; tests/test_sync_chains.sql
    # expects the primary chain's sync_uuid it mints.
    psql "$ADMIN_URL" -v ON_ERROR_STOP=on -Atc "select hivesense_app.init_local_sync_identity()" || return 1
    psql "$ADMIN_URL" -v ON_ERROR_STOP=on -f tests/test_sync_chains.sql
}

reinstall() {
    wait_for_db || return 1
    bash scripts/uninstall_app.sh --postgres-url="$ADMIN_URL" || return 1
    install
}

for s in "$@"; do
    case "$s" in
        shellcheck) step shellcheck run_shellcheck ;;
        sqlfluff) step sqlfluff run_sqlfluff ;;
        unit) step unit run_unit ;;
        sql-registered) step sql-registered sql_registered ;;
        install) step install install ;;
        reinstall) step reinstall reinstall ;;
        api-smoke) step api-smoke python3 .aidev/hivesense_smoke.py "$out" ;;
        *) echo "unknown step: $s" >&2; exit 2 ;;
    esac
done
python3 .aidev/junit_cases.py "$out/junit.xml" "$suite" "$cases"
exit "$status"

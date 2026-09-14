#!/bin/sh

# CI rehearsal of the sync-chain rebase (docs/sync_chain_rebase.md) in the
# docker/ci environment. Two phases around a same-model reconfiguration with a
# different chunk size (stands in for a splitter change):
#
#   hivesense_rebase_test.sh --phase=dump   --dir=DIR   # before the reconfigure
#   hivesense_rebase_test.sh --phase=rebase --dir=DIR   # after the regeneration
#
# The rebase phase loads the dump, runs every rebase step, checks the reports
# against what a same-corpus regeneration must produce (no posts gained or
# lost, every post whose chunk count changed re-sent), and confirms the public
# endpoints now serve the old chain. Exits nonzero on any failed check.

SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)
COMPOSE_DIR="${SCRIPTPATH}/../../../docker/ci"
ROOT="${SCRIPTPATH}/../../.."

PHASE=""
DIR=""
for arg in "$@"; do
  case "$arg" in
    --phase=*) PHASE="${arg#*=}" ;;
    --dir=*)   DIR="${arg#*=}" ;;
    *) echo "Usage: $0 --phase=dump|rebase --dir=DIR"; exit 2 ;;
  esac
done
[ -n "$DIR" ] || { echo "Usage: $0 --phase=dump|rebase --dir=DIR"; exit 2; }

PSQL_CMD="docker compose -f ${COMPOSE_DIR}/compose.yml exec -T haf psql -U haf_admin -d haf_block_log"

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
pass() { echo "ok: $1"; }

query_database() {
  $PSQL_CMD -q -A -t -c "SET ROLE hivesense_owner;" -c "$1" | tr -d '[:space:]'
}
show() {  # print a result set to the log
  $PSQL_CMD -q -c "SET ROLE hivesense_owner;" -c "$1"
}
http_get() {
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy \
    wget -qO - "http://hivesense-postgrest-rewriter${1}"
}
expect_eq() {  # $1 label, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1 is '$2', expected '$3'"; fi
}

case "$PHASE" in
  dump)
    echo "=== rebase test: dumping the current chain ==="
    "${ROOT}/scripts/legacy_chain/dump_old_chain.sh" --dir="$DIR" --psql="$PSQL_CMD" || exit 1
    # remember what the old chain looked like for the assertions later
    query_database "SELECT count(DISTINCT post_id) FROM hivesense_app.posts_vectors" > "$DIR/old_posts_with_vectors"
    query_database "SELECT count(*) FROM hivesense_app.posts_vectors" > "$DIR/old_chunks"
    # posts and their chunk counts, to compute the expected rechunked set
    $PSQL_CMD -q -A -t -c "SELECT ha.name || '/' || hpd.permlink || '|' || count(*)
        FROM hivesense_app.posts_vectors pv
        JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
        JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
        JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
        GROUP BY ha.name, hpd.permlink" | sed '/^$/d' | sort > "$DIR/old_chunk_counts"
    echo "dumped: $(cat "$DIR/old_posts_with_vectors") posts, $(cat "$DIR/old_chunks") chunks"
    exit 0
    ;;
  rebase) ;;
  *) echo "Usage: $0 --phase=dump|rebase --dir=DIR"; exit 2 ;;
esac

echo "=== rebase test: rebasing the dumped chain onto the regenerated node ==="
IFS='|' read -r OLD_UUID OLD_TAIL _ _ < "$DIR/old_status.txt"
FREEZE_BLOCK=$(query_database "SELECT hive.app_get_current_block_num('hivesense_app')")
NEW_UUID=$(query_database "SELECT sync_uuid FROM hivesense_app.hivesense_app_status WHERE id = 1")
echo "old uuid=$OLD_UUID tail=$OLD_TAIL; new uuid=$NEW_UUID; freeze block=$FREEZE_BLOCK"
if [ "$NEW_UUID" = "$OLD_UUID" ] || [ -z "$NEW_UUID" ]; then
  fail "regenerated node should have minted its own sync_uuid (got '$NEW_UUID')"
fi

"${ROOT}/scripts/legacy_chain/load_old_chain.sh" --dir="$DIR" --psql="$PSQL_CMD" || { fail "load_old_chain.sh"; exit 1; }

show "SELECT * FROM hivesense_app.rebase_resolve(${FREEZE_BLOCK});"
expect_eq "old posts unresolved" "$(query_database "SELECT count(*) FROM hivesense_app.legacy_unresolved")" 0
expect_eq "old vector rows resolved" \
  "$(query_database "SELECT count(*) FROM hivesense_app.legacy_vectors")" "$(cat "$DIR/old_chunks")"

show "SELECT * FROM hivesense_app.rebase_diff();"
show "SELECT * FROM hivesense_app.legacy_diff_histogram;"
# same corpus, same threshold: no post gained or lost embeddings
expect_eq "posts gone" "$(query_database "SELECT count(*) FROM hivesense_app.legacy_merge_set WHERE reason = 'gone'")" 0
expect_eq "posts new"  "$(query_database "SELECT count(*) FROM hivesense_app.legacy_merge_set WHERE reason = 'new'")" 0
# every post whose chunk count changed must be in the merge set (the diff may
# add posts whose count stayed equal but whose boundaries moved)
$PSQL_CMD -q -A -t -c "SELECT ha.name || '/' || hpd.permlink || '|' || count(*)
    FROM hivesense_app.posts_vectors pv
    JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
    JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
    JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
    GROUP BY ha.name, hpd.permlink" | sed '/^$/d' | sort > "$DIR/new_chunk_counts"
# comm prefixes column-2 lines with a tab; strip it so both sides dedupe
count_changed=$(comm -3 "$DIR/old_chunk_counts" "$DIR/new_chunk_counts" | tr -d '\t' | cut -d'|' -f1 | sort -u | wc -l | tr -d ' ')
rechunked=$(query_database "SELECT count(*) FROM hivesense_app.legacy_merge_set WHERE reason = 'rechunked'")
echo "posts whose chunk count changed: $count_changed; rechunked by the diff: $rechunked"
if [ "$count_changed" -gt 0 ] && [ "$rechunked" -ge "$count_changed" ]; then
  pass "diff covers every post whose chunk count changed"
else
  fail "diff rechunked $rechunked posts but $count_changed changed chunk count (a smaller tokens_per_chunk must change some)"
fi
# names are author/permlink: [a-z0-9.-]+ only, safe to embed as literals
changed_names=$(comm -3 "$DIR/old_chunk_counts" "$DIR/new_chunk_counts" | tr -d '\t' | cut -d'|' -f1 | sort -u | sed "s|.*|('&')|" | paste -sd, -)
if [ -n "$changed_names" ]; then
  missed=$(query_database "SELECT count(*) FROM (VALUES $changed_names) v(name)
      WHERE NOT EXISTS (
        SELECT 1 FROM hivesense_app.legacy_merge_set m
        JOIN hivemind_app.hive_posts hp ON hp.id = m.post_id
        JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
        JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
        WHERE ha.name || '/' || hpd.permlink = v.name)")
else
  missed=0
fi
expect_eq "count-changed posts missing from the merge set" "$missed" 0

show "SELECT * FROM hivesense_app.rebase_build_tables();"
show "SELECT hivesense_app.rebase_build_indexes();"
show "SELECT * FROM hivesense_app.rebase_swap();"
show "SELECT * FROM hivesense_app.rebase_verify();"
expect_eq "rebase_verify() checks failed" "$(query_database "SELECT count(*) FROM hivesense_app.rebase_verify() WHERE NOT ok")" 0

MERGE_OPS=$(query_database "SELECT merge_count FROM hivesense_app.legacy_rebase_state")
expect_eq "status.sync_uuid" "$(query_database "SELECT sync_uuid FROM hivesense_app.hivesense_app_status")" "$OLD_UUID"

# what downstreams see through the real HTTP path
# (PostgREST caches the schema; the swap changed no signatures, so no reload needed)
body=$(http_get "/sync-settings")
if echo "$body" | grep -q "\"sync_uuid\":\"$OLD_UUID\""; then
  pass "/sync-settings advertises the old uuid"
else
  fail "/sync-settings does not advertise $OLD_UUID: $(echo "$body" | head -c 300)"
fi
body=$(http_get "/sync-chains")
first=$(echo "$body" | grep -o '"sync_uuid":"[^"]*"' | head -1 | cut -d'"' -f4)
expect_eq "/sync-chains first uuid" "$first" "$OLD_UUID"
body=$(http_get "/embedding-updates?after_seq=${OLD_TAIL}&page_size=100000&sync_uuid=${OLD_UUID}")
n=$(echo "$body" | grep -o '"sync_seq"' | wc -l | tr -d ' ')
expect_eq "/embedding-updates ops after the old tail" "$n" "$MERGE_OPS"
body=$(http_get "/embedding-updates?after_seq=0&page_size=100000&sync_uuid=${OLD_UUID}")
n=$(echo "$body" | grep -o '"sync_seq"' | wc -l | tr -d ' ')
old_ops=$(query_database "SELECT count(*) FROM (SELECT DISTINCT sync_seq, post_id FROM hivesense_app.posts_vectors UNION SELECT sync_seq, post_id FROM hivesense_app.deleted_embeddings) x")
expect_eq "/embedding-updates from zero serves the whole history" "$n" "$old_ops"
if http_get "/embedding-updates?after_seq=0&page_size=10&sync_uuid=${NEW_UUID}" >/dev/null 2>&1; then
  fail "the regenerated node's own (pre-rebase) uuid is still accepted"
else
  pass "pre-rebase uuid rejected"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "=== rebase test: ${FAILURES} check(s) failed ===" >&2
  exit 1
fi
echo "=== rebase test: all checks passed ==="

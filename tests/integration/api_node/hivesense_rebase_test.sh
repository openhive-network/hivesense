#!/bin/sh

# CI rehearsal of the sync-chain rebase (docs/sync_chain_rebase.md) in the
# docker/ci environment. Two phases around a same-model reconfiguration with a
# different chunk size (stands in for a splitter change):
#
#   hivesense_rebase_test.sh --phase=dump   --dir=DIR   # before the reconfigure
#   hivesense_rebase_test.sh --phase=rebase --dir=DIR   # after the regeneration
#
# The dump phase first marks a few embedded posts deleted in hivemind (the
# regeneration drops them: 'gone'), removes the old vectors of a few others
# (the regeneration embeds them: 'new') and purges a few deleted posts on the
# old chain (delete marker only: left alone). The rebase phase loads the dump,
# runs every rebase step, checks the reports against what the regeneration must
# produce (exactly the arranged posts gained or lost, every post whose chunk
# count changed re-sent), and confirms the public endpoints now serve the old
# chain with a delete op per gone post and an insert op per new post. Exits
# nonzero on any failed check.

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

POST_NAME="ha.name || '/' || hpd.permlink"
POST_NAME_JOIN="JOIN hivemind_app.hive_posts hp ON hp.id = t.post_id
    JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
    JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id"

# names are author/permlink: [a-z0-9.-]+ only, safe to embed as literals
names_values() {  # $1 = file of names, one per line -> ('a/p'),('b/q')
  sed "s|.*|('&')|" "$1" | paste -sd, -
}
# sorted names of the post ids a query selects as column post_id
post_names() {
  $PSQL_CMD -v ON_ERROR_STOP=on -q -A -t -c "SELECT $POST_NAME FROM ($1) t $POST_NAME_JOIN" | sed '/^$/d' | sort
}
expect_same_names() {  # $1 label, $2 actual file, $3 expected file
  if cmp -s "$2" "$3"; then
    pass "$1 = $(paste -sd' ' - < "$3")"
  else
    fail "$1 differ (< actual, > expected): $(diff "$2" "$3" | grep '^[<>]' | paste -sd' ' -)"
  fi
}

case "$PHASE" in
  dump)
    echo "=== rebase test: arranging gone, new and already-purged posts ==="
    mkdir -p "$DIR" || exit 1
    # Three disjoint sets of embedded root posts with a single hive_posts row
    # (a re-posted permlink would resolve to its live row):
    #   gone_posts    marked deleted in hivemind after the dump's chain was
    #                 built: the old chain keeps their vectors, the
    #                 regeneration embeds nothing for them -> 'gone'
    #   new_posts     vectors removed from the old chain before the dump: the
    #                 regeneration embeds them -> 'new'
    #   purged_posts  deleted and purged on the old chain (delete marker, no
    #                 vectors): neither 'gone' nor tombstoned again
    # hivemind deletes by setting counter_deleted (and moves block_num, which
    # the regeneration does not need: it keys on counter_deleted).
    post_names "SELECT post_id FROM (
          SELECT DISTINCT pv.post_id FROM hivesense_app.posts_vectors pv
            JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
           WHERE hp.counter_deleted = 0 AND (hp.root_id = hp.id OR hp.root_id = 0)
             AND NOT EXISTS (SELECT 1 FROM hivemind_app.hive_posts o
                              WHERE o.author_id = hp.author_id AND o.permlink_id = hp.permlink_id
                                AND o.id <> hp.id)
           ORDER BY pv.post_id LIMIT 8) p" > "$DIR/arranged_posts"
    sed -n '1,3p' "$DIR/arranged_posts" > "$DIR/gone_posts"
    sed -n '4,6p' "$DIR/arranged_posts" > "$DIR/new_posts"
    sed -n '7,8p' "$DIR/arranged_posts" > "$DIR/purged_posts"
    if [ "$(wc -l < "$DIR/purged_posts")" -ne 2 ]; then
      echo "ERROR: fewer than 8 embedded root posts to arrange: $(paste -sd' ' - < "$DIR/arranged_posts")" >&2
      exit 1
    fi
    echo "gone: $(paste -sd' ' - < "$DIR/gone_posts")"
    echo "new: $(paste -sd' ' - < "$DIR/new_posts")"
    echo "purged: $(paste -sd' ' - < "$DIR/purged_posts")"
    by_name="FROM hivemind_app.hive_posts hp
        JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
        JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
       WHERE $POST_NAME IN (SELECT name FROM (VALUES"
    # one transaction; the purge must find exactly the purged posts, so it runs
    # before the gone posts are marked
    $PSQL_CMD -v ON_ERROR_STOP=on -1 -q -A -t \
      -c "UPDATE hivemind_app.hive_posts SET counter_deleted = 1
           WHERE id IN (SELECT hp.id $by_name $(names_values "$DIR/purged_posts")) v(name))" \
      -c "SET ROLE hivesense_owner" \
      -c "SELECT hivesense_app.purge_deleted_post_vectors()" \
      -c "RESET ROLE" \
      -c "UPDATE hivemind_app.hive_posts SET counter_deleted = 1
           WHERE id IN (SELECT hp.id $by_name $(names_values "$DIR/gone_posts")) v(name))" \
      -c "DELETE FROM hivesense_app.posts_vectors
           WHERE post_id IN (SELECT hp.id $by_name $(names_values "$DIR/new_posts")) v(name))" \
      > "$DIR/arrange.out" || { echo "ERROR: arranging the posts failed" >&2; exit 1; }
    purged=$(tr -d '[:space:]' < "$DIR/arrange.out")
    if [ "$purged" != "2" ]; then
      echo "ERROR: purge_deleted_post_vectors() purged '$purged' posts, expected the 2 arranged ones" >&2
      exit 1
    fi
    post_names "SELECT DISTINCT post_id FROM hivesense_app.posts_vectors" > "$DIR/arranged_with_vectors"
    for kind in gone new purged; do
      comm -12 "$DIR/arranged_with_vectors" "$DIR/${kind}_posts" > "$DIR/${kind}_with_vectors"
    done
    if ! cmp -s "$DIR/gone_with_vectors" "$DIR/gone_posts" || [ -s "$DIR/new_with_vectors" ] || [ -s "$DIR/purged_with_vectors" ]; then
      echo "ERROR: arrangement did not hold: gone posts must keep their vectors, new and purged posts must have none" >&2
      exit 1
    fi

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

# hivemind sits at the end of a fixed block log, so nothing should have
# revived the posts the dump phase marked deleted
cat "$DIR/gone_posts" "$DIR/purged_posts" > "$DIR/deleted_posts"
expect_eq "posts marked deleted still deleted in hivemind" "$(query_database "SELECT count(*)
    FROM hivemind_app.hive_posts hp
    JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
    JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
   WHERE hp.counter_deleted > 0
     AND $POST_NAME IN (SELECT name FROM (VALUES $(names_values "$DIR/deleted_posts")) v(name))")" \
  "$(wc -l < "$DIR/deleted_posts" | tr -d ' ')"

"${ROOT}/scripts/legacy_chain/load_old_chain.sh" --dir="$DIR" --psql="$PSQL_CMD" || { fail "load_old_chain.sh"; exit 1; }

show "SELECT * FROM hivesense_app.rebase_resolve(${FREEZE_BLOCK});"
expect_eq "old posts unresolved" "$(query_database "SELECT count(*) FROM hivesense_app.legacy_unresolved")" 0
expect_eq "old vector rows resolved" \
  "$(query_database "SELECT count(*) FROM hivesense_app.legacy_vectors")" "$(cat "$DIR/old_chunks")"

show "SELECT * FROM hivesense_app.rebase_diff();"
show "SELECT * FROM hivesense_app.legacy_diff_histogram;"
# same corpus otherwise: exactly the arranged posts gained or lost embeddings,
# and the purged ones (delete marker, no vectors on either side) are untouched
post_names "SELECT post_id FROM hivesense_app.legacy_merge_set WHERE reason = 'gone'" > "$DIR/merge_gone"
post_names "SELECT post_id FROM hivesense_app.legacy_merge_set WHERE reason = 'new'" > "$DIR/merge_new"
post_names "SELECT post_id FROM hivesense_app.legacy_merge_set" | comm -12 - "$DIR/purged_posts" > "$DIR/merge_purged"
expect_same_names "posts gone" "$DIR/merge_gone" "$DIR/gone_posts"
expect_same_names "posts new" "$DIR/merge_new" "$DIR/new_posts"
expect_eq "purged posts in the merge set" "$(wc -l < "$DIR/merge_purged" | tr -d ' ')" 0
# every post whose chunk count changed must be in the merge set (the diff may
# add posts whose count stayed equal but whose boundaries moved)
$PSQL_CMD -q -A -t -c "SELECT ha.name || '/' || hpd.permlink || '|' || count(*)
    FROM hivesense_app.posts_vectors pv
    JOIN hivemind_app.hive_posts hp ON hp.id = pv.post_id
    JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
    JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
    GROUP BY ha.name, hpd.permlink" | sed '/^$/d' | sort > "$DIR/new_chunk_counts"
# comm prefixes column-2 lines with a tab; strip it so both sides dedupe; the
# gone and new posts changed chunk count by arrangement, not by rechunking
cat "$DIR/gone_posts" "$DIR/new_posts" > "$DIR/gone_or_new"
comm -3 "$DIR/old_chunk_counts" "$DIR/new_chunk_counts" | tr -d '\t' | cut -d'|' -f1 | sort -u \
  | grep -vxF -f "$DIR/gone_or_new" > "$DIR/count_changed"
count_changed=$(wc -l < "$DIR/count_changed" | tr -d ' ')
rechunked=$(query_database "SELECT count(*) FROM hivesense_app.legacy_merge_set WHERE reason = 'rechunked'")
echo "posts whose chunk count changed: $count_changed; rechunked by the diff: $rechunked"
if [ "$count_changed" -gt 0 ] && [ "$rechunked" -ge "$count_changed" ]; then
  pass "diff covers every post whose chunk count changed"
else
  fail "diff rechunked $rechunked posts but $count_changed changed chunk count (a smaller tokens_per_chunk must change some)"
fi
changed_names=$(names_values "$DIR/count_changed")
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
# "op <op> author/permlink" per served op (embeddingupdate field order)
echo "$body" | grep -o '"op":"[a-z]*","author":"[^"]*","permlink":"[^"]*"' \
  | sed 's|^"op":"\([a-z]*\)","author":"\([^"]*\)","permlink":"\([^"]*\)"$|\1 \2/\3|' > "$DIR/served_ops"
sed -n 's/^delete //p' "$DIR/served_ops" | sort > "$DIR/served_deletes"
sed -n 's/^insert //p' "$DIR/served_ops" | sort > "$DIR/served_inserts"
cut -d' ' -f2 "$DIR/served_ops" | sort | comm -12 - "$DIR/purged_posts" > "$DIR/served_purged"
expect_same_names "/embedding-updates delete ops after the old tail" "$DIR/served_deletes" "$DIR/gone_posts"
expect_same_names "/embedding-updates insert ops after the old tail" "$DIR/served_inserts" "$DIR/new_posts"
expect_eq "/embedding-updates ops after the old tail for purged posts" "$(wc -l < "$DIR/served_purged" | tr -d ' ')" 0
expect_eq "vector rows of posts deleted in hivemind" "$(query_database "SELECT count(*)
    FROM hivesense_app.posts_vectors t $POST_NAME_JOIN
   WHERE $POST_NAME IN (SELECT name FROM (VALUES $(names_values "$DIR/deleted_posts")) v(name))")" 0
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

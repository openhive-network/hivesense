#!/bin/sh
# Dump the embedding chain of an OLD hivesense node so it can be rebased onto
# a regenerated node (docs/sync_chain_rebase.md). Read-only; runs against the
# old stack with plain psql, nothing is installed there.
#
# PRECONDITION: the old node's block processor is stopped (--stop-at-block),
# so the tables are static and separate COPY statements see one state.
#
# Output files (CSV with header, in --dir):
#   old_vectors.csv     author,permlink,chunk_number,embedding,sync_seq
#   old_deleted.csv     author,permlink,sync_seq
#   old_post_data.csv   author,permlink,number_of_tokens,last_vectors_block
#   old_root_posts.csv  author,permlink   (every live root post; consistency check)
#   old_status.txt      sync_uuid|max_visible_sync_seq|skipped_ops|current_block
#
# Usage:
#   dump_old_chain.sh --dir=/path/out [--psql="psql postgresql://haf_admin@haf/haf_block_log"]
#   dump_old_chain.sh --dir=/path/out --psql="docker compose exec -T haf psql -U haf_admin -d haf_block_log"
#   --skip-root-posts   omit old_root_posts.csv

set -eu

DIR=""
PSQL="psql ${POSTGRES_ACCESS:-postgresql://haf_admin@haf/haf_block_log}"
ROOT_POSTS=1

for arg in "$@"; do
  case "$arg" in
    --dir=*)   DIR="${arg#*=}" ;;
    --psql=*)  PSQL="${arg#*=}" ;;
    --skip-root-posts) ROOT_POSTS=0 ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
mkdir -p "$DIR"

# shellcheck disable=SC2086  # $PSQL is a command line, word-split on purpose
run_copy() {  # $1 = SQL query, $2 = output file
  echo "  -> $2"
  $PSQL -v ON_ERROR_STOP=on -q -A -t -c "COPY ($1) TO STDOUT WITH (FORMAT csv, HEADER true)" > "$2"
  echo "     $(($(wc -l < "$2") - 1)) rows"
}

# Refuse to dump a moving target.
# shellcheck disable=SC2086
bp=$($PSQL -A -t -c "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'hivesense_block_processing%'" | tr -d '[:space:]')
if [ "${bp:-0}" != "0" ]; then
  echo "ERROR: $bp hivesense block-processing session(s) are connected; stop the block processor first" >&2
  exit 1
fi

echo "Dumping old chain to $DIR"
# shellcheck disable=SC2086
$PSQL -v ON_ERROR_STOP=on -q -A -t -c "
  SELECT sync_uuid || '|' || max_visible_sync_seq || '|' || (skipped_op_count + upstream_skipped_op_count)
         || '|' || hive.app_get_current_block_num('hivesense_app')
    FROM hivesense_app.hivesense_app_status WHERE id = 1" | tr -d '[:space:]' > "$DIR/old_status.txt"
echo >> "$DIR/old_status.txt"   # read(1) needs the trailing newline
echo "  -> $DIR/old_status.txt: $(cat "$DIR/old_status.txt")"

NAME_JOIN="JOIN hivemind_app.hive_posts hp ON hp.id = t.post_id
           JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
           JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id"

run_copy "SELECT ha.name AS author, hpd.permlink, t.chunk_number, t.embedding::text AS embedding, t.sync_seq
            FROM hivesense_app.posts_vectors t $NAME_JOIN ORDER BY t.post_id, t.chunk_number" \
         "$DIR/old_vectors.csv"
run_copy "SELECT ha.name AS author, hpd.permlink, t.sync_seq
            FROM hivesense_app.deleted_embeddings t $NAME_JOIN ORDER BY t.sync_seq" \
         "$DIR/old_deleted.csv"
run_copy "SELECT ha.name AS author, hpd.permlink, t.number_of_tokens, t.last_vectors_block
            FROM hivesense_app.post_data t $NAME_JOIN ORDER BY t.post_id" \
         "$DIR/old_post_data.csv"
if [ "$ROOT_POSTS" = "1" ]; then
  run_copy "SELECT ha.name AS author, hpd.permlink
              FROM hivemind_app.hive_posts hp
              JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
              JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
             WHERE (hp.root_id = hp.id OR hp.root_id = 0) AND hp.counter_deleted = 0
             ORDER BY hp.id" \
           "$DIR/old_root_posts.csv"
else
  : > "$DIR/old_root_posts.csv"
fi
echo "Done."

#!/bin/sh
# Load a dump made by dump_old_chain.sh into the staging tables of the NEW
# hivesense node and record the old chain's identity, ready for
# hivesense_app.rebase_resolve() (docs/sync_chain_rebase.md).
#
# Usage:
#   load_old_chain.sh --dir=/path/of/dump [--psql="psql postgresql://haf_admin@haf/haf_block_log"]
#
# The psql command must connect as haf_admin (or hivesense_owner): the staging
# tables are created under hivesense_owner.

set -eu

DIR=""
PSQL="psql ${POSTGRES_ACCESS:-postgresql://haf_admin@haf/haf_block_log}"

for arg in "$@"; do
  case "$arg" in
    --dir=*)   DIR="${arg#*=}" ;;
    --psql=*)  PSQL="${arg#*=}" ;;
    --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
for f in old_status.txt old_vectors.csv old_deleted.csv old_post_data.csv old_root_posts.csv; do
  [ -f "$DIR/$f" ] || { echo "missing $DIR/$f" >&2; exit 1; }
done

# '|| true': read returns nonzero on a final line without newline
IFS='|' read -r OLD_UUID OLD_TAIL OLD_SKIPPED OLD_BLOCK < "$DIR/old_status.txt" || true
[ -n "${OLD_UUID:-}" ] && [ -n "${OLD_TAIL:-}" ] || { echo "malformed $DIR/old_status.txt" >&2; exit 1; }
echo "Old chain: uuid=$OLD_UUID tail_seq=$OLD_TAIL skipped=$OLD_SKIPPED block=$OLD_BLOCK"

# shellcheck disable=SC2086  # $PSQL is a command line, word-split on purpose
sql() { $PSQL -v ON_ERROR_STOP=on -q -c "SET ROLE hivesense_owner;" -c "$1"; }
# shellcheck disable=SC2086
load() {  # $1 = table, $2 = file (CSV with header)
  echo "  <- $2"
  if [ -s "$2" ]; then
    $PSQL -v ON_ERROR_STOP=on -q -c "SET ROLE hivesense_owner;" \
      -c "COPY hivesense_app.$1 FROM STDIN WITH (FORMAT csv, HEADER true)" < "$2"
  fi
}

sql "SELECT hivesense_app.rebase_create_staging();"
load legacy_vectors_raw    "$DIR/old_vectors.csv"
load legacy_deleted_raw    "$DIR/old_deleted.csv"
load legacy_post_data_raw  "$DIR/old_post_data.csv"
load legacy_root_posts_raw "$DIR/old_root_posts.csv"
sql "SELECT hivesense_app.rebase_set_old_status('$OLD_UUID'::uuid, $OLD_TAIL, $OLD_SKIPPED, $OLD_BLOCK);"
echo "Staged. Next: SELECT * FROM hivesense_app.rebase_resolve(<freeze block>);"

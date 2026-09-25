#!/bin/sh
# -e covers the commands whose status reaches the shell. It does NOT cover the
# queries below: `x=$(a | b)` takes the status of the last command in the pipe,
# which is `tr`, so a failed psql still assigns an empty string. require_number
# is what makes those checks fail closed.
set -eu

# Get the directory where docker compose is running
SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)
COMPOSE_DIR="${SCRIPTPATH}/../../../docker/ci"

query_database() {
  query=$1
  # explicit -U: newer HAF images default psql to the hived user, which
  # cannot read hivesense_app tables (the chunk-count check would silently
  # degrade into a no-op)
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -U haf_admin -A -t -d haf_block_log -c "$query" | tr -d '[:space:]'
}

# A check that cannot read its number has to FAIL, not pass. `[ "" -lt 3100 ]` is
# an error, and `if` reads an error as false, so an empty answer (psql failed, the
# role cannot read the table, the context row is missing) used to skip the range
# test entirely and fall through to "passed" (#52).
require_number() {
  case "$2" in
    ''|*[!0-9]*)
      echo "$1: expected a number, got '$2' -- the query failed or returned no row, so this check could not run" >&2
      exit 1
      ;;
  esac
}

# 1. check if hivesense is synced
hivesense_block_num=$(query_database "SELECT current_block_num FROM hafd.contexts WHERE name = 'hivesense_app'")
require_number "hivesense current_block_num" "$hivesense_block_num"
if [ "$hivesense_block_num" -ne 1000000 ]; then
  echo "Current block num ${hivesense_block_num} != 1000000" >&2
  exit 1
fi

# 2. check number of chunks (allow small variance across builders/hivemind versions)
number_of_chunks=$(query_database "SELECT COUNT(*) FROM hivesense_app.posts_vectors")
require_number "posts_vectors chunk count" "$number_of_chunks"
MIN_CHUNK_COUNT=${MIN_CHUNK_COUNT:-3100}
MAX_CHUNK_COUNT=${MAX_CHUNK_COUNT:-3500}
if [ "$number_of_chunks" -lt "$MIN_CHUNK_COUNT" ] || [ "$number_of_chunks" -gt "$MAX_CHUNK_COUNT" ]; then
  echo "Chunk count ${number_of_chunks} outside expected range [${MIN_CHUNK_COUNT}, ${MAX_CHUNK_COUNT}]" >&2
  exit 1
fi
echo "Chunk count: ${number_of_chunks} (expected range: ${MIN_CHUNK_COUNT}-${MAX_CHUNK_COUNT})"

# 3. check if Swagger works (query swagger service directly via Docker network)
if ! docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy wget -qO - "http://swagger:80/" | grep -q "Swagger UI"; then
  echo "Swagger UI content not detected" >&2
  exit 1
fi

# 4. check if OpenAPI hivesense endpoint is working (query PostgREST directly)
if ! docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy wget -qO - "http://hivesense-postgrest:3000/" | grep -q '"title":[[:space:]]*"Hivesense"'; then
  echo "OpenAPI endpoint is NOT available or missing expected title: Hivesense" >&2
  exit 1
fi

echo "passed"

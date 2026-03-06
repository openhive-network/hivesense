#!/bin/sh

# Test requires up and running API node
HOST_NAME=${PUBLIC_HOSTNAME:-"localhost"}

# Get the directory where docker compose is running
SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)
COMPOSE_DIR="${SCRIPTPATH}/../../../docker/ci"

query_database() {
  query=$1
  docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -A -t -d haf_block_log -c "$query" | tr -d '[:space:]'
}

# 1. check if hivesense is synced
hivesense_block_num=$(query_database "SELECT current_block_num FROM hafd.contexts WHERE name = 'hivesense_app'")
if [ "$hivesense_block_num" -ne 1000000 ]; then
  echo "Current block num ${hivesense_block_num} != 1000000" >&2
  exit 1
fi

# 2. check number of chunks
number_of_chunks=$(query_database "SELECT COUNT(*) FROM hivesense_app.posts_vectors")
EXPECTED_CHUNK_COUNT=${EXPECTED_CHUNK_COUNT:-3260}
if [ "$number_of_chunks" -ne "$EXPECTED_CHUNK_COUNT" ]; then
  echo "Wrong number of chunks ${number_of_chunks} != ${EXPECTED_CHUNK_COUNT}" >&2
  exit 1
fi

# 3. check if Swagger works
if ! docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy wget -qO - --no-check-certificate "https://${HOST_NAME}/hivesense-swagger/" | grep -q "Swagger UI"; then
  echo "Swagger UI content not detected" >&2
  exit 1
fi

# 4. check if OpenAPI hivesense endpoint is working
if ! docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T caddy wget -qO - --no-check-certificate "https://${HOST_NAME}/hivesense-api/" | grep -q '"title":[[:space:]]*"Hivesense"'; then
  echo "OpenAPI endpoint is NOT available or missing expected title: Hivesense" >&2
  exit 1
fi

echo "passed"

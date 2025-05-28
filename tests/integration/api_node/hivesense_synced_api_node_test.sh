#!/bin/sh

# Test requires up and running API node
HOST_NAME=${PUBLIC_HOSTNAME:-"localhost"}

query_database() {
  query=$1
  docker exec haf-world-haf-1 psql -A -t -d haf_block_log -c "$query" | tr -d '[:space:]'
}

# 1. check if hivesense is synced
hivesense_block_num=$(query_database "SELECT current_block_num FROM hafd.contexts WHERE name = 'hivesense_app1'")
if [ "$hivesense_block_num" -ne 1000000 ]; then
  echo "Current block num ${hivesense_block_num} != 1000000" >&2
  exit 1
fi

# 2. check number of chunks
number_of_chunks=$(query_database "SELECT COUNT(*) FROM hivesense_app.posts_vectors")
if [ "$number_of_chunks" -ne 194 ]; then
  echo "Wrong number of chunks ${number_of_chunks} != 194" >&2
  exit 1
fi

# 3. check if Swagger works
if ! docker exec haf-world-caddy-1 wget -qO - --no-check-certificate "https://${HOST_NAME}/hivesense-swagger/" | grep -q "Swagger UI"; then
  echo "Swagger UI content not detected" >&2
  exit 1
fi

# 4. check if OpenAPI hivesense endpoint is working
if ! docker exec haf-world-caddy-1 wget -qO - --no-check-certificate "https://${HOST_NAME}/hivesense-api/" | grep -q '"title":[[:space:]]*"Hivesense"'; then
  echo "OpenAPI endpoint is NOT available or missing expected title: Hivesense" >&2
  exit 1
fi

echo "passed"

#!/bin/sh

# On a dual-stack network, start the PostgREST rewriter against a stand-in
# hivesense-postgrest that listens on IPv4 only (like PostgREST's default !4),
# then recreate the stand-in at new addresses: the old IPv6 address held by a
# container with nothing listening, the old IPv4 address left unowned. Check
# the rewriter answers again within 15 s, no request takes longer than 5 s,
# and the rewriter never proxies to an IPv6 address.
#
# Skips, naming the reason, when the daemon cannot create an IPv6 network.
#
# Usage: rewriter_upstream_recreate_dual_stack_test.sh [IMAGE]
# IMAGE defaults to the rewriter image built for the current commit.

set -e

SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)

if [ -n "$1" ]; then
  IMAGE="$1"
else
  # shellcheck disable=SC1091
  . "${SCRIPTPATH}/../../../scripts/ci-helpers/compose_variables.sh"
  IMAGE="${HIVESENSE_REWRITER_IMAGE}:${HIVESENSE_VERSION}"
fi

NAME="rewriter-dual-stack-test-$$"
NETWORK="$NAME"
REWRITER="${NAME}-rewriter"
UPSTREAM="${NAME}-upstream"
HOLDER="${NAME}-holder"

cleanup() {
  docker rm -f "$REWRITER" "$UPSTREAM" "$HOLDER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  echo "--- rewriter log tail ---" >&2
  docker logs --tail 30 "$REWRITER" >&2 2>&1 || true
  exit 1
}

skip() {
  echo "SKIP: $1"
  exit 0
}

# Try a few subnets so one already taken on the host does not fail the test;
# any other refusal means the daemon cannot create an IPv6 network.
for x in $(( $$ % 200 + 20 )) $(( $$ % 200 + 21 )) $(( $$ % 200 + 22 )); do
  V4="172.31.${x}"
  V6="fd00:${x}:"
  if err=$(docker network create --ipv6 --subnet "${V4}.0/24" --subnet "${V6}:/64" "$NETWORK" 2>&1 >/dev/null); then
    break
  fi
  case "$err" in
    *overlap*) V4="" ;;
    *) skip "daemon cannot create an IPv6 network: ${err}" ;;
  esac
done
[ -n "$V4" ] || fail "no free 172.31.x.0/24 subnet for the test network"

# A stand-in PostgREST that echoes the request URI it receives, served by the
# rewriter image's own openresty so the test needs no other image.
start_upstream() {
  docker run -d --name "$UPSTREAM" --network "$NETWORK" --network-alias hivesense-postgrest \
    --ip "$1" --ip6 "$2" --entrypoint sh "$IMAGE" -c '
      printf "%s\n" "events {}" "http { server { listen 0.0.0.0:3000; location / { return 200 \"\$request_uri\"; } } }" > /tmp/upstream.conf
      exec /usr/local/openresty/bin/openresty -c /tmp/upstream.conf -g "daemon off;"' >/dev/null
}

if ! err=$(start_upstream "${V4}.10" "${V6}:10" 2>&1); then
  case "$err" in
    *ip6tables*|*IPv6*|*ipv6*) skip "daemon cannot attach a container to an IPv6 network: ${err}" ;;
    *) fail "stand-in upstream did not start: ${err}" ;;
  esac
fi

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$REWRITER" 2>/dev/null)" = "true" ]
}

expected="/rpc/get_hivesense_version"
max_elapsed=0

# One request through the rewriter; records the slowest request seen.
probe() {
  start=$(date +%s)
  got=$(docker exec "$REWRITER" wget -qO - -T 70 http://127.0.0.1/version 2>/dev/null || true)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le "$max_elapsed" ] || max_elapsed=$elapsed
  [ "$got" = "$expected" ]
}

# One CPU makes worker_processes auto start a single worker: each worker has
# its own resolver cache, so with many workers most requests would land on one
# that has cached nothing.
echo "Starting ${IMAGE} on a dual-stack network..."
docker run -d --name "$REWRITER" --network "$NETWORK" --ip "${V4}.2" --ip6 "${V6}:2" \
  --cpuset-cpus 0 "$IMAGE" >/dev/null

i=0
until probe; do
  running || fail "rewriter exited"
  i=$((i+1))
  [ "$i" -le 30 ] || fail "rewriter did not reach the upstream within 30s"
  sleep 1
done
# Several requests while both addresses are cached, so a resolver that also
# returns the IPv6 address gets to try it.
for _ in 1 2 3 4 5; do probe || fail "request before the recreate did not answer"; done
echo "Rewriter proxies /version to ${expected}."

echo "Recreating the stand-in at new addresses..."
docker rm -f "$UPSTREAM" >/dev/null
docker run -d --name "$HOLDER" --network "$NETWORK" --ip6 "${V6}:10" --ip "${V4}.30" \
  --entrypoint sleep "$IMAGE" infinity >/dev/null
start_upstream "${V4}.11" "${V6}:11" >/dev/null || fail "recreated stand-in did not start"

max_elapsed=0
deadline=$(( $(date +%s) + 15 ))
until probe; do
  running || fail "rewriter exited"
  [ "$(date +%s)" -lt "$deadline" ] || fail "rewriter did not answer within 15s of the recreate (slowest request ${max_elapsed}s)"
  sleep 1
done
for _ in 1 2 3 4 5; do probe || fail "request after the recreate did not answer"; done
[ "$max_elapsed" -le 5 ] || fail "a request after the recreate took ${max_elapsed}s"
echo "Rewriter answers again after the recreate (slowest request ${max_elapsed}s)."

if docker logs "$REWRITER" 2>&1 | grep -F 'upstream: "http://[' >&2; then
  fail "rewriter proxied to an IPv6 upstream address"
fi
echo "Rewriter never proxied to an IPv6 upstream address."

echo "PASS"

#!/bin/sh

# Start the PostgREST rewriter while its upstream (hivesense-postgrest) does
# not resolve, check it stays up, then start a stand-in upstream under that
# name and check the rewriter proxies rewritten requests to it.
#
# Usage: rewriter_unresolvable_upstream_test.sh [IMAGE]
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

NAME="rewriter-upstream-test-$$"
NETWORK="$NAME"
REWRITER="${NAME}-rewriter"
UPSTREAM="${NAME}-upstream"

cleanup() {
  docker rm -f "$REWRITER" "$UPSTREAM" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  echo "--- rewriter log tail ---" >&2
  docker logs --tail 30 "$REWRITER" >&2 2>&1 || true
  exit 1
}

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$REWRITER" 2>/dev/null)" = "true" ]
}

rewriter_get() {
  docker exec "$REWRITER" wget -qO - -T 2 "http://127.0.0.1$1" 2>/dev/null
}

docker network create "$NETWORK" >/dev/null

echo "Starting ${IMAGE} with no hivesense-postgrest on the network..."
docker run -d --name "$REWRITER" --network "$NETWORK" "$IMAGE" >/dev/null

i=0
until docker exec "$REWRITER" wget -q -T 2 --spider http://127.0.0.1:81/health 2>/dev/null; do
  running || fail "rewriter exited while its upstream was unresolvable"
  i=$((i+1))
  [ "$i" -le 30 ] || fail "rewriter health endpoint not answering after 30s"
  sleep 1
done
sleep 3
running || fail "rewriter exited while its upstream was unresolvable"
echo "Rewriter is up with an unresolvable upstream."

# A stand-in PostgREST that echoes the request URI it receives, served by the
# rewriter image's own openresty so the test needs no other image.
echo "Starting a stand-in hivesense-postgrest..."
docker run -d --name "$UPSTREAM" --network "$NETWORK" --network-alias hivesense-postgrest \
  --entrypoint sh "$IMAGE" -c '
    printf "%s\n" "events {}" "http { server { listen 3000; location / { return 200 \"\$request_uri\"; } } }" > /tmp/upstream.conf
    exec /usr/local/openresty/bin/openresty -c /tmp/upstream.conf -g "daemon off;"' >/dev/null

expected="/rpc/posts_similar?author=alice&permlink=hello"
i=0
until [ "$(rewriter_get /posts/alice/hello/similar)" = "$expected" ]; do
  running || fail "rewriter exited"
  i=$((i+1))
  [ "$i" -le 60 ] || fail "rewriter did not reach the upstream within 60s of it starting"
  sleep 1
done
echo "Rewriter proxies /posts/alice/hello/similar to ${expected}."

got=$(rewriter_get "/sync-status?x=1")
[ "$got" = "/rpc/get_hivesense_sync_status?x=1" ] || fail "/sync-status?x=1 proxied as '${got}'"
echo "Rewriter keeps query strings: /sync-status?x=1 -> ${got}."

echo "PASS"

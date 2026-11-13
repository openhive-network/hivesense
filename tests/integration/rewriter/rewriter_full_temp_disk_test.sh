#!/bin/sh

# Check the PostgREST rewriter passes a reply larger than its memory buffers
# through whole to a slow client while its proxy_temp has no room (a tiny
# tmpfs), as when the API node's disk is full: it must stream such a reply,
# not spool it to proxy_temp and cut it short. A stand-in hivesense-postgrest
# answers every request with REPLY_BYTES bytes.
#
# Usage: rewriter_full_temp_disk_test.sh [IMAGE]
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

# about a 1000-row /embedding-updates page
REPLY_BYTES=20000000
NAME="rewriter-temp-disk-test-$$"
NETWORK="$NAME"
REWRITER="${NAME}-rewriter"
UPSTREAM="${NAME}-upstream"
UPSTREAM_CONF=$(mktemp)

cleanup() {
  docker rm -f "$REWRITER" "$UPSTREAM" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -f "$UPSTREAM_CONF"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  echo "--- rewriter log tail ---" >&2
  docker logs --tail 30 "$REWRITER" >&2 2>&1 || true
  exit 1
}

cat > "$UPSTREAM_CONF" <<EOF
events {}
http {
    server {
        listen 3000;
        location / {
            content_by_lua_block {
                ngx.header["Content-Length"] = ${REPLY_BYTES}
                ngx.print(string.rep("x", ${REPLY_BYTES}))
            }
        }
    }
}
EOF

docker network create "$NETWORK" >/dev/null

docker create --name "$UPSTREAM" --network "$NETWORK" --network-alias hivesense-postgrest \
  --entrypoint /usr/local/openresty/bin/openresty "$IMAGE" -c /tmp/upstream.conf -g "daemon off;" >/dev/null
docker cp "$UPSTREAM_CONF" "$UPSTREAM:/tmp/upstream.conf"
docker start "$UPSTREAM" >/dev/null

echo "Starting ${IMAGE} with an 8 KB proxy_temp..."
docker run -d --name "$REWRITER" --network "$NETWORK" \
  --tmpfs /usr/local/openresty/nginx/proxy_temp:size=8k "$IMAGE" >/dev/null

i=0
until docker exec "$REWRITER" wget -q -T 5 -O /dev/null http://127.0.0.1/version 2>/dev/null; do
  [ "$(docker inspect -f '{{.State.Running}}' "$REWRITER" 2>/dev/null)" = "true" ] || fail "rewriter exited"
  i=$((i+1))
  [ "$i" -le 60 ] || fail "rewriter did not proxy /version within 60s"
  sleep 1
done
echo "Rewriter proxies to the stand-in upstream."

# The pipe stalls wget for a few seconds, so the reply backs up in the
# rewriter: a rewriter that spools fills proxy_temp and cuts the reply short.
got=$(docker exec "$REWRITER" sh -c \
  'wget -qO - -T 60 "http://127.0.0.1/embedding-updates?after_seq=0&page_size=1000" | { sleep 5; wc -c; }' | tr -d ' ')
[ "$got" = "$REPLY_BYTES" ] || fail "a ${REPLY_BYTES}-byte reply reached a slow client as ${got} bytes"
echo "A ${REPLY_BYTES}-byte reply reached a slow client whole."

echo "PASS"

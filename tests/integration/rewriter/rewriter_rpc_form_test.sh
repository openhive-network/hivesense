#!/bin/sh

# Check the PostgREST rewriter forwards a REST GET (or HEAD) of a hivesense
# function as a form POST of the arguments the function declares (its
# rpc_arguments.lua entry), so a value such as not.blocktrades is an argument
# rather than a PostgREST filter, while every other query parameter (a column
# filter, select, limit) stays in the query string. A stand-in
# hivesense-postgrest echoes the method, URI, Content-Type and body it receives;
# a second server in it plays a client sending HEAD then GET on one connection.
#
# Usage: rewriter_rpc_form_test.sh [IMAGE]
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

NAME="rewriter-rpc-form-test-$$"
NETWORK="$NAME"
REWRITER="${NAME}-rewriter"
UPSTREAM="${NAME}-upstream"
UPSTREAM_CONF=$(mktemp)
FAILURES=0

cleanup() {
  docker rm -f "$REWRITER" "$UPSTREAM" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -f "$UPSTREAM_CONF"
}
trap cleanup EXIT

abort() {
  echo "FAIL: $1" >&2
  echo "--- rewriter log tail ---" >&2
  docker logs --tail 30 "$REWRITER" >&2 2>&1 || true
  exit 1
}

rewriter_get() {
  docker exec "$REWRITER" wget -qO - -T 5 "http://127.0.0.1$1" 2>&1
}

# expect NAME ACTUAL EXPECTED
expect() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: got '$2', expected '$3'" >&2
    FAILURES=$((FAILURES+1))
  fi
}

cat > "$UPSTREAM_CONF" <<'EOF'
events {}
http {
    # Docker's embedded DNS, for the probe to find the rewriter by name
    resolver 127.0.0.11;
    server {
        listen 3000;
        location / {
            content_by_lua_block {
                ngx.req.read_body()
                local echo = table.concat({ngx.req.get_method(), ngx.var.request_uri,
                    ngx.var.http_content_type or "-", ngx.req.get_body_data() or ""}, " ")
                ngx.header["Content-Length"] = #echo
                ngx.print(echo)
            }
        }
    }
    server {
        listen 3001;
        # HEAD then GET of ?path= on one connection to ?host=:80; prints each
        # answer's status line and Content-Length, then the GET's body
        location /head-then-get {
            content_by_lua_block {
                local sock = ngx.socket.tcp()
                sock:settimeout(5000)
                local ok, err = sock:connect(ngx.var.arg_host, 80)
                if not ok then
                    ngx.print("connect: ", err)
                    return
                end
                local path = ngx.unescape_uri(ngx.var.arg_path)
                local function exchange(method)
                    sock:send(method .. " " .. path .. " HTTP/1.1\r\nHost: rewriter\r\n\r\n")
                    local status = sock:receive("*l")
                    local length = "-"
                    while true do
                        local line = sock:receive("*l")
                        if not line or line == "" then
                            break
                        end
                        length = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)") or length
                    end
                    return tostring(status), length
                end
                local head_status, head_length = exchange("HEAD")
                local get_status, get_length = exchange("GET")
                local body = tonumber(get_length) and sock:receive(tonumber(get_length))
                ngx.print(table.concat({head_status, head_length, get_status, get_length, tostring(body)}, "|"))
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

echo "Starting ${IMAGE}..."
docker run -d --name "$REWRITER" --network "$NETWORK" "$IMAGE" >/dev/null

i=0
until [ "$(rewriter_get /version)" = "GET /rpc/get_hivesense_version - " ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$REWRITER" 2>/dev/null)" = "true" ] || abort "rewriter exited"
  i=$((i+1))
  [ "$i" -le 60 ] || abort "rewriter did not proxy /version within 60s: '$(rewriter_get /version)'"
  sleep 1
done
echo "Rewriter proxies to the stand-in upstream."

FORM="application/x-www-form-urlencoded"

expect "operator-prefixed q and author go to the form body" \
  "$(rewriter_get "/posts/search?q=not.bitcoin&author=not.blocktrades&result_limit=5")" \
  "POST /rpc/posts_search ${FORM} q=not.bitcoin&author=not.blocktrades&result_limit=5"

expect "an operator-prefixed path segment goes to the form body" \
  "$(rewriter_get "/posts/eq.blocktrades/hello/similar?truncate=20")" \
  "POST /rpc/posts_similar ${FORM} author=eq.blocktrades&permlink=hello&truncate=20"

expect "a real author and permlink go to the form body" \
  "$(rewriter_get "/posts/alice/hello/similar")" \
  "POST /rpc/posts_similar ${FORM} author=alice&permlink=hello"

expect "a hyphenated declared argument goes to the form body" \
  "$(rewriter_get "/posts/search?q=hive&from-block=1&to-block=2")" \
  "POST /rpc/posts_search ${FORM} q=hive&from-block=1&to-block=2"

expect "column filter, select and limit stay in the query string" \
  "$(rewriter_get "/embedding-updates?after_seq=0&op=eq.insert&select=sync_seq,op&limit=5")" \
  "POST /rpc/embedding_updates?op=eq.insert&select=sync_seq,op&limit=5 ${FORM} after_seq=0"

expect "a call with no declared argument is forwarded unchanged" \
  "$(rewriter_get "/sync-status?x=1")" \
  "GET /rpc/get_hivesense_sync_status?x=1 - "

get_body="POST /rpc/posts_search ${FORM} q=not.bitcoin"
expect "HEAD answers the GET's status and length with no body; the next GET is framed" \
  "$(docker exec "$REWRITER" wget -qO - -T 15 \
      "http://hivesense-postgrest:3001/head-then-get?host=${REWRITER}&path=%2Fposts%2Fsearch%3Fq%3Dnot.bitcoin" 2>&1)" \
  "HTTP/1.1 200 OK|${#get_body}|HTTP/1.1 200 OK|${#get_body}|${get_body}"

if [ "$FAILURES" -gt 0 ]; then
  echo "--- rewriter log tail ---" >&2
  docker logs --tail 30 "$REWRITER" >&2 2>&1 || true
  echo "${FAILURES} rewriter check(s) failed" >&2
  exit 1
fi
echo "PASS"

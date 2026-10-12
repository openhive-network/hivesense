#!/usr/bin/env python3
"""Serve the installed hivesense schema with PostgREST and check its API answers.

    hivesense_smoke.py OUT_DIR [api-smoke|embed-search]

Starts `postgrest` the way docker/ci/compose.yml's hivesense-postgrest service does
(schema hivesense_endpoints, anonymous role hivesense_user, root spec `root`, extra
search path hivesense_app) on a free loopback port, against HIVESENSE_TEST_USER_URL,
then makes the calls of one check set:

  - api-smoke (default): CHECKS, against a fresh installation with no embeddings;
    every check asserts the shape that state answers with.
  - embed-search: EMBEDDED_CHECKS, after .aidev/run-checks.sh has embedded the posts
    of .aidev/seed_posts.sql through the stack's Ollama; the checks assert rank
    order (never a similarity value) of the search endpoints, which embed the query.

Writes OUT_DIR/<check set>.xml (one junit case per call) and exits non-zero when
any call fails. To check another endpoint, add it to the check set.
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
STARTUP_TIMEOUT_S = 60


def get(path):
    return ("GET", path, None)


def http_json(kind, *keys):
    def check(status, body) -> None:
        assert status == 200, f"HTTP {status}"
        assert isinstance(body, kind), f"expected {kind.__name__}, got {body!r}"
        if keys:
            row = body[0] if isinstance(body, list) and body else body
            missing = [k for k in keys if k not in row]
            assert not missing, f"lacks {missing}: {body!r}"
    return check


def http_is(expected):
    def check(status, body) -> None:
        assert status == 200, f"HTTP {status}"
        assert body == expected, f"got {body!r}, expected {expected!r}"
    return check


def http_error(code, message_part=""):
    def check(status, body) -> None:
        assert status == code, f"HTTP {status}, expected {code}"
        message = body.get("message", "") if isinstance(body, dict) else ""
        assert message_part in message, f"expected a message containing {message_part!r}, got {body!r}"
    return check


# name, request, check(status, decoded body). `{sync_uuid}` in a path is replaced
# by the primary chain's uuid, read from /rpc/get_sync_settings.
UNKNOWN_UUID = "00000000-0000-0000-0000-000000000000"
CHECKS = [
    ("root", get("/"), http_json(dict, "openapi", "paths")),
    ("get_hivesense_version", get("/rpc/get_hivesense_version"), http_json(str)),
    ("get_hivesense_sync_status", get("/rpc/get_hivesense_sync_status"), http_is({"last_block_num": 0, "last_block_time": None})),
    ("get_sync_settings", get("/rpc/get_sync_settings"), http_json(dict, "sync_uuid", "llm", "embedding_dimensionality")),
    ("get_sync_chains", get("/rpc/get_sync_chains"), http_json(list, "sync_uuid", "base_url", "llm")),
    ("embedding_updates", get("/rpc/embedding_updates?after_seq=0&page_size=10&sync_uuid={sync_uuid}"), http_is([])),
    ("embedding_updates.unknown_uuid", get(f"/rpc/embedding_updates?after_seq=0&page_size=10&sync_uuid={UNKNOWN_UUID}"),
     http_error(400, "UUID Mismatch")),
    ("posts_by_ids_query.unknown", get("/rpc/posts_by_ids_query?posts=" + urllib.parse.quote('[{"author":"nobody","permlink":"x"}]')),
     http_is([None])),
    ("posts_by_ids_query.invalid_json", get("/rpc/posts_by_ids_query?posts=nobody/x"), http_error(400, "Invalid JSON")),
    ("posts_similar.unknown", get("/rpc/posts_similar?author=nobody&permlink=x"), http_error(400, "does not exist")),
]


# The posts of .aidev/seed_posts.sql, as (author, permlink).
WITNESS = ("aidev-witness", "why-your-witness-votes-matter")
HIKING = ("aidev-hiker", "three-days-on-the-alpine-ridge")
SAUCE = ("aidev-chef", "slow-simmered-tomato-sauce-for-pasta")
SHORT = ("aidev-shorty", "back-from-the-market")  # below the token threshold
PASTA = ("aidev-cook", "fresh-egg-pasta-with-tomato-basil-sauce")
EMBEDDED = {WITNESS, HIKING, SAUCE, PASTA}
EMBEDDING_DIMS = 384


def search(endpoint, **params):
    # full_posts=0: every result is an {author, permlink} stub
    return get(f"/rpc/{endpoint}?" + urllib.parse.urlencode(dict(params, full_posts=0, result_limit=10)))


def similar_to(post):
    return search("posts_similar", author=post[0], permlink=post[1])


def ranked(first, rest):
    """The results are exactly `first` (in any order) followed by exactly `rest`."""
    def check(status, body) -> None:
        assert status == 200, f"HTTP {status}"
        assert isinstance(body, list), f"expected a list, got {body!r}"
        posts = [(row.get("author"), row.get("permlink")) for row in body]
        assert len(posts) == len(set(posts)), f"duplicate results: {posts}"
        assert set(posts[:len(first)]) == set(first), f"expected {sorted(first)} first, got {posts}"
        assert set(posts[len(first):]) == set(rest), f"expected {sorted(rest)} after them, got {posts}"
    return check


def authors_first(author):
    def check(status, body) -> None:
        assert status == 200, f"HTTP {status}"
        assert isinstance(body, list) and body, f"expected a non-empty list, got {body!r}"
        assert body[0] == author, f"expected {author} first, got {body}"
    return check


def one_upsert_per_embedded_post(status, body) -> None:
    assert status == 200, f"HTTP {status}"
    assert isinstance(body, list), f"expected a list, got {body!r}"
    upserts = [op for op in body if op.get("op") in ("insert", "update")]
    posts = sorted((op["author"], op["permlink"]) for op in upserts)
    assert posts == sorted(EMBEDDED), f"expected one insert/update for each of {sorted(EMBEDDED)}, got {posts}"
    for op in upserts:
        dims = [len(embedding) for embedding in op.get("embeddings") or []]
        assert dims and set(dims) == {EMBEDDING_DIMS}, f"{op['author']}/{op['permlink']}: embedding sizes {dims}"
    others = [op for op in body if op not in upserts]
    assert all(op.get("op") == "delete" and not op.get("embeddings") for op in others), f"unexpected operations: {others}"


EMBEDDED_CHECKS = [
    ("posts_search.pasta", search("posts_search", q="a recipe for cooking pasta with homemade tomato sauce"),
     ranked([SAUCE, PASTA], [WITNESS, HIKING])),
    ("posts_search.hiking", search("posts_search", q="hiking a mountain trail to the summit"),
     ranked([HIKING], [WITNESS, SAUCE, PASTA])),
    ("posts_search.witness", search("posts_search", q="voting for witnesses who produce blocks on the blockchain"),
     ranked([WITNESS], [HIKING, SAUCE, PASTA])),
    ("posts_similar.sauce", similar_to(SAUCE), ranked([PASTA], [WITNESS, HIKING])),
    # A post with no embedding (below the token threshold) has no similar posts (#60).
    ("posts_similar.unembedded", similar_to(SHORT), http_is([])),
    ("authors_search.hiking", get("/rpc/authors_search?" + urllib.parse.urlencode({"topic": "mountain hiking and trekking"})),
     authors_first(HIKING[0])),
    ("embedding_updates", get("/rpc/embedding_updates?after_seq=0&page_size=100&sync_uuid={sync_uuid}"),
     one_upsert_per_embedded_post),
]

CHECK_SETS = {"api-smoke": CHECKS, "embed-search": EMBEDDED_CHECKS}


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def call(base, request):
    method, path, payload = request
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as err:
        status, raw = err.code, err.read()
    text = raw.decode("utf-8", "replace")
    try:
        return status, json.loads(text) if text.strip() else None, text
    except ValueError:
        return status, None, text


def wait_until_serving(base, proc, log_path):
    deadline = time.monotonic() + STARTUP_TIMEOUT_S
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"postgrest exited with {proc.returncode}; see {log_path}")
        try:
            if call(base, ("GET", "/rpc/get_hivesense_version", None))[0] == 200:
                return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError(f"postgrest not serving after {STARTUP_TIMEOUT_S}s; see {log_path}")


def main(out, check_set):
    checks = CHECK_SETS[check_set]
    os.makedirs(out, exist_ok=True)
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    log_path = os.path.join(out, "postgrest.log")
    env = dict(os.environ,
               PGRST_DB_URI=os.environ["HIVESENSE_TEST_USER_URL"],
               PGRST_DB_SCHEMA="hivesense_endpoints",
               PGRST_DB_ANON_ROLE="hivesense_user",
               PGRST_DB_ROOT_SPEC="root",
               PGRST_DB_EXTRA_SEARCH_PATH="hivesense_app",
               PGRST_SERVER_HOST="127.0.0.1",
               PGRST_SERVER_PORT=str(port))
    cases = os.path.join(out, f"{check_set}.tsv")
    failed = 0
    with open(log_path, "w") as log, open(cases, "w") as tsv:
        proc = subprocess.Popen(["postgrest"], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_until_serving(base, proc, log_path)
            settings = call(base, get("/rpc/get_sync_settings"))[1]
            sync_uuid = settings.get("sync_uuid") if isinstance(settings, dict) else None
            for name, (method, path, payload), check in checks:
                request = (method, path.replace("{sync_uuid}", str(sync_uuid)), payload)
                t0 = time.monotonic()
                status, body, text = call(base, request)
                try:
                    check(status, body)
                    verdict, message = "pass", ""
                    print(f"ok   {name}")
                except AssertionError as err:
                    failed += 1
                    verdict, message = "fail", str(err).replace("\t", " ").replace("\n", " ")[:300]
                    print(f"FAIL {name}: {message}\n     response: {text[:500]}")
                tsv.write(f"case\t{name}\t{verdict}\t{time.monotonic() - t0:.3f}\t{message}\n")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
    subprocess.run([sys.executable, os.path.join(HERE, "junit_cases.py"), os.path.join(out, f"{check_set}.xml"), check_set, cases],
                   check=True)
    print(f"{len(checks) - failed}/{len(checks)} calls answered as expected")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in CHECK_SETS):
        sys.exit(f"usage: {sys.argv[0]} OUT_DIR [{'|'.join(CHECK_SETS)}]")
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "api-smoke"))

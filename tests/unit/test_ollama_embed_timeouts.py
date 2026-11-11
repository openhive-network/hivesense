#!/usr/bin/env python3
"""Request timeouts of hivesense_app.ollama_embed's batch version (db/ollama.sql).

Runs the function's PL/Python body as written, with a stand-in `plpy` module, against
a local stub HTTP server that answers after a configurable delay. Timeouts are scaled
down to fractions of a second; backoff sleeps are skipped. No database needed.
"""
import http.client
import io
import json
import os
import re
import socket
import sys
import threading
import types
import unittest
import urllib.error
import urllib.request
from email.message import Message
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, NoReturn, Self
from unittest import mock

OLLAMA_SQL = os.path.join(os.path.dirname(__file__), "..", "..", "db", "ollama.sql")

Embed = Callable[..., list[tuple[int, int, list[float]]]]


class PlpyError(Exception):
    pass


def load_ollama_embed(config: dict[str, Any]) -> tuple[Embed, list[str]]:
    """The batch ollama_embed as a python function; returns (function, notices)."""
    with open(OLLAMA_SQL) as f:
        sql = f.read()
    match = re.search(r"LANGUAGE plpython3u.*?AS \$BODY\$\n(.*?)\$BODY\$;", sql, re.S)
    assert match is not None, f"no plpython3u body in {OLLAMA_SQL}"
    body = match.group(1)
    notices: list[str] = []

    def error(msg: str) -> NoReturn:
        raise PlpyError(msg)

    plpy = types.ModuleType("plpy")
    setattr(plpy, "Error", PlpyError)
    setattr(plpy, "execute", lambda query: [dict(config)])
    setattr(plpy, "notice", notices.append)
    setattr(plpy, "warning", notices.append)
    setattr(plpy, "error", error)
    namespace: dict[str, Any] = {}
    exec("def ollama_embed(model, posts, host, embedding_options, max_retries):\n" + body, namespace)
    sys.modules["plpy"] = plpy
    return namespace["ollama_embed"], notices


class SlowEmbedServer:
    """Answers /api/embed with one 2-dim vector per input text after `delay` seconds."""

    def __init__(self: Self, delay: float) -> None:
        self.delay = delay
        self.requests = 0
        stop = self.stop = threading.Event()
        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self: Self) -> None:
                server.requests += 1
                texts = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["input"]
                if stop.wait(server.delay):
                    return
                out = json.dumps({"embeddings": [[1.0, float(i)] for i in range(len(texts))]}).encode()
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(out)))
                    self.end_headers()
                    self.wfile.write(out)
                except OSError:
                    pass  # the client gave up on this attempt

            def log_message(self: Self, format: str, *args: Any) -> None:
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self: Self) -> None:
        self.stop.set()
        self.httpd.shutdown()
        self.httpd.server_close()


class RejectingEmbedServer:
    """Answers /api/embed with `status` and an ollama-style error body when any input
    text contains "bad", else with one 2-dim vector per input text. Records each
    request's inputs."""

    REASON = "the input length exceeds the context length"

    def __init__(self: Self, status: int) -> None:
        self.requests: list[list[str]] = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self: Self) -> None:
                texts = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["input"]
                server.requests.append(texts)
                if any("bad" in t for t in texts):
                    code, out = status, json.dumps({"error": server.REASON}).encode()
                else:
                    code, out = 200, json.dumps({"embeddings": [[1.0, float(i)] for i in range(len(texts))]}).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self: Self, format: str, *args: Any) -> None:
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self: Self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


class Reply(io.BytesIO):
    """A 200 response as urlopen returns it."""

    def getcode(self: Self) -> int:
        return 200


class FailingReply(Reply):
    """A 200 response whose body read raises `error`."""

    def __init__(self: Self, error: BaseException) -> None:
        super().__init__()
        self.error = error

    def read(self: Self, size: int | None = -1) -> bytes:
        raise self.error


def embeddings_reply(n: int) -> Reply:
    return Reply(json.dumps({"embeddings": [[1.0, float(i)] for i in range(n)]}).encode())


BODY_READ_FAILURES: list[tuple[str, Callable[[], Reply], str]] = [
    ("timeout", lambda: FailingReply(socket.timeout("timed out")), "network error: timed out after 30s"),
    ("TimeoutError", lambda: FailingReply(TimeoutError("timed out")), "network error: timed out after 30s"),
    ("IncompleteRead", lambda: FailingReply(http.client.IncompleteRead(b"{", 99)),
     "network error: IncompleteRead(1 bytes read, 99 more expected)"),
    ("reset", lambda: FailingReply(ConnectionResetError(104, "Connection reset by peer")),
     "network error: [Errno 104] Connection reset by peer"),
    ("not JSON", lambda: Reply(b'{"embeddings": [[1.0, 0'), "malformed reply: "),
    ("no embeddings", lambda: Reply(b'{"error": "busy"}'), "malformed reply: no 'embeddings' in the JSON body"),
]

# Hosts without a scheme: urllib's Request rejects the first, urlopen the rest.
UNUSABLE_HOSTS = ["haproxy", "haproxy:7012", "127.0.0.1:7012"]


def config(base: float, per_text: float = 0.0, cap: float = 600.0, batch_size: int = 100) -> dict[str, Any]:
    return dict(embedding_batch_size=batch_size, embedding_api="ollama", embedding_timeout_base=base,
                embedding_timeout_per_text=per_text, embedding_timeout_max=cap)


def posts(n: int) -> list[dict[str, Any]]:
    return [dict(post_id=i, chunk_number=1, chunk_text=f"text {i}") for i in range(n)]


def timeouts(notices: list[str]) -> list[float]:
    return [float(t) for t in re.findall(r"timed out after ([0-9.]+)s", "\n".join(notices))]


def refused_url() -> str:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return f"http://127.0.0.1:{port}"


@mock.patch("time.sleep", lambda secs: None)
class OllamaEmbedTimeouts(unittest.TestCase):
    def serve(self: Self, delay: float) -> SlowEmbedServer:
        server = SlowEmbedServer(delay)
        self.addCleanup(server.close)
        return server

    def test_slow_server_answers_once_the_timeout_has_grown(self: Self) -> None:
        server = self.serve(0.6)
        embed, notices = load_ollama_embed(config(base=0.2, cap=2.0))
        out = embed("m", posts(2), server.url, None, None)
        self.assertEqual([(pid, num) for pid, num, _ in out], [(0, 1), (1, 1)])
        self.assertEqual(timeouts(notices), [0.2, 0.4])
        self.assertEqual(server.requests, 3)

    def test_fixed_timeout_never_reaches_a_slow_server(self: Self) -> None:
        # A cap equal to the base is the old fixed timeout: every attempt fails alike.
        server = self.serve(0.35)
        embed, notices = load_ollama_embed(config(base=0.1, cap=0.1))
        with self.assertRaisesRegex(PlpyError, r"giving up after 4 attempts: network error: timed out after 0.1s"):
            embed("m", posts(1), server.url, None, 4)
        self.assertEqual(timeouts(notices), [0.1, 0.1, 0.1])

    def test_growth_stops_at_the_cap(self: Self) -> None:
        server = self.serve(5)
        embed, notices = load_ollama_embed(config(base=0.05, cap=0.2))
        with self.assertRaises(PlpyError):
            embed("m", posts(1), server.url, None, 5)
        self.assertEqual(timeouts(notices), [0.05, 0.1, 0.2, 0.2])

    def test_refused_connection_keeps_the_timeout_and_backoff(self: Self) -> None:
        embed, notices = load_ollama_embed(config(base=0.1, cap=1.0))
        with mock.patch("urllib.request.urlopen", wraps=urllib.request.urlopen) as urlopen, \
                mock.patch("time.sleep") as sleep:
            with self.assertRaisesRegex(PlpyError, "giving up after 4 attempts"):
                embed("m", posts(1), refused_url(), None, 4)
        self.assertEqual([c.kwargs["timeout"] for c in urlopen.call_args_list], [0.1] * 4)
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [5, 10, 20])
        self.assertEqual(timeouts(notices), [])

    def test_initial_timeout_scales_with_batch_size(self: Self) -> None:
        server = self.serve(5)
        embed, notices = load_ollama_embed(config(base=0.01, per_text=0.02, cap=0.01))
        with self.assertRaises(PlpyError):
            embed("m", posts(5), server.url, None, 2)
        self.assertEqual(timeouts(notices), [0.1])

    def test_each_batch_restarts_from_the_base(self: Self) -> None:
        server = self.serve(0.3)
        embed, notices = load_ollama_embed(config(base=0.2, cap=2.0, batch_size=1))
        out = embed("m", posts(2), server.url, None, None)
        self.assertEqual(len(out), 2)
        self.assertEqual(timeouts(notices), [0.2, 0.2])
        self.assertEqual([n.split("]")[0] for n in notices], ["[Batch 0:1", "[Batch 1:2"])

    def test_bounded_search_path_caps_growth_at_60s(self: Self) -> None:
        embed, _ = load_ollama_embed(config(base=30, cap=600))
        with mock.patch("urllib.request.urlopen", side_effect=socket.timeout("timed out")) as urlopen:
            with self.assertRaises(PlpyError):
                embed("m", posts(1), "http://unused", None, 4)
        self.assertEqual([c.kwargs["timeout"] for c in urlopen.call_args_list], [30, 60, 60, 60])

    def test_unbounded_sync_path_grows_to_the_configured_cap(self: Self) -> None:
        embed, notices = load_ollama_embed(config(base=30, cap=600))
        calls: list[float] = []

        def urlopen(req: urllib.request.Request, timeout: float) -> NoReturn:
            calls.append(timeout)
            if len(calls) == 7:
                raise RuntimeError("stop")
            raise socket.timeout("timed out")

        with mock.patch("urllib.request.urlopen", urlopen), self.assertRaisesRegex(RuntimeError, "stop"):
            embed("m", posts(1), "http://unused", None, None)
        self.assertEqual(calls, [30, 60, 120, 240, 480, 600, 600])
        self.assertIn("timed out after 60s, retrying in 10s (2/inf)", notices[1])


@mock.patch("time.sleep", lambda secs: None)
class OllamaEmbedRejections(unittest.TestCase):
    def serve(self: Self, status: int) -> RejectingEmbedServer:
        server = RejectingEmbedServer(status)
        self.addCleanup(server.close)
        return server

    def test_400_on_a_single_text_is_not_retried_and_names_it(self: Self) -> None:
        server = self.serve(400)
        embed, notices = load_ollama_embed(config(base=1))
        texts = [dict(post_id=15482022, chunk_number=1, chunk_text="bad dots")]
        with self.assertRaisesRegex(PlpyError, r"\[Batch 0:1\] embedding server rejected post_id 15482022 "
                                    r"chunk_number 1: HTTP 400: .*" + RejectingEmbedServer.REASON):
            embed("m", texts, server.url, None, None)
        self.assertEqual(server.requests, [["bad dots"]])
        self.assertEqual(len(notices), 1)
        self.assertRegex(notices[0], r"HTTP 400, not retrying: .*" + RejectingEmbedServer.REASON)

    def test_400_in_a_batch_resends_its_texts_alone_and_names_the_rejected_one(self: Self) -> None:
        server = self.serve(400)
        embed, notices = load_ollama_embed(config(base=1, batch_size=4))
        texts = posts(4) + [dict(post_id=7, chunk_number=3, chunk_text="bad dots"), *posts(2)]
        with self.assertRaisesRegex(PlpyError, r"\[Batch 4:7\] embedding server rejected post_id 7 "
                                    r"chunk_number 3: HTTP 400: .*" + RejectingEmbedServer.REASON):
            embed("m", texts, server.url, None, None)
        self.assertEqual(server.requests, [
            ["text 0", "text 1", "text 2", "text 3"],
            ["bad dots", "text 0", "text 1"],
            ["bad dots"],
        ])
        self.assertTrue(all("not retrying" in n for n in notices), notices)

    def test_a_batch_rejected_while_each_text_is_accepted_alone_fails_naming_the_batch(self: Self) -> None:
        embed, _ = load_ollama_embed(config(base=1))

        def urlopen(req: urllib.request.Request, timeout: float) -> Any:
            assert isinstance(req.data, bytes)
            texts = json.loads(req.data)["input"]
            if len(texts) > 1:
                raise urllib.error.HTTPError(req.full_url, 413, "too large", Message(), io.BytesIO(b"batch too large"))
            return Reply(json.dumps({"embeddings": [[1.0]]}).encode())

        with mock.patch("urllib.request.urlopen", urlopen), self.assertRaisesRegex(PlpyError, r"rejected the batch with HTTP 413: batch too large, "
                                       r"yet accepted each of its 2 texts alone"):
            embed("m", posts(2), "http://unused", None, None)

    def test_transient_statuses_keep_retrying_on_the_sync_path(self: Self) -> None:
        for status in (500, 503, 408, 429):
            with self.subTest(status=status):
                server = self.serve(status)
                embed, notices = load_ollama_embed(config(base=1))
                sleeps: list[float] = []

                def sleep(secs: float) -> None:
                    sleeps.append(secs)
                    if len(sleeps) == 3:
                        raise RuntimeError("stop")

                with mock.patch("time.sleep", sleep), self.assertRaisesRegex(RuntimeError, "stop"):
                    embed("m", [dict(post_id=1, chunk_number=1, chunk_text="bad")], server.url, None, None)
                self.assertEqual(len(server.requests), 3)
                self.assertEqual(sleeps, [5, 10, 20])
                self.assertIn(f"HTTP {status} ", notices[0])
                self.assertIn("(1/inf)", notices[0])



class OllamaEmbedBodyReadFailures(unittest.TestCase):
    def test_a_failed_body_read_is_retried_like_a_network_error(self: Self) -> None:
        for name, failing, notice in BODY_READ_FAILURES:
            with self.subTest(name):
                embed, notices = load_ollama_embed(config(base=30, cap=600))
                replies = [failing(), embeddings_reply(2)]
                calls: list[tuple[float, list[str]]] = []

                def urlopen(req: urllib.request.Request, timeout: float) -> Reply:
                    assert isinstance(req.data, bytes)
                    calls.append((timeout, json.loads(req.data)["input"]))
                    return replies.pop(0)

                with mock.patch("urllib.request.urlopen", urlopen), mock.patch("time.sleep") as sleep:
                    out = embed("m", posts(2), "http://unused", None, None)
                self.assertEqual(out, [(0, 1, [1.0, 0.0]), (1, 1, [1.0, 1.0])])
                self.assertEqual([c[1] for c in calls], [["text 0", "text 1"]] * 2)
                grown = 60 if "timed out" in notice else 30
                self.assertEqual([c[0] for c in calls], [30, grown])
                self.assertEqual([c.args[0] for c in sleep.call_args_list], [5])
                self.assertEqual(len(notices), 1)
                self.assertIn(f"[Batch 0:2] {notice}", notices[0])
                self.assertIn("retrying in 5s (1/inf)", notices[0])

    def test_a_failed_body_read_counts_as_an_attempt_on_the_search_path(self: Self) -> None:
        for name, failing, notice in BODY_READ_FAILURES:
            with self.subTest(name):
                embed, notices = load_ollama_embed(config(base=30, cap=600))
                with mock.patch("urllib.request.urlopen", side_effect=lambda req, timeout: failing()) as urlopen, \
                        mock.patch("time.sleep"), \
                        self.assertRaisesRegex(PlpyError, r"\[Batch 0:1\] giving up after 3 attempts: "
                                               + re.escape(notice.replace("30s", "60s"))):
                    embed("m", posts(1), "http://unused", None, 3)
                self.assertEqual(urlopen.call_count, 3)
                self.assertEqual(len(notices), 2)


class OllamaEmbedUnusableHost(unittest.TestCase):
    def test_a_host_urllib_cannot_use_fails_at_once_without_a_request(self: Self) -> None:
        for host in UNUSABLE_HOSTS:
            for max_retries in (None, 3):
                with self.subTest(host=host, max_retries=max_retries):
                    embed, notices = load_ollama_embed(config(base=30))
                    with mock.patch("urllib.request.urlopen") as urlopen, \
                            mock.patch("time.sleep", side_effect=AssertionError("retried")), \
                            self.assertRaisesRegex(ValueError, "unknown url type"):
                        embed("m", posts(1), host, None, max_retries)
                    self.assertEqual(urlopen.call_count, 0)
                    self.assertEqual(notices, [])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Request timeouts of hivesense_app.ollama_embed's batch version (db/ollama.sql).

Runs the function's PL/Python body as written, with a stand-in `plpy` module, against
a local stub HTTP server that answers after a configurable delay. Timeouts are scaled
down to fractions of a second; backoff sleeps are skipped. No database needed.
"""
import json
import os
import re
import socket
import sys
import threading
import types
import unittest
import urllib.request
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


if __name__ == "__main__":
    unittest.main()

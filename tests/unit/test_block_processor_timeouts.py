#!/usr/bin/env python3
"""Request timeouts of the block processor's embedding client (scripts/hivesense_block_processor.py).

_embed_batch runs against a local stub HTTP server that answers after a configurable
delay. The 300s floor and the backoff are scaled down to fractions of a second.
No database needed.
"""
import io
import json
import os
import re
import socket
import sys
import unittest
from email.message import Message
from typing import Any, Self
from unittest import mock
from urllib.error import HTTPError

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
sys.path.insert(0, os.path.dirname(__file__))
import hivesense_block_processor as bp
from test_ollama_embed_timeouts import RejectingEmbedServer, Reply, SlowEmbedServer, refused_url


def config(host: str, base: float = 30, per_text: float = 1, cap: float = 600) -> dict[str, Any]:
    return dict(model="m", host=host, api_style="ollama", options=None,
                timeout_base=base, timeout_per_text=per_text, timeout_max=cap)


class Schedule(unittest.TestCase):
    def test_start_is_floored_at_300s(self: Self) -> None:
        self.assertEqual(bp._initial_timeout(config("h"), 100), 300)

    def test_start_honours_a_larger_base(self: Self) -> None:
        self.assertEqual(bp._initial_timeout(config("h", base=450), 1), 450)

    def test_start_scales_with_batch_size(self: Self) -> None:
        self.assertEqual(bp._initial_timeout(config("h", per_text=4), 100), 400)

    def test_grows_only_on_timeout(self: Self) -> None:
        self.assertEqual(bp._next_timeout(300, True, 1200), 600)
        self.assertEqual(bp._next_timeout(300, False, 1200), 300)

    def test_growth_stops_at_the_cap(self: Self) -> None:
        self.assertEqual(bp._next_timeout(800, True, 1200), 1200)
        self.assertEqual(bp._next_timeout(1200, True, 1200), 1200)


@mock.patch.object(bp, "INITIAL_RETRY_DELAY", 0.01)
@mock.patch.object(bp, "MAX_RETRY_DELAY", 0.01)
@mock.patch.object(bp, "MIN_REQUEST_TIMEOUT", 0.2)
class EmbedBatch(unittest.TestCase):
    def serve(self: Self, delay: float) -> SlowEmbedServer:
        server = SlowEmbedServer(delay)
        self.addCleanup(server.close)
        return server

    def warnings(self: Self, logs: Any) -> list[float]:
        return [float(t) for t in re.findall(r"timed out after ([0-9.]+)s", "\n".join(logs.output))]

    def test_slow_server_answers_once_the_timeout_has_grown(self: Self) -> None:
        server = self.serve(0.6)
        with self.assertLogs("hivesense", "WARNING") as logs:
            out = bp._embed_batch(config(server.url, base=0, per_text=0, cap=2.0), ["a", "b"], "t")
        self.assertEqual(out, [[1.0, 0.0], [1.0, 1.0]])
        self.assertEqual(self.warnings(logs), [0.2, 0.4])
        self.assertEqual(server.requests, 3)

    def test_growth_stops_at_the_cap(self: Self) -> None:
        cfg = config("http://unused", base=0, per_text=0, cap=1.0)
        calls: list[float] = []

        def urlopen(req: Any, timeout: float) -> Any:
            calls.append(timeout)
            if len(calls) == 6:
                raise RuntimeError("stop")
            raise socket.timeout("timed out")

        with mock.patch.object(bp, "urlopen", urlopen), self.assertRaisesRegex(RuntimeError, "stop"), \
                self.assertLogs("hivesense", "WARNING"):
            bp._embed_batch(cfg, ["a"], "t")
        self.assertEqual(calls, [0.2, 0.4, 0.8, 1.0, 1.0, 1.0])

    def test_cap_below_the_start_keeps_the_start(self: Self) -> None:
        server = self.serve(5)
        cfg = config(server.url, base=0, per_text=0.25, cap=0.05)
        calls: list[float] = []
        real = bp.urlopen

        def urlopen(req: Any, timeout: float) -> Any:
            calls.append(timeout)
            if len(calls) == 3:
                raise RuntimeError("stop")
            return real(req, timeout=timeout)

        with mock.patch.object(bp, "urlopen", urlopen), self.assertRaisesRegex(RuntimeError, "stop"), \
                self.assertLogs("hivesense", "WARNING") as logs:
            bp._embed_batch(cfg, ["a", "b"], "t")
        self.assertEqual(calls, [0.5, 0.5, 0.5])
        self.assertEqual(self.warnings(logs), [0.5, 0.5])

    def test_refused_connection_keeps_the_timeout_and_backoff(self: Self) -> None:
        cfg = config(refused_url(), base=0, per_text=0, cap=2.0)
        calls: list[float] = []
        real = bp.urlopen

        def urlopen(req: Any, timeout: float) -> Any:
            calls.append(timeout)
            if len(calls) == 4:
                raise RuntimeError("stop")
            return real(req, timeout=timeout)

        with mock.patch.object(bp, "urlopen", urlopen), mock.patch("time.sleep") as sleep, \
                mock.patch.object(bp, "INITIAL_RETRY_DELAY", 5), mock.patch.object(bp, "MAX_RETRY_DELAY", 120), \
                self.assertRaisesRegex(RuntimeError, "stop"), self.assertLogs("hivesense", "WARNING") as logs:
            bp._embed_batch(cfg, ["a"], "t")
        self.assertEqual(calls, [0.2] * 4)
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [5, 10, 20])
        self.assertEqual(self.warnings(logs), [])
        self.assertIn("refused", logs.output[0])


@mock.patch.object(bp, "INITIAL_RETRY_DELAY", 0.01)
@mock.patch.object(bp, "MAX_RETRY_DELAY", 0.01)
class EmbedRejections(unittest.TestCase):
    def serve(self: Self, status: int) -> RejectingEmbedServer:
        server = RejectingEmbedServer(status)
        self.addCleanup(server.close)
        return server

    def test_400_on_a_single_text_is_not_retried_and_names_it(self: Self) -> None:
        server = self.serve(400)
        with self.assertLogs("hivesense", "WARNING") as logs, \
                self.assertRaisesRegex(bp.EmbeddingRejected, r"HTTP 400: post_id 15482022 chunk_number 1: .*"
                                       + RejectingEmbedServer.REASON):
            bp._embed_one(config(server.url), [(15482022, 1, "bad dots")], "t")
        self.assertEqual(server.requests, [["bad dots"]])
        self.assertEqual(len(logs.output), 1)
        self.assertRegex(logs.output[0], r"ERROR.*\[t\] HTTP 400, not retrying: .*" + RejectingEmbedServer.REASON)

    def test_400_in_a_batch_resends_its_texts_alone_and_names_the_rejected_one(self: Self) -> None:
        server = self.serve(400)
        batch = [(1, 1, "a"), (7, 3, "bad dots"), (8, 1, "b")]
        with self.assertLogs("hivesense", "WARNING") as logs, \
                self.assertRaisesRegex(bp.EmbeddingRejected, r"HTTP 400: post_id 7 chunk_number 3: .*"
                                       + RejectingEmbedServer.REASON):
            bp._embed_one(config(server.url), batch, "t")
        self.assertEqual(server.requests, [["a", "bad dots", "b"], ["a"], ["bad dots"]])
        self.assertTrue(all("not retrying" in line for line in logs.output), logs.output)

    def test_a_batch_rejected_while_each_text_is_accepted_alone_names_the_batch(self: Self) -> None:
        def urlopen(req: Any, timeout: float) -> Any:
            if len(json.loads(req.data)["input"]) > 1:
                raise HTTPError(req.full_url, 413, "too large", Message(), io.BytesIO(b"batch too large"))
            return Reply(json.dumps({"embeddings": [[1.0]]}).encode())

        with mock.patch.object(bp, "urlopen", urlopen), self.assertLogs("hivesense", "WARNING"), \
                self.assertRaisesRegex(bp.EmbeddingRejected,
                                       r"HTTP 413: batch too large \(each of the batch's 2 texts is accepted alone\)"):
            bp._embed_one(config("http://unused"), [(1, 1, "a"), (2, 1, "b")], "t")

    def test_transient_statuses_keep_retrying(self: Self) -> None:
        for status in (500, 503, 408, 429):
            with self.subTest(status=status):
                server = self.serve(status)
                sleeps: list[float] = []

                def sleep(secs: float) -> None:
                    sleeps.append(secs)
                    if len(sleeps) == 3:
                        raise RuntimeError("stop")

                with mock.patch("time.sleep", sleep), self.assertRaisesRegex(RuntimeError, "stop"), \
                        self.assertLogs("hivesense", "WARNING") as logs:
                    bp._embed_one(config(server.url), [(1, 1, "bad")], "t")
                self.assertEqual(len(server.requests), 3)
                self.assertIn(f"HTTP {status} ", logs.output[0])
                self.assertIn("retrying", logs.output[0])


if __name__ == "__main__":
    unittest.main()

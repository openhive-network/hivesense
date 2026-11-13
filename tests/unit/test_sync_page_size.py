#!/usr/bin/env python3
"""Unit checks for the syncer's adaptive /embedding-updates page size (scripts/sync_embeddings.py).

Run from the syncer image (no database or network needed):
    docker run --rm -v "$PWD/tests:/tests:ro" <syncer image> python /tests/unit/test_sync_page_size.py
or locally with scripts/ on the path.
"""
import json
import os
import sys
import time
import unittest
from collections.abc import Callable, Iterator, Sequence
from typing import Any
from unittest import mock

import requests
from requests.exceptions import ChunkedEncodingError, ConnectionError, ContentDecodingError

os.environ.setdefault("HIVESENSE_API", "http://upstream")
os.environ.setdefault("POSTGRES_URI", "postgresql://x")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
sys.path.insert(0, os.getcwd())  # the syncer image keeps sync_embeddings.py in its WORKDIR
import sync_embeddings as s


def _reply(status: int, body: bytes) -> requests.Response:
    response = requests.Response()
    response.status_code = status
    response._content = body
    return response


class _Upstream:
    """Stand-in for requests.get over a stream of ops numbered 1..total whose
    replies are cut short (raising ChunkedEncodingError) when a page holds more
    than max_ops ops."""

    def __init__(self, total: int, max_ops: int) -> None:
        self.total = total
        self.max_ops = max_ops
        self.page_sizes: list[int] = []

    def get(self, url: str, params: dict[str, Any], timeout: int) -> requests.Response:
        self.page_sizes.append(params["page_size"])
        first = params["after_seq"] + 1
        ops = [{"sync_seq": seq} for seq in range(first, min(first + params["page_size"], self.total + 1))]
        if len(ops) > self.max_ops:
            raise ChunkedEncodingError("Response ended prematurely")
        return _reply(200, json.dumps(ops).encode())


class PageSizeSteps(unittest.TestCase):
    def test_reduction_halves_down_to_the_floor(self) -> None:
        self.assertEqual(s.reduced_page_size(1000), 500)
        self.assertEqual(s.reduced_page_size(31), 15)
        self.assertEqual(s.reduced_page_size(15), s.MIN_PAGE_SIZE)
        self.assertEqual(s.reduced_page_size(s.MIN_PAGE_SIZE), s.MIN_PAGE_SIZE)

    def test_recovery_doubles_up_to_batch(self) -> None:
        self.assertEqual(s.recovered_page_size(10), 20)
        self.assertEqual(s.recovered_page_size(500), s.BATCH)
        self.assertEqual(s.recovered_page_size(625), s.BATCH)
        self.assertEqual(s.recovered_page_size(s.BATCH), s.BATCH)


@mock.patch.object(time, "sleep")
class FetchOps(unittest.TestCase):
    def _fetch(self, get: Callable[..., requests.Response],
               page_size: int) -> tuple[requests.Response, list[dict[str, Any]], int]:
        with mock.patch.object(requests, "get", side_effect=get):
            return s.fetch_ops(0, "uuid", page_size)

    def test_truncated_replies_halve_until_a_page_passes(self, sleep: mock.Mock) -> None:
        upstream = _Upstream(total=5000, max_ops=200)
        with self.assertLogs(level="WARNING") as logs:
            _, ops, next_size = self._fetch(upstream.get, s.BATCH)
        self.assertEqual(upstream.page_sizes, [1000, 500, 250, 125])
        self.assertEqual([op["sync_seq"] for op in ops], list(range(1, 126)))
        self.assertEqual(next_size, 250)
        reductions = [line for line in logs.output if "page_size" in line]
        self.assertEqual(len(reductions), 3)
        self.assertIn("page_size 1000 -> 500 after a truncated reply", reductions[0])

    def test_pages_stay_contiguous_and_size_recovers(self, sleep: mock.Mock) -> None:
        upstream = _Upstream(total=6000, max_ops=60)
        seqs: list[int] = []
        page_size = s.BATCH
        with mock.patch.object(requests, "get", side_effect=upstream.get), self.assertLogs(level="INFO"):
            while len(seqs) < 600:
                _, ops, page_size = s.fetch_ops(seqs[-1] if seqs else 0, "uuid", page_size)
                seqs += [op["sync_seq"] for op in ops]
            upstream.max_ops = upstream.total  # the upstream heals
            while len(seqs) < upstream.total:
                _, ops, page_size = s.fetch_ops(seqs[-1], "uuid", page_size)
                seqs += [op["sync_seq"] for op in ops]
        self.assertEqual(seqs, list(range(1, upstream.total + 1)))
        self.assertEqual(page_size, s.BATCH)
        self.assertEqual(upstream.page_sizes[-1], s.BATCH)

    def test_floor_is_held_while_replies_stay_truncated(self, sleep: mock.Mock) -> None:
        replies: Sequence[Exception | requests.Response] = [ChunkedEncodingError("Response ended prematurely")] * 9 + [_reply(200, b"[]")]
        sizes: list[int] = []

        def get(url: str, params: dict[str, Any], timeout: int) -> requests.Response:
            sizes.append(params["page_size"])
            reply = replies[len(sizes) - 1]
            if isinstance(reply, Exception):
                raise reply
            return reply

        with self.assertLogs(level="WARNING"):
            _, ops, next_size = self._fetch(get, s.BATCH)
        self.assertEqual(sizes, [1000, 500, 250, 125, 62, 31, 15, 10, 10, 10])
        self.assertEqual(ops, [])
        self.assertEqual(next_size, 20)

    def test_unreadable_bodies_also_shrink(self, sleep: mock.Mock) -> None:
        replies: Iterator[Exception | requests.Response] = iter([ContentDecodingError("bad gzip"), _reply(200, b'[{"sync_seq": 1'),
                        _reply(200, b'[{"sync_seq": 1}]')])
        sizes: list[int] = []

        def get(url: str, params: dict[str, Any], timeout: int) -> requests.Response:
            sizes.append(params["page_size"])
            reply = next(replies)
            if isinstance(reply, Exception):
                raise reply
            return reply

        with self.assertLogs(level="WARNING") as logs:
            _, ops, _ = self._fetch(get, s.BATCH)
        self.assertEqual(sizes, [1000, 500, 250])
        self.assertEqual(ops, [{"sync_seq": 1}])
        self.assertTrue(any("page_size 500 -> 250 after an unreadable reply" in line for line in logs.output))

    def test_other_failures_keep_the_page_size(self, sleep: mock.Mock) -> None:
        replies: Iterator[Exception | requests.Response] = iter([ConnectionError("refused"), requests.exceptions.Timeout("slow"),
                        _reply(503, b""), _reply(200, b"[]")])
        sizes: list[int] = []

        def get(url: str, params: dict[str, Any], timeout: int) -> requests.Response:
            sizes.append(params["page_size"])
            reply = next(replies)
            if isinstance(reply, Exception):
                raise reply
            return reply

        with self.assertLogs(level="WARNING") as logs:
            self._fetch(get, 250)
        self.assertEqual(sizes, [250, 250, 250, 250])
        self.assertFalse(any("page_size" in line for line in logs.output))
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [3, 6, 12])


if __name__ == "__main__":
    unittest.main()

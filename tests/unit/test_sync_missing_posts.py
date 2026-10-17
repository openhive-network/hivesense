#!/usr/bin/env python3
"""Unit checks for the syncer's per-op post resolution (scripts/sync_embeddings.py).

Run from the syncer image (no database or network needed):
    docker run --rm -v "$PWD/tests:/tests:ro" <syncer image> python /tests/unit/test_sync_missing_posts.py
or locally with scripts/ on the path.
"""
import os
import sys
import unittest
from typing import Any
from unittest import mock

os.environ.setdefault("HIVESENSE_API", "http://upstream")
os.environ.setdefault("POSTGRES_URI", "postgresql://x")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
sys.path.insert(0, os.getcwd())  # the syncer image keeps sync_embeddings.py in its WORKDIR
import sync_embeddings as s  # noqa: E402


class FakeCursor:
    """Answers the post lookup from a {(author, permlink): post_id} map."""

    def __init__(self, posts: dict[tuple[str, str], int]) -> None:
        self.posts = posts
        self.lookups: list[tuple[str, str]] = []
        self._row: tuple[int] | None = None

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, sql: str, params: tuple[str, str]) -> None:
        self.lookups.append(params)
        post_id = self.posts.get(params)
        self._row = (post_id,) if post_id is not None else None

    def fetchone(self) -> tuple[int] | None:
        return self._row


class FakeConn:
    def __init__(self, posts: dict[tuple[str, str], int]) -> None:
        self.cur = FakeCursor(posts)
        self.rollbacks = 0

    def cursor(self) -> FakeCursor:
        return self.cur

    def rollback(self) -> None:
        self.rollbacks += 1


def op(kind: str, author: str, permlink: str, block: int, seq: int = 1) -> dict[str, Any]:
    return dict(op=kind, author=author, permlink=permlink, last_vectors_block=block, sync_seq=seq)


class ResolveBatchPosts(unittest.TestCase):
    def setUp(self) -> None:
        self.sleep = mock.patch.object(s.time, "sleep").start()
        mock.patch.object(s, "MISSING_POST_RETRIES", 3).start()
        self.addCleanup(mock.patch.stopall)

    def resolve(self, posts: dict[tuple[str, str], int], ops: list[dict[str, Any]],
                max_block: int | None) -> tuple[FakeConn, Any]:
        conn = FakeConn(posts)
        return conn, s.resolve_batch_posts(conn, ops, max_block)

    def test_missing_delete_is_noop_under_exit(self) -> None:
        mock.patch.object(s, "MISSING_POST_ACTION", "exit").start()
        ops = [op("delete", "web2.support", "mvbv27cddaj1jr", 110842292)]
        with self.assertLogs(level="WARNING") as logs:
            conn, (resolved, absent, ignored) = self.resolve({}, ops, None)
        self.assertEqual((resolved, absent, ignored), ([], 0, 1))
        self.assertEqual(conn.cur.lookups, [("web2.support", "mvbv27cddaj1jr")])
        self.sleep.assert_not_called()
        self.assertTrue(any("web2.support/mvbv27cddaj1jr" in line for line in logs.output))
        self.assertFalse(any("None" in line for line in logs.output))

    def test_missing_delete_alongside_resolved_ops(self) -> None:
        mock.patch.object(s, "MISSING_POST_ACTION", "exit").start()
        ins = op("insert", "alice", "p1", 100, seq=1)
        gone = op("delete", "bob", "p2", 200, seq=2)
        dele = op("delete", "carol", "p3", 90, seq=3)
        _, (resolved, absent, ignored) = self.resolve(
            {("alice", "p1"): 11, ("carol", "p3"): 33}, [ins, gone, dele], 100)
        self.assertEqual(resolved, [(ins, 11), (dele, 33)])
        self.assertEqual((absent, ignored), (0, 1))
        self.sleep.assert_not_called()

    def test_missing_insert_retries_then_exits(self) -> None:
        mock.patch.object(s, "MISSING_POST_ACTION", "exit").start()
        ops = [op("insert", "alice", "gone", 500)]
        with self.assertLogs(level="WARNING") as logs, self.assertRaises(SystemExit) as cm:
            self.resolve({}, ops, 500)
        self.assertEqual(cm.exception.code, 1)
        self.assertEqual(self.sleep.call_count, 3)
        retries = [line for line in logs.output if "not found after block" in line]
        self.assertEqual(len(retries), 3)
        self.assertTrue(all("after block 500;" in line for line in retries))

    def test_missing_insert_skipped_under_skip(self) -> None:
        mock.patch.object(s, "MISSING_POST_ACTION", "skip").start()
        ops = [op("insert", "alice", "gone", 500), op("insert", "bob", "here", 400, seq=2)]
        with self.assertLogs(level="WARNING"):
            _, (resolved, absent, ignored) = self.resolve({("bob", "here"): 7}, ops, 500)
        self.assertEqual(resolved, [(ops[1], 7)])
        self.assertEqual((absent, ignored), (1, 0))
        self.assertEqual(self.sleep.call_count, 3)

    def test_insert_found_during_retries(self) -> None:
        mock.patch.object(s, "MISSING_POST_ACTION", "exit").start()
        posts: dict[tuple[str, str], int] = {}
        conn = FakeConn(posts)
        self.sleep.side_effect = lambda _: posts.setdefault(("alice", "late"), 42)
        with self.assertLogs(level="WARNING"):
            resolved, absent, ignored = s.resolve_batch_posts(
                conn, [op("insert", "alice", "late", 500)], 500)
        self.assertEqual([pid for _, pid in resolved], [42])
        self.assertEqual((absent, ignored), (0, 0))
        self.assertEqual(self.sleep.call_count, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)

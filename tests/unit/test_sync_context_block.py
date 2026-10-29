#!/usr/bin/env python3
"""Unit checks for the syncer's empty-page context block (scripts/sync_embeddings.py).

Run from the syncer image (no database or network needed):
    docker run --rm -v "$PWD/tests:/tests:ro" <syncer image> python /tests/unit/test_sync_context_block.py
or locally with scripts/ on the path.
"""
import os
import sys
import unittest

os.environ.setdefault("HIVESENSE_API", "http://upstream")
os.environ.setdefault("POSTGRES_URI", "postgresql://x")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
sys.path.insert(0, os.getcwd())  # the syncer image keeps sync_embeddings.py in its WORKDIR
import sync_embeddings as s  # noqa: E402


class EmptyPageContextBlock(unittest.TestCase):
    def test_upstream_ahead_of_hivemind_is_clamped(self) -> None:
        self.assertEqual(s.empty_page_context_block(101_000_002, 101_000_000, 100_999_990), 101_000_000)
        self.assertEqual(s.empty_page_context_block(101_000_002, 101_000_000, None), 101_000_000)

    def test_upstream_at_or_below_hivemind_is_used(self) -> None:
        self.assertEqual(s.empty_page_context_block(101_000_000, 101_000_000, 100_999_990), 101_000_000)
        self.assertEqual(s.empty_page_context_block(100_999_995, 101_000_000, 100_999_990), 100_999_995)

    def test_clamped_below_last_set_leaves_context_unchanged(self) -> None:
        self.assertIsNone(s.empty_page_context_block(101_000_010, 100_999_990, 101_000_000))
        self.assertIsNone(s.empty_page_context_block(100_999_990, 101_000_010, 101_000_000))

    def test_same_as_last_set_is_no_change(self) -> None:
        self.assertIsNone(s.empty_page_context_block(101_000_005, 101_000_000, 101_000_000))


class UpstreamCurrentBlock(unittest.TestCase):
    def test_header_is_parsed(self) -> None:
        self.assertEqual(s.upstream_current_block({"X-Current-Block-Num": "101000002"}), 101_000_002)

    def test_missing_header_exits(self) -> None:
        with self.assertLogs(level="ERROR"), self.assertRaises(SystemExit) as cm:
            s.upstream_current_block({})
        self.assertEqual(cm.exception.code, 1)


class HivemindHeadBlock(unittest.TestCase):
    class _Cursor:
        def __init__(self, head: int) -> None:
            self.head = head
            self.sql: list[str] = []

        def execute(self, sql: str) -> None:
            self.sql.append(sql)

        def fetchone(self) -> tuple[int]:
            return (self.head,)

    def test_prefers_completed_block_num(self) -> None:
        cur = self._Cursor(101_000_000)
        self.assertEqual(s.hivemind_head_block(cur), 101_000_000)
        self.assertIn("hivemind_app.completed_block_num()", cur.sql[0])
        self.assertIn("hive.app_get_current_block_num('hivemind_app')", cur.sql[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)

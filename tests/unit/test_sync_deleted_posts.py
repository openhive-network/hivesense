#!/usr/bin/env python3
"""Unit checks for how the syncer (scripts/sync_embeddings.py) applies ops for
posts hivemind deleted, including a deleted post re-created under the same
author/permlink (hivemind keeps the deleted row and adds a new one).

The database is a fake that holds hive_posts rows and posts_vectors and answers
the statements resolve_batch_posts() and apply_op() issue. Run like the other
tests/unit checks (no database or network needed).
"""
import os
import sys
import unittest
from typing import Any

os.environ.setdefault("HIVESENSE_API", "http://upstream")
os.environ.setdefault("POSTGRES_URI", "postgresql://x")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
sys.path.insert(0, os.getcwd())  # the syncer image keeps sync_embeddings.py in its WORKDIR
import sync_embeddings as s  # noqa: E402

AUTHOR, PERMLINK = "alice", "hello-world"


class FakeDb:
    """hive_posts rows as (id, author, permlink, counter_deleted) and
    posts_vectors as {post_id: sync_seq}."""

    def __init__(self, posts: list[tuple[int, str, str, int]]) -> None:
        self.posts = posts
        self.vectors: dict[int, int] = {}
        self.tombstones: list[tuple[int, int]] = []


class FakeCursor:
    def __init__(self, db: FakeDb) -> None:
        self.db = db
        self._rows: list[tuple[Any, ...]] = []

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def _matching(self, author: str, permlink: str) -> list[tuple[int, str, str, int]]:
        return [p for p in self.db.posts if p[1] == author and p[2] == permlink]

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> None:
        self._rows = []
        if sql is s.POST_LOOKUP_SQL:
            author, permlink, deleted = params
            # ORDER BY ((counter_deleted > 0) = deleted) DESC, counter_deleted
            rows = sorted(self._matching(author, permlink),
                          key=lambda p: (deleted is not None and (p[3] > 0) != deleted, p[3]))
            self._rows = [(rows[0][0],)] if rows else []
        elif sql is s.DELETED_ROWS_SQL:
            self._rows = [(p[0],) for p in self._matching(*params) if p[3] > 0]
        elif "use_reduced_embeddings()" in sql:
            self._rows = [(False,)]
        elif sql.startswith("DELETE FROM hivesense_app.posts_vectors WHERE post_id = ANY"):
            for post_id in params[0]:
                self.db.vectors.pop(post_id, None)
        elif sql.startswith("DELETE FROM hivesense_app.posts_vectors WHERE post_id = %s"):
            self.db.vectors.pop(params[0], None)
        elif "INSERT INTO hivesense_app.deleted_embeddings" in sql:
            self.db.tombstones.append(params)
        elif "INSERT INTO hivesense_app.post_data" not in sql:
            raise AssertionError(f"unexpected statement: {sql}")

    def executemany(self, sql: str, rows: list[tuple[Any, ...]]) -> None:
        assert "INSERT INTO hivesense_app.posts_vectors" in sql
        for sync_seq, post_id, _chunk, _embedding in rows:
            self.db.vectors[post_id] = sync_seq

    def fetchone(self) -> tuple[Any, ...] | None:
        return self._rows[0] if self._rows else None

    def fetchall(self) -> list[tuple[Any, ...]]:
        return self._rows


class FakeConn:
    def __init__(self, db: FakeDb) -> None:
        self.db = db

    def cursor(self) -> FakeCursor:
        return FakeCursor(self.db)

    def rollback(self) -> None:
        return None


def op(kind: str, seq: int, post_deleted: bool | None) -> dict[str, Any]:
    o: dict[str, Any] = dict(op=kind, author=AUTHOR, permlink=PERMLINK, sync_seq=seq,
                             number_of_tokens=300, last_vectors_block=seq,
                             embeddings=[] if kind == "delete" else [[0.1, 0.2]])
    if post_deleted is not None:
        o["post_deleted"] = post_deleted
    return o


def apply(db: FakeDb, ops: list[dict[str, Any]]) -> None:
    conn = FakeConn(db)
    resolved, absent, ignored = s.resolve_batch_posts(conn, ops, None)
    assert (absent, ignored) == (0, 0)
    cur = conn.cursor()
    for o, post_id in resolved:
        s.apply_op(cur, o, post_id)


class DeletedPostOps(unittest.TestCase):
    def test_delete_of_deleted_post_removes_its_vectors(self) -> None:
        db = FakeDb([(10, AUTHOR, PERMLINK, 1)])
        db.vectors = {10: 5}
        apply(db, [op("delete", 7, True)])
        self.assertEqual(db.vectors, {})
        self.assertEqual(db.tombstones, [(10, 7)])

    def test_delete_before_local_hivemind_saw_the_deletion(self) -> None:
        # the delete is not covered by the hivemind head wait: the local row
        # can still be live, and it is that row's vectors that must go
        db = FakeDb([(10, AUTHOR, PERMLINK, 0)])
        db.vectors = {10: 5}
        apply(db, [op("delete", 7, True)])
        self.assertEqual(db.vectors, {})

    def test_delete_of_old_row_keeps_the_reposts_vectors(self) -> None:
        # a primary's one-time purge tombstones a post deleted long ago, after
        # the re-post's own insert
        db = FakeDb([(10, AUTHOR, PERMLINK, 1), (20, AUTHOR, PERMLINK, 0)])
        db.vectors = {10: 3, 20: 5}
        apply(db, [op("delete", 9, True)])
        self.assertEqual(db.vectors, {20: 5})
        self.assertEqual(db.tombstones, [(10, 9)])

    def test_delete_removes_every_deleted_row(self) -> None:
        db = FakeDb([(10, AUTHOR, PERMLINK, 1), (15, AUTHOR, PERMLINK, 2), (20, AUTHOR, PERMLINK, 0)])
        db.vectors = {10: 2, 15: 3, 20: 4}
        apply(db, [op("delete", 9, True)])
        self.assertEqual(db.vectors, {20: 4})

    def test_under_threshold_edit_of_repost_removes_the_live_rows_vectors(self) -> None:
        db = FakeDb([(10, AUTHOR, PERMLINK, 1), (20, AUTHOR, PERMLINK, 0)])
        db.vectors = {20: 5}
        apply(db, [op("delete", 9, False)])
        self.assertEqual(db.vectors, {})
        self.assertEqual(db.tombstones, [(20, 9)])

    def test_delete_then_recreate_stream(self) -> None:
        # A replica catching up on a hivemind that already holds both rows.
        # At fetch time the upstream reports the old row deleted and the
        # re-post live, so the old row's insert lands on the deleted row and
        # the live row gets vectors only with its own insert.
        db = FakeDb([(10, AUTHOR, PERMLINK, 1), (20, AUTHOR, PERMLINK, 0)])
        apply(db, [op("insert", 1, True)])
        self.assertEqual(db.vectors, {10: 1})
        apply(db, [op("delete", 2, True)])
        self.assertEqual(db.vectors, {})
        apply(db, [op("insert", 3, False)])
        self.assertEqual(db.vectors, {20: 3})

    def test_upstream_without_flag_prefers_the_live_row(self) -> None:
        db = FakeDb([(10, AUTHOR, PERMLINK, 1), (20, AUTHOR, PERMLINK, 0)])
        apply(db, [op("insert", 3, None)])
        self.assertEqual(db.vectors, {20: 3})
        apply(db, [op("delete", 4, None)])
        self.assertEqual(db.vectors, {})


if __name__ == "__main__":
    unittest.main()

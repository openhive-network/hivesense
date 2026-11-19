#!/usr/bin/env python3
"""The block processor's HNSW index build (scripts/hivesense_block_processor.py).

process_blocks runs inside haf_app_driver.py's transaction, where
ensure_indexes_are_created can neither wait for hivemind nor commit between its
steps: it must run on a connection of its own, in autocommit mode, without
holding up the range. psycopg2.connect and the driver's connection are stubbed.
No database needed.
"""
import os
import sys
import threading
from concurrent.futures import Future
import unittest
from types import SimpleNamespace
from typing import Any, Self
from unittest import mock

import psycopg2

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import hivesense_block_processor as bp

CALL = "CALL hivesense_app.ensure_indexes_are_created()"


class DriverCursor:
    """The driver connection's cursor: answers process_blocks' queries for a
    range in the live stage with no posts."""

    def __init__(self: Self, statements: list[str]) -> None:
        self.statements = statements
        self.result: Any = None

    def execute(self: Self, sql: str, params: Any = None) -> None:
        self.statements.append(sql)
        if "get_current_stage_name" in sql:
            self.result = ("live",)
        elif "massive_sync_finished" in sql:
            self.result = (True,)
        elif "posts_in_range" in sql:
            self.result = ([],)

    def fetchone(self: Self) -> Any:
        return self.result


class DriverConnection:
    def __init__(self: Self, password: str | None) -> None:
        self.statements: list[str] = []
        self.info = SimpleNamespace(dsn_parameters={"host": "haf", "user": "hivesense_owner", "dbname": "haf_block_log"},
                                    password=password)

    def cursor(self: Self) -> DriverCursor:
        return DriverCursor(self.statements)


class BuildConnection:
    """The build's own connection: records the autocommit mode each statement ran
    in and sends a server notice; `release` holds the CALL until set."""

    def __init__(self: Self, dsn: str, error: Exception | None, release: threading.Event) -> None:
        self.dsn = dsn
        self.autocommit = False
        self.notices: Any = []
        self.calls: list[tuple[str, bool]] = []
        self.closed = False
        self.error = error
        self.release = release

    def cursor(self: Self) -> "BuildConnection":
        return self

    def __enter__(self: Self) -> "BuildConnection":
        return self

    def __exit__(self: Self, *exc: object) -> None:
        pass

    def execute(self: Self, sql: str) -> None:
        self.calls.append((sql, self.autocommit))
        self.notices.append("NOTICE:  Waiting to build the HNSW index (for 00:00:00): hivemind is busy\n")
        self.release.wait(5)
        if self.error is not None:
            raise self.error

    def close(self: Self) -> None:
        self.closed = True


def build_future() -> Future[None]:
    """The block processor's started build."""
    future = bp._INDEX_BUILD
    assert future is not None, "no index build was started"
    return future


class IndexBuild(unittest.TestCase):
    def setUp(self: Self) -> None:
        self.enterContext(mock.patch.object(bp, "_CONFIG", {}))
        self.enterContext(mock.patch.object(bp, "_INDEX_BUILD", None))
        self.builds: list[BuildConnection] = []
        self.release = threading.Event()
        self.error: Exception | None = None

        def connect(dsn: str) -> BuildConnection:
            conn = BuildConnection(dsn, self.error, self.release)
            self.builds.append(conn)
            return conn

        self.enterContext(mock.patch.object(psycopg2, "connect", connect))

    def test_builds_once_on_its_own_autocommit_connection_without_holding_the_range(self: Self) -> None:
        driver = DriverConnection("secret")
        with self.assertLogs("hivesense", "INFO") as logs:
            bp.process_blocks(driver, 1, 10)  # returns while the build is still running
            self.assertFalse(build_future().done())
            self.release.set()
            build_future().result(5)
            bp.process_blocks(driver, 11, 20)
        self.assertNotIn(CALL, driver.statements)
        self.assertEqual(len(self.builds), 1)
        build = self.builds[0]
        self.assertEqual(build.calls, [(CALL, True)])
        self.assertTrue(build.closed)
        self.assertEqual(psycopg2.extensions.parse_dsn(build.dsn),
                         {"host": "haf", "user": "hivesense_owner", "dbname": "haf_block_log", "password": "secret"})
        self.assertIn("INFO:hivesense:NOTICE:  Waiting to build the HNSW index (for 00:00:00): hivemind is busy",
                      logs.output)
        self.assertEqual(sum("massive_sync_finished" in s for s in driver.statements), 1)

    def test_connects_without_a_password_when_the_driver_has_none(self: Self) -> None:
        self.release.set()
        bp.process_blocks(DriverConnection(None), 1, 10)
        build_future().result(5)
        self.assertNotIn("password", psycopg2.extensions.parse_dsn(self.builds[0].dsn))

    def test_a_failed_build_fails_the_next_range(self: Self) -> None:
        self.error = psycopg2.errors.DiskFull("could not resize shared memory segment")
        self.release.set()
        driver = DriverConnection("secret")
        bp.process_blocks(driver, 1, 10)
        with self.assertRaises(psycopg2.errors.DiskFull):
            build_future().result(5)
        with self.assertRaises(psycopg2.errors.DiskFull):
            bp.process_blocks(driver, 11, 20)
        self.assertTrue(self.builds[0].closed)


if __name__ == "__main__":
    unittest.main()

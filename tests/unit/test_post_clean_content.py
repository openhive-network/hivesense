#!/usr/bin/env python3
"""Runs of repeated symbols under hivesense_app.post_clean_content (db/posts_preprocessing.sql).

Runs the function's PL/Python body as written. The inputs are plain text, so where
BeautifulSoup or lxml is not installed a stand-in that returns the text unchanged takes its
place. No database needed.
"""
import importlib.util
import os
import re
import sys
import textwrap
import types
import unittest
from typing import Any, Callable, Self

PREPROCESSING_SQL = os.path.join(os.path.dirname(__file__), "..", "..", "db", "posts_preprocessing.sql")


class _PlainTextSoup:
    def __init__(self: Self, text: str, parser: str) -> None:
        self.text = text

    def __call__(self: Self, tags: list[str]) -> list[Any]:
        return []

    def get_text(self: Self, separator: str) -> str:
        return self.text


def load_post_clean_content() -> Callable[[str], str]:
    with open(PREPROCESSING_SQL) as f:
        sql = f.read()
    match = re.search(r"FUNCTION post_clean_content\(.*?LANGUAGE plpython3u.*?AS \$\$\n(.*?)\$\$;", sql, re.S)
    assert match is not None, f"no post_clean_content body in {PREPROCESSING_SQL}"
    sys.modules.setdefault("plpy", types.ModuleType("plpy"))
    if importlib.util.find_spec("bs4") is None or importlib.util.find_spec("lxml") is None:
        bs4_stub = types.ModuleType("bs4")
        setattr(bs4_stub, "BeautifulSoup", _PlainTextSoup)
        sys.modules["bs4"] = bs4_stub
    namespace: dict[str, Any] = {}
    exec("def post_clean_content(_text_input):\n" + textwrap.indent(match.group(1), "    "), namespace)
    post_clean_content: Callable[[str], str] = namespace["post_clean_content"]
    return post_clean_content


def longest_run(text: str) -> int:
    return max((len(m.group(0)) for m in re.finditer(r"(.)\1*", text, re.S)), default=0)


class LongSymbolRuns(unittest.TestCase):
    clean = staticmethod(load_post_clean_content())

    def test_a_thousand_dots_collapse_to_16(self: Self) -> None:
        body = "seribu titik untuk mu " + "." * 41812 + " " + "." * 140
        out = self.clean(body)
        self.assertEqual(out, "seribu titik untuk mu " + "." * 16 + " " + "." * 16)
        self.assertLessEqual(longest_run(out), 16)

    def test_every_symbol_is_collapsed_but_letters_digits_and_whitespace_are_kept(self: Self) -> None:
        body = "-" * 40 + "a" * 40 + "!" * 17 + "7" * 40 + "\n" * 40 + "😀" * 30 + "=" * 16 + "~" * 100
        out = self.clean(body)
        self.assertEqual(out, "-" * 16 + "a" * 40 + "!" * 16 + "7" * 40 + "\n" * 40 + "😀" * 16 + "=" * 16 + "~" * 16)

    def test_runs_joined_by_a_removal_are_bounded_too(self: Self) -> None:
        self.assertEqual(self.clean("." * 10 + "**" + "." * 10), "." * 16)

    def test_text_without_a_run_over_16_is_unchanged(self: Self) -> None:
        body = "Wait... what?! --- really!!! ok ~~ " + "#" * 16 + " (c) 2016 ?? " + "-=" * 30
        self.assertEqual(self.clean(body), body)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Unit checks for the HAF image tag chosen by scripts/ci-helpers/compose_variables.sh.

Sources the script with sh under each find_haf_image outcome and reads back HAF_VERSION.
Needs only sh (git is optional: CI_PROJECT_DIR stands in for the checkout root).
"""
import os
import subprocess
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join("scripts", "ci-helpers", "compose_variables.sh")
SHA = "8de693b2812a040aa5c4365c232ebab8036a1d11"
MARK = "HAF_VERSION_RESULT="


def haf_version(**env: str) -> str:
    base = {k: v for k, v in os.environ.items()
            if not (k.startswith("HAF_") or k in ("TAG", "CI_PROJECT_DIR"))}
    base["CI_PROJECT_DIR"] = REPO
    base.update(env)
    out = subprocess.run(
        ["sh", "-c", f'. ./{SCRIPT}; echo "{MARK}$HAF_VERSION"'],
        cwd=REPO, env=base, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, check=True, timeout=30,
    ).stdout
    return [line[len(MARK):] for line in out.splitlines() if line.startswith(MARK)][-1]


class HafVersion(unittest.TestCase):
    def test_release_tag_fallback_uses_upstream_tag(self) -> None:
        self.assertEqual(haf_version(HAF_UPSTREAM_TAG="1.28.8-rc3", HAF_UPSTREAM_CACHE_HIT="true",
                                     HAF_UPSTREAM_FALLBACK="release-tag", HAF_UPSTREAM_COMMIT=SHA),
                         "1.28.8-rc3")

    def test_commit_image_found_uses_commit_tag(self) -> None:
        self.assertEqual(haf_version(HAF_UPSTREAM_TAG="8de693b2", HAF_UPSTREAM_CACHE_HIT="true",
                                     HAF_UPSTREAM_FALLBACK="false", HAF_UPSTREAM_COMMIT=SHA),
                         "8de693b2")

    def test_no_image_found_uses_latest(self) -> None:
        self.assertEqual(haf_version(HAF_UPSTREAM_CACHE_HIT="false", HAF_UPSTREAM_COMMIT=SHA), "latest")

    def test_developer_haf_commit_only_uses_short_sha(self) -> None:
        self.assertEqual(haf_version(HAF_COMMIT=SHA), "8de693b2")

    def test_nothing_set_uses_latest(self) -> None:
        self.assertEqual(haf_version(), "latest")

    def test_preset_haf_version_is_kept(self) -> None:
        self.assertEqual(haf_version(HAF_VERSION="foo", HAF_UPSTREAM_TAG="1.28.8-rc3"), "foo")


if __name__ == "__main__":
    unittest.main()

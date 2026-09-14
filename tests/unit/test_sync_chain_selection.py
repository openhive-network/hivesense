#!/usr/bin/env python3
"""Unit checks for the syncer's /sync-chains selection (scripts/sync_embeddings.py).

Run from the syncer image (no database or network needed):
    docker run --rm -v "$PWD/tests:/tests:ro" <syncer image> python /tests/unit/test_sync_chain_selection.py
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

CFG = dict(llm="model-a", embedding_dimensionality=768, document_prefix="passage: ",
           query_prefix="query: ", tokens_per_chunk=512, overlap_amount=0.15,
           min_token_threshold=75, max_embeddings_per_post=None)


def chain(uuid, **over):
    c = dict(CFG, sync_uuid=uuid, base_url=None, skipped_op_count=0)
    c.update(over)
    return c


class SelectChain(unittest.TestCase):
    def test_first_sync_takes_first_matching(self):
        chains = [chain("u-other", llm="model-b"), chain("u-match-1"), chain("u-match-2")]
        self.assertEqual(s.select_chain(chains, CFG, None)["sync_uuid"], "u-match-1")

    def test_first_sync_overlap_tolerance(self):
        self.assertEqual(s.select_chain([chain("u", overlap_amount=0.1500000001)], CFG, None)["sync_uuid"], "u")

    def test_first_sync_no_match_exits(self):
        with self.assertRaises(SystemExit):
            s.select_chain([chain("u", tokens_per_chunk=256)], CFG, None)

    def test_existing_uuid_found(self):
        chains = [chain("u-primary"), chain("u-mine", base_url="https://old/hivesense-api")]
        got = s.select_chain(chains, CFG, "u-mine")
        self.assertEqual(got["sync_uuid"], "u-mine")
        self.assertEqual(got["base_url"], "https://old/hivesense-api")

    def test_existing_uuid_absent_exits(self):
        with self.assertRaises(SystemExit):
            s.select_chain([chain("u-primary")], CFG, "u-gone")

    def test_existing_uuid_config_drift_exits(self):
        with self.assertRaises(SystemExit):
            s.select_chain([chain("u-mine", llm="model-b")], CFG, "u-mine")

    def test_empty_list_exits(self):
        with self.assertRaises(SystemExit):
            s.select_chain([], CFG, None)

    def test_config_mismatches(self):
        self.assertEqual(s.config_mismatches(CFG, dict(CFG, llm="x", tokens_per_chunk=1)),
                         ["llm", "tokens_per_chunk"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

# Continuing a sync chain through an embedding regeneration

Downstream hivesense nodes follow our embeddings through `/embedding-updates`,
identified by `sync_uuid`: the uuid names one sequence of `sync_seq`-numbered
operations. A regenerated node normally mints a fresh uuid, so every downstream
would stop with "UUID Mismatch" until it wiped its embeddings and re-downloaded
everything.

When the regeneration keeps the **same model and configuration** (for example a
splitter change), the old chain can instead be *rebased* onto the new node:

1. both the old and the new node stop at the same block;
2. the old node's chain (vectors, delete markers, post metadata) is dumped and
   loaded on the new node;
3. the new node diffs the old chain against its own embeddings, post by post;
4. a merged table set is built: the old rows (old `sync_seq`) for posts whose
   embeddings are unchanged, the new node's rows with `sync_seq` after the old
   tail for posts that differ, delete markers for posts that vanished;
5. the merged tables replace the new node's tables and the node takes over the
   old uuid and tail seq.

Downstreams see one batch of edits and carry on. The old chain's full history
is preserved, so nodes that were lagging, nodes bootstrapping from zero and
nodes syncing from a downstream all keep working. The old node is never
modified and stays available as a rollback until it is decommissioned.

The tooling lives in `db/legacy_rebase.sql` (installed with the app) and
`scripts/legacy_chain/`. Everything runs as `hivesense_owner`
(`SET ROLE hivesense_owner` from `haf_admin`).

## Requirements

* Same `llm`, `embedding_dimensionality`, `document_prefix`, `query_prefix`,
  `tokens_per_chunk`, `overlap_amount`, `min_token_threshold` and
  `max_embeddings_per_post` on both nodes. Old syncers compare exactly these
  keys with `/sync-settings` at startup and exit on any difference.
* `reduction_mode` is `none` or `slice`. PCA installs (`posts_vectors_reduced`)
  are not supported by the rebase tooling.
* Enough disk on the new node for a second copy of `posts_vectors` and its
  HNSW index while the merged set is built.
* Downstream sync will be frozen for the duration of the dump, load, diff and
  HNSW build (hours on a full node). End-user search stays up on the old node.

## Procedure

Terms: `S_O` = the old node's `max_visible_sync_seq` at the freeze, `U_old` its
`sync_uuid`, `B` the freeze block.

1. **Regenerate.** Install and sync the new node normally. Let it reach the
   live head and build its HNSW index (the build is discarded later, but this
   proves the node and gives a baseline for search checks).
2. **Freeze both nodes at the same block.** Set `--stop-at-block=B` for both
   block processors (`HIVESENSE_SYNC_ARGS=--stop-at-block=B` in haf_api_node)
   with `B` a little ahead of the head, and wait for both to stop. Downstreams
   drain to `S_O` within seconds and then idle.
3. **Dump the old chain** (old node, read-only):
   ```
   scripts/legacy_chain/dump_old_chain.sh --dir=/data/old_chain \
       --psql="docker compose exec -T haf psql -U haf_admin -d haf_block_log"
   ```
   Refuses to run while a block-processing session is connected. Writes
   `old_vectors.csv` (the big one), `old_deleted.csv`, `old_post_data.csv`,
   `old_root_posts.csv` and `old_status.txt` (`U_old|S_O|skipped|block`).
4. **Load and resolve** (new node):
   ```
   scripts/legacy_chain/load_old_chain.sh --dir=/data/old_chain --psql="..."
   psql ... -c "SET ROLE hivesense_owner; SELECT * FROM hivesense_app.rebase_resolve(B);"
   ```
   Old posts are matched to this node's hivemind by author and permlink (never
   by post id). Read the report:

   | metric | meaning |
   |---|---|
   | `old_posts_with_vectors_unresolved` | posts the old node embedded that this hivemind does not have (listed in `legacy_unresolved`) |
   | `old_root_posts_missing_here` | live root posts of the old hivemind absent here |
   | `new_root_posts_missing_in_old` | root posts this hivemind has (created by `B`) that the old one did not list |

   All three should be 0. Nonzero values mean the two hivemind versions index
   different post sets: ops for posts an old-hivemind downstream cannot resolve
   make `MISSING_POST_ACTION=exit` syncers halt. Decide before continuing.
5. **Diff:**
   ```
   SELECT * FROM hivesense_app.rebase_diff();          -- default max cosine distance 0.001
   SELECT * FROM hivesense_app.legacy_diff_histogram;  -- chunk-pair distance buckets
   ```
   Reasons: `gone` (old had vectors, we have none), `new` (we have, old had
   none), `rechunked` (chunk numbers differ or a chunk pair is farther than the
   threshold). The histogram must be bimodal: identical chunks land at or below
   `1e-5`, moved boundaries well above `1e-2`. Re-run with another threshold if
   the gap is elsewhere. Inspect examples with
   ```
   SELECT m.reason, ha.name, hpd.permlink FROM hivesense_app.legacy_merge_set m
     JOIN hivemind_app.hive_posts hp ON hp.id = m.post_id
     JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
     JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id LIMIT 50;
   ```
6. **Build:**
   ```
   SELECT * FROM hivesense_app.rebase_build_tables();
   SELECT hivesense_app.rebase_build_indexes();   -- the HNSW build; hours on a full node
   ```
   Builds `posts_vectors_merged`, `deleted_embeddings_merged`,
   `post_data_merged` next to the live tables; the live tables keep serving.
7. **Swap** (block processor must be stopped, the function checks):
   ```
   SELECT * FROM hivesense_app.rebase_swap();
   SELECT * FROM hivesense_app.rebase_verify();
   ```
   The swap renames tables and indexes in one transaction, sets
   `sync_uuid = U_old`, `max_visible_sync_seq = S_O + merge ops` and moves the
   sequence. `rebase_verify()` must show `ok = t` on every row: it replays what
   a downstream at `S_O` will receive and checks it is exactly the merge set.
8. **Cut over.** Point the public API at the new node and start its block
   processor without `--stop-at-block` (`docker compose start`, not `up -d`,
   which re-runs installers). Old-uuid syncers apply the merge batch and
   continue. Snapshots taken from now on carry `U_old` and the full history.
9. **Later:** keep the old node frozen for a few days as rollback, then
   `SELECT hivesense_app.rebase_cleanup();` drops the `*_pre_rebase` and
   staging tables.

Every step checks the recorded phase (`hivesense_app.legacy_rebase_state`) so
steps cannot be skipped or repeated out of order. To start over before the
swap, run `load_old_chain.sh` again.

## `/sync-chains`

Servers list the chains they can supply at `/sync-chains`, most preferred
first: the primary chain (this node's own embeddings, what `/sync-settings`
describes) followed by rows of `hivesense_app.sync_chains`. Each entry carries
the configuration keys above, `skipped_op_count`, and an optional `base_url`
naming the API host that actually serves that chain.

The syncer (`scripts/sync_embeddings.py`) uses it as follows: a node starting
from scratch adopts the first chain whose configuration matches its install; a
node that already has a `sync_uuid` requires that chain to be listed and
matching, and otherwise stops with an explicit message. Upstreams without the
endpoint (404) are handled with `/sync-settings` as before.

This is what makes future transitions cheap. If a later release changes the
model, or the new hivemind indexes posts the old one did not (so the old chain
cannot be rebased), the old node can keep running and the new node lists its
chain with `base_url` pointing at it:

```sql
INSERT INTO hivesense_app.sync_chains (sync_uuid, priority, base_url, llm,
    embedding_dimensionality, document_prefix, query_prefix, tokens_per_chunk,
    overlap_amount, min_token_threshold, max_embeddings_per_post, note)
VALUES ('<old uuid>', 10, 'https://old-api.example/hivesense-api', 'old-model', 768,
        'passage: ', 'query: ', 512, 0.15, 75, NULL, 'old 1.28 chain kept during transition');
```
Old-configuration downstreams then follow the old node; new installs adopt
the primary chain.

# One-time purge of deleted posts' vectors

hivemind deletes a post by setting `hive_posts.counter_deleted > 0` and keeps
its row and body. Block processing now drops a deleted post's vectors and
writes a tombstone (a delete op on `/embedding-updates`) for it, but posts
deleted before that change still have vectors on every node of the chain.
`hivesense_app.purge_deleted_post_vectors()` removes them once.

It runs **by hand, once, on the chain primary** (the node that generates
embeddings, `syncing_embeddings = FALSE`). It deletes the vectors of every post
with `counter_deleted > 0` and writes one tombstone per purged post with a
fresh `sync_seq`, then publishes them. Replicas do not run it. Their syncers
receive the tombstones as ordinary delete ops and drop the same vectors. Called
on a replica, it raises
`purge_deleted_post_vectors runs on the chain primary only; replicas receive the deletions through the sync path (/embedding-updates)`
and changes nothing. Nothing in the install or the block processor calls it.

## Before running it

* Every replica of the chain must run a syncer that includes this change.
  An older syncer resolves an author/permlink with an unordered `LIMIT 1`.
  When the deleted post was later re-posted under the same author/permlink,
  hivemind holds two rows for it, and the older syncer can apply the dead
  row's tombstone to the re-post. The current syncer compares the op's
  `last_vectors_block` with the re-post's `block_num_created` and keeps the
  re-post's vectors.
* Stop the block processor, or at least make sure it is not in the middle of a
  batch. The purge takes `sync_seq` values and publishes them, so a batch in
  flight could be left with numbers below the published maximum that syncers
  never fetch.

## Running it

As `hivesense_owner` on the primary's HAF database:

```bash
psql -d haf_block_log -U haf_admin -v ON_ERROR_STOP=on \
     -c "SET ROLE hivesense_owner;" \
     -c "SELECT hivesense_app.purge_deleted_post_vectors();"
```

It prints a notice and the number of purged posts:

```
NOTICE:  Purged the vectors of 1234 deleted post(s), tombstoned for downstream syncers
 purge_deleted_post_vectors
----------------------------
                       1234
```

The function makes one pass over `posts_vectors` in batches of 1000 posts
(pass another batch size as its argument) and runs in a single transaction.
On a full node expect it to take minutes. A second call finds nothing to purge,
returns 0 and writes no tombstone.

Then restart the block processor. Replicas pick up the deletions on their next
sync pages.

## When it is not needed

A chain built by a full re-embed with this change never stores vectors for a
deleted post, so it has nothing to purge. The step does not need to be repeated
after a re-embed, nor on a new primary built that way.

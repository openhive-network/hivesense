# hivesense under AIDEV

AIDEV verifies changes to this repository through the slots in `project.yaml`,
integrates them into `aidev/integration`, and hands that off to `develop` through a
merge request (as in hive/HAfAH, hive/haf and hive/hivemind): `aidev handoff hivesense
--session <name>` opens or updates the merge request, starts the GitLab pipeline on
`aidev/integration` and sets auto-merge (`branches.handoff` in `project.yaml`;
`aidev handoff status hivesense` follows it). Merge them
**keeping the source branch**: this project deletes source branches on merge by
default, and `aidev/integration` must survive (it is protected for that reason).
GitLab CI doesn't run for AIDEV branches (`ai/*`, `session/*`, pushes to
`aidev/integration`); see `.gitlab-ci.yml` `workflow:`. It still gates the merge into
`develop`: see [GitLab CI before merging into develop](#gitlab-ci-before-merging-into-develop).

## Branches

- `aidev/integration` — the integration branch. Automated work lands here and nowhere else.
- `ai/*` — one branch per task, created and deleted by the platform. Do not commit to them.
- `session/*` — a session's accumulated work, landed on the integration branch as a batch.

## Suites

`.aidev/run-checks.sh <suite> <step>...` runs the named steps and writes
`test-results/<suite>/junit.xml`, one test case per step, with the step's log tail as
the failure body; `embed-search`, `embed-slice`, `embed-pca` and `api-smoke` also
write one case per call (`embed-search.xml`, `embed-slice.xml`, `embed-pca.xml`,
`api-smoke.xml`).

| Step | What |
|---|---|
| `shellcheck` | ShellCheck (pinned 0.11.0, the release CI's `lint_bash_scripts` pins too) at warning severity on every `*.sh` — the files CI's `lint_bash_scripts` checks — and at default severity on `.aidev/`'s own scripts |
| `sqlfluff` | `sqlfluff lint` 2.1.4 with `.sqlfluff`, as CI's `lint_sql_scripts`; any violation fails |
| `unit` | `tests/unit` with python's `unittest` (no database, no network) |
| `sql-registered` | every `.sql` under `db/` and `endpoints/` is applied by `scripts/install_app.sh` |
| `stack-pins` | the HAF, hafah, reputation_tracker and hivemind images of `test-stack.compose.yml` match `.gitlab-ci.yml`'s `UPSTREAM_BRANCH` and `x-apps-release` (see [the stack](#the-haf-test-stack-test-stackcomposeyml)); fails naming each stale image and the expected branch. Reads only the tree, no registry |
| `install` | `scripts/install_app.sh` into the stack's HAF database as `haf_admin`, then `hivesense_app.init_local_sync_identity()` (what the block processor runs at start-up) `tests/test_sync_chains.sql` and `tests/test_early_block_processing.sql` (HAF's keep-monotonic replay state, from `hive.disable_indexes_of_irreversible('keep-monotonic')` in a rolled-back transaction: the context is delivered blocks, does not finalize, and no `hivesense_app` function reads a table with deferred core indexes). The runtime image carries `install_with_app_lock.py`, so `install_app.sh` re-runs itself under the app's exclusive install lock as in hivesense's install image; the step fails if the log has the `install_with_app_lock.py wrapper not found` WARNING or lacks the wrapper's `Acquired install lock for hivesense` |
| `events-id` | CI's `events_id_test` (#54), with CI's messages: set `hafd.contexts.events_id = 0` for `hivesense_app`, call the tree's `sync_embeddings.ensure_context_detached` with psycopg, expect `events_id = hive.unreachable_event_id()` |
| `install-lock` | CI's `lock_skip_test`: a background psql session holds the app's shared install lock (`pg_advisory_lock_shared(hashtext('hive_fork_manager_app_lock'), hashtext('hivesense'))`, as a block processor does), then `install_app.sh` runs with other options; it must exit 0, log `Skipping hivesense install … lock held by`, and leave the installed objects (by oid) and the configuration row unchanged. The holder is ended (client and server session) however the check ends. Runs after `install` |
| `reinstall` | `scripts/uninstall_app.sh`, then `install` again |
| `embed-search` | reinstall configured as CI's `sync` job (`--llm=all-minilm:l6-v2 --vector_size=384 --tokenizer-model=all-MiniLM-L6-v2 --ollama=http://ollama:11434`, empty prefixes, `--min-token-threshold=200`, see below), apply `seed_posts.sql`, check `posts_in_range` finds the seeded posts, embed them with `generate_embeddings_for_posts` and publish them; check `posts_vectors` holds a non-zero 384-dim embedding for every long seeded post and none for the short one; build the HNSW index with `ensure_indexes_are_created()` (what the block processor does on reaching HAF's head) and check the index `get_hnsw_index_name()` names exists; then the embedding-backed calls of `.aidev/hivesense_smoke.py embed-search` (below). Fails fast when the embedding server is down: before reinstalling it probes `http://ollama:11434/api/tags` (10 s timeout) and fails with `embedding server http://ollama:11434 did not answer` unless it lists the model; and `generate_embeddings_for_posts`, whose sync-path retries never give up, runs under `statement_timeout = '600s'` (PL/Python sees the cancel at its next retry notice, so up to one retry cycle later). The 600 s leave room for `ollama_embed`'s adaptive request timeout on a loaded host: each timed-out attempt doubles the next one's timeout (30 s, 60 s, 120 s, 240 s), so a slow but working server still answers within it. Finally, pass or fail, reinstalls as `install` does, so the steps after it see a fresh installation |
| `embed-slice` | `embed-search` in CI's slice configuration (`.gitlab-ci.yml` `slice_phase`): `--llm=hf.co/mixedbread-ai/mxbai-embed-xsmall-v1:F16 --use-reduced-embeddings=true --reduction-mode=slice --reduced-dim=256` and CI's query prefix `Represent this sentence for searching relevant passages: `, the other options as `embed-search`. Also checks the installed `reduction_mode`/`use_reduced_embeddings`/`reduced_dims` and that every long seeded post (not the short one) has non-zero 256-dim slices; the index is the slice expression index. Then reinstalls the default |
| `embed-pca` | `embed-search`'s model in PCA mode: `--reduction-mode=pca --reduced-dim=32 --reduced-matrix-source=<file>`, the matrix a deterministic orthonormal 32×384 projection the step writes (`test-results/<suite>/pca-matrix.json`; `run_pca.py` needs numpy and a corpus, and four posts would give a degenerate fit). Checks the configuration, `reducing_matrix` has 32 rows, every chunk of every long seeded post has a non-zero 32-dim row in `posts_vectors_reduced` (the short post none), the PCA HNSW index exists, and `.aidev/hivesense_smoke.py embed-pca`. Then reinstalls the default |
| `api-smoke` | `.aidev/hivesense_smoke.py`: PostgREST over the installed schema (as `docker/ci/compose.yml`'s `hivesense-postgrest` runs it), then calls to `/`, `get_hivesense_version`, `get_hivesense_sync_status`, `get_sync_settings`, `get_sync_chains`, `embedding_updates` (matching and unknown `sync_uuid`), `posts_by_ids_query` and `posts_similar`, each checked against what an empty chain with no embeddings answers |

| Slot | Steps | HAF stack |
|---|---|---|
| quick | shellcheck, sqlfluff, unit, sql-registered, stack-pins | no |
| coverage | unit, sql-registered | no |
| full, canary | quick's steps plus install, events-id, install-lock, reinstall, embed-search, embed-slice, embed-pca, api-smoke | yes |
| baseline | install, reinstall, embed-search, api-smoke | yes |

`static` and `system` are unbound: AIDEV runs neither for a project.

### `embed-search`

`seed_posts.sql` writes five root posts straight into the stack's empty hivemind
(accounts, permlinks, posts, post data; blocks 101–105): long posts on witness voting,
mountain hiking and a tomato sauce for pasta, a second long pasta post by another
author, and a one-sentence post (title only) below the token threshold.

The threshold is 200, not CI's 75: the pinned `all-MiniLM-L6-v2` `tokenizer.json`
pads (and truncates) every encode to 128 tokens and hivesense's chunker counts tokens
per sentence without turning that off, so every sentence counts 128 and no post ever
falls below 75. 200 separates the one-sentence post (128 padded, ~13 unpadded) from
the long ones (>= 2048 padded, >= 253 unpadded), so the check stays valid once the
chunker stops counting padding. The padding also makes each long post several chunks.

The checks assert rank order, never a similarity value:

| Case | Asserts |
|---|---|
| `posts_search.pasta` / `.hiking` / `.witness` | a query on one topic ranks that topic's posts above all others; the short post is never returned |
| `posts_similar.sauce` | the other pasta post comes first, the post itself is not returned |
| `posts_similar.unembedded` | the short (unembedded) post answers HTTP 200 with `[]` (#60) |
| `authors_search.hiking` | the hiking post's author comes first |
| `embedding_updates` | with the primary `sync_uuid`: one insert/update per embedded post, each with 384-dim embeddings; anything else is a `delete` without embeddings |

Account and post ids are not in ranking order, so embeddings that carry no meaning
(e.g. all zero) cannot tie-break into the expected ranking.

`embed-slice` and `embed-pca` run the same calls (check sets `embed-slice`,
`embed-pca`) unweakened: both modes run the ANN step on reduced vectors but rerank by
the full embedding, and the seeded corpus is far below the ANN candidate count, so
the full-mode ranks apply. mxbai-embed-xsmall-v1 ranks the seeded posts as
all-minilm does.

Not covered: block processing (`scripts/hivesense_block_processor.py`), `run_pca.py`
and the full bridge-post objects (the searches ask for stubs). See the next section for what GitLab CI still gates.

## GitLab CI before merging into develop

AIDEV can't run what needs docker-in-docker or a block log, so GitLab CI remains the
gate for:

- hivesense's image builds (`build_images`);
- block processing: the `main_loop.sql` scheduler/worker loop, `process_blocks.sh`,
  `hivesense_block_processor.py`;
- the 1M-block sync (`sync`: HAF replay, hivemind sync, embeddings in full, PCA and
  slice configurations) and `run_pca.py`;
- the rebase rehearsal (`legacy_rebase.sql`, `tests/integration/api_node/hivesense_rebase_test.sh`);
- the PostgREST rewriter;
- the JMeter benchmarks (and `tests/ai`).

**Before each merge of `aidev/integration` into `develop`, run a web- or API-triggered
pipeline on `aidev/integration`** (Build → Pipelines → Run pipeline, branch
`aidev/integration`; the `workflow:` rules of `.gitlab-ci.yml` run exactly those for
that branch) **and merge only when it is green.** `aidev handoff hivesense` does both:
it starts that pipeline (an API-sourced one) and arms merge-when-pipeline-succeeds on
the hand-off merge request. A promote into `aidev/integration` while that auto-merge is
pending waits for it, since moving the source branch would cancel it.

## The HAF test stack (`test-stack.compose.yml`)

`haf`: the HAF testnet image CI resolves for `UPSTREAM_BRANCH` `develop` (HAF commit
`ce114878`, the first with the keep-monotonic early block processing API), started empty with the `sleep_infinity` maintenance script. It already
carries pgvector, plpython3u and the python `tokenizers` / `pysbd` modules hivesense's
SQL imports. Then one-shot services install hivesense's dependencies in the order
`docker/ci/compose.yml` does: `haf-init` (`hive.initialize_extension_data()`, what hived
does when it first connects), `hafah-install` and `reputation-tracker-install`, then
`hivemind-install` (`setup`). `ready` turns healthy once `hivemind_endpoints` exists,
which is what `docker compose up --wait` waits for. About 30 s on a warm host.

`ollama`: CI's `hivesense/ollama:0.18.0` with CI's models pulled at build time,
`all-minilm:l6-v2` and the slice-mode `hf.co/mixedbread-ai/mxbai-embed-xsmall-v1:F16`
(Matryoshka-trained, 384 dims, MiniLM tokenizer), so the stack pulls nothing at run
time; healthy once `ollama list` shows `all-minilm:l6-v2` (the embed steps probe for
their own model). The same image carries the MiniLM `tokenizer.json` both models use
(HF commit `1110a243`) at
`/tokenizer-files/all-MiniLM-L6-v2/`; the one-shot `tokenizer-copy` copies it into
the `tokenizer-files` volume, which `haf` mounts read-only at
`/home/hived/tokenizer-files`, where hivesense's chunker reads it
(`db/posts_preprocessing.sql`). `haf` starts after the copy.

hafah, reputation_tracker and hivemind are their `1.28.8-rc3` release images, recorded
in the top-level `x-apps-release`: `develop` has no app release images, so while HAF
follows `develop` they stay at the newest release. Each of the four is pinned as
`repo:tag@sha256:<digest>`: docker pulls the digest, and the tag says what the digest
is (the HAF commit for `haf`, the release for the others). The top-level
`x-haf-upstream-branch` records the HAF branch the commit was resolved for. CI
resolves the newest HAF image for `UPSTREAM_BRANCH` on every run; `stack-pins` fails
the `quick` slot when `x-haf-upstream-branch` differs from `.gitlab-ci.yml`'s
`UPSTREAM_BRANCH`, when a release tag differs from `x-apps-release`, or when
`x-apps-release` differs from a release `UPSTREAM_BRANCH`, naming each stale image.
When it moves, re-pin all four images together: HAF to
`registry.gitlab.syncad.com/hive/haf/testnet:<new HAF commit, 8 chars>@<its linux/amd64
digest>` with `x-haf-upstream-branch` set to the branch, the others to
`<repo>:<release>@<digest>` with `x-apps-release` set to the release. (A newer HAF commit on the same
branch isn't detected: that needs the registry.)

To run the stack checks by hand:

```bash
docker compose -p hivesense-checks -f .aidev/test-stack.compose.yml up -d --wait
docker run --rm --user "$(id -u):$(id -g)" --network hivesense-checks_default -v "$PWD:/w" -w /w \
    "$(grep -o 'registry[^"]*aidev-tests@sha256:[0-9a-f]*' .aidev/project.yaml)" \
    .aidev/run-checks.sh full shellcheck sqlfluff unit sql-registered stack-pins install events-id install-lock reinstall embed-search embed-slice embed-pca api-smoke
docker compose -p hivesense-checks -f .aidev/test-stack.compose.yml down -v
```

## The embedding server image (`runtime/ollama.Dockerfile`)

`registry.gitlab.syncad.com/hive/hivesense/aidev-ollama`, pinned by digest in
`test-stack.compose.yml`. To change the model, the tokenizer or the base, edit
`runtime/ollama.Dockerfile` (keep the `FROM` digest and the `ADD --checksum` pinned),
then rebuild and re-pin **in the same commit**:

```bash
.aidev/runtime/build.sh --image=ollama --push
# put the printed repo@sha256:<digest> into test-stack.compose.yml's `ollama` image
```

A new model also means new install options in `run-checks.sh` (`EMBEDDING_MODEL` or
`SLICE_MODEL`, `--vector_size`, `--tokenizer-model`) and `EMBEDDING_DIMS` in
`hivesense_smoke.py`; re-check that the seeded posts still rank as asserted.

## The test runtime image (`runtime/`)

The checks run in a container with your uid: `python:3.14-slim-bookworm` (the syncer's
python) with `postgresql-client`, the `postgrest` binary of
`common-ci-configuration/postgrest`, ShellCheck 0.11.0, sqlfluff 2.1.4 (with click
8.1.6, which 2.1.4 needs), `requests`, `psycopg`, `psycopg2` for the unit tests, and
`/usr/local/bin/install_with_app_lock.py` from the `common-ci-configuration/psql` image
hivesense's `Dockerfile` names in `PSQL_CLIENT_VERSION` (it needs only python3 and
psycopg2), so `install_app.sh` takes its advisory-lock path; all bases pinned by
digest.

CI's `lint_bash_scripts` image (`koalaman/shellcheck-alpine`) and this image pin the
same ShellCheck release, each by digest, so the `shellcheck` step and CI reach the
same verdict. Bump them together: change the release in `.gitlab-ci.yml` and in
`runtime/Dockerfile` in one commit, then rebuild and re-pin as below.

When `runtime/Dockerfile` changes, rebuild and re-pin **in the same commit**:

```bash
.aidev/runtime/build.sh --push   # registry digest if aidev-<input hash> exists, else build + push
# put the printed repo@sha256:<digest> into project.yaml environment.image
```

To build through a pull-through registry cache near the build host, set
`AIDEV_IMAGE_CACHE_BY_REGION` to `region=host:port` pairs, e.g.
`us=steem-9.syncad.com:5001,*=steem-9.syncad.com:5001`: a pair applies when its region
is a label of the host's FQDN, and `*` applies to any other host. Unset, the image is
built straight from `registry.gitlab.syncad.com`.

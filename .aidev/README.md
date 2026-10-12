# hivesense under AIDEV

AIDEV verifies changes to this repository through the slots in `project.yaml`,
integrates them into `aidev/integration`, and people merge that into `develop`
through merge requests (as in hive/HAfAH, hive/haf and hive/hivemind). Merge them
**keeping the source branch**: this project deletes source branches on merge by
default, and `aidev/integration` must survive (it is protected for that reason).
GitLab CI doesn't run for AIDEV branches (`ai/*`, `session/*`, pushes to
`aidev/integration`); see `.gitlab-ci.yml` `workflow:`.

## Branches

- `aidev/integration` — the integration branch. Automated work lands here and nowhere else.
- `ai/*` — one branch per task, created and deleted by the platform. Do not commit to them.
- `session/*` — a session's accumulated work, landed on the integration branch as a batch.

## Suites

`.aidev/run-checks.sh <suite> <step>...` runs the named steps and writes
`test-results/<suite>/junit.xml`, one test case per step, with the step's log tail as
the failure body; `api-smoke` also writes one case per call (`api-smoke.xml`).

| Step | What |
|---|---|
| `shellcheck` | ShellCheck (pinned 0.10.0) at warning severity on every `*.sh` — the files CI's `lint_bash_scripts` checks — and at default severity on `.aidev/`'s own scripts |
| `sqlfluff` | `sqlfluff lint` 2.1.4 with `.sqlfluff`, as CI's `lint_sql_scripts`; any violation fails |
| `unit` | `tests/unit` with python's `unittest` (no database, no network) |
| `sql-registered` | every `.sql` under `db/` and `endpoints/` is applied by `scripts/install_app.sh` |
| `install` | `scripts/install_app.sh` into the stack's HAF database as `haf_admin`, then `hivesense_app.init_local_sync_identity()` (what the block processor runs at start-up) and `tests/test_sync_chains.sql` |
| `reinstall` | `scripts/uninstall_app.sh`, then `install` again |
| `api-smoke` | `.aidev/hivesense_smoke.py`: PostgREST over the installed schema (as `docker/ci/compose.yml`'s `hivesense-postgrest` runs it), then calls to `/`, `get_hivesense_version`, `get_hivesense_sync_status`, `get_sync_settings`, `get_sync_chains`, `embedding_updates` (matching and unknown `sync_uuid`), `posts_by_ids_query` and `posts_similar`, each checked against what an empty chain with no embeddings answers |

| Slot | Steps | HAF stack |
|---|---|---|
| quick | shellcheck, sqlfluff, unit, sql-registered | no |
| coverage | unit, sql-registered | no |
| full, canary | quick's steps plus install, reinstall, api-smoke | yes |
| baseline | install, reinstall, api-smoke | yes |

`static` and `system` are unbound: AIDEV runs neither for a project.

Not covered: anything that needs embeddings. The stack has no Ollama, so block
processing, `posts_search` / `authors_search` (which embed the query) and the
similarity results themselves are untested here. CI's `sync` job (a 1M-block replay,
hivemind sync and Ollama embeddings in full, PCA and slice configurations, the rebase
rehearsal), the JMeter benchmarks and `tests/ai` stay in GitLab CI.

## The HAF test stack (`test-stack.compose.yml`)

`haf`: the HAF testnet image CI resolves for `UPSTREAM_BRANCH` `1.28.8-rc3` (HAF commit
`8de693b2`), started empty with the `sleep_infinity` maintenance script. It already
carries pgvector, plpython3u and the python `tokenizers` / `pysbd` modules hivesense's
SQL imports. Then one-shot services install hivesense's dependencies in the order
`docker/ci/compose.yml` does: `haf-init` (`hive.initialize_extension_data()`, what hived
does when it first connects), `hafah-install` and `reputation-tracker-install`, then
`hivemind-install` (`setup`). `ready` turns healthy once `hivemind_endpoints` exists,
which is what `docker compose up --wait` waits for. About 30 s on a warm host.

hafah, reputation_tracker and hivemind are their `1.28.8-rc3` release images. When
`.gitlab-ci.yml`'s `UPSTREAM_BRANCH` moves, re-pin all four images together: the HAF
digest to `registry.gitlab.syncad.com/hive/haf/testnet:<new HAF commit, 8 chars>`, the
others to their matching release tags.

To run the stack checks by hand:

```bash
docker compose -p hivesense-checks -f .aidev/test-stack.compose.yml up -d --wait
docker run --rm --user "$(id -u):$(id -g)" --network hivesense-checks_default -v "$PWD:/w" -w /w \
    "$(grep -o 'registry[^"]*aidev-tests@sha256:[0-9a-f]*' .aidev/project.yaml)" \
    .aidev/run-checks.sh full shellcheck sqlfluff unit sql-registered install reinstall api-smoke
docker compose -p hivesense-checks -f .aidev/test-stack.compose.yml down -v
```

## The test runtime image (`runtime/`)

The checks run in a container with your uid: `python:3.14-slim-bookworm` (the syncer's
python) with `postgresql-client`, the `postgrest` binary of
`common-ci-configuration/postgrest`, ShellCheck 0.10.0, sqlfluff 2.1.4 (with click
8.1.6, which 2.1.4 needs), and `requests`, `psycopg`, `psycopg2` for the unit tests,
all bases pinned by digest.

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

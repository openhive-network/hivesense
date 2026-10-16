# The image AIDEV runs this project's checks in (`environment.image` in
# .aidev/project.yaml). Checks run with the caller's uid and, for the slots that
# start the HAF test stack, on that stack's network.
#
#   python:3.14-slim-bookworm (the syncer image's python) + postgresql-client, git
#   + the postgrest binary of common-ci-configuration/postgrest, for `api-smoke`
#   + shellcheck 0.11.0 (static binary, the release .gitlab-ci.yml's lint_bash_scripts
#     pins too), for `shellcheck`
#   + sqlfluff 2.1.4 (the version CI's lint_sql_scripts job runs), for `sqlfluff`
#   + requests, psycopg and psycopg2, which scripts/sync_embeddings.py and
#     scripts/hivesense_block_processor.py import, for `unit`
#   + /usr/local/bin/install_with_app_lock.py from the psql image the hivesense
#     Dockerfile's PSQL_CLIENT_VERSION names, so `install` takes install_app.sh's
#     advisory-lock path (it needs only python3 and psycopg2)
#
# Pinned: a lint step's verdict must not move with a new release. The Dockerfile is
# the only input (nothing is copied from the tree). Build and pin it with
# .aidev/runtime/build.sh; see .aidev/README.md.
FROM registry.gitlab.syncad.com/hive/common-ci-configuration/postgrest@sha256:ad2d14b8699accf5d1fccf8314b25d835e6aaddadaec35597a5dac1f002eb457 AS postgrest
FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:3839feb0c30846aa3ae262143f216a3c1a0fa20b@sha256:6a3794d9fdc4e0590789fc01e48539bcd73273715e3b69dd1f45d3ecde8b1cde AS psql
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d AS shellcheck

FROM python:3.14-slim-bookworm@sha256:48b13b003dda20b16f9442b8475aa05fe21bf6579a8c881db92ffb4d8fd20f83

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends postgresql-client git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=postgrest /bin/postgrest /usr/local/bin/postgrest
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=psql /usr/local/bin/install_with_app_lock.py /usr/local/bin/install_with_app_lock.py

# click at the version sqlfluff/sqlfluff:2.1.4 ships: sqlfluff 2.1.4 fails on click >= 8.2.
RUN pip install --no-cache-dir sqlfluff==2.1.4 click==8.1.6 requests==2.32.5 'psycopg[binary]==3.2.10' psycopg2-binary==2.9.11

ENV HOME=/tmp PYTHONDONTWRITEBYTECODE=1
ENTRYPOINT []
CMD ["bash"]

# The image AIDEV runs this project's checks in. AIDEV builds it on the image
# .aidev/project.yaml's `environment.base` follows (common-ci-configuration's
# python-test-tools, the image CI's lint jobs run in), passed as BASE_IMAGE, and
# rebuilds it when that tag moves. Checks run with the caller's uid and, for the
# slots that start the HAF test stack, on that stack's network.
#
#   BASE_IMAGE: python, postgresql-client, git, postgrest (for `api-smoke`),
#     shellcheck and sqlfluff (for `shellcheck` and `sqlfluff`), at the versions
#     common-ci-configuration publishes; this file pins no tool version
#   + psycopg and psycopg2, which scripts/sync_embeddings.py and
#     scripts/hivesense_block_processor.py import, for `unit` (unpinned, as in
#     Dockerfile.syncer)
#   + /usr/local/bin/install_with_app_lock.py from the psql image the hivesense
#     Dockerfile's PSQL_CLIENT_VERSION names, so `install` takes install_app.sh's
#     advisory-lock path (it needs only python3 and psycopg2)
#
# Nothing is copied from the tree. See .aidev/README.md.
ARG BASE_IMAGE
FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:3839feb0c30846aa3ae262143f216a3c1a0fa20b@sha256:6a3794d9fdc4e0590789fc01e48539bcd73273715e3b69dd1f45d3ecde8b1cde AS psql

FROM ${BASE_IMAGE}

COPY --from=psql /usr/local/bin/install_with_app_lock.py /usr/local/bin/install_with_app_lock.py

RUN pip install --no-cache-dir 'psycopg[binary]' psycopg2-binary

ENV HOME=/tmp PYTHONDONTWRITEBYTECODE=1
ENTRYPOINT []
CMD ["bash"]

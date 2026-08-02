# docker build -t hivesense:local .
# syntax=docker/dockerfile:1.5
# Pinned to the c-c-c develop SHA tag that introduces python3 + py3-psycopg2
# + /usr/local/bin/install_with_app_lock.py (the wrapper used by install_app.sh).
# Bump when c-c-c publishes a new semver tag that includes the wrapper.
ARG PSQL_CLIENT_VERSION=b80b52472f5bf6a685c95f74b9837cc1adbf7ddc
FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:${PSQL_CLIENT_VERSION} AS psql_client

USER root
RUN <<EOF
  set -e
  apk add --no-cache curl su-exec
  adduser -s /bin/bash -G users -D "hived"
EOF

USER hived
WORKDIR /home/hived

ENTRYPOINT [ "/bin/bash", "-c" ]

FROM psql_client AS version-injection
USER root
ARG API_VERSION="dev"
COPY endpoints /tmp/src/endpoints
WORKDIR /tmp/src
RUN sed -i 's|"version": "[^"]*"|"version": "'"$API_VERSION"'"|' endpoints/endpoint_schema.sql \
    && sed -i 's|^  version: .*|  version: '"$API_VERSION"'|' endpoints/endpoint_schema.sql

FROM psql_client AS full

ARG BUILD_TIME
ARG GIT_COMMIT_SHA
ARG GIT_CURRENT_BRANCH
ARG GIT_LAST_LOG_MESSAGE
ARG GIT_LAST_COMMITTER
ARG GIT_LAST_COMMIT_DATE
LABEL org.opencontainers.image.created="$BUILD_TIME"
LABEL org.opencontainers.image.url="https://hive.io/"
LABEL org.opencontainers.image.documentation="https://gitlab.syncad.com/hive/reputation_tracker"
LABEL org.opencontainers.image.source="https://gitlab.syncad.com/hive/reputation_tracker"
LABEL org.opencontainers.image.revision="$GIT_COMMIT_SHA"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.ref.name="HiveSense"
LABEL org.opencontainers.image.title="HiveSense Image"
LABEL org.opencontainers.image.description="Runs HiveSense application"
LABEL io.hive.image.branch="$GIT_CURRENT_BRANCH"
LABEL io.hive.image.commit.log_message="$GIT_LAST_LOG_MESSAGE"
LABEL io.hive.image.commit.author="$GIT_LAST_COMMITTER"
LABEL io.hive.image.commit.date="$GIT_LAST_COMMIT_DATE"

# #45: carry the git hash to container runtime so install_app.sh can record it in
# the version table (SET_VERSION), which the /version endpoint serves.
ENV HIVESENSE_GIT_HASH="$GIT_COMMIT_SHA"

USER root

RUN <<EOF
  set -e
  mkdir /app
  chown hived /app
EOF

COPY --chown=hived:users scripts/install_app.sh /app/scripts/install_app.sh
COPY --chown=hived:users scripts/uninstall_app.sh /app/scripts/uninstall_app.sh
COPY --chown=hived:users scripts/process_blocks.sh /app/scripts/process_blocks.sh
COPY --chown=hived:users scripts/matrix_handler.sh /app/scripts/matrix_handler.sh
COPY --chown=hived:users db /app/db
COPY --chown=hived:users --from=version-injection /tmp/src/endpoints /app/endpoints
COPY docker/scripts/docker-entrypoint.sh /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

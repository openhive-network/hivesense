#!/bin/sh -x

# source the file to get environment set for docker compose, i.e when You want to call docker compose down
# with exact the same environment like when starting with start-ci-test-environment

NUMBER_OF_BLOCKS_TO_SYNC=1000000

ROOT_SRC_PATH="$(git rev-parse --show-superproject-working-tree || git rev-parse --show-toplevel)"
ROOT_SRC_PATH="${CI_PROJECT_DIR:-$ROOT_SRC_PATH}"

# Get Git SHAs
# HAF version comes from HAF_COMMIT env var (set by CI from find_haf_image job)
# or HAF_UPSTREAM_COMMIT directly. Falls back to HAF_VERSION if already set.
if [ -z "${HAF_VERSION:-}" ]; then
    HAF_VERSION="${HAF_COMMIT:-${HAF_UPSTREAM_COMMIT:-}}"
    if [ -z "$HAF_VERSION" ]; then
        echo "ERROR: HAF_COMMIT or HAF_UPSTREAM_COMMIT must be set (no HAF submodule)"
        exit 1
    fi
    # Use short SHA (8 chars) for image tag
    HAF_VERSION=$(echo "$HAF_VERSION" | cut -c1-8)
fi

# Hivemind version must be provided via environment variable
# No submodule dependency - CI should set HIVEMIND_VERSION
if [ -z "${HIVEMIND_VERSION:-}" ]; then
    # Default to a stable version if not provided
    # This should match the version of hivemind compatible with the HAF version being used
    HIVEMIND_VERSION="${HIVE_API_NODE_VERSION:-1.27.11}"
    echo "WARN: HIVEMIND_VERSION not set, using default: $HIVEMIND_VERSION"
fi

# Reputation tracker version - use REPUTATION_TRACKER_VERSION if set, otherwise default
if [ -z "${REPUTATION_TRACKER_VERSION:-}" ]; then
    REPUTATION_TRACKER_VERSION="${HIVE_API_NODE_VERSION:-1.27.12rc2}"
fi

GIT_COMMIT_SHA=$(git -C "$(git rev-parse --show-superproject-working-tree --show-toplevel | head -1)" rev-parse HEAD || true)
HIVESENSE_TAG=${TAG:-$(echo "$GIT_COMMIT_SHA" | cut -c1-8)}

HIVE_API_NODE_REGISTRY="registry.gitlab.syncad.com/hive"
PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME:-"localhost"}

# HAF and Hivemind
# HAF_VERSION is set above from HAF_COMMIT env var
ARGUMENTS="--replay-blockchain --stop-at-block=${NUMBER_OF_BLOCKS_TO_SYNC}"
# HIVEMIND_VERSION is set above from env var
export REPUTATION_TRACKER_VERSION
HIVEMIND_SYNC_ARGS="--test-max-block=${NUMBER_OF_BLOCKS_TO_SYNC}"

# Hivesense
HIVESENSE_IMAGE="registry.gitlab.syncad.com/hive/hivesense"
HIVESENSE_VERSION="$HIVESENSE_TAG"
HIVESENSE_REWRITER_IMAGE="registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter"

HIVESENSE_SYNC_ARGS="--stop-at-block=${NUMBER_OF_BLOCKS_TO_SYNC}"

HIVESENSE_OLLAMA=http://hivesense-ollama:11434
HIVESENSE_MODEL=all-minilm:l6-v2
HIVESENSE_VECTOR_SIZE=384
HIVESENSE_START_BLOCK=1
HIVESENSE_WORKERS=8
HIVESENSE_STOP_AT_BLOCK=${NUMBER_OF_BLOCKS_TO_SYNC}

export ZPOOL_MOUNT_POINT HIVE_API_NODE_REGISTRY TOP_LEVEL_DATASET_MOUNTPOINT
export HAF_IMAGE HAF_VERSION ARGUMENTS HAF_DATA_DIRECTORY
export HIVEMIND_VERSION HIVEMIND_SYNC_ARGS
export HIVESENSE_IMAGE HIVESENSE_VERSION HIVESENSE_REWRITER_IMAGE HIVESENSE_INSTALLATION_ARGS HIVESENSE_OLLAMA_MODEL
export HIVESENSE_SYNC_ARGS PUBLIC_HOSTNAME
export HIVESENSE_OLLAMA HIVESENSE_MODEL HIVESENSE_VECTOR_SIZE HIVESENSE_START_BLOCK HIVESENSE_WORKERS HIVESENSE_STOP_AT_BLOCK

# End of Docker Compose environment variables ##########################################################################

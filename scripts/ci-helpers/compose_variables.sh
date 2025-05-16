#!/bin/sh -x

# source the file to get environment set for docker compose, i.e when You want to call docker compose down
# with exact the same environment like when starting with start-ci-test-environment

NUMBER_OF_BLOCKS_TO_SYNC=1000000

ROOT_SRC_PATH="$(git rev-parse --show-superproject-working-tree || git rev-parse --show-toplevel)"
ROOT_SRC_PATH="${CI_PROJECT_DIR:-$ROOT_SRC_PATH}"

# Get Git SHAs
HAF_SUBMODULE_SHA=$(
    git -C "${ROOT_SRC_PATH}/submodules/haf" describe --tags --exact-match HEAD 2>/dev/null ||
    git -C "${ROOT_SRC_PATH}/submodules/haf" rev-parse --short=8 HEAD
)
HIVEMIND_NODE_SUBMODULE_SHA=$(
    git -C "${ROOT_SRC_PATH}/submodules/hivemind" describe --tags --exact-match HEAD 2>/dev/null ||
    git -C "${ROOT_SRC_PATH}/submodules/hivemind" rev-parse --short=8 HEAD
)

GIT_COMMIT_SHA=$(git -C "$(git rev-parse --show-superproject-working-tree --show-toplevel | head -1)" rev-parse HEAD || true)
HIVESENSE_TAG=${TAG:-$(echo "$GIT_COMMIT_SHA" | cut -c1-8)}

COMPOSE_PROFILES="core,admin,servers,hivemind,monitoring,ollama,hivesense"
HIVE_API_NODE_REGISTRY="registry.gitlab.syncad.com/hive"
PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME:-"localhost"}

# HAF and Hivemind
HAF_IMAGE="registry.gitlab.syncad.com/hive/hivesense/haf/ai-instance"
HAF_VERSION="$HAF_SUBMODULE_SHA"
ARGUMENTS="--replay-blockchain --block-stats-report-output=NOTIFY --block-stats-report-type=FULL --notifications-endpoint=hived-pme:9185 --stop-at-block=${NUMBER_OF_BLOCKS_TO_SYNC}"
HIVEMIND_VERSION="$HIVEMIND_NODE_SUBMODULE_SHA"
HIVEMIND_SYNC_ARGS="--test-max-block=${NUMBER_OF_BLOCKS_TO_SYNC}"

# Hivesense
HIVESENSE_IMAGE="registry.gitlab.syncad.com/hive/hivesense"
HIVESENSE_VERSION="$HIVESENSE_TAG"
HIVESENSE_REWRITER_IMAGE="registry.gitlab.syncad.com/hive/hivesense/rewiter"

HIVESENSE_SYNC_ARGS="--stop-at-block=${NUMBER_OF_BLOCKS_TO_SYNC}"

HIVESENSE_OLLAMA=http://hivesense-ollama:11434
HIVESENSE_MODEL=yxchia/multilingual-e5-base:F16
HIVESENSE_VECTOR_SIZE=768
HIVESENSE_START_BLOCK=1
HIVESENSE_WORKERS=16

export ZPOOL_MOUNT_POINT COMPOSE_PROFILES HIVE_API_NODE_REGISTRY TOP_LEVEL_DATASET_MOUNTPOINT
export HAF_IMAGE HAF_VERSION ARGUMENTS HAF_DATA_DIRECTORY
export HIVEMIND_VERSION HIVEMIND_SYNC_ARGS
export HIVESENSE_IMAGE HIVESENSE_VERSION HIVESENSE_REWRITER_IMAGE HIVESENSE_INSTALLATION_ARGS HIVESENSE_OLLAMA_MODEL
export HIVESENSE_SYNC_ARGS PUBLIC_HOSTNAME
export HIVESENSE_OLLAMA HIVESENSE_MODEL HIVESENSE_VECTOR_SIZE HIVESENSE_START_BLOCK HIVESENSE_WORKERS

# End of Docker Compose environment variables ##########################################################################


#!/bin/sh -x

# shellcheck disable=SC1091

set -e

print_help() {
cat <<EOF
Usage: $0 [OPTION[=VALUE]]...

Script that starts test environment for use with CI test jobs.
To start a local environment use Docker Compose directly. See docker/README.md for details.
OPTIONS:
    --block-log-directory=PATH  Directory with Hive blocklog directory to copy into datadir
    --haf-data-directory=PATH   HAF Data directory path (default: /srv/haf/data)
    --help|-h|-?                Display this help screen and exit
EOF
}

# Get absolute path to this script
SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)
ROOT_SRC_PATH="$SCRIPTPATH/../.."

. "${SCRIPTPATH}/compose_variables.sh"

MOUNT_POINT=/

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --block-log-directory=*)
        BLOCK_LOG_DIRECTORY="${1#*=}"
        ;;
    --haf-data-directory=*)
        MOUNT_POINT="${1#*=}"
        ;;
    --help|-h|-\?)
        print_help
        exit 0
        ;;
    *)
        echo "ERROR: '$1' is not a valid option/positional argument"
        echo
        print_help
        exit 2
        ;;
  esac
  shift
done

CI_PROJECT_DIR=${CI_PROJECT_DIR:-$ROOT_SRC_PATH}

# Docker Compose environment variables #################################################################################
# API NODE internals
ZPOOL_MOUNT_POINT="${MOUNT_POINT}/haf-pool"
HAF_DATA_DIRECTORY="${ZPOOL_MOUNT_POINT}/haf-datadir"
TOP_LEVEL_DATASET_MOUNTPOINT="${ZPOOL_MOUNT_POINT}/haf-datadir"
HAF_SHM_DIRECTORY="${TOP_LEVEL_DATASET_MOUNTPOINT}/shared_memory"

export ZPOOL_MOUNT_POINT TOP_LEVEL_DATASET_MOUNTPOINT HAF_DATA_DIRECTORY HAF_SHM_DIRECTORY

# Create directories using local script (no submodule dependency)
"${ROOT_SRC_PATH}/docker/ci/create_directories.sh" --data-dir="${HAF_DATA_DIRECTORY}"

if [ -n "${BLOCK_LOG_DIRECTORY}" ]; then
  cp "${BLOCK_LOG_DIRECTORY}/block_log" "${HAF_DATA_DIRECTORY}/blockchain/block_log"
  cp "${BLOCK_LOG_DIRECTORY}/block_log.artifacts" "${HAF_DATA_DIRECTORY}/blockchain/block_log.artifacts"
  chmod a+w "${HAF_DATA_DIRECTORY}/blockchain/block_log"
  chmod a+w "${HAF_DATA_DIRECTORY}/blockchain/block_log.artifacts"
fi

# Start Docker Compose using local CI compose file
COMPOSE_DIR="${ROOT_SRC_PATH}/docker/ci"

# Save current dir and move into CI compose directory
ORIGINAL_DIR=$(pwd)
cd "$COMPOSE_DIR"
  timeout -s INT -k 1m 20m docker compose up --detach --quiet-pull
cd "$ORIGINAL_DIR"

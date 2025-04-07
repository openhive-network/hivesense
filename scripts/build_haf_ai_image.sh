#! /bin/bash -x

set -euo pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
SCRIPTSDIR="$SCRIPTPATH/.."

BUILD_IMAGE_TAG=""
IMAGE_TAG_PREFIX=""
SRCROOTDIR="${SCRIPTSDIR}"
REGISTRY="${CI_REGISTRY:-registry.gitlab.syncad.com}"
REGISTRY="${REGISTRY}/hive/haf/"

HAF_AI_INSTANCE_REGISTRY="registry.gitlab.syncad.com/ickiewicz/hivesens/haf/"


HAF_SUBMODULE_SHA=$(git -C submodules/haf describe --tags --exact-match HEAD 2>/dev/null || git -C submodules/haf rev-parse --short=8 HEAD)
BUILD_IMAGE_TAG=${HAF_SUBMODULE_SHA}

print_help () {
cat <<-EOF
  Usage: $0 <src_dir> [OPTION[=VALUE]]...

  Builds docker image containing Hived installation
  OPTIONS:
      --push                    Push built images to registry
      --network-type=TYPE       Allows to specify type of blockchain network supported by built hived. Allowed values: mainnet, testnet, mirrornet
      --help|-h|-?              Display this help screen and exit
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --push)
          PUSH=1
          ;;
    --network-type=*)
        type="${1#*=}"

        case $type in
          "testnet"*)
            IMAGE_TAG_PREFIX=testnet-
            ;;
          "mirrornet"*)
            IMAGE_TAG_PREFIX=mirrornet-
            ;;
          "mainnet"*)
            IMAGE_TAG_PREFIX=
            ;;
           *)
            echo "ERROR: '$type' is not a valid network type"
            echo
            exit 3
        esac
        ;;
    --help|-h|-?)
        print_help
        exit 0
        ;;
    *)
        if [ -z "$SRCROOTDIR" ];
        then
          SRCROOTDIR="${1}"
        else
          echo "ERROR: '$1' is not a valid option/positional argument"
          echo
          print_help
          exit 2
        fi
        ;;
    esac
    shift
done

AI_INSTANCE_IMAGE_PATH="${HAF_AI_INSTANCE_REGISTRY}${IMAGE_TAG_PREFIX}ai-instance:${BUILD_IMAGE_TAG}"

docker build --progress=plain --target=ai-instance \
  --build-arg REGISTRY_IMAGE="${REGISTRY}" \
  --build-arg HAF_TAG="${BUILD_IMAGE_TAG}" \
  --tag "${AI_INSTANCE_IMAGE_PATH}" \
  --file Dockerfile.haf_ai "${SRCROOTDIR}"

if [ -n "${PUSH:-}" ]; then
  echo "Pushing image ${AI_INSTANCE_IMAGE_PATH}..."
  docker push "${AI_INSTANCE_IMAGE_PATH}"
  echo "Pushed image ${AI_INSTANCE_IMAGE_PATH}"
fi
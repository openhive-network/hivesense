#!/bin/sh

GIT_COMMIT_SHA=$(git -C "$(git rev-parse --show-superproject-working-tree --show-toplevel | head -1)" rev-parse HEAD || true)
if [ -z "$GIT_COMMIT_SHA" ]; then
  GIT_COMMIT_SHA="[unknown]"
fi

print_help () {
cat <<-EOF
  Usage: $0 <image> <local-directory> [OPTION[=VALUE]]...

  Exports data from a Docker image to a local directory
  OPTIONS:
    --push                 Push built images to registry
    --tag=TAG_NAME         Name of tag used for hivesense and hivesense_rewriter images
    --help,-h,-?           Display this help screen and exit
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag=*)
        TAG="${1#*=}"
        ;;
    --push)
        PUSH=1
        ;;
    --help|-h|-\?)
        print_help
        exit 0
        ;;
    -*)
        echo "ERROR: '$1' is not a valid option"
        exit 1
        ;;
    *)
        echo "ERROR: '$1' is not a valid positional argument"
    esac
    shift
done

TAG=${TAG:-$(echo "$GIT_COMMIT_SHA" | cut -c1-8)}

if [ -z "$TAG" ]; then
  echo "No tag, please pass it at first argument" >&2
  exit 1
fi

set -eu pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

docker build -t "registry.gitlab.syncad.com/hive/hivesense:${TAG}" "${SCRIPTPATH}/.."
docker build -t "registry.gitlab.syncad.com/hive/hivesense/rewiter:${TAG}" -f "${SCRIPTPATH}/../Dockerfile.rewriter"  "${SCRIPTPATH}/.."

echo "Build images tag ${TAG}"

if [ -n "${PUSH:-}" ]; then
  docker push "registry.gitlab.syncad.com/hive/hivesense:${TAG}"
  docker push "registry.gitlab.syncad.com/hive/hivesense/rewiter:${TAG}"
  echo "Pushed images tag ${TAG}"
fi

#!/bin/bash

GIT_COMMIT_SHA="$(git rev-parse HEAD || true)"
if [ -z "$GIT_COMMIT_SHA" ]; then
  GIT_COMMIT_SHA="[unknown]"
fi

print_help () {
cat <<-EOF
  Usage: $0 <image> <local-directory> [OPTION[=VALUE]]...

  Exports data from a Docker image to a local directory
  OPTIONS:
    --image-path=PATH         Path inside the Docker image that is to be exported (default: /home/hived/bin/).
    --help,-h,-?              Display this help screen and exit
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag=*)
        TAG="${1#*=}"
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

TAG=${TAG:-${GIT_COMMIT_SHA:0:8}}

if [ -z "$TAG" ]; then
  echo "No tag, please pass it at first argument" >&2
  exit 1
fi

set -eu pipefail

LOG_FILE=build.log

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

docker build -t registry.gitlab.syncad.com/ickiewicz/hivesens:${TAG} ${SCRIPTPATH}/..
docker build -t registry.gitlab.syncad.com/ickiewicz/hivesens/rewiter:${TAG} -f Dockerfile.rewriter  ${SCRIPTPATH}/..

docker push registry.gitlab.syncad.com/ickiewicz/hivesens:${TAG}
docker push registry.gitlab.syncad.com/ickiewicz/hivesens/rewiter:${TAG}

echo "Pushed images tag ${TAG}"




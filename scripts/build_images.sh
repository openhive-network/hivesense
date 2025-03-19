#!/bin/bash

GIT_COMMIT_SHA="$(git rev-parse HEAD || true)"
if [ -z "$GIT_COMMIT_SHA" ]; then
  GIT_COMMIT_SHA="[unknown]"
fi

TAG=${1:-${GIT_COMMIT_SHA:0:8}}

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




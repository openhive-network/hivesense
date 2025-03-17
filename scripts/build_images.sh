#!/bin/sh

TAG=$1

set -eu pipefail

LOG_FILE=build.log

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

docker build -t registry.gitlab.syncad.com/ickiewicz/hivesens:${TAG} ${SCRIPTPATH}/..
docker build -t registry.gitlab.syncad.com/ickiewicz/hivesens/rewiter:${TAG} -f Dockerfile.rewriter  ${SCRIPTPATH}/..

docker push registry.gitlab.syncad.com/ickiewicz/hivesens:${TAG}
docker push registry.gitlab.syncad.com/ickiewicz/hivesens/rewiter:${TAG}

echo "Pushed images tag ${TAG}"




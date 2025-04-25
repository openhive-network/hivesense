#!/bin/bash

# the test runs against working haf-api-node with enabled hivesense
# it use docker network haf (the same as api node)
# it directly asks hivesense-postgrest-rewriter with http to avoid haf-api-node overhead
# result are in $(pwd)/jmeter_results folder
# log from test in jmeter.log

set -e
set -o pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"

pushd "${SCRIPTPATH}"
  docker build -t hivesense-api-benchmark .
popd

time docker run --rm --network haf -v "$(pwd)":/test  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" hivesense-api-benchmark
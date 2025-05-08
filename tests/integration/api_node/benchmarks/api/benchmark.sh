#!/bin/sh

# the test runs against working haf-api-node with enabled hivesense
# it use docker network haf (the same as api node)
# it directly asks hivesense-postgrest-rewriter with http to avoid haf-api-node overhead
# result are in $(pwd)/jmeter_results folder
# log from test in jmeter.log

set -e

print_help() {
  echo "Usage: $0 [OPTIONS]"
  echo 
  echo "Run benchmark tests for HiveSense API"
  echo
  echo "Options:"
  echo "  --workers=NUMBER     Number of threads for each query. Default: 20"
  echo "  --loops=NUMBER       Number of loops for each query. Default: 250"
  echo "  --test=TYPE          Type of test to run. One of:"
  echo "                       all, pattern10, pattern20, pattern50, pattern100,"
  echo "                       pattern200, pattern500, pattern1000, post1, post2"
  echo "                       Default: all"
  echo "  --help, -h, -?       Display this help message"
  echo
  echo "Example:"
  echo "  $0 --workers=1 --loops=1 --test=pattern10"
}

# Print help if requested
for arg in "$@"; do
  if [ "$arg" = "--help" ] || [ "$arg" = "-h" ] || [ "$arg" = "-?" ]; then
    print_help
    exit 0
  fi
done

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"

cd "${SCRIPTPATH}"
docker build -t hivesense-api-benchmark .
cd - || exit 1

echo "Starting benchmark with args: $*"
time docker run --rm --network haf -v "$(pwd)":/test  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" hivesense-api-benchmark "$@"
BENCHMARK_EXIT_CODE=$?

# Make sure the benchmark errors are propagated
if [ $BENCHMARK_EXIT_CODE -ne 0 ]; then
  echo "ERROR: Benchmark failed with exit code $BENCHMARK_EXIT_CODE"
  exit $BENCHMARK_EXIT_CODE
fi
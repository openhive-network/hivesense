#! /bin/bash -x
set -e
set -o pipefail
# Script reponsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with hivemind.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to start a data collection for reputation_tracker application."
    echo "OPTIONS:"
    echo "  --host=VALUE         Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER        Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL   Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --stop-at-block=num  Allows to stop processing (sync) at given block"
    echo "  --help               Display this help screen and exit"
    echo
}

POSTGRES_USER=${POSTGRES_USER:-"hivesense_owner"}
POSTGRES_HOST=${POSTGRES_HOST:-"localhost"}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_URL=${POSTGRES_URL:-""}
PROCESS_BLOCK_LIMIT=${PROCESS_BLOCK_LIMIT:-null}
HIVESENSE_SCHEMA=${HIVESENSE_SCHEMA:-"hivesense_app"}
PARALLEL_WORKERS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --host=*)
        POSTGRES_HOST="${1#*=}"
        ;;
    --port=*)
        POSTGRES_PORT="${1#*=}"
        ;;
    --user=*)
        POSTGRES_USER="${1#*=}"
        ;;
    --postgres-url=*)
        POSTGRES_URL="${1#*=}"
        ;;
    --stop-at-block=*)
        PROCESS_BLOCK_LIMIT="${1#*=}"
        ;;
    --schema=*)
        HIVESENSE_SCHEMA="${1#*=}"
        ;;
    --help)
        print_help
        exit 0
        ;;
    -*)
        echo "ERROR: '$1' is not a valid option"
        echo
        print_help
        exit 1
        ;;
    *)
        echo "ERROR: '$1' is not a valid argument"
        echo
        print_help
        exit 2
        ;;
    esac
    shift
done

POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=hivesense_block_processing"}

process_blocks() {
    local n_blocks="${2:-null}"
    local worker=${1}
    log_file="hivesense_sync.log"
    # record the startup time for use in health checks
    date -uIseconds > /tmp/block_processing_startup_time.txt

    psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=on" -v HIVESENSE_SCHEMA="${HIVESENSE_SCHEMA}" -c "\timing" -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -c "CALL ${HIVESENSE_SCHEMA}.main('${HIVESENSE_SCHEMA}', ${worker}, $n_blocks );" 2>&1 | tee -i $log_file
}

# gen number of workers
NUMBER_OF_WORKERS="$(psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=on" -t -c "SELECT parallel_workers FROM ${HIVESENSE_SCHEMA}.hivesense_app_status" | xargs)";

pids=()

i=1

while [ "$i" -le "$NUMBER_OF_WORKERS" ]; do
    process_blocks "$i" "$PROCESS_BLOCK_LIMIT" &
    pids+=($!)
    i=$((i + 1))
done

terminate_jobs() {
    echo "Breaking HiveSense workers ${pids[@]}";
    psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=on" -t -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};SELECT ${HIVESENSE_SCHEMA}.stopProcessing()";
    wait "${pids[@]}"
    echo "Stopped HiveSense workers ${pids[@]}";
}

trap 'terminate_jobs' INT TERM
trap 'terminate_jobs' EXIT

wait
echo "Stopped HiveSense workers  2 ${pids[@]}";

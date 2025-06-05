#! /bin/bash
set -e
set -o pipefail

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

postgres_access(){
  echo "${POSTGRES_URL:-"postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=$1"}"
}
POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=hivesense_block_processing"}
NUMBER_OF_WORKERS="$(psql "$(postgres_access hivesense_block_processing)" -v "ON_ERROR_STOP=on" -t -c "SELECT parallel_workers FROM ${HIVESENSE_SCHEMA}.hivesense_app_status" | xargs)";
LLM="$(psql "$(postgres_access hivesense_block_processing)" -v "ON_ERROR_STOP=on" -t -c "SELECT llm FROM ${HIVESENSE_SCHEMA}.hivesense_app_status" | xargs)";
OLLAMA_ADDRESS="$(psql "$(postgres_access hivesense_block_processing)" -v "ON_ERROR_STOP=on" -t -c "SELECT ollama FROM ${HIVESENSE_SCHEMA}.hivesense_app_status" | xargs)";


initialize_ollama() {
  local max_retries=60
  local delay=2
  local attempt=0
  local http_code=""
  local response=""
  local curl_exit=0
  local llm_pull_request_sent=0

  echo "Checking if Ollama at ${OLLAMA_ADDRESS} has pulled model: ${LLM}"

  while [ "$attempt" -lt "$max_retries" ]; do
    if [ "$attempt" -gt 0 ]; then
      echo "Waiting for ollama to finish pulling model, attempt ${attempt}"
      sleep "$delay"
    fi
    set +e
    response=$(curl -s -w "%{http_code}" -X POST "${OLLAMA_ADDRESS}/api/show" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${LLM}\"}")
    curl_exit=$?
    set -e

    http_code="${response: -3}"

    if [ "$curl_exit" -ne 0 ]; then
      echo "curl failed (exit code $curl_exit), retrying..."
    elif [ "$http_code" = "404" ]; then
      if [ "$llm_pull_request_sent" -eq 0 ]; then
        llm_pull_request_sent=1
        echo "Model not found. Sending pull request for ${LLM} ..."
        set +e
        response=$(curl -s -w "%{http_code}" -X POST "${OLLAMA_ADDRESS}/api/pull" \
          -H "Content-Type: application/json" \
          -d "{\"name\": \"${LLM}\"}")
        curl_exit=$?
        http_code="${response: -3}"
        set -e
        if [  "$curl_exit" -ne 0 ] || [ "${http_code}" -ne 200 ]; then
          llm_pull_request_sent=0
          echo "Sending pull request failed"
        fi
        echo "Pull status: ${http_code}"
      fi
    elif [ "$http_code" = "200" ]; then
      echo "Model ${LLM} is fully pulled and ready."
      return 0
    else
      echo "Unexpected HTTP code: $http_code — retrying..."
    fi

    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for Ollama at ${OLLAMA_ADDRESS} to pull model ${LLM}."
  return 1
}



launch_worker() {
    local n_blocks="${2:-null}"
    local worker=${1}

    trap '' SIGINT SIGTERM  # Child ignores signals

    setsid bash <<EOF
    psql "$(postgres_access hivesense_worker_${worker})" \
      -v ON_ERROR_STOP=on \
      -v HIVESENSE_SCHEMA="${HIVESENSE_SCHEMA}" \
      -c "\\timing" \
      -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" \
      -c "CALL ${HIVESENSE_SCHEMA}.worker_loop(${worker}, '${HIVESENSE_SCHEMA}', ${n_blocks});" \
    || \
    psql "$(postgres_access hivesense_worker_${worker})" \
      -v ON_ERROR_STOP=on \
      -v HIVESENSE_SCHEMA="${HIVESENSE_SCHEMA}" \
      -c "\\timing" \
      -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" \
      -c "SELECT ${HIVESENSE_SCHEMA}.STOPPROCESSING();"
EOF
    echo "Worker ${worker} stopped"
}

launch_scheduler() {
    local n_blocks="${2:-null}"
    local num_workers=${1}

    trap '' SIGINT SIGTERM  # Child ignores signals

    setsid bash <<EOF
    psql "$(postgres_access hivesense_scheduler)" \
      -v ON_ERROR_STOP=on \
      -v HIVESENSE_SCHEMA="${HIVESENSE_SCHEMA}" \
      -c "\\timing" \
      -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" \
      -c "CALL ${HIVESENSE_SCHEMA}.scheduler('${HIVESENSE_SCHEMA}', ${num_workers}, ${n_blocks});" \
    || \
    psql "$(postgres_access hivesense_scheduler)" \
      -v ON_ERROR_STOP=on \
      -v HIVESENSE_SCHEMA="${HIVESENSE_SCHEMA}" \
      -c "\\timing" \
      -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" \
      -c "SELECT ${HIVESENSE_SCHEMA}.STOPPROCESSING();"
EOF
    echo "Scheduler stopped"
}

initialize_ollama

# record the startup time for use in health checks
date -uIseconds > /tmp/block_processing_startup_time.txt

launch_scheduler "$NUMBER_OF_WORKERS" "$PROCESS_BLOCK_LIMIT" &

# gen number of workers
i=1
while [ "$i" -le "$NUMBER_OF_WORKERS" ]; do
    launch_worker "$i" "$PROCESS_BLOCK_LIMIT" &
    i=$((i + 1))
done

terminate_jobs() {
    echo "Breaking HiveSense workers";
    psql "$(postgres_access hivesense_breaker)" -v "ON_ERROR_STOP=on" -t -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};SELECT ${HIVESENSE_SCHEMA}.stopProcessing()";
    wait
}

trap 'terminate_jobs' INT TERM

wait

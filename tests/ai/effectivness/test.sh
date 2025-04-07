#! /bin/bash

set -e
set -o pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"
SQL_FILE="${SCRIPTPATH}/queries.sql"

# Script reponsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with hivemind.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to setup a database already filled by HAF instance, to work with reputation_tracker application."
    echo "OPTIONS:"
    echo "  --host=VALUE              Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER             Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL        Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --schema=SCHEMA_NAME       Allows to specify a HiveSense schema"
    echo "  --help               Display this help screen and exit"
    echo
}

#hivesense_dir="$SCRIPTPATH/.."
POSTGRES_USER=${POSTGRES_USER:-"haf_admin"}
POSTGRES_HOST=${POSTGRES_HOST:-"localhost"}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_URL=${POSTGRES_URL:-""}
HIVESENSE_SCHEMA=${HIVESENSE_SCHEMA:-"hivesense_app"}
SWAGGER_URL=${SWAGGER_URL:-"{hivesense-host}"}
POSTGRES_APP_NAME=hivesense_install

while [ $# -gt 0 ]; do
  case "$1" in
    --host=*)
        POSTGRES_HOST="${1#*=}"
        ;;
    --port=*)
        POSTGRES_PORT="${1#*=}"
        ;;
    --postgres-url=*)
        POSTGRES_URL="${1#*=}"
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

POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=${POSTGRES_APP_NAME}"}

psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -v HIVESENSE_SCHEMA="${HIVESENSE_SCHEMA}" -q -t -f "${SQL_FILE}" | jq


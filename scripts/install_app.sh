#! /bin/bash

set -e
set -o pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"
SRCPATH="${SCRIPTPATH}/../"

# Script reponsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with hivemind.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to setup a database already filled by HAF instance, to work with reputation_tracker application."
    echo "OPTIONS:"
    echo "  --host=VALUE              Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER             Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL        Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --swagger-url=URL         Allows to specify a server URL"
    echo "  --is_forking=TRUE/FALSE   Allows to specify if app should be forking or not (defaults to true)"
    echo "  --indexes-only            Only creates indexes"
    echo "  --schema-only             Only creates schema, but not indexes"
    echo "  --help               Display this help screen and exit"
    echo
}

#hivesense_dir="$SCRIPTPATH/.."
POSTGRES_USER=${POSTGRES_USER:-"haf_admin"}
POSTGRES_HOST=${POSTGRES_HOST:-"localhost"}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_URL=${POSTGRES_URL:-""}
HIVESENSE_SCHEMA=${HIVESENSE_SCHEMA:-"hivesense_app"}
IS_FORKING=${IS_FORKING:-"true"}
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
    --swagger-url=*)
        SWAGGER_URL="${1#*=}"
        ;;
    --schema=*)
        hivesense_SCHEMA="${1#*=}"
        ;;
    --is_forking=*)
        IS_FORKING="${1#*=}"
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

#pushd "$hivesense_dir"
#./scripts/generate_version_sql.sh "$hivesense_dir"
#popd


  echo "Installing app..."
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -f "$SRCPATH/db/builtin_roles.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET ROLE hivesense_owner;CREATE SCHEMA IF NOT EXISTS ${HIVESENSE_SCHEMA} AUTHORIZATION hivesense_owner;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "CREATE EXTENSION IF NOT EXISTS ai CASCADE;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/db/database_schema.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/db/helpers.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/db/main_loop.sql"


  #psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/scripts/set_version_in_sql.pgsql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT USAGE ON SCHEMA ${HIVESENSE_SCHEMA} to hivesense_user;"
  #psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT USAGE ON SCHEMA hivesense_endpoints to hivesense_user;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT SELECT ON ALL TABLES IN SCHEMA ${HIVESENSE_SCHEMA} TO hivesense_user;"
  #psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT SELECT ON ALL TABLES IN SCHEMA hivesense_endpoints TO hivesense_user;"



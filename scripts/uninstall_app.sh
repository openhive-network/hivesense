#! /bin/bash

set -e
set -o pipefail

# Script reponsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with hivemind.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to CLEAR a database containing already deployed reputation_tracker app at given HAF instance."
    echo "OPTIONS:"
    echo "  --host=VALUE         Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER        Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL   Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --drop-indexes       Allows to also drop indexes built by application on regular HAF tables (their rebuild can be timeconsuming). Indexes are preserved by default."
    echo "  --help               Display this help screen and exit"
    echo
}

POSTGRES_USER=${POSTGRES_USER:-"haf_admin"}
POSTGRES_HOST=${POSTGRES_HOST:-"localhost"}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_URL=${POSTGRES_URL:-""}
HIVESENSE_SCHEMA=${HIVESENSE_SCHEMA:-"hivesense_app"}
DROP_INDEXES=${DROP_INDEXES:-0}

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
    --drop-indexes*)
        DROP_INDEXES=1
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

POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=hivesense_uninstall"}

uninstall_app() {
    remove_context_sql=$(cat << EOF
do
\$\$
DECLARE
  __parallel_workers INT;
BEGIN
  SELECT parallel_workers  INTO __parallel_workers FROM ${HIVESENSE_SCHEMA}.hivesense_app_status;
  FOR worker IN 1..__parallel_workers LOOP
    IF hive.app_context_exists('${HIVESENSE_SCHEMA}' || worker) THEN
     PERFORM hive.app_remove_context('${HIVESENSE_SCHEMA}' || worker);
     EXECUTE format('DROP SCHEMA IF EXISTS %s CASCADE', '${HIVESENSE_SCHEMA}' || worker);
    END IF;
  END LOOP;
END\$\$;
EOF
)

    drop_users_sql=$(cat <<EOF
do
\$\$
BEGIN
 IF NOT EXISTS( SELECT 1 FROM hafd.contexts hc WHERE owner = 'hivesense_owner' ) THEN
    DROP OWNED BY hivesense_owner CASCADE;
    DROP ROLE hivesense_owner;
    DROP OWNED BY hivesense_user CASCADE;
    DROP ROLE hivesense_user;
 END IF;
END\$\$;
EOF
)

  psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=OFF" -c "${remove_context_sql}"
  psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=OFF" -c "DROP SCHEMA IF EXISTS ${HIVESENSE_SCHEMA} CASCADE;"
  psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=OFF" -c "DROP SCHEMA IF EXISTS hivesense_endpoints CASCADE;"

  psql "$POSTGRES_ACCESS" -c "${drop_users_sql}" || true

  if [ "${DROP_INDEXES}" -eq 1 ]; then
    echo "Attempting to drop indexes built by application"

    # TODO(mickiewicz@syncad.com): remove indexes here
  else
    echo "Indexes created by application have been preserved"
  fi
}

uninstall_app

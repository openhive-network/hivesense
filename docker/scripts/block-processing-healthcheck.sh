#! /bin/sh

set -e

# Kill a still-pending healthcheck query when the script is interrupted
trap 'trap - 2 15 && kill -- -$$' 2 15

postgres_user=${POSTGRES_USER:-"hivesense_owner"}
postgres_host=${POSTGRES_HOST:-"haf"}
postgres_port=${POSTGRES_PORT:-5432}
POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$postgres_user@$postgres_host:$postgres_port/haf_block_log?application_name=hivesense_health_check"}
CONTEXT=${HIVESENSE_SCHEMA:-"hivesense_app"}

# Healthy when either:
# - hivesense has processed a block in the last minute, and that happened after
#   this container started (so a restart is not reported healthy on stale data)
# - or hivesense's head block has caught up with HAF's irreversible block
#   (so a HAF that stops receiving blocks does not make hivesense unhealthy)
#
# The entrypoint records the start of block processing in
# /tmp/block_processing_startup_time.txt before exec'ing process_blocks.sh.
if [ ! -f /tmp/block_processing_startup_time.txt ]; then
  echo "/tmp/block_processing_startup_time.txt does not exist: block processing has not started yet"
  exit 1
fi
STARTUP_TIME="$(cat /tmp/block_processing_startup_time.txt)"
CHECK="SET TIME ZONE 'UTC'; \
       SELECT ((now() - (SELECT last_active_at FROM hafd.contexts WHERE name = '${CONTEXT}')) < interval '1 minute' \
               AND (SELECT last_active_at FROM hafd.contexts WHERE name = '${CONTEXT}') > '${STARTUP_TIME}'::timestamp) OR \
              hive.is_app_in_sync('${CONTEXT}');"

# the container has no locale set; silence the psql warning
export LC_ALL=C
exec [ "$(psql "$POSTGRES_ACCESS" --quiet --no-align --tuples-only --command="${CHECK}")" = t ]

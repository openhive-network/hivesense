#!/bin/sh

set -e

# Get the directory where docker compose is running
SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)
COMPOSE_DIR="${SCRIPTPATH}/../../docker/ci"

# After replaying a finite block_log with P2P disabled, hived never transitions
# to live sync, so HAF's deferred indexes/FKs remain in 'missing' state.
# This makes hive.is_instance_ready() return false, blocking all apps.
# Restore them before waiting for apps to process blocks.
ensure_haf_indexes() {
    echo "Checking if HAF indexes need restoration..."

    READY=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "SELECT hive.is_instance_ready();" 2>/dev/null || echo "")
    if [ "$READY" = "t" ]; then
        echo "HAF indexes already created, skipping."
        return
    fi

    echo "Waiting for HAF events_queue to be populated..."
    for attempt in $(seq 1 120); do
        HAS_EVENTS=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "SELECT EXISTS(SELECT 1 FROM hafd.events_queue);" 2>/dev/null || echo "")
        if [ "$HAS_EVENTS" = "t" ]; then
            echo "HAF events_queue populated (attempt $attempt)."
            break
        fi
        if [ "$attempt" -eq 120 ]; then
            echo "ERROR: Timed out waiting for HAF events_queue"
            exit 1
        fi
        sleep 5
    done

    echo "Restoring HAF indexes..."
    docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -c "SELECT hive.enable_indexes_of_irreversible();"

    echo "Restoring HAF foreign keys..."
    for tbl in hafd.account_operations hafd.transactions hafd.accounts hafd.transactions_multisig hafd.hive_state hafd.blocks hafd.applied_hardforks; do
        docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -c "SELECT hive.restore_foreign_keys('$tbl');"
    done

    READY=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "SELECT hive.is_instance_ready();")
    echo "hive.is_instance_ready() = $READY"
    if [ "$READY" != "t" ]; then
        echo "ERROR: HAF instance still not ready after index restoration"
        docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -c "SELECT index_constraint_name, status FROM hafd.indexes_constraints WHERE status <> 'created';"
        exit 1
    fi
    echo "HAF indexes restored successfully."
}

wait_for_hivesense_startup() {
    COMMAND="SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'i' AND n.nspname = 'hivesense_app' AND c.relname = hivesense_app.get_hnsw_index_name());"
    MESSAGE="Waiting for Hivesense to finish processing blocks..."
    HIVEMIND_BLOCK_COMMAND="SELECT last_completed_block_num FROM hivemind_app.hive_state"
    HAF_BLOCK_COMMAND="SELECT consistent_block FROM hafd.hive_state"
    HIVESENSE_BLOCK_COMMAND="SELECT hive.app_get_current_block_num('hivesense_app')"

    i=0
    while :
    do
        i=$((i+1))
        if [ "$i" -gt 120 ]; then
            echo "Too long waiting, pending logs dump:"

            LOCK_DUMP_COMMAND="SELECT
                                   pg_stat_activity.pid,
                                   pg_stat_activity.query,
                                   pg_locks.locktype,
                                   pg_locks.mode,
                                   pg_locks.granted,
                                   pg_locks.relation::regclass AS locked_relation,
                                   pg_locks.page,
                                   pg_locks.tuple,
                                   pg_locks.virtualtransaction,
                                   pg_locks.virtualxid,
                                   pg_locks.transactionid,
                                   pg_locks.classid,
                                   pg_locks.objid,
                                   pg_locks.objsubid,
                                   pg_stat_activity.usename,
                                   pg_stat_activity.application_name,
                                   pg_stat_activity.client_addr,
                                   pg_stat_activity.backend_start,
                                   pg_stat_activity.query_start
                               FROM pg_locks
                               JOIN pg_stat_activity ON pg_locks.pid = pg_stat_activity.pid
                               ORDER BY pg_stat_activity.query_start;"
            docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "${LOCK_DUMP_COMMAND}";
            exit 1
        fi
        HAF_BLOCK=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "$HAF_BLOCK_COMMAND";)
        HIVEMIND_BLOCK=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "$HIVEMIND_BLOCK_COMMAND";)
        HIVESENSE_BLOCK=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "$HIVESENSE_BLOCK_COMMAND";)

        echo "HAF is on block: ${HAF_BLOCK}"
        echo "Hivemind is on block: ${HIVEMIND_BLOCK}"
        echo "Hivesense is on block: ${HIVESENSE_BLOCK}"

        RESULT=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf psql -d haf_block_log -t -A -c "$COMMAND")
        if [ "$RESULT" = "t" ]; then
            break
        fi
        echo "$MESSAGE"
        sleep 20
    done
}


ensure_haf_indexes
wait_for_hivesense_startup


echo "Block processing is finished."

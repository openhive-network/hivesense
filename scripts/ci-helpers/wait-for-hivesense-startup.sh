#!/bin/sh

set -e

wait_for_hivesense_startup() {
    COMMAND="SELECT EXISTS (SELECT 1 FROM pg_class WHERE relkind = 'i' AND ( relname = 'posts_vectors_embedding_half_hnsw' OR relname = 'posts_vectors_embedding_hnsw' ));"
    MESSAGE="Waiting for Hivesense to finish processing blocks..."
    HIVEMIND_BLOCK_COMMAND="SELECT last_completed_block_num FROM hivemind_app.hive_state"
    HAF_BLOCK_COMMAND="SELECT consistent_block FROM hafd.hive_state"
    HIVESENSE_BLOCK_COMMAND="SELECT hive.app_get_current_block_num('hivesense_app1')"

    i=0
    while :
    do
        i=$((i+1))
        if [ "$i" -gt 20 ]; then
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
            docker exec haf-world-haf-1 psql -d haf_block_log -t -A -c "${LOCK_DUMP_COMMAND}";
            exit 1
        fi
        HAF_BLOCK=$(docker exec haf-world-haf-1 psql -d haf_block_log -t -A -c "$HAF_BLOCK_COMMAND";)
        HIVEMIND_BLOCK=$(docker exec haf-world-haf-1 psql -d haf_block_log -t -A -c "$HIVEMIND_BLOCK_COMMAND";)
        HIVESENSE_BLOCK=$(docker exec haf-world-haf-1 psql -d haf_block_log -t -A -c "$HIVESENSE_BLOCK_COMMAND";)

        echo "HAF is on block: ${HAF_BLOCK}"
        echo "Hivemind is on block: ${HIVEMIND_BLOCK}"
        echo "Hivesense is on block: ${HIVESENSE_BLOCK}"

        RESULT=$(docker exec haf-world-haf-1 psql -d haf_block_log -t -A -c "$COMMAND")
        if [ "$RESULT" = "t" ]; then
            break
        fi
        echo "$MESSAGE"
        sleep 20
    done
}


wait_for_hivesense_startup


echo "Block processing is finished."

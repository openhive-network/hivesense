#!/bin/sh

# Reconfigure the hivesense app in a running CI test environment to a
# different embedding configuration, then resync and rebuild the index.
# HAF and hivemind are left untouched, so switching configurations only
# costs an embedding regeneration (a few minutes on the CI corpus).
#
# For --mode=pca the PCA projection matrix is computed first (via the
# hivesense-pca service) from the embeddings currently in posts_vectors,
# so the app must already be synced in a full-embedding configuration
# with the same model.

set -e

print_help() {
cat <<EOF
Usage: $0 --mode=none|pca|slice [OPTION[=VALUE]]...

OPTIONS:
    --mode=MODE              Embedding configuration to install (required)
    --model=NAME             Switch to a different Ollama model (default: keep current)
    --vector-size=NUMBER     Embedding dimensions of the model
    --reduced-dim=NUMBER     Reduced dimensions (defaults: pca=128, slice=256)
    --query-prefix=TEXT      Query prefix required by the model
    --document-prefix=TEXT   Document prefix required by the model
    --help|-h|-?             Display this help screen and exit
EOF
}

SCRIPTPATH=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)

# shellcheck disable=SC1091
. "${SCRIPTPATH}/compose_variables.sh"

COMPOSE_DIR="${SCRIPTPATH}/../../docker/ci"

MODE=""
MODEL=""
VECTOR_SIZE=""
REDUCED_DIM=""
QUERY_PREFIX=""
DOCUMENT_PREFIX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode=*)
        MODE="${1#*=}"
        ;;
    --model=*)
        MODEL="${1#*=}"
        ;;
    --vector-size=*)
        VECTOR_SIZE="${1#*=}"
        ;;
    --reduced-dim=*)
        REDUCED_DIM="${1#*=}"
        ;;
    --query-prefix=*)
        QUERY_PREFIX="${1#*=}"
        ;;
    --document-prefix=*)
        DOCUMENT_PREFIX="${1#*=}"
        ;;
    --help|-h|-\?)
        print_help
        exit 0
        ;;
    *)
        echo "ERROR: '$1' is not a valid option"
        print_help
        exit 2
        ;;
  esac
  shift
done

case "$MODE" in
  none)
    HIVESENSE_USE_REDUCED_EMBEDDINGS=false
    HIVESENSE_REDUCTION_MODE=none
    HIVESENSE_REDUCED_DIM=0
    ;;
  pca)
    HIVESENSE_USE_REDUCED_EMBEDDINGS=true
    HIVESENSE_REDUCTION_MODE=pca
    HIVESENSE_REDUCED_DIM="${REDUCED_DIM:-128}"
    HIVESENSE_REDUCED_MATRIX_SOURCE=/pca-matrix/pca_projection_matrix.json
    export HIVESENSE_REDUCED_MATRIX_SOURCE
    ;;
  slice)
    HIVESENSE_USE_REDUCED_EMBEDDINGS=true
    HIVESENSE_REDUCTION_MODE=slice
    HIVESENSE_REDUCED_DIM="${REDUCED_DIM:-256}"
    ;;
  *)
    echo "ERROR: --mode must be one of none, pca, slice"
    print_help
    exit 2
    ;;
esac
export HIVESENSE_USE_REDUCED_EMBEDDINGS HIVESENSE_REDUCTION_MODE HIVESENSE_REDUCED_DIM

# Must match the default used for the bind mounts in compose.yml
HIVESENSE_PCA_MATRIX_DIR="${HIVESENSE_PCA_MATRIX_DIR:-/tmp/hivesense-pca-matrix}"
export HIVESENSE_PCA_MATRIX_DIR

if [ -n "$MODEL" ]; then
  HIVESENSE_MODEL="$MODEL"
  export HIVESENSE_MODEL
fi
if [ -n "$VECTOR_SIZE" ]; then
  HIVESENSE_VECTOR_SIZE="$VECTOR_SIZE"
  export HIVESENSE_VECTOR_SIZE
fi
if [ -n "$QUERY_PREFIX" ]; then
  HIVESENSE_QUERY_PREFIX="$QUERY_PREFIX"
  export HIVESENSE_QUERY_PREFIX
fi
if [ -n "$DOCUMENT_PREFIX" ]; then
  HIVESENSE_DOCUMENT_PREFIX="$DOCUMENT_PREFIX"
  export HIVESENSE_DOCUMENT_PREFIX
fi

compose() {
  docker compose -f "${COMPOSE_DIR}/compose.yml" --profile reconfigure "$@"
}

# Run a one-shot service to completion via 'up' (not 'run') so the container
# gets its regular <project>-<service>-1 name, which the PG_ACCESS pg_hba
# entries match on.
run_one_shot() {
  svc="$1"
  echo "Running ${svc}..."
  compose up -d --no-deps --force-recreate "$svc"
  cid=$(compose ps -a -q "$svc")
  ec=$(docker wait "$cid")
  echo "--- ${svc} log tail ---"
  docker logs --tail 30 "$cid" 2>&1 || true
  if [ "$ec" != "0" ]; then
    echo "ERROR: ${svc} exited with code ${ec}" >&2
    exit 1
  fi
}

# 1. For PCA, compute the projection matrix from the embeddings that are
#    currently in the database (before the uninstall wipes them).
if [ "$MODE" = "pca" ]; then
  run_one_shot hivesense-pca
fi

# 2. If the model is changing, restart Ollama so it pulls the new model,
#    and wait for the pull to finish before block processing needs it.
if [ -n "$MODEL" ]; then
  compose up -d --no-deps --force-recreate hivesense-ollama
  echo "Waiting for Ollama to serve ${HIVESENSE_MODEL}..."
  i=0
  until compose exec -T hivesense-ollama ollama show "${HIVESENSE_MODEL}" >/dev/null 2>&1; do
    i=$((i+1))
    if [ "$i" -gt 60 ]; then
      echo "ERROR: timed out waiting for Ollama to pull ${HIVESENSE_MODEL}" >&2
      compose logs --no-log-prefix --tail 30 hivesense-ollama
      exit 1
    fi
    sleep 10
  done
  echo "Model ${HIVESENSE_MODEL} is available."
fi

# 3. Reinstall the app with the new configuration. install_app skips (with
#    exit code 0) while a block processor holds the app advisory lock, so
#    wait until the exclusive lock can be taken — the same probe the install
#    wrapper uses — before uninstalling.
echo "Waiting for the hivesense app advisory lock to be free..."
i=0
while :; do
  lock_free=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf \
    psql -U haf_admin -q -A -t -d haf_block_log -c \
    "SELECT pg_try_advisory_xact_lock(hashtext('hive_fork_manager_app_lock'), hashtext('hivesense'));" | tr -d '[:space:]')
  if [ "$lock_free" = "t" ]; then
    break
  fi
  i=$((i+1))
  if [ "$i" -gt 60 ]; then
    echo "ERROR: hivesense app advisory lock still held after 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

run_one_shot hivesense-uninstall-schema
run_one_shot hivesense-install-schema

# Guard against the install having been skipped anyway (exit code 0)
schema_exists=$(docker compose -f "${COMPOSE_DIR}/compose.yml" exec -T haf \
  psql -U haf_admin -q -A -t -d haf_block_log -c \
  "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'hivesense_app');" | tr -d '[:space:]')
if [ "$schema_exists" != "t" ]; then
  echo "ERROR: hivesense_app schema missing after install (install skipped?)" >&2
  exit 1
fi

# The uninstall dropped and recreated the hivesense roles, and PostgREST
# caches the schema. pgbouncer's pooled server connections still reference
# the dropped role (PostgREST gets HTTP 401 through them), so bounce
# pgbouncer first, then the PostgREST services.
compose restart pgbouncer
compose restart hivesense-postgrest hivesense-postgrest-rewriter

# 4. Regenerate embeddings and rebuild the index.
run_one_shot hivesense-process-blocks
"${SCRIPTPATH}/wait-for-hivesense-startup.sh"

echo "Resulting hivesense configuration:"
compose exec -T haf psql -U haf_admin -d haf_block_log -c \
  "SELECT hivesense_app.reduction_mode()        AS reduction_mode,
          hivesense_app.use_reduced_embeddings() AS use_reduced,
          hivesense_app.embedding_dims()         AS embedding_dims,
          hivesense_app.reduced_dims()           AS reduced_dims,
          hivesense_app.get_hnsw_index_name()    AS index_name;"

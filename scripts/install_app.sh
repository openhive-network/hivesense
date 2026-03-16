#! /bin/bash

set -e
set -o pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"
SRCPATH="${SCRIPTPATH}/../"

# Script reponsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with hivemind.

echo "All arguments: $*"

# Function to normalize boolean values to lowercase true/false
normalize_bool() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        true|yes|on|1)
            echo "true"
            ;;
        false|no|off|0)
            echo "false"
            ;;
        *)
            echo "ERROR: Invalid boolean value: $1" >&2
            echo "Expected: true/false, yes/no, on/off, 1/0 (case insensitive)" >&2
            exit 1
            ;;
    esac
}

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to setup a database already filled by HAF instance, to work with reputation_tracker application."
    echo "OPTIONS:"
    echo "  --host=VALUE                          Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER                         Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL                    Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --swagger-url=URL                     Allows to specify a server URL"
    echo "  --is_forking=TRUE/FALSE               Allows to specify if app should be forking or not (defaults to true)"
    echo "  --indexes-only                        Only creates indexes"
    echo "  --schema-only                         Only creates schema, but not indexes"
    echo "  --llm=MODEL_NAME                      Choose LLM model (defaults: bge-m3:latest)"
    echo "  --ollama=OLLAMA_URLS                  Choose OLLAMA server (defaults: http://192.168.6.17:11434)"
    echo "  --vector_size=NUMBER                  Choose vector size for embeddings (defaults: 768)"
    echo "  --start_block=NUMBER                  Choose start block to sync (default: 1)"
    echo "  --parallel_workers=NUMBER             Choose number of parallel contexts that ask OLLAMA"
    echo "  --embedding_batch_size=NUMBER         The number of texts we ask OLLAMA to generate embeddings for in a single API call"
    echo "  --tokenizer-model=MODEL_NAME          The tokenizer model, must be compatible with 'llm'"
    echo "  --tokens_per_chunk=NUMBER             The maximum number of tokens to break long posts into"
    echo "  --overlap_amount=NUMBER               The percentage of tokens_per_chunk that will be overlapped with the previous chunk (range 0-1, default 0.15)"
    echo "  --use-halfvec-index=BOOL              Use HNSW half-precision index (true/false, yes/no, on/off, 1/0)"
    echo "  --store-halfvec-embeddings=BOOL       Store half-precision embeddings (true/false, yes/no, on/off, 1/0)"
    echo "  --document-prefix=TEXT                Prefix for documents (defaults to 'passage: ')"
    echo "  --query-prefix=TEXT                   Prefix for queries (defaults to 'query: ')"
    echo "  --min-token-threshold=INT             Don't generate embeddings for posts with fewer than this number of tokens"
    echo "  --min-token-search-threshold=INT      Don't return search results for posts with fewer than this number of tokens"
    echo "  --max-embeddings-per-post             Maximum embeddings to generate for each post (defaults to 0 = unlimited)"
    echo "  --maintenance-work-mem                Desired setting of maintenance_work_mem to use while creating the HNSW index"
    echo "  --default-ef-search                   Default exploratory factor when searching"
    echo "  --minimum-ann-candidates              Always consider at least this many candidates for reranking"
    echo "  --use-reduced-embeddings=BOOL         Enable dimension reduction (true/false, yes/no, on/off, 1/0, case insensitive)"
    echo "  --reduced-dim=NUMBER                  Reduced dimension size"
    echo "  --reduction-mode=MODE                 Reduction method: 'none', 'pca', or 'slice' (matryoshka truncation)"
    echo "  --reduced-matrix-source=PATH|URL      Path to matrix file or URL to download (auto-detected)"
    echo "  --reduced-matrix-json=PATH            (Deprecated) Path to reduction matrix JSON file"
    echo "  --reduced-matrix-url=URL              (Deprecated) URL to download reduction matrix JSON"
    echo "  --reduced-matrix-file=PATH            (Deprecated) Alternative to --reduced-matrix-json"
    echo "  --allow-debugging=BOOL                Enable debugging flags for API calls (true/false, yes/no, on/off, 1/0)"
    echo "  --help                                Display this help screen and exit"
    echo
}

#hivesense_dir="$SCRIPTPATH/.."
POSTGRES_USER=${POSTGRES_USER:-"haf_admin"}
POSTGRES_HOST=${POSTGRES_HOST:-"haf"}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_URL=${POSTGRES_URL:-""}
HIVESENSE_SCHEMA=${HIVESENSE_SCHEMA:-"hivesense_app"}
SWAGGER_URL=${SWAGGER_URL:-"{hivesense-host}"}
POSTGRES_APP_NAME=hivesense_install
LLM='yxchia/multilingual-e5-base:F16'
OLLAMA_HOST='http://192.168.6.17:11434'
VECTOR_SIZE=768
PARALLEL_WORKERS=16
EMBEDDING_BATCH_SIZE=100
START_BLOCK=1
TOKENIZER_MODEL='e5-base' # shipped in haf docker image, compatible with yxchia/multilingual-e5-base:F16
TOKENS_PER_CHUNK=512
OVERLAP_AMOUNT='0.15'
USE_HALFVEC_INDEX=false
STORE_HALFVEC_EMBEDDINGS=false
DOCUMENT_PREFIX='passage: '
QUERY_PREFIX='query: '
MIN_TOKEN_THRESHOLD=75
MIN_TOKEN_SEARCH_THRESHOLD=0
MAX_EMBEDINGS_PER_POST=0
MAINTENANCE_WORK_MEM=28    # GB
USE_REDUCED_EMBEDDINGS=false
REDUCED_DIM=0          # must be set when flag=true
REDUCTION_MODE='none'  # 'none', 'pca', or 'slice' (matryoshka)
REDUCED_MATRIX_JSON=""
REDUCED_MATRIX_URL=""
REDUCED_MATRIX_FILE=""
HNSW_M=32
HNSW_EF_CONSTRUCTION=400
DEFAULT_EF_SEARCH=500
MINIMUM_ANN_CANDIDATES=1000
ALLOW_DEBUGGING=false

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
        HIVESENSE_SCHEMA="${1#*=}"
        ;;
    --llm=*)
        LLM="${1#*=}"
        ;;
    --ollama=*)
        OLLAMA_HOST="${1#*=}"
        ;;
    --vector_size=*)
        VECTOR_SIZE="${1#*=}"
        ;;
    --parallel_workers=*)
            PARALLEL_WORKERS="${1#*=}"
        ;;
    --embedding_batch_size=*)
            EMBEDDING_BATCH_SIZE="${1#*=}"
        ;;
    --tokenizer-model=*)
	    TOKENIZER_MODEL="${1#*=}"
        ;;
    --tokens_per_chunk=*)
	    TOKENS_PER_CHUNK="${1#*=}"
        ;;
    --overlap_amount=*)
	    OVERLAP_AMOUNT="${1#*=}"
        ;;
    --use-halfvec-index=*)
        USE_HALFVEC_INDEX=$(normalize_bool "${1#*=}")
        ;;
    --store-halfvec-embeddings=*)
        STORE_HALFVEC_EMBEDDINGS=$(normalize_bool "${1#*=}")
        ;;
    --document-prefix=*)
        DOCUMENT_PREFIX="${1#*=}"
        ;;
    --query-prefix=*)
        QUERY_PREFIX="${1#*=}"
        ;;
    --min-token-threshold=*)
        MIN_TOKEN_THRESHOLD="${1#*=}"
        ;;
    --min-token-search-threshold=*)
        MIN_TOKEN_SEARCH_THRESHOLD="${1#*=}"
        ;;
    --max-embeddings-per-post=*)
        MAX_EMBEDINGS_PER_POST="${1#*=}"
        ;;
    --maintenance-work-mem=*)
      MAINTENANCE_WORK_MEM="${1#*=}"
      ;;
    --use-reduced-embeddings=*)
	USE_REDUCED_EMBEDDINGS=$(normalize_bool "${1#*=}")
	;;
    --reduced-dim=*)
	REDUCED_DIM="${1#*=}"
	;;
    --reduction-mode=*)
	REDUCTION_MODE="${1#*=}"
	;;
    --reduced-matrix-source=*)
	REDUCED_MATRIX_SOURCE="${1#*=}"
	;;
    --reduced-matrix-json=*)
	REDUCED_MATRIX_JSON="${1#*=}"
	;;
    --reduced-matrix-url=*)
	REDUCED_MATRIX_URL="${1#*=}"
	;;
    --reduced-matrix-file=*)
	REDUCED_MATRIX_FILE="${1#*=}"
	;;
    --hnsw-m=*)
	HNSW_M="${1#*=}"
	;;
    --hnsw-ef-construction=*)
	HNSW_EF_CONSTRUCTION="${1#*=}"
	;;
    --default-ef-search=*)
        DEFAULT_EF_SEARCH="${1#*=}"
        ;;
    --minimum-ann-candidates=*)
        MINIMUM_ANN_CANDIDATES="${1#*=}"
        ;;
    --allow-debugging=*)
        ALLOW_DEBUGGING=$(normalize_bool "${1#*=}")
        ;;
    --config-dir=*)
        HIVESENSE_CONFIG_DIR="${1#*=}"
        ;;
    --start_block=*)
            START_BLOCK="${1#*=}"
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
echo "Number of workers: ${PARALLEL_WORKERS}"
echo "Batch size: ${EMBEDDING_BATCH_SIZE}"
echo "Model: ${LLM}"

psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -f "$SRCPATH/db/builtin_roles.sql"


psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "CREATE EXTENSION IF NOT EXISTS plpython3u;"

# common schema for all workers
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET ROLE hivesense_owner;CREATE SCHEMA IF NOT EXISTS ${HIVESENSE_SCHEMA} AUTHORIZATION hivesense_owner;"

psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "
  SET pg_temp.START_BLOCK TO ${START_BLOCK};
  SET pg_temp.VECTOR_SIZE TO ${VECTOR_SIZE};
  SET pg_temp.LLM TO '${LLM}';
  SET pg_temp.OLLAMA_HOST TO '${OLLAMA_HOST}';
  SET pg_temp.PARALLEL_WORKERS TO ${PARALLEL_WORKERS};
  SET pg_temp.EMBEDDING_BATCH_SIZE TO ${EMBEDDING_BATCH_SIZE};
  SET pg_temp.TOKENIZER_MODEL TO '${TOKENIZER_MODEL}';
  SET pg_temp.TOKENS_PER_CHUNK TO ${TOKENS_PER_CHUNK};
  SET pg_temp.OVERLAP_AMOUNT TO ${OVERLAP_AMOUNT};
  SET pg_temp.USE_HALFVEC_INDEX TO ${USE_HALFVEC_INDEX};
  SET pg_temp.STORE_HALFVEC_EMBEDDINGS TO ${STORE_HALFVEC_EMBEDDINGS};
  SET pg_temp.DOCUMENT_PREFIX TO '${DOCUMENT_PREFIX}';
  SET pg_temp.QUERY_PREFIX TO '${QUERY_PREFIX}';
  SET pg_temp.MIN_TOKEN_THRESHOLD TO ${MIN_TOKEN_THRESHOLD};
  SET pg_temp.MIN_TOKEN_SEARCH_THRESHOLD TO ${MIN_TOKEN_SEARCH_THRESHOLD};
  SET pg_temp.MAX_EMBEDINGS_PER_POST TO '${MAX_EMBEDINGS_PER_POST}';
  SET pg_temp.MAINTENANCE_WORK_MEM TO ${MAINTENANCE_WORK_MEM};
  SET pg_temp.USE_REDUCED_EMBEDDINGS TO ${USE_REDUCED_EMBEDDINGS};
  SET pg_temp.REDUCED_DIM           TO ${REDUCED_DIM};
  SET pg_temp.REDUCTION_MODE        TO '${REDUCTION_MODE}';
  SET pg_temp.HNSW_M                TO ${HNSW_M};
  SET pg_temp.HNSW_EF_CONSTRUCTION  TO ${HNSW_EF_CONSTRUCTION};
  SET pg_temp.DEFAULT_EF_SEARCH TO ${DEFAULT_EF_SEARCH};
  SET pg_temp.MINIMUM_ANN_CANDIDATES TO ${MINIMUM_ANN_CANDIDATES};
  SET pg_temp.ALLOW_DEBUGGING   TO ${ALLOW_DEBUGGING};
  SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};
" -f "$SRCPATH/db/database_schema.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/db/helpers.sql"

# Handle matrix JSON configuration only if USE_REDUCED_EMBEDDINGS is true and mode is PCA
if [ "$USE_REDUCED_EMBEDDINGS" = "true" ] && [ "$REDUCTION_MODE" != "slice" ]; then
  # Handle new unified matrix source parameter
  if [ -n "$REDUCED_MATRIX_SOURCE" ]; then
    # Detect if it's a URL or file path
    case "$REDUCED_MATRIX_SOURCE" in
      http://*|https://*)
        echo "Detected URL source: $REDUCED_MATRIX_SOURCE"
        MATRIX_HANDLER_ARGS="--matrix-url=$REDUCED_MATRIX_SOURCE"
        ;;
      *)
        echo "Detected file source: $REDUCED_MATRIX_SOURCE"
        MATRIX_HANDLER_ARGS="--matrix-file=$REDUCED_MATRIX_SOURCE"
        ;;
    esac

    if [ -n "${HIVESENSE_CONFIG_DIR:-}" ]; then
      MATRIX_HANDLER_ARGS="$MATRIX_HANDLER_ARGS --config-dir=$HIVESENSE_CONFIG_DIR"
    fi

    # Source the matrix handler to resolve the path
    # shellcheck disable=SC1090,SC2086
    . "$SRCPATH/scripts/matrix_handler.sh" $MATRIX_HANDLER_ARGS

    # Use the resolved path
    if [ -n "$HIVESENSE_REDUCED_MATRIX_JSON" ]; then
      REDUCED_MATRIX_JSON="$HIVESENSE_REDUCED_MATRIX_JSON"
    fi
  # Keep backward compatibility with old parameters
  elif [ -n "$REDUCED_MATRIX_URL" ]; then
    echo "Using deprecated --reduced-matrix-url parameter"
    # Build arguments for matrix_handler.sh
    MATRIX_HANDLER_ARGS="--matrix-url=$REDUCED_MATRIX_URL"
    if [ -n "${HIVESENSE_CONFIG_DIR:-}" ]; then
      MATRIX_HANDLER_ARGS="$MATRIX_HANDLER_ARGS --config-dir=$HIVESENSE_CONFIG_DIR"
    fi

    # Source the matrix handler to resolve the path
    # shellcheck disable=SC1090,SC2086
    . "$SRCPATH/scripts/matrix_handler.sh" $MATRIX_HANDLER_ARGS

    # Use the resolved path
    if [ -n "$HIVESENSE_REDUCED_MATRIX_JSON" ]; then
      REDUCED_MATRIX_JSON="$HIVESENSE_REDUCED_MATRIX_JSON"
    fi
  # Handle file path if specified (REDUCED_MATRIX_FILE takes precedence over REDUCED_MATRIX_JSON for consistency)
  elif [ -n "$REDUCED_MATRIX_FILE" ]; then
    echo "Using deprecated --reduced-matrix-file parameter"
    REDUCED_MATRIX_JSON="$REDUCED_MATRIX_FILE"
  elif [ -n "$REDUCED_MATRIX_JSON" ]; then
    echo "Using deprecated --reduced-matrix-json parameter"
  fi

  # Now check if we have a matrix file
  if [ -z "$REDUCED_MATRIX_JSON" ]; then
    echo "ERROR: --reduced-matrix-json is required when --use-reduced-embeddings=true"
    exit 1
  fi

  echo "Loading projection matrix ($REDUCED_MATRIX_JSON)…"

  # Check if the file is gzipped and handle accordingly
  case "$REDUCED_MATRIX_JSON" in
    *.gz)
    echo "Decompressing gzipped matrix file on-the-fly..."
    psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on <<EOF
    SET ROLE hivesense_owner;
    SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};
    SELECT hivesense_app.load_reducing_matrix(\$\$$(zcat "$REDUCED_MATRIX_JSON")\$\$::jsonb);
EOF
      ;;
    *)
    psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on <<EOF
    SET ROLE hivesense_owner;
    SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};
    SELECT hivesense_app.load_reducing_matrix(\$\$$(cat "$REDUCED_MATRIX_JSON")\$\$::jsonb);
EOF
      ;;
  esac
fi

psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA}, public;" -f "$SRCPATH/db/ollama.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET pg_temp.VECTOR_SIZE TO ${VECTOR_SIZE};SET pg_temp.LLM TO '${LLM}'; SET pg_temp.OLLAMA_HOST TO '${OLLAMA_HOST}';SET SEARCH_PATH TO ${HIVESENSE_SCHEMA}, public;" -f "$SRCPATH/db/main_loop.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA}, public;" -f "$SRCPATH/db/search.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/db/posts_preprocessing.sql"


psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET custom.swagger_url = '$SWAGGER_URL'; SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/endpoints/endpoint_schema.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/endpoints/find_similar_posts.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/endpoints/get_similar_posts_by_post.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/endpoints/find_thematic_contributors.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/endpoints/get_posts_by_ids.sql"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${HIVESENSE_SCHEMA};" -f "$SRCPATH/endpoints/embedding_updates.sql"

psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT USAGE ON SCHEMA ${HIVESENSE_SCHEMA} to hivesense_user;"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT SELECT ON ALL TABLES IN SCHEMA ${HIVESENSE_SCHEMA} TO hivesense_user;"

psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT USAGE ON SCHEMA hivesense_endpoints to hivesense_user;"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE hivesense_owner;GRANT SELECT ON ALL TABLES IN SCHEMA hivesense_endpoints TO hivesense_user;"

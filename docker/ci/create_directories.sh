#!/bin/sh

# Creates directory structure for HAF CI testing
# Simplified version that doesn't require root or handle ZFS

set -e

print_help() {
  echo "Usage: $0 [--data-dir=path]"
  echo "  Creates directory structure for HAF CI testing"
  echo "  --data-dir=path      Base directory for HAF data"
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir=*)
      TOP_LEVEL_DATASET_MOUNTPOINT="${1#*=}"
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_help
      exit 1
      ;;
  esac
  shift
done

# Check if data directory is set
if [ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ]; then
  echo "ERROR: --data-dir is required"
  exit 1
fi

echo "Creating HAF CI directory structure"
echo "Data directory: $TOP_LEVEL_DATASET_MOUNTPOINT"
echo ""

# Create main directories
echo "Creating main directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/blockchain"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/shared_memory"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/shared_memory/haf_wal"

# Create database directories
echo "Creating database directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store/pgdata"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store/pgdata/pg_wal"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store/tablespace"

# Create log directories
echo "Creating log directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/caddy"

# Create configuration directory
echo "Creating configuration directory..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"

# Create hived config for CI (small shared memory for 5M block_log)
echo "Creating hived config..."
cat > "$TOP_LEVEL_DATASET_MOUNTPOINT/config.ini" << 'CONFIGEOF'
shared-file-size = 1G
shared-file-full-threshold = 9500
shared-file-scale-rate = 1000
flush-state-interval = 0
webserver-thread-pool-size = 8
p2p-seed-node =
CONFIGEOF

# Create hivesense directories
echo "Creating hivesense directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config"

echo ""
echo "Setting permissions..."

# Set ownership - use sudo if available, otherwise try without
set_ownership() {
  _path="$1"
  _owner="$2"

  if command -v sudo >/dev/null 2>&1; then
    sudo chown -R "$_owner" "$_path" 2>/dev/null || true
  else
    chown -R "$_owner" "$_path" 2>/dev/null || true
  fi
}

# 1000:100 is hived:users inside the container
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT" "1000:100"

# 105:109 is postgres:postgres inside the container
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store" "105:109"
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d" "105:109"
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql" "105:109"
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger" "105:109"

# Ollama needs root:root
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama" "0:0"

# PCA and config use hived user
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca" "1000:100"
set_ownership "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config" "1000:100"

echo ""
echo "Directory structure created successfully!"

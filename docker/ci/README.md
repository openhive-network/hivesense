# CI Docker Compose Stack

This directory contains a self-contained Docker Compose setup for CI testing. It does not depend on submodules - all service definitions are inlined.

## Usage

### For CI

The CI pipeline uses these files automatically via the helper scripts:

```bash
# Start CI test environment
./scripts/ci-helpers/start-ci-test-environment.sh \
    --block-log-directory=/path/to/block_log \
    --haf-data-directory=/path/to/data

# Wait for hivesense to sync
./scripts/ci-helpers/wait-for-hivesense-startup.sh

# Run integration tests
./tests/integration/api_node/hivesense_synced_api_node_test.sh
```

### Manual Testing

```bash
# Set required environment variables
export HAF_VERSION="1.27.11rc2"
export HIVEMIND_VERSION="1.27.11rc2"
export HIVESENSE_VERSION="latest"
export TOP_LEVEL_DATASET_MOUNTPOINT="/path/to/data"

# Create directories
./create_directories.sh --data-dir=/path/to/data

# Start the stack
docker compose up -d

# Stop the stack
docker compose down
```

## Services

The compose file includes:

- **HAF Core**: `haf` - PostgreSQL + hived
- **Connection Pooling**: `pgbouncer`
- **Load Balancer**: `haproxy`, `haproxy-healthchecks`
- **Web Server**: `caddy`
- **Swagger UI**: `swagger`
- **HAfAH**: `hafah-install` (dependency for hivemind)
- **Reputation Tracker**: `reputation-tracker-*` (dependency for hivemind)
- **Hivemind**: `hivemind-*`
- **Hivesense**: `hivesense-*`

## Environment Variables

Required:
- `HAF_VERSION`: HAF image tag (e.g., "1.27.11rc2")
- `HIVEMIND_VERSION`: Hivemind image tag
- `HIVESENSE_VERSION`: Hivesense image tag
- `TOP_LEVEL_DATASET_MOUNTPOINT`: Data directory path

Optional:
- `PUBLIC_HOSTNAME`: Hostname for API endpoints (default: "localhost")
- `HIVESENSE_MODEL`: Ollama model name (default: "yxchia/multilingual-e5-base:F16")
- `HIVESENSE_VECTOR_SIZE`: Embedding dimensions (default: 768)
- `HIVESENSE_WORKERS`: Number of parallel workers (default: 16)

See `compose.yml` for the full list of configurable options.

## Production Deployments

This CI compose stack is for testing only. For production deployments, use the `haf_api_node` repository which provides:

- Full service profiles (monitoring, balance tracker, etc.)
- Caddy configuration files
- HAProxy configuration files
- ZFS dataset management

The `haf_api_node` repository includes the hivesense YAML files for operators:
- `hivesense.yaml`
- `hivesense-sync.yaml`
- `hivesense-local.yaml`

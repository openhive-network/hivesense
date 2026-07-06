# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HiveSense is a HAF-based application for semantic search on Hive blockchain posts. It uses machine learning embeddings (via Ollama) to enable meaning-based content discovery. The system integrates with Hivemind (Hive's social media data layer) to collect root posts, compute embeddings, and store them in PostgreSQL with pgvector.

## Architecture

### Components
- **HAF Application**: A scheduler + worker system that processes blocks from HAF
- **Ollama Integration**: Calls Ollama API to generate embeddings for post content
- **PostgreSQL with pgvector**: Stores embeddings and enables HNSW-indexed vector similarity search
- **PostgREST API**: Exposes semantic search endpoints (`/similarposts`, `/similarpostsbypost`, `/thematiccontributors`)
- **PostgREST Rewriter**: Transforms API requests/responses

### Database Schema
- **hivesense_app**: Main schema containing application state, post vectors, and processing logic
- **hivesense_endpoints**: API endpoint definitions for PostgREST
- **hivesense_owner/hivesense_user**: Database roles (owner for writes, user for read-only API access)

### Processing Flow
1. Scheduler (HAF app) gets block ranges from HAF, divides posts into batches for workers
2. Workers generate embeddings via Ollama API for each post chunk
3. Posts are chunked (512 tokens, 15% overlap), cleaned of links/tags, and filtered by minimum token count (75)
4. Embeddings are stored in `posts_vectors` table with HNSW index for fast similarity search

## Common Commands

### Build Docker Images
```bash
./scripts/build_images.sh          # Build all images (hivesense, rewriter, syncer, pca)
./scripts/build_images.sh --push   # Build and push to registry
./scripts/build_images.sh --tag=<tag>  # Use custom tag instead of git SHA
```

### Installation (on host with HAF already running)
```bash
./scripts/install_app.sh \
    --llm='bge-m3:latest' \
    --vector_size=1024 \
    --ollama=http://192.168.6.186:11434 \
    --parallel_workers=8

# Start from specific block
./scripts/install_app.sh ... --start_block=1000000
```

### Start Synchronization
```bash
./scripts/process_blocks.sh                   # Sync indefinitely
./scripts/process_blocks.sh --stop-at-block=5000000  # Stop at specific block
```

### Uninstall
```bash
./scripts/uninstall_app.sh
```

### Linting
```bash
# Shell scripts (CI uses shellcheck-alpine)
find . -name .git -type d -prune -o -type f -name \*.sh -exec shellcheck {} +

# SQL scripts (CI uses sqlfluff)
sqlfluff lint --dialect postgres
```

### CI Test Environment
```bash
# Start test environment (requires block_log with 1M+ blocks)
./scripts/ci-helpers/start-ci-test-environment.sh \
    --block-log-directory=<path> \
    --haf-data-directory=<path>

# Wait for sync completion
./scripts/ci-helpers/wait-for-hivesense-startup.sh

# Run integration test
./tests/integration/api_node/hivesense_synced_api_node_test.sh

# Run API benchmarks
./tests/integration/api_node/benchmarks/api/benchmark.sh --workers=1 --loops=1
```

## Key Source Files

### SQL Code (`db/`)
- `database_schema.sql`: Table definitions, HAF context registration, app status table
- `main_loop.sql`: `generate_embeddings_for_posts()` function, worker/scheduler loop logic
- `ollama.sql`: Ollama API integration (`ollama_embed()` function)
- `search.sql`: Vector similarity search functions
- `posts_preprocessing.sql`: Text cleaning and chunking logic

### Endpoints (`endpoints/`)
- `find_similar_posts.sql`: `/similarposts` - search by text pattern
- `get_similar_posts_by_post.sql`: `/similarpostsbypost` - find similar to existing post
- `find_thematic_contributors.sql`: `/thematiccontributors` - find authors by topic

### Scripts
- `process_blocks.sh`: Main entry point for block processing (spawns scheduler + workers)
- `install_app.sh`: Database setup with all configuration options

## CI Docker Compose

For CI testing, hivesense uses a self-contained Docker Compose stack in `docker/ci/`:

- `docker/ci/compose.yml`: All-in-one compose file with HAF, hivemind, and hivesense services
- `docker/ci/create_directories.sh`: Creates directory structure for CI testing

The CI stack uses published Docker images from the registry rather than submodules.

**For production deployments**: Use haf_api_node repo which includes hivesense yamls for operators.

## Configuration Options

Key parameters (see `./scripts/install_app.sh --help` for full list):
- `--llm`: Embedding model name (default: `yxchia/multilingual-e5-base:F16`)
- `--vector_size`: Embedding dimensions (default: 768)
- `--parallel_workers`: Number of worker processes (default: 16)
- `--embedding_batch_size`: Texts per Ollama API call (default: 100)
- `--tokens_per_chunk`: Max tokens per post chunk (default: 512)
- `--min-token-threshold`: Skip posts with fewer tokens (default: 75)
- `--use-halfvec-index`: Use 16-bit float index for memory savings
- `--use-reduced-embeddings`: Enable dimension reduction with PCA matrix

## CI Pipeline

Stages: detect → lint → build → sync → test → publish → cleanup

- **find_haf_image**: Automatically detects latest HAF image from upstream registry
- **lint_bash_scripts**: Shellcheck validation
- **lint_sql_scripts**: SQLFluff validation
- **build_images**: Builds and pushes Docker images
- **sync**: Integration test with HAF API node (syncs 1M blocks) using docker/ci/compose.yml. Tests all three embedding configurations: full vectors, PCA-reduced (matrix computed in-job by the pca image), and Matryoshka slice (mxbai-embed-xsmall-v1). Reconfiguration between phases reuses the synced HAF/hivemind stack via `scripts/ci-helpers/reconfigure-hivesense.sh`; per-configuration search tests live in `tests/integration/api_node/hivesense_search_test.sh`
- **publish_images**: Tags releases for protected branches

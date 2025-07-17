# HiveSense

HiveSense is a HAF-based application designed to enable **semantic search** among posts
on the Hive blockchain. It leverages **machine learning embeddings** to provide a
powerful and efficient way to find related content based on meaning rather than exact
keywords. The system integrates with [**Hivemind**](https://gitlab.syncad.com/hive/hivemind), a structured SQL-based database
layer for Hive social media data, to collect root posts, compute embeddings, and store
them in a **PostgreSQL vector database**. Through a **REST API**, HiveSense allows
clients to search for posts similar to a given text or retrieve posts similar to a
specific existing post. This enhances content discovery and engagement within the Hive
ecosystem.

## Software Architecture

### Dependencies

Ubuntu
Docker

```bash
sudo apt-get install postgresql-plpython3-17 postgresql-17-pgvector
```

#### External containers

1. [HAF](https://gitlab.syncad.com/hive/haf) server includes
    - [**Hivemind**](https://gitlab.syncad.com/hive/hivemind)
    - [pgai](https://github.com/Postgres-artificialintelligence/PGAI)
    - [pgvector](https://github.com/pgvector/pgvector)
2. [OLLAMA server](https://github.com/ollama/ollama)

### System context diagram

![system-context](./doc/images/system_context.png)

![containers](./doc/images/containers.png)

### Structure of sources

| **Directory Structure** | **Description**                                                          |
| ----------------------- | ------------------------------------------------------------------------ |
| **db/**                 | SQL code: schema definitions, runtime plpgsql code, HAF application code |
| **doc/**                | Resources for documentation                                              |
| **docker/**             | Scripts for docker container                                             |
| **endpoints/**          | REST API definitions                                                     |
| **scripts/**            | shell scripts                                                            |
| **submodules/**         | git submodules                                                           |
| **tests/**              | Tests                                                                    |

### Advantages of Using Ollama

Ollama simplifies the deployment of large language models by exposing them through a
lightweight REST API. Its minimal setup and support for GGUF-formatted models make it ideal
for building scalable, distributed vectorization systems. With Ollama, each node can run
independently, requiring no additional orchestration beyond standard container or process
management. This enables effortless horizontal scaling—just add more nodes and place them
behind a load balancer. Ollama internally handles batching and GPU scheduling, allowing
high-throughput inference without the need to implement complex worker queues or embedding
pipelines manually.

#### Install dockerized version of ollama server

Because the process of computing the embeddings is very resource-intensive, there are two
ways to configure HiveSense: you can have it generate the embeddings locally, or you can download 
embeddings generated from another HiveSense instance.  If you want to generate embeddings locally,
you will absolutely need a GPU, the fastest CPUs available today will not be able to keep up with
the rate new posts are being added.

If you sync embeddings from another HiveSense instance, your node will be storing and indexing
the embeddings for posts, but it won't be doing the expensive work of computing them.  Your node
will still need to run an ollama instance to generate embeddings for the search terms.  Since 
it's faster to generate embeddings for short things like search terms, a decent server CPU will
be able to create an embedding for a typical search term in a few hundred milliseconds.  As long
as the rate of search API calls is relatively low, a CPU-only node can still provide a good
search experience.

##### Requirements for GPU

- PC with AMD or NVIDIA graphics card(s)

For NVIDIA graphics cards, you'll also need:
- installed the [latest drivers](https://www.nvidia.com/en-us/drivers/) for the NVIDIA card
- installed [CUDA toolkit](https://developer.nvidia.com/cuda-downloads)
- installed [docker container toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) to run containers with GPU support

Read [documentation](https://github.com/ollama/ollama/blob/main/docs/README.md) from ollama and this document about [docker](https://github.com/ollama/ollama/blob/main/docs/docker.md). We can run several instances of ollama server depending on the computing power of our GPU card(s). In our case, we had an NVIDIA 3060RTX card with 12GB of NVRAM, which allowed us to run 2 instances of ollama server to achieve full GPU load.

contents of **compose.yml**:

```bash
---

services:
  ollama1:
    image: ollama/ollama:latest
    environment:
      - TZ=America/New_York
      - OLLAMA_HOST=0.0.0.0
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
      - NVIDIA_VISIBLE_DEVICES=all
      - OLLAMA_NUM_PARALLEL=16
      - OLLAMA_NUM_THREADS=16
      - OLLAMA_KEEP_ALIVE=-1
    tty: true
    ports:
      - "11435:11434"
    volumes:
      - type: bind
        source: ${PWD}/.ollama
        target: /root/.ollama

```

Run ollama server:

```bash
docker compose up -d
```

To add another instance just copy the compose.yml file and change the input port and service name in the ***compose.yml*** file to a different one. If you have the ability, in order to speed up data processing, you can run several or more servers (they can be located on different machines) and then expose them using a load balancer.

#### Load balancer

Example configuration for an nginx web server that performs simple load balancing:

contents of **default.conf**:

```bash
upstream backend {
#
# enter your endpoints for
# installed ollama servers...
# example:
    server 192.168.1.2:11435;
    server 192.168.1.3:11435;
    server 192.168.1.4:11435;
    server 192.168.1.4:11436;
    server 192.168.1.4:11437;
    }

server {
    listen 80;
    server_name _;

    include /etc/nginx/mime.types;

    location / {
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

```

contents of **compose.yml**:

```bash
name: nginx-rev
services:
    nginx-rev
        tty: true
        stdin_open: true
        restart: always
        container_name: nginx-rev
        ports:
            - 11434:80
        volumes:
            - ${PWD}/default.conf:/etc/nginx/conf.d/default.conf:ro
        image: nginx:latest

```

Running with the command

```bash
docker compose up -d
```

launches an endpoint on port 11434, which will distribute traffic among several machines/servers.

### Database

#### PostgreSQL roles

- **hivesense_owner** is able to modify the database tables, their content and modify schema. If used to start HiveSense
  haf application main loop that fill the tables
- **hivesense_user** has only read access to the HiveSense tables, used to execute queries started by REST API server

#### Index

For searching among vectorized posts, an HNSW index is used. This index requires a large amount of shared memory 
to be available to the PostgreSQL server. Therefore, the HAF container must be configured
with at least 8 GB of shared memory, which can be set using the --shm-size option when running the container.

### Vectorization

- Only root posts are vectorized
- Posts are cleaned from links and other tags
- Posts which contain less than 75 tokens (about 55 words) after cleanup are discarded
- Posts are chunked: 512 tokens (about 380 words) per chunk with 15% of those being overlapped with the previous chunk
- For performance reasons, we will only return the 1000 nearest posts when searching

Most of the numbers above can be tweaked via config settings.

#### HAF application(s)

##### Parallel LLM Queries using Workers

HiveSense uses multiple **workers** to query
the LLM in parallel. Each worker runs as a separate process, started by the
[`./scripts/process_blocks.sh`](./scripts/process_blocks.sh) script.

There is one **scheduler** task which is a HAF application.  It gets a range
of blocks from HAF, divides up the posts from that range of blocks into smaller 
batches, and puts them in a queue for the workers to crunch on.

Before working on a range of blocks, Hivemind must have already completed
processing that range.

##### Contexts

- context schema(default): **hivesense_app**

##### Stages
1.  **MASSIVE_PROCESSING** started when the context is more than 10 blocks after hive head. Max. 100 blocks in a one batch

### Continuous Integration (CI) Overview

The CI pipeline includes several key steps to ensure quality, build consistency, and up-to-date images for all critical components.

#### Linters
- **Shell scripts** and **SQL scripts** are automatically checked with linters to enforce coding standards and catch errors early.

#### Docker Image Builds
- Builds Docker images based on the current submodule versions for:
   - `haf` 
   - `hivemind`
   - `haf_api_node`
   - `hivesense`
   - `hivesense/rewriter`

#### Sync Job
- The sync job starts `haf_api_node` with:
   - `hivesense`
   - A local **Ollama** server

- It performs a blockchain sync for:
   - `haf`
   - `hivemind`
   - `hivesense`
   - Up to **1 million blocks**

### Start CI Tasks on Host
To reproduce CI-related issues on your local machine, you can replicate the environment using the following steps:

1. **Build Docker Images**
   ```bash
   ./scripts/build_images.sh             # Builds Docker images for hivesense and the PostgREST rewriter.
   ```

2. **Download a Blocklog**
   - Download a `blocklog` file containing **at least 1 million blocks** and place it in a local directory.

3. **Start the Test Environment**
   ```bash
   ./scripts/ci-helpers/start-ci-test-environment.sh \
     --block-log-directory=<path_to_blocklog_directory> \
     --haf-data-directory=<path_to_haf_api_node_data_directory>
   ```

4. **Wait for Hivesense to Sync**
   ```bash
   ./scripts/ci-helpers/wait-for-hivesense-startup.sh
   ```

Once the environment is up and synced, you can reproduce, debug, and test changes as they would occur during CI execution.

## Installation

### API Node
The Hivesense is intended to run as a part of [HAF_API_NODE](https://gitlab.syncad.com/hive/haf_api_node), you must
add hivesense to `COMPOSE_PROFILES` variable in th `.env` file. To customize setup set variables:
- `HIVESENSE_SYNC_ARGS` - process_blocks.sh parameters
- `HIVESENSE_OLLAMA` - Ollama endpoint address
- `HIVESENSE_MODEL` - LLM used to vectorization
- `HIVESENSE_VECTOR_SIZE` - LLM vector size
- `HIVESENSE_START_BLOCK` - From which block start vectorization 
- `HIVESENSE_WORKERS` - How many vectorization workers use 

### Dockerized setup

1. Build HAF docker image with AI support
   A version of HAF is added as submodule to the project, and corresponding base_instance HAF docker image
   is used as a base layer for HAF wit AI support (see [Dockerfile.haf_ai](./Dockerfile.haf_ai). Use 'scripts/build_haf_ai_image.sh':

   ```bash
   ./scripts/build_haf_ai_image.sh
   ```

   The script will build an image `registry.gitlab.syncad.com/hive/hivesense/haf/ai-instance:<HAF image tag>`. THe HiveSense can
   be deployed only on `ai-instance` HAF.
2. Build HiveSense docker image.

   ```bash
   ./scripts/build_images.sh
   ```

   The script will build hivesense and its query rewriter images:

   ```bash
   registry.gitlab.syncad.com/hive/hivesense:<8 digit git sha>
   registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:<8 digit git sha>
   ```

   With using switch '--push' new images will also be pushed to registry
3. Run hivesense container

   ```bash
   docker run registry.gitlab.syncad.com/hive/hivesense:<8 digit git sha> (install_app|process_blocks|uninstall_app)
   ```

   Possible options starts scripts explained  in the pragraph below

### On host installation

It must be installed alongside HAF and an already synced Hivemind.

1. **Install**
   You need to choose an Ollama host and an LLM model along with its vector
   size. It is also possible to specify the address of a HAF server with
   Hivemind. See `./scripts/install_app.sh --help` for details.

   ```bash
   ./scripts/install_app.sh --llm='bge-m3:latest' --vector_size=1024 \
       --ollama=http://192.168.6.186:11434 --parallel_workers=8
   ```

   It is possible to start vectorizing post from a given block with using '--start_block'

   ```bash
   ./scripts/install_app.sh --llm='bge-m3:latest' --vector_size=1024 \
       --ollama=http://192.168.6.186:11434 --parallel_workers=8 --start_block=1000000
   ```

2. **Start synchronization**
   By default, it will synchronize indefinitely, but you can set a block
   height to stop at.

   ```bash
   time ./scripts/process_blocks.sh --stop-at-block=5000000
   ```

3. **Uninstall**
   Completely remove the HiveSense data from HAF.

   ```bash
   ./scripts/uninstall_app.sh
   ```
## Hivesense API Reference

The Hivesense API provides AI-powered semantic search capabilities for the Hive social network. Base URL: `/hivesense-api`

### API Documentation

#### Interactive Documentation
Interactive API documentation is available at `/hivesense-swagger`, where you can:
- Explore all endpoints in detail
- Test API calls directly in the browser
- View complete request/response schemas
- Try out different parameter combinations

#### OpenAPI Definition
The OpenAPI/Swagger definition is available in JSON format at:
- `/hivesense-api/` - Raw OpenAPI specification
This can be imported into API tools and used for generating client libraries.

### Endpoints

#### Semantic Search Endpoints

##### GET `/similarposts`
Finds posts semantically similar to a text pattern.

**Parameters:**
- `pattern` (required): Text query to find similar posts (e.g. "astronauts on moon")
- `tr_body` (required): Post body truncation length (0 for full content)
- `posts_limit` (required): Number of posts to return
- `observer` (optional): Hive account name for filtering results
- `start_author`, `start_permlink` (optional): Pagination parameters

**Example:**
```bash
curl -X 'GET' \
  'https://localhost/hivesense-api/similarposts?pattern=astronauts%20on%20moon&tr_body=200&posts_limit=5' \
  -H 'accept: application/json'
````

##### GET `/similarpostsbypost`
Gets semantically similar posts to a given Hive post. Performs semantic similarity search to find posts that are contextually similar to a specified Hive post. The endpoint analyzes the content and context of the target post and returns up to 50 related posts, ranked by their similarity score.

Key features:
- Semantic analysis considers post content and context
- Results are ordered by similarity (most similar first)
- Optional content filtering through observer blacklists
- Configurable body length truncation for preview purposes
- Maximum of 50 posts returned to ensure performance

The similarity analysis takes into account:
- Post content and context
- Semantic relationships between posts
- Topic relevance and contextual meaning

**Parameters:**
- `author` (required): The Hive username of the post author. This is the account name that created the original post for which you want to find similar content. Must be a valid Hive account name.
- `permlink` (required): The unique permlink identifier of the post. This is the URL-friendly version of the post title that appears in the post URL on Hive. Together with the author name, it uniquely identifies the post.
- `tr_body` (required): Controls the length of returned post bodies in the results. When set to 0, returns complete post content. Any other positive value will truncate the post body to that many characters. Useful for generating previews or reducing response size. Maximum value is 65535 characters.
- `posts_limit` (required): Specifies the maximum number of similar posts to return. Must be between 1 and 50. The posts are returned in order of similarity, with the most similar posts first. Setting a lower limit can improve response times and reduce data transfer.
- `observer` (optional): Optional Hive account name with blacklists that will be used to filter the results. When provided, any posts from authors in the observer blacklist will be excluded from the results. Leave empty to disable blacklist filtering. Useful for content moderation and personalization.

**Example:**

```bash
curl -X 'GET' \
  'https://localhost/hivesense-api/similarpostsbypost?author=bue-witness&permlink=my-blog-post&tr_body=20&posts_limit=10' \
  -H 'accept: application/json'
```

##### GET `/thematiccontributors`
Identifies and ranks Hive authors who contribute significantly to specific topics or themes using semantic analysis. This endpoint leverages AI-powered embeddings to discover subject matter experts and thought leaders across different domains on the Hive blockchain.
Key features:
- Discovers content creators specializing in specific topics
- Ranks authors based on semantic relevance and contribution volume
- Optional content filtering through observer blacklists
- Helps identify domain experts and thought leaders

The contributor analysis considers:
- Content relevance using semantic understanding
- Author's contribution frequency in the topic area
- Depth and quality of thematic content
- Recent activity in the subject matter

**Parameters:**
- `thematic` (required): Text describing the thematic area to analyze. This can be a topic, concept, field of interest, or any subject matter (e.g., "blockchain technology", "sustainable farming"). Must be descriptive enough to capture the semantic context.
- `authors_limit` (required): Maximum number of contributors to return.  
- `observer` (optional): Hive account name with blacklists to filter results. When provided, authors in the observer's blacklist will be excluded. Leave empty to disable filtering.

**Example:**
``` bash
curl -X 'GET' \
  'https://localhost/hivesense-api/thematiccontributors?thematic=cryptocurrency%20mining&authors_limit=10' \
  -H 'accept: application/json'
```


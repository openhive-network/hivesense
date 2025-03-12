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

sudo apt-get install postgresql-plpython3-17 postgresql-17-pgvector

#### External containers
1. [HAF](https://gitlab.syncad.com/hive/haf) server includes
    - [**Hivemind**](https://gitlab.syncad.com/hive/hivemind)
    - [pgai](https://github.com/Postgres-artificialintelligence/PGAI)
    - [pgvector](https://github.com/pgvector/pgvector)
2. [OLLAMA server](https://github.com/ollama/ollama)

### System context diagram
![](./doc/images/system_context.png)

![](./doc/images/containers.png)

### Structure of sources
| **Directory Structure** | **Description**                                                          |
|-------------------------|--------------------------------------------------------------------------|
| **db/**                 | SQL code: schema definitions, runtime plpgsql code, HAF application code |
| **doc/**                | Resources for documentation                                              |
| **docker/**             | Scripts for docker container                                             |
| **endpoints/**          | REST API definitions                                                     |
| **scripts/**            | shell scripts                                                            |
| **submodules/**         | git submodules                                                           |
| **tests/**              | Tests                                                                    |

### Database
#### PostgreSQL roles
- **hivesense_owner** is able to modify the database tables, their content and modify schema. If used to start HiveSense
  haf application main loop that fill the tables
- **hivesense_user** has only read access to the HiveSense tables, used to execute queries started by REST API server 

#### HAF application(s)
##### Parallel LLM Queries using Workers

HiverSense uses **workers**—HAF applications with their own contexts—to query  
the LLM in parallel. Each worker runs as a separate process, started by the  
[`./scripts/process_blocks.sh`](./scripts/process_blocks.sh) script.

These HAF applications operate independently, processing similar ranges of  
blocks while **exclusively** selecting Hive posts to vectorize according to  
their individual criteria.

Applications use HAF contexts to determine the range of blocks to process.  
They then check if Hivemind has already synchronized these blocks. If not,  
the transaction is rolled back, the application waits a few seconds, and  
then retries.

##### Contexts 
- contexts name: **hivesense_app**{*worker nr*} each worker got separated context name that includes worker number
- context schema(default): **hivesense_app**

##### Stages
1.  **MASSIVE_PROCESSING** started when the context is more than 10 blocks after hive head. Max. 100 blocks in a one batch


## Installation

It must be installed alongside HAF and an already synced Hivemind.

1. **Install**  
   You need to choose an Ollama host and an LLM model along with its vector
   size. It is also possible to specify the address of a HAF server with
   Hivemind. See `./scripts/install_app.sh --help` for details.

   ```bash
   ./scripts/install_app.sh --llm='bge-m3:latest' --vector_size=1024 \
       --ollama=http://192.168.6.186:11434 --parallel_workers=8
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

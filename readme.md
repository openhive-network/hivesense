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

#### Index
For searching among vectorized posts IVFFLAT index is used with 4000 centroids and 4 probes. The numbers are
chosen experimentally od table with 14M vectors.

### Vectorization
- Only root posts are vectorized
- Posts are cleaned from links and other tags
- Posts which contain less than 50 words after cleanup are discarded
- there is a limit to find only first 1000 of nearest posts (searching performance reason)

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

## REST API

**GET** `/similarposts`

### Description
Retrieves a list of posts that are semantically similar to the given pattern using a semantic search mechanism.
The API supports pagination through the `pagesize` and `pagestart` parameters, where `pagesize` determines the 
number of results per request and `pagestart` specifies the index of the first result in the similarity-sorted list.
To fetch the next set of results, set `pagestart` to the last element index of the previous page (0 for the first page).
The response is a JSON array where each object contains a `url` and `similarity_order`. Ensure the values are properly
URL-encoded when making a request.

### Parameters

| Parameter   | Type   | Required | Description |
|------------|--------|----------|-------------|
| `pattern`  | string | Yes      | The pattern text used for semantic search in posts. |
| `pagesize` | int    | Yes      | The number of results to return per request. |
| `pagestart` | int    | Yes      | The index of the first post in the similarity-sorted list; use 0 for the first page and the last element index of the previous page for subsequent pages. |

### Example Request

```http
GET /similarposts?pattern=thailand%20beaches&pagesize=10&pagestart=0
```

### Example SQL Query

```sql
SELECT * FROM hivesense_endpoints.get_similar_posts('thailand beaches', 10, 0);
```

### Example Response

```json
[
   {"url" : "@jpphotography/longtail-boat-in-the-andaman-sea-thailand", "similarity_order" : 1},
   {"url" : "@karunagata/tour-to-the-beach-e91da61426e42", "similarity_order" : 2},
   {"url" : "@hangin/landscape-seascape-contest-week-023", "similarity_order" : 3},
   {"url" : "@sandstorm/beach-wednesday-jomtien-beach-thailand", "similarity_order" : 4},
   {"url" : "@viktor.phuket/sunset-in-thailand", "similarity_order" : 5}
]
```


### REST Call Example
```http
GET 'https://localhost/hivesense-swagger/hivesense-api/similarposts?pattern=thailand%20beaches&pagesize=10&pagestart=0'
```







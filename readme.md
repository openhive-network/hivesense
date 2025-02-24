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

#### External containers
1. [HAF](https://gitlab.syncad.com/hive/haf) server includes
    - hivemind
    - [pgai](https://github.com/Postgres-artificialintelligence/PGAI)
    - [pgvector](https://github.com/pgvector/pgvector)
2. [OLLAMA server](https://github.com/ollama/ollama)

### System context diagram
![](./doc/images/system_context.png)

### Database
#### PostgreSQL roles
- **hivesense_owner** is able to modify the database tables, their content and modify schema. If used to start HiveSense
  haf application main loop that fill the tables
- **hivesense_user** has only read access to the HiveSense tables, used to execute queries started by REST API server 

#### HAF application
- context name: **hivesense_app**
- context schema(default): **hivesense_app**

##### Stages
1.  **MASSIVE_PROCESSING** started when the context is more than 10 blocks after hive head. Max. 100 blocks in a one batch


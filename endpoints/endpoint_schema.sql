SET ROLE reptracker_owner;

/** openapi
openapi: 3.1.0
info:
  title: Hivesense
  description: >-
    Hivesense is an API which use AI methods to search in Hive social network
  license:
    name: MIT License
    url: https://opensource.org/license/mit
  version: 1.27.8
externalDocs:
  description: Hivesense gitlab repository
  url: https://gitlab.syncad.com/Ickiewicz/hivesens
tags:
  - name: AI
    description: AI methods to browse Hive social data
  - name: Other
    description: General API information
servers:
  - url: /hivesense-api
 */

DO $__$
    DECLARE
        __schema_name VARCHAR;
        __swagger_url TEXT;
    BEGIN
        SHOW SEARCH_PATH INTO __schema_name;
        __swagger_url := current_setting('custom.swagger_url')::TEXT;

        CREATE SCHEMA IF NOT EXISTS hivesense_endpoints AUTHORIZATION reptracker_owner;

        EXECUTE FORMAT(
                'create or replace function hivesense_endpoints.root() returns json as $_$
                declare
                -- openapi-spec
-- openapi-generated-code-begin
  openapi json = $$
{
  "openapi": "3.1.0",
  "info": {
    "title": "Hivesense",
    "description": "Hivesense is an API which use AI methods to search in Hive social network",
    "license": {
      "name": "MIT License",
      "url": "https://opensource.org/license/mit"
    },
    "version": "1.27.8"
  },
  "externalDocs": {
    "description": "Hivesense gitlab repository",
    "url": "https://gitlab.syncad.com/Ickiewicz/hivesens"
  },
  "tags": [
    {
      "name": "AI",
      "description": "AI methods to browse Hive social data"
    },
    {
      "name": "Other",
      "description": "General API information"
    }
  ],
  "servers": [
    {
      "url": "/hivesense-api"
    }
  ],
  "paths": {
    "/similarposts": {
      "get": {
        "tags": [
          "AI"
        ],
        "summary": "List of posts semantic similar to a given pattern",
        "description": "Make a semantic search for a posts similar to a pattern text given as a parameter\n\nSQL example\n* `SELECT * FROM hivesense_endpoints.get_similar_posts(''astronauts on moon'', 10);`\n\nREST call example\n* `GET ''https://%1$s/hivesense-api/similarposts/''`\n",
        "operationId": "hivesense_endpoints.get_similar_posts",
        "parameters": [
          {
            "in": "query",
            "name": "pattern",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "pattern to search in posts"
          },
          {
            "in": "query",
            "name": "pagesize",
            "required": true,
            "schema": {
              "type": "integer"
            }
          }
        ],
        "responses": {
          "200": {
            "description": "* Returns  'JSON'\n",
                "content": {
                "application/json": {
                "schema": {
                "type": "string",
                "x-sql-datatype": "JSON"
                },
                "example": {
                "@bob/my_introduction_post": null,
                "@alice/intro": null
                }
                }
                }
                }
                }
                }
                }
                }
                }
                $$;
                -- openapi-generated-code-end
                -- openapi-generated-code-begin
                openapi json = $$
                {
                "openapi": "3.1.0",
                "info": {
                "title": "Hivesense",
                "description": "Hivesense gives semantic search for Hive posts",
                "license": {
                "name": "MIT License",
                "url": "https://opensource.org/license/mit"
                },
                "version": "1.27.8"
                },
                "externalDocs": {
                "description": "Hivesense gitlab repository",
                "url": "https://gitlab.syncad.com/Ickiewicz/hivesens"
                },
                "tags": [
                {
                "name": "AI",
                "description": "Functions supported by AI methods"
                }
                ],
                "servers": [
                {
                "url": "/hivesense-api"
                }
                ],
                "paths": {
                "/accounts/{account-name}/reputation": {
                "get": {
                "tags": [
                "Accounts"
                ],
                "summary": "Account reputation",
                "description": "Returns calculated reputation with formula found in:\nhttps://hive.blog/steemit/@digitalnotvir/how-reputation-scores-are-calculated-the-details-explained-with-simple-math\n\nSQL example\n* `SELECT * FROM hivesense_endpoints.get_account_reputation(''blocktrades'');`\n\nREST call example\n* `GET ''https://%1$s/reputation-api/accounts/blocktrades/reputation''`\n",
                "operationId": "hivesense_endpoints.get_account_reputation",
                "parameters": [
                {
                "in": "path",
                "name": "account-name",
                "required": true,
                "schema": {
                "type": "string"
                },
                "description": "Name of the account"
                }
                ],
                "responses": {
                "200": {
                "description": "No such account in the database",
                "content": {
                "application/json": {
                "schema": {
                "type": "integer"
                },
                "example": 69
                }
                }
                }
                }
                }
                },
                "/last-synced-block": {
                "get": {
                "tags": [
                "Other"
                ],
                "summary": "Get last block number synced by Hivesense",
                "description": "Get the block number of the last block synced by Hivesense.\n\nSQL example\n* `SELECT * FROM hivesense_endpoints.get_rep_last_synced_block();`\n\nREST call example\n* `GET ''https://%1$s/reputation-api/last-synced-block''`\n",
                "operationId": "hivesense_endpoints.get_rep_last_synced_block",
                "responses": {
                "200": {
                "description": "Last synced block by Hivesense\n\n* Returns `INT`\n",
                "content": {
                "application/json": {
                "schema": {
                "type": "integer"
                },
                "example": 5000000
                }
                }
                },
                "404": {
                "description": "No blocks synced"
                }
                }
                }
                }
                }
                }
                $$;
                -- openapi-generated-code-end
                begin
                return openapi;
                end
                $_$ language plpgsql;'
            , __swagger_url);

    END
$__$;

RESET ROLE;

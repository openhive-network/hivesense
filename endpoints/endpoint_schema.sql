SET ROLE hivesense_owner;

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

        CREATE SCHEMA IF NOT EXISTS hivesense_endpoints AUTHORIZATION hivesense_owner;

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
        "description": "Make a semantic search for a posts similar to a pattern text given as a parameter\n\nSQL example\n* `SELECT * FROM hivesense_endpoints.get_similar_posts(''astronauts on moon'', 10,0);`\n\nREST call example\n* `GET ''https://%1$s/hivesense-api/similarposts/''`\n",
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
          },
          {
            "in": "query",
            "name": "pagestart",
            "required": true,
            "schema": {
              "type": "integer"
            },
            "description": "the order number of the starting post in the similarity-sorted list."
          }
        ],
        "responses": {
          "200": {
            "description": "* Returns  JSON\n",
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
begin
  return openapi;
end
$_$ language plpgsql;'
            , __swagger_url);

    END
$__$;

RESET ROLE;

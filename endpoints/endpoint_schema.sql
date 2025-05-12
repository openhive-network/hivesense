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
  url: https://gitlab.syncad.com/hive/hivesense
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
    "url": "https://gitlab.syncad.com/hive/hivesense"
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
        "description": "Semantic search endpoint designed to find posts based on their semantic\nsimilarity to a provided text pattern. It allows users to search for\ncontent that is contextually and meaningfully similar to their search\nquery, going beyond simple keyword matching.\n\nThe API returns results in JSON format, containing comprehensive post information\nincluding author details, title, body content, category, voting data, and various metadata.\nResults are automatically ranked by their semantic relevance to the search pattern,\nensuring the most relevant content appears first.\n",
        "operationId": "hivesense_endpoints.get_similar_posts",
        "parameters": [
          {
            "in": "query",
            "name": "pattern",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Text pattern used for semantic search. The query text (e.g., \"astronauts on moon\", \"climate change\") to find semantically similar posts."
          },
          {
            "in": "query",
            "name": "tr_body",
            "required": true,
            "schema": {
              "type": "integer"
            },
            "description": "Truncation length for post bodies. Use 0 for full content, or specify character limit."
          },
          {
            "in": "query",
            "name": "posts_limit",
            "required": true,
            "schema": {
              "type": "integer"
            },
            "description": "Specifies how many posts to return in the results."
          },
          {
            "in": "query",
            "name": "observer",
            "required": false,
            "schema": {
              "type": "string",
              "default": ""
            },
            "description": "Observer (hive account name) whose settings (such as muted lists) are used to filter out excluded posts from the search results"
          },
          {
            "in": "query",
            "name": "start_author",
            "required": false,
            "schema": {
              "type": "string",
              "default": ""
            },
            "description": "Together with start_permlink, identifies the last post from the previous page. These two parameters combined\ndefine the starting point for pagination when fetching the next set of results.\n"
          },
          {
            "in": "query",
            "name": "start_permlink",
            "required": false,
            "schema": {
              "type": "string",
              "default": ""
            },
            "description": "Together with start_author, identifies the last post from the previous page. The permlink is\nthe unique identifier (slug) of the post. These two parameters combined define the starting point\nfor pagination when fetching the next set of results.\n"
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
                "example": {}
              }
            }
          }
        }
      }
    },
    "/similarpostsbypost": {
      "get": {
        "tags": [
          "AI"
        ],
        "summary": "List of posts semantic similar to a given post described by author and permlink",
        "description": "Make a semantic search for a posts similar to a given post as a parameter. Returns max. first 50 most similar posts.\n\nSQL example\n* `SELECT * FROM hivesense_endpoints.get_similar_posts_by_post(''bue-witness'',''bue-witness-post'', 20, 10);`\n\nREST call example\n* `GET ''https://%1$s/hivesense-api/similarpoststsbypost/''`\n",
        "operationId": "hivesense_endpoints.get_similar_posts_by_post",
        "parameters": [
          {
            "in": "query",
            "name": "author",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "post author name"
          },
          {
            "in": "query",
            "name": "permlink",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "permlink of a post"
          },
          {
            "in": "query",
            "name": "tr_body",
            "required": true,
            "schema": {
              "type": "integer"
            },
            "description": "0 means no truncate, other return post shrinked to given value"
          },
          {
            "in": "query",
            "name": "posts_limit",
            "required": true,
            "schema": {
              "type": "integer"
            },
            "description": "limit for number of posts, cannot be grater than 50"
          },
          {
            "in": "query",
            "name": "observer",
            "required": false,
            "schema": {
              "type": "string",
              "default": ""
            },
            "description": "account name to use its blacklists"
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
                "example": {}
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

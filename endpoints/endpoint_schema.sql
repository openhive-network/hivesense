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
            "description": "* Returns  JSON with a sorted list of posts\n",
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
        "summary": "Get semantically similar posts to a given Hive post",
        "description": "Performs semantic similarity search to find posts that are contextually\nsimilar to a specified Hive post. The endpoint analyzes the content and\ncontext of the target post and returns up to 50 related posts, ranked by\ntheir similarity score.\n\nKey features:\n- Semantic analysis considers post content and context\n- Results are ordered by similarity (most similar first)\n- Optional content filtering through observer blacklists\n- Configurable body length truncation for preview purposes\n- Maximum of 50 posts returned to ensure performance\n\nThe similarity analysis takes into account:\n- Post content and context\n- Semantic relationships between posts\n- Topic relevance and contextual meaning\n\nSQL example:\nSELECT * FROM hivesense_endpoints.get_similar_posts_by_post(''bue-witness'', ''bue-witness-post'', 20, 10);\n\nREST call example:\nGET ''https://%1$s/hivesense-api/similarpostsbypost?author=bue-witness&permlink=my-blog-post&tr_body=20&posts_limit=10''\n",
        "operationId": "hivesense_endpoints.get_similar_posts_by_post",
        "parameters": [
          {
            "in": "query",
            "name": "author",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "The Hive username of the post author. This is the account name that\ncreated the original post for which you want to find similar content.\nMust be a valid Hive account name.\n",
            "example": "bue-witness"
          },
          {
            "in": "query",
            "name": "permlink",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "The unique permlink identifier of the post. This is the URL-friendly\nversion of the post title that appears in the post URL on Hive.\nTogether with the author name, it uniquely identifies the post.\n",
            "example": "my-blog-post"
          },
          {
            "in": "query",
            "name": "tr_body",
            "required": true,
            "schema": {
              "type": "integer",
              "minimum": 0,
              "maximum": 65535
            },
            "description": "Controls the length of returned post bodies in the results. When set to 0,\nreturns complete post content. Any other positive value will truncate the\npost body to that many characters. Useful for generating previews or\nreducing response size. Maximum value is 65535 characters.\n",
            "example": 20
          },
          {
            "in": "query",
            "name": "posts_limit",
            "required": true,
            "schema": {
              "type": "integer",
              "minimum": 1,
              "maximum": 50
            },
            "description": "Specifies the maximum number of similar posts to return. Must be between\n1 and 50. The posts are returned in order of similarity, with the most\nsimilar posts first. Setting a lower limit can improve response times\nand reduce data transfer.\n",
            "example": 10
          },
          {
            "in": "query",
            "name": "observer",
            "required": false,
            "schema": {
              "type": "string",
              "default": ""
            },
            "description": "Optional Hive account name with blacklists that will be used to filter the\nresults. When provided, any posts from authors in the observer\nblacklist will be excluded from the results. Leave empty to disable\nblacklist filtering. Useful for content moderation and personalization.\n",
            "example": "hive.blog"
          }
        ],
        "responses": {
          "200": {
            "description": "Successful response with JSON that contains a list of similar posts",
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
    "/thematiccontributors": {
      "get": {
        "tags": [
          "AI"
        ],
        "summary": "List of Hive accounts thematically aligned with a given pattern, ranked by the semantic similarity of their posts.",
        "description": "This endpoint returns a JSON array of author names ranked by their thematic alignment\nwith a given text pattern. The ranking is based on the semantic similarity of their\nposts to the input pattern, with higher-ranked posts contributing more to the author\u2019s score.\nEach authors score is computed as the sum of 1 / sqrt(r), where r is the rank of each post\nassociated with the author. Authors with more frequent and higher-ranked posts receive higher scores.\nThe result is a sorted list of author names, from most to least thematically aligned.\n",
        "operationId": "hivesense_endpoints.find_thematic_contributors",
        "parameters": [
          {
            "in": "query",
            "name": "thematic",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Text pattern used for semantic search. The query text (e.g., \"astronauts on moon\", \"climate change\") to find contributors.",
            "example": "Make witness node secure against hackers attack and emergency situations"
          },
          {
            "in": "query",
            "name": "authors_limit",
            "required": true,
            "schema": {
              "type": "integer"
            },
            "description": "Specifies how many authors to return in the results.",
            "example": 10
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
          }
        ],
        "responses": {
          "200": {
            "description": "* Returns  JSON with a sorted list of Hive accounts\n",
            "content": {
              "application/json": {
                "schema": {
                  "type": "string",
                  "x-sql-datatype": "JSON"
                },
                "example": [
                  "dele-puppy",
                  "nextgencrypto",
                  "xeroc",
                  "steemed",
                  "tuck-fheman",
                  "dantheman",
                  "salvation",
                  "pharesim",
                  "masteryoda",
                  "ihashfury"
                ]
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

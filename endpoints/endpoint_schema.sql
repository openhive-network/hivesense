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
    "/posts/search": {
      "get": {
        "tags": [
          "AI"
        ],
        "summary": "Full semantic search results in a single call",
        "description": "Returns an ordered list of posts most similar to a given query.\nThe first **N** results (default 10, max 50) are returned as full\nbridge-post JSON objects; the remaining results (up to **posts_limit**,\ndefault 100, max 1000) are stub entries containing only *author* and\n*permlink*.  Paging is now done entirely on the client side.\n",
        "operationId": "hivesense_endpoints.posts_search",
        "parameters": [
          {
            "in": "query",
            "name": "q",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Search query text for semantic similarity, e.g. `\"vector databases\"`"
          },
          {
            "in": "query",
            "name": "truncate",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 0
            },
            "description": "Body truncation length (0 = full content, >0 = truncate to N chars)"
          },
          {
            "in": "query",
            "name": "result_limit",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 100,
              "minimum": 1,
              "maximum": 1000
            },
            "description": "Total number of posts (full + stub) to return"
          },
          {
            "in": "query",
            "name": "full_posts",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 10,
              "minimum": 0,
              "maximum": 50
            },
            "description": "How many of the top results should include full post data"
          },
          {
            "in": "query",
            "name": "observer",
            "required": false,
            "schema": {
              "type": "string",
              "default": ""
            },
            "description": "Hive account whose mute lists etc. will be respected"
          }
        ],
        "responses": {
          "200": {
            "description": "JSON array of result objects",
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
    "/posts/{author}/{permlink}/similar": {
      "get": {
        "tags": [
          "AI"
        ],
        "summary": "Full semantic search results for similar posts in a single call",
        "description": "Performs semantic similarity search to find posts that are contextually\nsimilar to a specified Hive post. Returns an ordered list of posts most \nsimilar to the given post.\n\nThe first **N** results (default 10, max 50) are returned as full\nbridge-post JSON objects; the remaining results (up to **posts_limit**,\ndefault 100, max 1000) are stub entries containing only *author* and\n*permlink*. Paging is done entirely on the client side.\n\nKey features:\n- Semantic analysis considers post content and context\n- Results are ordered by similarity (most similar first)\n- Optional content filtering through observer blacklists\n- Configurable body length truncation for preview purposes\n- Split response: full data for top results, stubs for remainder\n\nThe similarity analysis takes into account:\n- Post content and context\n- Semantic relationships between posts\n- Topic relevance and contextual meaning\n\nSQL example:\nSELECT * FROM hivesense_endpoints.posts_similar(''bue-witness'', ''bue-witness-post'', 20, 100, 10);\n\nREST call example:\nGET ''https://%1$s/hivesense-api/posts/bue-witness/my-blog-post/similar?truncate=20&limit=100&full_posts=10''\n",
        "operationId": "hivesense_endpoints.posts_similar",
        "parameters": [
          {
            "in": "path",
            "name": "author",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "The Hive username of the post author. This is the account name that\ncreated the original post for which you want to find similar content.\nMust be a valid Hive account name.\n",
            "example": "bue-witness"
          },
          {
            "in": "path",
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
            "name": "truncate",
            "required": false,
            "schema": {
              "type": "integer",
              "minimum": 0,
              "maximum": 65535,
              "default": 0
            },
            "description": "Controls the length of returned post bodies in the results. When set to 0,\nreturns complete post content. Any other positive value will truncate the\npost body to that many characters. Useful for generating previews or\nreducing response size. Maximum value is 65535 characters.\n",
            "example": 20
          },
          {
            "in": "query",
            "name": "result_limit",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 100,
              "minimum": 1,
              "maximum": 1000
            },
            "description": "Total number of posts (full + stub) to return. Must be between\n1 and 1000. The posts are returned in order of similarity, with the most\nsimilar posts first. Setting a lower limit can improve response times\nand reduce data transfer.\n",
            "example": 100
          },
          {
            "in": "query",
            "name": "full_posts",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 10,
              "minimum": 0,
              "maximum": 50
            },
            "description": "How many of the top results should include full post data. Any \nremaining posts (up to result_limit) will be stub entries with only \nauthor & permlink. Set this to the size of your first page of results.\n",
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
    "/authors/search": {
      "get": {
        "tags": [
          "AI"
        ],
        "summary": "List of Hive accounts thematically aligned with a given pattern, ranked by the semantic similarity of their posts.",
        "description": "This endpoint returns a JSON array of author names ranked by their thematic alignment\nwith a given text pattern. The ranking is based on the semantic similarity of their\nposts to the input pattern, with higher-ranked posts contributing more to the author\u2019s score.\nEach authors score is computed as the sum of 1 / sqrt(r), where r is the rank of each post\nassociated with the author. Authors with more frequent and higher-ranked posts receive higher scores.\nThe result is a sorted list of author names, from most to least thematically aligned.\n",
        "operationId": "hivesense_endpoints.authors_search",
        "parameters": [
          {
            "in": "query",
            "name": "topic",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Topic or theme to search for. Authors whose posts are semantically related to this topic will be returned.",
            "example": "Make witness node secure against hackers attack and emergency situations"
          },
          {
            "in": "query",
            "name": "result_limit",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 10,
              "minimum": 1,
              "maximum": 100
            },
            "description": "Maximum number of authors to return (1-100).",
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
    },
    "/posts/by-ids": {
      "post": {
        "tags": [
          "AI"
        ],
        "summary": "Fetch full post details for multiple posts by their IDs",
        "description": "Retrieves complete post information for a batch of posts identified by\ntheir author/permlink pairs. This endpoint is designed to work with the\nnew paging model where search results return mostly stub entries, and\nclients fetch full details as needed for display.\n\nKey features:\n- Accepts up to 50 post identifiers in a single request\n- Returns posts in the same order as requested\n- Supports body truncation for preview mode\n- Respects observer mute lists and blacklists\n- Returns null for non-existent posts while preserving order\n\nThis endpoint is typically used after calling /posts/search or\n/posts/{author}/{permlink}/similar, which return full data for only\nthe first N posts. When the user scrolls or pages through results,\nthe client calls this endpoint with the next batch of author/permlink\npairs to get their full details.\n\nExample workflow:\n1. Call /posts/search with result_limit=1000, full_posts=10\n2. Display first 10 posts immediately (already have full data)\n3. When user scrolls to post 11, call this endpoint with posts 11-20\n4. Continue fetching batches as user scrolls\n",
        "operationId": "hivesense_endpoints.posts_by_ids",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "posts"
                ],
                "properties": {
                  "posts": {
                    "type": "array",
                    "description": "Array of post identifiers. Each item must have both ''author'' \nand ''permlink'' fields. Maximum 50 posts per request.\n",
                    "minItems": 1,
                    "maxItems": 50,
                    "items": {
                      "type": "object",
                      "required": [
                        "author",
                        "permlink"
                      ],
                      "properties": {
                        "author": {
                          "type": "string",
                          "description": "The Hive username of the post author"
                        },
                        "permlink": {
                          "type": "string",
                          "description": "The unique permlink identifier of the post"
                        }
                      }
                    },
                    "example": [
                      {
                        "author": "bue-witness",
                        "permlink": "my-first-post"
                      },
                      {
                        "author": "another-user",
                        "permlink": "interesting-topic"
                      }
                    ]
                  },
                  "truncate": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 65535,
                    "default": 0,
                    "description": "Body truncation length. 0 returns full content, positive values\ntruncate to N characters. Useful for preview mode.\n"
                  },
                  "observer": {
                    "type": "string",
                    "default": "",
                    "description": "Optional Hive account whose mute lists and blacklists will be\napplied to filter results. Leave empty to disable filtering.\n"
                  }
                }
              }
            }
          }
        },
        "responses": {
          "200": {
            "description": "JSON array of post objects in the same order as requested.\nNon-existent posts are returned as null to preserve array indices.\n",
            "content": {
              "application/json": {
                "schema": {
                  "type": "string",
                  "x-sql-datatype": "JSON"
                },
                "example": {}
              }
            }
          },
          "400": {
            "description": "Invalid request (e.g., too many posts, invalid format)"
          }
        }
      }
    },
    "/posts/by-ids-query": {
      "get": {
        "tags": [
          "AI"
        ],
        "summary": "Fetch full post details for multiple posts (GET variant)",
        "description": "GET variant of /posts/by-ids that accepts post identifiers as query\nparameters. Limited to fetching fewer posts due to URL length constraints.\n\nFor larger batches, use the POST /posts/by-ids endpoint instead.\n\nThe posts parameter should be a URL-encoded JSON array.\n\nExample:\nGET /posts/by-ids-query?posts=[{\"author\":\"user1\",\"permlink\":\"post1\"}]&truncate=500\n",
        "operationId": "hivesense_endpoints.posts_by_ids_query",
        "parameters": [
          {
            "in": "query",
            "name": "posts",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "URL-encoded JSON array of post identifiers. Each object must have\n''author'' and ''permlink'' fields. Maximum 10 posts for GET requests.\n",
            "example": "[{\"author\":\"bue-witness\",\"permlink\":\"my-post\"}]"
          },
          {
            "in": "query",
            "name": "truncate",
            "required": false,
            "schema": {
              "type": "integer",
              "minimum": 0,
              "maximum": 65535,
              "default": 0
            },
            "description": "Body truncation length (0 = full content)"
          },
          {
            "in": "query",
            "name": "observer",
            "required": false,
            "schema": {
              "type": "string",
              "default": ""
            },
            "description": "Optional Hive account for filtering"
          }
        ],
        "responses": {
          "200": {
            "description": "JSON array of post objects",
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
  },
  "components": {
    "schemas": {
      "embeddingupdate": {
        "type": "object",
        "properties": {
          "sync_seq": {
            "type": "integer"
          },
          "op": {
            "type": "string"
          },
          "author": {
            "type": "string"
          },
          "permlink": {
            "type": "string"
          },
          "number_of_tokens": {
            "type": "integer"
          },
          "last_vectors_block": {
            "type": "integer"
          },
          "embeddings": {
            "type": "array",
            "items": {
              "type": "array",
              "items": {
                "type": "number"
              }
            }
          }
        }
      },
      "syncsettings": {
        "type": "object",
        "properties": {
          "sync_uuid": {
            "type": "string",
            "format": "uuid"
          },
          "llm": {
            "type": "string"
          },
          "embedding_dimensionality": {
            "type": "integer"
          },
          "document_prefix": {
            "type": "string"
          },
          "query_prefix": {
            "type": "string"
          },
          "tokens_per_chunk": {
            "type": "integer"
          },
          "overlap_amount": {
            "type": "number"
          },
          "min_token_threshold": {
            "type": "integer"
          },
          "max_embeddings_per_post": {
            "type": "integer"
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

SET ROLE hivesense_owner;

/** openapi:paths
/embedding-updates:
  get:
    tags:
      - AI
    summary: Stream post-level embedding operations since a given sequence number
    operationId: hivesense_endpoints.embedding_updates
    parameters:
      - in: query
        name: after_seq
        required: true
        schema: { type: integer }
        description: |
          Clients pass the highest sync_seq they have applied.  
          The server returns every operation with sync_seq > after_seq.
      - in: query
        name: page_size
        required: true
        schema: { type: integer }
        description: Maximum number of operations to return.
    responses:
      '200':
        description: JSON array of operations, ordered by sync_seq.
        content:
          application/json:
            schema: { type: string, x-sql-datatype: JSONB }
*/
-- openapi-generated-code-begin
CREATE OR REPLACE FUNCTION hivesense_endpoints.get_sync_settings()
RETURNS TABLE (
  sync_uuid uuid,
  llm text,
  embedding_dimensionality int,
  document_prefix text,
  query_prefix text,
  tokens_per_chunk int,
  overlap_amount real,
  min_token_threshold int,
  max_embeddings_per_post int
)
-- openapi-generated-code-end
AS $$
  SELECT
    sync_uuid,
    llm,
    embedding_dimensionality,
    document_prefix,
    query_prefix,
    tokens_per_chunk,
    overlap_amount,
    min_token_threshold,
    max_embeddings_per_post
  FROM hivesense_app_status
  ORDER BY id
  LIMIT 1;
$$ LANGUAGE sql STABLE;

/** openapi:paths
/embedding-updates:
  get:
    tags:
      - AI
    summary: Stream post-level embedding operations since a given sequence number
    operationId: hivesense_endpoints.embedding_updates
    parameters:
      - in: query
        name: after_seq
        required: true
        schema: { type: integer }
        description: |
          Clients pass the highest sync_seq they have applied.  
          The server returns every operation with sync_seq > after_seq.
      - in: query
        name: page_size
        required: true
        schema: { type: integer }
        description: Maximum number of operations to return.
    responses:
      '200':
        description: JSON array of operations, ordered by sync_seq.
        content:
          application/json:
            schema: { type: string, x-sql-datatype: JSONB }
*/
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hivesense_endpoints.embedding_updates;
CREATE OR REPLACE FUNCTION hivesense_endpoints.embedding_updates(
    "after_seq" int,
    "page_size" int,
    "sync_uuid" uuid
)
RETURNS TABLE (
  sync_seq            int,
  op                  text,
  author              text,
  permlink            text,
  number_of_tokens    int,
  last_vectors_block  int,
  embeddings          real[]    -- PostgREST will JSON-encode this array
)
-- openapi-generated-code-end
  LANGUAGE plpgsql
  STABLE PARALLEL SAFE
AS $$
DECLARE
  __max_visible integer;
  __our_uuid    uuid;
BEGIN
  -- 0) fetch the current watermark and uuid
  SELECT max_visible_sync_seq, has.sync_uuid
    INTO __max_visible, __our_uuid
    FROM hivesense_app.hivesense_app_status has
   WHERE id = 1;

  IF sync_uuid != __our_uuid THEN
    RAISE EXCEPTION 'UUID Mismatch'
      USING DETAIL = 'Your sync_uuid parameter doesn''t match ours -- perhaps you were syncing with a different server?',
            HINT = 'To sync with this server, you will need to wipe your hivesense data';
  END IF;

  PERFORM set_config('response.headers', format('[{"X-Current-Block-Num":"%s"}]', hive.app_get_current_block_num('hivesense_app')), true);

  RETURN QUERY
  WITH 
  -- 1a) the first N inserts/updates
  pv_limited AS (
    SELECT DISTINCT ON (pv.sync_seq, post_id) pv.sync_seq, post_id
      FROM hivesense_app.posts_vectors pv
     WHERE pv.sync_seq > after_seq
       AND pv.sync_seq <= __max_visible
     ORDER BY pv.sync_seq
     LIMIT page_size
  ),
  -- 1b) the first N deletes
  de_limited AS (
    SELECT DISTINCT ON (de.sync_seq, post_id) de.sync_seq, post_id
      FROM hivesense_app.deleted_embeddings de
     WHERE de.sync_seq > after_seq
       AND de.sync_seq <= __max_visible
     ORDER BY de.sync_seq
     LIMIT page_size
  ),
  -- 2) union them into your final N changes, classifying op
  limited_ops AS (
    SELECT
      COALESCE(pv.sync_seq, de.sync_seq) AS sync_seq,
      COALESCE(pv.post_id,  de.post_id)  AS post_id,
      CASE
        WHEN pv.sync_seq IS NOT NULL AND de.sync_seq IS NOT NULL THEN 'update'
        WHEN pv.sync_seq IS NOT NULL                             THEN 'insert'
        ELSE                                                          'delete'
      END AS op
    FROM pv_limited pv
    FULL JOIN de_limited de USING (sync_seq, post_id)
    ORDER BY COALESCE(pv.sync_seq, de.sync_seq)
    LIMIT page_size
  ),
  -- 3) join only those N rows to metadata
  ops_with_meta AS (
    SELECT
      lo.sync_seq,
      lo.post_id,
      lo.op,
      ha.name      AS author,
      hpd.permlink AS permlink,
      pd.number_of_tokens,
      pd.last_vectors_block
    FROM limited_ops lo
    JOIN hivemind_app.hive_posts         hp  ON hp.id         = lo.post_id
    JOIN hivemind_app.hive_accounts      ha  ON ha.id         = hp.author_id
    JOIN hivemind_app.hive_permlink_data hpd ON hpd.id        = hp.permlink_id
    JOIN hivesense_app.post_data         pd  ON pd.post_id    = lo.post_id
  )
  -- 4) fetch embeddings for only those N rows
  SELECT
    om.sync_seq,
    om.op,
    om.author::text,
    om.permlink::text,
    om.number_of_tokens,
    om.last_vectors_block,
    -- build a Postgres array of real[] here; PostgREST will turn it into JSON
    ARRAY(
      SELECT pv2.embedding::real[]
        FROM hivesense_app.posts_vectors pv2
       WHERE pv2.sync_seq = om.sync_seq
         AND pv2.post_id  = om.post_id
       ORDER BY pv2.chunk_number
    ) AS embeddings
  FROM ops_with_meta om
  ORDER BY om.sync_seq
  LIMIT page_size;
END;
$$;

RESET ROLE;

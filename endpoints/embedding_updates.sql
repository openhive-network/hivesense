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
DROP FUNCTION IF EXISTS hivesense_endpoints.embedding_updates;
CREATE OR REPLACE FUNCTION hivesense_endpoints.embedding_updates(
    "after_seq" INT,
    "page_size"     INT
)
RETURNS JSONB
-- openapi-generated-code-end
  LANGUAGE plpgsql
  STABLE PARALLEL SAFE
AS $$
DECLARE
  __result      jsonb;
  __max_visible integer;
BEGIN
  -- 0) fetch the current watermark
  SELECT max_visible_sync_seq
    INTO __max_visible
    FROM hivesense_app.hivesense_app_status
   WHERE id = 1;

  WITH 
  -- 1a) the first N inserts/updates
  pv_limited AS (
    SELECT sync_seq, post_id
      FROM hivesense_app.posts_vectors
     WHERE sync_seq > after_seq
       AND sync_seq <= __max_visible
     ORDER BY sync_seq
     LIMIT page_size
  ),
  -- 1b) the first N deletes
  de_limited AS (
    SELECT sync_seq, post_id
      FROM hivesense_app.deleted_embeddings
     WHERE sync_seq > after_seq
       AND sync_seq <= __max_visible
     ORDER BY sync_seq
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
  ),
  -- 4) fetch embeddings for only those N rows
  ops_with_embeddings AS (
    SELECT
      om.sync_seq,
      om.op,
      om.author,
      om.permlink,
      om.number_of_tokens,
      om.last_vectors_block,
      COALESCE(
        (
          SELECT jsonb_agg(to_jsonb(pv2.embedding::real[]) ORDER BY pv2.chunk_number)
            FROM hivesense_app.posts_vectors pv2
           WHERE pv2.sync_seq = om.sync_seq
             AND pv2.post_id  = om.post_id
        ),
        '[]'::jsonb
      ) AS embeddings
    FROM ops_with_meta om
  )
  -- 5) build the final JSONB array
  SELECT jsonb_agg(
           jsonb_build_object(
             'sync_seq',           sync_seq,
             'op',                 op,
             'author',             author,
             'permlink',           permlink,
             'number_of_tokens',   number_of_tokens,
             'last_vectors_block', last_vectors_block,
             'embeddings',         embeddings
           )
         )
    INTO __result
    FROM ops_with_embeddings;

  RETURN COALESCE(__result, '[]'::jsonb);
END;
$$;

RESET ROLE;

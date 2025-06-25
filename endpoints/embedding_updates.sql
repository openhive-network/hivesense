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
LANGUAGE plpgsql STABLE
AS
$$
DECLARE
    __result        JSONB;
    __max_visible   INT;
BEGIN
    -- only expose completed sync_seq up to this threshold
    SELECT max_visible_sync_seq
      INTO __max_visible
      FROM hivesense_app.hivesense_app_status
     WHERE id = 1;

    WITH joined_ops AS (
      SELECT
        COALESCE(pv.sync_seq, de.sync_seq) AS sync_seq,
        COALESCE(pv.post_id,  de.post_id)  AS post_id,
        CASE
          WHEN pv.sync_seq IS NOT NULL AND de.sync_seq IS NOT NULL THEN 'update'
          WHEN pv.sync_seq IS NOT NULL                             THEN 'insert'
          ELSE                                                          'delete'
        END AS op
      FROM (
        SELECT DISTINCT sync_seq, post_id
          FROM hivesense_app.posts_vectors
         WHERE sync_seq > after_seq
           AND sync_seq <= __max_visible
      ) pv
      FULL OUTER JOIN (
        SELECT sync_seq, post_id
          FROM hivesense_app.deleted_embeddings
         WHERE sync_seq > after_seq
           AND sync_seq <= __max_visible
      ) de USING (sync_seq, post_id)
    ),
    ops_with_embeddings AS (
      SELECT
        jo.sync_seq,
        jo.op,
        ha.name      AS author,
        hpd.permlink AS permlink,
        pd.number_of_tokens,
        pd.last_vectors_block,
        CASE
          WHEN jo.op IN ('insert','update') THEN (
            -- array of embeddings, ordered by chunk_number
            SELECT jsonb_agg(to_jsonb(pv2.embedding::real[]) ORDER BY pv2.chunk_number)
              FROM hivesense_app.posts_vectors pv2
             WHERE pv2.sync_seq = jo.sync_seq
               AND pv2.post_id  = jo.post_id
          )
          ELSE '[]'::JSONB
        END AS embeddings
      FROM joined_ops jo
      JOIN hivemind_app.hive_posts            hp  ON hp.id         = jo.post_id
      JOIN hivemind_app.hive_accounts         ha  ON ha.id         = hp.author_id
      JOIN hivemind_app.hive_permlink_data    hpd ON hpd.id        = hp.permlink_id
      JOIN hivesense_app.post_data            pd  ON pd.post_id    = jo.post_id
      ORDER BY jo.sync_seq
      LIMIT "page_size"
    )

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

    RETURN COALESCE(__result, '[]'::JSONB);
END
$$;

RESET ROLE;

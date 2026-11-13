SET ROLE hivesense_owner;

-- A hivemind older than its _votes_mode parameter has only the seven-argument
-- create_bridge_post_object, and plpgsql resolves a call only when it runs:
-- choose the call per row so the endpoints returning full posts keep answering
-- on such a node (with active_votes embedded) and go vote-free once hivemind
-- has the mode.
CREATE OR REPLACE FUNCTION hivesense_app.full_post_object(
    _observer_id INT,
    _row RECORD,
    _truncate INT
)
RETURNS JSONB
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    IF to_regprocedure(
           'hivemind_postgrest_utilities.create_bridge_post_object(integer, record, integer, text[], boolean, boolean, jsonb, smallint, integer)'
       ) IS NULL THEN
        RETURN hivemind_postgrest_utilities.create_bridge_post_object(
                   _observer_id, _row, _truncate, NULL, _row.is_pinned, TRUE);
    END IF;
    RETURN hivemind_postgrest_utilities.create_bridge_post_object(
               _observer_id, _row, _truncate, NULL, _row.is_pinned, TRUE,
               _votes_mode => 1::SMALLINT);
END;
$$;

RESET ROLE;

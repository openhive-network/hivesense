SET ROLE hivesense_owner;

CREATE OR REPLACE PROCEDURE hivesense_massive_processing(
    IN _from INT, IN _to INT, IN _logs BOOLEAN
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __start_ts timestamptz;
  __end_ts   timestamptz;
BEGIN
  PERFORM set_config('synchronous_commit', 'OFF', false);

  IF _logs THEN
    RAISE NOTICE 'Hivesense is attempting to process a block range: <%, %>', _from, _to;
    __start_ts := clock_timestamp();
  END IF;

  PERFORM hivesense_block_range_data(_from, _to);

  IF _logs THEN
    __end_ts := clock_timestamp();
    RAISE NOTICE 'Hivesense processed block range: <%, %> successfully in % s
    ', _from, _to, (extract(epoch FROM __end_ts - __start_ts));
  END IF;
END
$$;

CREATE OR REPLACE PROCEDURE hivesense_single_processing(
    in _from INT, in _to INT, IN _logs BOOLEAN)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __start_ts timestamptz;
  __end_ts   timestamptz;
BEGIN
  PERFORM set_config('synchronous_commit', 'ON', false);

  IF _logs THEN
    RAISE NOTICE 'Hivesense processing block: %...', _from;
    __start_ts := clock_timestamp();
  END IF;

  PERFORM hivesense_block_range_data(_from, _to);
  
  IF _logs THEN
    __end_ts := clock_timestamp();
    RAISE NOTICE 'Hivesense processed block % successfully in % s
    ', _from, (extract(epoch FROM __end_ts - __start_ts));
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION continueProcessingLoop(
    _appContext hive.context_name,
    _maxBlockLimit INT,
    _blocks_range hive.blocks_range
)
RETURNS BOOLEAN
LANGUAGE 'plpgsql'
AS
$$
BEGIN
    IF _blocks_range IS NULL AND _maxBlockLimit IS NOT NULL THEN
        IF hive.app_get_current_block_num(_appContext) >= _maxBlockLimit THEN
            RAISE NOTICE 'Blocks limit reached. Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
            RETURN FALSE;
        END IF;
    END IF;

    IF NOT continueProcessing() THEN
        RAISE NOTICE 'Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END
$$;

/** Application entry point, which:
  - defines its data schema,
  - creates HAF application context,
  - starts application main-loop (which iterates infinitely). 
  - To stop it call `stopProcessing();` from another session and commit its trasaction.
*/
CREATE OR REPLACE PROCEDURE main(
    IN _appContext hive.context_name,
    IN _maxBlockLimit INT = NULL
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  _blocks_range hive.blocks_range := (0,0);
BEGIN
  IF _maxBlockLimit != NULL THEN
    RAISE NOTICE 'Max block limit is specified as: %', _maxBlockLimit;
  END IF;

  PERFORM allowProcessing();
  
  RAISE NOTICE 'Last block processed by application: %', hive.app_get_current_block_num(_appContext);

  RAISE NOTICE 'Entering application main loop...';

  LOOP
    CALL hive.app_next_iteration(
      _appContext,
      _blocks_range, 
      _override_max_batch => NULL, 
      _limit => _maxBlockLimit);

    IF NOT continueProcessingLoop( _appContext, _maxBlockLimit, _blocks_range ) THEN
        ROLLBACK;
        RETURN;
    END IF;

    IF _blocks_range IS NULL THEN
      RAISE INFO 'Waiting for next block...';
      CONTINUE;
    END IF;

    CALL hivesense_process_blocks(_appContext, _blocks_range);
  END LOOP;

  ASSERT FALSE, 'Cannot reach this point';
END
$$;


RESET ROLE;

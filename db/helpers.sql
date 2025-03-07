SET ROLE hivesense_owner;

CREATE OR REPLACE FUNCTION continueProcessing()
RETURNS BOOLEAN
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN continue_processing FROM hivesense_app_status LIMIT 1;
END
$$;

CREATE OR REPLACE FUNCTION allowProcessing()
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
BEGIN
  UPDATE hivesense_app_status SET continue_processing = True;
END
$$;

--- Helper function to be called from separate transaction 
--- (must be committed) to safely stop execution of the application.
CREATE OR REPLACE FUNCTION stopProcessing()
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
BEGIN
  UPDATE hivesense_app_status SET continue_processing = False;
END
$$;


CREATE OR REPLACE FUNCTION get_version()
RETURNS TEXT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN runtime_hash FROM version LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION set_version(_git_hash TEXT)
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
DECLARE
  _schema_hash TEXT := (SELECT schema_hash FROM version LIMIT 1);
BEGIN
TRUNCATE TABLE version;

IF _schema_hash IS NULL THEN
  INSERT INTO version(schema_hash, runtime_hash) VALUES (_git_hash, _git_hash);
ELSE
  INSERT INTO version(schema_hash, runtime_hash) VALUES (_schema_hash, _git_hash);
END IF;

END
$$;




CREATE OR REPLACE PROCEDURE hivesense_process_blocks(_context_name hive.context_name, _block_range hive.blocks_range,  IN _worker INT, OUT _done INT, _logs BOOLEAN = true)
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  IF hive.get_current_stage_name(_context_name) = 'MASSIVE_PROCESSING' THEN
    CALL hivesense_massive_processing(_block_range.first_block, _block_range.last_block, _logs, _worker, _done);
    RETURN;
  END IF;

  CALL hivesense_single_processing(_block_range.first_block, _block_range.last_block, _logs, _worker, _done);
END
$$;

CREATE OR REPLACE FUNCTION clean_content(_text_input TEXT)
    RETURNS TEXT
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
DECLARE
    __cleaned_text TEXT;
BEGIN
    RETURN _text_input;
    -- Step 1: Remove image markdown, URLs, and HTML tags in one go
    __cleaned_text := regexp_replace(
            _text_input,
            '(!\[.*?\]\(.*?\)|https?://\S+|<img[^>]*>|<b[^>]*>.*?</b>|<table[^>]*>.*?</table>|' ||
            '<div[^>]*>.*?</div>|<style[^>]*>.*?</style>|<script[^>]*>.*?</script>|<[^>]+>)',
            '', 'gi'
                      );
    -- Step 2: Remove Markdown-style links and image placeholders
    __cleaned_text := regexp_replace(__cleaned_text, '\[([^\]]+)\]\([^\)]+\)|!\[\]\([^)]*\)|!\S+\.(jpg|jpeg|png|gif)', '\1', 'gi');
    -- Step 3: Remove "Posted via" and unwanted characters
    __cleaned_text := regexp_replace(__cleaned_text, 'Posted via.*$|[*_]+|[^[:alnum:]\s,.!?"''’]', '', 'gmi');
    -- Step 4: Normalize whitespace (final step)
    __cleaned_text := trim(regexp_replace(__cleaned_text, '\s+', ' ', 'g'));
    RETURN __cleaned_text;
END;
$$;





RESET ROLE;

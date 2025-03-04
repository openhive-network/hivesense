SET ROLE hivesense_owner;

DO $__$
DECLARE
  __schema_name VARCHAR;
  __swagger_url TEXT;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;
  __swagger_url := current_setting('custom.swagger_url')::TEXT;

CREATE SCHEMA IF NOT EXISTS hivesense_endpoints AUTHORIZATION hivesense_owner;

END
$__$;

RESET ROLE;
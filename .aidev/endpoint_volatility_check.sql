-- Every function in hivesense_endpoints, the schema PostgREST exposes, must be
-- STABLE or IMMUTABLE: PostgREST runs a VOLATILE function READ WRITE once a GET
-- reaches it as a POST. Fails naming the VOLATILE ones. Run against an installed
-- database:
--   psql ... -v ON_ERROR_STOP=on -f .aidev/endpoint_volatility_check.sql
DO $$
DECLARE
    _volatile TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'hivesense_endpoints') THEN
        RAISE EXCEPTION 'no hivesense_endpoints schema: run after install';
    END IF;

    SELECT string_agg(p.oid::REGPROCEDURE::TEXT, ', ' ORDER BY p.oid::REGPROCEDURE::TEXT)
    INTO _volatile
    FROM pg_proc AS p
    INNER JOIN pg_namespace AS n ON p.pronamespace = n.oid
    WHERE n.nspname = 'hivesense_endpoints' AND p.provolatile = 'v';

    IF _volatile IS NOT NULL THEN
        RAISE EXCEPTION 'VOLATILE functions in hivesense_endpoints (declare them STABLE): %', _volatile;
    END IF;

    RAISE NOTICE 'every function in hivesense_endpoints is STABLE or IMMUTABLE';
END
$$;

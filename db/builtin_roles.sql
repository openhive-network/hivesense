DO $$
BEGIN
-- TODO(mickiewicz@syncad.com) : grant select for hivemind_user to hivemind_app.hive_state
-- then change inherit from hivemind to hivemind_user
CREATE ROLE hivesense_owner WITH LOGIN INHERIT IN ROLE hive_applications_owner_group, hivemind;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

DO $$
BEGIN
  CREATE ROLE hivesense_user WITH LOGIN INHERIT IN ROLE hive_applications_group, hivemind_user;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

--- Allow to create schemas
GRANT hivesense_owner TO haf_admin;
GRANT hivesense_user TO hivesense_owner;

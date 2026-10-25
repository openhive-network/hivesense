DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hivemind') THEN
    RAISE EXCEPTION 'role "hivemind" does not exist: install hivemind before hivesense';
  END IF;
END
$$;

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
  CREATE ROLE hivesense_user WITH LOGIN INHERIT IN ROLE hive_applications_group, hivemind;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

-- CREATE ROLE ... IN ROLE grants these only when it creates the role; dropping
-- and recreating hivemind (its uninstall and reinstall) takes the hivemind
-- memberships away from roles that already exist.
GRANT hive_applications_owner_group, hivemind TO hivesense_owner;
GRANT hive_applications_group, hivemind TO hivesense_user;

--- Allow to create schemas
GRANT hivesense_owner TO haf_admin;
GRANT hivesense_user TO hivesense_owner;

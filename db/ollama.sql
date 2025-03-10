DROP TYPE iF EXISTS hivesense_app.id_and_post CASCADE;
CREATE TYPE hivesense_app.id_and_post AS(
      post_id INTEGER
    , body TEXT
);


DROP TYPE iF EXISTS hivesense_app.post_and_vector CASCADE;
CREATE TYPE hivesense_app.post_and_vector AS(
      post_id INTEGER
    , vec vector
);

-- batch version of pga ollama embed
-- because it uses python, then only super user can be owner
-- TODO(mickiewicz@syncad.com) create pull request with the function for pgai
DROP FUNCTION IF EXISTS hivesense_app.ollama_embed(text,hivesense_app.id_and_post[],text,text,jsonb);
CREATE FUNCTION hivesense_app.ollama_embed(
    model text,
    posts hivesense_app.id_and_post[],
    host text DEFAULT NULL::text,
    keep_alive text DEFAULT NULL::text,
    embedding_options jsonb DEFAULT NULL::jsonb)
    RETURNS hivesense_app.post_and_vector[]
    LANGUAGE 'plpython3u'
    IMMUTABLE PARALLEL SAFE
    SET search_path=pg_catalog, pg_temp
AS $BODY$
    if "ai.version" not in GD:
        r = plpy.execute("select coalesce(pg_catalog.current_setting('ai.python_lib_dir', true), '/usr/local/lib/pgai') as python_lib_dir")
        python_lib_dir = r[0]["python_lib_dir"]
        from pathlib import Path
        import sys
        import sysconfig
        # Note: the "old" (pre-0.4.0) packages are installed as system-level python packages
        # and take precedence over our extension-version specific packages.
        # By removing the whole thing from the path we won't run into package conflicts.
        if "purelib" in sysconfig.get_path_names() and sysconfig.get_path("purelib") in sys.path:
            sys.path.remove(sysconfig.get_path("purelib"))
        python_lib_dir = Path(python_lib_dir).joinpath("0.8.0")
        import site
        site.addsitedir(str(python_lib_dir))
        from ai import __version__ as ai_version
        assert("0.8.0" == ai_version)
        GD["ai.version"] = "0.8.0"
    else:
        if GD["ai.version"] != "0.8.0":
            plpy.fatal("the pgai extension version has changed. start a new session")
    import ai.ollama
    client = ai.ollama.make_client(plpy, host)
    embedding_options_1 = None
    if embedding_options is not None:
        import json
        embedding_options_1 = {k: v for k, v in json.loads(embedding_options).items()}

    embeddings = []
    for post in posts:
        resp = client.embeddings(model, post['body'], options=embedding_options_1, keep_alive=keep_alive)
        embedding = resp.get("embedding")
        if embedding is not None:
            embeddings.append((post['post_id'], embedding))
    return embeddings;
$BODY$;

GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post[], text, text, jsonb) TO haf_admin WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post[], text, text, jsonb) TO hivesense_user;
GRANT EXECUTE ON FUNCTION hivesense_app.ollama_embed(text, hivesense_app.id_and_post[], text, text, jsonb) TO pg_database_owner WITH GRANT OPTION;
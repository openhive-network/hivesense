CREATE OR REPLACE FUNCTION post_clean_content(_text_input TEXT)
RETURNS TEXT
LANGUAGE plpython3u
IMMUTABLE
AS $$
import re

# Cache regex patterns in a global dictionary to avoid recompilation
if 'post_clean_content_patterns' not in globals():
    globals()['post_clean_content_patterns'] = {
        "remove_html": re.compile(r'(!\[.*?\]\(.*?\)|https?://\S+|<img[^>]*>|<b[^>]*>.*?</b>|'
                                  r'<table[^>]*>.*?</table>|<div[^>]*>.*?</div>|'
                                  r'<style[^>]*>.*?</style>|<script[^>]*>.*?</script>|<[^>]+>)', re.IGNORECASE),

        "remove_markdown_links": re.compile(r'\[([^\]]+)\]\([^\)]+\)|!\[\]\([^)]*\)|!\S+\.(jpg|jpeg|png|gif)', re.IGNORECASE),

        "remove_unwanted": re.compile(r'Posted via.*$|[*_]+|[^a-zA-Z0-9\s,.!?\"\'’]', re.MULTILINE),

        "normalize_whitespace": re.compile(r'\s+')
    }

patterns = globals()['post_clean_content_patterns']

def clean_text(text):
    text = patterns["remove_html"].sub('', text)
    text = patterns["remove_markdown_links"].sub(r'\1', text)
    text = patterns["remove_unwanted"].sub('', text)
    return patterns["normalize_whitespace"].sub(' ', text).strip()

return clean_text(_text_input)
$$;

GRANT EXECUTE ON FUNCTION post_clean_content(TEXT) TO hivesense_user;
GRANT EXECUTE ON FUNCTION post_clean_content(TEXT) TO pg_database_owner WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION post_clean_content(TEXT) TO pg_database_owner WITH GRANT OPTION;

CREATE OR REPLACE FUNCTION post_count_words(_post_body TEXT)
RETURNS INTEGER
LANGUAGE plpython3u
IMMUTABLE
PARALLEL SAFE
AS
$BODY$
    return len(_post_body.split())
$BODY$;

GRANT EXECUTE ON FUNCTION post_count_words(TEXT) TO hivesense_user;
GRANT EXECUTE ON FUNCTION post_count_words(TEXT) TO pg_database_owner WITH GRANT OPTION;
GRANT EXECUTE ON FUNCTION post_count_words(TEXT) TO pg_database_owner WITH GRANT OPTION;

CREATE OR REPLACE FUNCTION preprocess_post(_post_body TEXT)
RETURNS TEXT [] --NULL means that post was rejected
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS
$BODY$
DECLARE
    __words_limit INT := 50;
    __result TEXT;
    __chunks TEXT[];
BEGIN
    __result := post_clean_content( _post_body );
    IF __result IS NULL THEN
        RETURN __result;
    END IF;

    IF post_count_words( __result ) <= __words_limit THEN
        RETURN NULL;
    END IF;

    SELECT chunk_post( __result ) INTO __chunks;

    RETURN __chunks;
END;
$BODY$;

CREATE OR REPLACE FUNCTION chunk_post(
    _body TEXT,
    _chunk_size INTEGER DEFAULT 1000,
    _chunk_overlap INTEGER DEFAULT 100
)
RETURNS TEXT [] -- array with chunks
LANGUAGE plpython3u
IMMUTABLE
AS
$$
from langchain.text_splitter import RecursiveCharacterTextSplitter

text_splitter = RecursiveCharacterTextSplitter(
    chunk_size=_chunk_size,
    chunk_overlap=_chunk_overlap,
    separators=[]
)

chunks = text_splitter.split_text(_body)

return chunks[:3]
$$;

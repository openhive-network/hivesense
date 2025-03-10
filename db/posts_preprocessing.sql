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
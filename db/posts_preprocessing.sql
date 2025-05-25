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

        "remove_unwanted": re.compile(r'Posted via.*$|[*_]+', re.MULTILINE),

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

CREATE OR REPLACE FUNCTION preprocess_post(
    _post_body TEXT,
    _tokenizer_name TEXT DEFAULT 'intfloat/multilingual-e5-base',
    _max_tokens INTEGER DEFAULT 512,
    _min_new_ratio DOUBLE PRECISION DEFAULT 0.85,
    _lang_model TEXT DEFAULT 'xx_sent_ud_sm',
    _max_chunks INTEGER DEFAULT NULL,
    _truncate_long_sentences BOOLEAN DEFAULT TRUE,
    _document_prefix TEXT DEFAULT ''
)
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

    SELECT chunk_post( __result, _tokenizer_name, _max_tokens, _min_new_ratio, _lang_model, _max_chunks, _truncate_long_sentences, _document_prefix ) INTO __chunks;

    RETURN __chunks;
END;
$BODY$;


-- divides a post into parts of at most `max_token` tokens each, breaking
-- on sentence boundaries.
-- with the default parameters, it attempts to create a 15% overlap, so
-- the first 15% of the tokens of the second chunk will be the same as the
-- last 15% of the tokens from the first chunk.
--
-- note: if the last chunk would have only a few lines of new post content,
--       this will add as much overlap as possible instead of just targeting 15%
CREATE OR REPLACE FUNCTION chunk_post(
    _body TEXT,
    _tokenizer_name TEXT DEFAULT 'intfloat/multilingual-e5-base',
    _max_tokens INTEGER DEFAULT 512,
    _min_new_ratio DOUBLE PRECISION DEFAULT 0.85,
    _lang_model TEXT DEFAULT 'xx_sent_ud_sm',
    _max_chunks INTEGER DEFAULT NULL,
    _truncate_long_sentences BOOLEAN DEFAULT TRUE,
    _document_prefix TEXT DEFAULT ''
)
RETURNS TEXT[]    -- array of prefixed chunks
LANGUAGE plpython3u
IMMUTABLE
AS $$
# --- Cache loader dict in globals() ---
if 'chunk_post_cache' not in globals():
    globals()['chunk_post_cache'] = {}

cache = globals()['chunk_post_cache']
key = (_tokenizer_name, _lang_model)

if key not in cache:
    import spacy
    from transformers import AutoTokenizer

    nlp = spacy.load(_lang_model, disable=["ner","tagger","parser"])
    tokenizer = AutoTokenizer.from_pretrained(_tokenizer_name)

    cache[key] = (nlp, tokenizer)

# retrieve cached objects
nlp, tokenizer = cache[key]

# --- Determine prefix token‐cost and adjust budget ---
prefix = _document_prefix or ''
prefix_ids = tokenizer.encode(prefix, add_special_tokens=False)
prefix_len = len(prefix_ids)

max_content_tokens = _max_tokens - prefix_len
if max_content_tokens <= 0:
    plpy.error(f"DOCUMENT_PREFIX '{prefix}' exceeds token budget {_max_tokens}")

# --- Pre-tokenize sentences ---
doc = nlp(_body)
sentence_tokens = [
    (sent.text.strip(),
     tokenizer.encode(sent.text.strip(), add_special_tokens=False))
    for sent in doc.sents
    if sent.text.strip()
]

chunks = []
prev_sentences = []
i = 0
new_budget = int(max_content_tokens * _min_new_ratio)

# --- Main loop: build each chunk ---
while i < len(sentence_tokens):
    chunk = []         # List of (text, tokens)
    chunk_tokens = 0

    # Phase 1: new content up to new_budget
    new_tokens = 0
    while i < len(sentence_tokens):
        text, tokens = sentence_tokens[i]
        tlen = len(tokens)

        # Special: first sentence if it alone exceeds new_budget
        if not chunk and new_tokens == 0 and tlen > new_budget:
            if tlen <= max_content_tokens:
                chunk.append((text, tokens))
                chunk_tokens += tlen
                new_tokens += tlen
                i += 1
            elif _truncate_long_sentences:
                trunc = tokens[:max_content_tokens]
                chunk.append((tokenizer.decode(trunc), trunc))
                chunk_tokens += len(trunc)
                new_tokens += len(trunc)
                i += 1
            else:
                i += 1
            break

        if new_tokens + tlen > new_budget:
            break

        chunk.append((text, tokens))
        new_tokens += tlen
        chunk_tokens += tlen
        i += 1

    # Phase 2: prepend overlap from previous chunk
    for prev_text, prev_tokens in reversed(prev_sentences):
        ptlen = len(prev_tokens)
        if chunk_tokens + ptlen <= max_content_tokens:
            chunk.insert(0, (prev_text, prev_tokens))
            chunk_tokens += ptlen
        else:
            break

    # Phase 3: back-fill with any remaining new sentences
    while i < len(sentence_tokens):
        text, tokens = sentence_tokens[i]
        tlen = len(tokens)
        if chunk_tokens + tlen > max_content_tokens:
            break
        chunk.append((text, tokens))
        chunk_tokens += tlen
        i += 1

    # finalize this chunk
    chunks.append(" ".join([s for s, _ in chunk]))
    prev_sentences = chunk

# Apply chunk limit if specified
if _max_chunks is not None:
    chunks = chunks[:_max_chunks]

return [ prefix + c for c in chunks ]
$$;

/* ======================================================================
   post_clean_content
   ===================================================================== */
CREATE OR REPLACE FUNCTION post_clean_content(_text_input TEXT)
RETURNS TEXT
LANGUAGE plpython3u
IMMUTABLE
AS $$
import re, html, plpy
from bs4 import BeautifulSoup

if 'post_clean_patterns' not in globals():
    globals()['post_clean_patterns'] = {
        # images & bare URLs
        "remove_markdown": re.compile(r'(!\[.*?\]\(.*?\)|https?://\S+)', re.IGNORECASE), # remove markdown images and bare http links

        # [title](url) ⇒ title
        "remove_markdown_links": re.compile(r'\[([^\]]+)\]\([^\)]+\)|!\[\]\([^)]*\)|!\S+\.(jpg|jpeg|png|gif)', re.IGNORECASE),

        "remove_unwanted": re.compile(r'Posted via.*$|[*_]+', re.MULTILINE),

        "remove_base64" : re.compile(r'data:image\/[a-zA-Z]+;base64,[A-Za-z0-9+/=]+'),

        # C0 control characters (except \t \n \r) and DEL: pure noise for the
        # embedding model, and raw separators like \x1c crash pySBD's
        # numbered-list parser (int('\x1c2') ValueError, seen at block ~8.9M)
        "remove_control_chars": re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'),
    }

patterns = globals()['post_clean_patterns']

def clean(text: str) -> str:
    # 0) Drop control characters before anything else parses the text
    text = patterns["remove_control_chars"].sub('', text)

    # 1) Unescape HTML entities like &nbsp;
    text = html.unescape(text)

    # 2) Parse and strip unwanted tags
    soup = BeautifulSoup(text, 'lxml')
    for tag in soup(['script', 'style', 'img', 'table']):
        tag.decompose()

    # 4) Extract the remaining text and collapse whitespace
    extracted = soup.get_text(separator=' ')

    extracted = patterns["remove_markdown_links"].sub(r'\1', extracted)
    extracted = patterns["remove_markdown"].sub('', extracted)
    extracted = patterns["remove_base64"].sub('', extracted)
    return patterns["remove_unwanted"].sub('', extracted)

return clean(_text_input)
$$;

GRANT EXECUTE ON FUNCTION post_clean_content(TEXT) TO hivesense_user;
GRANT EXECUTE ON FUNCTION post_clean_content(TEXT) TO pg_database_owner     WITH GRANT OPTION;

-- This composite will let us return both (TEXT[] chunks, INT token_count).
DROP TYPE IF EXISTS hivesense_app.post_preprocess_result CASCADE;
CREATE TYPE hivesense_app.post_preprocess_result AS (
    chunks          TEXT[],   -- the array of chunk‐strings, exactly as before
    token_count     INT       -- total number of tokens in the original post
);

CREATE OR REPLACE FUNCTION chunk_post(
    _body TEXT,
    _post_id INTEGER,
    _permlink TEXT,
    _tokenizer_name TEXT DEFAULT 'e5-base',
    _max_tokens     INTEGER      DEFAULT 512,
    _min_new_ratio  DOUBLE PRECISION DEFAULT 0.85,
    _max_chunks     INTEGER      DEFAULT NULL,
    _truncate_long_sentences BOOLEAN DEFAULT TRUE,
    _document_prefix TEXT        DEFAULT 'passage: ',
    _min_token_threshold INT     DEFAULT 75        -- reject very short posts
)
RETURNS hivesense_app.post_preprocess_result
LANGUAGE plpython3u
IMMUTABLE
AS $$
import re, plpy
import pysbd
from pathlib import Path

# ---------------------------------------------------------
# 1.  Cache tokenizer, regexes, and fixed overhead
# ---------------------------------------------------------
if 'chunk_post_cache' not in globals():
    globals()['chunk_post_cache'] = {}

key = (_tokenizer_name, _document_prefix)
cache = globals()['chunk_post_cache']

if key not in cache:
    from tokenizers import Tokenizer

    root = Path("/home/hived/tokenizer-files") / _tokenizer_name          # <-- mount or COPY here
    if (root / "tokenizer.json").exists():               # JSON-BPE (GPT/Qwen/etc.)
        tokenizer = Tokenizer.from_file(str(root / "tokenizer.json"))
    else:
        plpy.error(f"No tokenizer.json found, please place (or bind-mount) the appropriate file in {str(root)}") 

    prefix_ids = tokenizer.encode(_document_prefix or '', add_special_tokens=False)
    specials   = tokenizer.num_special_tokens_to_add(is_pair=False)  # typically 2

    patterns = {
        "normalize_whitespace": re.compile(r'\s+'),

        "cjk_sentence_end": re.compile(r'(?<=[。？！…\.?!])\s*|\r?\n+'),

        # Last-resort sentence terminators across scripts, used when the
        # primary splitter finds no boundary in an oversized "sentence":
        # ASCII/ellipsis need a following space (protects decimals and
        # abbreviations); script-specific marks don't collide with numbers so
        # they split with or without one: Devanagari/Bengali danda and double
        # danda, Urdu full stop, Arabic question mark, Armenian full stop,
        # Ethiopic full stop, Myanmar section mark, Khmer khan.
        "universal_sentence_end": re.compile(r'(?<=[。？！।॥۔؟։።။។])\s*|(?<=[\.?!…])\s+|\r?\n+'),

        # any Hiragana (U+3040–U+309F) or Katakana (U+30A0–U+30FF) code‐point
        "ja_characters": re.compile(r"[\u3040-\u309F\u30A0-\u30FF]"),
        # basic CJK Unified Ideographs (U+4E00–U+9FFF)
        "zh_characters": re.compile(r"[\u4E00-\u9FFF]"),
        # Hangul Syllables (U+AC00–U+D7AF)
        "ko_characters": re.compile(r"[\uAC00-\uD7AF]"),
        # detect when to apply workaround for PySBD bug
        "catastrophic_backtracking_trigger": re.compile(r"\[[^\]]*\d{5,}[^\]]*\]")
    }

    cache[key] = {
        'tok'           : tokenizer,
        'prefix_ids'    : prefix_ids,
        'prefix_len'    : len(prefix_ids),
        'specials'      : specials,
        'fixed_overhead': len(prefix_ids) + specials,
        'patterns'      : patterns
    }

tok        = cache[key]['tok']
prefix_len = cache[key]['prefix_len']
fixed_over = cache[key]['fixed_overhead']
prefix     = _document_prefix or ''
patterns   = cache[key]['patterns']

# ---------------------------------------------------------
# 2.  Helper functions for splitting text on sentences
# ---------------------------------------------------------
def split_cjk(text: str) -> list[str]:
    # splits out the punctuation
    parts = re.split(patterns["cjk_sentence_end"], text)
    # filter out any empty strings
    return [p for p in parts if p]

# stupid language guesser for now.  we should likely use langdetect or lid if "assume english works for most western languages" is wrong
def guess_language(text: str) -> str:
    if patterns["ko_characters"].search(text):
        return 'ko'
    if patterns["ja_characters"].search(text):
        return 'ja'
    if patterns["zh_characters"].search(text):
        return'zh'
    return 'en'

def split_sentences(text: str, assumed_language: str) -> list[str]:
    if assumed_language == 'ko':
        # sbd doesn't have Korean language support, so fall back to a simple
        # regex that splits on either .!?, their CJK equivalents, or newlines.
        # that's better than nothing, maybe we can find something smarter later
        return split_cjk(text)

    # cache one Segmenter per language
    if 'sentence_splitters' not in globals():
        globals()['sentence_splitters'] = {}
    cache = globals()['sentence_splitters']

    sbd_cache_key = f'sbd_{assumed_language}'
    if sbd_cache_key not in cache:
        cache[sbd_cache_key] = pysbd.Segmenter(language=assumed_language, clean=False)
    sbd = cache[sbd_cache_key]

    if patterns["catastrophic_backtracking_trigger"].search(text):
        GD['hivesense_regex_fallbacks'] = GD.get('hivesense_regex_fallbacks', 0) + 1
        plpy.debug(f"Detected possible PySBD catastrophic backtracking situation, using simple regex splitter for this post")
        # Detected something like "[111 111 111]"
        # This can trigger the PySBD bug: https://github.com/nipunsadvilkar/pySBD/issues/79
        # do a simple split instead
        return patterns["universal_sentence_end"].split(text)
    else:
        try:
            return sbd.segment(text)
        except Exception as e:
            # pySBD has more parsing bugs than the backtracking one above
            # (e.g. int() on stray digits in its list detection). One bad post
            # must not kill a multi-day generation run: fall back to the same
            # simple splitter and keep going.
            GD['hivesense_regex_fallbacks'] = GD.get('hivesense_regex_fallbacks', 0) + 1
            plpy.warning(f"pySBD failed on this post ({e!r}); using simple regex splitter")
            return patterns["universal_sentence_end"].split(text)

def normalize_whitespace(text: str) -> str:
    return patterns["normalize_whitespace"].sub(' ', text).strip()

def split_sentences_to_token_count(text: str,
                                   target_max_length: int,
                                   tok) -> list[tuple[str,list[int]]]:
    language = guess_language(text)
    raw_sents = split_sentences(text, language)

    # normalize and drop any empties
    cleaned = [normalize_whitespace(s) for s in raw_sents if s.strip()]

    output = []
    for s in cleaned:
        token_ids = tok.encode(s, add_special_tokens=False).ids
        if len(token_ids) <= target_max_length:
            output.append((s, token_ids))
            continue

        # --- oversized chunk!
        # SBD will refuse to split multi-sentence quotes and parentheticals.
        # try to unwrap quotes/parens and re-split
        unwrapped = False
        for open_ch, close_ch in [('"', '"'), ('“', '”'), ("'", "'"), ('(', ')'), ('[', ']')]:
            if s.startswith(open_ch) and s.endswith(close_ch):
                inner = s[len(open_ch):-len(close_ch)]
                # re-split the inner text
                for sub in split_sentences(inner, language):
                    sub_clean = normalize_whitespace(sub)
                    if not sub_clean:
                        continue
                    sub_tokens = tok.encode(sub_clean, add_special_tokens=False).ids
                    output.append((sub_clean, sub_tokens))
                unwrapped = True
                break

        if unwrapped:
            continue

        # --- fallback: brute-force split on sentence terminators from any
        # script (pySBD only handles 22 languages; Bengali/Hindi/Urdu prose
        # and similar used to arrive here as one giant "sentence" and get
        # hard-truncated despite ending every sentence with a danda)
        parts = patterns["universal_sentence_end"].split(s)
        if len(parts) > 1:
            for sub in parts:
                sub_clean = normalize_whitespace(sub)
                if not sub_clean:
                    continue
                sub_tokens = tok.encode(sub_clean, add_special_tokens=False).ids
                # if still too big, we could recurse—but this should catch most
                output.append((sub_clean, sub_tokens))
        else:
            # give up and accept the giant sentence
            output.append((s, token_ids))

    return output
# ---------------------------------------------------------
# 3.  Work out the *content* budget once
# ---------------------------------------------------------
max_content_tokens = _max_tokens - fixed_over
if max_content_tokens <= 0:
    plpy.error(f"DOCUMENT_PREFIX '{prefix}' exceeds token budget {_max_tokens}")

# ---------------------------------------------------------
# 4.  Split to sentences, pre-tokenising every sentence
# ---------------------------------------------------------
sentence_tokens = split_sentences_to_token_count(_body, max_content_tokens, tok)

# here is our total token count for the entire (cleaned) post:
__token_count = sum(len(ids) for _txt, ids in sentence_tokens)

if __token_count < _min_token_threshold:
    # returns NULL if the post is “too short”
    return None

# ---------------------------------------------------------
# 5.  Chunk loop
# ---------------------------------------------------------
chunks          = []
prev_sentences  = []           # context for overlap
i               = 0            # cursor into sentence_tokens

while i < len(sentence_tokens):
    chunk          = []        # sentences in display order
    added_stack    = []        # sentences in *addition* order
    chunk_tokens   = 0
    new_tokens     = 0
    new_budget     = int(max_content_tokens * _min_new_ratio)

    # ---- Phase 1:  fresh content up to new_budget ----
    while i < len(sentence_tokens):
        txt, ids = sentence_tokens[i]
        tlen     = len(ids)

        # special case: very long first sentence
        if not chunk and tlen > new_budget:
            if tlen <= max_content_tokens:
                # accept whole
                chunk.extend([(txt, ids)])
                added_stack.append({'txt': txt, 'ids': ids, 'src': 'new'})
                new_tokens   += tlen
                chunk_tokens += tlen
                i += 1
            elif _truncate_long_sentences:
                # Count every truncation for the caller's per-range telemetry
                # (hivesense_app.pop_truncation_count); the per-post detail is
                # DEBUG - enough of an excerpt to judge whether a reasonable
                # splitter had a split point (prose in a script we don't
                # split, e.g. Bengali danda) or the text is anomalous (base64
                # blobs, giant lists).
                GD['hivesense_truncated_chunks'] = GD.get('hivesense_truncated_chunks', 0) + 1
                warning_threshold = 800
                if tlen > warning_threshold:
                    plpy.debug(f'Post ID: {_post_id}     Link: {_permlink}')
                    plpy.debug(f'Truncating long sentence of {tlen} tokens to {max_content_tokens}')
                    plpy.debug(f'Sentence is ({len(txt)} chars): {txt[:300]}{"..." if len(txt) > 300 else ""}')
                trunc_ids = ids[:max_content_tokens]
                trunc_txt = tok.decode(trunc_ids)
                chunk.extend([(trunc_txt, trunc_ids)])
                added_stack.append({'txt': trunc_txt,
                                    'ids': trunc_ids,
                                    'src': 'new'})
                new_tokens   += len(trunc_ids)
                chunk_tokens += len(trunc_ids)
                i += 1
            break

        if new_tokens + tlen > new_budget:
            break

        chunk.extend([(txt, ids)])
        added_stack.append({'txt': txt, 'ids': ids, 'src': 'new'})
        new_tokens   += tlen
        chunk_tokens += tlen
        i += 1

    # ---- Phase 2:  prepend overlap from previous chunk ----
    for ptxt, pids in reversed(prev_sentences):
        plen = len(pids)
        if chunk_tokens + plen <= max_content_tokens:
            chunk.insert(0, (ptxt, pids))
            added_stack.append({'txt': ptxt, 'ids': pids, 'src': 'prev'})
            chunk_tokens += plen
        else:
            break

    # ---- Phase 3:  back-fill with more new sentences ----
    while i < len(sentence_tokens):
        txt, ids = sentence_tokens[i]
        tlen     = len(ids)
        if chunk_tokens + tlen > max_content_tokens:
            break
        chunk.extend([(txt, ids)])
        added_stack.append({'txt': txt, 'ids': ids, 'src': 'new'})
        chunk_tokens += tlen
        i += 1

    # ---- Phase 4:  verify & trim until the real encode fits ----
    def encode_len(txt: str) -> int:
        return len(tok.encode(txt, add_special_tokens=True).ids)

    full_txt = prefix + " ".join(t for t, _ in chunk)

    while encode_len(full_txt) > _max_tokens:
        if not added_stack:
            plpy.error("Internal error: no sentence left to pop but still long")

        last = added_stack.pop()          # most-recently-added
        chunk.remove((last['txt'], last['ids']))

        if len(chunk) == 0:
            # last['ids'] is the ONLY remaining content; chop it token-by-token
            ids = last['ids'][:]
            while ids and encode_len(prefix + tok.decode(ids)) > _max_tokens:
                ids.pop()                 # drop ONE token-id
            if not ids:
                plpy.error("Even one token would overflow; aborting.")
            # rebuild chunk with the shrunken sentence
            shrunk_txt = tok.decode(ids)
            chunk.append((shrunk_txt, ids))
            # push a synthetic entry so we could shrink further if still needed
            added_stack.append({'txt': shrunk_txt, 'ids': ids, 'src': 'new'})
        else:
            # if the popped item came from fresh content we must re-process it
            if last['src'] == 'new':
                i -= 1                    # rewind so the next chunk sees it

        full_txt = prefix + " ".join(t for t, _ in chunk)

    chunks.append(full_txt)

    # build the context list for the next loop
    prev_sentences = chunk

    if _max_chunks is not None and len(chunks) >= _max_chunks:
        break

# plpy.notice(f"chunked post {_post_id} with token count {__token_count}")
return (chunks, __token_count)
$$;
GRANT EXECUTE ON FUNCTION chunk_post(TEXT, INT, TEXT, TEXT, INTEGER, DOUBLE PRECISION, INTEGER, BOOLEAN, TEXT, INT) TO hivesense_user;
GRANT EXECUTE ON FUNCTION chunk_post(TEXT, INT, TEXT, TEXT, INTEGER, DOUBLE PRECISION, INTEGER, BOOLEAN, TEXT, INT) TO pg_database_owner      WITH GRANT OPTION;


/* ======================================================================
   3.  preprocess_post – calls new chunk_post
   ===================================================================== */
CREATE OR REPLACE FUNCTION preprocess_post(
    _post_body  TEXT,
    _post_id INTEGER,
    _permlink TEXT,
    _tokenizer_name TEXT DEFAULT 'e5-base',
    _max_tokens     INTEGER      DEFAULT 512,
    _min_new_ratio  DOUBLE PRECISION DEFAULT 0.85,
    _max_chunks     INTEGER      DEFAULT NULL,
    _truncate_long_sentences BOOLEAN DEFAULT TRUE,
    _document_prefix TEXT        DEFAULT 'passage: ',
    _min_token_threshold INT     DEFAULT 75
)
RETURNS hivesense_app.post_preprocess_result -- NULL ➜ post rejected
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    __cleaned TEXT;
    __result  hivesense_app.post_preprocess_result;
BEGIN
    __cleaned := hivesense_app.post_clean_content(_post_body);
    IF __cleaned IS NULL OR length(__cleaned)=0 THEN
        RETURN NULL;
    END IF;

    SELECT *
      INTO __result
    FROM hivesense_app.chunk_post(
        __cleaned,
        _post_id,
        _permlink,
        _tokenizer_name,
        _max_tokens,
        _min_new_ratio,
        _max_chunks,
        _truncate_long_sentences,
        _document_prefix,
        _min_token_threshold
    );


    -- If the post was too short or filtered out, chunk_post returns NULL
    IF __result IS NULL THEN
        RETURN NULL;
    END IF;

    -- 3) Return the composite (chunks, token_count) unchanged
    RETURN __result;
END;
$$;

GRANT EXECUTE ON FUNCTION preprocess_post(TEXT, INT, TEXT, TEXT, INTEGER, DOUBLE PRECISION, INTEGER, BOOLEAN, TEXT, INT) TO hivesense_user;
GRANT EXECUTE ON FUNCTION preprocess_post(TEXT, INT, TEXT, TEXT, INTEGER, DOUBLE PRECISION, INTEGER, BOOLEAN, TEXT, INT) TO pg_database_owner  WITH GRANT OPTION;


-- Chunker telemetry: chunk_post counts in the session's PL/Python GD the
-- sentences it had to hard-truncate (no split point found) and the posts it
-- split with the simple regex instead of pySBD (backtracking guard). The
-- block processor pops the counters once per range and reports them next to
-- the chunk totals, so split-failure rates stay visible without the per-post
-- log noise (that detail is now DEBUG, with the echoed text capped).
CREATE OR REPLACE FUNCTION pop_chunker_counters()
RETURNS TABLE(truncated INT, regex_fallback INT)
LANGUAGE plpython3u
VOLATILE
AS $$
return [(GD.pop('hivesense_truncated_chunks', 0), GD.pop('hivesense_regex_fallbacks', 0))]
$$;

GRANT EXECUTE ON FUNCTION pop_chunker_counters() TO hivesense_user;

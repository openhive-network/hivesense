SET ROLE hivesense_owner;

CREATE OR REPLACE FUNCTION clean_content(_text_input TEXT)
    RETURNS TEXT
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
DECLARE
    __cleaned_text TEXT;
BEGIN

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
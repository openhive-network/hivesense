# The embedding server of the AIDEV test stack (.aidev/test-stack.compose.yml): CI's
# hivesense/ollama image (docker/ci/compose.yml `hivesense-ollama`) with CI's model,
# all-minilm:l6-v2 (384 dims), pulled at build time so the stack needs no network,
# and that model's tokenizer.json, which hivesense's chunker reads from
# /home/hived/tokenizer-files/all-MiniLM-L6-v2 inside the HAF container (the stack
# copies it there through a volume). Also CI's slice-mode model,
# hf.co/mixedbread-ai/mxbai-embed-xsmall-v1:F16 (Matryoshka-trained, 384 dims, MiniLM
# tokenizer, so the same tokenizer.json serves both). Build and pin with
# .aidev/runtime/build.sh.
FROM registry.gitlab.syncad.com/hive/hivesense/ollama@sha256:836da41ca3ebf1b0500fbc4b49a0d12a9dc22946c88ce8ede925137b8ac1da90

ENV OLLAMA_MODELS=/models OLLAMA_HOST=0.0.0.0:11434 OLLAMA_NUM_GPU=0 OLLAMA_KEEP_ALIVE=-1

# sentence-transformers/all-MiniLM-L6-v2 at commit 1110a243.
ADD --chmod=644 --checksum=sha256:be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037 \
    https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/1110a243fdf4706b3f48f1d95db1a4f5529b4d41/tokenizer.json \
    /tokenizer-files/all-MiniLM-L6-v2/tokenizer.json

RUN chmod 0755 /tokenizer-files /tokenizer-files/all-MiniLM-L6-v2; \
    ollama serve & pid=$!; \
    for i in $(seq 60); do ollama list >/dev/null 2>&1 && break; sleep 1; done; \
    ollama pull all-minilm:l6-v2 \
    && ollama pull hf.co/mixedbread-ai/mxbai-embed-xsmall-v1:F16 && ollama list; \
    kill $pid; wait $pid || true

ENTRYPOINT ["/usr/local/bin/ollama"]
CMD ["serve"]

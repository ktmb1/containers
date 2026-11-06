# NeMo Guardrails as an OpenAI-compatible proxy that masks personal data with
# Presidio before a request leaves the house.
#
# It sits between a caller inside the cluster (Heym) and the envoy-ai gateway,
# for models whose provider may log or train on prompts - the free OpenRouter
# tier. Everything is masked: the system prompt, every earlier turn, tool
# results and tool-call arguments, not just the latest user message the
# built-in NeMo rail covers. See rails/scrub/ for how and why, and verify.sh
# for the proof.
#
# Nobody publishes a NeMo Guardrails server image to pin, so this builds one.
# It runs on CPU: Presidio's NER is a spaCy pipeline, not an LLM, and needs no
# accelerator.
#
# 3.13, not 3.14+: nemoguardrails 0.24.1 declares python <3.14.
FROM python:3.13-slim-trixie@sha256:09a17cad02668ae61ece136b4fd36ac3849e14f670ebedb637ea3e15580525bc

# The full transitive lock, with hashes - see requirements.in for the direct
# pins and why NeMo is held at 0.24.1.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --require-hashes --only-binary=:all: -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

COPY scrubber.py serve.py /app/
COPY rails /app/rails

# Fail the build, not the first request, if the sources do not compile or the
# spaCy pipeline cannot be loaded by this spaCy.
RUN python3 -m compileall -q /app \
    && python3 -c "import spacy; spacy.load('en_core_web_lg')"

# HOME under /tmp: NeMo, fastembed and Hugging Face libraries all look for a
# cache directory under it, and /tmp is the one writable path under
# readOnlyRootFilesystem. verify.sh runs the image with no route out, so a
# runtime download would fail there rather than in the cluster.
#
# TLDEXTRACT_PUBLIC_SUFFIX_LIST_URLS empty: Presidio's email and URL
# recognizers use tldextract, which fetches the Public Suffix List from GitHub
# on first use. With no route out that cost a traceback and a DNS timeout on
# the first request, then fell back to the snapshot bundled with tldextract -
# so use the snapshot outright. It moves with the tldextract pin in the lock.
ENV TLDEXTRACT_PUBLIC_SUFFIX_LIST_URLS="" \
    PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/tmp \
    PORT=8000

WORKDIR /app

# An arbitrary non-root uid, matching the distroless "nonroot" convention.
USER 65532:65532

EXPOSE 8000

# serve.py self-checks the masking and execs the NeMo server; it never wraps
# it, so the server is PID 1 and Kubernetes sees its crashes.
ENTRYPOINT ["python3", "/app/serve.py"]

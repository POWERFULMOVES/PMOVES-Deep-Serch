# PMOVES Deep Serch — Streamlit image for the WebWalker UI.
#
# WHY THIS FILE EXISTS
# The fork ships no Dockerfile at all. Its only runnable entry point is the Streamlit
# app in WebWalker/src/app.py, and the PMOVES integration sheet already fixes the
# service's identity and port:
#     PMOVES.AI_INTEGRATION.md
#       - **Name:** PMOVES Deep Serch
#       - **Slug:** deep-serch
#       - **Tier:** api
#       - **Port:** 8098
#       - **Health Check:** http://localhost:8098/healthz
# so this image listens on 8098 and is named for the deep-serch service.
#
# EVIDENCE FOR EVERY NON-OBVIOUS CHOICE (all measured in this repo at the pinned commit)
#
# 1. WORKDIR /app/WebWalker/src — the app's own imports are SIBLING imports.
#        WebWalker/src/app.py:4    from agent import WebWalker
#        WebWalker/src/app.py:10   from utils import *
#        WebWalker/src/agent.py:12 from prompts import *
#    None of those are packages; they resolve only when the process CWD is the
#    directory holding app.py / agent.py / utils.py / prompts.py. The repo really does
#    ship "prompts.py" (plural) — there is no "prompt.py".
#
# 2. The app refuses to start without an LLM key.
#        WebWalker/src/app.py:17  if 'DASHSCOPE_API_KEY' not in os.environ and \
#                                    'OPENAI_API_KEY' not in os.environ:
#        WebWalker/src/app.py:18      raise ValueError("Please set the environment variable
#                                            'DASHSCOPE_API_KEY' or 'OPENAI_API_KEY' ...")
#    So the key is injected at RUNTIME via the environment; nothing is baked into the
#    image. The DASHSCOPE branch (app.py:19-30) is self-contained (model_server is
#    hardcoded to the DashScope compatible-mode endpoint); the OPENAI branch
#    (app.py:31) additionally requires OPENAI_MODEL_SERVER, which is why the image
#    documents DASHSCOPE_API_KEY as the single-variable option.
#
# 3. streamlit is installed explicitly because WebWalker/requirements.txt omits it,
#    while app.py:1 is `import streamlit as st`:
#        WebWalker/requirements.txt -> crawl4ai, requests, json5, pillow, beautifulsoup4,
#                                     qwen-agent, datasets, tenacity, volcengine-python-sdk,
#                                     langchain, langchain-community, langchain-core
#    Only WebWalker/requirements.txt is installed: WebDancer/requirements.txt and
#    WebSailor/requirements.txt are the WebDancer/WebSailor research harnesses (they ask
#    for sglang[all] and the full qwen-agent GUI stack) and are not imported by this app.
#    WebWalker/src/rag_system.py does import volcenginesdkarkruntime + datasets, but
#    app.py never imports rag_system — and both packages are already covered by
#    WebWalker/requirements.txt (volcengine-python-sdk provides volcenginesdkarkruntime).
#
# 3b. soundfile is installed explicitly because WebWalker/requirements.txt asks for a
#    bare `qwen-agent`, and qwen-agent's own import chain needs it:
#        WebWalker/src/app.py:4            from agent import WebWalker
#        WebWalker/src/agent.py:4          from qwen_agent.agents.fncall_agent import FnCallAgent
#        qwen_agent/llm/base.py:29        from qwen_agent.utils.utils import (...)
#        qwen_agent/utils/utils.py:34      import soundfile as sf
#    Without it the whole app module fails to import:
#        ModuleNotFoundError: No module named 'soundfile'
#    (soundfile ships in qwen-agent's [gui] extra, which this repo does not request).
#    json5, numpy, requests, pydantic and PIL are all already satisfied by
#    WebWalker/requirements.txt; soundfile was the only missing one.
#
# 4. A chromium build is installed because the app's screenshot path needs one:
#        WebWalker/src/utils.py:45  run_config = CrawlerRunConfig(screenshot=True, ...)
#        WebWalker/src/utils.py:49  async with AsyncWebCrawler() as crawler:
#    crawl4ai drives playwright's chromium, and playwright does not download a browser
#    during pip install. Browsers land in PLAYWRIGHT_BROWSERS_PATH, which is set to a
#    world-readable path because the container runs as the unprivileged pmoves user.
#    CAVEAT (runtime, not build): chromium's sandbox needs privileges this image does
#    not grant, so the browser may refuse to launch as uid 65532 without --no-sandbox;
#    app.py does not expose crawl4ai's browser_config, so that would need a code change
#    in WebWalker/src/utils.py. The image itself builds and starts regardless.
#
# 5. Non-root uid/gid 65532 with HOME=/home/pmoves is required, not cosmetic:
#        WebWalker/src/app.py:164  with open("ROOT_URL.txt", "w") as f:
#        WebWalker/src/app.py:177  image_folder = "images/"
#    Both are relative to the process CWD, so the working directory must be writable by
#    the runtime user; and streamlit writes its ~/.streamlit config under HOME.
#    uid/gid 65532 is the PMOVES house convention, e.g.
#    pmoves/services/hi-rag-gateway-v2/Dockerfile:
#        RUN groupadd -r pmoves --gid=65532 && \
#            useradd -r -g pmoves --uid=65532 --home-dir=/app --shell=/sbin/nologin pmoves && \
#            chown -R pmoves:pmoves /app
#        USER pmoves:pmoves
#
# 6. HEALTHCHECK hits streamlit's own health endpoint, /_stcore/health, which returns
#    the literal body "ok" (measured: HTTP 200, body "ok").
#    The /healthz URL in PMOVES.AI_INTEGRATION.md is the PMOVES FastAPI convention, but this
#    service is a Streamlit process, not a FastAPI app — app.py never mounts
#    pmoves_health.health_check_router (the module is shipped in the repo but unused).
#    Measured: GET /healthz returns HTTP 200 with the Streamlit single-page-app HTML,
#    because streamlit's catch-all route serves the app shell for unknown paths. That
#    makes /healthz useless as a probe: it returns 200 even while the app script itself
#    is failing to import. /_stcore/health is the route that actually reflects the
#    server's state. curl is installed so the check needs no python startup cost.

FROM python:3.11-slim

# python:3.11-slim is the PMOVES house base for Python services (the majority of
# pmoves/services/*/Dockerfile files use python:3.11-slim), and 3.11 satisfies every
# wheel in WebWalker/requirements.txt.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    STREAMLIT_SERVER_HEADLESS=true \
    STREAMLIT_BROWSER_GATHER_USAGE_STATS=false

# build-essential: pip fallback if any dependency has to be built from source.
# curl: used by the HEALTHCHECK below.
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first so the layer is cached independently of the source copy.
COPY WebWalker/requirements.txt ./WebWalker/requirements.txt
RUN pip install --no-cache-dir -r ./WebWalker/requirements.txt && \
    pip install --no-cache-dir streamlit soundfile && \
    mkdir -p /ms-playwright

# Kept as a separate layer from the pip install above so a change to the Python
# dependencies does not re-download the browser.
RUN playwright install --with-deps chromium && \
    chmod -R a+rX /ms-playwright

# The Streamlit app and its sibling modules (see note 1).
COPY WebWalker/src/ /app/WebWalker/src/

# PMOVES integration modules shipped by this repo (PMOVES.AI_INTEGRATION.md lists
# pmoves_health/, pmoves_announcer/ and pmoves_registry/ as files created for the
# integration). All three import only the standard library, so they add no dependencies.
COPY pmoves_health/ /app/pmoves_health/
COPY pmoves_announcer/ /app/pmoves_announcer/
COPY pmoves_registry/ /app/pmoves_registry/

# Non-root runtime user (see note 5). /app/WebWalker/src is the writable CWD the app
# writes ROOT_URL.txt and images/ into (see note 5).
RUN groupadd -r pmoves --gid=65532 && \
    useradd -r -g pmoves --uid=65532 --home-dir=/home/pmoves --shell=/sbin/nologin pmoves && \
    mkdir -p /home/pmoves && \
    chown -R pmoves:pmoves /app /home/pmoves /ms-playwright && \
    chmod a+rX /ms-playwright

ENV HOME=/home/pmoves

WORKDIR /app/WebWalker/src

USER pmoves:pmoves

EXPOSE 8098

# Note 2: a key must be supplied at runtime. MEASURED behaviour with no key at all:
# app.py raises ValueError during the script run (app.py:17-18), so the Streamlit server
# still starts and serves the shell, but every page shows that import error. With only
# OPENAI_API_KEY set, app.py:31 also requires OPENAI_MODEL_SERVER, so llm_cfg is never
# assigned and the agent cannot run.
#   docker run -e DASHSCOPE_API_KEY=... -p 8098:8098 pmoves-deep-serch:test
#   docker run -e OPENAI_API_KEY=... -e OPENAI_MODEL_SERVER=... -p 8098:8098 ...
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:8098/_stcore/health || exit 1

CMD ["streamlit", "run", "app.py", \
     "--server.port=8098", \
     "--server.address=0.0.0.0", \
     "--server.headless=true", \
     "--browser.gatherUsageStats=false"]

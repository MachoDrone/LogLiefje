# LogLiefje AI — Nosana node log analysis container
# v0.04.1
#
# Based on ollama/ollama for full GPU support (CUDA 12/13, cuBLAS, etc.)
# with Python added on top for the analysis pipeline.
#
# Build:  docker build -t logliefje-ai:latest ./logliefje-ai/
# Run:    docker run --rm [--gpus all] \
#           -v ./mylog.txt:/input/mylogs.txt:ro \
#           -v logliefje-model-cache:/root/.ollama \
#           -e GITHUB_TOKEN=... \
#           logliefje-ai:latest

FROM ollama/ollama:latest

# Install Python 3 + system deps (git for keyword_sync, curl for API calls)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    curl \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy application code
WORKDIR /app
COPY analyze.py prompts.py keyword_sync.py report_formatter.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

# Mount points
# /input/mylogs.txt  — log file to analyze (read-only)
# /root/.ollama      — model cache (persists via Docker volume)
VOLUME ["/input", "/root/.ollama"]

# Version label (checked by LogLiefje-ai.sh for auto-rebuild)
LABEL logliefje.version="0.04.1"

# Environment
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/app/entrypoint.sh"]

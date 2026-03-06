# LogLiefje AI — Nosana node log analysis container
# v0.03.8
#
# Multi-stage build: copies ollama binary + GPU/CPU runner libraries from
# the official image. GPU access provided at runtime via --gpus all.
#
# Build:  docker build -t logliefje-ai:latest ./logliefje-ai/
# Run:    docker run --rm [--gpus all] \
#           -v ./mylog.txt:/input/mylogs.txt:ro \
#           -v logliefje-model-cache:/root/.ollama \
#           -e GITHUB_TOKEN=... \
#           logliefje-ai:latest

# Stage 1: Extract ollama binary + runtime libs from official image
FROM ollama/ollama:latest AS ollama-src

# Stage 2: Minimal runtime
FROM python:3.11-slim

# Copy ollama binary and GPU/CPU runner libraries
COPY --from=ollama-src /bin/ollama /usr/local/bin/ollama
COPY --from=ollama-src /usr/lib/ollama /usr/lib/ollama

# System deps (git for keyword_sync, curl for API calls)
RUN apt-get update && apt-get install -y --no-install-recommends \
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
LABEL logliefje.version="0.03.8"

# Environment
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/app/entrypoint.sh"]

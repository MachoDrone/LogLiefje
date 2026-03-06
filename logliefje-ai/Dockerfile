# LogLiefje AI — Nosana node log analysis container
# v0.03.5
#
# Multi-stage build: copies only the ollama binary (~40MB) from the official
# image, skipping ~4.5GB of CUDA/ROCm/Vulkan libs. GPU access is provided
# at runtime via --gpus all and the NVIDIA Container Toolkit.
#
# Build:  docker build -t logliefje-ai:latest ./logliefje-ai/
# Run:    docker run --rm [--gpus all] \
#           -v ./mylog.txt:/input/mylogs.txt:ro \
#           -v logliefje-model-cache:/root/.ollama \
#           -e GITHUB_TOKEN=... \
#           logliefje-ai:latest

# Stage 1: Extract ollama binary from official image
FROM ollama/ollama:latest AS ollama-src

# Stage 2: Minimal runtime
FROM python:3.11-slim

# Copy only the ollama binary (skip CUDA/ROCm/Vulkan libs)
COPY --from=ollama-src /bin/ollama /usr/local/bin/ollama

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
LABEL logliefje.version="0.03.5"

# Environment
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/app/entrypoint.sh"]

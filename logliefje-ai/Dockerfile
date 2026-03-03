# LogLiefje AI — Nosana node log analysis container
# v0.02.0
#
# Build:  docker build -t logliefje-ai:latest ./logliefje-ai/
# Run:    docker run --rm [--gpus all] \
#           -v ./mylog.txt:/input/mylogs.txt:ro \
#           -v logliefje-model-cache:/root/.ollama \
#           -e GITHUB_TOKEN=... \
#           logliefje-ai:latest

FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    zstd \
    && rm -rf /var/lib/apt/lists/*

# Install ollama (binary only, ~100MB — model pulled at runtime)
RUN curl -fsSL https://ollama.com/install.sh | sh

# Copy application code
WORKDIR /app
COPY analyze.py prompts.py keyword_sync.py report_formatter.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

# Mount points
# /input/mylogs.txt  — log file to analyze (read-only)
# /root/.ollama      — model cache (persists via Docker volume)
VOLUME ["/input", "/root/.ollama"]

# Environment
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/app/entrypoint.sh"]

#!/bin/bash
# LogLiefje AI container entrypoint
# v0.04.0 — --no-ai for keyword-scan-only, --cpu for 3b LLM on CPU
set -e

echo "=== LogLiefje AI Container ===" >&2
echo "Input: /input/mylogs.txt" >&2

# Verify input exists
if [ ! -f /input/mylogs.txt ]; then
    echo "ERROR: /input/mylogs.txt not found" >&2
    echo "Usage: docker run --rm -v ./mylog.txt:/input/mylogs.txt:ro -v logliefje-model-cache:/root/.ollama logliefje-ai:latest" >&2
    exit 1
fi

# No-AI mode: skip ollama entirely — keyword-scan-only
if [ "${FORCE_NO_AI}" = "1" ]; then
    echo "No-AI mode — skipping model download (keyword-scan-only)" >&2
    cd /app
    exec python3 analyze.py
fi

# Start ollama for model caching
ollama serve &>/dev/null &
OLLAMA_PID=$!

echo "Waiting for ollama..." >&2
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:11434/api/tags 2>/dev/null | grep -q 200; then
        break
    fi
    sleep 1
done

# Select model based on mode
if [ "${FORCE_CPU}" = "1" ]; then
    MODEL="qwen2.5:3b"
    MODEL_SIZE="~1.9GB"
else
    MODEL="qwen2.5:7b"
    MODEL_SIZE="~4.5GB"
fi

# Check if model is already cached in the volume
if ollama list 2>/dev/null | grep -q "$MODEL"; then
    echo "Model $MODEL found in cache — skipping download" >&2
else
    echo "First run — downloading $MODEL ($MODEL_SIZE)..." >&2
    ollama pull "$MODEL" >&2
    echo "Model download complete" >&2
fi

# Kill temporary ollama — analyze.py starts its own with GPU/CPU detection
kill $OLLAMA_PID 2>/dev/null
wait $OLLAMA_PID 2>/dev/null || true
sleep 1

# Run analysis pipeline (analyze.py starts ollama with proper GPU/CPU mode)
cd /app
exec python3 analyze.py

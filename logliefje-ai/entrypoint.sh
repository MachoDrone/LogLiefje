#!/bin/bash
# LogLiefje AI container entrypoint
# v0.02.0 — runtime model pull, stdout report output
set -e

echo "=== LogLiefje AI Container ===" >&2
echo "Input: /input/mylogs.txt" >&2

# Verify input exists
if [ ! -f /input/mylogs.txt ]; then
    echo "ERROR: /input/mylogs.txt not found" >&2
    echo "Usage: docker run --rm -v ./mylog.txt:/input/mylogs.txt:ro -v logliefje-model-cache:/root/.ollama logliefje-ai:latest" >&2
    exit 1
fi

# Start ollama temporarily to check/pull model
ollama serve &>/dev/null &
OLLAMA_PID=$!

echo "Waiting for ollama..." >&2
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:11434/api/tags 2>/dev/null | grep -q 200; then
        break
    fi
    sleep 1
done

# Check if model is already cached in the volume
if ollama list 2>/dev/null | grep -q "qwen2.5:7b"; then
    echo "Model qwen2.5:7b found in cache — skipping download" >&2
else
    echo "First run — downloading qwen2.5:7b (~4.5GB)..." >&2
    ollama pull qwen2.5:7b >&2
    echo "Model download complete" >&2
fi

# Kill temporary ollama — analyze.py starts its own with GPU/CPU detection
kill $OLLAMA_PID 2>/dev/null
wait $OLLAMA_PID 2>/dev/null || true
sleep 1

# Run analysis pipeline (analyze.py starts ollama with proper GPU/CPU mode)
cd /app
exec python3 analyze.py

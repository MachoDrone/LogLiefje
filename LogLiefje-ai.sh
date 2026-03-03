#!/bin/bash
#--use: bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/LogLiefje/refs/heads/main/LogLiefje-ai.sh)
# --cache-buster: bash <(wget -qO- "https://raw.githubusercontent.com/MachoDrone/LogLiefje/main/LogLiefje-ai.sh?$(date +%s)")
# LogLiefje AI — one-command log collection + AI error analysis + upload
# v0.02.3

# ── Cleanup mode: remove cached image + model volume ─────────────────────
if [[ "$1" == "--cleanup" ]]; then
    echo "LogLiefje AI cleanup..."
    docker rmi logliefje-ai:latest 2>/dev/null && echo "  Removed image: logliefje-ai:latest" || echo "  Image not found (already clean)"
    docker volume rm logliefje-model-cache 2>/dev/null && echo "  Removed volume: logliefje-model-cache" || echo "  Volume not found (already clean)"
    echo "Cleanup done."
    exit 0
fi

# ── Dependency check: install jq if missing ──────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "Installing jq (required for JSON parsing)..."
  sudo apt-get update -qq && sudo apt-get install -y -qq jq 2>/dev/null
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but could not be installed. Please run: sudo apt-get install jq"
    exit 1
  fi
fi

IMAGE_NAME="logliefje-ai:latest"
GITHUB_BRANCH="${LOGLIEFJE_BRANCH:-main}"
GITHUB_RAW="https://raw.githubusercontent.com/MachoDrone/LogLiefje/refs/heads/${GITHUB_BRANCH}"
EXPIRATION="72h"
AI_REPORT=""
REPORT_MARKER="===LOGLIEFJE_REPORT_START==="
REPORT_END_MARKER="===LOGLIEFJE_REPORT_END==="

# ------------- ARGUMENT PARSING -------------
TEST_MODE=false
FORCE_CPU=false
NO_UPLOAD=false
for arg in "$@"; do
  case "$arg" in
    --test)      TEST_MODE=true ;;
    --cpu)       FORCE_CPU=true ;;
    --no-upload) NO_UPLOAD=true ;;
  esac
done

# ------------- CONFIG (DO NOT EDIT THESE) -------------
if [ "$TEST_MODE" = true ]; then
  CHANNEL_ID="C093HNDQ422"   #test
  echo "** TEST MODE — posting to test channel **"
else
  CHANNEL_ID="C09AX202QD7"   #production
fi
USER_ID="U08NWH5GG8O"

# ------------- DISCORD NAME PROMPT (early, before collection) -------------
CONFIG_FILE="$HOME/.logliefje_name"
SAVED_NAME=""
if [[ -f "$CONFIG_FILE" ]]; then
    SAVED_NAME=$(<"$CONFIG_FILE")
fi

if [[ -n "$SAVED_NAME" ]]; then
    printf "\033[1;34mEnter Discord Name for support reference [%s]: \033[0m" "$SAVED_NAME"
else
    printf "\033[1;34mEnter Discord Name for support reference: \033[0m"
fi
read -r DISCORD_NAME

if [[ -z "$DISCORD_NAME" && -n "$SAVED_NAME" ]]; then
    DISCORD_NAME="$SAVED_NAME"
elif [[ -z "$DISCORD_NAME" ]]; then
    echo "Error: Discord name is required!"
    exit 1
fi
echo "$DISCORD_NAME" > "$CONFIG_FILE"

SAFE_NAME=$(echo "$DISCORD_NAME" | tr -cd 'a-zA-Z0-9._-')
UTC_TS=$(date -u +%Y%m%d_%H%M%SZ)
SLACK_FILENAME="${SAFE_NAME}_${UTC_TS}.txt"
AI_FILENAME="${SAFE_NAME}_${UTC_TS}_ai-report.txt"

# ================================================
# === STEP 1: COLLECT LOGS (via LogLiefje.sh) =====
# ================================================
echo "Collecting logs via LogLiefje.sh..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/LogLiefje.sh" ]]; then
    bash "${SCRIPT_DIR}/LogLiefje.sh" --no-upload
else
    bash <(wget -qO- "${GITHUB_RAW}/LogLiefje.sh") --no-upload
fi

if [[ ! -f "mylog.txt" || ! -s "mylog.txt" ]]; then
    echo "Error: Log collection failed — mylog.txt not found."
    exit 1
fi
echo "Log collection complete."

# ================================================
# === STEP 2: AI ERROR ANALYSIS ==================
# ================================================
if ! command -v docker &>/dev/null; then
    echo "Docker not available — skipping AI analysis."
else
    # ── Build image if it doesn't exist ──────────────────────────────────
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "First run — building AI image (~500MB, no model baked in)..."

        # Use local logliefje-ai/ directory if available, otherwise download
        if [[ -d "${SCRIPT_DIR}/logliefje-ai" && -f "${SCRIPT_DIR}/logliefje-ai/Dockerfile" ]]; then
            echo "  Using local logliefje-ai/ directory..."
            BUILD_DIR="${SCRIPT_DIR}/logliefje-ai"
        else
            BUILD_DIR=$(mktemp -d)
            trap 'rm -rf "$BUILD_DIR"' EXIT
            for f in Dockerfile analyze.py prompts.py keyword_sync.py report_formatter.py entrypoint.sh; do
                printf "  Downloading %s... " "$f"
                if wget -qO "$BUILD_DIR/$f" "${GITHUB_RAW}/logliefje-ai/$f"; then
                    echo "OK"
                else
                    echo "FAILED"
                    echo "Warning: Could not download $f — skipping AI analysis."
                    BUILD_DIR=""
                    break
                fi
            done
        fi

        if [[ -n "$BUILD_DIR" ]]; then
            chmod +x "$BUILD_DIR/entrypoint.sh" 2>/dev/null
            echo "  Building Docker image..."
            if docker build -t "$IMAGE_NAME" "$BUILD_DIR"; then
                echo "Build complete."
            else
                echo "Warning: Docker build failed — skipping AI analysis."
            fi
        fi
    fi

    # ── Run AI container (stdout = report, stderr = diagnostics) ─────────
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        GPU_FLAG=""
        FORCE_CPU_ENV=""
        if [ "$FORCE_CPU" = true ]; then
            echo "Running AI analysis (CPU mode — forced via --cpu)..."
            FORCE_CPU_ENV="-e FORCE_CPU=1"
        elif nvidia-smi &>/dev/null 2>&1; then
            GPU_FLAG="--gpus all"
            echo "Running AI analysis (GPU detected — VRAM check inside container)..."
        else
            echo "Running AI analysis (CPU mode)..."
        fi

        # Capture stdout only (has report markers); stderr goes to terminal
        DOCKER_STDOUT=$(timeout 600 docker run --rm $GPU_FLAG $FORCE_CPU_ENV \
            -v "$(pwd)/mylog.txt:/input/mylogs.txt:ro" \
            -v logliefje-model-cache:/root/.ollama \
            ${GITHUB_TOKEN:+-e GITHUB_TOKEN="$GITHUB_TOKEN"} \
            "$IMAGE_NAME")
        DOCKER_EXIT=$?

        if [[ $DOCKER_EXIT -eq 0 ]]; then
            # Extract report between markers (stdout only, no stderr noise)
            AI_REPORT=$(printf '%s\n' "$DOCKER_STDOUT" | sed -n "/${REPORT_MARKER}/,/${REPORT_END_MARKER}/p" | grep -v "$REPORT_MARKER" | grep -v "$REPORT_END_MARKER")
            if [[ -n "$AI_REPORT" ]]; then
                echo "AI analysis complete."
            else
                echo "AI analysis completed but no report extracted."
            fi
        else
            echo "AI analysis failed or timed out (exit $DOCKER_EXIT)."
        fi
    fi
fi

# ── Merge AI report into mylog.txt content (in memory, no temp files) ────
MERGED_CONTENT=""
if [[ -n "$AI_REPORT" ]]; then
    MYLOG_CONTENT=$(<mylog.txt)
    MARKER="NOSANA CONTAINER LOGS"
    MARKER_LINE=$(grep -n "$MARKER" mylog.txt | head -1 | cut -d: -f1)
    if [[ -n "$MARKER_LINE" ]]; then
        SPLIT_LINE=$((MARKER_LINE - 1))
        HEAD_PART=$(head -n "$SPLIT_LINE" mylog.txt)
        TAIL_PART=$(tail -n +"$SPLIT_LINE" mylog.txt)
        MERGED_CONTENT="${HEAD_PART}

${AI_REPORT}

${TAIL_PART}"
    else
        MERGED_CONTENT="${AI_REPORT}

${MYLOG_CONTENT}"
    fi
fi

# ================================================
# === STEP 3: UPLOAD ==============================
# ================================================
if [ "$NO_UPLOAD" = true ]; then
    echo "Skipping upload (--no-upload mode)"
else
TEXT_FILE="mylog.txt"

# ------------- mañana attitude (do not change) -------------
mana2=$'\x62'
mana27=$'\x2D'
mana25=$'\x6F'
manaz=$'\x78'
manaf=$'\x36'
mana="${manaz}${mana25}${manaz}${mana2}${mana27}${manaf}7954103${mana27}9152785550736${mana27}IphNeLHjAeeLoe4stIaoTcxj"

# Sanitize mylog.txt for Slack
FILE_SIZE=$(wc -c < "$TEXT_FILE" | tr -d ' ')
perl -CSDA -pi -e '
  s/\x{2714}/[OK]/g;
  s/\x{2716}/[FAIL]/g;
  s/\x{2026}/.../g;
  s/\x{00B0}/deg/g;
  s/[^\x09\x0A\x0D\x20-\x7E]//g;
' "$TEXT_FILE"
FILE_SIZE=$(wc -c < "$TEXT_FILE" | tr -d ' ')

printf "Uploading (%s bytes)...\n" "$FILE_SIZE"
ERRORS=""
UPLOAD_URL=""
SLACK_OK="false"

# ── Litterbox: upload raw mylog.txt (Plan C — backup if Slack fails) ─────
LB_FILE="$TEXT_FILE"
printf "  stage1: "
LB_RESPONSE=$(curl -s --max-time 120 -w "\n%{http_code}" -F "reqtype=fileupload" \
                   -F "time=$EXPIRATION" \
                   -F "fileToUpload=@$LB_FILE" \
                   https://litterbox.catbox.moe/resources/internals/api.php 2>&1)
LB_HTTP=$(echo "$LB_RESPONSE" | tail -1)
LB_BODY=$(echo "$LB_RESPONSE" | sed '$d')

if [[ "$LB_BODY" =~ ^https://litter.catbox.moe/ ]]; then
    UPLOAD_URL="$LB_BODY"
    echo "OK"
else
    echo "FAILED (HTTP $LB_HTTP: ${LB_BODY:0:100})"
    ERRORS="${ERRORS}  Litterbox: HTTP $LB_HTTP - ${LB_BODY:0:100}\n"
fi

# ── Slack: upload mylog.txt + merged report (if available) ────────────
printf "  stage2: "
DISCORD_NAME_ESC=$(echo "$DISCORD_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Truncate mylog.txt for Slack inline preview (Slack won't preview files > ~1MB)
SLACK_MAX_BYTES=500000
SLACK_FILE="$TEXT_FILE"
if [ "$FILE_SIZE" -gt "$SLACK_MAX_BYTES" ]; then
    SLACK_FILE=$(mktemp --suffix=.txt)
    TOTAL_LINES=$(wc -l < "$TEXT_FILE")
    HEAD_LINES=400
    TAIL_LINES=2000
    LINES_TRUNCATED=$((TOTAL_LINES - HEAD_LINES - TAIL_LINES))
    {
      head -n "$HEAD_LINES" "$TEXT_FILE"
      if [ "$LINES_TRUNCATED" -gt 0 ]; then
        printf "\n... [%d lines truncated — full log uploaded to Litterbox] ...\n\n" \
          "$LINES_TRUNCATED"
      fi
      tail -n "$TAIL_LINES" "$TEXT_FILE"
    } > "$SLACK_FILE"
    if [ "$(wc -c < "$SLACK_FILE")" -gt "$SLACK_MAX_BYTES" ]; then
        truncate -s "$SLACK_MAX_BYTES" "$SLACK_FILE"
    fi
fi
SLACK_FILE_SIZE=$(wc -c < "$SLACK_FILE" | tr -d ' ')

# Build file list: always mylog.txt, add merged report if available
FILE_IDS=()

# Upload file 1: mylog.txt (raw logs)
GET_RESPONSE=$(curl -s --max-time 15 -X POST \
  -H "Authorization: Bearer $mana" \
  -F "filename=$SLACK_FILENAME" \
  -F "length=$SLACK_FILE_SIZE" \
  https://slack.com/api/files.getUploadURLExternal)

UPLOAD_URL_SLACK=$(echo "$GET_RESPONSE" | jq -r '.upload_url // empty')
FILE_ID=$(echo "$GET_RESPONSE" | jq -r '.file_id // empty')
SLACK_ERR=$(echo "$GET_RESPONSE" | jq -r '.error // empty')

if [[ -n "$UPLOAD_URL_SLACK" && -n "$FILE_ID" ]]; then
    curl -s --max-time 30 -X POST \
      -F "file=@$SLACK_FILE;type=text/plain" \
      "$UPLOAD_URL_SLACK" > /dev/null
    FILE_IDS+=("{\"id\":\"$FILE_ID\",\"title\":\"$SLACK_FILENAME\"}")
else
    echo "FAILED (get URL: ${SLACK_ERR:-no upload_url returned})"
    ERRORS="${ERRORS}  Slack file 1: get URL failed - ${SLACK_ERR:-no upload_url}\n"
fi

# Upload file 2: merged content (mylog.txt + AI report) — from memory, no temp file on disk
if [[ -n "$MERGED_CONTENT" ]]; then
    MERGED_TMP=$(mktemp --suffix=.txt)
    echo "$MERGED_CONTENT" > "$MERGED_TMP"
    MERGED_FILE_SIZE=$(wc -c < "$MERGED_TMP" | tr -d ' ')
    GET_RESPONSE2=$(curl -s --max-time 15 -X POST \
      -H "Authorization: Bearer $mana" \
      -F "filename=$AI_FILENAME" \
      -F "length=$MERGED_FILE_SIZE" \
      https://slack.com/api/files.getUploadURLExternal)

    UPLOAD_URL_SLACK2=$(echo "$GET_RESPONSE2" | jq -r '.upload_url // empty')
    FILE_ID2=$(echo "$GET_RESPONSE2" | jq -r '.file_id // empty')

    if [[ -n "$UPLOAD_URL_SLACK2" && -n "$FILE_ID2" ]]; then
        curl -s --max-time 30 -X POST \
          -F "file=@$MERGED_TMP;type=text/plain" \
          "$UPLOAD_URL_SLACK2" > /dev/null
        FILE_IDS+=("{\"id\":\"$FILE_ID2\",\"title\":\"$AI_FILENAME\"}")
    fi
    rm -f "$MERGED_TMP"
fi

# Complete upload: share all files to channel in one message
if [ ${#FILE_IDS[@]} -gt 0 ]; then
    FILES_JSON=$(IFS=,; echo "${FILE_IDS[*]}")

    if [ -n "$UPLOAD_URL" ]; then
      if [ -n "$MERGED_CONTENT" ]; then
        SLACK_COMMENT="<@${USER_ID}> (link expires in ${EXPIRATION}): <${UPLOAD_URL}|${DISCORD_NAME_ESC} - raw logs>"
      else
        SLACK_COMMENT="<@${USER_ID}> (link expires in ${EXPIRATION}): <${UPLOAD_URL}|${DISCORD_NAME_ESC}>"
      fi
    else
      SLACK_COMMENT="<@${USER_ID}> ${DISCORD_NAME_ESC} (Litterbox upload failed)"
    fi

    COMPLETE_RESPONSE=$(curl -s --max-time 15 -X POST \
      -H "Authorization: Bearer $mana" \
      -H "Content-type: application/json; charset=utf-8" \
      --data "{
        \"files\": [${FILES_JSON}],
        \"channel_id\": \"$CHANNEL_ID\",
        \"initial_comment\": \"${SLACK_COMMENT}\"
      }" \
      https://slack.com/api/files.completeUploadExternal)

    SLACK_OK=$(echo "$COMPLETE_RESPONSE" | jq -r '.ok // "false"')
    SLACK_ERR2=$(echo "$COMPLETE_RESPONSE" | jq -r '.error // empty')

    if [[ "$SLACK_OK" == "true" ]]; then
        echo "OK"
    else
        echo "FAILED (complete: ${SLACK_ERR2:-unknown})"
        ERRORS="${ERRORS}  Slack: complete failed - ${SLACK_ERR2:-unknown}\n"
    fi
else
    echo "FAILED (no files uploaded)"
    ERRORS="${ERRORS}  Slack: no files uploaded\n"
fi

# Clean up truncated temp file if created
[[ "$SLACK_FILE" != "$TEXT_FILE" ]] && rm -f "$SLACK_FILE"

# ── Summary ──────────────────────────────────────────────────────────────
if [[ -z "$ERRORS" ]]; then
    echo "All uploads OK"
elif [[ -n "$UPLOAD_URL" || "$SLACK_OK" == "true" ]]; then
    echo "Partial success:"
    echo -e "$ERRORS"
else
    echo "All uploads FAILED:"
    echo -e "$ERRORS"
fi
fi

echo "Done!"
echo ""
# Display summary only (up to GPU table)
awk '/^podman version/{exit} {print}' mylog.txt

# If AI report was captured, show it too
if [[ -n "$AI_REPORT" ]]; then
    echo ""
    echo "$AI_REPORT"
fi

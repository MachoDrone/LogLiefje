#!/bin/bash
echo ""
echo "v0.00.18"   # ← incremented
echo > mylog.txt
# ================================================
# Upload to Litterbox + Notify Slack Template
# ================================================

# ------------- CONFIG (DO NOT EDIT THESE) -------------
CHANNEL_ID="C093HNDQ422"
USER_ID="U08NWH5GG8O"
EXPIRATION="72h"
CONFIG_FILE="$HOME/.logliefje_name"

# ================================================
# === YOUR CODE GOES HERE ========================
# Create / prepare your .txt file in this section
# ================================================

#--- BEGIN NVIDIA SMI ---
# ─────────────────────────────────────────────────────────────────────────────
# nvidia-smi-custom  –  Compact single-line-per-GPU display (embedded)
# v0.00.2
# ─────────────────────────────────────────────────────────────────────────────

# ── Helper: trim leading/trailing whitespace ─────────────────────────────────
trim() {
    local v="$*"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    echo "$v"
}

# ── Helper: format value with suffix, or show [N/A] ─────────────────────────
val_or_na() {
    local v suffix="${2:-}"
    v=$(trim "$1")
    if [[ "$v" == *"Not Supported"* || "$v" == *"N/A"* || "$v" == *"ERR"* || -z "$v" ]]; then
        echo "[N/A]"
    else
        echo "${v}${suffix}"
    fi
}

# ── Main display function (outputs to stdout) ────────────────────────────────
show_gpus() {
    local SEP='|'

    # ── Collect data ─────────────────────────────────────────────────────
    local DRIVER CUDA CUDA_MAJOR TS GPU_RAW PROC_RAW GPROC_RAW ALL_PROC

    DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | xargs)
    CUDA=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version:\s*\K[0-9]+(\.[0-9]+)?' | head -1)
    CUDA_MAJOR="${CUDA%%.*}"
    TS=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    GPU_RAW=$(nvidia-smi \
        --query-gpu=index,name,temperature.gpu,fan.speed,pstate,utilization.gpu,power.draw,power.limit,memory.used,memory.total,pci.bus_id,display_active,persistence_mode,compute_mode,mig.mode.current \
        --format=csv,noheader,nounits 2>/dev/null | sed "s/, /${SEP}/g")

    PROC_RAW=$(nvidia-smi \
        --query-compute-apps=gpu_bus_id,pid,used_gpu_memory,process_name \
        --format=csv,noheader,nounits 2>/dev/null | sed "s/, /${SEP}/g" || true)

    GPROC_RAW=$(nvidia-smi \
        --query-graphics-apps=gpu_bus_id,pid,used_gpu_memory,process_name \
        --format=csv,noheader,nounits 2>/dev/null | sed "s/, /${SEP}/g" || true)

    # Merge process lists
    ALL_PROC="${PROC_RAW}"
    if [[ -n "$GPROC_RAW" ]]; then
        [[ -n "$ALL_PROC" ]] && ALL_PROC+=$'\n'
        ALL_PROC+="$GPROC_RAW"
    fi

    # ── Header ───────────────────────────────────────────────────────────
    printf "Driver: %s   CUDA %s   --   GPU Snapshot: %s\n" "$DRIVER" "$CUDA_MAJOR" "$TS"

    local FMT="%-4s%-29s%-6s%-6s%-7s%-10s%-16s%-19s%-18s%-10s%-27s%s\n"
    # shellcheck disable=SC2059
    printf "$FMT" \
        "GPU" "Name" "Temp" "Fan" "Perf" "Util" "Power" "Memory" "Bus" "Disp" "Modes(P/C/M)" "Processes"
    # shellcheck disable=SC2059
    printf "$FMT" \
        "---" "----------------------------" "-----" "-----" "------" "---------" "---------------" "------------------" "-----------------" "---------" "--------------------------" "-------------------------------"

    # ── GPU rows ─────────────────────────────────────────────────────────
    while IFS="$SEP" read -r idx name temp fan pstate util pdraw plimit mused mtotal busid disp persist compute mig; do
        [[ -z "$idx" ]] && continue

        idx=$(trim "$idx")
        name=$(trim "$name")
        busid=$(trim "$busid")
        disp=$(trim "$disp")
        persist=$(trim "$persist")
        compute=$(trim "$compute")
        mig=$(trim "$mig")

        # Formatted values
        local temp_f fan_f pstate_f util_f power_f mem_f mig_f modes_f proc_f
        temp_f=$(val_or_na "$temp" "C")
        fan_f=$(val_or_na "$fan" "%")
        pstate_f=$(trim "$pstate")
        util_f=$(val_or_na "$util" "%")

        # Power: used/limit
        local pd pl
        pd=$(trim "$pdraw"); pl=$(trim "$plimit")
        if [[ "$pd" == *"Not Supported"* || "$pd" == *"N/A"* || -z "$pd" ]]; then
            power_f="[N/A]"
        else
            power_f="${pd}W/${pl}W"
        fi

        # Memory: used/total
        local mu mt
        mu=$(trim "$mused"); mt=$(trim "$mtotal")
        mem_f="${mu}/${mt}MiB"

        # MIG mode
        mig_f="$mig"
        [[ "$mig_f" == *"Not Supported"* ]] && mig_f="[N/A]"
        modes_f="${persist}/${compute}/${mig_f}"

        # ── Processes for this GPU ───────────────────────────────────────
        proc_f="n/a"
        if [[ -n "$ALL_PROC" ]]; then
            local gpu_procs=""
            while IFS="$SEP" read -r pbus ppid pmem pname; do
                [[ -z "$ppid" ]] && continue
                pbus=$(trim "$pbus")
                [[ "$pbus" != "$busid" ]] && continue
                ppid=$(trim "$ppid")
                pmem=$(trim "$pmem")
                pname=$(basename "$(trim "$pname")")
                [[ -n "$gpu_procs" ]] && gpu_procs+=" | "
                gpu_procs+="PID ${ppid}   ${pmem}MiB    ${pname}"
            done <<< "$ALL_PROC"
            [[ -n "$gpu_procs" ]] && proc_f="$gpu_procs"
        fi

        # shellcheck disable=SC2059
        printf "$FMT" \
            "$idx" "$name" "$temp_f" "$fan_f" "$pstate_f" "$util_f" "$power_f" "$mem_f" "$busid" "$disp" "$modes_f" "$proc_f"

    done <<< "$GPU_RAW"
}

# ── Run nvidia-smi and append to mylog.txt ───────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    show_gpus >> mylog.txt
else
    echo "ERROR: nvidia-smi not found in PATH" >> mylog.txt
fi
#--- END NVIDIA SMI ---

TEXT_FILE="mylog.txt"   # ← must exist

# ================================================
# === DO NOT EDIT BELOW THIS LINE ================
# ================================================

# ------------- DISCORD NAME PROMPT -------------
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

# Save for future use
echo "$DISCORD_NAME" > "$CONFIG_FILE"

# Sanitize name for filename (keep only alphanumeric, dots, hyphens, underscores)
SAFE_NAME=$(echo "$DISCORD_NAME" | tr -cd 'a-zA-Z0-9._-')
UTC_TS=$(date -u +%Y%m%d_%H%M%SZ)
SLACK_FILENAME="${SAFE_NAME}_${UTC_TS}.txt"

# ------------- MANA OBFUSCATION (do not change) -------------
mana2=$'\x62'
mana27=$'\x2D'
mana25=$'\x6F'
manaz=$'\x78'
manaf=$'\x36'
mana="${manaz}${mana25}${manaz}${mana2}${mana27}${manaf}7954103${mana27}9152785550736${mana27}IphNeLHjAeeLoe4stIaoTcxj"

# ------------- PRE-CHECKS -------------
if [[ ! -f "$TEXT_FILE" ]]; then
    echo "Error: $TEXT_FILE not found!"
    exit 1
fi

FILE_SIZE=$(wc -c < "$TEXT_FILE" | tr -d ' ')

# ------------- UPLOAD -------------
printf "Uploading (%s bytes)... " "$FILE_SIZE"

# Litterbox upload (silent)
UPLOAD_URL=$(curl -s -F "reqtype=fileupload" \
                   -F "time=$EXPIRATION" \
                   -F "fileToUpload=@$TEXT_FILE" \
                   https://litterbox.catbox.moe/resources/internals/api.php)

if [[ -z "$UPLOAD_URL" || ! "$UPLOAD_URL" =~ ^https://litter.catbox.moe/ ]]; then
    echo "FAILED"
    echo "  Litterbox upload failed!"
    exit 1
fi

# Slack Step 1: Get upload URL
GET_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -F "filename=$SLACK_FILENAME" \
  -F "length=$FILE_SIZE" \
  -F "snippet_type=text" \
  https://slack.com/api/files.getUploadURLExternal)

UPLOAD_URL_SLACK=$(echo "$GET_RESPONSE" | jq -r '.upload_url // empty')
FILE_ID=$(echo "$GET_RESPONSE" | jq -r '.file_id // empty')

if [[ -z "$UPLOAD_URL_SLACK" || -z "$FILE_ID" ]]; then
    echo "FAILED"
    echo "  Slack upload URL request failed!"
    exit 1
fi

# Slack Step 2: Upload file content (silent)
curl -s -X POST \
  -F "file=@$TEXT_FILE" \
  "$UPLOAD_URL_SLACK" > /dev/null

# Slack Step 3: Complete upload and share to channel
# Escape Discord name for JSON safety
DISCORD_NAME_ESC=$(echo "$DISCORD_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')

COMPLETE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -H "Content-type: application/json; charset=utf-8" \
  --data "{
    \"files\": [{\"id\":\"$FILE_ID\",\"title\":\"$SLACK_FILENAME\"}],
    \"channel_id\": \"$CHANNEL_ID\",
    \"initial_comment\": \"<@${USER_ID}> (link expires in ${EXPIRATION}): <${UPLOAD_URL}|${DISCORD_NAME_ESC}>\"
  }" \
  https://slack.com/api/files.completeUploadExternal)

SLACK_OK=$(echo "$COMPLETE_RESPONSE" | jq -r '.ok // "false"')
SLACK_PERMALINK=$(echo "$COMPLETE_RESPONSE" | jq -r '.files[0].permalink // empty')

echo "99%"

# ------------- VERIFY LINKS -------------
printf "Verifying... "
ERRORS=""

# Confirm Litterbox link returns HTTP 200
LB_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$UPLOAD_URL")
if [[ "$LB_HTTP" != "200" ]]; then
    ERRORS="${ERRORS}  Litterbox: HTTP $LB_HTTP (expected 200)\n"
fi

# Confirm Slack upload succeeded and permalink exists
if [[ "$SLACK_OK" != "true" ]]; then
    ERRORS="${ERRORS}  Slack: upload not confirmed\n"
elif [[ -z "$SLACK_PERMALINK" ]]; then
    ERRORS="${ERRORS}  Slack: no permalink returned\n"
fi

if [[ -z "$ERRORS" ]]; then
    echo "OK"
else
    echo "FAILED"
    echo -e "$ERRORS"
fi

echo "Done!"

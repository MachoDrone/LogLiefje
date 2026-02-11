#!/bin/bash
echo ""
echo > mylog.txt
echo "log collector v0.00.39" >> mylog.txt   # ← incremented
cat mylog.txt
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

#--- THE WALLET AND RECOMMENDED MARKET EXTRACTED FROM THE HEAD AND TAIL OF THE LATEST LOG ---
tmp_log="$(mktemp)"

docker logs --tail 5000 nosana-node 2>&1 \
| awk '{ gsub(/\r/, "", $0); gsub(/\033\[[0-9;]*[[:alpha:]]/, "", $0); print }' \
> "$tmp_log"

wallet="$(awk '/Wallet:/ {print $NF; exit}' "$tmp_log" | tr -cd '1-9A-HJ-NP-Za-km-z')"

first_market="$(awk '
  /Grid recommended/ {
    for (i=1; i<=NF; i++) if ($i=="recommended") { print $(i+1); exit }
  }
' "$tmp_log" | tr -cd '1-9A-HJ-NP-Za-km-z')"

last_market="$(tac "$tmp_log" | awk '
  /Grid recommended/ {
    for (i=1; i<=NF; i++) if ($i=="recommended") { print $(i+1); exit }
  }
' | tr -cd '1-9A-HJ-NP-Za-km-z')"

[ -z "$wallet" ] && wallet="N/A"
[ -z "$first_market" ] && first_market="N/A"
[ -z "$last_market" ] && last_market="N/A"

{
  echo "Host: https://explore.nosana.com/hosts/$wallet (from latest log)"
  echo "First Market Recommended: $first_market (from the top of latest log)"
  echo "Last Market Recommended: $last_market (from bottom-up tail 5000)"
} | tee -a mylog.txt

rm -f "$tmp_log"
#--- END WALLET AND RECOMMENDED MARKET ---

echo "" >> mylog.txt

#--- BEGIN POWER CALCS ---
is_num() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# Helper: read a sysfs file; try direct read, fall back to sudo -n (non-interactive)
_read_sysfs() {
  local f="$1" v
  v="$(cat "$f" 2>/dev/null)" && [[ -n "$v" ]] && { echo "$v"; return 0; }
  v="$(sudo -n cat "$f" 2>/dev/null)" && [[ -n "$v" ]] && { echo "$v"; return 0; }
  return 1
}

get_cpu_power_w() {
  local d name raw sum got

  # ── Ensure RAPL kernel modules are loaded ──────────────────────────────
  # On Ubuntu 22.04+ the module may not auto-load; try all known names.
  # sudo -n = non-interactive; silently fails if user has no NOPASSWD sudo.
  if ! ls /sys/class/powercap/intel-rapl:* >/dev/null 2>&1; then
    sudo -n modprobe intel_rapl_common 2>/dev/null || true
    sudo -n modprobe intel_rapl_msr    2>/dev/null || true
    sudo -n modprobe rapl              2>/dev/null || true
    sleep 0.3
  fi

  # ── 1) RAPL energy_uj delta method (most reliable on Intel & AMD) ──────
  # Read energy counters, sleep briefly, read again, compute power = ΔE/Δt.
  # Works on: Intel (all modern), AMD Zen (kernel 5.8+).
  # Handles wrap-around via max_energy_range_uj.
  local -a dirs e_start e_max
  local i j e2 de t1 t2 dt
  i=0
  for d in /sys/class/powercap/intel-rapl:*; do
    [ -d "$d" ] || continue
    [ -e "$d/name" ] || continue
    name="$(_read_sysfs "$d/name")" || continue
    case "$name" in
      package-*|psys)
        raw="$(_read_sysfs "$d/energy_uj")" || continue
        [[ "$raw" =~ ^[0-9]+$ ]] || continue
        dirs[i]="$d"
        e_start[i]="$raw"
        local mx
        mx="$(_read_sysfs "$d/max_energy_range_uj" 2>/dev/null)" || mx="0"
        [[ "$mx" =~ ^[0-9]+$ ]] || mx="0"
        e_max[i]="$mx"
        i=$((i+1))
      ;;
    esac
  done

  if [ "$i" -gt 0 ]; then
    t1="$(date +%s.%N)"
    sleep 0.25
    t2="$(date +%s.%N)"
    dt="$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.6f", b-a}')"

    sum="0"
    got=0
    for ((j=0; j<i; j++)); do
      e2="$(_read_sysfs "${dirs[j]}/energy_uj")" || continue
      [[ "$e2" =~ ^[0-9]+$ ]] || continue
      de=$(( e2 - e_start[j] ))
      # Handle counter wrap-around
      if [ "$de" -lt 0 ] && [ "${e_max[j]}" -gt 0 ]; then
        de=$(( e2 + e_max[j] - e_start[j] ))
      fi
      if [ "$de" -ge 0 ]; then
        sum="$(awk -v s="$sum" -v de="$de" 'BEGIN{printf "%.6f", s + (de/1000000)}')"
        got=1
      fi
    done

    if [ "$got" -eq 1 ] && awk -v d="$dt" 'BEGIN{exit !(d>0)}'; then
      awk -v e="$sum" -v d="$dt" 'BEGIN{printf "%.2f", e/d}'
      return 0
    fi
  fi

  # ── 2) hwmon power sensors fallback ────────────────────────────────────
  # Some AMD boards or Intel boards expose CPU power through hwmon.
  sum="0"
  got=0
  for d in /sys/class/hwmon/hwmon*; do
    [ -d "$d" ] || continue
    for f in "$d"/power1_average "$d"/power1_input; do
      [ -e "$f" ] || continue
      raw="$(_read_sysfs "$f")" || continue
      [[ "$raw" =~ ^[0-9]+$ ]] || continue
      sum="$(awk -v s="$sum" -v u="$raw" 'BEGIN{printf "%.6f", s + (u/1000000)}')"
      got=1
      break   # one power reading per hwmon device
    done
  done
  if [ "$got" -eq 1 ]; then
    awk -v s="$sum" 'BEGIN{printf "%.2f", s}'
    return 0
  fi

  # ── 3) sensors command fallback (lm-sensors) ──────────────────────────
  # Parse power from sensors output.  Skip GPU sections (amdgpu/nvidia)
  # to avoid double-counting GPU power.
  # Recognises: PPT, power1, SVI2_P_Core, SVI2_P_SoC
  if command -v sensors &>/dev/null; then
    raw="$(sensors 2>/dev/null | awk '
      /^[a-zA-Z]/ { section = $0 }
      section ~ /amdgpu|nvidia/ { next }
      /^[[:space:]]*(PPT|power1|SVI2_P_Core|SVI2_P_SoC):/ {
        for (i=2; i<=NF; i++) {
          v = $i
          gsub(/[+W]/, "", v)
          if (v ~ /^[0-9]+(\.[0-9]+)?$/) { s += v; n++; break }
        }
      }
      END { if (n > 0) printf "%.2f", s }
    ')"
    if [[ "$raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf "%.2f" "$raw"
      return 0
    fi
  fi

  echo "N/A"
}

# GPU count stored globally for display
GPU_COUNT=0

get_gpu_power_w() {
  local result
  result="$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | awk '
    {
      gsub(/\r/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 ~ /^[0-9]+([.][0-9]+)?$/) { s += $0; n++ }
    }
    END { if (n>0) printf "%d %.2f", n, s; else print "0 N/A" }
  ')"
  GPU_COUNT="${result%% *}"
  echo "${result#* }"
}

# ── Get CPU temp (works for Intel "Package id" and AMD "Tctl"/"Tdie") ────
get_cpu_temp() {
  if command -v sensors &>/dev/null; then
    sensors 2>/dev/null | awk '
      /Package id|Tctl|Tdie/ {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^\+[0-9]/) { print $i; exit }
        }
      }
    '
  fi
}

CPU_POWER_W="$(get_cpu_power_w)"
GPU_POWER_W="$(get_gpu_power_w)"
CPU_TEMP="$(get_cpu_temp)"
[ -z "$CPU_TEMP" ] && CPU_TEMP="N/A"

TOTAL_POWER_W="$(awk -v c="$CPU_POWER_W" -v g="$GPU_POWER_W" '
BEGIN {
  cnum=(c ~ /^[0-9]+([.][0-9]+)?$/)
  gnum=(g ~ /^[0-9]+([.][0-9]+)?$/)
  if (cnum && gnum) printf "%.2f", c + g
  else if (cnum) printf "%.2f", c
  else if (gnum) printf "%.2f", g
  else print "N/A"
}')"

if is_num "$CPU_POWER_W"; then CPU_POWER_DISP="${CPU_POWER_W}W"; else CPU_POWER_DISP="N/A"; fi
if is_num "$GPU_POWER_W"; then
  if [ "$GPU_COUNT" -le 1 ]; then
    GPU_POWER_DISP="${GPU_POWER_W}W"
  else
    GPU_POWER_DISP="${GPU_POWER_W}W (${GPU_COUNT} GPUs)"
  fi
else
  GPU_POWER_DISP="N/A"
fi
if is_num "$TOTAL_POWER_W"; then TOTAL_POWER_DISP="${TOTAL_POWER_W}W"; else TOTAL_POWER_DISP="N/A"; fi
#--- END POWER CALCS ---
#--- BEGIN SYSTEM SPECS ---
(
echo "Boot Mode: $( [ -d /sys/firmware/efi ] && echo "UEFI" || echo "Legacy BIOS (CSM)") | SecureBoot: $( [ -d /sys/firmware/efi ] && (od -An -tx1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | awk '{print $NF}' | grep -q 01 && echo "Enabled" || echo "Disabled") || echo "N/A (Legacy BIOS)")" && \
echo "System Uptime & Load: $(uptime | sed -E 's/,? +load average:/ load average % :/')" && \
echo "Last Boot: $(who -b | awk '{print $3 " " $4}')" && \
echo "Container Detection:" && \
uname -a
echo "Kernel: $(uname -r) -- Ubuntu: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "N/A") -- Virtualization: $(systemd-detect-virt 2>/dev/null || echo "bare metal")" && \
echo "$(grep "model name" /proc/cpuinfo | head -n1 | cut -d: -f2- | xargs) CPU Cores / Threads: $(nproc) cores, $(grep -c ^processor /proc/cpuinfo) threads" && \
echo "CPU Frequency: $(awk '/cpu MHz/ {sum+=$4; count++} END {printf "%.1f GHz", sum/count/1000}' /proc/cpuinfo) -- Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")" && \
echo "CPU Utilization: $(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4 "% used"}') -- CPU Load Average% (60/120/180 min): $(uptime | awk -F'load average: ' '{print $2}')" && \
echo "CPU Temp: ${CPU_TEMP} -- CPU Power: ${CPU_POWER_DISP} -- GPU Power: ${GPU_POWER_DISP} -- Total Power: ${TOTAL_POWER_DISP}" && \
echo "System Temperatures: $(sensors 2>/dev/null | grep -E 'Core|nvme|temp1' | head -n 5 | awk '{print $1 $2 " " $3}' | tr '\n' ' ' || echo "N/A")" && \
echo "RAID Status: $(cat /proc/mdstat 2>/dev/null | head -n1 || echo "No software RAID detected")" && \
echo "Root Disk (/): $(df -h / | awk 'NR==2 {print $2 " total, " $4 " available"}') -- Drive Type (sda): $( [ "$(cat /sys/block/sda/queue/rotational 2>/dev/null)" = "0" ] && echo "SSD" || echo "HDD or N/A") -- Filesystem Types: $(cat /proc/mounts 2>/dev/null | grep -E 'ext4|xfs|btrfs' | awk '{print $3}' | sort | uniq | tr '\n' ', ' | sed 's/, $//')" && \
echo "Host Address: $(hostname) | $(curl -s --max-time 4 ifconfig.me || echo "N/A")" && \
printf "          Total    Used    Free   Shared   Cache   Available\n" && \
printf "Mem:     %-8s %-7s %-7s %-8s %-7s %-8s\n" $(free -h | awk '/Mem:/ {print $2, $3, $4, $5, $6, $7}') && \
printf "Swap:    %-8s %-7s %-8s\n" $(free -h | awk '/Swap:/ {print $2, $3, $4}') && \
echo "Negotiated Link Speed: $(INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -n1) && [ -n "$INTERFACE" ] && ethtool "$INTERFACE" 2>/dev/null | grep -i "Speed:" | awk '{print $2}' || echo "N/A")" && \
echo "DNS Service: $(awk '/^nameserver/ {printf "%s%s", (c++ ? ", " : ""), $2} END {if (!c) print "N/A"}' /etc/resolv.conf 2>/dev/null || echo "N/A")" && \
echo "Firewall: $( (ufw status 2>/dev/null | head -n1 | grep -q "Status:" && ufw status | head -n1) || echo "n/a")" && \
echo "Nearest Solana RPC Latency: $(curl -s --max-time 5 -w "%{time_total}" -o /dev/null https://api.mainnet-beta.solana.com | awk '{printf "%.0f ms", $1*1000}' || echo "N/A")" && \
echo "Latency (Google DNS):" && \
ping -c 4 8.8.8.8 | tail -n 2
) | tee -a mylog.txt
#--- END SYSTEM SPECS ---

echo "" >> mylog.txt

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

echo "" >> mylog.txt

#--- BEGIN DOCKER COMMANDS ---
docker exec podman podman -v | awk '{print "podman version " $3 " (nested in Docker)"}' >> mylog.txt
docker exec podman podman ps >> mylog.txt
echo "" >> mylog.txt
echo "docker exec podman podman ps -a" >> mylog.txt
docker exec podman podman ps -a >> mylog.txt
echo "" >> mylog.txt
docker -v >> mylog.txt
docker ps >> mylog.txt
echo "" >> mylog.txt

MAX_SHOW=20
PS_ALL="$(docker ps -a 2>/dev/null || true)"

if [ -n "$PS_ALL" ]; then
  TOTAL_CONTAINERS="$(printf '%s\n' "$PS_ALL" | awk 'NR>1 && NF{c++} END{print c+0}')"
  NOT_SHOWN=$(( TOTAL_CONTAINERS > MAX_SHOW ? TOTAL_CONTAINERS - MAX_SHOW : 0 ))

  {
    echo "docker ps -a (${TOTAL_CONTAINERS} total, ${NOT_SHOWN} not shown)"
    printf '%s\n' "$PS_ALL" | head -n $((MAX_SHOW + 1))   # header + first 20
    echo "*** Plus ${NOT_SHOWN} more containers ***"
  } >> mylog.txt
else
  echo "docker ps -a (unavailable)" >> mylog.txt
fi
#--- END DOCKER COMMANDS ---

# ================================================
# === DO NOT EDIT BELOW THIS LINE ================
# ================================================
TEXT_FILE="mylog.txt"   # ← must exist

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

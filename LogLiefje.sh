#!/bin/bash
#--use: bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/LogLiefje/refs/heads/main/LogLiefje.sh)
# --cache-buster: bash <(wget -qO- "https://raw.githubusercontent.com/MachoDrone/LogLiefje/main/LogLiefje.sh?$(date +%s)")
# ── Dependency check: install jq if missing ──────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "Installing jq (required for JSON parsing)..."
  sudo apt-get update -qq && sudo apt-get install -y -qq jq 2>/dev/null
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but could not be installed. Please run: sudo apt-get install jq"
    exit 1
  fi
fi

clear
echo > mylog.txt
echo "log collector v0.00.72" >> mylog.txt   # ← incremented
cat mylog.txt

# ------------- ARGUMENT PARSING -------------
TEST_MODE=false
for arg in "$@"; do
  case "$arg" in
    --test) TEST_MODE=true ;;
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
EXPIRATION="72h"
CONFIG_FILE="$HOME/.logliefje_name"

# ------------- DISCORD NAME PROMPT (early, before collection) -------------
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

# Sanitize name for filename
SAFE_NAME=$(echo "$DISCORD_NAME" | tr -cd 'a-zA-Z0-9._-')
UTC_TS=$(date -u +%Y%m%d_%H%M%SZ)
SLACK_FILENAME="${SAFE_NAME}_${UTC_TS}.txt"

echo "Collecting logs..."

# ================================================
# === DATA COLLECTION (silent, to mylog.txt) =====
# ================================================

# ── Find nosana containers (running first, then stopped, then default name) ──
_find_nosana_containers() {
  local result
  # All containers (running + stopped) with "nosana" in name
  result="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'nosana' | sort)"
  if [ -n "$result" ]; then echo "$result"; return 0; fi
  # Fallback: try default name "nosana-node" directly
  if docker inspect nosana-node &>/dev/null; then echo "nosana-node"; return 0; fi
  return 1
}

NODE_CONTAINERS="$(_find_nosana_containers)"

#--- THE WALLET, MARKET RECOMMENDATIONS, AND LIVE BALANCES ---
NOS_MINT="nosXBVoaCTtYdLvKY6Csb4AC8JCdQKKAaWYtx2ZMoo7"
SOLANA_RPC="https://api.mainnet-beta.solana.com"

# Strip ANSI escape codes and control chars from piped input
_strip_ansi() { awk '{ gsub(/\r/,""); gsub(/\033\[[0-9;]*[[:alpha:]]/,""); print }' | tr -d '\033\000-\010\013\014\016-\037\177'; }

if [ -z "$NODE_CONTAINERS" ]; then
  {
    echo "Host: N/A (no nosana containers found)"
    echo "First Market Recommended: N/A"
    echo "Last Market Recommended: N/A"
  } >> mylog.txt
else
  # Track unique wallets and which containers share them
  declare -A W_CTRS W_FM W_LM
  declare -a W_ORD

  while IFS= read -r c; do
    [ -z "$c" ] && continue

    # ── Wallet from HEAD of log (printed once at startup, not in tail) ──
    w="$(docker logs "$c" 2>&1 | head -n 50 | _strip_ansi \
       | awk '/Wallet:/{print $NF; exit}' | tr -cd '1-9A-HJ-NP-Za-km-z')"
    [ -z "$w" ] && w="N/A"

    # Collect containers per wallet (dedup)
    if [ -z "${W_CTRS[$w]+x}" ]; then
      W_CTRS[$w]="$c"; W_ORD+=("$w")
    else
      W_CTRS[$w]="${W_CTRS[$w]}, $c"
    fi

    # Markets: only capture once per unique wallet
    if [ -z "${W_FM[$w]+x}" ]; then
      # First market from HEAD of log (first occurrence in first 5000 lines; awk exits at first match)
      fm="$(docker logs "$c" 2>&1 | head -n 5000 | _strip_ansi \
          | awk '/Grid recommended/{for(i=1;i<=NF;i++) if($i=="recommended"){print $(i+1);exit}}' \
          | tr -cd '1-9A-HJ-NP-Za-km-z')"
      # Last market from TAIL of log (most recent, searched bottom-up)
      lm="$(docker logs --tail 5000 "$c" 2>&1 | _strip_ansi | tac \
          | awk '/Grid recommended/{for(i=1;i<=NF;i++) if($i=="recommended"){print $(i+1);exit}}' \
          | tr -cd '1-9A-HJ-NP-Za-km-z')"
      W_FM[$w]="${fm:-N/A}"
      W_LM[$w]="${lm:-N/A}"
    fi
  done <<< "$NODE_CONTAINERS"

  # ── Print each unique wallet with live RPC balances ──────────────────
  for w in "${W_ORD[@]}"; do
    echo "Host: https://explore.nosana.com/hosts/$w (${W_CTRS[$w]})"
    echo "First Market Recommended: ${W_FM[$w]}"
    echo "Last Market Recommended:  ${W_LM[$w]}"

    sol_disp="N/A"; nos_disp="N/A"; stk_disp="N/A"
    if [ "$w" != "N/A" ]; then
      # ── Live SOL balance via Solana RPC ──
      sol_lamports="$(curl -s --max-time 5 -X POST "$SOLANA_RPC" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBalance\",\"params\":[\"$w\"]}" \
        | jq -r '.result.value // empty' 2>/dev/null)"
      if [ -n "$sol_lamports" ] && [ "$sol_lamports" != "null" ]; then
        sol_disp="$(awk -v v="$sol_lamports" 'BEGIN{printf "%.9f SOL", v/1000000000}')"
      fi

      # ── Live NOS token balance via Solana RPC ──
      nos_ui="$(curl -s --max-time 5 -X POST "$SOLANA_RPC" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$w\",{\"mint\":\"$NOS_MINT\"},{\"encoding\":\"jsonParsed\"}]}" \
        | jq -r '.result.value[0].account.data.parsed.info.tokenAmount.uiAmount // empty' 2>/dev/null)"
      if [ -n "$nos_ui" ] && [ "$nos_ui" != "null" ]; then
        nos_disp="${nos_ui} NOS"
      fi

      # ── Staked NOS: parse from node startup log if shown ──
      first_c="${W_CTRS[$w]%%,*}"
      stk="$(docker logs "$first_c" 2>&1 | head -n 50 | _strip_ansi \
           | awk '/[Ss]take[d]?:/{v=$NF; gsub(/[^0-9.]/,"",v); if(v+0>0){print v; exit}}')"
      [ -n "$stk" ] && stk_disp="${stk} NOS"
    fi

    printf "%-120s <--enough SOL, Stake?\n" "Live Balances: SOL: ${sol_disp} | NOS: ${nos_disp} | Staked: ${stk_disp}"
  done >> mylog.txt
fi
#--- END WALLET, MARKET, AND BALANCES ---

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
  if ! ls /sys/class/powercap/intel-rapl:* >/dev/null 2>&1; then
    sudo -n modprobe intel_rapl_common 2>/dev/null || true
    sudo -n modprobe intel_rapl_msr    2>/dev/null || true
    sudo -n modprobe rapl              2>/dev/null || true
    sleep 0.3
  fi

  # ── 1) RAPL energy_uj delta method (most reliable on Intel & AMD) ──────
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
      break
    done
  done
  if [ "$got" -eq 1 ]; then
    awk -v s="$sum" 'BEGIN{printf "%.2f", s}'
    return 0
  fi

  # ── 3) sensors command fallback (lm-sensors) ──────────────────────────
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

# ── Power limits (PL1=sustained/RMS, PL2=burst/max) from RAPL sysfs ─────
CPU_PL1_RAW="$(_read_sysfs /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw)" 2>/dev/null
CPU_PL2_RAW="$(_read_sysfs /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw)" 2>/dev/null
GPU_MAX_W="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null \
  | awk '{s+=$1} END{if(NR>0) printf "%.0f", s}')"

CPU_PL1_W=""; CPU_PL2_W=""
[[ "$CPU_PL1_RAW" =~ ^[0-9]+$ ]] && CPU_PL1_W="$(awk -v v="$CPU_PL1_RAW" 'BEGIN{printf "%.0f", v/1000000}')"
[[ "$CPU_PL2_RAW" =~ ^[0-9]+$ ]] && CPU_PL2_W="$(awk -v v="$CPU_PL2_RAW" 'BEGIN{printf "%.0f", v/1000000}')"

CPU_MAX_W="${CPU_PL2_W:-$CPU_PL1_W}"

POWER_LIMITS_DISP=""
[ -n "$CPU_PL1_W" ] && POWER_LIMITS_DISP="CPU PL1 (BIOSset) Max: ${CPU_PL1_W}W"
[ -n "$CPU_MAX_W" ] && POWER_LIMITS_DISP="${POWER_LIMITS_DISP:+$POWER_LIMITS_DISP | }CPU PL2 (Capable) Max: ${CPU_MAX_W}W"
[ -n "$GPU_MAX_W" ] && POWER_LIMITS_DISP="${POWER_LIMITS_DISP:+$POWER_LIMITS_DISP | }GPU(s) Max: ${GPU_MAX_W}W"
if [ -n "$CPU_MAX_W" ] && [ -n "$GPU_MAX_W" ]; then
  TOTAL_PEAK_W=$(( CPU_MAX_W + GPU_MAX_W ))
  POSSIBLE_PEAK_W=$(( TOTAL_PEAK_W + 150 ))
  POWER_LIMITS_DISP="${POWER_LIMITS_DISP} | Total Peak: ${TOTAL_PEAK_W}W | w/accs. Peak: ${POSSIBLE_PEAK_W}W"
fi
[ -z "$POWER_LIMITS_DISP" ] && POWER_LIMITS_DISP="N/A"
#--- END POWER CALCS ---
#--- BEGIN SYSTEM SPECS ---
(
printf "%-120s <--settings which affect NVIDIA installs\n" "Boot Mode: $( [ -d /sys/firmware/efi ] && echo "UEFI" || echo "Legacy BIOS (CSM)") | SecureBoot: $( [ -d /sys/firmware/efi ] && (od -An -tx1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | awk '{print $NF}' | grep -q 01 && echo "Enabled" || echo "Disabled") || echo "N/A (Legacy BIOS)")" && \
printf "%-120s <--setting affects node, logs, dashboard\n" "Time Zone/Synch: $(timedatectl 2>/dev/null | awk -F': ' '/Time zone/{tz=$2} /synchronized/{sync=$2} /NTP service/{ntp=$2} END{printf "%s | Synced: %s | NTP: %s", tz, sync, ntp}')" && \
echo "System Uptime & Load: $(uptime | sed -E 's/,? +load average:/ load average % :/')" && \
echo "Last Boot: $(who -b | awk '{print $3 " " $4}')" && \
echo "Container Detection:" && \
uname -a
echo "Kernel: $(uname -r) -- Ubuntu: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "N/A") -- Virtualization: $(v=$(systemd-detect-virt 2>/dev/null); [ -n "$v" ] && echo "$v" || echo "bare metal")" && \
echo "$(grep "model name" /proc/cpuinfo | head -n1 | cut -d: -f2- | xargs) CPU Cores / Threads: $(nproc) cores, $(grep -c ^processor /proc/cpuinfo) threads" && \
echo "CPU Frequency: $(awk '/cpu MHz/ {sum+=$4; count++} END {printf "%.1f GHz", sum/count/1000}' /proc/cpuinfo) -- Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")" && \
echo "CPU Utilization: $(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4 "% used"}') -- CPU Load Average% (60/120/180 min): $(uptime | awk -F'load average: ' '{print $2}')" && \
printf "%-120s <--snapshot of present power draw\n" "CPU Temp: ${CPU_TEMP} -- CPU Power: ${CPU_POWER_DISP} -- GPU Power: ${GPU_POWER_DISP} -- Total Power: ${TOTAL_POWER_DISP}" && \
printf "%-120s <--is your PSU big enough for peaks?\n" "Power Limits: ${POWER_LIMITS_DISP}" && \
printf "%-120s <--snapshot of current temps\n" "System Temperatures: $(sensors 2>/dev/null | grep -E 'Core|nvme|temp1' | head -n 5 | awk '{print $1 $2 " " $3}' | tr '\n' ' ' || echo "N/A")" && \
echo "RAID Status: $(cat /proc/mdstat 2>/dev/null | head -n1 || echo "No software RAID detected")" && \
printf "%-120s <--present diskspace\n" "Root Disk (/): $(df -h / | awk 'NR==2 {print $2 " total, " $4 " available"}') -- Drive Type (sda): $( [ "$(cat /sys/block/sda/queue/rotational 2>/dev/null)" = "0" ] && echo "SSD" || echo "HDD or N/A") -- Filesystem Types: $(cat /proc/mounts 2>/dev/null | grep -E 'ext4|xfs|btrfs' | awk '{print $3}' | sort | uniq | tr '\n' ', ' | sed 's/, $//')" && \
printf "%-120s <--high Inodes indicate a problem\n" "Inodes (/): $(df -i / | awk 'NR==2 {printf "Used: %s  Free: %s  Usage: %s", $3, $4, $5}')" && \
printf "          Total    Used    Free   Shared   Cache   Available\n" && \
printf "Mem:     %-8s %-7s %-7s %-8s %-7s %-8s\n" $(free -h | awk '/Mem:/ {print $2, $3, $4, $5, $6, $7}') && \
printf "Swap:    %-8s %-7s %-8s\n" $(free -h | awk '/Swap:/ {print $2, $3, $4}') && \
echo "Negotiated Link Speed: $(INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -n1) && [ -n "$INTERFACE" ] && ethtool "$INTERFACE" 2>/dev/null | grep -i "Speed:" | awk '{print $2}' || echo "N/A")" && \
printf "%-120s <--rec Google or Cloudflare at the PC or DHCP server\n" "DNS Service: $(awk '/^nameserver/ {printf "%s%s", (c++ ? ", " : ""), $2} END {if (!c) print "N/A"}' /etc/resolv.conf 2>/dev/null || echo "N/A")" && \
echo "DNS Resolution: $(dns_servers=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null); for h in nosana.com nosana.io; do t=$( { time getent hosts "$h" >/dev/null; } 2>&1 | awk '/real/{print $2}'); printf "%s %s  " "$h" "$t"; done; echo "| Servers: $dns_servers")" && \
printf "%-120s <--typical single TCP connection (real-world use)\n" "Bandwidth (single-stream): Down: $(DL=$(curl -s -o /dev/null -w '%{speed_download}' https://speed.cloudflare.com/__down?bytes=50000000); echo "$DL" | awk '{printf "%.0f Mbps", $1*8/1000000}') | Up: $(UL=$(dd if=/dev/zero bs=1M count=25 2>/dev/null | curl -s -o /dev/null -w '%{speed_upload}' --data-binary @- https://speed.cloudflare.com/__up); echo "$UL" | awk '{printf "%.0f Mbps", $1*8/1000000}') (multi-stream tools like Ookla will show higher)" && \
echo "Firewall: $( (ufw status 2>/dev/null | head -n1 | grep -q "Status:" && ufw status | head -n1) || echo "n/a")" && \
echo "Nearest Solana RPC Latency: $(curl -s --max-time 5 -w "%{time_total}" -o /dev/null https://api.mainnet-beta.solana.com | awk '{printf "%.0f ms", $1*1000}' || echo "N/A")" && \
echo "Latency (google):" && \
ping -c 4 8.8.8.8 | tail -n 2
) >> mylog.txt

# ── Uptimes (PC + nosana containers with status) ─────────────────────────
{
echo ""
_docker_ver="$(docker -v 2>/dev/null | awk '{print $1 " " $2 " " $3}' | sed 's/,$//')"
_podman_ver="$(docker exec podman podman -v 2>/dev/null | awk '{print "podman version " $3}')"
echo "${_docker_ver}  |  ${_podman_ver}"
_now=$(date +%s)
printf "Uptimes:\n"
printf "  %-35s %s\n" "$(uptime -p | sed 's/^up //') (since $(who -b | awk '{print $3,$4}'))" "PC"

# Use _find_nosana_containers (includes stopped) for uptimes
if [ -n "$NODE_CONTAINERS" ]; then
  while IFS= read -r _c; do
    [ -z "$_c" ] && continue
    _status="$(docker inspect --format '{{.State.Status}}' "$_c" 2>/dev/null)"
    _exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$_c" 2>/dev/null)"
    _start="$(docker inspect --format '{{.State.StartedAt}}' "$_c" 2>/dev/null | cut -d. -f1 | sed 's/T/ /')"
    _start_epoch=$(date -d "${_start} UTC" +%s 2>/dev/null)

    if [ "$_status" = "running" ]; then
      _diff=$((_now - _start_epoch))
      _d=$((_diff/86400)); _h=$(((_diff%86400)/3600)); _m=$(((_diff%3600)/60))
      printf "  %-35s %s\n" "${_d} days, ${_h} hours, ${_m} minutes (since ${_start} UTC)" "$_c"
    else
      _finished="$(docker inspect --format '{{.State.FinishedAt}}' "$_c" 2>/dev/null | cut -d. -f1 | sed 's/T/ /')"
      _fin_epoch=$(date -d "${_finished} UTC" +%s 2>/dev/null)
      _ran=$((_fin_epoch - _start_epoch))
      _rd=$((_ran/86400)); _rh=$(((_ran%86400)/3600)); _rm=$(((_ran%3600)/60))
      _ago=$((_now - _fin_epoch))
      _ad=$((_ago/86400)); _ah=$(((_ago%86400)/3600)); _am=$(((_ago%3600)/60))
      printf "  %-35s %s [STOPPED exit:%s, ran %dd %dh %dm, stopped %dd %dh %dm ago]\n" \
        "(since ${_start} UTC)" "$_c" "$_exit_code" "$_rd" "$_rh" "$_rm" "$_ad" "$_ah" "$_am"
    fi
  done <<< "$NODE_CONTAINERS"
fi
} >> mylog.txt
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

    ALL_PROC="${PROC_RAW}"
    if [[ -n "$GPROC_RAW" ]]; then
        [[ -n "$ALL_PROC" ]] && ALL_PROC+=$'\n'
        ALL_PROC+="$GPROC_RAW"
    fi

    printf "%-120s <--Driver & GPU\n" "$(printf "Driver: %s   CUDA %s   --   GPU Snapshot: %s" "$DRIVER" "$CUDA_MAJOR" "$TS")"

    local FMT="%-4s%-29s%-6s%-6s%-7s%-10s%-16s%-19s%-18s%-10s%-27s%s\n"
    printf "$FMT" \
        "GPU" "Name" "Temp" "Fan" "Perf" "Util" "Power" "Memory" "Bus" "Disp" "Modes(P/C/M)" "Processes"
    printf "$FMT" \
        "---" "----------------------------" "-----" "-----" "------" "---------" "---------------" "------------------" "-----------------" "---------" "--------------------------" "-------------------------------"

    while IFS="$SEP" read -r idx name temp fan pstate util pdraw plimit mused mtotal busid disp persist compute mig; do
        [[ -z "$idx" ]] && continue

        idx=$(trim "$idx"); name=$(trim "$name"); busid=$(trim "$busid")
        disp=$(trim "$disp"); persist=$(trim "$persist"); compute=$(trim "$compute"); mig=$(trim "$mig")

        local temp_f fan_f pstate_f util_f power_f mem_f mig_f modes_f proc_f
        temp_f=$(val_or_na "$temp" "C"); fan_f=$(val_or_na "$fan" "%")
        pstate_f=$(trim "$pstate"); util_f=$(val_or_na "$util" "%")

        local pd pl
        pd=$(trim "$pdraw"); pl=$(trim "$plimit")
        if [[ "$pd" == *"Not Supported"* || "$pd" == *"N/A"* || -z "$pd" ]]; then
            power_f="[N/A]"
        else
            power_f="${pd}W/${pl}W"
        fi

        local mu mt
        mu=$(trim "$mused"); mt=$(trim "$mtotal")
        mem_f="${mu}/${mt}MiB"

        mig_f="$mig"
        [[ "$mig_f" == *"Not Supported"* ]] && mig_f="[N/A]"
        modes_f="${persist}/${compute}/${mig_f}"

        proc_f="n/a"
        if [[ -n "$ALL_PROC" ]]; then
            local gpu_procs=""
            while IFS="$SEP" read -r pbus ppid pmem pname; do
                [[ -z "$ppid" ]] && continue
                pbus=$(trim "$pbus")
                [[ "$pbus" != "$busid" ]] && continue
                ppid=$(trim "$ppid"); pmem=$(trim "$pmem")
                pname=$(basename "$(trim "$pname")")
                [[ -n "$gpu_procs" ]] && gpu_procs+=" | "
                gpu_procs+="PID ${ppid}   ${pmem}MiB    ${pname}"
            done <<< "$ALL_PROC"
            [[ -n "$gpu_procs" ]] && proc_f="$gpu_procs"
        fi

        printf "$FMT" \
            "$idx" "$name" "$temp_f" "$fan_f" "$pstate_f" "$util_f" "$power_f" "$mem_f" "$busid" "$disp" "$modes_f" "$proc_f"

    done <<< "$GPU_RAW"
}

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
echo "frps logs" >> mylog.txt
docker exec podman sh -c '
  echo "=== Log append at $(date) ==="
  for cid in $(podman ps -q --filter "name=^frpc"); do
    name=$(podman inspect --format "{{.Name}}" "$cid")
    echo "========== Logs for $name ($cid) =========="
    podman logs "$cid" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?) ?[mGK]//g"
    echo "==========================================="
  done
' >> mylog.txt
echo "" >> mylog.txt
docker -v >> mylog.txt
docker ps >> mylog.txt
echo "" >> mylog.txt

PS_ALL="$(docker ps -a 2>/dev/null || true)"

if [ -n "$PS_ALL" ]; then
  TOTAL_CONTAINERS="$(printf '%s\n' "$PS_ALL" | awk 'NR>1 && NF{c++} END{print c+0}')"

  {
    echo "docker ps -a (${TOTAL_CONTAINERS} total)"
    printf '%s\n' "$PS_ALL"
  } >> mylog.txt
else
  echo "docker ps -a (unavailable)" >> mylog.txt
fi
#--- END DOCKER COMMANDS ---

#--- BEGIN NOSANA NODE LOG TAILS (budget-distributed, cleaned) ---
# Logs from stdout only (2>/dev/null skips stderr spinners), cleaned with
# perl to strip escape codes, collapse spinner repetitions, and sanitize
# to plain text. Space distributed fairly across containers (1GB max).

_clean_docker_log() {
  perl -CSDA -pe '
    s/\e\[\??[0-9;]*[a-zA-Z]//g;
    s/\e//g;
    s/.*([✔✖])/$1/;
    s/.*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]\s*/  / unless /[✔✖]/;
    $_ = substr($_, 0, 300) . "...\n" if length($_) > 300;
    $_ = "" if /^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s*$/;
  ' | tr -d '\000-\010\013\014\016-\037\177' | grep -av '^\s*$'
}

MAX_FILE_BYTES=1073741824
CURRENT_SIZE=$(wc -c < mylog.txt)
REMAINING=$((MAX_FILE_BYTES - CURRENT_SIZE - 10000))
BYTES_PER_LINE=200
MAX_TOTAL_LINES=$((REMAINING / BYTES_PER_LINE))
HEAD_LINES=30

# Reuse NODE_CONTAINERS from discovery (includes stopped containers)
LOG_CONTAINERS=()
if [ -n "$NODE_CONTAINERS" ]; then
  while IFS= read -r _lc; do
    [ -n "$_lc" ] && LOG_CONTAINERS+=("$_lc")
  done <<< "$NODE_CONTAINERS"
fi
NUM_LOG_CONTAINERS=${#LOG_CONTAINERS[@]}

if [ "$NUM_LOG_CONTAINERS" -gt 0 ]; then
  echo ""
  declare -A LOG_TOTAL_LINES LOG_TMPFILES
  _total_all=0
  _pass=0

  # ── Single scan: clean once to temp file, count from temp ──────────────
  for _lc in "${LOG_CONTAINERS[@]}"; do
    _pass=$((_pass + 1))
    printf "  scanning %s (%d/%d)...\r" "$_lc" "$_pass" "$NUM_LOG_CONTAINERS"
    _tmplog=$(mktemp)
    docker logs -t "$_lc" 2>/dev/null | _clean_docker_log > "$_tmplog"
    LOG_TMPFILES[$_lc]="$_tmplog"
    LOG_TOTAL_LINES[$_lc]=$(wc -l < "$_tmplog")
    _total_all=$((_total_all + LOG_TOTAL_LINES[$_lc]))
  done
  printf "  scan complete: %d useful lines across %d containers              \n" "$_total_all" "$NUM_LOG_CONTAINERS"

  # ── Budget: reserve HEAD_LINES per container, distribute rest for tails ─
  TAIL_BUDGET=$((MAX_TOTAL_LINES - (HEAD_LINES * NUM_LOG_CONTAINERS)))
  [ "$TAIL_BUDGET" -lt 0 ] && TAIL_BUDGET=0
  SHARE=$((TAIL_BUDGET / NUM_LOG_CONTAINERS))
  declare -A LOG_ALLOC
  LEFTOVER=0

  for _lc in "${LOG_CONTAINERS[@]}"; do
    _avail=$((LOG_TOTAL_LINES[$_lc] - HEAD_LINES))
    [ "$_avail" -lt 0 ] && _avail=0
    if [ "$_avail" -le "$SHARE" ]; then
      LOG_ALLOC[$_lc]="$_avail"
      LEFTOVER=$((LEFTOVER + SHARE - _avail))
    else
      LOG_ALLOC[$_lc]="$SHARE"
    fi
  done

  LONG_CONTAINERS=0
  for _lc in "${LOG_CONTAINERS[@]}"; do
    _avail=$((LOG_TOTAL_LINES[$_lc] - HEAD_LINES))
    [ "$_avail" -gt "$SHARE" ] && LONG_CONTAINERS=$((LONG_CONTAINERS + 1))
  done

  if [ "$LONG_CONTAINERS" -gt 0 ] && [ "$LEFTOVER" -gt 0 ]; then
    BONUS=$((LEFTOVER / LONG_CONTAINERS))
    for _lc in "${LOG_CONTAINERS[@]}"; do
      _avail=$((LOG_TOTAL_LINES[$_lc] - HEAD_LINES))
      if [ "$_avail" -gt "$SHARE" ]; then
        LOG_ALLOC[$_lc]=$((LOG_ALLOC[$_lc] + BONUS))
        [ "${LOG_ALLOC[$_lc]}" -gt "$_avail" ] && LOG_ALLOC[$_lc]="$_avail"
      fi
    done
  fi

  # ── Write navigation header + logs per container ────────────────────────
  {
    echo ""
    echo ""
    echo ""
    echo "========================================================================"
    echo "NOSANA CONTAINER LOGS (${NUM_LOG_CONTAINERS} containers)"
    echo "========================================================================"
    echo "To jump to a specific container log, search for:"
    for _lc in "${LOG_CONTAINERS[@]}"; do
      printf "  === %s:    (%d lines)\n" "$_lc" "${LOG_TOTAL_LINES[$_lc]}"
    done
    echo "------------------------------------------------------------------------"
  } >> mylog.txt

  for _lc in "${LOG_CONTAINERS[@]}"; do
    _tmplog="${LOG_TMPFILES[$_lc]}"
    printf "  writing %s: head %d + tail %d of %d lines\n" \
      "$_lc" "$HEAD_LINES" "${LOG_ALLOC[$_lc]}" "${LOG_TOTAL_LINES[$_lc]}"
    {
      _shown=$((HEAD_LINES + LOG_ALLOC[$_lc]))
      [ "$_shown" -gt "${LOG_TOTAL_LINES[$_lc]}" ] && _shown="${LOG_TOTAL_LINES[$_lc]}"
      _omitted=$((LOG_TOTAL_LINES[$_lc] - _shown))
      if [ "$_omitted" -eq 0 ]; then
        _trim_note="100% OF LOG"
      else
        _trim_note="${_omitted} lines omitted"
      fi
      printf "\n\n\n=== %s: head %d + tail %d of %d cleaned lines (%s) ===\n" \
        "$_lc" "$HEAD_LINES" "${LOG_ALLOC[$_lc]}" "${LOG_TOTAL_LINES[$_lc]}" "$_trim_note"
      echo "--- HEAD (first ${HEAD_LINES} lines) ---"
      head -n "$HEAD_LINES" "$_tmplog"
      echo ""
      echo "--- TAIL (last ${LOG_ALLOC[$_lc]} lines) ---"
      tail -n "${LOG_ALLOC[$_lc]}" "$_tmplog"
    } >> mylog.txt
    rm -f "$_tmplog"
  done
  echo "  log collection complete"
fi
#--- END NOSANA NODE LOG TAILS ---

# ================================================
# === UPLOAD AND DISPLAY =========================
# ================================================
TEXT_FILE="mylog.txt"   # ← must exist

# ------------- mañana attitude (do not change) -------------
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

# Sanitize: strip any stray binary/control bytes so Slack shows inline text preview
perl -CSDA -pi -e 's/[^\x09\x0A\x0D\x20-\x7E\x{80}-\x{10FFFF}]//g' "$TEXT_FILE"
FILE_SIZE=$(wc -c < "$TEXT_FILE" | tr -d ' ')

# ------------- UPLOAD (both independent -- one failure doesn't block the other) -------------
printf "Uploading (%s bytes)...\n" "$FILE_SIZE"
ERRORS=""
UPLOAD_URL=""
SLACK_OK="false"

# ── Litterbox upload ─────────────────────────────────────────────────────
printf "  stage1: "
LB_RESPONSE=$(curl -s --max-time 120 -w "\n%{http_code}" -F "reqtype=fileupload" \
                   -F "time=$EXPIRATION" \
                   -F "fileToUpload=@$TEXT_FILE" \
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

# ── Slack upload ─────────────────────────────────────────────────────────
printf "  stage2: "
DISCORD_NAME_ESC=$(echo "$DISCORD_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Step 1: Get upload URL
GET_RESPONSE=$(curl -s --max-time 15 -X POST \
  -H "Authorization: Bearer $mana" \
  -F "filename=$SLACK_FILENAME" \
  -F "length=$FILE_SIZE" \
  https://slack.com/api/files.getUploadURLExternal)

UPLOAD_URL_SLACK=$(echo "$GET_RESPONSE" | jq -r '.upload_url // empty')
FILE_ID=$(echo "$GET_RESPONSE" | jq -r '.file_id // empty')
SLACK_ERR=$(echo "$GET_RESPONSE" | jq -r '.error // empty')

if [[ -z "$UPLOAD_URL_SLACK" || -z "$FILE_ID" ]]; then
    echo "FAILED (get URL: ${SLACK_ERR:-no upload_url returned})"
    ERRORS="${ERRORS}  Slack: get URL failed - ${SLACK_ERR:-no upload_url}\n"
else
    # Step 2: Upload file content
    curl -s --max-time 30 -X POST \
      -F "file=@$TEXT_FILE" \
      "$UPLOAD_URL_SLACK" > /dev/null

    # Step 3: Complete upload and share to channel
    # Include Litterbox link in message if available
    if [ -n "$UPLOAD_URL" ]; then
      SLACK_COMMENT="<@${USER_ID}> (link expires in ${EXPIRATION}): <${UPLOAD_URL}|${DISCORD_NAME_ESC}>"
    else
      SLACK_COMMENT="<@${USER_ID}> ${DISCORD_NAME_ESC} (Litterbox upload failed)"
    fi

    COMPLETE_RESPONSE=$(curl -s --max-time 15 -X POST \
      -H "Authorization: Bearer $mana" \
      -H "Content-type: application/json; charset=utf-8" \
      --data "{
        \"files\": [{\"id\":\"$FILE_ID\",\"title\":\"$SLACK_FILENAME\"}],
        \"channel_id\": \"$CHANNEL_ID\",
        \"initial_comment\": \"${SLACK_COMMENT}\"
      }" \
      https://slack.com/api/files.completeUploadExternal)

    SLACK_OK=$(echo "$COMPLETE_RESPONSE" | jq -r '.ok // "false"')
    SLACK_PERMALINK=$(echo "$COMPLETE_RESPONSE" | jq -r '.files[0].permalink // empty')
    SLACK_ERR2=$(echo "$COMPLETE_RESPONSE" | jq -r '.error // empty')

    if [[ "$SLACK_OK" == "true" ]]; then
        echo "OK"
    else
        echo "FAILED (complete: ${SLACK_ERR2:-unknown})"
        ERRORS="${ERRORS}  Slack: complete failed - ${SLACK_ERR2:-unknown}\n"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────
if [[ -z "$ERRORS" ]]; then
    echo "Both uploads OK"
elif [[ -n "$UPLOAD_URL" || "$SLACK_OK" == "true" ]]; then
    echo "Partial success:"
    echo -e "$ERRORS"
else
    echo "Both uploads FAILED:"
    echo -e "$ERRORS"
fi

echo "Done!"
echo ""
# Display summary only (up to GPU table; docker/podman/frpc logs are uploaded but not shown)
awk '/^podman version/{exit} {print}' mylog.txt

# =============================================================================
# LOGLIEFJE PROJECT RULES & INTENTIONS
# Keep this block at the end of the script for future AI coding sessions.
# =============================================================================
#
# ── CORE CONSTRAINTS ────────────────────────────────────────────────────────
# - No 3rd party apps can be installed. Only native Ubuntu v20-25 tools
#   (Desktop, Server, minimal, core).
# - Exception: jq is auto-installed if missing. It is required for parsing
#   Solana RPC JSON (live SOL/NOS balances) and Slack API responses (upload).
# - perl is native to all Ubuntu versions -- it is not 3rd party.
# - Script must work for hosts with 1 GPU or 8 GPUs.
# - Supported OSes: Ubuntu v20-25 (Desktop, Server, minimal, core).
#
# ── DOCKER LOG CLEANING ────────────────────────────────────────────────────
# - Docker logs use 2>/dev/null (stdout only) to skip stderr spinner
#   animations (170K+ lines of noise from Nosana CLI spinners).
# - Cleaned with perl -CSDA -pe (UTF-8 mode REQUIRED). Without -CSDA,
#   perl operates in byte mode and breaks multi-byte UTF-8 characters
#   like ✔ ✖ ⠋ into replacement chars (�).
# - NEVER use mawk (Ubuntu default awk) for log cleaning. mawk destroys
#   UTF-8 with [:print:] character class (treats it as ASCII-only).
# - Spinner collapse: keep from last ✔/✖ or last spinner char per line.
# - Truncate lines >300 chars (spinner/progress artifacts).
# - Remove timestamp-only blank lines (docker entries where content was
#   entirely ANSI codes; after stripping, only timestamp remains).
# - tr -d strips remaining control chars (0x00-0x08, 0x0B, 0x0C,
#   0x0E-0x1F, 0x7F). Preserves UTF-8 bytes (>= 0x80).
# - The output file MUST be clean text with zero binary bytes, or Slack
#   will force a file download instead of showing a browser preview link.
#
# ── CONTAINER DISCOVERY ────────────────────────────────────────────────────
# - Uses docker ps -a as PRIMARY (not fallback) to find both running AND
#   stopped containers with "nosana" anywhere in the container name.
# - This catches all naming conventions: nosana-node, nosana-node.gpu0,
#   nosana-node.gpu1, nosana-node1, nosana-mymachine, etc.
# - Last-resort fallback: docker inspect nosana-node (only catches that
#   exact literal name; used if docker ps -a returns nothing).
# - docker logs works on stopped containers -- wallet, markets, and full
#   log history are still accessible after docker stop.
# - Stopped containers show: exit code (0=clean stop, 137=OOM/killed,
#   1=error), how long it ran, and how long ago it stopped.
#
# ── WALLETS & BALANCES ─────────────────────────────────────────────────────
# - Each container has a unique wallet. One GPU per container currently.
#   Future multi-GPU containers (e.g. 4x4090) would still be one wallet
#   per container. Associative arrays handle dedup but in practice wallets
#   are unique per container.
# - Wallet extracted from HEAD of docker log (first 50 lines). The wallet
#   is printed once at container startup and never appears in recent tail.
# - First market: head -n 5000 of log (awk exits at first match).
# - Last market: tail 5000 searched bottom-up with tac.
# - SOL/NOS balances are LIVE queries via Solana RPC curl POST (not from
#   stale log data). This is why jq must be installed.
# - NOS token mint address: nosXBVoaCTtYdLvKY6Csb4AC8JCdQKKAaWYtx2ZMoo7
#
# ── RAPL CPU POWER MEASUREMENT ─────────────────────────────────────────────
# - Try modprobe intel_rapl_common / intel_rapl_msr / rapl if sysfs absent.
# - _read_sysfs() helper: tries direct cat, falls back to sudo -n cat
#   (non-interactive, won't hang if no passwordless sudo).
# - Energy delta method: read energy_uj, sleep 0.25s, read again,
#   compute watts = delta_energy / delta_time.
# - Handles counter wrap-around via max_energy_range_uj.
# - Fallback chain: RAPL sysfs -> hwmon power sensors -> sensors command
#   (skips amdgpu/nvidia sections to avoid double-counting GPU power).
# - Works on both Intel and AMD (kernel 5.8+ for AMD Zen).
#
# ── TIMESTAMPS & TIMEZONES ─────────────────────────────────────────────────
# - Docker timestamps (StartedAt, FinishedAt) are in UTC.
# - When converting with date -d, MUST append "UTC" to the string or
#   results are wrong for non-UTC timezones. This caused negative uptimes
#   for EST users (UTC-5) before the fix.
#
# ── UPLOAD ARCHITECTURE ────────────────────────────────────────────────────
# - Two independent uploads: Litterbox (stage1) and Slack (stage2).
# - One failure must NOT block the other. No exit 1 after stage1 failure.
# - Show actual error details: HTTP code + response body for Litterbox,
#   API .error field for Slack.
# - If Litterbox fails, Slack message adjusts (no broken Litterbox link).
# - Upload labels shown to user as "stage1" and "stage2" (no service names
#   or URLs exposed to the operator).
#
# ── USER DISPLAY ───────────────────────────────────────────────────────────
# - User sees: version, name prompt, "Collecting logs...", scan progress,
#   upload status, "Done!", then summary up to GPU table only.
# - Full data (podman ps, docker ps -a, frpc logs, container log tails)
#   is uploaded but NOT displayed to the user.
# - Display cutoff: awk '/^podman version/{exit} {print}' mylog.txt
# - Footnotes (<--) on key lines for operator guidance.
# - clear screen at script start.
#
# ── LOG TAIL BUDGET SYSTEM ─────────────────────────────────────────────────
# - 1GB max file size (Litterbox limit).
# - Single docker log read per container: clean to temp file, count from
#   temp (wc -l), then head+tail from temp. Fast and efficient.
# - Budget distributed fairly: short containers get all their lines,
#   leftover budget flows to longer containers.
# - HEAD_LINES=30 per container for startup info, rest allocated to tail.
# - Navigation header before logs lists all containers with line counts
#   and search terms (=== container_name:) for jumping in any text viewer.
#
# ── SCRIPT CONVENTIONS ─────────────────────────────────────────────────────
# - Version number format: v0.00.XX, incremented with each edit.
# - chmod +x applied to script file.
# - Discord name saved to ~/.logliefje_name for reuse across runs.
# - Container grep matches "nosana" anywhere in container name.
# - All commands are native to Ubuntu except jq (auto-installed).
# - The Nosana CLI uses \033[1G (cursor to column 1) for spinner
#   animations, NOT \r. This is why simple \r-based cleaning fails.
# - Bandwidth test uses Cloudflare (50MB max; 100MB returns HTTP 403).
#   Single TCP stream -- will always show lower than multi-stream Ookla.
# =============================================================================

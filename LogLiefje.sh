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
echo "log collector v0.00.62" >> mylog.txt   # ← incremented
cat mylog.txt

# ------------- CONFIG (DO NOT EDIT THESE) -------------
#CHANNEL_ID="C09AX202QD7" #production
CHANNEL_ID="C093HNDQ422" #test
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
printf "%-120s <--setting affects node, logs, dashboard\n" "Clock: $(timedatectl 2>/dev/null | awk -F': ' '/Time zone/{tz=$2} /synchronized/{sync=$2} /NTP service/{ntp=$2} END{printf "%s | Synced: %s | NTP: %s", tz, sync, ntp}')" && \
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
        "(since ${_start})" "$_c" "$_exit_code" "$_rd" "$_rh" "$_rm" "$_ad" "$_ah" "$_am"
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
  perl -pe '
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
      printf "\n\n\n=== %s: head %d + tail %d of %d cleaned lines ===\n" \
        "$_lc" "$HEAD_LINES" "${LOG_ALLOC[$_lc]}" "${LOG_TOTAL_LINES[$_lc]}"
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

LB_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$UPLOAD_URL")
if [[ "$LB_HTTP" != "200" ]]; then
    ERRORS="${ERRORS}  Litterbox: HTTP $LB_HTTP (expected 200)\n"
fi

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
echo ""
# Display summary only (up to GPU table; docker/podman/frpc logs are uploaded but not shown)
awk '/^podman version/{exit} {print}' mylog.txt

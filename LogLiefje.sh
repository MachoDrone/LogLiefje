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
echo "log collector v0.00.92" >> mylog.txt   # ← incremented
cat mylog.txt

# ------------- ARGUMENT PARSING -------------
TEST_MODE=false
NO_UPLOAD=false
FULL_LOGS=false
for arg in "$@"; do
  case "$arg" in
    --test)      TEST_MODE=true ;;
    --no-upload) NO_UPLOAD=true ;;
    --100)       FULL_LOGS=true ;;
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

# ------------- DISCORD NAME + OPERATOR ERROR PROMPTS (skip in --no-upload) --
if [ "$NO_UPLOAD" = false ]; then
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

  echo ""
  printf "\033[1;33mPaste the error you saw, or describe the issue.\033[0m\n"
  printf "\033[1;33mPress Enter twice when done:\033[0m\n"
  OPERATOR_ERROR=""
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && break
    OPERATOR_ERROR="${OPERATOR_ERROR:+${OPERATOR_ERROR}
}${_line}"
  done
fi

echo "Collecting logs..."

# ================================================
# === DATA COLLECTION (silent, to mylog.txt) =====
# ================================================

# ── Discover nosana-node containers via image-based detection ──────────────
# Returns outer|inner|logpath triples in NODE_PAIRS array.
# Outer: Docker containers running nosana/podman image
# Inner: Podman containers running nosana/nosana-node image (inside outer)
# Logpath: direct log file path inside the outer container
_discover_nosana_nodes() {
  NODE_PAIRS=()
  local outers outer inners inner logpath
  mapfile -t outers < <(timeout -k 1 5 docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep 'nosana/podman' | awk '{print $1}')
  for outer in "${outers[@]}"; do
    [ -z "$outer" ] && continue
    mapfile -t inners < <(timeout -k 1 5 docker exec "$outer" podman ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep 'nosana/nosana-node' | awk '{print $1}')
    for inner in "${inners[@]}"; do
      [ -z "$inner" ] && continue
      logpath="$(timeout -k 1 5 docker exec "$outer" podman inspect --format='{{.HostConfig.LogConfig.Path}}' "$inner" 2>/dev/null)"
      [[ "$logpath" = /* ]] || continue
      NODE_PAIRS+=("${outer}|${inner}|${logpath}")
    done
  done
}
_discover_nosana_nodes

_clean_docker_log() {
  perl -CSDA -pe '
    s/\e\[\??[0-9;]*[a-zA-Z]//g;
    s/\e//g;
    # Keep the timestamp for rule and error lines that share a spinner frame.
    s/^(\S+\s+(?:stdout|stderr)\s+[PF]\s+).*?[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏].*([✔✖])/$1$2/;
    s/^(\S+\s+(?:stdout|stderr)\s+[PF]\s+).*?[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]\s*/$1/ unless /[✔✖]/;
    $_ = substr($_, 0, 500) . "...\n" if length($_) > 500;
    $_ = "" if /^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s*$/;
  ' | tr -d '\000-\010\013\014\016-\037\177' | grep -av '^\s*$'
}

# Collapse consecutive identical lines: keep 1, summarise rest.
# Also cleans output: truncates timestamp to seconds, strips container-log
# prefix (stdout/stderr P/F), removes Braille spinners, collapses whitespace.
_dedup_consecutive() {
  perl -CSDA -ne '
    use Time::Local qw(timegm);
    sub utc_stamp {
      my ($stamp, $zone) = @_;
      return $stamp . "Z" if $zone eq "Z" || $zone =~ /^[+-]00:00$/;
      my ($year, $month, $day, $hour, $minute, $sec) = split(/[-T:]/, $stamp);
      my $epoch = eval { timegm($sec, $minute, $hour, $day, $month - 1, $year) };
      return $stamp . $zone unless defined $epoch;
      my ($sign, $hh, $mm) = $zone =~ /^([+-])(\d\d):(\d\d)$/;
      my $offset = ($hh * 60 + $mm) * 60 * ($sign eq "+" ? 1 : -1);
      my @utc = gmtime($epoch - $offset);
      return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $utc[5]+1900, $utc[4]+1, $utc[3], @utc[2,1,0]);
    }
    BEGIN { $prev = ""; $count = 0; }
    # normalise for comparison
    $norm = $_;
    $norm =~ s/^\d{4}-\d{2}-\d{2}T[\d:.+Z-]+\s+(?:stdout|stderr)\s+[PF]\s?//;
    $norm =~ s/[\x{2800}-\x{28FF}]//g;
    $norm =~ s/\s+/ /g;
    $norm =~ s/^\s+|\s+$//g;
    next if $norm eq "";
    # clean the output line (same transforms but keep truncated timestamp)
    $out = $_;
    $out =~ s/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d\d:\d\d)\s+(?:stdout|stderr)\s+[PF]\s?/utc_stamp($1,$2)." "/e;
    $out =~ s/[\x{2800}-\x{28FF}]//g;
    $out =~ s/\x{23F1}\s*//g;
    $out =~ s/\x{26A1}\s*//g;
    $out =~ s/[\x{2500}-\x{257F}\x{2580}-\x{259F}]+//g;
    $out =~ s/[ \t]+/ /g;
    $out =~ s/^\s+//;
    $out =~ s/\s+$/\n/;
    $out = "  $out";
    if ($norm eq $prev) {
      $count++;
    } else {
      printf "  [... above line repeated %d more times]\n", $count - 1 if $count > 1;
      $prev = $norm;
      $count = 1;
      print $out;
    }
    END {
      printf "  [... above line repeated %d more times]\n", $count - 1 if $count > 1;
    }
  ' | perl -ne '
    # Collapse ticker runs (Duration ticks, RESTARTING countdowns, etc.)
    # Keep only first + last real line per run.
    # NOTE: avoid !$var — Perl 5.38 negation bug returns truthy ref
    $is_tick = (/Duration:.*Max Duration:/ || /RESTARTING In \d+/ || /Downloading\s+\|.*\|.*\d+.*\//) ? 1 : 0;
    if ($is_tick) {
      if ($in_run) {
        $run_count++;
      } else {
        $first = $_;
        $in_run = 1;
        $run_count = 1;
      }
      $last_tick = $_;
      next;
    }
    if ($in_run && /^\s*\[\.\.\. above line repeated/) { next; }
    if ($in_run) {
      print $first;
      if ($run_count > 2) {
        printf "  [... %d ticks collapsed ...]\n", $run_count - 2;
        print $last_tick;
      } elsif ($run_count == 2) {
        print $last_tick;
      }
      $in_run = 0;
    }
    print;
    END {
      if ($in_run) {
        print $first;
        if ($run_count > 2) {
          printf "  [... %d ticks collapsed ...]\n", $run_count - 2;
          print $last_tick;
        } elsif ($run_count == 2) {
          print $last_tick;
        }
      }
    }
  '
}

# Keep the original startup excerpt in addition to the selected recent history.
_retain_recent_node_log() {
  local file=$1 cutoff=$2
  awk -v cutoff="$cutoff" '
    NR <= 29 { print; next }
    {
      line=$0; sub(/^[[:space:]]*/, "", line)
      if (line ~ /^[0-9]+-[0-9]+-[0-9]+T[0-9:]+Z /) {
        dated=1
        recent=(substr(line, 1, 19) >= cutoff)
      }
      if (dated && !recent) { omitted++; next }
      if (omitted) {
        printf "\n--- last 48 hours (%d older lines omitted) ---\n\n", omitted
        omitted=0
      }
      print
    }
    END { if (omitted) printf "\n--- %d older lines omitted ---\n", omitted }
  ' "$file" > "$file.recent" && mv -- "$file.recent" "$file"
}

MAX_FILE_BYTES=1073741824

# Stream retained FRPC logs separately from the small, time-sensitive probe window.
# This part also works on minimal installations without Python.
_ll_write_retained_frpc_logs() {
  local destination=$1 outers proxies outer label image proxy id path available status bytes
  local found=false
  : > "$destination" || return 1
  outers=$(timeout -k 1 5 docker ps --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}') || {
    echo "FRPC log capture unavailable: Docker inventory failed."
    return
  }
  while IFS=$'\t' read -r outer label image; do
    [[ "$image" =~ (^|/)nosana/podman(:|@|$) && "$outer" =~ ^[[:xdigit:]]{64}$ ]] || continue
    proxies=$(timeout -k 1 5 docker exec "$outer" podman ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}') || {
      printf 'FRPC log capture unavailable for %s: Podman inventory failed.\n' "$label"
      continue
    }
    while IFS=$'\t' read -r id proxy image; do
      [[ "$proxy" =~ ^frpc-api-[1-9A-HJ-NP-Za-km-z]{32,44}$ && "$id" =~ ^[[:xdigit:]]{64}$ ]] || continue
      [[ "$image" =~ (^|/)nosana/frpc(:|@|$) ]] || continue
      found=true
      path=$(timeout -k 1 5 docker exec "$outer" podman inspect --format '{{.HostConfig.LogConfig.Path}}' "$id") || path=""
      if [[ "$path" != /*/"$id"/userdata/ctr.log || "$path" == */../* ]]; then
        printf 'FRPC log unavailable for [%s] %s: path unverified.\n' "$label" "$proxy"
        continue
      fi
      available=$((MAX_FILE_BYTES - $(wc -c < "$destination") - 512))
      if (( available < 1 )); then
        printf 'FRPC log omitted for [%s] %s: report byte limit.\n' "$label" "$proxy"
        continue
      fi
      bytes=$(timeout -k 1 5 docker exec "$outer" stat -c %s -- "$path") || bytes=unknown
      printf '\n=== [%s] frpc-api logs ===\nContainer: %s [%s] | collected %s\n' \
        "$label" "$proxy" "${id:0:12}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$destination"
      if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > available )); then
        printf '[FRPC log truncated to most recent %s bytes.]\n' "$available" >> "$destination"
      fi
      timeout -k 2 60 docker exec "$outer" tail -c "$available" -- "$path" | perl -pe '
        s/\e\[[0-?]*[ -\/]*[@-~]//g;
        $pem = 1 if /-----BEGIN .*PRIVATE KEY-----/;
        $end = /-----END .*PRIVATE KEY-----/;
        $_ = "[redacted sensitive log line]\n" if $pem || /authorization|bearer\s+|(?:password|token|secret|private.?key|api.?key|signature|mnemonic|seed|auth\.\w+)\s*["\x27]?\s*[:=]/i;
        $pem = 0 if $end;
      ' >> "$destination"
      status=("${PIPESTATUS[@]}")
      if (( status[0] != 0 || status[1] != 0 )); then
        printf 'FRPC log incomplete for [%s] %s (read %s, filter %s).\n' "$label" "$proxy" "${status[0]}" "${status[1]}"
      fi
    done <<< "$proxies"
  done <<< "$outers"
  [[ "$found" = true ]] || echo "No matching API proxy found in the running wrappers."
}

# BEGIN LOGLIEFJE CONTAINER NETWORK REPORT
# Print the compact probe snapshot. The report's full FRPC log section is collected separately.
_ll_container_network_report() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Container network checks unavailable: python3 missing."
    return 0
  fi
  python3 - <<'LOGLIEFJE_NETWORK_PY' || echo "Container network checks incomplete."
import collections
import concurrent.futures
import datetime
import functools
import ipaddress
import json
import os
import re
import selectors
import subprocess
import time

HOST_MANAGER = 'host-manager.k8s.prd.nos.ci'
LOG_LIMIT = 65536
FORMAT = r'{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}'
LIST = ['ps', '-a', '--no-trunc', '--format', FORMAT]
WALLET = r'[1-9A-HJ-NP-Za-km-z]{32,44}'
Node = collections.namedtuple('Node', 'id name image state')


def safe_tool_error(raw, hosts):
    # Only expose DNS/connection diagnostics. Tool stderr sometimes includes a command, URL or credentials.
    words = set(('curl getent getaddrinfo hosts host hostname could not resolve resolving name or service known '
                 'temporary failure in resolution does lookup failed to connect connection refused cannot '
                 'server port after ms milliseconds timed out operation with bytes received no address '
                 'associated network is unreachable permission denied tool found timeout expired unknown '
                 'gethostbyname refused try again reset peer system error enotfound eai_again').split())
    allowed = {h.lower() for h in hosts} | words
    fallback = ''
    for line in raw.decode('utf-8','replace').splitlines():
        line = line.strip()
        if not line or len(line) > 240:
            continue
        recognized = next((s for s in ('could not resolve host','failed to connect','connection refused','timed out',
                          'name or service not known','temporary failure in name resolution','name does not resolve',
                          'no address associated','network is unreachable','permission denied','not found',
                          'enotfound','eai_again') if s in line.lower()),'')
        if not recognized:
            continue
        fallback = recognized
        if not re.fullmatch(r'[A-Za-z0-9 _.:,()\x27"-]+', line):
            continue
        tokens = re.findall(r'[A-Za-z0-9_.-]+', line.lower())
        if all(t in allowed or re.fullmatch(r'[0-9]{1,10}', t) or valid_ip(t) for t in tokens):
            return line
    return fallback


def valid_ip(value):
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def capture(args, seconds=5, size=32768, diagnostics=None, hosts=()):
    """Bound time and stdout even if a container tool hangs or floods its pipe."""
    until = time.monotonic() + seconds
    try:
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE if diagnostics is not None else subprocess.DEVNULL)
    except OSError:
        return 127, ''
    data, error = bytearray(), bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            if proc.stderr:
                selector.register(proc.stderr, selectors.EVENT_READ)
            while selector.get_map():
                left = until - time.monotonic()
                ready = selector.select(max(0, left))
                if left <= 0 or not ready:
                    return 124, ''
                for key, _ in ready:
                    block = os.read(key.fd, 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                    elif key.fileobj is proc.stderr:
                        error.extend(block[:max(0, 512-len(error))])
                    else:
                        if len(data) + len(block) > size:
                            return 125, ''
                        data.extend(block)
            rc = proc.wait(timeout=max(0, until-time.monotonic()))
            if rc and diagnostics is not None:
                detail = safe_tool_error(error,hosts)
                if detail:
                    diagnostics.append(detail)
            return rc, data.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        return 124, ''
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        proc.stdout.close()
        if proc.stderr:
            proc.stderr.close()


def inventory(command):
    rc, raw = capture(command + LIST, size=1024 * 1024)
    if rc:
        return None
    result = []
    for line in raw.splitlines():
        fields = line.split('\t')
        if (len(fields) == 4 and re.fullmatch(r'[0-9a-f]{64}', fields[0])
                and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', fields[1])):
            result.append(Node(*fields))
    return result


def image_is(item, name):
    return bool(re.fullmatch(r'(?:(?:registry\.hub\.|index\.)?docker\.(?:io|com)/)?nosana/'
                             + name + r'(?::[^@/]+)?(?:@sha256:[0-9a-f]{64})?', item.image))


def running(container):
    # Podman 4.x formats the State column as "Up 19 hours".
    state = container.state.lower()
    return state == 'running' or bool(re.match(r'^up(?:\s|$)',state)) and 'paused' not in state


def inspect(command, container, field):
    rc, value = capture(command + ['inspect', '--format', field, container.id])
    return value.strip() if not rc else ''


def config_route(text, wallet):
    # The generated TOML uses JSON-compatible strings, integers and string arrays.
    # A new serverAddr starts another configuration when parsing retained stdout.
    server, blocks, current = None, [], None
    for line in text.splitlines():
        line = line.strip()
        if line == '[[proxies]]':
            current = {}
            blocks.append(current)
            continue
        if line.startswith('['):
            current = None
            continue
        match = re.fullmatch(r'(serverAddr|name|localIp|localPort|customDomains)\s*=\s*(.+)', line)
        if not match:
            continue
        key, value = match.groups()
        try:
            value = json.loads(value)
        except ValueError:
            value = None
        if key == 'serverAddr':
            server, blocks, current = value, [], None
        elif current is not None:
            current[key] = value
    if not isinstance(server, str) or len(server) > 190:
        return None
    label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    if not re.fullmatch(r'(?:' + label + r'\.)+(?:nos\.ci|nosana\.io)', server):
        return None
    candidates = [b for b in blocks if b.get('name') == 'API-' + wallet]
    if len(candidates) != 1:
        return None
    block = candidates[0]
    alias, port, domains = (block.get(k) for k in ('localIp', 'localPort', 'customDomains'))
    if (not isinstance(alias, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,62}', alias)
            or type(port) is not int or not 1 <= port <= 65535
            or not isinstance(domains, list) or wallet + '.' + server not in domains):
        return None
    return {'wallet': wallet, 'server': server, 'alias': alias, 'port': port}


def time_ns(value):
    m = re.fullmatch(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)', value)
    if m:
        try:
            dt = datetime.datetime.fromisoformat(m[1] + ('+00:00' if m[3] == 'Z' else m[3]))
            return int(dt.timestamp()) * 10**9 + int((m[2] or '').ljust(9, '0'))
        except ValueError:
            pass
    return None


def current_log_config(log, start):
    earliest = time_ns(start)
    if earliest is None or earliest <= 0:
        return ''
    selected = []
    for line in log.splitlines():
        match = re.match(r'^(\S+) (?:stdout|stderr) F (.*)$', line)
        if match:
            timestamp = time_ns(match[1])
            if timestamp is not None and timestamp >= earliest:
                selected.append(match[2])
    return '\n'.join(selected)


def read_logs(outer_cmd, podman, proxy):
    field = inspect(podman, proxy, '{{.HostConfig.LogConfig.Path}}')
    # A file path reported by the daemon must identify this FRPC's own log.
    if not (field.startswith('/') and field.endswith('/' + proxy.id + '/userdata/ctr.log')
            and re.fullmatch(r'/[A-Za-z0-9_./-]+', field) and '..' not in field.split('/')):
        return '', 'unavailable (no verified container log path)'
    rc, data = capture(outer_cmd + ['tail', '-c', str(LOG_LIMIT + 1), field], size=LOG_LIMIT + 1)
    if rc:
        return '', 'unavailable (read error %s)' % rc
    # The byte tail can start inside a line or UTF-8 code point.
    if len(data.encode('utf-8')) >= LOG_LIMIT + 1:
        return data.partition('\n')[2], 'truncated (last 65536 bytes, complete lines)'
    return data, 'captured' if data.strip() else 'empty'


def networks(podman, item):
    try:
        value = json.loads(inspect(podman, item, '{{json .NetworkSettings.Networks}}'))
        return value if isinstance(value, dict) else {}
    except ValueError:
        return {}


def match_node(networks_for, nodes, proxy, alias):
    exact = [node for node in nodes if node.name == alias]
    if len(nodes) == 1 and exact:
        return exact[0], ''
    frp_networks = networks_for(proxy)
    matches = list(exact)
    for node in nodes:
        if node in exact:
            continue
        for key, conf in networks_for(node).items():
            if (key in frp_networks and isinstance(conf, dict)
                    and alias in (conf.get('Aliases') or [])):
                matches.append(node)
                break
    if len(matches) == 1:
        return matches[0], ''
    return None, 'ambiguous node alias' if matches else 'matching node unavailable'


def shared_node_ips(proxy_networks, node_networks):
    result = set()
    for network in proxy_networks.keys() & node_networks.keys():
        attachment = node_networks[network]
        if not isinstance(attachment, dict):
            continue
        values = [attachment.get('IPAddress'), attachment.get('GlobalIPv6Address')]
        for field in ('SecondaryIPAddresses', 'SecondaryIPv6Addresses'):
            secondary = attachment.get(field)
            if isinstance(secondary, list):
                values.extend(entry.get('Addr') for entry in secondary if isinstance(entry, dict))
        for value in values:
            if isinstance(value, str) and valid_ip(value):
                result.add(str(ipaddress.ip_address(value)))
    return result


NODE_CHECKS = r"""
const {lookup} = require('dns').promises;
const http = require('http'), https = require('https'), fs = require('fs');
const {isIP} = require('net');
const c = JSON.parse(process.argv[1]);
const clean = e => String(e.code || e.message || 'error').replace(/[^A-Za-z0-9 _-]/g,'').slice(0,80);
async function resolve(host) {
  let timer;
  try {
    const entries = await Promise.race([lookup(host, {all:true}),
      new Promise((_,reject) => {timer=setTimeout(()=>reject(new Error('DNS timeout')), 3000);})]);
    const addresses = [...new Set(entries.map(x => x.address).filter(isIP))].slice(0,8);
    return addresses.length ? addresses.join(', ') : 'failed (no addresses)';
  } catch(e) {
    const code=/^[A-Z0-9_]{1,32}$/.test(e.code||'') ? e.code : (e.message==='DNS timeout'?'DNS timeout':'lookup error');
    const syscall=['getaddrinfo','getnameinfo','queryA','queryAaaa'].includes(e.syscall) ? e.syscall : '';
    const name=e.hostname===host ? e.hostname : '';
    return 'failed ('+[code,syscall,name].filter(Boolean).join(' ')+')';
  }
  finally { clearTimeout(timer); }
}
function get(url, info) {
  return new Promise(resolve => {
    const limit = info ? 65536 : 2048;
    let done=false, timer;
    const finish = value => {if (!done) {done=true; clearTimeout(timer); resolve(value);}};
    const req = (url.startsWith('https:') ? https : http).get(url, res => {
      const parts=[]; let size=0; const status='HTTP ' + res.statusCode;
      res.on('data', part => {
        size += part.length;
        if (size > limit) { finish(status + ', body exceeds limit'); req.destroy(); }
        else { parts.push(part); }
      });
      res.on('end', () => {
        let body;
        try {body=JSON.parse(Buffer.concat(parts).toString());}
        catch {finish(status + ', invalid JSON'); return;}
        const object=body!==null && typeof body==='object' && !Array.isArray(body);
        const valid = info ? object : body===c.wallet;
        const detail = info ? (object ? 'JSON object' : 'invalid JSON object')
                            : (valid ? 'identity matched' : 'WRONG identity');
        finish(status + ', ' + detail + (res.statusCode === 200 && valid ? ' (pass)' : ' (fail)'));
      });
      res.on('aborted', () => finish(status + ', response aborted'));
      res.on('error', e => finish(status + ', ' + clean(e)));
    });
    timer=setTimeout(()=>{finish('failed (HTTP timeout)');req.destroy();}, 6000);
    req.on('error', e => finish('failed (' + clean(e) + ')'));
  });
}
(async()=>{
  let resolvers=[];
  try {resolvers=fs.readFileSync('/etc/resolv.conf','utf8').split(/\r?\n/)
    .map(x=>(/^\s*nameserver\s+(\S+)/.exec(x)||[])[1]).filter(x=>x && isIP(x)).slice(0,8);}
  catch {}
  const checks=[['resolver', () => Promise.resolve(resolvers.join(', ') || 'unavailable')],
                ['DNS Host Manager ' + c.manager, () => resolve(c.manager)]];
  if(c.wallet) {
    checks.push(['DNS FRP server ' + c.server, () => resolve(c.server)]);
    const bases=[['loopback','http://127.0.0.1:'+c.port], ['public','https://'+c.wallet+'.'+c.server]];
    for (const [view,base] of bases) {
      checks.push([view+' /', () => get(base+'/', false)], [view+' /node/info', () => get(base+'/node/info', true)]);
    }
  }
  const result = await Promise.all(checks.map(async ([name,run]) => {
    const start=process.hrtime.bigint();
    const value=await run();
    return [name, value+' ['+Number((process.hrtime.bigint()-start)/1000000n)+' ms]'];
  }));
  process.stdout.write(JSON.stringify(result),()=>process.exit(0));
})().catch(()=>process.exit(1));
"""


def node_checks(podman, node, route=None):
    if not running(node):
        return ['node checks skipped: container ' + node.state]
    target = dict(route or {}, manager=HOST_MANAGER)
    cmd = podman + ['exec', node.id, 'node', '-e', NODE_CHECKS, json.dumps(target)]
    start = time.monotonic()
    rc, raw = capture(cmd, seconds=9, size=8192)
    if rc:
        return ['node checks unavailable (%s) [%d ms]' % (failure(rc), (time.monotonic()-start)*1000)]
    try:
        results = ['node ' + k + ': ' + v for k, v in json.loads(raw)
                   if isinstance(k,str) and isinstance(v,str)]
    except (ValueError, TypeError):
        return ['node checks unavailable (invalid probe output)']
    if not route:
        results.append('node route-specific DNS/API skipped: no verified FRPC route')
    return results


def addresses(lines, resolvers=False):
    values = []
    for line in lines.splitlines():
        parts = line.split()
        if not parts or (resolvers and (len(parts) < 2 or parts[0] != 'nameserver')):
            continue
        try:
            ip = str(ipaddress.ip_address(parts[1 if resolvers else 0]))
        except ValueError:
            continue
        if ip not in values:
            values.append(ip)
    return ', '.join(values[:8])


def failure(rc, details=()):
    reason = {124:'timeout', 137:'terminated', 143:'timed out or terminated',
              126:'tool unavailable', 127:'tool unavailable', 125:'exec or output limit'}.get(rc)
    explanation = ', '.join(filter(None, (reason,*details)))
    return 'exit %s%s' % (rc, ', ' + explanation if explanation else '')


def direct_dns(cmd, alias, record_type, expected_ips):
    # Query the exact alias through FRPC's resolver, even when it has a DNS search suffix.
    absolute_alias = alias if alias.endswith('.') else alias + '.'
    rc, text = capture(cmd + ['timeout', '4', 'nslookup', '-type=' + record_type, absolute_alias],
                       seconds=6, size=8192)
    # Both BusyBox and BIND print the resolver's address before the first Name:.
    # A resolver header by itself is also a valid response to a query with no records.
    answers = set()
    in_answer = False
    for line in text.splitlines():
        key, sep, value = line.strip().partition(':')
        if key == 'Name' and sep:
            in_answer = True
        elif key == 'Server' and sep:
            in_answer = False
        elif in_answer and key == 'Address' and valid_ip(value.strip()):
            ip = ipaddress.ip_address(value.strip())
            if ip.version == (4 if record_type == 'A' else 6):
                answers.add(str(ip))

    if answers:
        if not expected_ips:
            comparison = 'node IP comparison unavailable'
        elif answers <= expected_ips:
            comparison = 'matches node'
        else:
            comparison = 'includes an address outside the matched node'
        detail = ', incomplete query' if rc else ''
        return ', '.join(sorted(answers)) + ' (' + comparison + detail + ')'
    error = re.search(r":\s*(NXDOMAIN|SERVFAIL|REFUSED|FORMERR|NOTIMP)\s*$", text, re.M)
    if error:
        return error[1]
    if 'no servers could be reached' in text.lower():
        return 'unavailable (no DNS server responded)'
    if not rc and re.search(r'^Server:\s*\S', text, re.M):
        return 'no ' + record_type + ' address records'
    return 'unavailable (' + (failure(rc) if rc else 'unrecognized nslookup output') + ')'


def hosts_entry(cmd, alias):
    # Only extract addresses for the route alias. Other hostnames and comments stay in FRPC.
    select_alias = (r'{ sub(/#.*/, ""); for (i=2; i<=NF; i++) '
                    r'if (tolower($i)==tolower(alias)) { print $1; break } }')
    rc, text = capture(cmd + ['awk', '-v', 'alias=' + alias, select_alias, '/etc/hosts'], size=4096)
    if rc:
        return 'unavailable (' + failure(rc) + ')'
    if not text.strip():
        return 'no entry'
    return addresses(text) or 'unavailable (invalid address)'


def frp_checks(podman, proxy, route, node, expected_ips=frozenset()):
    if not running(proxy):
        return ['FRPC checks skipped: container ' + proxy.state]
    cmd = podman + ['exec', proxy.id]
    def read_resolvers():
        rc, text = capture(cmd + ['cat', '/etc/resolv.conf'], size=8192)
        return addresses(text, True) or ('unavailable (' + failure(rc) + ')' if rc else 'unavailable')
    def dns(host):
        errors = []
        rc, text = capture(cmd + ['timeout', '4', 'getent', 'hosts', host], size=4096, diagnostics=errors, hosts=(host,))
        if rc:
            return 'failed (' + failure(rc,errors) + ')'
        return addresses(text) or 'failed (no addresses)'
    def root():
        # Curl's response and size are bounded again by the outer process. No body is reported.
        url = 'http://%s:%s/' % (route['alias'], route['port'])
        errors = []
        rc, text = capture(cmd + ['curl','--silent','--show-error','--noproxy','*','--connect-timeout','3',
                                 '--max-time','6','--max-filesize','2048','--proto','=http',
                                 '--write-out','\n%{http_code}',url], seconds=8, size=2052, diagnostics=errors,
                           hosts=(route['alias'],))
        if rc:
            return 'failed (' + failure(rc,errors) + ')'
        text, separator, status = text.rpartition('\n')
        if not separator or not re.fullmatch(r'\d{3}', status):
            return 'failed (invalid HTTP result)'
        try:
            body = json.loads(text)
        except ValueError:
            return 'HTTP ' + status + ', invalid JSON'
        expected = route['wallet']
        matched = body == expected
        result = ' (pass)' if matched and status == '200' else ' (fail)'
        return 'HTTP ' + status + (', identity matched' if matched else ', WRONG identity') + result
    def timed(call, *args):
        start = time.monotonic()
        value = call(*args)
        return value + ' [%d ms]' % ((time.monotonic()-start)*1000)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=7) as pool:
        tasks = [('FRPC resolver', pool.submit(timed,read_resolvers))]
        if route:
            tasks.append(('FRPC DNS server ' + route['server'], pool.submit(timed,dns,route['server'])))
        if node and route:
            alias = route['alias']
            results.append('Node IP on networks shared with FRPC: ' +
                           (', '.join(sorted(expected_ips)) or 'unavailable (no active shared-network IP verified)'))
            tasks.append(('FRPC DNS node alias ' + alias, pool.submit(timed, dns, alias)))
            if not valid_ip(alias):
                for kind in ('A', 'AAAA'):
                    tasks.append(('FRPC direct DNS ' + kind + ' ' + alias,
                                  pool.submit(timed, direct_dns, cmd, alias, kind, expected_ips)))
            else:
                results.append('FRPC direct DNS skipped: route target is an IP address')
            tasks.extend([('FRPC /etc/hosts ' + alias, pool.submit(timed, hosts_entry, cmd, alias)),
                          ('FRPC to node /', pool.submit(timed,root))])
        results.extend(key + ': ' + task.result() for key,task in tasks)
    if not route:
        results.append('FRPC route-specific DNS/API skipped: no verified route')
    elif not node:
        results.append('FRPC node-alias DNS/API skipped: node association unverified')
    return results


def report():
    outers = inventory(['docker'])
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
    print('Container DNS/API evidence (operator side) ' + stamp)
    if outers is None:
        print('Docker inventory unavailable; container checks skipped.')
        return
    wrappers = [o for o in outers if image_is(o, 'podman')]
    if not wrappers:
        print('No Nosana Docker/Podman wrapper found; container checks skipped.')
    for outer in wrappers:
        print('Wrapper %s [%s] %s' % (outer.name, outer.id[:12], outer.state))
        if not running(outer):
            print('  FRPC capture and live checks unavailable: wrapper ' + outer.state)
            continue
        outer_cmd = ['docker','exec',outer.id]
        podman = outer_cmd + ['podman']
        items = inventory(podman)
        if items is None:
            print('  Podman inventory unavailable; FRPC capture and checks skipped.')
            continue
        nodes = [n for n in items if image_is(n, 'nosana-node')]
        proxies = [p for p in items if image_is(p, 'frpc') and re.fullmatch('frpc-api-' + WALLET,p.name)]
        if not proxies:
            print('  No matching FRPC container found; FRPC log capture unavailable.')

        # Reuse the same network attachments when matching and comparing pairs in this wrapper.
        @functools.lru_cache(maxsize=None)
        def networks_for(item):
            return networks(podman, item)

        seen = set()
        for proxy in proxies:
            wallet = proxy.name[len('frpc-api-'):]
            log, status = read_logs(outer_cmd, podman, proxy)
            print('  %s [%s] %s; FRPC history window (64 KiB) %s' % (proxy.name,proxy.id[:12],proxy.state,status))
            if log.strip():
                print('  Retained lines: %d registration success, %d route conflict' %
                      (sum('start proxy success' in s for s in log.splitlines()),
                       sum('router config conflict' in s for s in log.splitlines())))
            # Read only the generated route fields. Never print configuration or container environments.
            config, route = '', None
            if running(proxy):
                sniff = (r'/^[[:space:]]*\[/ {if ($0 ~ /^[[:space:]]*\[\[proxies\]\][[:space:]]*$/) '
                         r'print "[[proxies]]"; else print "[other]"; next} '
                         r'/^[[:space:]]*(serverAddr|name|localIp|localPort|customDomains)[[:space:]]*=/')
                rc, config = capture(podman + ['exec',proxy.id,'awk',sniff,'/etc/frp/frpc.toml'],size=16384)
                if not rc:
                    route = config_route(config,wallet)
            source = 'active config'
            if not config.strip():
                start_value = inspect(podman,proxy,'{{json .State.StartedAt}}')
                try:
                    start = json.loads(start_value)
                except ValueError:
                    start = start_value  # Some runtimes render the timestamp without JSON quotes.
                route = config_route(current_log_config(log,start if isinstance(start,str) else ''),wallet)
                source = 'same-startup log'
            node, reason = match_node(networks_for,nodes,proxy,route['alias']) if route else (None,'no verified API route')
            expected_ips = set()
            if route:
                print('  API route (%s): %s.%s -> %s:%d' %
                      (source,wallet,route['server'],route['alias'],route['port']))
            if node:
                seen.add(node.id)
                print('  Node %s [%s] %s' % (node.name,node.id[:12],node.state))
                if running(proxy) and running(node):
                    expected_ips = shared_node_ips(networks_for(proxy), networks_for(node))
            else:
                print('  Node association unavailable: ' + reason)
            print('  Live probe start UTC: ' + datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds'))
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                jobs = [pool.submit(frp_checks,podman,proxy,route,node,expected_ips)]
                if node:
                    jobs.append(pool.submit(node_checks,podman,node,route))
                for job in jobs:
                    for line in job.result():
                        print('    ' + line)
        for node in nodes:
            if node.id not in seen:
                print('  Unpaired node %s [%s] %s' % (node.name,node.id[:12],node.state))
                for line in node_checks(podman,node):
                    print('    ' + line)


report()
LOGLIEFJE_NETWORK_PY
}
# END LOGLIEFJE CONTAINER NETWORK REPORT

# BEGIN QUALIFICATION REPORT
# One instance's complete cleaned log, before the 48-hour and report-size trims.
# Optional second argument is the inclusive UTC cutoff for timeline entries.
_qualification_report() {
  perl -CSDA - "$1" "${2:-}" <<'QUALIFICATION_PERL'
use strict;
use warnings;
use utf8;
use File::Temp qw(tempfile);
use POSIX qw(strftime);
use Time::Local qw(timegm);

my ($path, $cutoff) = @ARGV;
open my $log, '<:encoding(UTF-8)', $path or die "Cannot read qualification log: $!\n";
$cutoff =~ s/Z$//;
my $iso = qr/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)?/;
my $number = qr/[0-9]+(?:\.[0-9]+)?/;
my ($first_target, $last_target, $first_legacy, $last_legacy);
my ($obs, $phase, $rule_index, $await_label);
my ($rows) = tempfile(TMPDIR => 1, UNLINK => 1);
binmode $rows, ':encoding(UTF-8)';
my ($outside, $observed, $operational) = (0, 0, 0);

# Normalize known offsets. Some old cleaning paths discarded the time zone.
sub clock_time {
    my ($stamp) = @_;
    return ('time unavailable', '') unless $stamp;
    my ($base, $zone) = $stamp =~ /^(.{19})(?:\.\d+)?(Z|[+-]\d\d:\d\d)?$/;
    return ("$base (zone unknown)", '') unless defined $zone;
    return ("${base}Z", $base) if $zone =~ /^(?:Z|[+-]00:00)$/;
    my ($y, $m, $d, $h, $min, $s) = $base =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)$/;
    my ($sign, $offset_h, $offset_m) = $zone =~ /^([+-])(\d\d):(\d\d)$/;
    my $offset = ($offset_h * 60 + $offset_m) * 60;
    my $epoch = eval { timegm($s, $min, $h, $d, $m-1, $y) };
    return ($stamp, '') unless defined $epoch;
    my $utc = strftime('%Y-%m-%dT%H:%M:%S', gmtime($epoch - ($sign eq '+' ? $offset : -$offset)));
    return ("${utc}Z", $utc);
}

sub target_seen {
    my ($label) = @_;
    $first_target //= $label;
    $last_target = $label;
    $obs->{target} = $label;
}

sub finish {
    return unless $obs;
    my ($stamp, $utc) = clock_time($obs->{stamp});
    if (keys(%$obs) == 1) {
        # A bare header can remain at a truncation boundary.
    } elsif ($cutoff && $utc && $utc lt $cutoff) {
        ++$outside;
    } else {
        my @details;
        push @details, "target=$obs->{target}" if defined $obs->{target};
        push @details, "benchmark ID=$obs->{id}" if defined $obs->{id};
        push @details, "measurement time=$obs->{measured_at}" if defined $obs->{measured_at};
        if (my $speeds = $obs->{speeds}) {
            my @pairs;
            for my $engine (qw(primary fast ookla libre)) {
                next unless exists $speeds->{$engine};
                my $down = $speeds->{$engine}{download} // '?';
                my $up = $speeds->{$engine}{upload} // '?';
                push @pairs, "$engine=$down/$up";
            }
            push @details, 'Mbps down/up: ' . join(' ', @pairs);
        }
        push @details, "required passed=$obs->{counts}" if defined $obs->{counts};
        push @details, @{$obs->{checks} // []};
        for my $key (qw(download upload)) {
            push @details, "reported average(${key}_mbps)=$obs->{averages}{$key}"
                if defined $obs->{averages}{$key};
        }
        push @details, "admission=$obs->{admission}" if defined $obs->{admission};
        if ($obs->{decision_stamp}) {
            my ($decided) = clock_time($obs->{decision_stamp});
            push @details, "decision observed=$decided" if $decided ne $stamp;
        }
        push @details, "next eligible=$obs->{next}" if defined $obs->{next};
        if (@details) {
            print {$rows} '  ', $stamp, ' | ', join(' | ', @details), "\n" or die "Cannot spool qualification timeline: $!\n";
            ++$observed;
        }
    }
    undef $obs;
    undef $phase;
    undef $rule_index;
    undef $await_label;
}

sub begin_decision {
    my ($stamp, $same_error) = @_;
    finish() if $obs && defined $obs->{admission} && !$same_error;
    if ($obs && $cutoff) {
        my (undef, $start) = clock_time($obs->{stamp});
        my (undef, $decision) = clock_time($stamp);
        finish() if $start && $decision && $start lt $cutoff && $decision ge $cutoff;
    }
    my $has_evaluation = $obs && keys(%$obs) > 1;
    $obs //= { stamp => $stamp };
    $obs->{decision_stamp} //= $stamp;
    $phase = 'decision';
    return $has_evaluation;
}

sub operation {
    my ($kind, $value, $stamp) = @_;
    my ($display, $utc) = clock_time($stamp);
    return if $cutoff && $utc && $utc lt $cutoff;
    print {$rows} "  $display | $kind=$value\n" or die "Cannot spool qualification timeline: $!\n";
    ++$operational;
}

while (my $line = <$log>) {
    chomp $line;
    next unless $obs || $line =~ /LATEST MEASUREMENTS|TARGET MARKET|Optional thresholds|Grid recommended|Node currently meets|NodeNotQualifiedError|Node does not (?:qualify|meet the minimum requirements)|access was granted|QUEUED\s+In market|Could not join market|has claimed job|started successfully|group:network|network\.(?:download|upload)_mbps|Benchmark ID:/i;
    $line =~ s/^\s+|\s+$//g;
    my ($stamp) = $line =~ s/^($iso)(?:\s+|$)// ? $1 : undef;
    $line =~ s/^(?:stdout|stderr) [PF]\s*//;
    $line =~ s/^\s+|\s+$//g;
    next if $line eq '' || $line =~ /^\[\.\.\./;

    if ($line =~ /\bGrid recommended\s+([1-9A-HJ-NP-Za-km-z]{32,44})(?![1-9A-Za-z])/) {
        my $address = $1;
        $first_legacy //= $address;
        $last_legacy = $address;
        finish();
        operation('legacy recommendation', $address, $stamp);
        next;
    }
    if ($line =~ /^Wallet:/i) {
        finish();
        next;
    }
    if ($line eq 'LATEST MEASUREMENTS') {
        finish() unless ($phase // '') eq 'metadata';
        $obs //= { stamp => $stamp };
        $phase = 'measurements';
        next;
    }
    if ($line eq 'TARGET MARKET') {
        finish() unless ($phase // '') =~ /^(?:metadata|measurements)$/;
        $obs //= { stamp => $stamp };
        $phase = 'required';
        $await_label = 1;
        next;
    }
    if ($await_label) {
        undef $await_label;
        if ($line =~ /^[\w][\w .&'()\/+_\-]{0,150}$/ &&
            $line !~ /^(?:Optional thresholds|Running |Node |Starting |Collecting |Error\b|Could not |Waiting )/i) {
            target_seen($line);
            next;
        }
    }
    if ($line =~ /^(?:[•*]\s*)?network\.(download|upload)_mbps(?:_(fast|libre|ookla))?\s+($number|null|N\/A)$/i) {
        my ($leg, $engine, $value) = (lc $1, lc($2 // 'primary'), $3);
        finish() if $obs && ($phase // '') !~ /^(?:metadata|measurements)$/;
        $obs //= { stamp => $stamp };
        $phase = 'measurements';
        $obs->{speeds}{$engine}{$leg} = $value;
        next;
    }
    if ($line =~ /^Benchmark ID:\s*([A-Za-z0-9_-]{1,128})$/i) {
        my $id = $1;
        finish() if $obs && (defined $obs->{id} || ($phase // '') !~ /^(?:metadata|measurements)$/);
        $obs //= { stamp => $stamp };
        $phase //= 'metadata';
        $obs->{id} = $id;
        next;
    }
    if ($obs && $line =~ /^(?:Sample timestamp|Measurement time(?:stamp)?):\s*($iso)$/i) {
        $obs->{measured_at} = $1;
        next;
    }
    if ($obs && $line =~ /^(?:Evaluated averages?\s*:\s*)?average\((?:download|upload)_mbps\)\s*[:=]/i) {
        while ($line =~ /average\((download|upload)_mbps\)\s*[:=]\s*($number)\b/ig) {
            $obs->{averages}{lc $1} = $2;
        }
        next;
    }
    if ($line eq 'Optional thresholds') {
        $obs //= { stamp => $stamp };
        $phase = 'optional';
        undef $rule_index;
        next;
    }
    next if $obs && $line eq '(do not block market access)';
    if ($line =~ /^(\[FAIL\]|\[OK\]|[✔✓✖✗])\s+([a-z][\w.:\[\]-]*)(?:\s+(.+))?$/) {
        my ($mark, $key, $value) = ($1, $2, $3);
        if (($phase // '') =~ /^(?:required|optional)$/ || $key eq 'group:network') {
            $obs //= { stamp => $stamp };
            undef $rule_index;
            my $scope = $phase // 'unclassified';
            $scope = 'unclassified' unless $scope =~ /^(?:required|optional)$/;
            my $failed = $mark =~ /^(?:\[FAIL\]|[✖✗])$/;
            if ($failed || $scope eq 'optional' || $key eq 'group:network') {
                my $text = "$scope " . ($failed ? 'failed' : 'passed') . "=$key";
                $text .= " (reported $value)" if defined $value;
                push @{$obs->{checks}}, $text;
                $rule_index = $#{$obs->{checks}};
            }
            next;
        }
    }
    if ($obs && $line =~ /^rule:\s*(.+)$/) {
        my $rule = $1;
        $rule =~ s/≥/>=/g;
        $rule =~ s/≤/<=/g;
        $obs->{checks}[$rule_index] .= " ($rule)" if defined $rule_index;
        undef $rule_index;
        next;
    }
    if ($line =~ /^Node currently meets (all (\d+)|(\d+) of (\d+)) market requirements for (.+?)\s*(?:\s+[—–-]?\s*\d+ still need improvement)?$/) {
        my ($passed, $total, $name) = (defined $2 ? $2 : $3, $2 // $4, $5);
        finish() if $obs && defined $obs->{counts};
        $obs //= { stamp => $stamp };
        target_seen($name);
        $obs->{counts} = "$passed/$total";
        $phase = 'feedback';
        next;
    }
    if ($line =~ /^(?:Error Name:\s*)?NodeNotQualifiedError\b|^(?:Message:\s*)?Node does not (?:qualify for a market yet|meet the minimum requirements for any market)/) {
        my $name = $line =~ /^(?:Error Name:\s*)?NodeNotQualifiedError\b/;
        my $same_error = $obs && $obs->{await_error_message} && $line =~ /^(?:Message:\s*)?Node does not meet the minimum requirements/;
        begin_decision($stamp, $same_error);
        $obs->{admission} = $name || $same_error ? 'no market (NodeNotQualifiedError)' : 'no market';
        $obs->{await_error_message} = $name;
        $obs->{next} = $1 if $line =~ /Next eligible retest at ($iso)/;
        next;
    }
    if ($line =~ /^Some thresholds .*but access was granted\b/) {
        my $has_evaluation = begin_decision($stamp, 0);
        $obs->{admission} = 'granted' if $has_evaluation;
        finish();
        operation('explicit access', 'granted', $stamp);
        next;
    }

    my $message = $line;
    $message =~ s/^(?:\[OK\]|[✔✓])\s+//;
    if ($message =~ /^QUEUED\s+In market\s+(\S+)(?: at position (\d+\/\d+))?/i) {
        finish();
        operation('queued in market', "$1" . (defined $2 ? " at position $2" : ''), $stamp);
    } elsif ($line =~ /^(?:(?:\[FAIL\]|[✖✗])\s+)?Could not join market$/) {
        finish();
        operation('queue entry', 'failed', $stamp);
    } elsif ($message =~ /^Node has claimed job ([\w-]+)\b/) {
        finish();
        operation('job claimed', $1, $stamp);
    } elsif ($message =~ /^Job ([\w-]+) started successfully\b/) {
        finish();
        operation('job started', $1, $stamp);
    } elsif ($obs && ($phase // '') eq 'measurements' &&
             $line =~ /^(?:[•*]\s+|[a-z][a-z0-9_.:\[\]-]+\s+\S)/) {
        # Other flattened fields in the same native measurement table.
        next;
    } elsif ($obs && $line !~ /^(?:=+|Timestamp:)/) {
        finish();
    }
}
finish();

printf "First observed target: %s\n", $first_target // 'not observed';
printf "Last observed target: %s\n", $last_target // 'not observed';
printf "First legacy recommendation: %s\n", $first_legacy // 'not observed';
printf "Last legacy recommendation: %s\n", $last_legacy // 'not observed';
print "Qualification timeline (log observations; repeated readings can appear on retries)\n";
print "  A missing benchmark ID or evaluated average was unavailable in that log block. ? marks an unreported direction.\n" if $observed;
printf "  %d older observation%s outside the UTC selection.\n", $outside, $outside == 1 ? '' : 's' if $outside;
print "  No qualification events observed in selection.\n" unless $observed || $operational;
seek $rows, 0, 0 or die "Cannot read qualification timeline: $!\n";
while (my $row = <$rows>) { print $row }
QUALIFICATION_PERL
}
# END QUALIFICATION REPORT


report_work=$(mktemp -d) || { echo "Cannot create diagnostic scratch directory" >&2; exit 1; }
trap 'rm -rf -- "$report_work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Capture reachability before scanning large logs or measuring host bandwidth.
_ll_container_network_report > "$report_work/network.txt"
_ll_write_retained_frpc_logs "$report_work/frpc.log" >> "$report_work/network.txt"
log_cutoff=""
if [ "$FULL_LOGS" = false ]; then
  log_cutoff=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%S)
fi

# Reuse NODE_PAIRS from discovery
NUM_LOG_CONTAINERS=${#NODE_PAIRS[@]}

if [ "$NUM_LOG_CONTAINERS" -gt 0 ]; then
  echo ""
  declare -A LOG_TOTAL_LINES LOG_TMPFILES QUALIFICATION_REPORTS
  _total_all=0
  _pass=0

  # ── Single scan: clean once to temp file, count from temp ──────────────
  for _pair in "${NODE_PAIRS[@]}"; do
    IFS='|' read -r _outer _inner _logpath <<< "$_pair"
    _label="[${_outer}] ${_inner}"
    _pass=$((_pass + 1))
    printf "  scanning %s (%d/%d)...\r" "$_label" "$_pass" "$NUM_LOG_CONTAINERS"
    _tmplog="$report_work/node-$_pass.log"
    docker exec "$_outer" cat "$_logpath" 2>/dev/null | _clean_docker_log | _dedup_consecutive > "$_tmplog"
    _read_status=${PIPESTATUS[0]}
    QUALIFICATION_REPORTS[$_pair]="$report_work/qualification-$_pass.txt"
    if ! _qualification_report "$_tmplog" "$log_cutoff" > "${QUALIFICATION_REPORTS[$_pair]}"; then
      printf '%s\n' 'First observed target: unavailable' 'Last observed target: unavailable' \
        'First legacy recommendation: unavailable' 'Last legacy recommendation: unavailable' \
        'Qualification timeline unavailable: could not process the retained node log.' > "${QUALIFICATION_REPORTS[$_pair]}"
    fi
    if (( _read_status != 0 )); then
      printf 'Node log read incomplete (docker exit %d).\n' "$_read_status" >> "${QUALIFICATION_REPORTS[$_pair]}"
    fi
    if [[ -n "$log_cutoff" ]]; then
      _retain_recent_node_log "$_tmplog" "$log_cutoff"
    fi
    LOG_TMPFILES[$_pair]="$_tmplog"
    LOG_TOTAL_LINES[$_pair]=$(wc -l < "$_tmplog")
    _total_all=$((_total_all + LOG_TOTAL_LINES[$_pair]))
  done
  printf "  scan complete: %d useful lines across %d containers              \n" "$_total_all" "$NUM_LOG_CONTAINERS"

fi

#--- THE WALLET, MARKET RECOMMENDATIONS, AND LIVE BALANCES ---
NOS_MINT="nosXBVoaCTtYdLvKY6Csb4AC8JCdQKKAaWYtx2ZMoo7"
SOLANA_RPC="https://api.mainnet-beta.solana.com"

# Strip ANSI escape codes and control chars from piped input
_strip_ansi() { awk '{ gsub(/\r/,""); gsub(/\033\[[0-9;]*[[:alpha:]]/,""); print }' | tr -d '\033\000-\010\013\014\016-\037\177'; }

if [ ${#NODE_PAIRS[@]} -eq 0 ]; then
  {
    echo "Host: N/A (no nosana containers found)"
    echo "First Market Recommended: N/A"
    echo "Last Market Recommended: N/A"
  } >> mylog.txt
else
  # Track unique wallets and which containers share them
  declare -A W_CTRS W_OUTER W_LOGPATH NODE_WALLET
  declare -a W_ORD

  for _pair in "${NODE_PAIRS[@]}"; do
    IFS='|' read -r _outer _inner _logpath <<< "$_pair"
    _label="[${_outer}] ${_inner}"

    # ── Wallet from log (grep first match directly — no podman call) ──
    w="$(docker exec "$_outer" grep -m1 'Wallet:' "$_logpath" 2>/dev/null | _strip_ansi \
       | awk '{print $NF}' | tr -cd '1-9A-HJ-NP-Za-km-z')"
    [ -z "$w" ] && w="N/A"

    # Collect containers per wallet (dedup)
    if [ -z "${W_CTRS[$w]+x}" ]; then
      W_CTRS[$w]="$_label"; W_ORD+=("$w")
      W_OUTER[$w]="$_outer"; W_LOGPATH[$w]="$_logpath"
    else
      W_CTRS[$w]="${W_CTRS[$w]}, $_label"
    fi

    NODE_WALLET[$_pair]="$w"
  done

  # ── Print each unique wallet with live RPC balances ──────────────────
  for w in "${W_ORD[@]}"; do
    echo "Host: https://explore.nosana.com/hosts/$w (${W_CTRS[$w]})"
    for _pair in "${NODE_PAIRS[@]}"; do
      [[ "${NODE_WALLET[$_pair]}" = "$w" ]] || continue
      IFS='|' read -r _outer _inner _ <<< "$_pair"
      printf 'Markets observed in [%s] %s:\n' "$_outer" "$_inner"
      sed -n '1,4{ s/^First legacy recommendation:/First Market Recommended:/; s/^Last legacy recommendation:/Last Market Recommended:/; p; }' "${QUALIFICATION_REPORTS[$_pair]}"
    done

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
      stk="$(docker exec "${W_OUTER[$w]}" head -n 50 "${W_LOGPATH[$w]}" 2>/dev/null | _strip_ansi \
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
# Show what getent actually returned. A fast failure otherwise looks like fast DNS.
_host_dns_report() {
  local host start_ms end_ms answer status addresses error
  printf 'Host resolv.conf nameservers: '
  awk '/^nameserver/ {printf "%s%s", (n++ ? ", " : ""), $2} END {if (!n) printf "unavailable"; print ""}' /etc/resolv.conf
  if command -v resolvectl >/dev/null; then
    echo "System DNS by link:"
    timeout 3 resolvectl dns 2>&1 | head -c 2048
    echo
  fi
  for host in nosana.com nosana.io; do
    start_ms=$(date +%s%3N)
    answer=$(timeout -k 1 3 getent ahosts "$host" 2>&1)
    status=$?
    end_ms=$(date +%s%3N)
    addresses=$(awk '/^[0-9a-fA-F:.]+[[:space:]]/ && !seen[$1]++ {print $1}' <<< "$answer" | paste -sd, -)
    if (( status == 0 )) && [[ -n "$addresses" ]]; then
      printf 'Host DNS %s: OK %s (%d ms)\n' "$host" "$addresses" "$((end_ms-start_ms))"
    else
      error=${answer:0:240}
      [[ $status != 124 ]] || error="timeout"
      printf 'Host DNS %s: FAILED (exit %d, %d ms)%s\n' "$host" "$status" "$((end_ms-start_ms))" "${error:+: $error}"
    fi
  done
}

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
_host_dns_report && \
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
# Get podman version from first discovered outer container
if [ ${#NODE_PAIRS[@]} -gt 0 ]; then
  IFS='|' read -r _first_outer _ _ <<< "${NODE_PAIRS[0]}"
  _podman_ver="$(docker exec "$_first_outer" podman -v 2>/dev/null | awk '{print "podman version " $3}')"
else
  _podman_ver="$(docker exec podman podman -v 2>/dev/null | awk '{print "podman version " $3}')"
fi
echo "${_docker_ver}  |  ${_podman_ver}"
_now=$(date +%s)
printf "Uptimes:\n"
printf "  %-35s %s\n" "$(uptime -p | sed 's/^up //') (since $(who -b | awk '{print $3,$4}'))" "PC"

# Use NODE_PAIRS for uptimes (inner nosana-node containers)
if [ ${#NODE_PAIRS[@]} -gt 0 ]; then
  for _pair in "${NODE_PAIRS[@]}"; do
    IFS='|' read -r _outer _inner _logpath <<< "$_pair"
    _label="[${_outer}] ${_inner}"
    _status="$(docker exec "$_outer" podman inspect --format '{{.State.Status}}' "$_inner" 2>/dev/null)"
    _exit_code="$(docker exec "$_outer" podman inspect --format '{{.State.ExitCode}}' "$_inner" 2>/dev/null)"
    _start="$(docker exec "$_outer" podman inspect --format '{{.State.StartedAt}}' "$_inner" 2>/dev/null | cut -d. -f1 | sed 's/T/ /')"
    _start_epoch=$(date -d "${_start} UTC" +%s 2>/dev/null)

    if [ "$_status" = "running" ]; then
      _diff=$((_now - _start_epoch))
      _d=$((_diff/86400)); _h=$(((_diff%86400)/3600)); _m=$(((_diff%3600)/60))
      printf "  %-35s %s\n" "${_d} days, ${_h} hours, ${_m} minutes (since ${_start} UTC)" "$_label"
    else
      _finished="$(docker exec "$_outer" podman inspect --format '{{.State.FinishedAt}}' "$_inner" 2>/dev/null | cut -d. -f1 | sed 's/T/ /')"
      _fin_epoch=$(date -d "${_finished} UTC" +%s 2>/dev/null)
      _ran=$((_fin_epoch - _start_epoch))
      _rd=$((_ran/86400)); _rh=$(((_ran%86400)/3600)); _rm=$(((_ran%3600)/60))
      _ago=$((_now - _fin_epoch))
      _ad=$((_ago/86400)); _ah=$(((_ago%86400)/3600)); _am=$(((_ago%3600)/60))
      printf "  %-35s %s [STOPPED exit:%s, ran %dd %dh %dm, stopped %dd %dh %dm ago]\n" \
        "(since ${_start} UTC)" "$_label" "$_exit_code" "$_rd" "$_rh" "$_rm" "$_ad" "$_ah" "$_am"
    fi
  done
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
echo "docker exec podman podman ps -a" >> mylog.txt
docker exec podman podman ps -a >> mylog.txt
echo "" >> mylog.txt
{
  cat "$report_work/network.txt"
  for _pair in "${NODE_PAIRS[@]}"; do
    IFS='|' read -r _outer _inner _ <<< "$_pair"
    printf '\n=== [%s] %s qualification ===\n' "$_outer" "$_inner"
    tail -n +5 "${QUALIFICATION_REPORTS[$_pair]}"
  done
  if [[ -s "$report_work/frpc.log" ]]; then
    printf '\nFRPC logs\n'
    cat "$report_work/frpc.log"
  fi
  echo
} >> mylog.txt
docker -v >> mylog.txt
echo "" >> mylog.txt

PS_ALL="$(docker ps 2>/dev/null || true)"

if [ -n "$PS_ALL" ]; then
  TOTAL_CONTAINERS="$(printf '%s\n' "$PS_ALL" | awk 'NR>1 && NF{c++} END{print c+0}')"

  {
    echo "docker ps (${TOTAL_CONTAINERS} total)"
    printf '%s\n' "$PS_ALL"
  } >> mylog.txt
else
  echo "docker ps (unavailable)" >> mylog.txt
fi
#--- END DOCKER COMMANDS ---

#--- BEGIN NOSANA NODE LOG TAILS (budget-distributed, cleaned) ---
# The retained node file contains stdout and stderr. The cleaned, date-selected
# excerpts share the report budget across containers.

CURRENT_SIZE=$(wc -c < mylog.txt)
REMAINING=$((MAX_FILE_BYTES - CURRENT_SIZE - 10000))
BYTES_PER_LINE=200
MAX_TOTAL_LINES=$((REMAINING / BYTES_PER_LINE))
HEAD_LINES=30

if [ "$NUM_LOG_CONTAINERS" -gt 0 ]; then
  # ── Budget: reserve HEAD_LINES per container, distribute rest for tails ─
  TAIL_BUDGET=$((MAX_TOTAL_LINES - (HEAD_LINES * NUM_LOG_CONTAINERS)))
  [ "$TAIL_BUDGET" -lt 0 ] && TAIL_BUDGET=0
  SHARE=$((TAIL_BUDGET / NUM_LOG_CONTAINERS))
  declare -A LOG_ALLOC
  LEFTOVER=0

  for _pair in "${NODE_PAIRS[@]}"; do
    _avail=$((LOG_TOTAL_LINES[$_pair] - HEAD_LINES))
    [ "$_avail" -lt 0 ] && _avail=0
    if [ "$_avail" -le "$SHARE" ]; then
      LOG_ALLOC[$_pair]="$_avail"
      LEFTOVER=$((LEFTOVER + SHARE - _avail))
    else
      LOG_ALLOC[$_pair]="$SHARE"
    fi
  done

  LONG_CONTAINERS=0
  for _pair in "${NODE_PAIRS[@]}"; do
    _avail=$((LOG_TOTAL_LINES[$_pair] - HEAD_LINES))
    [ "$_avail" -gt "$SHARE" ] && LONG_CONTAINERS=$((LONG_CONTAINERS + 1))
  done

  if [ "$LONG_CONTAINERS" -gt 0 ] && [ "$LEFTOVER" -gt 0 ]; then
    BONUS=$((LEFTOVER / LONG_CONTAINERS))
    for _pair in "${NODE_PAIRS[@]}"; do
      _avail=$((LOG_TOTAL_LINES[$_pair] - HEAD_LINES))
      if [ "$_avail" -gt "$SHARE" ]; then
        LOG_ALLOC[$_pair]=$((LOG_ALLOC[$_pair] + BONUS))
        [ "${LOG_ALLOC[$_pair]}" -gt "$_avail" ] && LOG_ALLOC[$_pair]="$_avail"
      fi
    done
  fi

  # ── Write operator-reported error (if any) ──────────────────────────────
  if [[ -n "$OPERATOR_ERROR" ]]; then
    {
      echo ""
      echo ""
      echo "========================================================================"
      echo "OPERATOR REPORTED ERROR:"
      echo "========================================================================"
      echo "$OPERATOR_ERROR"
      echo ""
    } >> mylog.txt
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
    for _pair in "${NODE_PAIRS[@]}"; do
      IFS='|' read -r _outer _inner _ <<< "$_pair"
      _label="[${_outer}] ${_inner}"
      printf "  === %s:    (%d lines)\n" "$_label" "${LOG_TOTAL_LINES[$_pair]}"
    done
    echo "------------------------------------------------------------------------"
  } >> mylog.txt

  for _pair in "${NODE_PAIRS[@]}"; do
    IFS='|' read -r _outer _inner _ <<< "$_pair"
    _label="[${_outer}] ${_inner}"
    _tmplog="${LOG_TMPFILES[$_pair]}"
    printf "  writing %s: head %d + tail %d of %d lines\n" \
      "$_label" "$HEAD_LINES" "${LOG_ALLOC[$_pair]}" "${LOG_TOTAL_LINES[$_pair]}"
    {
      _shown=$((HEAD_LINES + LOG_ALLOC[$_pair]))
      [ "$_shown" -gt "${LOG_TOTAL_LINES[$_pair]}" ] && _shown="${LOG_TOTAL_LINES[$_pair]}"
      _omitted=$((LOG_TOTAL_LINES[$_pair] - _shown))
      if [ "$_omitted" -eq 0 ]; then
        _trim_note="100% OF LOG"
      else
        _trim_note="${_omitted} lines omitted"
      fi
      printf "\n\n\n=== %s: head %d + tail %d of %d cleaned lines (%s) ===\n" \
        "$_label" "$HEAD_LINES" "${LOG_ALLOC[$_pair]}" "${LOG_TOTAL_LINES[$_pair]}" "$_trim_note"
      echo "--- HEAD (first ${HEAD_LINES} lines) ---"
      head -n "$HEAD_LINES" "$_tmplog"
      echo ""
      echo "--- TAIL (last ${LOG_ALLOC[$_pair]} lines) ---"
      tail -n "${LOG_ALLOC[$_pair]}" "$_tmplog"
    } >> mylog.txt
    rm -f "$_tmplog"
  done
  echo "  log collection complete"
fi
#--- END NOSANA NODE LOG TAILS ---

# ── Sanitize: strip control bytes + non-ASCII → pure 7-bit ASCII ─────────
# (done before --no-upload exit so callers get a clean file too)
perl -CSDA -pi -e '
  s/\x{2714}/[OK]/g;       # ✔
  s/\x{2716}/[FAIL]/g;     # ✖
  s/\x{2265}/>=/g;
  s/\x{2264}/<=/g;
  s/\x{2026}/.../g;        # …
  s/\x{00B0}/deg/g;        # °
  s/[^\x09\x0A\x0D\x20-\x7E]//g;  # strip anything else non-ASCII
' mylog.txt

# Line-based allocations are estimates. Enforce the byte limit on the final
# ASCII report, preserving the summary and most recent tail if it overflows.
_limit_report_bytes() {
  local file=$1 limit=$2 scratch=$3 size available front
  local marker=$'\n[Report byte limit reached; middle of report omitted.]\n'
  size=$(stat -c %s -- "$file") || return 1
  (( size > limit )) || return 0
  available=$((limit - ${#marker}))
  (( available > 0 )) || return 1
  front=$((available / 2))
  {
    head -c "$front" -- "$file" &&
    printf '%s' "$marker" &&
    tail -c "$((available-front))" -- "$file"
  } > "$scratch" && cat "$scratch" > "$file"
}
if ! _limit_report_bytes mylog.txt "$MAX_FILE_BYTES" "$report_work/limited.txt"; then
  echo "Could not apply the report size limit." >&2
  exit 1
fi

# ── --no-upload: stop here, caller handles upload ────────────────────────
if [ "$NO_UPLOAD" = true ]; then
    echo "Log collection complete (--no-upload mode)."
    exit 0
fi

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

# Sanitize: strip control bytes + replace remaining non-ASCII → pure 7-bit ASCII
# so Slack reliably detects text and shows inline preview
perl -CSDA -pi -e '
  s/\x{2714}/[OK]/g;       # ✔
  s/\x{2716}/[FAIL]/g;     # ✖
  s/\x{2026}/.../g;        # …
  s/\x{00B0}/deg/g;        # °
  s/[^\x09\x0A\x0D\x20-\x7E]//g;  # strip anything else non-ASCII
' "$TEXT_FILE"
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

# Truncate for Slack inline preview (Slack won't preview files > ~1MB)
SLACK_MAX_BYTES=500000
SLACK_FILE="$TEXT_FILE"
if [ "$FILE_SIZE" -gt "$SLACK_MAX_BYTES" ]; then
    SLACK_FILE=$(mktemp --suffix=.txt)
    TOTAL_LINES=$(wc -l < "$TEXT_FILE")
    # Keep head (system summary) + tail (recent logs), stay under limit
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
    # If still too large, hard-truncate to byte limit
    if [ "$(wc -c < "$SLACK_FILE")" -gt "$SLACK_MAX_BYTES" ]; then
        truncate -s "$SLACK_MAX_BYTES" "$SLACK_FILE"
    fi
fi
SLACK_FILE_SIZE=$(wc -c < "$SLACK_FILE" | tr -d ' ')

# Step 1: Get upload URL (filename + length only; snippet_type not supported)
GET_RESPONSE=$(curl -s --max-time 15 -X POST \
  -H "Authorization: Bearer $mana" \
  -F "filename=$SLACK_FILENAME" \
  -F "length=$SLACK_FILE_SIZE" \
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
      -F "file=@$SLACK_FILE;type=text/plain" \
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

# Clean up truncated temp file if created
[[ "$SLACK_FILE" != "$TEXT_FILE" ]] && rm -f "$SLACK_FILE"

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
# - Read the retained CRI log (stdout and stderr). Collapse spinner noise.
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
# - Uses IMAGE-BASED detection (not name-based grep):
#   1. Outer: docker ps --format | grep 'nosana/podman' → finds Docker containers
#   2. Inner: docker exec $outer podman ps --format | grep 'nosana/nosana-node'
#   3. Logpath: podman inspect --format='{{.HostConfig.LogConfig.Path}}' $inner
# - Returns outer|inner|logpath triples in NODE_PAIRS array.
# - Reads logs via direct file access: docker exec $outer head/tail/cat $logpath
# - This bypasses `podman logs` (which can hang) and `docker logs` (which
#   only sees the outer container's log, not the inner nosana-node).
# - Works for all node configurations: nn01 multi-GPU (podman-gpu0/1/2),
#   single-podman nodes (nn02-nn06), and future configurations.
# - Stopped inner containers show: exit code, runtime, and time since stop.
#
# ── WALLETS & BALANCES ─────────────────────────────────────────────────────
# - Each container has a unique wallet. One GPU per container currently.
#   Future multi-GPU containers (e.g. 4x4090) would still be one wallet
#   per container. Associative arrays handle dedup but in practice wallets
#   are unique per container.
# - Wallet extracted from HEAD of docker log (first 50 lines). The wallet
#   is printed once at container startup and never appears in recent tail.
# - First/last targets and legacy recommendations use the full retained node log.
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
# - Full data (podman ps, docker ps, frpc logs, container log tails)
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
# ── LOG DEDUPLICATION ──────────────────────────────────────────────────────
# - Raw podman log lines have a container-log prefix (timestamp + stdout P)
#   that makes every line unique, plus Braille spinner chars (U+2800-28FF)
#   that differ per animation frame. Empty spinner frames (prefix-only lines)
#   are interleaved between content lines.
# - _dedup_consecutive (perl -CSDA) normalises each line for comparison:
#   strips the timestamp+stdout prefix, strips Braille chars, collapses
#   whitespace. Empty-after-normalisation lines are dropped entirely.
# - Only the first occurrence of each consecutive identical run is kept
#   (with cleaned output: second-precision timestamp, no stdout P, no
#   spinners, 2-space indent); then a summary "  [... above line repeated
#   N more times]" is emitted for runs of 2+.
# - Output lines are cleaned: timestamp truncated to seconds, container-log
#   prefix (stdout/stderr P/F) stripped, Braille spinners removed, whitespace
#   collapsed, 2-space indent added.
# - Typical reduction: 7M lines → ~30K-50K lines (531MB → ~10-15MB).
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

#!/bin/bash
# frpc-logs.sh v0.00.2
# Log viewer for frpc-api containers running inside nested Podman-in-Docker.
# Reads log files directly — bypasses `podman logs` (which hangs on large logs).
# Auto-detects both outer Docker and inner Podman containers by name prefix.
#
# Usage:
#   ./frpc-logs.sh              # show full log from all detected containers
#   ./frpc-logs.sh --tail 100   # last 100 lines
#   ./frpc-logs.sh --head 50    # first 50 lines
#   ./frpc-logs.sh -g "error"   # grep for pattern (extended regex)
#   ./frpc-logs.sh -f           # follow mode (like tail -f)
#   ./frpc-logs.sh -c podman-gpu0  # target a specific outer Docker container
#   ./frpc-logs.sh -i frpc-api-6Ue...  # target a specific inner Podman container
#   ./frpc-logs.sh -o           # write combined log: {hostname}-all-frpc-api.log
#   ./frpc-logs.sh -o --uncombine  # write separate files per container

VERSION="0.00.2"
TAIL_LINES=""
HEAD_LINES=""
FOLLOW=false
GREP_PATTERN=""
TARGET_CONTAINER=""
INNER_CONTAINER=""
OUTPUT_FILE=false
COMBINE=true

# Detection settings
OUTER_IMAGE="nosana/podman"
INNER_PREFIX="frpc-api"

usage() {
    cat <<EOF
frpc-logs.sh v${VERSION}
Tail frpc-api logs directly from the log file (no podman logs hang).

Usage: $(basename "$0") [OPTIONS]

Options:
  --tail NUM  Show last NUM lines (default: full log)
  --head NUM  Show first NUM lines (default: full log)
  -f        Follow mode (tail -f)
  -g PAT    Grep for pattern (extended regex, e.g. "error|Error|ERROR")
  -c NAME   Target a specific outer Docker container (skip auto-detect)
  -i NAME   Target a specific inner Podman container (skip auto-detect)
  -o        Write output to file (combined; uses -all- only for multi-container hosts)
  --uncombine  With -o, write separate files: {hostname}-{docker}-frpc-api.log
  -h        Show this help
  -v        Show version

Auto-detection:
  Outer: finds Docker containers running the '$OUTER_IMAGE' image
  Inner: finds Podman containers whose name starts with '$INNER_PREFIX'
EOF
    exit 0
}

# Pre-parse long options (shift them out before getopts)
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uncombine) COMBINE=false; shift ;;
        --tail)  TAIL_LINES="$2"; shift 2 ;;
        --head)  HEAD_LINES="$2"; shift 2 ;;
        *)         ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

# Parse arguments
while getopts "fg:c:i:ohv" opt; do
    case "$opt" in
        f) FOLLOW=true ;;
        g) GREP_PATTERN="$OPTARG" ;;
        c) TARGET_CONTAINER="$OPTARG" ;;
        i) INNER_CONTAINER="$OPTARG" ;;
        o) OUTPUT_FILE=true ;;
        h) usage ;;
        v) echo "frpc-logs.sh v${VERSION}"; exit 0 ;;
        *) usage ;;
    esac
done

# Validate --tail/--head mutual exclusion
if [[ -n "$TAIL_LINES" && -n "$HEAD_LINES" ]]; then
    echo "ERROR: Cannot use --tail and --head together." >&2
    exit 1
fi

# Helper: read log with tail/head/cat based on flags
read_log() {
    local container="$1" logpath="$2"
    if [[ -n "$TAIL_LINES" ]]; then
        docker exec "$container" tail -n "$TAIL_LINES" "$logpath"
    elif [[ -n "$HEAD_LINES" ]]; then
        docker exec "$container" head -n "$HEAD_LINES" "$logpath"
    else
        docker exec "$container" cat "$logpath"
    fi
}

HOSTNAME=$(hostname -s)

# Auto-detect or use specified container
if [[ -n "$TARGET_CONTAINER" ]]; then
    CONTAINERS=("$TARGET_CONTAINER")
else
    mapfile -t CONTAINERS < <(docker ps --format '{{.Names}}\t{{.Image}}' | grep 'nosana/podman' | awk '{print $1}')
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        echo "ERROR: No containers running the nosana/podman image found." >&2
        echo "Use 'docker ps' to check running containers, or specify one with -c NAME." >&2
        exit 1
    fi
fi

# Pass 1: Discover all container/inner/logpath triples
PAIRS=()    # "container|inner|logpath" entries
for CONTAINER in "${CONTAINERS[@]}"; do
    if [[ -n "$INNER_CONTAINER" ]]; then
        INNER_NAMES=("$INNER_CONTAINER")
    else
        mapfile -t INNER_NAMES < <(docker exec "$CONTAINER" podman ps --format '{{.Names}}' 2>/dev/null | grep "^${INNER_PREFIX}")
        if [[ ${#INNER_NAMES[@]} -eq 0 ]]; then
            echo "WARNING: No '${INNER_PREFIX}*' container found inside '$CONTAINER'. Skipping." >&2
            continue
        fi
    fi
    for INNER in "${INNER_NAMES[@]}"; do
        LOGPATH=$(docker exec "$CONTAINER" podman inspect --format='{{.HostConfig.LogConfig.Path}}' "$INNER" 2>/dev/null)
        if [[ -z "$LOGPATH" ]]; then
            echo "WARNING: Could not get log path for '$INNER' in container '$CONTAINER'. Skipping." >&2
            continue
        fi
        PAIRS+=("${CONTAINER}|${INNER}|${LOGPATH}")
    done
done

if [[ ${#PAIRS[@]} -eq 0 ]]; then
    echo "ERROR: No frpc-api log paths found." >&2
    exit 1
fi

# Determine combined filename (smart: skip -all- for single container)
if [[ "$OUTPUT_FILE" == true && "$COMBINE" == true ]]; then
    if [[ ${#PAIRS[@]} -eq 1 ]]; then
        IFS='|' read -r C _ _ <<< "${PAIRS[0]}"
        COMBINEFILE="${HOSTNAME}-${C}-frpc-api.log"
    else
        COMBINEFILE="${HOSTNAME}-all-frpc-api.log"
    fi
    > "$COMBINEFILE"
    COMBINE_FIRST=true
fi

# Pass 2: Fetch logs
FIRST=true
for PAIR in "${PAIRS[@]}"; do
    IFS='|' read -r CONTAINER INNER LOGPATH <<< "$PAIR"
    OUTFILE="${HOSTNAME}-${CONTAINER}-frpc-api.log"

    if [[ "$FOLLOW" == true ]]; then
        # Follow mode — only practical for a single container
        if [[ ${#PAIRS[@]} -gt 1 ]]; then
            echo "WARNING: Follow mode with multiple containers only follows the last one." >&2
        fi
        if [[ "$OUTPUT_FILE" == true ]]; then
            echo "WARNING: Follow mode (-f) is not compatible with file output (-o). Writing to stdout." >&2
        fi
        if [[ -n "$GREP_PATTERN" ]]; then
            docker exec "$CONTAINER" tail -f "$LOGPATH" | grep -E --line-buffered "$GREP_PATTERN"
        else
            docker exec "$CONTAINER" tail -f "$LOGPATH"
        fi
    elif [[ "$OUTPUT_FILE" == true && "$COMBINE" == true ]]; then
        # Combined mode — append to single file with headers
        if [[ "$COMBINE_FIRST" == true ]]; then
            COMBINE_FIRST=false
        else
            echo "" >> "$COMBINEFILE"
        fi
        # Only add section header when there are multiple containers
        if [[ ${#PAIRS[@]} -gt 1 ]]; then
            echo "=== ${HOSTNAME}-${CONTAINER}-frpc-api ===" >> "$COMBINEFILE"
        fi
        if [[ -n "$GREP_PATTERN" ]]; then
            read_log "$CONTAINER" "$LOGPATH" | grep -E "$GREP_PATTERN" >> "$COMBINEFILE"
        else
            read_log "$CONTAINER" "$LOGPATH" >> "$COMBINEFILE"
        fi
    elif [[ "$OUTPUT_FILE" == true ]]; then
        if [[ -n "$GREP_PATTERN" ]]; then
            read_log "$CONTAINER" "$LOGPATH" | grep -E "$GREP_PATTERN" > "$OUTFILE"
        else
            read_log "$CONTAINER" "$LOGPATH" > "$OUTFILE"
        fi
        echo "Wrote ${OUTFILE}"
    else
        # Print separator between containers
        if [[ "$FIRST" == true ]]; then
            FIRST=false
        else
            echo ""
        fi
        echo "=== [$CONTAINER] frpc-api logs ==="
        if [[ -n "$GREP_PATTERN" ]]; then
            read_log "$CONTAINER" "$LOGPATH" | grep -E "$GREP_PATTERN"
        else
            read_log "$CONTAINER" "$LOGPATH"
        fi
    fi
done

# Report combined file
if [[ "$OUTPUT_FILE" == true && "$COMBINE" == true ]]; then
    echo "Wrote ${COMBINEFILE}"
fi

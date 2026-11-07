#!/bin/bash
# Emulate only the local Docker/Podman records requested by the collector.
# Internal operations always target fixture files; no container CLI is used.
outer_id=$(printf 'a%.0s' {1..64})
node_id=$(printf 'b%.0s' {1..64})
proxy_id=$(printf 'c%.0s' {1..64})
node_name=nosana-node
proxy_name=frpc-api-${FIXTURE_WALLET}
node_log=/var/lib/containers/storage/overlay-containers/$node_id/userdata/ctr.log
proxy_log=/var/lib/containers/storage/overlay-containers/$proxy_id/userdata/ctr.log

inventory_row() {
    local fmt="$1"
    fmt=${fmt//'{{.ID}}'/$2}
    fmt=${fmt//'{{.Names}}'/$3}
    fmt=${fmt//'{{.Image}}'/$4}
    fmt=${fmt//'{{.State}}'/"$5"}
    fmt=${fmt//'{{.Status}}'/Up}
    printf '%b\n' "$fmt"
}
if [[ "$1" == -v ]]; then
    echo 'Docker version 29.7.2, build fixture'
    exit
fi
if [[ "$1" == ps ]]; then
    if [[ "$*" == *--format* ]]; then
        inventory_row "${!#}" "$outer_id" podman nosana/podman:fixture running
    else
        printf 'CONTAINER ID IMAGE NAMES\n%s nosana/podman:fixture podman\n' "$outer_id"
    fi
    exit
fi
[[ "$1" == exec ]] || exit 1
shift
if [[ "${1:-}" == -i ]]; then shift; fi
[[ "$1" == podman || "$1" == "$outer_id" ]] || exit 1
shift
if [[ "$1" == timeout ]]; then
    shift
    if [[ "$1" == -k ]]; then shift 2; fi
    shift
fi
if [[ "$1" == podman ]]; then
    shift
    case "$1" in
        -v|--version|version) echo 'podman version 4.5.0'; exit ;;
        ps)
            if [[ "$*" == *--format* ]]; then
                inventory_row "${!#}" "$node_id" "$node_name" nosana/nosana-node:fixture "Up 4 days"
                inventory_row "${!#}" "$proxy_id" "$proxy_name" nosana/frpc:fixture "Up 19 hours"
            else
                printf 'NAMES\n%s\n%s\n' "$node_name" "$proxy_name"
            fi
            exit ;;
        inspect)
            case "$*" in
                *LogConfig.Path*)
                    case "${!#}" in
                        "$node_id"|"$node_name") echo "$node_log"; exit ;;
                        "$proxy_id"|"$proxy_name") echo "$proxy_log"; exit ;;
                    esac ;;
                *State.Status*) echo 'running'; exit ;;
                *State.StartedAt*|*State.FinishedAt*) echo '2026-11-01T01:23:45.123456Z'; exit ;;
                *State.ExitCode*) echo 0; exit ;;
            esac ;;
        exec)
            # Only the attempted probe is recorded. Do not record command bodies.
            if [[ "${2:-}" == "$proxy_id" && "${3:-}" == awk && "${!#}" == /etc/frp/frpc.toml ]]; then
                exec /usr/bin/cat "$FIXTURE_DIR/frpc.toml"
            elif [[ "${2:-}" == "$proxy_id" && "${3:-}" == curl ]]; then
                echo frpc-local-api >> "$FIXTURE_DIR/probe-attempts"
            elif [[ "${2:-}" == "$node_id" && "${3:-}" == node ]]; then
                echo node >> "$FIXTURE_DIR/probe-attempts"
            fi
            exit 127 ;; # Runtime/network tools unavailable is a supported condition.
    esac
elif [[ "$1" == cat || "$1" == head || "$1" == tail || "$1" == grep || "$1" == stat ]]; then
    command=$1
    shift
    args=("$@")
    last=$((${#args[@]}-1))
    case "${args[last]}" in
        "$node_log") args[last]="$FIXTURE_DIR/node.log" ;;
        "$proxy_log") args[last]="$FIXTURE_DIR/proxy.log" ;;
        *) exit 1 ;;
    esac
    exec "/usr/bin/$command" "${args[@]}"
fi
exit 1

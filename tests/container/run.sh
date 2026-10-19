#!/usr/bin/env bash
# Docker owns the server. RESP peers exchange binary files over ordinary TCP.
set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

# Only resource ownership crosses main's scope for the EXIT trap.
run_id=
workspace=
evidence_dir=
resource_kinds=()
resource_names=()

docker_call() {
    timeout --signal=TERM --kill-after=3s 30s docker "$@"
}

register() {
    resource_kinds+=("$1")
    resource_names+=("$2")
}

# Evidence collection reports each failure so cleanup can continue.
# shellcheck disable=SC2310
collect_evidence() {
    local index name prefix

    for ((index = 0; index < ${#resource_names[@]}; index++)); do
        [[ ${resource_kinds[index]} == container ]] || continue
        name=${resource_names[index]}
        prefix="$workspace/evidence/$name"
        if docker_call inspect "$name" > "$prefix.inspect.json" 2> /dev/null; then
            docker_call logs --tail 150 "$name" \
                > "$workspace/stdout" 2> "$workspace/stderr" || return 1
            tail -c 32768 "$workspace/stdout" > "$prefix.stdout.log" || return 1
            tail -c 32768 "$workspace/stderr" > "$prefix.stderr.log" || return 1
        fi
    done
}

# Cleanup handles command statuses explicitly and must try every owned resource.
# shellcheck disable=SC2310
cleanup() {
    local status=$? failed=false index kind name found label

    trap - EXIT
    trap '' INT TERM
    if [[ -n "$workspace" ]]; then
        collect_evidence || failed=true
        if [[ -n "$evidence_dir" ]]; then
            cp -R "$workspace/evidence/." "$evidence_dir/" || failed=true
        fi
    fi

    for ((index = ${#resource_names[@]} - 1; index >= 0; index--)); do
        kind=${resource_kinds[index]}
        name=${resource_names[index]}
        if ! found=$(docker_call "$kind" inspect "$name" 2>&1); then
            if [[ "$found" != *'No such'* && "$found" != *'no such'* ]]; then
                printf 'container: cannot inspect %s: %s\n' "$name" "$found" >&2
                failed=true
            fi
            continue
        fi
        if ! label=$(printf '%s\n' "$found" | jq -er \
            '.[0] | (.Config.Labels // .Labels) | .["io.kgcache.container-test"]'); then
            failed=true
            continue
        fi
        if [[ "$label" != "$run_id" ]]; then
            printf 'container: refusing to remove unowned resource %s\n' "$name" >&2
            failed=true
            continue
        fi
        if [[ "$kind" == container ]]; then
            docker_call container rm --force "$name" > /dev/null || failed=true
        else
            docker_call "$kind" rm "$name" > /dev/null || failed=true
        fi
    done

    if [[ "$status" != 0 && -n "$workspace" ]]; then
        for found in "$workspace/evidence/"*.stderr.log; do
            [[ -f "$found" ]] || continue
            tail -c 8192 "$found" >&2
        done
    fi
    if [[ -n "$workspace" ]]; then
        rm -rf -- "$workspace" || failed=true
    fi
    if [[ "$status" == 0 && "$failed" == true ]]; then
        status=1
    fi
    exit "$status"
}

# Run under timeout in a separate process. Bash variables cannot hold NUL bytes.
exchange() (
    local host=$1 port=$2 input=$3 expected=$4 actual=$5 size writer

    exec 3<> "/dev/tcp/$host/$port"
    size=$(wc -c < "$expected")
    cat "$input" >&3 &
    writer=$!
    trap 'kill -TERM "$writer" 2> /dev/null || true' EXIT
    head -c "$size" <&3 > "$actual"
    wait "$writer"
    trap - EXIT
    cmp "$expected" "$actual"
)

request() {
    timeout --signal=TERM --kill-after=2s 10s \
        bash "$RELEASE_ROOT/tests/container/run.sh" --exchange "$@"
}

create_volume() {
    register volume "$1"
    docker_call volume create --label "io.kgcache.container-test=$run_id" \
        "$1" > /dev/null
}

create_server() {
    local image=$1 network=$2 name=$3 mount=$4

    shift 4
    register container "$name"
    docker_call create \
        --name "$name" \
        --label "io.kgcache.container-test=$run_id" \
        --platform linux/amd64 \
        --read-only \
        --network "$network" \
        --publish '127.0.0.1::6379' \
        --mount "$mount" \
        --env KGCACHE_TEST_CONTROL=invalid-release-control \
        --log-driver local \
        --log-opt max-size=1m \
        --log-opt max-file=2 \
        "$@" "$image" > /dev/null
}

start_server() {
    local name=$1 port running deadline

    docker_call start "$name" > /dev/null
    port=$(docker_call inspect "$name" | jq -er \
        '.[0].NetworkSettings.Ports["6379/tcp"][0].HostPort')
    printf '%s\n' "$port" > "$workspace/port"
    deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        # request returns the status of its one bounded subprocess.
        # shellcheck disable=SC2310
        if request 127.0.0.1 "$port" "$workspace/ping.request" \
            "$workspace/ping.expected" "$workspace/ping.actual" \
            2> "$workspace/readiness.log"; then
            return
        fi
        running=$(docker_call inspect --format '{{.State.Running}}' "$name")
        [[ "$running" == true ]] || release_fail "$name exited before readiness"
        sleep 0.05
    done
    release_fail "$name did not become ready within 60 seconds"
}

stop_server() {
    timeout --signal=TERM --kill-after=3s 40s \
        docker stop --time 30 "$1" > /dev/null
    docker_call inspect "$1" | jq -e \
        '.[0].State | .ExitCode == 0 and (.OOMKilled | not)' > /dev/null
}

check_layout() {
    local name=$1 layout status dependencies actual_sha

    layout=$(docker_call exec "$name" stat -c '%u:%g:%a' \
        /data /etc/kgcache/kgcache.conf /usr/local/bin/kgcache)
    [[ "$layout" == $'10001:10001:750\n0:0:444\n0:0:755' ]] ||
        release_fail 'incorrect image ownership or permissions'
    status=$(docker_call exec "$name" cat /proc/1/status)
    [[ "$status" == *$'Uid:\t10001\t10001\t10001\t10001'* ]] ||
        release_fail 'PID 1 must run as UID 10001'
    dependencies=$(docker_call exec "$name" ldd /usr/local/bin/kgcache)
    [[ "$dependencies" != *'not found'* ]] || release_fail 'unresolved runtime library'
    printf '%s\n' "$dependencies" > "$workspace/evidence/dependencies.log"
    # The tool variable is expanded inside the container.
    # shellcheck disable=SC2016
    docker_call exec "$name" bash -c \
        'for tool in zig python3 cc kgcache-controlled-server kgcache-fake-server readelf; do
            if command -v "$tool"; then exit 1; fi
        done'

    docker_call exec "$name" cat /usr/share/kgcache/build-info.json \
        > "$workspace/evidence/build-info.json"
    actual_sha=$(docker_call exec "$name" sha256sum /usr/local/bin/kgcache)
    actual_sha=${actual_sha%% *}
    jq -e --arg sha "$actual_sha" --slurpfile image "$workspace/evidence/image.json" \
        '.binary.sha256 == $sha and .persistence_test_controls == false and
        .target == "x86_64-linux-gnu.2.36" and .cpu == "baseline" and
        .optimize == "ReleaseSafe" and
        .source.revision == $image[0][0].Config.Labels["org.opencontainers.image.revision"] and
        .version == $image[0][0].Config.Labels["org.opencontainers.image.version"]' \
        "$workspace/evidence/build-info.json" > /dev/null
}

smoke() {
    local image=$1 network=$2 name="$run_id-smoke" volume="$run_id-smoke" port

    create_volume "$volume"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data"
    start_server "$name"
    port=$(cat "$workspace/port")
    check_layout "$name"
    # RESP bulk lengths use literal dollar signs.
    # shellcheck disable=SC2016
    printf '*3\r\n$3\r\nSET\r\n$13\r\ncontainer-key\r\n$15\r\nbinary\000\377\r\nvalue\r\n*2\r\n$3\r\nGET\r\n$13\r\ncontainer-key\r\n' \
        > "$workspace/binary.request"
    # shellcheck disable=SC2016
    printf '+OK\r\n$15\r\nbinary\000\377\r\nvalue\r\n' > "$workspace/binary.expected"
    request 127.0.0.1 "$port" "$workspace/binary.request" \
        "$workspace/binary.expected" "$workspace/binary.actual"
    stop_server "$name"
}

main() {
    local image='' artifacts='' allow_emulation=false network native engine_arch

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image | --artifacts)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --image) image=$2 ;;
                    --artifacts) artifacts=$2 ;;
                esac
                shift 2
                ;;
            --allow-emulation)
                allow_emulation=true
                shift
                ;;
            --help)
                printf 'Usage: bash tests/container/run.sh --image IMAGE [--artifacts DIR] [--allow-emulation]\n'
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done

    [[ -n "$image" ]] || release_fail '--image is required'
    release_require_commands docker timeout jq mktemp head tail cmp wc tr
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-container.XXXXXX")
    run_id=$(printf '%s' "${workspace##*/}" | tr '[:upper:].' '[:lower:]-')
    mkdir "$workspace/evidence"
    if [[ -n "$artifacts" ]]; then
        mkdir -p "$artifacts"
        evidence_dir=$(mktemp -d "$artifacts/run.XXXXXX")
        printf 'Container evidence: %s\n' "$evidence_dir"
    fi
    # RESP bulk lengths use literal dollar signs.
    # shellcheck disable=SC2016
    printf '*1\r\n$4\r\nPING\r\n' > "$workspace/ping.request"
    printf '+PONG\r\n' > "$workspace/ping.expected"

    docker_call image inspect "$image" > "$workspace/evidence/image.json"
    jq -e '.[0] | .Os == "linux" and .Architecture == "amd64" and
      (.Config | .User == "10001:10001" and .WorkingDir == "/data" and
        .StopSignal == "SIGTERM" and
        .Entrypoint == ["/usr/local/bin/kgcache"] and
        .Cmd == ["/etc/kgcache/kgcache.conf"] and
        (.ExposedPorts | has("6379/tcp")) and (.Volumes | not))' \
        "$workspace/evidence/image.json" > /dev/null
    engine_arch=$(docker_call info --format '{{.Architecture}}')
    native=false
    if [[ "$engine_arch" == x86_64 || "$engine_arch" == amd64 ]]; then
        native=true
    else
        [[ "$allow_emulation" == true ]] ||
            release_fail 'native amd64 engine required; use --allow-emulation for development'
    fi
    image=$(jq -er '.[0].Id' "$workspace/evidence/image.json")
    network="$run_id-network"
    register network "$network"
    docker_call network create --label "io.kgcache.container-test=$run_id" \
        "$network" > /dev/null

    smoke "$image" "$network"
    jq --null-input \
        --slurpfile image "$workspace/evidence/image.json" \
        --slurpfile build "$workspace/evidence/build-info.json" \
        --argjson native "$native" \
        '{passed: true, image_id: $image[0][0].Id, image_size_bytes: $image[0][0].Size,
          build: $build[0], native_execution: $native}' \
        > "$workspace/evidence/result.json"
    cat "$workspace/evidence/result.json"
}

case "${1:-}" in
    --exchange)
        shift
        exchange "$@"
        ;;
    *) main "$@" ;;
esac

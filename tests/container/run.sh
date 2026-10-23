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
peer_pids=()
guide_project=

source "$RELEASE_ROOT/tests/container/health.sh"
source "$RELEASE_ROOT/tests/container/compose.sh"

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
        [[ -s "$prefix.inspect.json" ]] && continue
        if docker_call container inspect "$name" > "$workspace/inspect.json" 2> /dev/null; then
            mv "$workspace/inspect.json" "$prefix.inspect.json" || return 1
            docker_call logs --tail 150 "$name" \
                > "$workspace/stdout" 2> "$workspace/stderr" || return 1
            tail -c 32768 "$workspace/stdout" > "$prefix.stdout.log" || return 1
            tail -c 32768 "$workspace/stderr" > "$prefix.stderr.log" || return 1
        fi
    done
    for name in "$workspace/evidence/"*.log; do
        [[ -f "$name" ]] || continue
        tail -c 32768 "$name" > "$workspace/bounded.log" || return 1
        mv "$workspace/bounded.log" "$name" || return 1
    done
}

# Cleanup handles command statuses explicitly and must try every owned resource.
# shellcheck disable=SC2310
cleanup() {
    local status=$? failed=false index kind name found label fixture_uid fixture_gid

    trap - EXIT
    trap '' INT TERM
    for found in ${peer_pids[@]+"${peer_pids[@]}"}; do
        kill -TERM "$found" 2> /dev/null || true
        wait "$found" 2> /dev/null || true
    done
    if [[ -n "$workspace" ]]; then
        collect_evidence || failed=true
    fi

    for ((index = ${#resource_names[@]} - 1; index >= 0; index--)); do
        kind=${resource_kinds[index]}
        name=${resource_names[index]}
        if ! found=$(docker_call "$kind" inspect "$name" 2>&1); then
            if [[ "$found" != *'No such'* && "$found" != *'no such'* &&
                "$found" != *"network $name not found"* ]]; then
                printf 'container: cannot inspect %s: %s\n' "$name" "$found" >&2
                failed=true
            fi
            continue
        fi
        if ! label=$(printf '%s\n' "$found" | jq -er \
            --arg guide "$guide_project" --arg run "$run_id" \
            '.[0] | (.Config.Labels // .Labels) |
            .["io.kgcache.container-test"] //
            (if $guide != "" and .["com.docker.compose.project"] == $guide
                then $run else null end)'); then
            failed=true
            continue
        fi
        if [[ "$label" != "$run_id" ]]; then
            printf 'container: refusing to remove unowned resource %s\n' "$name" >&2
            failed=true
            continue
        fi
        if [[ "$kind" == container ]]; then
            if [[ "$name" == "$run_id-storage-helper" && -d "$workspace/bind" ]]; then
                # Restore only this run's bind fixture for host-side removal.
                fixture_uid=$(id -u) || failed=true
                fixture_gid=$(id -g) || failed=true
                docker_call exec "$name" chown -R "$fixture_uid:$fixture_gid" \
                    /fixtures/bind || failed=true
                docker_call exec "$name" chmod -R u+rwX /fixtures/bind || failed=true
            fi
            docker_call container rm --force "$name" > /dev/null || failed=true
        else
            docker_call "$kind" rm "$name" > /dev/null || failed=true
        fi
    done

    if [[ -n "$evidence_dir" ]]; then
        cp -R "$workspace/evidence/." "$evidence_dir/" || failed=true
    fi
    if [[ "$failed" == true ]]; then
        printf 'container: evidence collection or resource cleanup failed\n' >&2
    fi
    if [[ "$status" != 0 && -n "$workspace" ]]; then
        for found in "$workspace/evidence/"*.stderr.log; do
            [[ -f "$found" ]] || continue
            tail -c 8192 "$found" >&2
        done
    fi
    if [[ -n "$workspace" ]]; then
        if [[ "$status" == 0 && "$failed" == false ]]; then
            cat "$workspace/evidence/result.json"
        fi
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
    timeout --signal=TERM --kill-after=2s 30s \
        bash "$RELEASE_ROOT/tests/container/run.sh" --exchange "$@"
}

measure() {
    local name=$1 TIMEFORMAT='%3R'

    shift
    { time "$@"; } 2> "$workspace/evidence/$name.seconds"
}

command_reply() {
    local port=$1 expected=$2 arg

    shift 2
    {
        printf '*%d\r\n' "$#"
        for arg in "$@"; do
            printf '$%d\r\n%s\r\n' "${#arg}" "$arg"
        done
    } > "$workspace/command.request"
    printf '%b' "$expected" > "$workspace/command.expected"
    request 127.0.0.1 "$port" "$workspace/command.request" \
        "$workspace/command.expected" "$workspace/command.actual"
}

create_volume() {
    register volume "$1"
    docker_call volume create --label "io.kgcache.container-test=$run_id" \
        "$1" > /dev/null
}

create_server() {
    local image=$1 network=$2 name=$3 mount=$4
    local options=()

    shift 4
    while [[ $# -gt 0 && "$1" != -- ]]; do
        options+=("$1")
        shift
    done
    if [[ ${1:-} == -- ]]; then
        shift
    fi
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
        ${options[@]+"${options[@]}"} "$image" "$@" > /dev/null
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

remove_server() {
    # Preserve state before a replacement removes the old container.
    docker_call container inspect "$1" > "$workspace/evidence/$1.inspect.json"
    docker_call logs --tail 150 "$1" \
        > "$workspace/evidence/$1.stdout.log" 2> "$workspace/evidence/$1.stderr.log"
    docker_call container rm "$1" > /dev/null
}

file_hash() {
    # The path argument is expanded by the container shell.
    # shellcheck disable=SC2016
    docker_call exec "$1" sh -c \
        'if [ -f "$1" ]; then sha256sum "$1"; fi' sh "$2"
}

wait_persistence() {
    local name=$1 path=$2 previous=$3 deadline current processes lines

    deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        processes=$(docker_call top "$name" -eo pid,ppid,stat,comm)
        lines=$(printf '%s\n' "$processes" | wc -l)
        current=$(file_hash "$name" "$path")
        printf '%s\n%s\n' "$processes" "$current" >> "$workspace/evidence/children.log"
        if ((lines == 2)) && [[ -n "$current" && "$current" != "$previous" ]]; then
            return
        fi
        sleep 0.05
    done
    release_fail 'persistence did not finish and reap its child while PID 1 was alive'
}

check_layout() {
    local name=$1 layout status dependencies actual_sha actual_version

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
        'for tool in zig python3 cc kgcache-controlled-server kgcache-fake-server readelf redis-cli curl nc netcat; do
            if command -v "$tool"; then exit 1; fi
        done'

    docker_call exec "$name" cat /usr/share/kgcache/build-info.json \
        > "$workspace/evidence/build-info.json"
    actual_sha=$(docker_call exec "$name" sha256sum /usr/local/bin/kgcache)
    actual_sha=${actual_sha%% *}
    actual_version=$(docker_call exec "$name" /usr/local/bin/kgcache --version)
    printf '%s\n' "$actual_version" > "$workspace/evidence/version.log"
    jq -e -L "$RELEASE_ROOT/tools/release" --arg sha "$actual_sha" \
        --arg version "$actual_version" --slurpfile image "$workspace/evidence/image.json" \
        --from-file "$RELEASE_ROOT/tools/container/validate-image.jq" \
        "$workspace/evidence/build-info.json" > /dev/null
}

raw_peer() {
    local image=$1 network=$2 name=$3 host=$4 input=$5 expected=$6

    register container "$name"
    # Expand the endpoint and reply size in the peer container.
    # shellcheck disable=SC2016
    docker_call create --name "$name" --platform linux/amd64 --read-only \
        --label "io.kgcache.container-test=$run_id" --network "$network" \
        --mount "type=bind,src=$input,dst=/checks/request,readonly" \
        --mount "type=bind,src=$expected,dst=/checks/expected,readonly" \
        --entrypoint bash "$image" -ec \
        'exec 3<> "/dev/tcp/$1/6379"
        cat /checks/request >&3
        size=$(wc -c < /checks/expected)
        head -c "$size" <&3 | cmp - /checks/expected' bash "$host" > /dev/null
    docker_call start --attach "$name"
    docker_call container inspect "$name" | jq -e \
        '.[0].State.ExitCode == 0' > /dev/null
}

smoke() {
    local image=$1 network=$2 name="$run_id-smoke" volume="$run_id-smoke" port

    create_volume "$volume"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data"
    measure cold-start start_server "$name"
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
    raw_peer "$image" "$network" "$run_id-peer" "$name" \
        "$workspace/binary.request" "$workspace/binary.expected"
    stop_server "$name"
    remove_server "$name"
    name="$run_id-replacement"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data"
    start_server "$name"
    port=$(cat "$workspace/port")
    # RESP bulk length markers are literal.
    # shellcheck disable=SC2016
    command_reply "$port" '$15\r\nbinary\000\377\r\nvalue\r\n' GET container-key
    stop_server "$name"
}

recovery() {
    local image=$1 network=$2 policy=$3 name="$run_id-recovery-$3"
    local volume="$run_id-recovery-$3" port config="$workspace/$3.conf" old

    cp "$RELEASE_ROOT/containers/kgcache.conf" "$config"
    case "$policy" in
        always) printf 'appendfsync always\n' >> "$config" ;;
        snapshot) printf 'appendonly no\n' >> "$config" ;;
    esac
    chmod 0444 "$config"
    create_volume "$volume"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data" \
        --mount "type=bind,src=$config,dst=/etc/kgcache/kgcache.conf,readonly"
    start_server "$name"
    port=$(cat "$workspace/port")
    command_reply "$port" '+OK\r\n' SET durable value
    case "$policy" in
        everysec)
            # A completed rewrite establishes the durable prefix. No assertion
            # requires an arbitrary last everysec write to survive SIGKILL.
            old=$(file_hash "$name" /data/appendonlydir/appendonly.aof.manifest)
            command_reply "$port" '+Background append only file rewriting started\r\n' BGREWRITEAOF
            wait_persistence "$name" /data/appendonlydir/appendonly.aof.manifest "$old"
            ;;
        snapshot) command_reply "$port" '+OK\r\n' SAVE ;;
    esac
    docker_call kill --signal KILL "$name" > /dev/null
    docker_call inspect "$name" | jq -e \
        '.[0].State | .ExitCode == 137 and (.OOMKilled | not)' > /dev/null
    remove_server "$name"
    name="$name-new"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data" \
        --mount "type=bind,src=$config,dst=/etc/kgcache/kgcache.conf,readonly"
    start_server "$name"
    port=$(cat "$workspace/port")
    # shellcheck disable=SC2016
    command_reply "$port" '$5\r\nvalue\r\n' GET durable
    stop_server "$name"
}

expect_startup_failure() {
    local name=$1 source=$2 code logs

    docker_call start "$name" > /dev/null
    code=$(docker_call wait "$name")
    [[ "$code" != 0 ]] || release_fail 'invalid startup unexpectedly succeeded'
    logs=$(docker_call logs --tail 100 "$name" 2>&1)
    [[ "$logs" == *"$source"* && "$logs" != *'started and listening'* ]] ||
        release_fail "startup did not fail before readiness with $source"
}

storage_cases() {
    local image=$1 network=$2 helper="$run_id-storage-helper" mount name kind
    local volume="$run_id-permissions" before after port config="$workspace/invalid.conf"
    local snapshot_config="$workspace/storage-snapshot.conf" code logs

    create_volume "$volume"
    register container "$helper"
    docker_call create --name "$helper" --platform linux/amd64 --user 0:0 \
        --label "io.kgcache.container-test=$run_id" \
        --mount "type=volume,src=$volume,dst=/volume" \
        --mount "type=bind,src=$workspace,dst=/fixtures" \
        --entrypoint /bin/sleep "$image" 600 > /dev/null
    docker_call start "$helper" > /dev/null
    mkdir "$workspace/bind"
    docker_call exec "$helper" chown 10001:10001 /fixtures/bind
    docker_call exec "$helper" chmod 0750 /fixtures/bind
    name="$run_id-bind"
    mount="type=bind,src=$workspace/bind,dst=/data"
    create_server "$image" "$network" "$name" "$mount"
    start_server "$name"
    port=$(cat "$workspace/port")
    command_reply "$port" '+OK\r\n' SET bind works
    stop_server "$name"
    docker_call exec "$helper" test -s /fixtures/bind/appendonlydir/appendonly.aof.1.incr

    # Existing AOF parts remain writable, but new files in /data are blocked.
    # This is the regression that a directory-open check alone does not catch.
    docker_call exec "$helper" chmod 0550 /fixtures/bind
    name="$run_id-existing-unwritable"
    create_server "$image" "$network" "$name" "$mount"
    expect_startup_failure "$name" 'cannot prepare persistence directory'
    docker_call exec "$helper" chmod 0750 /fixtures/bind

    cp "$RELEASE_ROOT/containers/kgcache.conf" "$snapshot_config"
    printf 'appendonly no\n' >> "$snapshot_config"
    chmod 0444 "$snapshot_config"
    name="$run_id-shutdown-error"
    create_server "$image" "$network" "$name" "$mount" \
        --mount "type=bind,src=$snapshot_config,dst=/etc/kgcache/kgcache.conf,readonly"
    start_server "$name"
    port=$(cat "$workspace/port")
    command_reply "$port" '+OK\r\n' SET shutdown error
    docker_call exec "$helper" chmod 0550 /fixtures/bind
    docker_call kill --signal TERM "$name" > /dev/null
    code=$(docker_call wait "$name")
    logs=$(docker_call logs --tail 100 "$name" 2>&1)
    [[ "$code" == 1 && "$logs" == *'app: server shutdown failed'* ]] ||
        release_fail 'storage errors during shutdown must remain visible and nonzero'
    docker_call exec "$helper" chmod 0750 /fixtures/bind

    # A readable root-owned directory tests create access, rather than access
    # to the directory itself. The service must leave this owner and mode alone.
    docker_call exec "$helper" touch /volume/existing
    docker_call exec "$helper" chown 0:0 /volume
    docker_call exec "$helper" chmod 0755 /volume
    before=$(docker_call exec "$helper" stat -c '%u:%g:%a' /volume)
    for kind in wrong-owner read-only; do
        name="$run_id-$kind"
        mount="type=volume,src=$volume,dst=/data"
        if [[ "$kind" == read-only ]]; then
            docker_call exec "$helper" chown 10001:10001 /volume
            before=$(docker_call exec "$helper" stat -c '%u:%g:%a' /volume)
            mount="$mount,readonly"
        fi
        create_server "$image" "$network" "$name" "$mount"
        expect_startup_failure "$name" 'cannot prepare persistence directory'
        if [[ "$kind" == read-only ]]; then
            logs=$(docker_call logs --tail 100 "$name" 2>&1)
            [[ "$logs" == *ReadOnlyFileSystem* ]] || release_fail 'expected a read-only filesystem error'
        fi
        after=$(docker_call exec "$helper" stat -c '%u:%g:%a' /volume)
        [[ "$before" == "$after" ]] || release_fail 'service modified mount permissions'
    done
    printf 'port invalid\n' > "$config"
    chmod 0444 "$config"
    name="$run_id-invalid-config"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data" \
        --mount "type=bind,src=$config,dst=/etc/kgcache/kgcache.conf,readonly"
    expect_startup_failure "$name" InvalidValue
}

# This helper runs only through docker exec during the active-child cases.
# Stop the real child so shutdown can be observed before it is resumed.
freeze_child() {
    local deadline=$((SECONDS + 30)) stat pid _comm state parent _rest

    printf 'ready\n' > /data/.watcher-ready
    while ((SECONDS < deadline)); do
        for stat in /proc/[0-9]*/stat; do
            if read -r pid _comm state parent _rest < "$stat" 2> /dev/null; then
                [[ "$parent" == 1 && "$pid" != 1 && "$state" != Z ]] || continue
                if kill -STOP "$pid" 2> /dev/null; then
                    if read -r pid _comm state parent _rest < "$stat" 2> /dev/null; then
                        if [[ "$state" == T ]]; then
                            printf '%s\n' "$pid" > /data/.held-child
                            return
                        fi
                    fi
                fi
            fi
        done
        sleep 0.005
    done
    return 1
}

wait_file() {
    local name=$1 path=$2 deadline=$((SECONDS + 30))

    while ((SECONDS < deadline)); do
        # docker_call has one command and returns its status directly.
        # shellcheck disable=SC2310
        if docker_call exec "$name" test -s "$path"; then
            return
        fi
        sleep 0.02
    done
    release_fail "timed out waiting for $path"
}

hold_peer() {
    local host=$1 port=$2 input=$3 ready=$4 control=$5 _ignored

    exec 3<> "/dev/tcp/$host/$port"
    cat "$input" >&3
    printf 'ready\n' > "$ready"
    read -r _ignored < "$control"
}

latency_peer() {
    local host=$1 port=$2 index reply

    exec 3<> "/dev/tcp/$host/$port"
    for ((index = 0; index < 64; index++)); do
        # RESP bulk lengths use literal dollar signs.
        # shellcheck disable=SC2016
        printf '*1\r\n$4\r\nPING\r\n' >&3
        IFS= read -r reply <&3
        [[ "$reply" == $'+PONG\r' ]] || return 1
    done
}

start_peer() {
    local port=$1 input=$2 label=$3 deadline=$((SECONDS + 5))

    mkfifo "$workspace/$label.control"
    timeout --signal=TERM --kill-after=2s 120s \
        bash "$RELEASE_ROOT/tests/container/run.sh" --hold \
        127.0.0.1 "$port" "$input" "$workspace/$label.ready" \
        "$workspace/$label.control" &
    peer_pids+=("$!")
    while ((SECONDS < deadline)); do
        [[ -s "$workspace/$label.ready" ]] && return
        sleep 0.02
    done
    release_fail 'client did not establish its connection'
}

# The frames here use literal RESP length markers.
# shellcheck disable=SC2016
load_workload() {
    local port=$1 value index

    value=$(printf '%4096s' '')
    for ((index = 0; index < 4096; index++)); do
        printf '*3\r\n$3\r\nSET\r\n$8\r\nload%04d\r\n$4096\r\n%s\r\n' "$index" "$value"
    done > "$workspace/load.request"
    for ((index = 0; index < 4096; index++)); do
        printf '+OK\r\n'
    done > "$workspace/load.expected"
    measure writes request 127.0.0.1 "$port" "$workspace/load.request" \
        "$workspace/load.expected" "$workspace/load.actual"

    {
        printf '*3\r\n$3\r\nSET\r\n$4\r\nslow\r\n$262144\r\n'
        head -c 262144 /dev/zero
        printf '\r\n'
    } > "$workspace/slow-value.request"
    printf '+OK\r\n' > "$workspace/ok.expected"
    request 127.0.0.1 "$port" "$workspace/slow-value.request" \
        "$workspace/ok.expected" "$workspace/slow-value.actual"
    for ((index = 0; index < 128; index++)); do
        printf '*2\r\n$3\r\nGET\r\n$4\r\nslow\r\n'
    done > "$workspace/slow.request"
}

process_lifecycle() {
    local image=$1 network=$2 volume="$run_id-process" name="$run_id-process"
    local port index kind old path watcher child state peak

    create_volume "$volume"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data" \
        --memory 256m --cpus 1
    start_server "$name"
    port=$(cat "$workspace/port")
    load_workload "$port"
    measure ping-roundtrips timeout --signal=TERM --kill-after=2s 10s \
        bash "$RELEASE_ROOT/tests/container/run.sh" --latency 127.0.0.1 "$port"
    peak=$(docker_call exec "$name" cat /sys/fs/cgroup/memory.peak)
    printf '%s\n' "$peak" > "$workspace/evidence/write-memory-peak.bytes"

    for ((index = 0; index < 3; index++)); do
        command_reply "$port" '+OK\r\n' SET cycle "$index"
        old=$(file_hash "$name" /data/dump.kgc)
        command_reply "$port" '+Background saving started\r\n' BGSAVE
        wait_persistence "$name" /data/dump.kgc "$old"
        path=/data/appendonlydir/appendonly.aof.manifest
        old=$(file_hash "$name" "$path")
        command_reply "$port" '+Background append only file rewriting started\r\n' BGREWRITEAOF
        wait_persistence "$name" "$path" "$old"
    done
    peak=$(docker_call exec "$name" cat /sys/fs/cgroup/memory.peak)
    printf '%s\n' "$peak" > "$workspace/evidence/persistence-memory-peak.bytes"

    watcher=$(declare -f freeze_child)
    : > "$workspace/idle.request"
    for kind in snapshot rewrite; do
        start_peer "$port" "$workspace/idle.request" "idle-$kind"
        start_peer "$port" "$workspace/slow.request" "slow-$kind"
        docker_call exec --detach "$name" bash -c "$watcher; freeze_child"
        # The marker contains one byte so test -s proves the watcher is armed.
        wait_file "$name" /data/.watcher-ready
        if [[ "$kind" == snapshot ]]; then
            command_reply "$port" '+Background saving started\r\n' BGSAVE
        else
            command_reply "$port" '+Background append only file rewriting started\r\n' BGREWRITEAOF
        fi
        wait_file "$name" /data/.held-child
        child=$(docker_call exec "$name" cat /data/.held-child)
        printf '%s: child %s stopped before SIGTERM\n' "$kind" "$child" \
            >> "$workspace/evidence/active-children.log"
        docker_call kill --signal TERM "$name" > /dev/null
        state=$(docker_call inspect --format '{{.State.Running}}' "$name")
        [[ "$state" == true ]] || release_fail 'PID 1 exited before settling its child'
        expect_probe_failure "$name" /etc/kgcache/kgcache.conf
        # The child PID is a positional argument to the container shell.
        # shellcheck disable=SC2016
        docker_call exec "$name" bash -c 'kill -CONT "$1"' bash "$child"
        timeout --signal=TERM --kill-after=3s 40s docker wait "$name" > /dev/null
        docker_call inspect "$name" | jq -e \
            '.[0].State | .ExitCode == 0 and (.OOMKilled | not)' > /dev/null
        remove_server "$name"
        name="$run_id-after-$kind"
        create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data" \
            --memory 256m --cpus 1
        measure replay start_server "$name"
        port=$(cat "$workspace/port")
        command_reply "$port" '+PONG\r\n' PING
        # shellcheck disable=SC2016
        command_reply "$port" '$1\r\n2\r\n' GET cycle
        docker_call exec "$name" rm -f /data/.watcher-ready /data/.held-child
    done
    stop_server "$name"
}

main() {
    local image='' artifacts='' allow_emulation=false network native engine_arch
    local build=false guide=false

    export PATH="$RELEASE_ROOT/.client-tools/go/bin:$RELEASE_ROOT/.client-tools/node/bin:$PATH"
    export GOTOOLCHAIN=local GOWORK=off

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
            --build)
                build=true
                shift
                ;;
            --guide)
                guide=true
                shift
                ;;
            --help)
                printf 'Usage: bash tests/container/run.sh (--image IMAGE | --build) [--guide] [--artifacts DIR] [--allow-emulation]\n'
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done

    if [[ "$build" == true ]]; then
        [[ -z "$image" ]] || release_fail '--build and --image cannot be combined'
    else
        [[ -n "$image" ]] || release_fail '--image or --build is required'
        [[ "$guide" == false ]] || release_fail '--guide requires --build in an isolated environment'
    fi
    release_require_commands docker timeout jq mktemp head tail cmp wc tr
    compose_preflight
    engine_arch=$(docker_call info --format '{{.Architecture}}')
    native=false
    if [[ "$engine_arch" == x86_64 || "$engine_arch" == amd64 ]]; then
        native=true
    else
        [[ "$allow_emulation" == true ]] ||
            release_fail 'native amd64 engine required; use --allow-emulation for development'
    fi
    if [[ "$build" == true ]]; then
        docker_call buildx version > /dev/null
    fi
    if [[ "$guide" == true ]]; then
        release_require_commands redis-cli
        # docker_call returns the status of its one bounded command.
        # shellcheck disable=SC2310
        if docker_call image inspect kgcache:local > /dev/null 2>&1; then
            release_fail '--guide requires an isolated image store without kgcache:local'
        fi
    fi
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

    docker_call compose version > "$workspace/evidence/compose-version.log"
    docker_call version > "$workspace/evidence/docker-version.log"
    if [[ "$guide" == true ]]; then
        guide_project="$run_id-guide"
    fi
    if [[ "$build" == true ]]; then
        compose_build "$guide"
        image=$(cat "$workspace/built-image-id")
    fi
    docker_call image inspect "$image" > "$workspace/evidence/image.json"
    jq -e '.[0] | .Os == "linux" and .Architecture == "amd64" and
      (.Config | .User == "10001:10001" and .WorkingDir == "/data" and
        .StopSignal == "SIGTERM" and
        (.Healthcheck | .Test == ["CMD", "/usr/local/bin/kgcache", "healthcheck", "/etc/kgcache/kgcache.conf"] and
          .Interval == 30000000000 and .Timeout == 2000000000 and
          .StartPeriod == 60000000000 and .Retries == 3) and
        .Entrypoint == ["/usr/local/bin/kgcache"] and
        .Cmd == ["/etc/kgcache/kgcache.conf"] and
        (.ExposedPorts | has("6379/tcp")) and (.Volumes | not))' \
        "$workspace/evidence/image.json" > /dev/null
    image=$(jq -er '.[0].Id' "$workspace/evidence/image.json")
    network="$run_id-network"
    register network "$network"
    docker_call network create --label "io.kgcache.container-test=$run_id" \
        "$network" > /dev/null

    smoke "$image" "$network"
    health_cases "$image" "$network"
    compose_health "$image" "$network"
    storage_cases "$image" "$network"
    recovery "$image" "$network" everysec
    recovery "$image" "$network" always
    recovery "$image" "$network" snapshot
    process_lifecycle "$image" "$network"
    compose_cases "$image"
    if [[ "$guide" == true ]]; then
        compose_guide "$image"
    fi
    jq --null-input \
        --slurpfile image "$workspace/evidence/image.json" \
        --slurpfile build "$workspace/evidence/build-info.json" \
        --argjson native "$native" \
        --argjson guide "$guide" \
        --rawfile cold "$workspace/evidence/cold-start.seconds" \
        --rawfile replay "$workspace/evidence/replay.seconds" \
        --rawfile ping "$workspace/evidence/ping-roundtrips.seconds" \
        --rawfile write_peak "$workspace/evidence/write-memory-peak.bytes" \
        --rawfile persistence_peak "$workspace/evidence/persistence-memory-peak.bytes" \
        '{passed: true, image_id: $image[0][0].Id, image_size_bytes: $image[0][0].Size,
          build: $build[0], native_execution: $native,
          qualified_amd64: ($native and ($build[0].source.dirty | not)),
          compose: {passed: true, guide_checked: $guide,
            clients: ["go-redis-v9.22.0", "node-redis-6.2.1"]},
          workload: {keys: 4096, value_bytes: 4096, memory_limit_bytes: 268435456, cpus: 1},
          measurements: {cold_start_seconds: ($cold | tonumber), replay_seconds: ($replay | tonumber),
            ping_mean_ms: (($ping | tonumber) * 1000 / 64),
            write_memory_peak_bytes: ($write_peak | tonumber),
            persistence_memory_peak_bytes: ($persistence_peak | tonumber)}}' \
        > "$workspace/evidence/result.json"
}

case "${1:-}" in
    --latency)
        shift
        latency_peer "$@"
        ;;
    --hold)
        shift
        hold_peer "$@"
        ;;
    --exchange)
        shift
        exchange "$@"
        ;;
    --run)
        shift
        main "$@"
        ;;
    *)
        exec timeout --signal=TERM --kill-after=60s 1800s \
            bash "$RELEASE_ROOT/tests/container/run.sh" --run "$@"
        ;;
esac

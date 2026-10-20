#!/usr/bin/env bash
# Sourced by run.sh. All fixtures use the same owned resources and deadlines.
# The runner defines these variables before sourcing this file.
: "${workspace?}" "${run_id?}"

wait_health() {
    local name=$1 expected=$2 deadline=$((SECONDS + 75)) status

    while ((SECONDS < deadline)); do
        docker_call inspect "$name" > "$workspace/health.json"
        status=$(jq -er '.[0].State.Health.Status' "$workspace/health.json")
        if [[ "$status" == "$expected" ]]; then
            cp "$workspace/health.json" "$workspace/evidence/$name-$expected.json"
            return
        fi
        sleep 0.2
    done
    release_fail "$name did not become $expected"
}

expect_probe_failure() {
    local name=$1 status lines

    shift
    # Failure is the assertion. Keep its status and output for inspection.
    if docker_call exec "$name" /usr/local/bin/kgcache healthcheck "$@" \
        > "$workspace/probe.stdout" 2> "$workspace/probe.stderr"; then
        release_fail 'incorrect endpoint unexpectedly passed its health probe'
    else
        status=$?
    fi
    [[ "$status" == 1 && ! -s "$workspace/probe.stdout" ]] ||
        release_fail 'health probe must fail with status 1 and empty stdout'
    lines=$(wc -l < "$workspace/probe.stderr")
    ((lines == 1)) ||
        release_fail 'health probe must emit one diagnostic'
}

health_cases() {
    local image=$1 network=$2 volume="$run_id-health" name="$run_id-health"
    local config="$workspace/health.conf" port state

    create_volume "$volume"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data"
    start_server "$name"
    wait_health "$name" starting
    wait_health "$name" healthy
    docker_call exec "$name" /usr/local/bin/kgcache healthcheck /etc/kgcache/kgcache.conf \
        > "$workspace/probe.stdout" 2> "$workspace/probe.stderr"
    [[ ! -s "$workspace/probe.stdout" && ! -s "$workspace/probe.stderr" ]] ||
        release_fail 'successful probe must be silent'
    port=$(cat "$workspace/port")
    command_reply "$port" '+OK\r\n' SET health-replay value
    stop_server "$name"
    remove_server "$name"

    # Delay only this replay fixture. Production startup still execs kgcache.
    # The longer start period must suppress failures until the gate is released.
    name="$run_id-health-replay"
    # The fixture checks for a marker inside its own mounted volume.
    # shellcheck disable=SC2016
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data" \
        --health-interval 1s --health-start-period 60s --health-retries 2 \
        --entrypoint /bin/bash -- -ec \
        'until [ -f /data/.health-start ]; do sleep 0.1; done
        exec /usr/local/bin/kgcache /etc/kgcache/kgcache.conf'
    docker_call start "$name" > /dev/null
    wait_health "$name" starting
    # Docker may use a slower check interval during startup. Wait for a real failure.
    state=$((SECONDS + 25))
    while ((SECONDS < state)); do
        docker_call inspect "$name" > "$workspace/health-start.json"
        if jq -e '.[0].State.Health | .Status == "starting" and
            .FailingStreak == 0 and any(.Log[]; .ExitCode == 1)' \
            "$workspace/health-start.json" > /dev/null; then
            break
        fi
        sleep 0.2
    done
    jq -e '.[0].State.Health | .Status == "starting" and .FailingStreak == 0 and
        any(.Log[]; .ExitCode == 1)' "$workspace/health-start.json" > /dev/null
    cp "$workspace/health-start.json" "$workspace/evidence/replay-starting.json"
    docker_call exec "$name" touch /data/.health-start
    wait_health "$name" healthy
    docker_call inspect "$name" > "$workspace/health-replay.json"
    port=$(jq -er '.[0].NetworkSettings.Ports["6379/tcp"][0].HostPort' \
        "$workspace/health-replay.json")
    # shellcheck disable=SC2016
    command_reply "$port" '$5\r\nvalue\r\n' GET health-replay
    stop_server "$name"

    # A mounted shared config changes both the server and default health command.
    cp "$RELEASE_ROOT/containers/kgcache.conf" "$config"
    printf 'port 7000\n' >> "$config"
    chmod 0444 "$config"
    name="$run_id-health-mounted"
    create_server "$image" "$network" "$name" "type=volume,src=$volume,dst=/data" \
        --mount "type=bind,src=$config,dst=/etc/kgcache/kgcache.conf,readonly" \
        --health-interval 1s --health-start-period 1s --health-retries 2
    docker_call start "$name" > /dev/null
    wait_health "$name" healthy
    expect_probe_failure "$name" /etc/kgcache/kgcache.conf --port 6379

    # PID 1 is stopped while its TCP listener remains open. Probes must time out.
    docker_call kill --signal STOP "$name" > /dev/null
    wait_health "$name" unhealthy
    jq -e '.[0].State.Health | .FailingStreak >= 2 and
        any(.Log[]; .ExitCode == 1 and (.Output | contains("deadline expired")))' \
        "$workspace/evidence/$name-unhealthy.json" > /dev/null
    docker_call kill --signal CONT "$name" > /dev/null
    wait_health "$name" healthy
    stop_server "$name"
}

compose_health() {
    local image=$1 network=$2 name="$run_id-health-compose" volume="$run_id-health-compose"
    local HEALTH_IMAGE=$image HEALTH_NETWORK=$network HEALTH_VOLUME=$volume
    local HEALTH_CONTAINER=$name HEALTH_RUN_ID=$run_id HEALTH_PROBE_PORT=7000

    export HEALTH_IMAGE HEALTH_NETWORK HEALTH_VOLUME HEALTH_CONTAINER HEALTH_RUN_ID HEALTH_PROBE_PORT
    create_volume "$volume"
    register container "$name"
    docker_call compose --project-name "$run_id-health" \
        --file "$RELEASE_ROOT/tests/container/health.compose.yaml" \
        config > "$workspace/evidence/health-compose.yaml"
    docker_call compose --project-name "$run_id-health" \
        --file "$RELEASE_ROOT/tests/container/health.compose.yaml" \
        up --detach --no-build --pull never
    wait_health "$name" healthy
    stop_server "$name"
    remove_server "$name"

    HEALTH_PROBE_PORT=7001
    name="$run_id-health-mismatch"
    HEALTH_CONTAINER=$name
    register container "$name"
    docker_call compose --project-name "$run_id-health" \
        --file "$RELEASE_ROOT/tests/container/health.compose.yaml" \
        up --detach --no-build --pull never
    wait_health "$name" unhealthy
    # Prove the server responds on 7000 while the configured health port fails.
    docker_call exec "$name" /usr/local/bin/kgcache healthcheck \
        /etc/kgcache/kgcache.conf --port 7000
    expect_probe_failure "$name" /etc/kgcache/kgcache.conf --port 7001
    stop_server "$name"
}

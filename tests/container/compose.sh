#!/usr/bin/env bash
# Sourced by run.sh. Compose variants come from the checked-in deployment.
: "${workspace?}" "${run_id?}" "${guide_project?}"

compose_call() {
    local file=$1 project=$2

    shift 2
    timeout --signal=TERM --kill-after=5s 150s docker compose \
        --project-directory "$RELEASE_ROOT" --project-name "$project" \
        --file "$file" "$@"
}

compose_preflight() {
    local help registry="$RELEASE_ROOT/tests/integration/clients/matrix.json"
    local actual expected

    docker_call version > /dev/null
    help=$(docker_call compose up --help)
    [[ "$help" == *--wait-timeout* && "$help" == *--no-build* ]] ||
        release_fail 'Compose must support up --wait --wait-timeout and --no-build'
    docker_call compose port --help > /dev/null
    docker_call compose --file "$RELEASE_ROOT/docker-compose.yml" config --format json > /dev/null
    release_require_commands make "${GO:-go}" "${NODE:-node}" npm
    timeout --signal=TERM --kill-after=3s 30s \
        make -C "$RELEASE_ROOT" list-clients > /dev/null
    expected=$(jq -er '.profiles[] | select(.id == "go-redis-v9.22.0") | .runtimeVersion' "$registry")
    actual=$("${GO:-go}" version)
    [[ "$actual" == *"go$expected "* ]] ||
        release_fail 'install the registered Go runtime before container qualification'
    expected=$(jq -er '.profiles[] | select(.id == "node-redis-6.2.1") | .runtimeVersion' "$registry")
    actual=$("${NODE:-node}" --version)
    [[ "$actual" == "v$expected" ]] ||
        release_fail 'install the registered Node runtime before container qualification'
    expected=$(jq -er '.profiles[] | select(.id == "node-redis-6.2.1") | .packageManagerVersion' "$registry")
    actual=$(npm --version)
    [[ "$actual" == "$expected" ]] ||
        release_fail 'install the registered npm version before container qualification'
}

compose_build() {
    local guide=$1 file="$workspace/source-compose.json" project="$run_id-build"
    local tag="kgcache:test-$run_id"

    if [[ "$guide" == true ]]; then
        file="$RELEASE_ROOT/docker-compose.yml"
        project=$guide_project
        tag=kgcache:local
    else
        compose_model "$tag" "$project" "$file"
        jq --slurpfile base "$workspace/base-compose.json" \
            '.services.kgcache.build = $base[0].services.kgcache.build' \
            "$file" > "$file.next"
        mv "$file.next" "$file"
    fi
    compose_call "$file" "$project" config --quiet
    if ! timeout --signal=TERM --kill-after=10s 600s docker compose \
        --project-directory "$RELEASE_ROOT" --project-name "$project" --file "$file" build \
        > "$workspace/evidence/compose-build.log" 2>&1; then
        tail -c 8192 "$workspace/evidence/compose-build.log" >&2
        release_fail 'Compose source build failed'
    fi
    docker_call image inspect --format '{{.Id}}' "$tag" > "$workspace/built-image-id"
}

compose_model() {
    local image=$1 project=$2 output=$3

    docker_call compose --file "$RELEASE_ROOT/docker-compose.yml" config --format json \
        > "$workspace/base-compose.json"
    jq --arg image "$image" --arg project "$project" --arg run "$run_id" '
        del(.name, .services.kgcache.build) |
        .services.kgcache.image = $image |
        .services.kgcache.ports[0].published = "0" |
        .services.kgcache.labels["io.kgcache.container-test"] = $run |
        .networks.default.name = ($project + "_default") |
        .networks.default.labels["io.kgcache.container-test"] = $run |
        .volumes["kgcache-data"].name = ($project + "_kgcache-data") |
        .volumes["kgcache-data"].labels["io.kgcache.container-test"] = $run
    ' "$workspace/base-compose.json" > "$output"
}

compose_register() {
    register network "$1"_default
    register volume "$1"_kgcache-data
    register container "$1"-kgcache-1
}

compose_up() {
    local file=$1 project=$2 image=$3

    compose_call "$file" "$project" config --quiet
    compose_call "$file" "$project" up --wait --wait-timeout 120 --no-build --pull never
    docker_call inspect "$project-kgcache-1" > "$workspace/compose-inspect.json"
    jq -e --arg image "$image" '
        .[0] | .Image == $image and .State.Health.Status == "healthy" and
        .Config.User == "10001:10001" and
        .HostConfig.ReadonlyRootfs and .HostConfig.CapDrop == ["ALL"] and
        (.HostConfig.SecurityOpt | index("no-new-privileges:true") != null) and
        .HostConfig.Memory == 536870912 and .HostConfig.NanoCpus == 1000000000 and
        .Config.StopTimeout == 30 and
        (.HostConfig.PortBindings | to_entries | length == 1) and
        (.HostConfig.PortBindings[][] | .HostIp == "127.0.0.1")
    ' "$workspace/compose-inspect.json" > /dev/null
}

compose_port() {
    local endpoint

    endpoint=$(compose_call "$1" "$2" port kgcache "${3:-6379}")
    [[ "$endpoint" == 127.0.0.1:* ]] || release_fail 'expected one loopback endpoint'
    printf '%s\n' "${endpoint##*:}"
}

compose_stop() {
    compose_call "$1" "$2" stop
    docker_call inspect "$2-kgcache-1" > "$workspace/compose-inspect.json"
    jq -e '.[0].State | .ExitCode == 0 and (.OOMKilled | not)' \
        "$workspace/compose-inspect.json" > /dev/null
}

compose_clients() {
    local port=$1
    local KGCACHE_SMOKE_HOST=127.0.0.1 KGCACHE_SMOKE_PORT=$port

    export KGCACHE_SMOKE_HOST KGCACHE_SMOKE_PORT
    if ! timeout --signal=TERM --kill-after=5s 180s \
        make -C "$RELEASE_ROOT" smoke-go CLIENT_PROFILE=go-redis-v9.22.0 \
        > "$workspace/evidence/go-smoke.log" 2>&1; then
        tail -c 8192 "$workspace/evidence/go-smoke.log" >&2
        return 1
    fi
    if ! timeout --signal=TERM --kill-after=5s 180s \
        make -C "$RELEASE_ROOT" smoke-node CLIENT_PROFILE=node-redis-6.2.1 \
        > "$workspace/evidence/node-smoke.log" 2>&1; then
        tail -c 8192 "$workspace/evidence/node-smoke.log" >&2
        return 1
    fi
}

compose_guide() {
    local image=$1 file="$RELEASE_ROOT/docker-compose.yml" project=$guide_project port
    local name="$guide_project-kgcache-1" result

    compose_register "$project"
    compose_call "$file" "$project" config --quiet
    compose_call "$file" "$project" up --wait --wait-timeout 120
    docker_call inspect "$name" > "$workspace/compose-inspect.json"
    jq -e --arg image "$image" '.[0].Image == $image' \
        "$workspace/compose-inspect.json" > /dev/null
    port=$(compose_port "$file" "$project")
    [[ "$port" == 6379 ]] || release_fail 'guide must use port 6379'
    compose_call "$file" "$project" ps > "$workspace/evidence/guide-ps.log"
    result=$(timeout 5s redis-cli -h 127.0.0.1 -p 6379 --raw PING)
    [[ "$result" == PONG ]] || release_fail 'guide PING failed'
    result=$(timeout 5s redis-cli -h 127.0.0.1 -p 6379 --raw SET compose-example:value hello)
    [[ "$result" == OK ]] || release_fail 'guide SET failed'
    result=$(timeout 5s redis-cli -h 127.0.0.1 -p 6379 --raw GET compose-example:value)
    [[ "$result" == hello ]] || release_fail 'guide GET failed'
    result=$(timeout 5s redis-cli -h 127.0.0.1 -p 6379 --raw DEL compose-example:value)
    [[ "$result" == 1 ]] || release_fail 'guide DEL failed'
    compose_call "$file" "$project" logs --tail 100 kgcache \
        > "$workspace/evidence/guide-logs.log" 2>&1
    compose_stop "$file" "$project"
    compose_call "$file" "$project" start
    compose_call "$file" "$project" up --wait --wait-timeout 120
    compose_call "$file" "$project" up --force-recreate --wait --wait-timeout 120
    compose_stop "$file" "$project"
    collect_evidence
    compose_call "$file" "$project" down
    docker_call volume inspect "$project"_kgcache-data > /dev/null
}

compose_isolation() {
    local image=$1 original_port=$2 project="$run_id-parallel"
    local file="$workspace/parallel.json" port conflict="$run_id-conflict"

    compose_register "$project"
    compose_model "$image" "$project" "$file"
    compose_up "$file" "$project" "$image"
    port=$(compose_port "$file" "$project")
    [[ "$port" != "$original_port" ]] || release_fail 'parallel projects shared a host port'
    # shellcheck disable=SC2016
    command_reply "$port" '$-1\r\n' GET compose-state
    command_reply "$port" '+OK\r\n' SET compose-state separate

    file="$workspace/conflict.json"
    compose_register "$conflict"
    compose_model "$image" "$conflict" "$file"
    jq --arg port "$original_port" '.services.kgcache.ports[0].published = $port' \
        "$file" > "$file.next"
    mv "$file.next" "$file"
    if compose_call "$file" "$conflict" up --wait --wait-timeout 15 --no-build --pull never \
        > "$workspace/evidence/compose-conflict.log" 2>&1; then
        release_fail 'a conflicting published port unexpectedly started'
    fi
    # Both running projects must survive the third project's failure.
    # shellcheck disable=SC2016
    command_reply "$original_port" '$8\r\nretained\r\n' GET compose-state
    # shellcheck disable=SC2016
    command_reply "$port" '$8\r\nseparate\r\n' GET compose-state
}

compose_cases() {
    local image=$1 project="$run_id-compose" file="$workspace/compose.json"
    local name="$run_id-compose-kgcache-1" port before after mode config mount

    compose_register "$project"
    compose_model "$image" "$project" "$file"
    cp "$file" "$workspace/evidence/compose.json"
    compose_up "$file" "$project" "$image"
    port=$(compose_port "$file" "$project")
    command_reply "$port" '+OK\r\n' SET compose-state retained
    compose_clients "$port"
    raw_peer "$image" "${project}_default" "$project-peer" kgcache \
        "$workspace/ping.request" "$workspace/ping.expected"
    compose_isolation "$image" "$port"
    compose_call "$file" "$project" ps > "$workspace/evidence/compose-ps.log"
    compose_call "$file" "$project" exec -T kgcache \
        /usr/local/bin/kgcache healthcheck /etc/kgcache/kgcache.conf
    compose_call "$file" "$project" logs --tail 100 kgcache \
        > "$workspace/evidence/compose-logs.log" 2>&1
    compose_stop "$file" "$project"
    compose_call "$file" "$project" start
    compose_up "$file" "$project" "$image"
    port=$(compose_port "$file" "$project")
    # shellcheck disable=SC2016
    command_reply "$port" '$8\r\nretained\r\n' GET compose-state
    before=$(docker_call inspect --format '{{.Id}}' "$name")
    docker_call inspect "$name" > "$workspace/evidence/compose-before-replacement.json"
    compose_call "$file" "$project" up --force-recreate --wait --wait-timeout 120 --no-build --pull never
    compose_up "$file" "$project" "$image"
    after=$(docker_call inspect --format '{{.Id}}' "$name")
    [[ "$before" != "$after" ]] || release_fail 'Compose did not replace its container'
    port=$(compose_port "$file" "$project")
    # shellcheck disable=SC2016
    command_reply "$port" '$8\r\nretained\r\n' GET compose-state
    compose_stop "$file" "$project"
    collect_evidence
    compose_call "$file" "$project" down
    docker_call volume inspect "$project"_kgcache-data > /dev/null

    for mode in mounted cli snapshot disposable invalid missing; do
        project="$run_id-compose-$mode"
        file="$workspace/compose-$mode.json"
        name="$project-kgcache-1"
        config="$workspace/compose-$mode.conf"
        compose_register "$project"
        compose_model "$image" "$project" "$file"
        cp "$RELEASE_ROOT/containers/kgcache.conf" "$config"
        case "$mode" in
            mounted) printf 'port 7000\n' >> "$config" ;;
            snapshot) printf 'appendonly no\nshutdown-save yes\n' >> "$config" ;;
            disposable) printf 'appendonly no\nsave ""\nshutdown-save no\n' >> "$config" ;;
            invalid) printf 'port invalid\n' >> "$config" ;;
            missing) config="$workspace/absent.conf" ;;
        esac
        if [[ "$mode" != missing ]]; then
            chmod 0444 "$config"
        fi
        jq --arg config "$config" '.services.kgcache.volumes += [{
            type: "bind", source: $config, target: "/etc/kgcache/kgcache.conf",
            read_only: true, bind: {create_host_path: false}}]' "$file" > "$file.next"
        mv "$file.next" "$file"
        if [[ "$mode" == mounted || "$mode" == cli ]]; then
            jq '.services.kgcache.ports[0].target = 7000' "$file" > "$file.next"
            mv "$file.next" "$file"
        fi
        if [[ "$mode" == cli ]]; then
            jq '.services.kgcache.command = ["/etc/kgcache/kgcache.conf", "--port", "7000"] |
                .services.kgcache.healthcheck.test = ["CMD", "/usr/local/bin/kgcache",
                    "healthcheck", "/etc/kgcache/kgcache.conf", "--port", "7000"]' \
                "$file" > "$file.next"
            mv "$file.next" "$file"
        fi
        cp "$file" "$workspace/evidence/compose-$mode.json"
        if [[ "$mode" == invalid || "$mode" == missing ]]; then
            # Failure is expected; a failed assertion must still exit main.
            if compose_call "$file" "$project" up --wait --wait-timeout 15 --no-build --pull never \
                > "$workspace/evidence/compose-$mode.log" 2>&1; then
                release_fail "$mode config unexpectedly started"
            fi
            if [[ "$mode" == missing ]]; then
                [[ ! -e "$config" ]] || release_fail 'Compose created a missing config path'
            else
                docker_call inspect "$name" > "$workspace/compose-inspect.json"
                jq -e '.[0].State | .Running == false and .ExitCode != 0' \
                    "$workspace/compose-inspect.json" > /dev/null
            fi
            continue
        fi
        compose_up "$file" "$project" "$image"
        if [[ "$mode" == mounted || "$mode" == cli ]]; then
            port=$(compose_port "$file" "$project" 7000)
            docker_call inspect "$name" > "$workspace/compose-inspect.json"
            mount=$(jq -er \
                '.[0].Mounts[] | select(.Destination == "/etc/kgcache/kgcache.conf") | .RW | tostring' \
                "$workspace/compose-inspect.json")
            [[ "$mount" == false ]] || release_fail 'config mount must be read-only'
        else
            port=$(compose_port "$file" "$project")
        fi
        command_reply "$port" '+OK\r\n' SET mode-state saved
        compose_stop "$file" "$project"
        if [[ "$mode" == snapshot || "$mode" == disposable ]]; then
            # Inspect stopped storage through a separate test-only container.
            before="$project-storage"
            register container "$before"
            docker_call create --name "$before" --platform linux/amd64 --read-only \
                --label "io.kgcache.container-test=$run_id" \
                --mount "type=volume,src=${project}_kgcache-data,dst=/data,readonly" \
                --entrypoint sh "$image" -ec \
                'find /data -mindepth 1 -maxdepth 2 -type f' > /dev/null
            after=$(docker_call start --attach "$before")
            if [[ "$mode" == disposable ]]; then
                [[ -z "$after" ]] || release_fail 'disposable mode wrote persistence files'
            else
                [[ "$after" == /data/dump.kgc ]] || release_fail 'snapshot mode did not save'
            fi
            compose_up "$file" "$project" "$image"
            port=$(compose_port "$file" "$project")
            if [[ "$mode" == disposable ]]; then
                # shellcheck disable=SC2016
                command_reply "$port" '$-1\r\n' GET mode-state
            else
                # shellcheck disable=SC2016
                command_reply "$port" '$5\r\nsaved\r\n' GET mode-state
            fi
            compose_stop "$file" "$project"
        fi
    done
}

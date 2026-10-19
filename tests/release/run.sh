#!/usr/bin/env bash
# Qualify one release artifact in the selected Bookworm filesystem.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"
source "${BASH_SOURCE[0]%/*}/docker.sh"

usage() {
    printf 'Usage: bash tests/release/run.sh [--prefix DIR] [--artifacts DIR] [--allow-emulation]\n'
}

docker_platform() {
    local engine_arch
    engine_arch=$(timeout --signal=TERM --kill-after=5s 15s docker info --format '{{.Architecture}}') ||
        release_fail 'cannot identify the Docker engine architecture'
    case "$engine_arch" in
        x86_64 | amd64) printf 'linux/amd64\n' ;;
        aarch64 | arm64) printf 'linux/arm64\n' ;;
        *) release_fail "unknown Docker engine architecture: $engine_arch" ;;
    esac
}

native_execution() {
    local platform=$1 engine_platform=$2 allow_emulation=$3
    if [[ "$engine_platform" == "$platform" ]]; then
        printf 'true\n'
    elif [[ "$allow_emulation" == true ]]; then
        printf 'false\n'
    else
        release_fail "native $platform is required; engine is $engine_platform (use --allow-emulation for a development smoke check)"
    fi
}

# Assign only the resource ownership fields used by the EXIT trap in docker.sh.
prepare_workspace() {
    local artifacts=$1 identifier
    mkdir -p "$artifacts" "$RELEASE_ROOT/.zig-cache"
    artifacts=$(cd "$artifacts" && pwd -P)
    probe_evidence_dir=$(mktemp -d "$artifacts/run.XXXXXX")
    probe_workspace=$(mktemp -d "$RELEASE_ROOT/.zig-cache/release-check.XXXXXX")
    identifier=$(printf '%s' "${probe_workspace##*/}" | tr '[:upper:].' '[:lower:]-')
    probe_id="kgcache-release-$identifier"
    printf 'Release check evidence: %s\n' "$probe_evidence_dir"
}

prepare_context() {
    local prefix=$1 context="$probe_workspace/context"
    mkdir -p "$context/artifact/bin" "$context/tools"
    cp "$prefix/bin/kgcache" "$context/artifact/bin/kgcache"
    cp "$prefix/build-info.json" "$context/artifact/build-info.json"
    cp -R tools/release "$context/tools/release"
    cp -R "$probe_workspace/helpers/libexec/kgcache-tests" "$context/test-tools"
    cp tests/release/Dockerfile tests/release/runtime.sh "$context/"
    bash tools/release/verify.sh --prefix "$context/artifact"
    cp "$context/artifact/build-info.json" "$probe_evidence_dir/build-info.json"
}

build_probe_images() {
    local platform=$1 stage log
    for stage in runtime inspection tests; do
        printf 'Building %s probe image...\n' "$stage"
        log="$probe_evidence_dir/build-$stage.log"
        if ! timeout --signal=TERM --kill-after=10s 600s docker build \
            --platform "$platform" --build-arg "RUNTIME_BASE=$RUNTIME_BASE" \
            --target "$stage" --tag "$probe_id:$stage" "$probe_workspace/context" > "$log" 2>&1; then
            cat "$log" >&2
            release_fail "cannot build the $stage probe; log: $log"
        fi
    done
}

check_runtime_libraries() {
    local platform=$1 output expected_sha
    probe_run runtime "$platform" "$probe_id:runtime" 30s "$probe_evidence_dir/runtime-libraries.log"
    output=$(cat "$probe_evidence_dir/runtime-libraries.log.stdout")
    [[ "$output" != *'not found'* ]] || release_fail 'unresolved runtime dependency'
    expected_sha=$(release_read_field "$probe_evidence_dir/build-info.json" .binary.sha256)
    [[ "$output" == *"$expected_sha  /usr/local/bin/kgcache"* ]] || release_fail 'runtime executable checksum mismatch'
}

inspect_binary() {
    local platform=$1
    probe_run inspection "$platform" "$probe_id:inspection" 30s "$probe_evidence_dir/inspection.log"
    cp "$probe_evidence_dir/inspection.log.stdout" "$probe_evidence_dir/abi.json"
    jq --exit-status . "$probe_evidence_dir/abi.json" > /dev/null
}

write_result() {
    local platform=$1 native=$2 engine_platform=$3 qualified=false
    if [[ "$native" == true && "$platform" == linux/amd64 ]]; then qualified=true; fi
    jq --null-input \
        --slurpfile build "$probe_evidence_dir/build-info.json" \
        --arg engine "$engine_platform" \
        --argjson native "$native" --argjson qualified "$qualified" \
        '{schema_version: 1, build: $build[0], engine_platform: $engine, native_execution: $native,
          initial_amd64_qualified: $qualified, runtime_libraries: "passed",
          elf_inspection: "passed", process_tests: "passed"}' > "$probe_evidence_dir/result.json"
    printf 'Bookworm checks passed: platform=%s native=%s initial_amd64_qualified=%s\n' "$platform" "$native" "$qualified"
}

main() {
    local prefix="$RELEASE_ROOT/zig-out/release/linux-amd64" artifacts='' allow_emulation=false
    local platform revision native compiler engine_platform
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                release_require_value "$1" "${2:-}"
                prefix=$2
                shift 2
                ;;
            --artifacts)
                release_require_value "$1" "${2:-}"
                artifacts=$2
                shift 2
                ;;
            --allow-emulation)
                allow_emulation=true
                shift
                ;;
            --help)
                usage
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done
    release_require_commands git jq file docker timeout mktemp tr
    release_require_sha256
    cd "$RELEASE_ROOT"
    prefix=$(cd "$prefix" && pwd -P)
    bash tools/release/verify.sh --prefix "$prefix"
    platform=$(release_read_field "$prefix/build-info.json" .platform)
    revision=$(release_read_field "$prefix/build-info.json" .source.revision)
    release_assert_source "$revision"
    engine_platform=$(docker_platform)
    native=$(native_execution "$platform" "$engine_platform" "$allow_emulation")
    compiler=$(bash tools/release/zig.sh --print-path)

    trap probe_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    prepare_workspace "${artifacts:-$RELEASE_ROOT/test-artifacts/release/${platform//\//-}}"
    printf 'Building process test tools...\n'
    release_compile "$compiler" "$probe_workspace/helpers" "$platform" integration-tools
    release_assert_source "$revision"
    prepare_context "$prefix"
    build_probe_images "$platform"
    printf 'Checking runtime libraries...\n'
    check_runtime_libraries "$platform"
    printf 'Inspecting the release ELF...\n'
    inspect_binary "$platform"
    printf 'Running process tests...\n'
    probe_run tests "$platform" "$probe_id:tests" 240s "$probe_evidence_dir/process.log"
    release_assert_source "$revision"
    write_result "$platform" "$native" "$engine_platform"
}

main "$@"

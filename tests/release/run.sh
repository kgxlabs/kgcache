#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../../tools/release/common.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/docker.sh"

prefix="$release_root/zig-out/release/linux-amd64"
artifacts=
allow_emulation=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) [[ $# -ge 2 && -n "$2" ]] || release_fail 'missing prefix'; prefix=$2; shift 2 ;;
        --artifacts) [[ $# -ge 2 && -n "$2" ]] || release_fail 'missing artifacts directory'; artifacts=$2; shift 2 ;;
        --allow-emulation) allow_emulation=true; shift ;;
        --help) printf 'Usage: bash tests/release/run.sh [--prefix DIR] [--artifacts DIR] [--allow-emulation]\n'; exit 0 ;;
        *) release_fail "unknown argument: $1" ;;
    esac
done
cd "$release_root"
prefix=$(cd "$prefix" && pwd -P)
bash tools/release/verify.sh --prefix "$prefix"
metadata="$prefix/build-info.json"
platform=$(jq -r .platform "$metadata")
release_platform "$platform"
source_revision=$(jq -er .source.revision "$metadata")
release_assert_source "$source_revision"

# A different engine architecture means emulation, even if the client is native.
engine_arch=$(docker info --format '{{.Architecture}}')
case "$engine_arch" in
    x86_64|amd64) engine_platform=linux/amd64 ;;
    aarch64|arm64) engine_platform=linux/arm64 ;;
    *) release_fail "unknown Docker engine architecture: $engine_arch" ;;
esac
native=false
if [[ "$engine_platform" == "$platform" ]]; then native=true; fi
[[ "$native" == true || "$allow_emulation" == true ]] ||
    release_fail "native $platform is required; engine is $engine_platform (use --allow-emulation for a development smoke check)"
command -v timeout >/dev/null || release_fail 'GNU timeout is required'

artifacts=${artifacts:-"$release_root/test-artifacts/release/${platform//\//-}"}
mkdir -p "$artifacts" "$release_root/.zig-cache"
artifacts=$(cd "$artifacts" && pwd -P)
artifacts=$(mktemp -d "$artifacts/run.XXXXXX")
printf 'Release check evidence: %s\n' "$artifacts"
check_root=$(mktemp -d "$release_root/.zig-cache/release-check.XXXXXX")
check_id="kgcache-release-$(basename "$check_root" | tr '[:upper:].' '[:lower:]-')"
probe_id=$check_id
probe_workspace=$check_root
probe_evidence_dir=$artifacts
trap probe_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compiler=$(bash tools/release/zig.sh --print-path)
"$compiler" build integration-tools "-Dtarget=$release_target" -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$check_root/helpers"
release_assert_source "$source_revision"
mkdir -p "$check_root/context/artifact/bin" "$check_root/context/tools"
cp "$prefix/bin/kgcache" "$check_root/context/artifact/bin/kgcache"
cp "$metadata" "$check_root/context/artifact/build-info.json"
cp -R tools/release "$check_root/context/tools/release"
cp -R "$check_root/helpers/libexec/kgcache-tests" "$check_root/context/test-tools"
cp tests/release/Dockerfile "$check_root/context/Dockerfile"
bash tools/release/verify.sh --prefix "$check_root/context/artifact"
cp "$metadata" "$artifacts/build-info.json"

for stage in runtime inspection tests; do
    timeout --signal=TERM --kill-after=10s 600s docker build --platform "$platform" \
        --build-arg "RUNTIME_BASE=$release_runtime" --target "$stage" \
        --tag "$check_id:$stage" "$check_root/context" >"$artifacts/build-$stage.log" 2>&1 || {
            cat "$artifacts/build-$stage.log" >&2
            release_fail "could not build the $stage probe"
        }
done

# Resolve dependencies before diagnostic packages or test tools are added.
probe_run runtime "$platform" "$check_id:runtime" 30s "$artifacts/runtime-libraries.log" sh -ec '
    test ! -e /tests
    test ! -e /probe
    if command -v zig; then exit 1; fi
    ldd /usr/local/bin/kgcache
    sha256sum /usr/local/bin/kgcache
'
case $(cat "$artifacts/runtime-libraries.log") in
    *'not found'*) release_fail 'unresolved runtime dependency' ;;
esac
[[ $(cat "$artifacts/runtime-libraries.log") == *"$(jq -r .binary.sha256 "$metadata")  /usr/local/bin/kgcache"* ]] ||
    release_fail 'runtime executable checksum mismatch'
probe_run inspection "$platform" "$check_id:inspection" 30s "$artifacts/inspection.log"
cp "$artifacts/inspection.log.stdout" "$artifacts/abi.json"
probe_run tests "$platform" "$check_id:tests" 240s "$artifacts/process.log"
release_assert_source "$source_revision"
qualified=false
if [[ "$native" == true && "$platform" == linux/amd64 ]]; then qualified=true; fi
jq -n --slurpfile build "$metadata" --arg engine "$engine_platform" --argjson native "$native" --argjson qualified "$qualified" \
    '{schema_version: 1, build: $build[0], engine_platform: $engine, native_execution: $native,
      initial_amd64_qualified: $qualified, runtime_libraries: "passed", elf_inspection: "passed", process_tests: "passed"}' \
    >"$artifacts/result.json"
printf 'Bookworm checks passed: platform=%s native=%s initial_amd64_qualified=%s\nEvidence: %s\n' "$platform" "$native" "$qualified" "$artifacts"

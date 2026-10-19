#!/usr/bin/env bash
# Check specific artifact rejection reasons and preserve good output on failure.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

artifact_workspace=
artifact_logs=

new_case() {
    local prefix=$1 name=$2 output="$artifact_workspace/$2"
    mkdir -p "$output/bin"
    cp "$prefix/bin/kgcache" "$output/bin/kgcache"
    cp "$prefix/build-info.json" "$output/build-info.json"
    printf '%s\n' "$output"
}

expect_rejection() {
    local name=$1 message=$2 prefix=$3 status output
    if bash "$RELEASE_ROOT/tools/release/verify.sh" --prefix "$prefix" >"$artifact_logs/$name.log" 2>&1; then
        release_fail "$name was accepted; log: $artifact_logs/$name.log"
    else
        status=$?
    fi
    output=$(cat "$artifact_logs/$name.log")
    if [[ "$status" != 1 || "$output" != *"$message"* ]]; then
        cat "$artifact_logs/$name.log" >&2
        release_fail "$name failed for an unexpected reason (status $status)"
    fi
    printf 'Passed: %s\n' "$name"
}

check_rejections() {
    local prefix=$1 candidate
    candidate=$(new_case "$prefix" changed-binary)
    printf 'changed' >>"$candidate/bin/kgcache"
    expect_rejection changed-binary 'binary checksum mismatch' "$candidate"

    candidate=$(new_case "$prefix" wrong-target)
    jq '.target = "wrong-target"' "$prefix/build-info.json" >"$candidate/build-info.json"
    expect_rejection wrong-target 'platform and target do not agree' "$candidate"

    candidate=$(new_case "$prefix" wrong-architecture)
    jq '.platform = "linux/arm64" | .target = "aarch64-linux-gnu.2.36"' "$prefix/build-info.json" >"$candidate/build-info.json"
    expect_rejection wrong-architecture 'wrong executable format or architecture' "$candidate"

    candidate=$(new_case "$prefix" dirty-source)
    jq '.source.dirty = true' "$prefix/build-info.json" >"$candidate/build-info.json"
    expect_rejection dirty-source 'development artifact has dirty source' "$candidate"

    candidate=$(new_case "$prefix" test-controls)
    jq '.persistence_test_controls = true' "$prefix/build-info.json" >"$candidate/build-info.json"
    expect_rejection test-controls 'persistence_test_controls must be false' "$candidate"

    candidate=$(new_case "$prefix" missing-source-record)
    jq 'del(.source)' "$prefix/build-info.json" >"$candidate/build-info.json"
    expect_rejection missing-source-record 'source must be an object' "$candidate"

    candidate=$(new_case "$prefix" invalid-recorded-checksum)
    jq '.binary.sha256 = "invalid"' "$prefix/build-info.json" >"$candidate/build-info.json"
    expect_rejection invalid-recorded-checksum 'binary.sha256 must be a SHA-256 checksum' "$candidate"

    candidate=$(new_case "$prefix" invalid-executable)
    printf 'not an ELF executable\n' >"$candidate/bin/kgcache"
    expect_rejection invalid-executable 'wrong executable format or architecture' "$candidate"

    candidate=$(new_case "$prefix" missing-executable)
    rm "$candidate/bin/kgcache"
    expect_rejection missing-executable 'missing executable' "$candidate"
}

check_failed_rebuild() {
    local prefix=$1 candidate real_jq status output
    candidate=$(new_case "$prefix" failed-rebuild)
    real_jq=$(command -v jq)
    mkdir "$artifact_workspace/failing-tools"
    cat >"$artifact_workspace/failing-tools/jq" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == --null-input ]]; then
    printf 'simulated metadata writer failure\n' >&2
    exit 73
fi
exec "$REAL_JQ" "$@"
SH
    chmod +x "$artifact_workspace/failing-tools/jq"
    if env PATH="$artifact_workspace/failing-tools:$PATH" REAL_JQ="$real_jq" \
        bash tools/release/build.sh --prefix "$candidate" >"$artifact_logs/failed-rebuild.log" 2>&1; then
        release_fail 'rebuild unexpectedly succeeded with a broken metadata writer'
    else
        status=$?
    fi
    output=$(cat "$artifact_logs/failed-rebuild.log")
    if [[ "$status" != 1 || "$output" != *'cannot write release build record'* ]]; then
        cat "$artifact_logs/failed-rebuild.log" >&2
        release_fail 'rebuild failed for an unexpected reason'
    fi
    cmp "$prefix/bin/kgcache" "$candidate/bin/kgcache"
    cmp "$prefix/build-info.json" "$candidate/build-info.json"
    bash tools/release/verify.sh --prefix "$candidate"
    printf 'Passed: failed rebuild preserves previous artifact\n'
}

cleanup_artifact_checks() {
    local status=$?
    trap - EXIT
    if [[ -n "$artifact_workspace" ]]; then rm -rf -- "$artifact_workspace"; fi
    exit "$status"
}

main() {
    [[ $# == 1 ]] || release_fail 'usage: bash tests/release/artifact.sh RELEASE_PREFIX'
    local prefix
    release_require_commands git jq file cmp mktemp
    release_require_sha256
    cd "$RELEASE_ROOT"
    prefix=$(cd "$1" && pwd -P)
    bash tools/release/verify.sh --prefix "$prefix"
    mkdir -p .zig-cache test-artifacts/release/artifact
    trap cleanup_artifact_checks EXIT
    artifact_workspace=$(mktemp -d "$RELEASE_ROOT/.zig-cache/artifact-check.XXXXXX")
    artifact_logs=$(mktemp -d "$RELEASE_ROOT/test-artifacts/release/artifact/run.XXXXXX")
    check_rejections "$prefix"
    check_failed_rebuild "$prefix"
    printf 'Artifact checks passed. Evidence: %s\n' "$artifact_logs"
}

main "$@"

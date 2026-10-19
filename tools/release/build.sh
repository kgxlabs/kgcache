#!/usr/bin/env bash
# Build and verify a complete artifact before replacing the previous release.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"

# Only resource ownership crosses main's scope. The EXIT trap needs these paths
# after main returns, and restores the previous directory if publication fails.
build_workspace=
build_output=
build_lock=

cleanup_build() {
    local status=$?
    trap - EXIT
    if [[ -n "$build_workspace" ]]; then
        if [[ -d "$build_workspace/previous" && ! -e "$build_output" ]]; then
            if ! mv "$build_workspace/previous" "$build_output"; then
                printf 'release: cannot restore the previous artifact; preserved at %s/previous\n' "$build_workspace" >&2
                exit 1
            fi
        fi
        if ! rm -rf -- "$build_workspace"; then
            printf 'release: cannot remove build workspace %s\n' "$build_workspace" >&2
            if [[ "$status" == 0 ]]; then status=1; fi
        fi
    fi
    if [[ -n "$build_lock" ]]; then
        if ! rmdir "$build_lock"; then
            printf 'release: cannot remove build lock %s\n' "$build_lock" >&2
            if [[ "$status" == 0 ]]; then status=1; fi
        fi
    fi
    exit "$status"
}

resolve_output() {
    local requested=${1%/} parent name
    name=${requested##*/}
    [[ -n "$name" && "$name" != . && "$name" != .. ]] || release_fail 'invalid release prefix'
    parent=${requested%/*}
    if [[ "$parent" == "$requested" ]]; then parent=.; fi
    mkdir -p "$parent"
    parent=$(cd "$parent" && pwd -P) || release_fail 'cannot resolve output directory'
    build_output="$parent/$name"
    case "$build_output" in
        "$RELEASE_ROOT"|"$RELEASE_ROOT/zig-out"|"$RELEASE_ROOT/zig-out/bin")
            release_fail 'release output must be separate from the normal install prefix'
            ;;
    esac
    [[ ! -L "$build_output" ]] || release_fail 'release prefix must not be a symbolic link'
    [[ ! -e "$build_output" || -d "$build_output" ]] || release_fail 'release prefix must be a directory'
    if ! mkdir "$build_output.lock"; then
        release_fail "release output is locked: $build_output.lock (check for another build before removing a stale lock)"
    fi
    build_lock="$build_output.lock"
    build_workspace=$(mktemp -d "$parent/.$name.build.XXXXXX")
}

write_record() {
    local output=$1 platform=$2 revision=$3 dirty=$4 archive_sha=$5
    local version target binary_sha
    version=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' "$RELEASE_ROOT/build.zig.zon")
    [[ -n "$version" && "$version" != *$'\n'* ]] || release_fail 'cannot read a single package version'
    target=$(release_target "$platform")
    binary_sha=$(release_sha256 "$output/bin/kgcache")
    if ! jq --null-input \
        --arg version "$version" \
        --arg revision "$revision" \
        --argjson dirty "$dirty" \
        --arg platform "$platform" \
        --arg target "$target" \
        --arg cpu "$RELEASE_CPU" \
        --arg optimize "$RELEASE_OPTIMIZE" \
        --arg compiler "$ZIG_VERSION" \
        --arg archive_sha "$archive_sha" \
        --arg runtime "$RUNTIME_BASE" \
        --arg sha "$binary_sha" \
        --from-file "$RELEASE_ROOT/tools/release/create-build-info.jq" \
        >"$output/build-info.json"; then
        release_fail 'cannot write release build record'
    fi
}

publish_artifact() {
    if [[ -d "$build_output" ]]; then
        mv "$build_output" "$build_workspace/previous"
    fi
    mv "$build_workspace/artifact" "$build_output"
}

main() {
    local platform=linux/amd64 prefix='' allow_dirty=false
    local revision source_status current_revision current_status dirty=false compiler archive_sha
    local verify_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --platform)
                release_require_value "$1" "${2:-}"
                platform=$2
                shift 2
                ;;
            --prefix)
                release_require_value "$1" "${2:-}"
                prefix=$2
                shift 2
                ;;
            --allow-dirty)
                allow_dirty=true
                shift
                ;;
            --help)
                printf 'Usage: bash tools/release/build.sh [--platform linux/amd64|linux/arm64] [--prefix DIR] [--allow-dirty]\n'
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done
    release_require_commands git jq file sed mktemp timeout
    release_require_sha256
    release_target "$platform" >/dev/null
    cd "$RELEASE_ROOT"
    revision=$(release_git_revision)
    source_status=$(release_git_status)
    if [[ -n "$source_status" ]]; then
        dirty=true
        [[ "$allow_dirty" == true ]] || release_fail 'source tree is dirty; commit changes or use --allow-dirty for a development artifact'
    fi
    compiler=$(bash tools/release/zig.sh --print-path)
    archive_sha=$(cat "${compiler%/*}/.verified-sha256")
    trap cleanup_build EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    resolve_output "${prefix:-$RELEASE_ROOT/zig-out/release/${platform//\//-}}"
    release_compile "$compiler" "$build_workspace/artifact" "$platform"
    current_revision=$(release_git_revision)
    current_status=$(release_git_status)
    if [[ "$current_revision" != "$revision" || "$current_status" != "$source_status" ]]; then
        release_fail 'source tree changed during the release build'
    fi
    release_check_binary "$build_workspace/artifact/bin/kgcache" "$platform"
    write_record "$build_workspace/artifact" "$platform" "$revision" "$dirty" "$archive_sha"
    verify_args=(--prefix "$build_workspace/artifact")
    if [[ "$allow_dirty" == true ]]; then verify_args+=(--allow-dirty); fi
    bash tools/release/verify.sh "${verify_args[@]}"
    publish_artifact
    printf 'Release artifact: %s\n' "$build_output"
}

main "$@"

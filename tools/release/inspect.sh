#!/usr/bin/env bash
# Inspect ELF requirements using a validated release artifact and GNU readelf.
set -euo pipefail

source "${BASH_SOURCE[0]%/*}/common.sh"

inspection_workspace=

check_header() {
    local reader=$1 binary=$2 platform=$3 header machine

    header=$("$reader" -h "$binary") || release_fail 'cannot read ELF header'
    machine=$(release_machine "$platform")

    if [[ "$header" != *ELF64* ||
        "$header" != *'little endian'* ||
        "$header" != *"$machine"* ]]; then
        release_fail 'unexpected ELF class, byte order, or machine'
    fi
}

read_interpreter() {
    local reader=$1 binary=$2 platform=$3 headers interpreter expected

    headers=$("$reader" -l "$binary") ||
        release_fail 'cannot read ELF program headers'
    interpreter=$(printf '%s\n' "$headers" |
        sed -nE 's/.*Requesting program interpreter: ([^]]+)\].*/\1/p') ||
        release_fail 'cannot parse ELF interpreter'
    expected=$(release_loader "$platform")

    [[ -n "$interpreter" && "$interpreter" == "$expected" ]] ||
        release_fail "unexpected dynamic loader: $interpreter"

    printf '%s\n' "$interpreter"
}

read_dependencies() {
    local reader=$1 binary=$2 output=$3 dynamic

    dynamic=$("$reader" -d "$binary") ||
        release_fail 'cannot read ELF dynamic section'
    if [[ "$dynamic" == *'(RPATH)'* || "$dynamic" == *'(RUNPATH)'* ]]; then
        release_fail 'release binary contains a runtime library search path'
    fi

    printf '%s\n' "$dynamic" |
        sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p' |
        sort -u > "$output"
    [[ -s "$output" ]] || release_fail 'missing dynamic dependency information'
}

read_glibc_versions() {
    local reader=$1 binary=$2 workspace=$3

    "$reader" --version-info "$binary" > "$workspace/version-info"
    awk -v "baseline=$GLIBC_VERSION" \
        -f "$RELEASE_ROOT/tools/release/glibc-versions.awk" \
        "$workspace/version-info" > "$workspace/versions-unsorted"
    sort -u "$workspace/versions-unsorted" > "$workspace/versions"
}

write_report() {
    local workspace=$1 interpreter=$2 needed versions

    needed=$(jq --raw-input --slurp 'split("\n") | map(select(length > 0))' \
        "$workspace/needed")
    versions=$(jq --raw-input --slurp 'split("\n") | map(select(length > 0))' \
        "$workspace/versions")

    jq --null-input \
        --arg interpreter "$interpreter" \
        --argjson needed "$needed" \
        --argjson versions "$versions" \
        '{class: "ELF64", byte_order: "little", interpreter: $interpreter, needed: $needed, glibc_versions: $versions}'
}

cleanup_inspection() {
    local status=$?

    trap - EXIT

    if [[ -n "$inspection_workspace" ]]; then
        rm -rf -- "$inspection_workspace"
    fi

    exit "$status"
}

main() {
    [[ $# == 1 ]] ||
        release_fail 'usage: bash tools/release/inspect.sh RELEASE_PREFIX'
    local prefix=$1 reader=${READELF:-readelf} platform interpreter

    release_require_commands "$reader" jq file awk sed sort mktemp
    release_require_sha256

    bash "$RELEASE_ROOT/tools/release/verify.sh" --prefix "$prefix"
    platform=$(release_read_field "$prefix/build-info.json" .platform)

    trap cleanup_inspection EXIT
    inspection_workspace=$(mktemp -d)

    check_header "$reader" "$prefix/bin/kgcache" "$platform"
    interpreter=$(read_interpreter "$reader" "$prefix/bin/kgcache" "$platform")
    read_dependencies "$reader" "$prefix/bin/kgcache" \
        "$inspection_workspace/needed"
    read_glibc_versions "$reader" "$prefix/bin/kgcache" "$inspection_workspace"

    write_report "$inspection_workspace" "$interpreter"
}

main "$@"

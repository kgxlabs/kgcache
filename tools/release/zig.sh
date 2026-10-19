#!/usr/bin/env bash
# Fetch a verified host compiler, or reuse the verified compiler cache.
set -euo pipefail

source "${BASH_SOURCE[0]%/*}/common.sh"

download_workspace=

cleanup_download() {
    local status=$?

    trap - EXIT

    if [[ -n "$download_workspace" ]]; then
        rm -rf -- "$download_workspace"
    fi

    exit "$status"
}

host_platform() {
    local system arch

    system=$(uname -s) || release_fail 'cannot identify the compiler host OS'
    arch=$(uname -m) ||
        release_fail 'cannot identify the compiler host architecture'

    case "$system/$arch" in
        Linux/x86_64) printf 'x86_64-linux\n' ;;
        Linux/aarch64 | Linux/arm64) printf 'aarch64-linux\n' ;;
        Darwin/arm64) printf 'aarch64-macos\n' ;;
        Darwin/x86_64) printf 'x86_64-macos\n' ;;
        *)
            release_fail 'the pinned compiler supports Linux and macOS on amd64 or arm64'
            ;;
    esac
}

compiler_checksum() {
    case "$1" in
        x86_64-linux)
            printf '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00\n'
            ;;
        aarch64-linux)
            printf 'ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17\n'
            ;;
        aarch64-macos)
            printf 'b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489\n'
            ;;
        x86_64-macos)
            printf '0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7\n'
            ;;
        *) release_fail "no pinned compiler checksum for $1" ;;
    esac
}

check_compiler_cache() {
    local directory=$1 expected_sha=$2 actual_sha version

    if [[ ! -x "$directory/zig" || ! -f "$directory/.verified-sha256" ]]; then
        release_fail "incomplete compiler cache; remove this directory and retry: $directory"
    fi

    actual_sha=$(cat "$directory/.verified-sha256")
    [[ "$actual_sha" == "$expected_sha" ]] ||
        release_fail "compiler cache checksum record differs; remove and retry: $directory"

    version=$("$directory/zig" version) ||
        release_fail 'cached compiler cannot execute'
    [[ "$version" == "$ZIG_VERSION" ]] ||
        release_fail 'cached compiler version mismatch'
}

download_compiler() {
    local cache=$1 directory=$2 platform=$3 expected_sha=$4
    local archive actual_sha version

    release_require_commands curl tar
    release_require_sha256

    download_workspace=$(mktemp -d "$cache/download.XXXXXX")
    archive="$download_workspace/archive.tar.xz"

    printf 'Downloading Zig %s for %s\n' "$ZIG_VERSION" "$platform" >&2
    curl --fail --silent --show-error --location --retry 2 \
        --connect-timeout 15 --max-time 300 \
        "https://ziglang.org/download/$ZIG_VERSION/zig-$platform-$ZIG_VERSION.tar.xz" \
        --output "$archive"

    actual_sha=$(release_sha256 "$archive")
    [[ "$actual_sha" == "$expected_sha" ]] ||
        release_fail 'compiler archive checksum mismatch'

    mkdir "$download_workspace/unpacked"
    tar -xJf "$archive" -C "$download_workspace/unpacked" --strip-components=1

    version=$("$download_workspace/unpacked/zig" version)
    [[ "$version" == "$ZIG_VERSION" ]] ||
        release_fail 'compiler version mismatch'
    printf '%s\n' "$expected_sha" \
        > "$download_workspace/unpacked/.verified-sha256"

    [[ ! -e "$directory" ]] ||
        release_fail "compiler cache appeared during download; retry: $directory"
    mv "$download_workspace/unpacked" "$directory"

    rm -rf -- "$download_workspace"
    download_workspace=
}

main() {
    local platform checksum cache directory

    if [[ ${1:-} == --print-path && $# != 1 ]]; then
        release_fail '--print-path accepts no additional arguments'
    fi

    release_require_commands uname mktemp

    platform=$(host_platform)
    checksum=$(compiler_checksum "$platform")
    cache="$RELEASE_ROOT/.zig-cache/toolchains"
    directory="$cache/zig-$platform-$ZIG_VERSION"

    trap cleanup_download EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    mkdir -p "$cache"
    if [[ ! -e "$directory" ]]; then
        download_compiler "$cache" "$directory" "$platform" "$checksum"
    fi
    check_compiler_cache "$directory" "$checksum"

    if [[ ${1:-} == --print-path ]]; then
        printf '%s\n' "$directory/zig"
    else
        exec "$directory/zig" "$@"
    fi
}

main "$@"

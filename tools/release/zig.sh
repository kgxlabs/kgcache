#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)
        toolchain_platform=x86_64-linux
        toolchain_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
    Linux/aarch64|Linux/arm64)
        toolchain_platform=aarch64-linux
        toolchain_sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
    Darwin/arm64)
        toolchain_platform=aarch64-macos
        toolchain_sha=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
    Darwin/x86_64)
        toolchain_platform=x86_64-macos
        toolchain_sha=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
    *) release_fail 'the pinned compiler supports Linux and macOS on amd64 or arm64' ;;
esac

toolchain_name="zig-$toolchain_platform-$release_zig_version"
toolchain_cache="$release_root/.zig-cache/toolchains"
toolchain_dir="$toolchain_cache/$toolchain_name"
mkdir -p "$toolchain_cache"
if [[ ! -x "$toolchain_dir/zig" || ! -f "$toolchain_dir/.verified-sha256" ]] ||
    [[ $(cat "$toolchain_dir/.verified-sha256" 2>/dev/null) != "$toolchain_sha" ]]; then
    toolchain_temp=$(mktemp -d "$toolchain_cache/download.XXXXXX")
    trap 'rm -rf -- "$toolchain_temp"' EXIT
    archive="$toolchain_temp/archive.tar.xz"
    curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 300 \
        "https://ziglang.org/download/$release_zig_version/$toolchain_name.tar.xz" -o "$archive" >&2
    [[ $(release_sha256 "$archive") == "$toolchain_sha" ]] || release_fail 'compiler archive checksum mismatch'
    mkdir "$toolchain_temp/unpacked"
    tar -xJf "$archive" -C "$toolchain_temp/unpacked" --strip-components=1
    [[ $("$toolchain_temp/unpacked/zig" version) == "$release_zig_version" ]] || release_fail 'compiler version mismatch'
    printf '%s\n' "$toolchain_sha" >"$toolchain_temp/unpacked/.verified-sha256"
    # Install the compiler only after its download has been verified.
    if [[ -e "$toolchain_dir" ]]; then
        release_fail "incomplete compiler cache; remove this directory and retry: $toolchain_dir"
    fi
    mv "$toolchain_temp/unpacked" "$toolchain_dir"
fi
[[ $("$toolchain_dir/zig" version) == "$release_zig_version" ]] || release_fail 'cached compiler version mismatch'
if [[ ${1:-} == --print-path ]]; then
    printf '%s\n' "$toolchain_dir/zig"
else
    exec "$toolchain_dir/zig" "$@"
fi

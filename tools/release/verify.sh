#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

prefix="$release_root/zig-out/release/linux-amd64"
allow_dirty=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) [[ $# -ge 2 && -n "$2" ]] || release_fail 'missing prefix'; prefix=$2; shift 2 ;;
        --allow-dirty) allow_dirty=true; shift ;;
        --help) printf 'Usage: bash tools/release/verify.sh [--prefix DIR] [--allow-dirty]\n'; exit 0 ;;
        *) release_fail "unknown argument: $1" ;;
    esac
done
metadata="$prefix/build-info.json"
[[ -f "$metadata" ]] || release_fail "missing build record: $metadata"
jq -e --arg compiler "$release_zig_version" --arg runtime "$release_runtime" '
    .schema_version == 1 and (.version | type == "string") and
    (.source.revision | test("^[0-9a-f]{40}$")) and (.source.dirty | type == "boolean") and
    .compiler.version == $compiler and (.compiler.archive_sha256 | test("^[0-9a-f]{64}$")) and
    .cpu == "baseline" and .optimize == "ReleaseSafe" and .persistence_test_controls == false and
    .runtime_base == $runtime and .binary.path == "bin/kgcache" and
    (.binary.sha256 | test("^[0-9a-f]{64}$"))' "$metadata" >/dev/null || release_fail 'invalid release build record'
release_platform "$(jq -r .platform "$metadata")"
[[ $(jq -r .target "$metadata") == "$release_target" ]] || release_fail 'platform and target do not agree'
[[ "$allow_dirty" == true || $(jq -r .source.dirty "$metadata") == false ]] || release_fail 'development artifact has dirty source'
release_check_binary "$prefix/bin/kgcache"
[[ $(release_sha256 "$prefix/bin/kgcache") == $(jq -r .binary.sha256 "$metadata") ]] || release_fail 'binary checksum mismatch'
printf 'Verified %s release artifact.\n' "$(jq -r .platform "$metadata")" >&2

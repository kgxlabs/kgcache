#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

platform=linux/amd64
prefix=
allow_dirty=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) [[ $# -ge 2 ]] || release_fail 'missing platform'; platform=$2; shift 2 ;;
        --prefix) [[ $# -ge 2 && -n "$2" ]] || release_fail 'missing prefix'; prefix=$2; shift 2 ;;
        --allow-dirty) allow_dirty=true; shift ;;
        --help) printf 'Usage: bash tools/release/build.sh [--platform linux/amd64|linux/arm64] [--prefix DIR] [--allow-dirty]\n'; exit 0 ;;
        *) release_fail "unknown argument: $1" ;;
    esac
done
release_platform "$platform"
cd "$release_root"
prefix=${prefix:-"$release_root/zig-out/release/${platform//\//-}"}
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd -P)
[[ "$prefix" != "$release_root/zig-out" && "$prefix" != "$release_root" && "$prefix" != / ]] ||
    release_fail 'release output must be separate from the normal install prefix'
source_revision=$(git rev-parse HEAD)
source_status=$(git status --porcelain --untracked-files=normal)
source_dirty=false
if [[ -n "$source_status" ]]; then
    source_dirty=true
    [[ "$allow_dirty" == true ]] || release_fail 'source tree is dirty; commit changes or use --allow-dirty for a development artifact'
fi
source_version=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' build.zig.zon)
[[ -n "$source_version" ]] || release_fail 'missing package version'
compiler=$(bash tools/release/zig.sh --print-path)
compiler_archive_sha=$(cat "$(dirname "$compiler")/.verified-sha256")
"$compiler" build "-Dtarget=$release_target" -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$prefix"
[[ $(git rev-parse HEAD) == "$source_revision" && $(git status --porcelain --untracked-files=normal) == "$source_status" ]] ||
    release_fail 'source tree changed during the release build'
release_check_binary "$prefix/bin/kgcache"
binary_sha=$(release_sha256 "$prefix/bin/kgcache")
metadata_temp=$(mktemp "$prefix/.build-info.XXXXXX")
trap 'rm -f -- "$metadata_temp"' EXIT
jq -n --arg version "$source_version" --arg revision "$source_revision" \
    --argjson dirty "$source_dirty" --arg platform "$platform" --arg target "$release_target" \
    --arg compiler "$release_zig_version" --arg archive_sha "$compiler_archive_sha" \
    --arg sha "$binary_sha" --arg runtime "$release_runtime" \
    '{schema_version: 1, version: $version, source: {revision: $revision, dirty: $dirty},
      platform: $platform, target: $target, cpu: "baseline", optimize: "ReleaseSafe",
      persistence_test_controls: false, compiler: {version: $compiler, archive_sha256: $archive_sha},
      runtime_base: $runtime, binary: {path: "bin/kgcache", sha256: $sha}}' >"$metadata_temp"
mv "$metadata_temp" "$prefix/build-info.json"
verify_args=(--prefix "$prefix")
if [[ "$allow_dirty" == true ]]; then verify_args+=(--allow-dirty); fi
bash tools/release/verify.sh "${verify_args[@]}"
printf 'Release artifact: %s\n' "$prefix"

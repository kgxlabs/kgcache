#!/usr/bin/env bash
# Local builds may have unknown provenance. Clean builds require explicit metadata.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../release/common.sh"

main() {
    local platform="${TARGETOS:?}/${TARGETARCH:?}" compiler archive_sha version sha target

    [[ "$platform" == linux/amd64 ]] ||
        release_fail "unsupported image platform: $platform (supported: linux/amd64)"
    [[ ${SOURCE_DIRTY:-} == true || ${SOURCE_DIRTY:-} == false ]] ||
        release_fail 'SOURCE_DIRTY must be true or false'
    [[ ${SOURCE_REVISION:-} == unknown || ${SOURCE_REVISION:-} =~ ^[0-9a-f]{40}$ ]] ||
        release_fail 'SOURCE_REVISION must be a full Git revision or unknown for development'
    if [[ "$SOURCE_DIRTY" == false ]]; then
        [[ "$SOURCE_REVISION" != unknown ]] ||
            release_fail 'clean images require an explicit full Git revision'
        [[ -n ${VERSION:-} ]] || release_fail 'clean images require an explicit VERSION'
    fi

    version=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' build.zig.zon)
    [[ -n "$version" && "$version" != *$'\n'* ]] ||
        release_fail 'cannot read a single package version'
    [[ -z ${VERSION:-} || "$VERSION" == "$version" ]] ||
        release_fail 'VERSION must match build.zig.zon'
    [[ ${IMAGE_RUNTIME_BASE:-} == "$RUNTIME_BASE" ]] ||
        release_fail 'image base differs from the qualified release base'

    compiler=$(bash tools/release/zig.sh --print-path)
    archive_sha=$(cat "${compiler%/*}/.verified-sha256")
    target=$(release_target "$platform")
    timeout --signal=TERM --kill-after=10s 600s "$compiler" build \
        "-Dtarget=$target" "-Dcpu=$RELEASE_CPU" "-Doptimize=$RELEASE_OPTIMIZE" \
        --cache-dir .zig-cache/objects --prefix /out
    release_check_binary /out/bin/kgcache "$platform"
    sha=$(release_sha256 /out/bin/kgcache)
    jq --null-input --arg version "$version" --arg revision "$SOURCE_REVISION" \
        --argjson dirty "$SOURCE_DIRTY" --arg platform "$platform" \
        --arg target "$target" --arg cpu "$RELEASE_CPU" \
        --arg optimize "$RELEASE_OPTIMIZE" --arg compiler "$ZIG_VERSION" \
        --arg archive_sha "$archive_sha" --arg runtime "$RUNTIME_BASE" --arg sha "$sha" \
        --from-file tools/release/create-build-info.jq > /out/build-info.json
}

main "$@"

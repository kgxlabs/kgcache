#!/usr/bin/env bash
# BuildKit supplies provenance because the build context excludes Git metadata.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../release/common.sh"

main() {
    local platform="${TARGETOS:?}/${TARGETARCH:?}" compiler archive_sha version sha target

    [[ "$platform" == linux/amd64 ]] ||
        release_fail "unsupported image platform: $platform (supported: linux/amd64)"
    [[ ${SOURCE_REVISION:-} =~ ^[0-9a-f]{40}$ ]] ||
        release_fail 'SOURCE_REVISION must be an explicit full Git revision'
    [[ ${SOURCE_DIRTY:-} == true || ${SOURCE_DIRTY:-} == false ]] ||
        release_fail 'SOURCE_DIRTY must be true or false'
    version=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' build.zig.zon)
    [[ -n ${VERSION:-} && "$VERSION" == "$version" ]] ||
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

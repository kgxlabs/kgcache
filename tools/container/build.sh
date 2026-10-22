#!/usr/bin/env bash
# Local builds may have unknown provenance. Clean builds require explicit metadata.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../release/common.sh"

main() {
    local platform="${TARGETOS:?}/${TARGETARCH:?}" compiler archive_sha version sha target
    local development_version

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

    development_version=$(release_development_version)
    version=${VERSION:-$development_version}
    release_validate_version "$version" VERSION
    [[ ${IMAGE_RUNTIME_BASE:-} == "$RUNTIME_BASE" ]] ||
        release_fail 'image base differs from the qualified release base'

    compiler=$(bash tools/release/zig.sh --print-path)
    archive_sha=$(cat "${compiler%/*}/.verified-sha256")
    target=$(release_target "$platform")
    release_compile "$compiler" /out "$platform" "$version" \
        --cache-dir .zig-cache/objects
    release_check_binary /out/bin/kgcache "$platform"
    sha=$(release_sha256 /out/bin/kgcache)
    jq --null-input --arg version "$version" --arg revision "$SOURCE_REVISION" \
        --arg development_version "$development_version" \
        --argjson dirty "$SOURCE_DIRTY" --arg platform "$platform" \
        --arg target "$target" --arg cpu "$RELEASE_CPU" \
        --arg optimize "$RELEASE_OPTIMIZE" --arg compiler "$ZIG_VERSION" \
        --arg archive_sha "$archive_sha" --arg runtime "$RUNTIME_BASE" --arg sha "$sha" \
        --from-file tools/release/create-build-info.jq > /out/build-info.json
}

main "$@"

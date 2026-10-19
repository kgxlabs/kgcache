#!/usr/bin/env bash
# Verify the release record and the exact executable it describes.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"

usage() {
    printf 'Usage: bash tools/release/verify.sh [--prefix DIR] [--allow-dirty]\n'
}

validate_record() {
    local metadata=$1 target=$2
    if ! jq --exit-status \
        --arg target "$target" \
        --arg cpu "$RELEASE_CPU" \
        --arg optimize "$RELEASE_OPTIMIZE" \
        --arg compiler "$ZIG_VERSION" \
        --arg runtime "$RUNTIME_BASE" \
        --from-file "$RELEASE_ROOT/tools/release/validate-build-info.jq" \
        "$metadata" > /dev/null; then
        release_fail "invalid release build record: $metadata"
    fi
}

main() {
    local prefix="$RELEASE_ROOT/zig-out/release/linux-amd64" allow_dirty=false
    local metadata platform target dirty expected_sha actual_sha
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                usage
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done
    release_require_commands jq file
    release_require_sha256
    metadata="$prefix/build-info.json"
    [[ -f "$metadata" ]] || release_fail "missing build record: $metadata"
    platform=$(release_read_field "$metadata" .platform)
    target=$(release_target "$platform")
    validate_record "$metadata" "$target"
    dirty=$(release_read_field "$metadata" .source.dirty)
    if [[ "$dirty" == true && "$allow_dirty" == false ]]; then
        release_fail 'development artifact has dirty source'
    fi
    release_check_binary "$prefix/bin/kgcache" "$platform"
    expected_sha=$(release_read_field "$metadata" .binary.sha256)
    actual_sha=$(release_sha256 "$prefix/bin/kgcache")
    [[ "$actual_sha" == "$expected_sha" ]] || release_fail 'binary checksum mismatch'
    printf 'Verified %s release artifact.\n' "$platform" >&2
}

main "$@"

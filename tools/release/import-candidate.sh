#!/usr/bin/env bash
# Verify a saved candidate, then load and inspect its exact image without a build.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"
source "${BASH_SOURCE[0]%/*}/candidate-common.sh"

import_workspace=
import_container=

cleanup_import() {
    local exit_status=$? failed=false

    trap - EXIT
    if [[ -n "$import_container" ]]; then
        timeout --signal=TERM --kill-after=2s 5s docker rm --force "$import_container" > /dev/null 2>&1 || failed=true
    fi
    if [[ -n "$import_workspace" ]]; then
        rm -rf -- "$import_workspace" || failed=true
    fi
    if [[ "$exit_status" == 0 && "$failed" == true ]]; then
        exit_status=1
    fi
    exit "$exit_status"
}

main() {
    local candidate='' expected='' allow_emulation=false qualified engine image native=false manifest_sha

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --candidate | --expected-sha256)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --candidate) candidate=$2 ;;
                    --expected-sha256) expected=$2 ;;
                esac
                shift 2
                ;;
            --allow-emulation)
                allow_emulation=true
                shift
                ;;
            --help)
                printf 'Usage: bash tools/release/import-candidate.sh --candidate DIR [--expected-sha256 HASH] [--allow-emulation]\n'
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done
    [[ -n "$candidate" ]] || release_fail '--candidate is required'
    [[ -z "$expected" || "$expected" =~ ^[0-9a-f]{64}$ ]] || release_fail 'expected SHA-256 must have 64 lowercase hex characters'
    release_require_commands docker timeout jq file tar gzip head sort uniq cmp cut wc mktemp
    release_require_sha256

    trap cleanup_import EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    import_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-import.XXXXXX")
    candidate_snapshot_bundle "$candidate" "$import_workspace/bundle" "$expected"
    candidate_check_archive "$import_workspace/bundle" "$import_workspace/archive"
    qualified=$(release_read_field "$import_workspace/bundle/candidate.json" .qualification.qualified_amd64)
    engine=$(candidate_engine)
    if [[ "$engine" == linux/amd64 ]]; then
        native=true
    fi
    [[ "$allow_emulation" == true || ("$qualified" == true && "$native" == true) ]] ||
        release_fail 'native qualified candidate and amd64 engine required; use --allow-emulation for a development verification'
    image=$(release_read_field "$import_workspace/bundle/candidate.json" .image.id)
    timeout --signal=TERM --kill-after=5s 180s docker image load \
        --input "$import_workspace/archive/image.tar" > "$import_workspace/load.log"
    # The archive configuration and every layer were checked before Docker loads
    # it. An existing local image with the expected ID cannot hide a wrong archive.
    import_container="kgcache-import-${import_workspace##*.}"
    candidate_inspect_image "$image" "$import_workspace/bundle" "$import_container" "$import_workspace/image"
    import_container=
    manifest_sha=$(release_sha256 "$import_workspace/bundle/candidate.json")
    jq -n \
        --arg manifest "$manifest_sha" \
        --arg image "$image" \
        --arg engine "$engine" \
        --argjson native "$native" \
        --slurpfile candidate "$import_workspace/bundle/candidate.json" \
        '{schema_version: 1, passed: true, publishable: false, rebuilt: false, candidate_sha256: $manifest,
          source_sha: $candidate[0].source_sha, version: $candidate[0].version, image_id: $image,
          engine: $engine, native_import: $native,
          candidate_qualified_amd64: $candidate[0].qualification.qualified_amd64}'
}

main "$@"

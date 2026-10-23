#!/usr/bin/env bash
# Keep expected failures in a fresh shell with normal errexit handling.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"
source "${BASH_SOURCE[0]%/*}/../../tools/release/candidate-common.sh"

[[ $# -ge 3 && $# -le 4 ]] || release_fail 'candidate fixture expects mode, bundle, workspace, and optional checksum'
case "$1" in
    bundle)
        candidate_snapshot_bundle "$2" "$3/bundle" "${4:-}"
        candidate_check_archive "$3/bundle" "$3/archive"
        ;;
    archive) candidate_check_archive "$2" "$3" ;;
    request) candidate_validate_request "$2" "$3" ;;
    *) release_fail 'unknown candidate fixture mode' ;;
esac

#!/usr/bin/env bash
# Run expected failures in a separate process so EXIT cleanup is exercised.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"
source "${BASH_SOURCE[0]%/*}/docker.sh"

main() {
    cd "$RELEASE_ROOT"
    case "$1" in
        git-status)
            release_assert_source "$2"
            ;;
        bootstrap)
            # Exercise the old CI command. The build check must reject an empty
            # compiler even when this shell construct masks bootstrap failure.
            # shellcheck disable=SC2312
            ZIG=$(bash tools/release/zig.sh --print-path) bash tests/build/run.sh
            ;;
        docker-timeout)
            probe_id=$2
            trap probe_cleanup EXIT
            probe_run runtime linux/amd64 "$RUNTIME_BASE" 2s "$3" \
                sh -c 'trap "" TERM; while :; do sleep 1; done'
            ;;
        *) release_fail "unknown failure fixture: $1" ;;
    esac
}

main "$@"

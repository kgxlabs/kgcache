#!/usr/bin/env bash
# Read a PR title/body or a complete commit message from stdin.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"

[[ $# == 0 ]] || release_fail 'usage: bash tools/release/compatibility.sh < message.txt'
release_require_commands jq
jq --raw-input --slurp --exit-status \
    --from-file "$RELEASE_ROOT/tools/release/compatibility.jq" > /dev/null

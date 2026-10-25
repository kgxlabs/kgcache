#!/usr/bin/env bash
# Check publication context failures in a separate shell.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

[[ $# == 3 ]] || release_fail 'expected repository, branch, and source'
release_require_workflow_source "$1" "$2" "$3"

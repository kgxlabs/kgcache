#!/usr/bin/env bash
# Run trusted base-branch tooling against PR metadata and Git objects only.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"

maintenance_workspace=

cleanup_maintenance() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "$maintenance_workspace" ]]; then
        rm -rf -- "$maintenance_workspace"
    fi
    exit "$exit_status"
}

main() {
    local event='' repo="$RELEASE_ROOT" base head revision main_sha kind

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event | --repo)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --event) event=$2 ;;
                    --repo) repo=$2 ;;
                esac
                shift 2
                ;;
            *) release_fail 'usage: bash tools/release/check-maintenance.sh --event FILE [--repo DIR]' ;;
        esac
    done
    release_require_commands git jq sed mktemp
    [[ -f "$event" ]] || release_fail 'PR event file is required'
    jq -e -L "$RELEASE_ROOT/tools/release" 'include "policy";
        .pull_request | (.base.ref | startswith("release/")) and
        (.base.ref[8:] | line_name) and (.base.sha | sha) and (.head.sha | sha)' "$event" > /dev/null ||
        release_fail 'expected a PR targeting canonical release/MAJOR.MINOR'
    base=$(jq -r '.pull_request.base.sha' "$event")
    head=$(jq -r '.pull_request.head.sha' "$event")
    trap cleanup_maintenance EXIT
    maintenance_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-maintenance.XXXXXX")
    jq -r '.pull_request | .title + "\n" + (.body // "")' "$event" > "$maintenance_workspace/pr-message"
    bash "$RELEASE_ROOT/tools/release/compatibility.sh" < "$maintenance_workspace/pr-message"
    git --no-replace-objects -C "$repo" rev-list --no-merges "$base..$head" > "$maintenance_workspace/commits"
    [[ -s "$maintenance_workspace/commits" ]] || release_fail 'PR introduces no maintenance commits'
    : > "$maintenance_workspace/main-commits"
    while IFS= read -r revision; do
        git --no-replace-objects -C "$repo" show -s --format=%B "$revision" > "$maintenance_workspace/message"
        bash "$RELEASE_ROOT/tools/release/compatibility.sh" < "$maintenance_workspace/message"
        sed -nE 's/^\(cherry picked from commit ([0-9a-f]{40})\)$/\1/p' "$maintenance_workspace/message" \
            >> "$maintenance_workspace/main-commits"
    done < "$maintenance_workspace/commits"
    sed -nE 's/^\(cherry picked from commit ([0-9a-f]{40})\)$/\1/p' "$maintenance_workspace/pr-message" \
        >> "$maintenance_workspace/main-commits"
    kind=$(jq -r '.pull_request.title' "$event")
    if jq -en --arg title "$kind" '$title | test("^fix(?:\\([^()]+\\))?: "; "i")' > /dev/null; then
        [[ -s "$maintenance_workspace/main-commits" ]] ||
            release_fail 'fix PR requires a full main cherry-pick reference in its body or commits'
    fi
    while IFS= read -r main_sha; do
        git --no-replace-objects -C "$repo" merge-base --is-ancestor "$main_sha" refs/remotes/origin/main ||
            release_fail 'backport source is not on pinned main'
        git --no-replace-objects -C "$repo" show -s --format=%B "$main_sha" > "$maintenance_workspace/message"
        bash "$RELEASE_ROOT/tools/release/compatibility.sh" < "$maintenance_workspace/message"
    done < "$maintenance_workspace/main-commits"
    printf 'Maintenance declarations and main references passed. Review still judges compatibility.\n'
}

main "$@"

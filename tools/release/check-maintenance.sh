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
    local event='' message='' repo="$RELEASE_ROOT" repo_given=false
    local base head revision main_sha kind

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event | --repo | --message)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --event) event=$2 ;;
                    --repo) repo=$2 repo_given=true ;;
                    --message) message=$2 ;;
                esac
                shift 2
                ;;
            *) release_fail 'usage: bash tools/release/check-maintenance.sh --event FILE [--repo DIR] | --message FILE' ;;
        esac
    done
    release_require_commands jq
    if [[ -n "$message" ]]; then
        [[ -z "$event" && "$repo_given" == false ]] ||
            release_fail '--message cannot be combined with --event or --repo'
        if [[ "$message" == - ]]; then
            release_validate_maintenance
        else
            release_validate_maintenance < "$message"
        fi
        return
    fi
    release_require_commands git mktemp
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
    release_validate_maintenance < "$maintenance_workspace/pr-message"
    git --no-replace-objects -C "$repo" rev-list --no-merges "$base..$head" > "$maintenance_workspace/commits"
    [[ -s "$maintenance_workspace/commits" ]] || release_fail 'PR introduces no maintenance commits'
    : > "$maintenance_workspace/main-commits"
    while IFS= read -r revision; do
        git --no-replace-objects -C "$repo" show -s --format=%B "$revision" > "$maintenance_workspace/message"
        release_validate_maintenance < "$maintenance_workspace/message"
        release_backport_commits < "$maintenance_workspace/message" \
            >> "$maintenance_workspace/main-commits"
    done < "$maintenance_workspace/commits"
    release_backport_commits < "$maintenance_workspace/pr-message" \
        >> "$maintenance_workspace/main-commits"
    kind=$(jq -r -L "$RELEASE_ROOT/tools/release" \
        'include "policy"; if fix_request(""; .pull_request.title)
         then "fix" else "maintenance" end' "$event")
    if [[ "$kind" == fix ]]; then
        [[ -s "$maintenance_workspace/main-commits" ]] ||
            release_fail 'fix PR requires a full main cherry-pick reference in its body or commits'
    fi
    while IFS= read -r main_sha; do
        release_validate_main_commit "$repo" "$main_sha" refs/remotes/origin/main
    done < "$maintenance_workspace/main-commits"
    printf 'Maintenance declarations and main references passed. Review still judges compatibility.\n'
}

main "$@"

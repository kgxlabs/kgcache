#!/usr/bin/env bash
# Execute the real maintenance preflight with local events and a tag API stub.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

maintenance_test_workspace=

cleanup_maintenance_workflow() {
    local exit_status=$?

    trap - EXIT
    [[ -z "$maintenance_test_workspace" ]] || rm -rf -- "$maintenance_test_workspace"
    exit "$exit_status"
}

check_target() {
    local branch=$1 status=$2 accepted=$3 api=$4 repository=${5:-fixture/kgcache} exit_status=0

    jq -n --arg branch "$branch" --arg repository "$repository" '{pull_request: {
        base: {ref: $branch}, head: {repo: {full_name: $repository}}}}' \
        > "$maintenance_test_workspace/event.json"
    : > "$maintenance_test_workspace/calls"
    (
        cd "$maintenance_test_workspace"
        env PATH="$maintenance_test_workspace/bin:$PATH" GH_TOKEN=fixture \
            REPOSITORY=fixture/kgcache RUNNER_TEMP="$maintenance_test_workspace" \
            GITHUB_EVENT_PATH="$maintenance_test_workspace/event.json" \
            TAG_FIXTURE_STATUS="$status" TAG_FIXTURE_CALLS="$maintenance_test_workspace/calls" \
            bash -e "$maintenance_test_workspace/preflight.sh"
    ) > "$maintenance_test_workspace/output.log" 2>&1 || exit_status=$?
    if [[ ("$accepted" == true && "$exit_status" != 0) || ("$accepted" == false && "$exit_status" == 0) ]]; then
        cat "$maintenance_test_workspace/output.log" >&2
        release_fail "maintenance preflight returned $exit_status for $branch (HTTP $status)"
    fi
    if [[ "$api" == false ]]; then
        [[ ! -s "$maintenance_test_workspace/calls" ]] || release_fail 'release series queried its original tag'
    else
        grep -Fxq "https://api.github.com/repos/fixture/kgcache/git/ref/tags/v${branch#release/}" \
            "$maintenance_test_workspace/calls"
    fi
}

main() {
    release_require_commands awk bash jq mktemp ln grep
    trap cleanup_maintenance_workflow EXIT
    maintenance_test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-maintenance-workflow.XXXXXX")
    mkdir "$maintenance_test_workspace/bin"
    ln -s "$RELEASE_ROOT" "$maintenance_test_workspace/base"
    awk '
        $0 == "      - name: Check the requested release version" { step = 1; next }
        step && $0 == "        run: |" { body = 1; next }
        body && substr($0, 1, 10) == "          " { print substr($0, 11); next }
        body && $0 !~ /^[[:space:]]*$/ { exit }
    ' "$RELEASE_ROOT/.github/workflows/maintenance.yml" > "$maintenance_test_workspace/preflight.sh"
    [[ -s "$maintenance_test_workspace/preflight.sh" ]] || release_fail 'maintenance workflow preflight is missing'
    cat > "$maintenance_test_workspace/bin/curl" << 'SH'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) printf '{}\n' > "$2"; shift 2 ;;
        https://api.github.com/*) printf '%s\n' "$1" >> "$TAG_FIXTURE_CALLS"; shift ;;
        *) shift ;;
    esac
done
printf '%s' "$TAG_FIXTURE_STATUS"
SH
    chmod +x "$maintenance_test_workspace/bin/curl"
    check_target release/0.1.0 200 true false
    check_target release/0.1.0-rc 200 true false
    check_target release/0.1.0-rc.1 200 true false
    check_target release/0.1.0-beta.1 404 true true
    check_target release/0.1.0-beta.1 200 false true
    check_target release/0.1.0-beta.1 500 false true
    check_target release/0.1 200 false false
    check_target release/0.1.0 200 false false other/fork
    printf 'Passed: maintenance workflow series, occupied tags, exact targets, and API failures\n'
}

main "$@"

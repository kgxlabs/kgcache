#!/usr/bin/env bash
# Git history and API fixtures stay local. No project refs or releases change.
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"
    source "${BASH_SOURCE[0]%/*}/../../tools/release/candidate-common.sh"
fi

github_test_workspace=
github_test_logs=
fixture_repo=
fixture_api=
fixture_cut=
fixture_policy=
fixture_fix=
fixture_backport=

cleanup_github_tests() {
    local exit_status=$?

    trap - EXIT
    [[ -z "$github_test_workspace" ]] || rm -rf -- "$github_test_workspace"
    exit "$exit_status"
}

fixture_commit() {
    git -C "$fixture_repo" add . || return $?
    git -C "$fixture_repo" -c core.hooksPath=/dev/null commit --quiet -m "$1" || return $?
    git -C "$fixture_repo" rev-parse HEAD
}

route() {
    local path=$1 file=$2

    jq --arg path "$path" --arg file "$file" '.[$path] = {file: $file}' \
        "$fixture_api/routes.json" > "$fixture_api/routes.next.json"
    mv "$fixture_api/routes.next.json" "$fixture_api/routes.json"
}

fixture_pr() {
    local number=$1 source=$2 branch=$3 time=$4

    jq -n --argjson number "$number" --arg source "$source" --arg branch "$branch" --arg time "$time" \
        '{number: $number, merged: true, state: "closed", merge_commit_sha: $source,
          title: "fix: compatible correction", body: "Reviewed summary", merged_at: $time,
          base: {repo: {full_name: "fixture/kgcache"}, ref: $branch},
          head: {sha: $source}, user: {login: "contributor"}, merged_by: {login: "maintainer"}}' \
        > "$fixture_api/pr-$number.json"
    jq -n --arg source "$source" '[{id: 1, state: "APPROVED", commit_id: $source,
        submitted_at: "2026-10-20T00:00:01Z", user: {login: "maintainer"}}]' \
        > "$fixture_api/reviews-$number.json"
    jq '[{number, merge_commit_sha, base}]' "$fixture_api/pr-$number.json" > "$fixture_api/associated-$source.json"
    route "/repos/fixture/kgcache/pulls/$number" "pr-$number.json"
    route "/repos/fixture/kgcache/pulls/$number/reviews?per_page=100" "reviews-$number.json"
    route "/repos/fixture/kgcache/commits/$source/pulls?per_page=100" "associated-$source.json"
}

setup_github_fixture() {
    fixture_repo="$github_test_workspace/repo"
    fixture_api="$github_test_workspace/api"
    mkdir -p "$fixture_repo" "$fixture_api" "$github_test_workspace/bin"
    cp "$RELEASE_ROOT/tests/release/github-curl.sh" "$github_test_workspace/bin/curl"
    chmod +x "$github_test_workspace/bin/curl"
    printf '{}\n' > "$fixture_api/routes.json"
    printf '{"permission":"write"}\n' > "$fixture_api/permission.json"
    route /repos/fixture/kgcache/collaborators/maintainer/permission permission.json
    git -C "$fixture_repo" init --quiet --initial-branch=main
    git -C "$fixture_repo" config user.name 'Release fixture'
    git -C "$fixture_repo" config user.email fixture@example.invalid
    git -C "$fixture_repo" config commit.gpgsign false
    git -C "$fixture_repo" config core.hooksPath /dev/null
    printf '.{\n    .version = "0.0.0",\n}\n' > "$fixture_repo/build.zig.zon"
    fixture_cut=$(fixture_commit 'chore: initial source')
    mkdir "$fixture_repo/.github"
    jq -n --arg cut "$fixture_cut" '{schema_version: 1, repository: "fixture/kgcache", lines: [{
        line: "0.2", branch: "release/0.2", cut_sha: $cut, status: "preparing", channel: "regular",
        prerelease_prefix: null, target_version: null, decision_ref: "https://github.com/fixture/kgcache/pull/1",
        notes_ref: "notes/0.2", baseline: null, activation: null, blocked_versions: []}]}' \
        > "$fixture_repo/.github/release-lines.json"
    fixture_policy=$(fixture_commit 'chore: register reviewed release line')
    fixture_pr 1 "$fixture_policy" main 2026-10-20T00:00:02Z
    printf 'compatible correction\n' > "$fixture_repo/fix.txt"
    fixture_fix=$(fixture_commit 'fix: correct main first')
    fixture_pr 2 "$fixture_fix" main 2026-10-20T00:00:05Z
    git -C "$fixture_repo" update-ref refs/remotes/origin/main "$fixture_fix"
    git -C "$fixture_repo" switch --quiet --detach "$fixture_cut"
    git -C "$fixture_repo" cherry-pick -x "$fixture_fix" > /dev/null
    fixture_backport=$(git -C "$fixture_repo" rev-parse HEAD)
    fixture_pr 3 "$fixture_backport" release/0.2 2026-10-20T00:00:06Z
    git -C "$fixture_repo" update-ref refs/remotes/origin/release/0.2 "$fixture_backport"
    jq -n --arg cut "$fixture_cut" --arg backport "$fixture_backport" '[
        {node_id: "branch-original", ref: "refs/heads/release/0.2", activity_type: "branch_creation",
          before: ("0" * 40), after: $cut, timestamp: "2026-10-20T00:00:04Z"},
        {node_id: "branch-update", ref: "refs/heads/release/0.2", activity_type: "pr_merge",
          before: $cut, after: $backport, timestamp: "2026-10-20T00:00:06Z"}]' > "$fixture_api/branch.json"
    jq -n --arg policy "$fixture_policy" --arg fix "$fixture_fix" '[
        {node_id: "main-registration", ref: "refs/heads/main", activity_type: "pr_merge",
          after: $policy, timestamp: "2026-10-20T00:00:02Z"},
        {node_id: "main-fix", ref: "refs/heads/main", activity_type: "pr_merge",
          after: $fix, timestamp: "2026-10-20T00:00:05Z"}]' > "$fixture_api/main.json"
    route '/repos/fixture/kgcache/activity?ref=refs%2Fheads%2Frelease%2F0.2&time_period=year&per_page=100' branch.json
    route '/repos/fixture/kgcache/activity?ref=refs%2Fheads%2Fmain&time_period=year&per_page=100' main.json
    jq -n --arg cut "$fixture_cut" '{repository: {full_name: "fixture/kgcache"},
        ref: "refs/heads/release/0.2", after: $cut, before: ("0" * 40),
        created: true, forced: false, deleted: false}' > "$github_test_workspace/create.json"
    jq -n --arg cut "$fixture_cut" --arg source "$fixture_backport" '{repository: {full_name: "fixture/kgcache"},
        ref: "refs/heads/release/0.2", after: $source, before: $cut,
        created: false, forced: false, deleted: false}' > "$github_test_workspace/update.json"
    jq -n '{repository: {full_name: "fixture/kgcache"}, ref: "release/0.2", ref_type: "branch"}' \
        > "$github_test_workspace/ui-create.json"
    jq -n --arg base "$fixture_cut" --arg head "$fixture_backport" --arg main "$fixture_fix" \
        '{pull_request: {title: "fix: correct supported behavior", body: ("(cherry picked from commit " + $main + ")"),
          base: {ref: "release/0.2", sha: $base}, head: {sha: $head}}}' > "$github_test_workspace/pr.json"
    export GITHUB_FIXTURE_ROOT="$fixture_api"
    export PATH="$github_test_workspace/bin:$PATH"
    export GH_TOKEN=fixture-read-only
}

select_fixture() {
    local name=$1 event=$2 source=$3 event_name=${4:-push}

    bash "$RELEASE_ROOT/tools/release/github.sh" --repo "$fixture_repo" --repository fixture/kgcache \
        --event "$event" --event-name "$event_name" --source-sha "$source" --output "$github_test_workspace/$name"
}

expect_github_failure() {
    local name=$1 message=$2 output

    shift 2
    if "$@" > "$github_test_logs/$name.log" 2>&1; then
        release_fail "$name unexpectedly passed"
    fi
    output=$(cat "$github_test_logs/$name.log")
    [[ "$output" == *"$message"* ]] || {
        cat "$github_test_logs/$name.log" >&2
        release_fail "$name failed for another reason"
    }
    printf 'Passed: %s\n' "$name"
}

mutate_api() {
    local file=$1 filter=$2

    cp "$fixture_api/$file" "$fixture_api/saved.json"
    jq "$filter" "$fixture_api/$file" > "$fixture_api/changed.json"
    mv "$fixture_api/changed.json" "$fixture_api/$file"
}

restore_api() {
    mv "$fixture_api/saved.json" "$fixture_api/$1"
}

check_github_selection() {
    local first second

    select_fixture creation "$github_test_workspace/create.json" "$fixture_cut"
    select_fixture ui-creation "$github_test_workspace/ui-create.json" "$fixture_cut" create
    first=$(jq -r '.request_key' "$github_test_workspace/creation/proposal.json")
    second=$(jq -r '.request_key' "$github_test_workspace/ui-creation/proposal.json")
    [[ "$first" == "$second" ]]
    jq -e --arg source "$fixture_cut" --arg policy "$fixture_policy" \
        '.source_sha == $source and .creation.policy_sha == $policy and .publishable == false and
          .creation.creation_id == "branch-original" and .version == "0.2.0"' \
        "$github_test_workspace/creation/proposal.json" > /dev/null
    select_fixture update "$github_test_workspace/update.json" "$fixture_backport"
    jq -e --arg source "$fixture_backport" --arg main "$fixture_fix" \
        '.source_sha == $source and .event.review.kind == "fix" and
          .event.review.main_commits == [$main] and .version == "0.2.0"' \
        "$github_test_workspace/update/proposal.json" > /dev/null
    select_fixture repeated "$github_test_workspace/update.json" "$fixture_backport"
    cmp "$github_test_workspace/update/proposal.json" "$github_test_workspace/repeated/proposal.json"
    printf 'Passed: immutable create/update, duplicate deliveries, and main-first reviews\n'

    mutate_api branch.json '. += [.[0] | .node_id = "branch-recreated"]'
    expect_github_failure recreated 'recreated release branch' \
        select_fixture recreated "$github_test_workspace/create.json" "$fixture_cut"
    restore_api branch.json
    mutate_api branch.json '.[1].activity_type = "force_push"'
    expect_github_failure forced 'force updated' \
        select_fixture forced "$github_test_workspace/update.json" "$fixture_backport"
    restore_api branch.json
    mutate_api branch.json 'map(select(.activity_type != "branch_creation"))'
    expect_github_failure expired 'missing original creation activity' \
        select_fixture expired "$github_test_workspace/update.json" "$fixture_backport"
    restore_api branch.json
    mutate_api main.json 'map(select(.timestamp > "2026-10-20T00:00:04Z"))'
    expect_github_failure missing-policy 'missing main activity' \
        select_fixture missing-policy "$github_test_workspace/create.json" "$fixture_cut"
    restore_api main.json
    mutate_api main.json '.[0].timestamp = "2026-10-20T00:00:04Z"'
    expect_github_failure ambiguous-policy 'missing main activity' \
        select_fixture ambiguous-policy "$github_test_workspace/create.json" "$fixture_cut"
    restore_api main.json
    mutate_api pr-1.json '.merged_at = "2026-10-20T00:00:05Z"'
    expect_github_failure late-registration 'not merged before branch creation' \
        select_fixture late-registration "$github_test_workspace/create.json" "$fixture_cut"
    restore_api pr-1.json
    mutate_api reviews-3.json '.[0].commit_id = ("f" * 40)'
    expect_github_failure stale-approval 'approval of its final head' \
        select_fixture stale-approval "$github_test_workspace/update.json" "$fixture_backport"
    restore_api reviews-3.json
    mutate_api reviews-3.json '. += [.[0] | .id = 2 | .submitted_at = "2026-10-20T00:00:03Z" | .state = "CHANGES_REQUESTED"]'
    expect_github_failure changes-requested 'unresolved maintainer change request' \
        select_fixture changes-requested "$github_test_workspace/update.json" "$fixture_backport"
    restore_api reviews-3.json
    mutate_api permission.json '.permission = "read"'
    expect_github_failure read-only-merger 'merger needs current maintainer' \
        select_fixture read-only-merger "$github_test_workspace/update.json" "$fixture_backport"
    restore_api permission.json
    mutate_api pr-3.json '.title = "feat: add feature"'
    expect_github_failure feature 'must not declare features' \
        select_fixture feature "$github_test_workspace/update.json" "$fixture_backport"
    restore_api pr-3.json
    mutate_api pr-2.json '.merged_at = "2026-10-20T00:00:07Z"'
    expect_github_failure not-main-first 'not merged on main first' \
        select_fixture not-main-first "$github_test_workspace/update.json" "$fixture_backport"
    restore_api pr-2.json
    expect_github_failure wrong-source 'push source differs' \
        select_fixture wrong-source "$github_test_workspace/update.json" "$fixture_cut"
}

check_github_previews() {
    local calls_before calls_after sha

    git -C "$fixture_repo" -c tag.gpgsign=false tag --annotate fixture-preview \
        "$fixture_cut" --message 'local fixture only'
    calls_before=$(wc -l < "$fixture_api/calls.log")
    bash "$RELEASE_ROOT/tools/release/github.sh" --repo "$fixture_repo" --repository fixture/kgcache \
        --event "$github_test_workspace/ui-create.json" \
        --event-name workflow_dispatch --source-sha "$fixture_backport" \
        --source-ref refs/tags/fixture-preview --version 0.2.0-rc.1+local.001 --output "$github_test_workspace/preview"
    calls_after=$(wc -l < "$fixture_api/calls.log")
    [[ "$calls_before" == "$calls_after" ]]
    jq -e --arg source "$fixture_cut" '.source_sha == $source and .mode == "preview" and
        .version == "0.2.0-rc.1+local.001" and .request_key == null and .publishable == false' \
        "$github_test_workspace/preview/proposal.json" > /dev/null
    sha=$(release_sha256 "$github_test_workspace/preview/proposal.json")
    jq -e --arg sha "$sha" '.proposal_sha256 == $sha and .api == []' \
        "$github_test_workspace/preview/github-evidence.json" > /dev/null
    candidate_validate_request "$github_test_workspace/preview/proposal.json" \
        "$github_test_workspace/preview/github-evidence.json"
    jq '.proposal_sha256 = ("f" * 64)' "$github_test_workspace/preview/github-evidence.json" \
        > "$github_test_workspace/wrong-evidence.json"
    expect_github_failure wrong-request-evidence 'request evidence differs' \
        bash "$RELEASE_ROOT/tests/release/candidate-child.sh" request \
        "$github_test_workspace/preview/proposal.json" "$github_test_workspace/wrong-evidence.json"
    printf 'Passed: tag preview pins source/version without API access or publication\n'
}

check_github_pagination() {
    local path='/repos/fixture/kgcache/activity?ref=refs%2Fheads%2Frelease%2F0.2&time_period=year&per_page=100'

    cp "$fixture_api/routes.json" "$fixture_api/routes.original.json"
    jq '.[0:1]' "$fixture_api/branch.json" > "$fixture_api/branch-first.json"
    jq '.[1:]' "$fixture_api/branch.json" > "$fixture_api/branch-next.json"
    jq --arg path "$path" '.[$path] = {file: "branch-first.json",
        next: ("https://api.github.com" + $path + "&after=cursor")} |
        .[$path + "&after=cursor"] = {file: "branch-next.json"}' \
        "$fixture_api/routes.json" > "$fixture_api/routes.next.json"
    mv "$fixture_api/routes.next.json" "$fixture_api/routes.json"
    select_fixture paginated "$github_test_workspace/update.json" "$fixture_backport"
    cmp "$github_test_workspace/paginated/proposal.json" "$github_test_workspace/update/proposal.json"
    jq --arg path "$path" '.[$path].next = "https://other.example.invalid/collect"' \
        "$fixture_api/routes.json" > "$fixture_api/routes.next.json"
    mv "$fixture_api/routes.next.json" "$fixture_api/routes.json"
    expect_github_failure hostile-pagination 'unexpected GitHub pagination URL' \
        select_fixture hostile-pagination "$github_test_workspace/update.json" "$fixture_backport"
    mv "$fixture_api/routes.original.json" "$fixture_api/routes.json"
    printf 'Passed: activity pagination preserves proof and rejects another service\n'
}

check_shared_policy() {
    local references

    jq -en -L "$RELEASE_ROOT/tools/release" 'include "policy";
        fix_request("chore: correction"; "fix: correct behavior") and
        fix_request("fix: correction"; "chore: compatible maintenance") and
        fix_request(""; "fix: correct behavior") and
        fix_request("fix: correction"; "") and
        (fix_request(""; "") | not) and
        (fix_request("ci: check code"; "chore: maintain checks") | not)' > /dev/null
    printf '%s\n' \
        'Review notes' \
        "(cherry picked from commit $fixture_fix)" \
        ' (cherry picked from commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)' \
        '(cherry picked from commit abc123)' \
        '(cherry picked from commit AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)' \
        '(cherry picked from commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) extra' \
        > "$github_test_workspace/references.txt"
    printf '(cherry picked from commit %s)\r\n' "$fixture_fix" \
        >> "$github_test_workspace/references.txt"
    references=$(release_backport_commits < "$github_test_workspace/references.txt")
    [[ "$references" == "$fixture_fix" ]] || release_fail 'backport reference grammar changed'
    printf 'Passed: shared fix classification and full main reference grammar\n'
}

check_review_states() {
    mutate_api reviews-3.json '. += [.[0] | .id = 2 | .state = "COMMENTED" | .submitted_at = "2026-10-20T00:00:03Z"]'
    select_fixture commented "$github_test_workspace/update.json" "$fixture_backport"
    restore_api reviews-3.json
    mutate_api reviews-3.json '.[0].state = "DISMISSED"'
    expect_github_failure dismissed-approval 'approval of its final head' \
        select_fixture dismissed-approval "$github_test_workspace/update.json" "$fixture_backport"
    restore_api reviews-3.json
    mutate_api reviews-3.json '.[0].user.login = "contributor"'
    expect_github_failure self-approval 'approval of its final head' \
        select_fixture self-approval "$github_test_workspace/update.json" "$fixture_backport"
    restore_api reviews-3.json
    mutate_api pr-3.json '.base.ref = "main"'
    expect_github_failure wrong-base 'expected a merged PR' \
        select_fixture wrong-base "$github_test_workspace/update.json" "$fixture_backport"
    restore_api pr-3.json
}

check_owner_review_bypass() {
    local original_main policy file

    original_main=$(git -C "$fixture_repo" rev-parse refs/remotes/origin/main)
    git -C "$fixture_repo" switch --quiet main
    printf '{"review_bypass":{"login":"maintainer","id":101}}\n' \
        > "$fixture_repo/.github/release-automation.json"
    policy=$(fixture_commit 'ci: allow the owner to bypass reviews')
    for file in pr-3.json reviews-3.json permission.json; do
        cp "$fixture_api/$file" "$fixture_api/owner-$file"
    done
    printf '[]\n' > "$fixture_api/reviews-3.json"
    expect_github_failure untrusted-review-bypass 'approval of its final head' \
        select_fixture untrusted-review-bypass "$github_test_workspace/update.json" "$fixture_backport"
    git -C "$fixture_repo" update-ref refs/remotes/origin/main "$policy"
    expect_github_failure other-review-merger 'approval of its final head' \
        select_fixture other-review-merger "$github_test_workspace/update.json" "$fixture_backport"
    mutate_api pr-3.json '.merged_by.id = 101 | .user.login = "maintainer"'
    expect_github_failure non-admin-review-bypass 'owner administration access' \
        select_fixture non-admin-review-bypass "$github_test_workspace/update.json" "$fixture_backport"
    printf '{"permission":"admin"}\n' > "$fixture_api/permission.json"
    select_fixture owner-review-bypass "$github_test_workspace/update.json" "$fixture_backport"
    mutate_api reviews-3.json '[{id: 2, state: "CHANGES_REQUESTED",
        submitted_at: "2026-10-20T00:00:03Z", user: {login: "reviewer"}}]'
    route /repos/fixture/kgcache/collaborators/reviewer/permission permission.json
    expect_github_failure owner-change-request 'unresolved maintainer change request' \
        select_fixture owner-change-request "$github_test_workspace/update.json" "$fixture_backport"
    for file in pr-3.json reviews-3.json permission.json; do
        cp "$fixture_api/owner-$file" "$fixture_api/$file"
    done
    git -C "$fixture_repo" update-ref refs/remotes/origin/main "$original_main"
    printf 'Passed: only the configured owner can merge without approval\n'
}

check_maintenance_prs() {
    local feature_sha

    bash "$RELEASE_ROOT/tools/release/check-maintenance.sh" \
        --repo "$fixture_repo" --event "$github_test_workspace/pr.json"
    jq '.pull_request.title = "fix!: incompatible correction"' \
        "$github_test_workspace/pr.json" > "$github_test_workspace/breaking-pr.json"
    expect_github_failure breaking-pr 'must not declare features' \
        bash "$RELEASE_ROOT/tools/release/check-maintenance.sh" \
        --repo "$fixture_repo" --event "$github_test_workspace/breaking-pr.json"
    expect_github_failure mixed-maintenance-mode 'cannot be combined' \
        bash "$RELEASE_ROOT/tools/release/check-maintenance.sh" \
        --event "$github_test_workspace/pr.json" --message - < /dev/null
    git -C "$fixture_repo" switch --quiet main
    printf 'new behavior\n' > "$fixture_repo/feature.txt"
    feature_sha=$(fixture_commit 'feat: introduce behavior on main')
    git -C "$fixture_repo" update-ref refs/remotes/origin/main "$feature_sha"
    jq --arg source "$feature_sha" \
        '.pull_request.body = "(cherry picked from commit " + $source + ")"' \
        "$github_test_workspace/pr.json" > "$github_test_workspace/feature-main-pr.json"
    expect_github_failure feature-main-source 'must not declare features' \
        bash "$RELEASE_ROOT/tools/release/check-maintenance.sh" \
        --repo "$fixture_repo" --event "$github_test_workspace/feature-main-pr.json"
}

main() {
    [[ $# == 0 ]] || release_fail 'usage: bash tests/release/github.sh'
    release_require_commands git jq sed timeout curl mktemp cmp wc
    release_require_sha256
    trap cleanup_github_tests EXIT
    mkdir -p "$RELEASE_ROOT/.zig-cache" "$RELEASE_ROOT/test-artifacts/release/github"
    github_test_workspace=$(mktemp -d "$RELEASE_ROOT/.zig-cache/github-tests.XXXXXX")
    github_test_logs=$(mktemp -d "$RELEASE_ROOT/test-artifacts/release/github/run.XXXXXX")
    printf 'GitHub contract evidence: %s\n' "$github_test_logs"
    setup_github_fixture
    check_shared_policy
    check_github_selection
    check_github_pagination
    check_review_states
    check_owner_review_bypass
    check_github_previews
    check_maintenance_prs
    cp "$fixture_api/calls.log" "$github_test_logs/calls.log"
    cp "$github_test_workspace/update/proposal.json" "$github_test_logs/update-proposal.json"
    cp "$github_test_workspace/preview/proposal.json" "$github_test_logs/preview-proposal.json"
    printf 'GitHub release contracts passed. No external requests or production refs were used.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

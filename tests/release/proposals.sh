#!/usr/bin/env bash
# All commits, branches, and tags in these checks belong to temporary fixtures.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

proposal_test_workspace=
proposal_test_logs=
# Fixture identity is shared by the setup helpers. No project Git state is used.
fixture_repo=
fixture_cut=
fixture_policy=
fixture_source=
fixture_main_fix=
fixture_before=

cleanup_tests() {
    local status=$?

    trap - EXIT
    if [[ -n "$proposal_test_workspace" ]]; then
        rm -rf -- "$proposal_test_workspace"
    fi
    exit "$status"
}

fixture_commit() {
    git -C "$fixture_repo" add . || return $?
    git -C "$fixture_repo" -c core.hooksPath=/dev/null commit --quiet -m "$1" || return $?
    git -C "$fixture_repo" rev-parse HEAD
}

empty_state() {
    jq -n '{schema_version: 1, repository: "fixture/kgcache", creation: null,
        updates: [], requests: [], releases: []}' > "$fixture_repo/state.json"
}

new_fixture() {
    fixture_repo=$(mktemp -d "$proposal_test_workspace/repo.XXXXXX")
    git -C "$fixture_repo" init --quiet --initial-branch=main
    git -C "$fixture_repo" config user.name 'Release fixture'
    git -C "$fixture_repo" config user.email fixture@example.invalid
    git -C "$fixture_repo" config commit.gpgsign false
    git -C "$fixture_repo" config core.hooksPath /dev/null
    printf 'state*.json\nevent.json\n*.out\n' > "$fixture_repo/.gitignore"
    printf '.{\n    .version = "0.0.0",\n}\n' > "$fixture_repo/build.zig.zon"
    fixture_cut=$(fixture_commit 'chore: initial source')
    mkdir -p "$fixture_repo/.github"
    jq -n --arg cut "$fixture_cut" '{schema_version: 1, repository: "fixture/kgcache", lines: [{
        line: "0.2", branch: "release/0.2", cut_sha: $cut, status: "preparing", channel: "regular",
        prerelease_prefix: null, target_version: null, decision_ref: "review/registration",
        notes_ref: "notes/0.2", baseline: null, activation: null, blocked_versions: []}]}' \
        > "$fixture_repo/.github/release-lines.json"
    fixture_policy=$(fixture_commit 'chore: register line')
    git -C "$fixture_repo" update-ref refs/remotes/origin/main "$fixture_policy"
    git -C "$fixture_repo" update-ref refs/remotes/origin/release/0.2 "$fixture_cut"
    jq -n --arg source "$fixture_cut" --arg policy "$fixture_policy" '{schema_version: 1, repository: "fixture/kgcache",
        kind: "create", branch: "release/0.2", source_sha: $source, before_sha: null,
        forced: false, deleted: false, creation_id: "original-cut", creation_policy_sha: $policy, review: null}' \
        > "$fixture_repo/event.json"
    fixture_source=$fixture_cut
    empty_state
}

run_proposal() {
    bash "$RELEASE_ROOT/tools/release/propose.sh" --repo "$fixture_repo" \
        --repository fixture/kgcache --state "$fixture_repo/state.json" "$@"
}

check_json() {
    jq -e "$1" "$fixture_repo/result.out" > /dev/null || release_fail "assertion failed: $1"
}

expect_rejection() {
    local name=$1 message=$2 status output

    shift 2
    if "$@" > "$proposal_test_logs/$name.log" 2>&1; then
        release_fail "$name unexpectedly passed"
    else status=$?; fi
    output=$(cat "$proposal_test_logs/$name.log")
    [[ "$status" != 0 && "$output" == *"$message"* ]] || {
        cat "$proposal_test_logs/$name.log" >&2
        release_fail "$name failed for an unexpected reason"
    }
    printf 'Passed: %s\n' "$name"
}

change_policy() {
    git -C "$fixture_repo" switch --quiet main
    jq "$1" "$fixture_repo/.github/release-lines.json" > "$fixture_repo/policy.out"
    mv "$fixture_repo/policy.out" "$fixture_repo/.github/release-lines.json"
    fixture_policy=$(fixture_commit 'chore: update reviewed policy')
    git -C "$fixture_repo" update-ref refs/remotes/origin/main "$fixture_policy"
}

save_creation() {
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    jq --slurpfile proposal "$fixture_repo/result.out" '.creation = $proposal[0].creation' \
        "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
}

add_release() {
    local version=$1 status=$2 source=${3:-$fixture_source} tag_object request_key

    git -C "$fixture_repo" -c tag.gpgsign=false tag --annotate "v$version" "$source" --message 'isolated release fixture'
    tag_object=$(git -C "$fixture_repo" rev-parse "refs/tags/v$version")
    # Independently encode the documented request tuple, without the proposer.
    printf '[1,"request","fixture/kgcache","release/0.2","%s"]' "$source" \
        > "$fixture_repo/key.out"
    request_key=$(release_sha256 "$fixture_repo/key.out")
    jq --arg version "$version" --arg status "$status" --arg source "$source" \
        --arg policy "$fixture_policy" --arg tag "$tag_object" --arg key "$request_key" \
        '(.requests | map(select(.request_key == $key)) | .[0].policy_sha // $policy) as $original
         | .releases += [{version: $version, source_sha: $source, policy_sha: $original,
            tag_object_sha: $tag, request_key: $key, branch: "release/0.2", status: $status}]' \
        "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
}

add_update() {
    local title=${1:-fix: compatible correction}

    git -C "$fixture_repo" switch --quiet main
    printf '%s\n' "$title $RANDOM" > "$fixture_repo/fix.txt"
    fixture_main_fix=$(fixture_commit 'fix: correct main first')
    fixture_policy=$fixture_main_fix
    git -C "$fixture_repo" update-ref refs/remotes/origin/main "$fixture_policy"
    fixture_before=$fixture_source
    git -C "$fixture_repo" switch --quiet --detach "$fixture_before"
    git -C "$fixture_repo" cherry-pick -x "$fixture_main_fix" > /dev/null
    git -C "$fixture_repo" -c core.hooksPath=/dev/null commit --quiet --amend -m "$title"
    fixture_source=$(git -C "$fixture_repo" rev-parse HEAD)
    git -C "$fixture_repo" update-ref refs/remotes/origin/release/0.2 "$fixture_source"
    jq -n --arg before "$fixture_before" --arg source "$fixture_source" --arg main "$fixture_main_fix" \
        '{schema_version: 1, repository: "fixture/kgcache", kind: "update", branch: "release/0.2",
          source_sha: $source, before_sha: $before, forced: false, deleted: false, creation_id: "original-cut",
          review: {before_sha: $before, source_sha: $source, decision_ref: "review/backport",
            kind: "fix", main_commits: [$main]}}' > "$fixture_repo/event.json"
}

save_update() {
    jq --slurpfile event "$fixture_repo/event.json" '.updates += [$event[0].review]' \
        "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
}

check_first_and_previews() {
    local before after

    new_fixture
    before=$(git -C "$fixture_repo" show-ref)
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0" and .source_eligible and .publishable == false and .proposal_only and
        .reused == false and (.request_key | length) == 64 and .creation.creation_id == "original-cut"'
    cp "$fixture_repo/result.out" "$proposal_test_logs/first.json"
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/repeat.out"
    cmp "$fixture_repo/result.out" "$fixture_repo/repeat.out"
    run_proposal --source "$fixture_cut" --version 0.2.0-rc.0+build.001 > "$fixture_repo/result.out"
    check_json '.mode == "preview" and .request_key == null and .state_request == null and
        .source_eligible == false and .image.version_tag == "0.2.0-rc.0_build.001"'
    run_proposal --source "$fixture_policy" --line 0.3 > "$fixture_repo/result.out"
    check_json '.version == "0.3.0" and .source_eligible == false and (.eligibility_limits | length) > 2'
    run_proposal --source "$fixture_cut" > "$fixture_repo/result.out"
    check_json '.version == "0.0.0" and .development_version == "0.0.0"'
    expect_rejection preview-line-version 'version belongs to another release line' \
        run_proposal --line 0.2 --version 0.3.0
    expect_rejection invalid-line 'line must be canonical' run_proposal --line 00.2
    expect_rejection docker-length '128 characters' run_proposal --version "1.2.3+$(printf '%0123d' 0)"
    expect_rejection event-source-override 'source from the event' \
        run_proposal --event "$fixture_repo/event.json" --source HEAD
    after=$(git -C "$fixture_repo" show-ref)
    [[ "$before" == "$after" ]] || release_fail 'proposal changed Git refs'
    printf 'Passed: first release, deterministic preview, and unchanged Git refs\n'
}

check_patch_and_retries() {
    new_fixture
    save_creation
    cp "$fixture_repo/event.json" "$fixture_repo/original-creation.out"
    add_release 0.2.0 complete
    change_policy '.lines[0].status = "supported"'
    add_update
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.1" and .reused == false'
    jq --slurpfile proposal "$fixture_repo/result.out" '.requests = [$proposal[0].state_request]' \
        "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    change_policy '.lines[0].notes_ref = "notes/updated-through-review"'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.1" and .reused and .policy_sha != .original_policy_sha and
        .state_request.policy_sha == .original_policy_sha and .reservation == null'
    add_release 0.2.1 incomplete
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.1" and .reused and .reservation.status == "incomplete" and
        .reservation.policy_sha == .original_policy_sha'
    run_proposal --event "$fixture_repo/original-creation.out" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0" and .reused and .reservation.status == "complete"'
    cp "$fixture_repo/event.json" "$fixture_repo/old-event.out"
    save_update
    add_update
    expect_rejection pending-tag 'earlier tagged request is unresolved' run_proposal --event "$fixture_repo/event.json"
    change_policy '.lines[0].blocked_versions = ["0.2.1"]'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.2"'
    expect_rejection blocked-retry 'version is blocked' run_proposal --event "$fixture_repo/old-event.out"
    printf 'Passed: patch, untagged/tagged retry, unresolved tag, and blocked skip\n'
}

check_abandoned_and_large_patch() {
    new_fixture
    save_creation
    add_release 0.2.0 abandoned
    add_update
    expect_rejection abandoned-policy 'abandoned tag requires' run_proposal --event "$fixture_repo/event.json"
    change_policy '.lines[0].blocked_versions = ["0.2.0"]'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.1"'

    new_fixture
    save_creation
    add_release 0.2.999999999999999999999999999999 complete
    change_policy '.lines[0].status = "supported"'
    add_update
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.1000000000000000000000000000000"'
    printf 'Passed: abandoned first tag and large patch progression\n'
}

check_candidates() {
    new_fixture
    change_policy '.lines[0] |= (.channel = "prerelease" | .prerelease_prefix = "rc" | .target_version = "0.2.0")'
    save_creation
    check_json '.version == "0.2.0-rc.1" and .channel == "prerelease"'
    add_release 0.2.0-rc.999999999999999999999999 complete
    add_update
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0-rc.1000000000000000000000000"'
    change_policy '.lines[0].prerelease_prefix = "beta"'
    expect_rejection candidate-backwards 'advance SemVer precedence' run_proposal --event "$fixture_repo/event.json"
    change_policy '.lines[0] |= (.channel = "regular" | .prerelease_prefix = null | .target_version = null)'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0" and .channel == "regular"'
    printf 'Passed: first candidate, large counter, prefix ordering, and regular graduation\n'
}

check_history_rejections() {
    local cut_event

    new_fixture
    cp "$fixture_repo/event.json" "$fixture_repo/cut-event.out"
    cut_event="$fixture_repo/cut-event.out"
    save_creation
    add_update
    run_proposal --event "$cut_event" > "$fixture_repo/result.out"
    check_json '.source_sha == .cut_sha'
    jq '.creation_id = "recreated"' "$fixture_repo/event.json" > "$fixture_repo/recreated.out"
    expect_rejection recreated-branch 'recreated release branch' run_proposal --event "$fixture_repo/recreated.out"
    jq '.forced = true' "$fixture_repo/event.json" > "$fixture_repo/forced.out"
    expect_rejection forced-branch 'forced or deleted' run_proposal --event "$fixture_repo/forced.out"
    jq '.before_sha = .source_sha | .review.before_sha = .source_sha' \
        "$fixture_repo/event.json" > "$fixture_repo/wrong-before.out"
    expect_rejection wrong-before 'one reviewed squash commit' run_proposal --event "$fixture_repo/wrong-before.out"
    empty_state
    expect_rejection missing-creation 'missing original creation proof' run_proposal --event "$fixture_repo/event.json"

    new_fixture
    jq --arg source "$fixture_policy" '.source_sha = $source' "$fixture_repo/event.json" > "$fixture_repo/wrong-cut.out"
    expect_rejection wrong-cut 'branch creation source differs' run_proposal --event "$fixture_repo/wrong-cut.out"
    jq --arg policy "$fixture_cut" '.creation_policy_sha = $policy' \
        "$fixture_repo/event.json" > "$fixture_repo/before-registration.out"
    expect_rejection creation-before-registration 'not registered at its original creation policy' \
        run_proposal --event "$fixture_repo/before-registration.out"
}

check_policy_and_state_rejections() {
    local actual_sha

    new_fixture
    change_policy '.lines[0].status = "retired"'
    expect_rejection retired-line 'line is retired' run_proposal --event "$fixture_repo/event.json"
    run_proposal --source "$fixture_cut" --line 0.2 --version 0.2.0 > "$fixture_repo/result.out"
    check_json '.source_eligible == false and any(.eligibility_limits[]; contains("retired"))'
    change_policy '.lines[0].status = "preparing" | .lines[0].blocked_versions = ["0.2.0"]'
    expect_rejection blocked-version 'version is blocked' run_proposal --event "$fixture_repo/event.json"
    change_policy '.lines = []'
    expect_rejection unregistered-line 'unregistered release line' run_proposal --event "$fixture_repo/event.json"
    change_policy '.lines = [{line: "00.2"}]'
    expect_rejection invalid-policy 'line must be canonical' run_proposal --source "$fixture_cut"

    new_fixture
    save_creation
    actual_sha=$fixture_policy
    expect_rejection stale-policy 'pinned origin/main' run_proposal --policy-sha "$fixture_cut"
    git -C "$fixture_repo" -c tag.gpgsign=false tag --annotate v0.2.0 "$fixture_cut" --message fixture
    expect_rejection unexplained-tag 'missing/conflicting reserved release record' run_proposal --event "$fixture_repo/event.json"
    git -C "$fixture_repo" tag --delete v0.2.0 > /dev/null
    add_release 0.2.0 complete
    git -C "$fixture_repo" tag --delete v0.2.0 > /dev/null
    expect_rejection missing-tag 'tag is missing or changed' run_proposal --event "$fixture_repo/event.json"
    git -C "$fixture_repo" -c tag.gpgsign=false tag --annotate v0.2.0 "$actual_sha" --message changed
    expect_rejection changed-tag 'missing/conflicting reserved release record' run_proposal --event "$fixture_repo/event.json"

    new_fixture
    git -C "$fixture_repo" -c tag.gpgsign=false tag v0.2.0 "$fixture_cut"
    expect_rejection lightweight-tag 'must be annotated' run_proposal --event "$fixture_repo/event.json"
}

check_maintenance() {
    local message

    printf 'fix(parser): correct framing\n\nReviewed compatible fix.\n' |
        bash "$RELEASE_ROOT/tools/release/check-maintenance.sh" --message -
    for message in 'feat: add behavior' 'Feat(cache): add behavior' 'fix!: change behavior' \
        $'fix: correction\n\nBREAKING CHANGE: changed replies' \
        $'chore: cleanup\n\nBREAKING-CHANGE: changed config'; do
        printf '%s\n' "$message" > "$proposal_test_workspace/message"
        expect_rejection "compatibility-${RANDOM}" 'must not declare features or breaking changes' \
            bash "$RELEASE_ROOT/tools/release/check-maintenance.sh" --message "$proposal_test_workspace/message"
    done
    new_fixture
    save_creation
    add_update 'feat: add new behavior'
    expect_rejection maintenance-feature 'must not declare features' run_proposal --event "$fixture_repo/event.json"
    printf 'Passed: declared features and breaking changes are rejected\n'
}

check_failed_requests() {
    new_fixture
    save_creation
    add_update
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    cp "$fixture_repo/event.json" "$fixture_repo/original-event.out"
    jq --slurpfile result "$fixture_repo/result.out" '.requests = [$result[0].state_request]' \
        "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    save_update
    add_update
    expect_rejection pending-untagged 'earlier untagged request is still pending' \
        run_proposal --event "$fixture_repo/event.json"
    jq '.requests[0].status = "failed"' "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0" and (.supersedes | length) == 1'
    jq '.requests[0].status = "superseded"' "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    expect_rejection superseded-request 'request was superseded' \
        run_proposal --event "$fixture_repo/original-event.out"

    new_fixture
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    jq --slurpfile result "$fixture_repo/result.out" '.requests = [$result[0].state_request | .version = "0.2.7"]' \
        "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    expect_rejection stale-request 'prior proposal is stale' run_proposal --event "$fixture_repo/event.json"
    jq --arg policy "$fixture_cut" '.requests[0].version = "0.2.0" | .requests[0].policy_sha = $policy' \
        "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    expect_rejection unregistered-saved-policy 'saved policy did not register' \
        run_proposal --event "$fixture_repo/event.json"
    jq '.requests[0].request_key = ("0" * 64)' "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    expect_rejection tampered-request-key 'saved request key does not match' \
        run_proposal --event "$fixture_repo/event.json"
    printf 'Passed: failed-source replacement, superseded retry, and stale request identity\n'
}

check_source_proofs() {
    local original_source root tree

    new_fixture
    save_creation
    add_update
    cp "$fixture_repo/event.json" "$fixture_repo/earlier-event.out"
    original_source=$fixture_source
    save_update
    add_update
    run_proposal --event "$fixture_repo/earlier-event.out" > "$fixture_repo/result.out"
    jq -e --arg source "$original_source" '.source_sha == $source' "$fixture_repo/result.out" > /dev/null
    jq '.updates = []' "$fixture_repo/state.json" > "$fixture_repo/state-next.json"
    mv "$fixture_repo/state-next.json" "$fixture_repo/state.json"
    expect_rejection missing-reviewed-progression 'missing reviewed first-parent progression' \
        run_proposal --event "$fixture_repo/event.json"

    new_fixture
    save_creation
    add_update
    jq --arg source "$fixture_source" '.review.main_commits = [$source]' \
        "$fixture_repo/event.json" > "$fixture_repo/not-main.out"
    expect_rejection main-first 'backport source is not merged on main' run_proposal --event "$fixture_repo/not-main.out"
    jq '.review.main_commits = []' "$fixture_repo/event.json" > "$fixture_repo/no-main.out"
    expect_rejection missing-backport-source 'fix backports require main_commits' \
        run_proposal --event "$fixture_repo/no-main.out"
    jq '.source_sha = ("0" * 40) | .review.source_sha = .source_sha' \
        "$fixture_repo/event.json" > "$fixture_repo/missing-source.out"
    expect_rejection missing-source 'missing commit or history' run_proposal --event "$fixture_repo/missing-source.out"

    tree=$(git -C "$fixture_repo" rev-parse "$fixture_cut^{tree}")
    root=$(printf 'fix: unrelated fixture\n' | git -C "$fixture_repo" commit-tree "$tree")
    git -C "$fixture_repo" update-ref refs/remotes/origin/release/0.2 "$root"
    jq --arg source "$root" '.source_sha = $source | .review.source_sha = $source' \
        "$fixture_repo/event.json" > "$fixture_repo/unrelated.out"
    expect_rejection unrelated-source 'source does not follow the registered cut' \
        run_proposal --event "$fixture_repo/unrelated.out"

    new_fixture
    save_creation
    add_update
    mkdir -p "$fixture_repo/.github"
    jq -n '{schema_version: 1, repository: "fixture/kgcache", lines: []}' \
        > "$fixture_repo/.github/release-lines.json"
    fixture_source=$(fixture_commit 'fix: keep main policy authoritative')
    git -C "$fixture_repo" update-ref refs/remotes/origin/release/0.2 "$fixture_source"
    # A reviewed maintenance edit may include a private policy copy. Main still governs.
    jq --arg before "$fixture_before" --arg source "$fixture_source" \
        '.before_sha = $before | .source_sha = $source | .review.before_sha = $before |
         .review.source_sha = $source | .review.kind = "maintenance"' \
        "$fixture_repo/event.json" > "$fixture_repo/private-policy.out"
    expect_rejection unreviewed-private-parent 'one reviewed squash commit' \
        run_proposal --event "$fixture_repo/private-policy.out"
    # Squash the fixture edit, preserving the registered cut as its parent.
    tree=$(git -C "$fixture_repo" rev-parse "$fixture_source^{tree}")
    fixture_source=$(printf 'chore: keep private copy separate\n' |
        git -C "$fixture_repo" commit-tree "$tree" -p "$fixture_cut")
    git -C "$fixture_repo" update-ref refs/remotes/origin/release/0.2 "$fixture_source"
    jq --arg source "$fixture_source" --arg before "$fixture_cut" \
        '.source_sha = $source | .before_sha = $before | .review.source_sha = $source |
         .review.before_sha = $before | .review.kind = "maintenance" | .review.main_commits = []' \
        "$fixture_repo/event.json" > "$fixture_repo/private-policy.out"
    run_proposal --event "$fixture_repo/private-policy.out" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0" and .decision_ref == "review/registration" and .source_eligible'
    change_policy '.lines[0].status = "retired"'
    expect_rejection private-policy-revocation 'line is retired' run_proposal --event "$fixture_repo/private-policy.out"
    printf 'Passed: immutable event source, complete reviews, main-first proof, and authoritative main policy\n'
}

check_additional_contracts() {
    local clone

    new_fixture
    clone="$proposal_test_workspace/shallow"
    git clone --quiet --depth 1 "file://$fixture_repo" "$clone"
    expect_rejection shallow-history 'shallow repositories are rejected' \
        bash tools/release/propose.sh --repo "$clone" --repository fixture/kgcache

    new_fixture
    save_creation
    add_release 0.2.0 complete
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0" and .reused and .reservation.status == "complete"'
    add_update
    expect_rejection preparing-after-regular 'requires supported line status' \
        run_proposal --event "$fixture_repo/event.json"
    change_policy '.lines[0].status = "supported"'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.1"'
    change_policy '.lines[0].baseline = {version: "0.2.0", source_sha: .lines[0].cut_sha, record_ref: "release/v0.2.0"} |
        .lines[0].activation = {source_sha: .lines[0].cut_sha, decision_ref: "review/activation"}'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.activation.decision_ref == "review/activation"'
    change_policy '.lines[0].baseline.version = "0.2.99"'
    expect_rejection invalid-baseline 'baseline lacks its completed fixed release record' \
        run_proposal --event "$fixture_repo/event.json"

    new_fixture
    save_creation
    add_release 0.2.0+one complete
    change_policy '.lines[0].status = "supported" |
        .lines[0].baseline = {version: "0.2.0+one", source_sha: .lines[0].cut_sha, record_ref: "release/metadata-baseline"}'
    add_update
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.1" and .baseline.version == "0.2.0+one"'
    add_release 0.2.0+two complete
    save_update
    add_update
    expect_rejection equal-metadata-precedence 'equal SemVer precedence' run_proposal --event "$fixture_repo/event.json"

    new_fixture
    change_policy '.lines[0] |= (.channel = "prerelease" | .prerelease_prefix = "alpha" | .target_version = "0.2.0")'
    save_creation
    cp "$fixture_repo/event.json" "$fixture_repo/creation-event.out"
    add_release 0.2.0-alpha.1 incomplete
    add_update
    change_policy '.lines[0].prerelease_prefix = "rc"'
    expect_rejection original-prefix-changed 'candidate prefix changed' \
        run_proposal --event "$fixture_repo/creation-event.out"
    expect_rejection channel-unresolved 'earlier tagged request is unresolved' \
        run_proposal --event "$fixture_repo/event.json"
    change_policy '.lines[0].blocked_versions = ["0.2.0-alpha.1"]'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0-rc.1"'
    add_release 0.2.0-rc.1 abandoned
    save_update
    add_update
    change_policy '.lines[0].blocked_versions += ["0.2.0-rc.1"]'
    run_proposal --event "$fixture_repo/event.json" > "$fixture_repo/result.out"
    check_json '.version == "0.2.0-rc.2"'
    change_policy '.lines[0].prerelease_prefix = "rc+metadata"'
    expect_rejection invalid-candidate-prefix 'prefix must not contain build metadata' \
        run_proposal --event "$fixture_repo/event.json"
    printf 'Passed: shallow rejection, lifecycle, baseline/activation, equal metadata, and advancing prefix\n'
}

main() {
    [[ $# == 0 ]] || release_fail 'usage: bash tests/release/proposals.sh'
    release_require_commands git jq bash mktemp cmp
    release_require_sha256
    cd "$RELEASE_ROOT"
    mkdir -p .zig-cache test-artifacts/release/proposals
    proposal_test_workspace=$(mktemp -d "$RELEASE_ROOT/.zig-cache/release-proposals.XXXXXX")
    proposal_test_logs=$(mktemp -d "$RELEASE_ROOT/test-artifacts/release/proposals/run.XXXXXX")
    trap cleanup_tests EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    jq -ne -L tools/release --from-file tests/release/semver_tests.jq
    check_first_and_previews
    check_patch_and_retries
    check_abandoned_and_large_patch
    check_candidates
    check_history_rejections
    check_policy_and_state_rejections
    check_maintenance
    check_failed_requests
    check_source_proofs
    check_additional_contracts
    printf 'Proposal checks passed. Evidence: %s\n' "$proposal_test_logs"
}

main "$@"

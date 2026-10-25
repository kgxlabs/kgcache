#!/usr/bin/env bash
# Sourced by publication.sh. All release refs and notes stay in local fixtures.
# The parent harness owns the shared fixture paths.
# shellcheck disable=SC2154

merged_pr_fixture() {
    local number=$1 branch=$2 version_message=$3 source

    if git -C "$fixture_repo" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$fixture_repo" switch --quiet "$branch"
    else
        git -C "$fixture_repo" switch --quiet -c "$branch" main
    fi
    printf '%s\n' "$number" > "$fixture_repo/release-request.txt"
    source=$(fixture_commit "$version_message")
    fixture_pr "$number" "$source" "$branch" 2026-10-20T00:00:10Z
    jq '.title = "chore(release): publish candidate" | .body = "Candidate notes from the PR." |
        .head.repo = {full_name:"fixture/kgcache"}' "$fixture_api/pr-$number.json" \
        > "$fixture_api/release-pr.json"
    cp "$fixture_api/release-pr.json" "$fixture_api/pr-$number.json"
    jq '{action:"closed",repository:{full_name:"fixture/kgcache"},pull_request:.}' \
        "$fixture_api/pr-$number.json" > "$publication_workspace/release-event-$number.json"
    git -C "$fixture_repo" push --quiet "$publication_remote" "$branch"
    route "/repos/fixture/kgcache/rules/branches/${branch//\//%2F}?per_page=100" merge-rules.json
    printf '%s\n' "$source"
}

check_merged_release_prs() {
    local original_repo=$fixture_repo
    local fixture_repo="$publication_workspace/versioned-repo"
    local publication_remote="$publication_workspace/versioned-remote.git"
    local candidate_test_workspace="$publication_workspace/versioned-candidate"
    local source key other_source saved_head actual_head

    git clone --quiet "$original_repo" "$fixture_repo"
    git -C "$fixture_repo" config user.name 'Release fixture'
    git -C "$fixture_repo" config user.email fixture@example.invalid
    git -C "$fixture_repo" config commit.gpgsign false
    git -C "$fixture_repo" config core.hooksPath /dev/null
    git -C "$fixture_repo" switch --quiet main
    git -C "$fixture_repo" rm --quiet .github/release-lines.json
    fixture_commit 'chore: remove the release registry' > /dev/null
    git clone --quiet --bare "$fixture_repo" "$publication_remote"
    source=$(merged_pr_fixture 21 release/0.3.0-rc.1 'chore(release): prepare candidate')
    jq '.action = "opened"' "$publication_workspace/release-event-21.json" > "$publication_workspace/opened.json"
    expect_github_failure opened-release 'requires a merged pull request' coordinate_fixture enqueue \
        --event "$publication_workspace/opened.json" --event-name pull_request --source "$source"
    jq '.pull_request.merged = false' "$publication_workspace/release-event-21.json" > "$publication_workspace/unmerged.json"
    expect_github_failure unmerged-release 'requires a merged pull request' coordinate_fixture enqueue \
        --event "$publication_workspace/unmerged.json" --event-name pull_request --source "$source"
    jq '.pull_request.base.ref = "main"' "$publication_workspace/release-event-21.json" > "$publication_workspace/wrong-target.json"
    expect_github_failure main-release-target 'expected release/VERSION' coordinate_fixture enqueue \
        --event "$publication_workspace/wrong-target.json" --event-name pull_request --source "$source"
    jq '.pull_request.base.ref = "release/0.3"' "$publication_workspace/release-event-21.json" > "$publication_workspace/incomplete-version.json"
    expect_github_failure incomplete-release-version 'complete SemVer' coordinate_fixture enqueue \
        --event "$publication_workspace/incomplete-version.json" --event-name pull_request --source "$source"
    jq '.pull_request.head.repo.full_name = "other/fork"' "$publication_workspace/release-event-21.json" > "$publication_workspace/fork-release.json"
    expect_github_failure fork-release 'identity differs' coordinate_fixture enqueue \
        --event "$publication_workspace/fork-release.json" --event-name pull_request --source "$source"
    jq '.pull_request.merge_commit_sha = ("f" * 40)' "$publication_workspace/release-event-21.json" > "$publication_workspace/wrong-merge.json"
    expect_github_failure wrong-release-merge 'identity differs' coordinate_fixture enqueue \
        --event "$publication_workspace/wrong-merge.json" --event-name pull_request --source "$source"
    [[ -z "$(git -C "$publication_remote" show-ref --verify refs/heads/release-state 2> /dev/null || true)" ]]
    coordinate_fixture enqueue --event "$publication_workspace/release-event-21.json" \
        --event-name pull_request --source "$source" > "$publication_workspace/versioned-request.json"
    key=$(jq -r .request_key "$publication_workspace/versioned-request.json")
    saved_head=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    jq '.pull_request.body = "Changed after the merge."' "$publication_workspace/release-event-21.json" \
        > "$publication_workspace/redelivery.json"
    coordinate_fixture enqueue --event "$publication_workspace/redelivery.json" \
        --event-name pull_request --source "$source" > "$publication_workspace/versioned-duplicate.json"
    cmp "$publication_workspace/versioned-request.json" "$publication_workspace/versioned-duplicate.json"
    actual_head=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    [[ "$saved_head" == "$actual_head" ]]
    coordinate_fixture allocate --request "$key" --output "$publication_workspace/versioned-selection" \
        > "$publication_workspace/versioned-allocated.json"
    jq -e --arg source "$source" '.version == "0.3.0-rc.1" and .source_sha == $source and
        .proposal.mode == "release" and .proposal.branch == "release/0.3.0-rc.1" and
        .proposal.release_notes.body == "Candidate notes from the PR."' \
        "$publication_workspace/versioned-allocated.json" > /dev/null
    candidate_validate_request "$publication_workspace/versioned-selection/proposal.json" \
        "$publication_workspace/versioned-selection/github-evidence.json"
    jq '.proposal' "$publication_workspace/versioned-allocated.json" > "$publication_workspace/versioned-proposal.json"
    mkdir -p "$candidate_test_workspace"
    create_fixture "$publication_workspace/versioned-proposal.json"
    coordinate_fixture qualify --request "$key" --candidate "$candidate_test_workspace/good" > /dev/null
    coordinate_fixture tag --request "$key" --candidate "$candidate_test_workspace/good" \
        > "$publication_workspace/versioned-tagged.json"
    coordinate_fixture tag --request "$key" --candidate "$candidate_test_workspace/good" \
        > "$publication_workspace/versioned-retry.json"
    cmp "$publication_workspace/versioned-tagged.json" "$publication_workspace/versioned-retry.json"
    actual_head=$(git -C "$publication_remote" rev-parse 'refs/tags/v0.3.0-rc.1^{commit}')
    [[ "$source" == "$actual_head" ]]
    other_source=$(merged_pr_fixture 22 release/0.3.0-rc.1 'chore: another candidate request')
    expect_github_failure duplicate-version 'version already belongs' coordinate_fixture enqueue \
        --event "$publication_workspace/release-event-22.json" --event-name pull_request --source "$other_source"
    source=$(merged_pr_fixture 23 release/0.3.0-rc.2 'chore(release): prepare next candidate')
    jq '.pull_request.body = ""' "$publication_workspace/release-event-23.json" \
        > "$publication_workspace/empty-notes.json"
    coordinate_fixture enqueue --event "$publication_workspace/empty-notes.json" \
        --event-name pull_request --source "$source" > "$publication_workspace/next-candidate.json"
    key=$(jq -r .request_key "$publication_workspace/next-candidate.json")
    coordinate_fixture allocate --request "$key" > "$publication_workspace/next-allocated.json"
    jq -e '.version == "0.3.0-rc.2" and
        (.proposal.release_notes.body | contains("/pull/23"))' \
        "$publication_workspace/next-allocated.json" > /dev/null
    jq -en -L "$RELEASE_ROOT/tools/release" --slurpfile request "$publication_workspace/next-allocated.json" \
        'include "publication"; {requests:{candidate:$request[0]}} | alias_plan("candidate") |
          .line == null and .latest == null' > /dev/null
    printf 'Passed: merged versioned PRs, automatic state, frozen notes, exact versions, and immutable retry\n'
}

check_merged_release_publication() {
    local publication_remote="$publication_workspace/versioned-remote.git"
    local candidate_test_workspace="$publication_workspace/versioned-candidate"
    local publication_key image summary previous_latest actual_latest

    # The publication helpers consume this local through Bash's dynamic scope.
    # shellcheck disable=SC2034
    publication_key=$(jq -r .request_key "$publication_workspace/versioned-tagged.json")
    previous_latest=$(jq -r .latest "$publication_workspace/http/state.json")
    seed_registry_transport
    publish_fixture upload > "$publication_workspace/versioned-uploaded.json"
    image=$(jq -r '.candidate.image_id' "$publication_workspace/versioned-uploaded.json")
    mkdir "$publication_workspace/versioned-verification"
    jq -n --arg image "$image" '{passed:true,image_id:$image,synthetic:true,qualified_amd64:false}' \
        > "$publication_workspace/versioned-verification/service.json"
    summary=$(release_sha256 "$publication_workspace/versioned-verification/service.json")
    jq -n --slurpfile request "$publication_workspace/versioned-uploaded.json" --arg sha "$summary" \
        '{passed:true,synthetic:true,native_amd64:false,digest:$request[0].registry.uploaded.digest,
          request_key:$request[0].request_key,candidate_sha256:$request[0].candidate_sha256,
          image_id:$request[0].candidate.image_id,engine_id:"synthetic-separate-engine",service_sha256:$sha}' \
        > "$publication_workspace/versioned-verification/verification.json"
    publish_fixture promote --verification "$publication_workspace/versioned-verification" > /dev/null
    publish_fixture release > "$publication_workspace/versioned-published.json"
    publish_fixture release > "$publication_workspace/versioned-publish-retry.json"
    cmp "$publication_workspace/versioned-published.json" "$publication_workspace/versioned-publish-retry.json"
    publish_fixture aliases > "$publication_workspace/versioned-complete.json"
    jq -e '.status == "complete" and .alias.intent.line == null and .alias.intent.latest == null' \
        "$publication_workspace/versioned-complete.json" > /dev/null
    jq -e 'any(.releases[]; .tag_name == "v0.3.0-rc.1" and .prerelease == true and
        (.body | startswith("Candidate notes from the PR.")) and (.assets | length == 4))' \
        "$publication_workspace/http/state.json" > /dev/null
    actual_latest=$(jq -r .latest "$publication_workspace/http/state.json")
    [[ "$actual_latest" == "$previous_latest" ]]
    printf 'Passed: versioned PR image, frozen GitHub notes, release assets, and unchanged stable latest\n'
}

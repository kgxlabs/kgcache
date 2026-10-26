#!/usr/bin/env bash
# Sourced by publication.sh. All release refs and notes stay in local fixtures.
# The parent harness owns the shared fixture paths.
# shellcheck disable=SC2154

check_release_artifact_identity() {
    jq -en -L "$RELEASE_ROOT/tools/release" 'include "candidate";
        {kind:"release",source_sha:("a" * 40),head_sha:("b" * 40)} as $event |
        {source_sha:$event.source_sha,run:{id:"9001"}} as $candidate |
        {id:77,expired:false,workflow_run:{id:9001,head_sha:$event.head_sha}} as $artifact |
        ($artifact | candidate_artifact_matches($candidate; $event; "77")) and
        ($artifact | .workflow_run.head_sha = $event.source_sha |
          candidate_artifact_matches($candidate; $event; "77") | not) and
        ($artifact | candidate_artifact_matches($candidate | .source_sha = ("c" * 40); $event; "77") | not) and
        ($artifact | .workflow_run.id = 9002 | candidate_artifact_matches($candidate; $event; "77") | not) and
        ($artifact | .expired = true | candidate_artifact_matches($candidate; $event; "77") | not) and
        ($artifact | candidate_artifact_matches($candidate; $event; "78") | not) and
        ($artifact | candidate_artifact_matches($candidate; $event | .head_sha = "invalid"; "77") | not) and
        ($artifact | .workflow_run.head_sha = $candidate.source_sha |
          candidate_artifact_matches($candidate; {kind:"update"}; "77"))' > /dev/null
    printf 'Passed: merged PR artifact head, selected source, run identity, expiration, and artifact ID\n'
}

merged_pr_fixture() {
    local number=$1 branch=$2 version_message=$3 main_fix=${4:-} source parent

    if git -C "$fixture_repo" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$fixture_repo" switch --quiet "$branch"
    else
        git -C "$fixture_repo" switch --quiet -c "$branch" main
    fi
    if [[ -n "$main_fix" ]]; then
        git -C "$fixture_repo" cherry-pick -x "$main_fix" > /dev/null
        source=$(git -C "$fixture_repo" rev-parse HEAD)
    else
        printf '%s\n' "$number" > "$fixture_repo/release-request.txt"
        source=$(fixture_commit "$version_message")
    fi
    parent=$(git -C "$fixture_repo" rev-parse "$source^")
    if ! jq -e --arg path "/repos/fixture/kgcache/commits/$parent/pulls?per_page=100" \
        'has($path)' "$fixture_api/routes.json" > /dev/null; then
        printf '[]\n' > "$fixture_api/associated-$parent.json"
        route "/repos/fixture/kgcache/commits/$parent/pulls?per_page=100" "associated-$parent.json"
    fi
    fixture_pr "$number" "$source" "$branch" 2026-10-20T00:00:10Z
    jq --arg main "$main_fix" '
        .title = (if $main == "" then "chore(release): publish candidate" else "fix: correct released behavior" end) |
        .body = ("Candidate notes from the PR." +
          if $main == "" then "" else "\n\n(cherry picked from commit " + $main + ")" end) |
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
    local source key other_source saved_head actual_head merge_source tree

    git clone --quiet "$original_repo" "$fixture_repo"
    git -C "$fixture_repo" config user.name 'Release fixture'
    git -C "$fixture_repo" config user.email fixture@example.invalid
    git -C "$fixture_repo" config commit.gpgsign false
    git -C "$fixture_repo" config core.hooksPath /dev/null
    git -C "$fixture_repo" switch --quiet main
    git -C "$fixture_repo" switch --quiet -c historical-docs
    printf 'historical documentation\n' > "$fixture_repo/historical-docs.txt"
    fixture_commit 'docs: add historical documentation' > /dev/null
    git -C "$fixture_repo" switch --quiet main
    printf 'historical main change\n' > "$fixture_repo/historical-main.txt"
    fixture_commit 'chore: update historical main' > /dev/null
    git -C "$fixture_repo" merge --quiet --no-ff -m 'Merge historical documentation' historical-docs
    git -C "$fixture_repo" rm --quiet .github/release-lines.json
    fixture_commit 'chore: remove the release registry' > /dev/null
    git clone --quiet --bare "$fixture_repo" "$publication_remote"
    source=$(merged_pr_fixture 21 release/0.3.0-rc.1 'chore(release): prepare candidate')
    tree=$(git -C "$fixture_repo" rev-parse "$source^{tree}")
    merge_source=$(git -C "$fixture_repo" commit-tree "$tree" -p "$source" -p "$fixture_fix" \
        -m 'chore: synthetic release merge')
    git -C "$fixture_repo" push --quiet "$publication_remote" "$merge_source:refs/heads/synthetic-merge"
    jq --arg source "$merge_source" '.pull_request.merge_commit_sha = $source' \
        "$publication_workspace/release-event-21.json" > "$publication_workspace/merge-source.json"
    expect_github_failure release-merge-source 'must have exactly one parent' coordinate_fixture enqueue \
        --event "$publication_workspace/merge-source.json" --event-name pull_request --source "$merge_source"
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
    printf 'Passed: inherited merges, squash-only release PRs, automatic state, frozen notes, exact versions, and immutable retry\n'
}

check_merged_release_publication() {
    local fixture_name=${1:-versioned} tag=${2:-v0.3.0-rc.1} notes=${3:-Candidate notes from the PR.}
    local publication_remote="$publication_workspace/$fixture_name-remote.git"
    local candidate_test_workspace="$publication_workspace/$fixture_name-candidate"
    local result="$publication_workspace/$fixture_name"
    local publication_key image summary previous_latest actual_latest next_key next_version

    # The publication helpers consume this local through Bash's dynamic scope.
    # shellcheck disable=SC2034
    publication_key=$(jq -r .request_key "$result-tagged.json")
    previous_latest=$(jq -r .latest "$publication_workspace/http/state.json")
    seed_registry_transport
    publish_fixture upload > "$result-uploaded.json"
    image=$(jq -r '.candidate.image_id' "$result-uploaded.json")
    mkdir "$result-verification"
    jq -n --arg image "$image" '{passed:true,image_id:$image,synthetic:true,qualified_amd64:false}' \
        > "$result-verification/service.json"
    summary=$(release_sha256 "$result-verification/service.json")
    jq -n --slurpfile request "$result-uploaded.json" --arg sha "$summary" \
        '{passed:true,synthetic:true,native_amd64:false,digest:$request[0].registry.uploaded.digest,
          request_key:$request[0].request_key,candidate_sha256:$request[0].candidate_sha256,
          image_id:$request[0].candidate.image_id,engine_id:"synthetic-separate-engine",service_sha256:$sha}' \
        > "$result-verification/verification.json"
    publish_fixture promote --verification "$result-verification" > /dev/null
    publish_fixture release > "$result-published.json"
    publish_fixture release > "$result-publish-retry.json"
    cmp "$result-published.json" "$result-publish-retry.json"
    publish_fixture aliases > "$result-complete.json"
    jq -e '.status == "complete" and .alias.intent.line == null and .alias.intent.latest == null' \
        "$result-complete.json" > /dev/null
    jq -e --arg tag "$tag" --arg notes "$notes" 'any(.releases[]; .tag_name == $tag and .prerelease == true and
        (.body | startswith($notes)) and (.assets | length == 4))' \
        "$publication_workspace/http/state.json" > /dev/null
    actual_latest=$(jq -r .latest "$publication_workspace/http/state.json")
    [[ "$actual_latest" == "$previous_latest" ]]
    printf 'Passed: versioned PR image, frozen GitHub notes, release assets, and unchanged stable latest\n'
    if [[ "$fixture_name" == manual || "$fixture_name" == automatic ]]; then
        next_version=${tag#v}
        next_version="${next_version%.*}.2"
        next_key=$(jq -r .request_key "$result-backport.json")
        coordinate_fixture allocate --request "$next_key" > "$result-after-publication.json"
        jq -e --arg version "$next_version" '.version == $version and .status == "admitted"' "$result-after-publication.json" > /dev/null
        printf 'Passed: the same RC branch continues after successful initial publication\n'
    fi
}

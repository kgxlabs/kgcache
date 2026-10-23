#!/usr/bin/env bash
# Inspect immutable Git objects and supplied history. Emit an advisory proposal.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"

proposal_workspace=

cleanup_proposal() {
    local status=$?

    trap - EXIT
    if [[ -n "$proposal_workspace" ]]; then
        rm -rf -- "$proposal_workspace"
    fi
    exit "$status"
}

require_commit() {
    local repo=$1 revision=$2 kind

    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || release_fail 'expected a full commit SHA'
    kind=$(git --no-replace-objects -C "$repo" cat-file -t "$revision") ||
        release_fail "missing commit or history: $revision"
    [[ "$kind" == commit ]] || release_fail "not a commit: $revision"
}

require_ancestor() {
    local repo=$1 ancestor=$2 descendant=$3 message=$4

    if git --no-replace-objects -C "$repo" merge-base --is-ancestor "$ancestor" "$descendant"; then
        return
    fi
    release_fail "$message"
}

require_first_parent() {
    local repo=$1 ancestor=$2 descendant=$3 message=$4 chain revision found=false

    chain=$(git --no-replace-objects -C "$repo" rev-list --first-parent "$descendant") ||
        release_fail 'cannot inspect first-parent history'
    while IFS= read -r revision; do
        if [[ "$revision" == "$ancestor" ]]; then
            found=true
        fi
    done <<< "$chain"
    [[ "$found" == true ]] || release_fail "$message"
}

tuple_key() {
    local kind=$1 repository=$2 branch=$3 source=$4 version=$5 encoded

    encoded=$(jq -cn \
        --arg kind "$kind" \
        --arg repository "$repository" \
        --arg branch "$branch" \
        --arg source "$source" \
        --arg version "$version" \
        'if $kind == "request" then [1, "request", $repository, $branch, $source]
         else [1, "source-version", $source, $version] end') ||
        release_fail 'cannot encode the identity tuple'
    printf '%s' "$encoded" > "$proposal_workspace/tuple" ||
        release_fail 'cannot write the identity tuple'
    release_sha256 "$proposal_workspace/tuple"
}

require_registered_policy() {
    local repo=$1 revision=$2 repository=$3 message=$4

    git --no-replace-objects -C "$repo" show "$revision:.github/release-lines.json" \
        > "$proposal_workspace/inspected-policy.json" || release_fail "$message"
    jq -es -L "$RELEASE_ROOT/tools/release" \
        --arg repository "$repository" \
        --slurpfile current "$proposal_workspace/line.json" \
        'include "policy";
         if length != 1 then error("expected one historical release policy")
         else .[0] | validate_policy($repository)
           | any(.lines[]; .branch == $current[0].branch and .cut_sha == $current[0].cut_sha and
             .decision_ref == $current[0].decision_ref and .status != "retired") end' \
        "$proposal_workspace/inspected-policy.json" > /dev/null || release_fail "$message"
}

validate_history() {
    local repo=$1 source=$2 policy_sha=$3 branch=$4 cut=$5 remote_sha=$6
    local creation_policy before revision parents main_sha creation_id event_kind repository

    event_kind=$(jq -r '.kind' "$proposal_workspace/event.json")
    if [[ "$event_kind" == create && "$source" != "$cut" ]]; then
        release_fail 'branch creation source differs from the registered cut'
    fi
    require_commit "$repo" "$cut"
    require_ancestor "$repo" "$cut" "$policy_sha" 'registered cut is not reachable from main policy'
    require_first_parent "$repo" "$cut" "$source" 'source does not follow the registered cut'
    require_first_parent "$repo" "$source" "$remote_sha" 'event source is not in the registered release history'
    require_first_parent "$repo" "$cut" "$remote_sha" 'release branch history was rewritten'

    if [[ "$event_kind" == create ]]; then
        jq -e --arg source "$source" --arg branch "$branch" \
            --slurpfile event "$proposal_workspace/event.json" \
            '.creation == null or (.creation.source_sha == $source and .creation.branch == $branch and
              .creation.creation_id == $event[0].creation_id and
              .creation.policy_sha == $event[0].creation_policy_sha)' "$proposal_workspace/state.json" > /dev/null ||
            release_fail 'release branch was recreated'
        jq -e '.creation != null or (.releases | length) == 0' \
            "$proposal_workspace/state.json" > /dev/null || release_fail 'reserved line requires original creation proof'
        creation_policy=$(jq -r '.creation_policy_sha' "$proposal_workspace/event.json")
        jq -e '.activation == null' "$proposal_workspace/line.json" > /dev/null ||
            release_fail 'an imported line requires a new reviewed update after activation'
    else
        jq -e --arg cut "$cut" --arg branch "$branch" \
            --slurpfile event "$proposal_workspace/event.json" \
            '.creation != null and .creation.branch == $branch and .creation.source_sha == $cut and
              .creation.creation_id == $event[0].creation_id' "$proposal_workspace/state.json" > /dev/null ||
            release_fail 'missing original creation proof or recreated release branch'
        creation_policy=$(jq -r '.creation.policy_sha' "$proposal_workspace/state.json")
        before=$(jq -r '.before_sha' "$proposal_workspace/event.json")
        require_commit "$repo" "$before"
        parents=$(git --no-replace-objects -C "$repo" show -s --format=%P "$source")
        [[ "$parents" == "$before" ]] ||
            release_fail 'an update must be one reviewed squash commit after before_sha'
    fi

    require_commit "$repo" "$creation_policy"
    require_ancestor "$repo" "$creation_policy" "$policy_sha" 'creation policy is not in current main history'
    repository=$(jq -r '.repository' "$proposal_workspace/state.json")
    require_registered_policy "$repo" "$creation_policy" "$repository" \
        'the line was not registered at its original creation policy'

    jq --slurpfile event "$proposal_workspace/event.json" \
        '.updates + (if $event[0].kind == "update" then [$event[0].review] else [] end)
         | group_by(.source_sha) | map(
           if (unique | length) != 1 then error("conflicting review records") else .[0] end)' \
        "$proposal_workspace/state.json" > "$proposal_workspace/reviews.json"
    git --no-replace-objects -C "$repo" rev-list --reverse --first-parent "$cut..$source" \
        > "$proposal_workspace/commits"
    while IFS= read -r revision; do
        parents=$(git --no-replace-objects -C "$repo" show -s --format=%P "$revision")
        jq -e --arg source "$revision" --arg before "$parents" \
            'any(.[]; .source_sha == $source and .before_sha == $before)' \
            "$proposal_workspace/reviews.json" > /dev/null ||
            release_fail "missing reviewed first-parent progression: $revision"
        git --no-replace-objects -C "$repo" show -s --format=%B "$revision" \
            > "$proposal_workspace/message"
        bash "$RELEASE_ROOT/tools/release/compatibility.sh" < "$proposal_workspace/message"
        jq -r --arg source "$revision" '.[] | select(.source_sha == $source) | .main_commits[]' \
            "$proposal_workspace/reviews.json" > "$proposal_workspace/main-commits"
        while IFS= read -r main_sha; do
            require_commit "$repo" "$main_sha"
            require_ancestor "$repo" "$main_sha" "$policy_sha" 'backport source is not merged on main'
            git --no-replace-objects -C "$repo" show -s --format=%B "$main_sha" \
                > "$proposal_workspace/message"
            bash "$RELEASE_ROOT/tools/release/compatibility.sh" < "$proposal_workspace/message"
        done < "$proposal_workspace/main-commits"
    done < "$proposal_workspace/commits"

    revision=$(jq -r '.activation.source_sha // empty' "$proposal_workspace/line.json")
    if [[ -n "$revision" ]]; then
        require_commit "$repo" "$revision"
        require_first_parent "$repo" "$cut" "$revision" 'activation does not follow the registered cut'
        require_first_parent "$repo" "$revision" "$before" 'request predates the reviewed activation'
        [[ "$source" != "$revision" ]] || release_fail 'activation requires a new branch update'
    fi
    # The original identity is returned as data, never written back to state.
    creation_id=$(jq -r '.creation_id' "$proposal_workspace/event.json")
    jq -n \
        --arg branch "$branch" \
        --arg source "$cut" \
        --arg policy "$creation_policy" \
        --arg id "$creation_id" \
        --slurpfile state "$proposal_workspace/state.json" \
        '$state[0].creation // {branch: $branch, source_sha: $source, policy_sha: $policy, creation_id: $id}' \
        > "$proposal_workspace/creation.json"
}

main() {
    local repo="$RELEASE_ROOT" repository=kgxlabs/kgcache source_ref=HEAD
    local policy_sha='' line='' version='' event='' state='' source_given=false
    local mode=preview source_sha branch='' main_sha remote_sha='' cut='' shallow
    local development_version request_key='' revision key record_branch \
        source_version_key expected_key reused prior_policy

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                printf 'Usage: bash tools/release/propose.sh [--repo DIR] [--repository OWNER/REPO] [--policy-sha SHA] [--state FILE] [--source REF] [--line MAJOR.MINOR] [--version SEMVER] [--event FILE]\n'
                return
                ;;
            --repo | --repository | --policy-sha | --state | --source | --line | --version | --event)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --repo) repo=$2 ;;
                    --repository) repository=$2 ;;
                    --policy-sha) policy_sha=$2 ;;
                    --state) state=$2 ;;
                    --source) source_ref=$2 source_given=true ;;
                    --line) line=$2 ;;
                    --version) version=$2 ;;
                    --event) event=$2 mode=branch ;;
                esac
                shift 2
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done

    release_require_commands git jq sed mktemp bash
    release_require_sha256
    jq -en --arg repository "$repository" \
        '$repository | test("\\A[a-z0-9_.-]+/[a-z0-9_.-]+\\z")' > /dev/null ||
        release_fail 'repository must be a lowercase OWNER/REPO slug'
    if [[ "$mode" == branch ]]; then
        [[ "$source_given" == false && -z "$version" ]] ||
            release_fail 'branch events take source from the event and version from policy'
    fi
    if [[ -n "$line" ]]; then
        jq -en -L "$RELEASE_ROOT/tools/release" --arg line "$line" \
            'include "policy"; $line | line_name' > /dev/null ||
            release_fail 'line must be canonical MAJOR.MINOR'
    fi
    if [[ -n "$version" ]]; then
        release_validate_version "$version"
    fi

    trap cleanup_proposal EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    proposal_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-proposal.XXXXXX")
    main_sha=$(git --no-replace-objects -C "$repo" rev-parse --verify 'refs/remotes/origin/main^{commit}') ||
        release_fail 'fetch origin/main before inspecting release policy'
    [[ -z "$policy_sha" || "$policy_sha" == "$main_sha" ]] ||
        release_fail 'policy_sha must match the pinned origin/main snapshot'
    policy_sha=$main_sha
    require_commit "$repo" "$policy_sha"
    shallow=$(git --no-replace-objects -C "$repo" rev-parse --is-shallow-repository)
    [[ "$shallow" == false ]] || release_fail 'complete Git history is required; shallow repositories are rejected'
    revision=$(git -C "$repo" rev-parse --path-format=absolute --git-path info/grafts)
    [[ ! -s "$revision" ]] || release_fail 'Git grafts are not supported for release proofs'

    if git --no-replace-objects -C "$repo" cat-file -e "$policy_sha:.github/release-lines.json" 2> /dev/null; then
        git --no-replace-objects -C "$repo" show "$policy_sha:.github/release-lines.json" \
            > "$proposal_workspace/policy-input.json"
    elif [[ "$mode" == preview ]]; then
        jq -n --arg repository "$repository" \
            '{schema_version: 1, repository: $repository, lines: []}' > "$proposal_workspace/policy-input.json"
    else release_fail 'release registry is missing from main policy'; fi
    jq -es -L "$RELEASE_ROOT/tools/release" --arg repository "$repository" \
        'include "policy"; if length == 1 then .[0] | validate_policy($repository)
         else error("expected one release policy") end' \
        "$proposal_workspace/policy-input.json" > "$proposal_workspace/policy.json"
    if [[ -n "$state" ]]; then
        jq -es -L "$RELEASE_ROOT/tools/release" --arg repository "$repository" \
            'include "policy"; if length == 1 then .[0] | validate_state($repository)
             else error("expected one release state") end' "$state" > "$proposal_workspace/state.json"
    else
        jq -n --arg repository "$repository" '{schema_version: 1, repository: $repository,
            creation: null, updates: [], requests: [], releases: []}' > "$proposal_workspace/state.json"
    fi
    if [[ "$mode" == branch ]]; then
        jq -es -L "$RELEASE_ROOT/tools/release" --arg repository "$repository" \
            'include "policy"; if length == 1 then .[0] | validate_event($repository)
             else error("expected one branch event") end' "$event" > "$proposal_workspace/event.json"
        source_sha=$(jq -r '.source_sha' "$proposal_workspace/event.json")
        branch=$(jq -r '.branch' "$proposal_workspace/event.json")
        [[ -z "$line" || "$line" == "${branch#release/}" ]] || release_fail 'event and selected line differ'
        line=${branch#release/}
    else
        source_sha=$(git --no-replace-objects -C "$repo" rev-parse --verify --end-of-options "$source_ref^{commit}") ||
            release_fail 'cannot resolve preview source'
        printf 'null\n' > "$proposal_workspace/event.json"
    fi
    require_commit "$repo" "$source_sha"
    development_version=$(git --no-replace-objects -C "$repo" show "$source_sha:build.zig.zon" |
        sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p') ||
        release_fail 'selected source is missing its development version'
    release_validate_version "$development_version" 'selected development version'
    jq --arg line "$line" '.lines | map(select(.line == $line)) | .[0] // null' \
        "$proposal_workspace/policy.json" > "$proposal_workspace/line.json"
    printf 'null\n' > "$proposal_workspace/creation.json"
    if [[ "$mode" == branch ]]; then
        jq -e '. != null' "$proposal_workspace/line.json" > /dev/null || release_fail 'unregistered release line'
        cut=$(jq -r '.cut_sha' "$proposal_workspace/line.json")
        remote_sha=$(git --no-replace-objects -C "$repo" rev-parse --verify "refs/remotes/origin/$branch^{commit}") ||
            release_fail 'registered remote release branch is missing'
        validate_history "$repo" "$source_sha" "$policy_sha" "$branch" "$cut" "$remote_sha"
        request_key=$(tuple_key request "$repository" "$branch" "$source_sha" '')
    fi

    git --no-replace-objects -C "$repo" for-each-ref \
        --format='%(refname:strip=2)%09%(objecttype)%09%(objectname)%09%(*objecttype)%09%(*objectname)' \
        'refs/tags/v*' > "$proposal_workspace/tags.tsv"
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") |
        {version: .[0][1:], type: .[1], object_sha: .[2], peeled_type: .[3], source_sha: .[4]})' \
        "$proposal_workspace/tags.tsv" > "$proposal_workspace/tags.json"
    jq -r '.requests[], .releases[] | [.branch, .source_sha, .request_key] | @tsv' \
        "$proposal_workspace/state.json" > "$proposal_workspace/keys.tsv"
    while IFS=$'\t' read -r record_branch revision key; do
        expected_key=$(tuple_key request "$repository" "$record_branch" "$revision" '')
        [[ "$key" == "$expected_key" ]] ||
            release_fail 'saved request key does not match repository, branch, and source'
    done < "$proposal_workspace/keys.tsv"

    jq -n -L "$RELEASE_ROOT/tools/release" \
        --arg mode "$mode" \
        --arg repository "$repository" \
        --arg source "$source_sha" \
        --arg policy_sha "$policy_sha" \
        --arg line "$line" \
        --arg explicit_version "$version" \
        --arg development_version "$development_version" \
        --arg request_key "$request_key" \
        --slurpfile policy "$proposal_workspace/policy.json" \
        --slurpfile state "$proposal_workspace/state.json" \
        --slurpfile event "$proposal_workspace/event.json" \
        --slurpfile tags "$proposal_workspace/tags.json" \
        --slurpfile creation "$proposal_workspace/creation.json" \
        --from-file "$RELEASE_ROOT/tools/release/propose.jq" > "$proposal_workspace/proposal.json"

    # Check actual Git ancestry for reserved and earlier untagged requests.
    if [[ "$mode" == branch ]]; then
        reused=$(jq -r '.reused' "$proposal_workspace/proposal.json")
        jq -r '.releases[], .requests[] | select(.branch == "release/" + $line) |
            [.source_sha, .request_key, .policy_sha] | @tsv' --arg line "$line" \
            "$proposal_workspace/state.json" > "$proposal_workspace/previous.tsv"
        while IFS=$'\t' read -r revision key prior_policy; do
            require_commit "$repo" "$revision"
            require_commit "$repo" "$prior_policy"
            require_ancestor "$repo" "$prior_policy" "$policy_sha" 'saved policy is not in current main history'
            require_registered_policy "$repo" "$prior_policy" "$repository" \
                'saved policy did not register this release line'
            require_first_parent "$repo" "$cut" "$revision" 'saved source does not follow the registered cut'
            require_first_parent "$repo" "$revision" "$remote_sha" 'saved branch history was rewritten'
            if [[ "$key" != "$request_key" && "$reused" == false ]]; then
                require_first_parent "$repo" "$revision" "$source_sha" 'request order cannot be proven; a later or unrelated request exists'
            fi
        done < "$proposal_workspace/previous.tsv"
    fi
    version=$(jq -r '.version' "$proposal_workspace/proposal.json")
    source_version_key=$(tuple_key source-version '' '' "$source_sha" "$version")
    jq --arg key "$source_version_key" '.image.source_version_key = $key | .image.source_tag = "src-" + $key' \
        "$proposal_workspace/proposal.json"
}

main "$@"

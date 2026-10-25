#!/usr/bin/env bash
# Durable request coordination. Source branches are never modified.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"
source "${BASH_SOURCE[0]%/*}/candidate-common.sh"

coordinate_workspace=
coordinate_repository=

cleanup_coordinate() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "$coordinate_workspace" ]]; then
        rm -rf -- "$coordinate_workspace"
    fi
    exit "$exit_status"
}

coordinate_git() {
    timeout --signal=TERM --kill-after=5s 120s \
        git --no-replace-objects -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -C "$coordinate_workspace/repo" "$@"
}

coordinate_export() {
    local request=$1 output=$2 sha

    [[ ! -e "$output" ]] || release_fail 'output must be a new directory'
    mkdir -p "$output"
    jq --arg key "$request" '.requests[$key].proposal' "$coordinate_workspace/state.json" > "$output/proposal.json"
    sha=$(release_sha256 "$output/proposal.json")
    jq -n --arg sha "$sha" --slurpfile proposal "$output/proposal.json" \
        '{schema_version: 1, mode: $proposal[0].mode, repository: $proposal[0].repository,
          source_sha: $proposal[0].source_sha, policy_sha: $proposal[0].policy_sha,
          proposal_sha256: $sha, publishable: false}' > "$output/github-evidence.json"
    jq --arg key "$request" '.requests[$key]' "$coordinate_workspace/state.json" > "$output/request.json"
}

coordinate_read() {
    local remote=$1 state_ref=$2 revision

    revision=$(coordinate_git ls-remote --refs "$remote" "$state_ref")
    if [[ -z "$revision" ]]; then
        printf '\n'
        return
    fi
    [[ "$revision" != *$'\n'* ]] || release_fail 'ambiguous state ref'
    revision=${revision%%$'\t'*}
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || release_fail 'invalid remote state identity'
    coordinate_git fetch --quiet --no-tags "$remote" "$state_ref"
    coordinate_git show "$revision:state.json" > "$coordinate_workspace/state.json"
    printf '%s\n' "$revision"
}

coordinate_write() {
    local remote=$1 state_ref=$2 expected=$3 message=$4 tag=${5:-} tag_object=${6:-}
    local blob tree commit actual
    local args=()

    jq -es -L "$RELEASE_ROOT/tools/release" --arg repository "$coordinate_repository" \
        'include "publication"; if length == 1 then .[0] | validate_ledger($repository)
         else error("expected one ledger") end' "$coordinate_workspace/state.json" > /dev/null
    blob=$(coordinate_git hash-object -w "$coordinate_workspace/state.json")
    tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | coordinate_git mktree)
    [[ -z "$expected" ]] || args=(-p "$expected")
    commit=$(coordinate_git -c user.name='Release automation' \
        -c user.email=release@example.invalid commit-tree "$tree" ${args[@]+"${args[@]}"} -m "$message")
    args=(push --quiet --atomic "--force-with-lease=$state_ref:$expected")
    if [[ -n "$tag" ]]; then
        args+=("--force-with-lease=refs/tags/$tag:" "$remote" "$commit:$state_ref" "$tag_object:refs/tags/$tag")
    else args+=("$remote" "$commit:$state_ref"); fi
    # A lost response is reconciled by the exact intended commit, never by
    # blindly repeating a mutation against a newer state snapshot.
    # The wrapper contains one command. Its failure is handled by read-back.
    # shellcheck disable=SC2310
    if coordinate_git "${args[@]}" > "$coordinate_workspace/push.log" 2>&1; then
        :
    else
        actual=$(coordinate_git ls-remote --refs "$remote" "$state_ref")
        [[ "${actual%%$'\t'*}" == "$commit" ]] || {
            cat "$coordinate_workspace/push.log" >&2
            release_fail 'state write conflict or failed push; reload the original request'
        }
    fi
    actual=$(coordinate_git ls-remote --refs "$remote" "$state_ref")
    [[ "${actual%%$'\t'*}" == "$commit" ]] || release_fail 'state read-back differs from intended commit'
    if [[ -n "$tag" ]]; then
        actual=$(coordinate_git ls-remote --refs "$remote" "refs/tags/$tag")
        [[ "${actual%%$'\t'*}" == "$tag_object" ]] || release_fail 'tag read-back differs from intended object'
    fi
    printf '%s\n' "$commit"
}

coordinate_key() {
    local repository=$1 branch=$2 source=$3 encoded

    encoded=$(jq -cn --arg repository "$repository" --arg branch "$branch" --arg source "$source" \
        '[1, "request", $repository, $branch, $source]')
    printf '%s' "$encoded" > "$coordinate_workspace/key"
    release_sha256 "$coordinate_workspace/key"
}

coordinate_release_proposal() {
    local key=$1 development source_key notes_sha original encoded

    original=$(jq -r --arg key "$key" '.requests[$key].policy_sha' "$coordinate_workspace/state.json")
    development=$(coordinate_git show "$source:build.zig.zon" |
        sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p')
    release_validate_version "$development" 'release development version'
    encoded=$(jq -cn --arg source "$source" --arg version "$version" '[1,"source-version",$source,$version]')
    source_key=$(printf '%s' "$encoded" | release_sha256 /dev/stdin)
    jq -n -L "$RELEASE_ROOT/tools/release" --arg key "$key" --arg policy "$original" \
        --arg development "$development" --arg source_key "$source_key" \
        --slurpfile ledger "$coordinate_workspace/state.json" \
        'include "release-pr"; release_proposal($ledger[0].requests[$key].event;
          $policy; $development; $key; $source_key)' > "$coordinate_workspace/proposal.json"
    jq -j '.release_notes.body' "$coordinate_workspace/proposal.json" > "$coordinate_workspace/release-notes"
    notes_sha=$(release_sha256 "$coordinate_workspace/release-notes")
    jq --arg sha "$notes_sha" '.release_notes.sha256 = $sha' \
        "$coordinate_workspace/proposal.json" > "$coordinate_workspace/proposal.next.json"
    mv "$coordinate_workspace/proposal.next.json" "$coordinate_workspace/proposal.json"
    candidate_validate_proposal "$coordinate_workspace/proposal.json"
}

main() {
    local operation=${1:-} remote='' state_ref=refs/heads/release-state fixture=false
    local repository='' event='' event_name='' source='' output='' request='' candidate='' failure='' artifact='' checkpoint_file='' transfer=''
    local expected key branch line policy status version tag object candidate_sha now before earlier
    local fixture_path selected release_request=false

    [[ $# -gt 0 ]] || release_fail 'expected init, enqueue, allocate, qualify, tag, or status'
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote | --repository | --event | --event-name | --source | --output | --request | --candidate | --failure | --artifact-id | --checkpoint | --transfer)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --remote) remote=$2 ;;
                    --repository) repository=$2 ;;
                    --event) event=$2 ;;
                    --event-name) event_name=$2 ;;
                    --source) source=$2 ;;
                    --output) output=$2 ;;
                    --request) request=$2 ;;
                    --candidate) candidate=$2 ;;
                    --failure) failure=$2 ;;
                    --artifact-id) artifact=$2 ;;
                    --checkpoint) checkpoint_file=$2 ;;
                    --transfer) transfer=$2 ;;
                esac
                shift 2
                ;;
            --fixture)
                fixture=true
                shift
                ;;
            *) release_fail "unknown coordinate argument: $1" ;;
        esac
    done
    release_require_commands git jq timeout mktemp date
    release_require_sha256
    [[ -n "$remote" && "$repository" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] ||
        release_fail 'remote and lowercase repository are required'
    case "$operation" in init | enqueue | allocate | qualify | tag | status | fail | checkpoint) ;;
    *) release_fail 'unsupported coordinate operation' ;;
    esac
    if [[ "$fixture" == true ]]; then
        [[ "$repository" == fixture/* && -d "$remote" ]] ||
            release_fail 'fixture writes require an existing local bare repository and fixture/ identity'
        fixture_path=$(cd "$remote" && pwd -P)
        selected=$(git -C "$fixture_path" rev-parse --is-bare-repository)
        [[ "$selected" == true ]] ||
            release_fail 'fixture destination must be bare'
        remote=$fixture_path
    else
        [[ "$remote" == "https://github.com/$repository.git" ]] || release_fail 'production remote must match repository'
        branch=$(release_workflow_branch "$repository")
    fi
    trap cleanup_coordinate EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    coordinate_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-coordinate.XXXXXX")
    if [[ "$fixture" == false ]]; then
        # Keep credentials in the step environment. Git config, remote URLs,
        # retained records, and the helper file contain no token bytes.
        # Expansion belongs to the later askpass process, not this writer.
        # shellcheck disable=SC2016
        printf '%s\n' '#!/usr/bin/env bash' \
            'case "$1" in *Username*) printf "x-access-token\n" ;; *) printf "%s\n" "${GH_TOKEN:?}" ;; esac' \
            > "$coordinate_workspace/askpass"
        chmod 700 "$coordinate_workspace/askpass"
        export GIT_ASKPASS="$coordinate_workspace/askpass" GIT_TERMINAL_PROMPT=0
    fi
    git -c core.hooksPath=/dev/null clone --quiet --no-hardlinks --no-checkout -- "$remote" "$coordinate_workspace/repo"
    coordinate_repository=$repository
    policy=$(coordinate_git rev-parse 'refs/remotes/origin/main^{commit}')
    if [[ "$fixture" == false ]]; then
        coordinate_git show "$policy:.github/release-automation.json" > "$coordinate_workspace/config.json"
        jq -e -L "$RELEASE_ROOT/tools/release" --arg repository "$repository" \
            'include "publication"; validate_automation($repository) | .enabled == true' \
            "$coordinate_workspace/config.json" > /dev/null ||
            release_fail 'production release automation is not activated'
        bash "$RELEASE_ROOT/tools/release/github.sh" --repo "$coordinate_workspace/repo" \
            --repository "$repository" --check-rules "$branch" --output "$coordinate_workspace/rules"
    fi
    expected=$(coordinate_read "$remote" "$state_ref")
    if [[ "$operation" == init ]]; then
        [[ -z "$expected" ]] || release_fail 'durable state already exists; do not replace it'
        jq -n --arg repository "$repository" \
            '{schema_version: 1, repository: $repository, lines: {}, requests: {}, aliases: {}}' \
            > "$coordinate_workspace/state.json"
        coordinate_write "$remote" "$state_ref" '' 'chore(release): initialize durable state'
        return
    fi
    if [[ -z "$expected" && "$operation" == enqueue &&
        ("$event_name" == pull_request || "$event_name" == workflow_dispatch || "$event_name" == repository_dispatch) ]]; then
        jq -n --arg repository "$repository" \
            '{schema_version:1,repository:$repository,lines:{},requests:{},aliases:{}}' \
            > "$coordinate_workspace/state.json"
    elif [[ -z "$expected" ]]; then
        release_fail 'missing durable state; explicit initialization is required'
    fi
    if [[ "$fixture" == false && -n "$expected" ]] &&
        jq -e '.state_root_sha != null' "$coordinate_workspace/config.json" > /dev/null; then
        selected=$(coordinate_git rev-list --max-parents=0 "$expected")
        jq -e --arg root "$selected" '.state_root_sha == $root and
            (.state_root_sha | test("^[0-9a-f]{40}$"))' "$coordinate_workspace/config.json" > /dev/null ||
            release_fail 'pin the reviewed state root in main policy before admitting requests'
    fi
    jq -e -L "$RELEASE_ROOT/tools/release" --arg repository "$repository" \
        'include "publication"; validate_ledger($repository)' "$coordinate_workspace/state.json" > /dev/null
    if [[ "$operation" == status ]]; then
        cat "$coordinate_workspace/state.json"
        return
    fi
    if [[ "$operation" == enqueue ]]; then
        [[ -f "$event" && "$source" =~ ^[0-9a-f]{40}$ && -n "$event_name" ]] ||
            release_fail 'enqueue requires event, event-name, and exact source'
        bash "$RELEASE_ROOT/tools/release/github.sh" --repo "$coordinate_workspace/repo" \
            --repository "$repository" --event "$event" --event-name "$event_name" \
            --source-sha "$source" --ledger "$coordinate_workspace/state.json" \
            --output "$coordinate_workspace/selection"
        selected="$coordinate_workspace/selection"
        branch=$(jq -r '.branch' "$selected/event.json")
        line=${branch#release/}
        key=$(coordinate_key "$repository" "$branch" "$source")
        if [[ "$fixture" == false ]]; then
            [[ "$event_name" == "$GITHUB_EVENT_NAME" ]] || release_fail 'request differs from authenticated workflow event'
            release_require_workflow_source "$repository" "$branch" "$source"
        fi
        if jq -e --arg key "$key" '.requests[$key] != null' "$coordinate_workspace/state.json" > /dev/null; then
            jq --arg key "$key" '.requests[$key]' "$coordinate_workspace/state.json"
            return
        fi
        jq -e '[.requests[] | select(.status != "complete" and .status != "superseded")] | length < 100' \
            "$coordinate_workspace/state.json" > /dev/null || release_fail 'durable request queue is full'
        if jq -e '.kind == "release"' "$selected/event.json" > /dev/null; then
            jq -L "$RELEASE_ROOT/tools/release" --slurpfile ledger "$coordinate_workspace/state.json" \
                'include "release-pr"; .version = release_request_version($ledger[0])' \
                "$selected/event.json" > "$coordinate_workspace/release-event.json"
            mv "$coordinate_workspace/release-event.json" "$selected/event.json"
            version=$(jq -r '.version' "$selected/event.json")
            jq -e --arg version "$version" 'all(.requests[]; .version != $version)' \
                "$coordinate_workspace/state.json" > /dev/null ||
                release_fail 'version already belongs to another release request; use a new version branch'
            selected=$(cat "$selected/rules-sha256")
            jq --arg key "$key" --arg policy "$policy" --arg fingerprint "$selected" \
                --slurpfile event "$coordinate_workspace/selection/event.json" \
                '.requests[$key] = {request_key:$key, source_sha:$event[0].source_sha,
                  branch:$event[0].branch, version:$event[0].version, policy_sha:$policy,
                  event:$event[0], enforcement_sha256:$fingerprint, status:"queued"}' \
                "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
            selected="$coordinate_workspace/selection"
        else
            jq --arg key "$key" --arg line "$line" --arg policy "$policy" \
                --slurpfile event "$selected/event.json" --slurpfile record "$selected/line-record.json" \
                '.lines[$line] = $record[0] |
                 .requests[$key] = {request_key: $key, source_sha: $event[0].source_sha,
                   branch: $event[0].branch, policy_sha: $policy, event: $event[0], status: "queued"}' \
                "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
        fi
        mv "$coordinate_workspace/next.json" "$coordinate_workspace/state.json"
        coordinate_write "$remote" "$state_ref" "$expected" 'chore(release): enqueue source' >&2
        if [[ -n "$output" ]]; then
            [[ ! -e "$output" ]] || release_fail 'output must be a new directory'
            cp -R "$selected" "$output"
        fi
        jq --arg key "$key" '.requests[$key]' "$coordinate_workspace/state.json"
        return
    fi
    [[ "$request" =~ ^[0-9a-f]{64}$ ]] || release_fail 'a full request key is required'
    jq -e --arg key "$request" '.requests[$key] != null' "$coordinate_workspace/state.json" > /dev/null ||
        release_fail 'unknown durable request; do not allocate a replacement'
    branch=$(jq -r --arg key "$request" '.requests[$key].branch' "$coordinate_workspace/state.json")
    source=$(jq -r --arg key "$request" '.requests[$key].source_sha' "$coordinate_workspace/state.json")
    if [[ "$fixture" == false ]]; then
        release_require_workflow_source "$repository" "$branch" "$source"
        jq -e --arg key "$request" --arg run "${GITHUB_RUN_ID:-}" \
            '(.requests[$key].event.trigger | IN("workflow_dispatch", "repository_dispatch") | not) or .requests[$key].event.run_id == $run' \
            "$coordinate_workspace/state.json" > /dev/null || release_fail 'retry the original manual publication workflow'
    fi
    line=${branch#release/}
    status=$(jq -r --arg key "$request" '.requests[$key].status' "$coordinate_workspace/state.json")
    [[ "$status" != superseded ]] || release_fail 'request was superseded; use the accepted descendant'
    if jq -e --arg key "$request" '.requests[$key].event.kind == "release"' \
        "$coordinate_workspace/state.json" > /dev/null; then
        release_request=true
        version=$(jq -r --arg key "$request" '.requests[$key].version' "$coordinate_workspace/state.json")
        coordinate_git show "$policy:.github/release-automation.json" > "$coordinate_workspace/config.json"
        jq -e --arg version "$version" '(.blocked_versions // [] | index($version)) == null' \
            "$coordinate_workspace/config.json" > /dev/null || release_fail 'version was blocked'
    else
        coordinate_git show "$policy:.github/release-lines.json" > "$coordinate_workspace/policy.json"
        jq -e -L "$RELEASE_ROOT/tools/release" --arg repository "$repository" \
            --arg line "$line" 'include "policy"; validate_policy($repository) |
            any(.lines[]; .line == $line and .status != "retired")' \
            "$coordinate_workspace/policy.json" > /dev/null || release_fail 'line is not currently authorized'
    fi
    if [[ "$operation" == checkpoint ]]; then
        version=$(jq -r --arg key "$request" '.requests[$key].version' "$coordinate_workspace/state.json")
        [[ "$release_request" == true ]] || jq -e --arg line "$line" --arg version "$version" \
            'any(.lines[]; .line == $line and (.blocked_versions | index($version)) == null)' \
            "$coordinate_workspace/policy.json" > /dev/null || release_fail 'version was blocked'
        tag="v$version"
        object=$(coordinate_git ls-remote --refs "$remote" "refs/tags/$tag")
        jq -e --arg key "$request" --arg object "${object%%$'\t'*}" \
            '.requests[$key].tag_object_sha == $object' "$coordinate_workspace/state.json" > /dev/null ||
            release_fail 'reserved tag is missing or changed'
        [[ -f "$checkpoint_file" && ! -L "$checkpoint_file" ]] || release_fail 'checkpoint file is required'
        candidate_sha=$(candidate_file_size "$checkpoint_file")
        [[ "$candidate_sha" -le 1048576 ]] || release_fail 'checkpoint exceeds 1 MiB'
        jq -e -L "$RELEASE_ROOT/tools/release" --arg key "$request" --argjson fixture "$fixture" \
            --slurpfile change "$checkpoint_file" \
            'include "policy"; include "publication"; require($fixture or $change[0].phase != "verified" or
               ($change[0].value.native_amd64 == true and $change[0].value.synthetic == false);
               "production requires native registry verification") |
             checkpoint($key; $change[0].phase; $change[0].value)' \
            "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
    elif [[ "$operation" == allocate ]]; then
        if [[ "$status" != queued && "$status" != failed ]]; then
            [[ -z "$output" ]] || coordinate_export "$request" "$output"
            jq --arg key "$request" '.requests[$key]' "$coordinate_workspace/state.json"
            return
        fi
        coordinate_git rev-list --reverse --first-parent "$source" > "$coordinate_workspace/ancestors"
        while IFS= read -r before; do
            [[ "$before" != "$source" ]] || break
            earlier=$(jq -r --arg branch "$branch" --arg source "$before" \
                '.requests[] | select(.branch == $branch and .source_sha == $source) |
                 if .status == "complete" or .status == "superseded" or
                    (.status == "failed" and .tag_object_sha == null) then empty else .request_key end' \
                "$coordinate_workspace/state.json")
            [[ -z "$earlier" ]] || release_fail 'an earlier source is unresolved; retry its original request'
        done < "$coordinate_workspace/ancestors"
        if [[ "$release_request" == true ]]; then
            tag=$(coordinate_git ls-remote --refs "$remote" "refs/tags/v$version")
            [[ -z "$tag" ]] || release_fail 'version tag already exists outside this request'
            coordinate_release_proposal "$request"
        else
            jq -n -L "$RELEASE_ROOT/tools/release" --arg line "$line" \
                --slurpfile ledger "$coordinate_workspace/state.json" \
                'include "publication"; proposer_state($ledger[0]; $line)' > "$coordinate_workspace/proposer-state.json"
            jq --arg key "$request" '.requests[$key].event' "$coordinate_workspace/state.json" > "$coordinate_workspace/event.json"
            bash "$RELEASE_ROOT/tools/release/propose.sh" --repo "$coordinate_workspace/repo" \
                --repository "$repository" --event "$coordinate_workspace/event.json" \
                --state "$coordinate_workspace/proposer-state.json" > "$coordinate_workspace/proposal.json"
        fi
        jq --arg key "$request" --slurpfile proposal "$coordinate_workspace/proposal.json" \
            'reduce $proposal[0].supersedes[] as $old (.; .requests[$old].status = "superseded") |
             .requests[$key] += {status: "admitted", version: $proposal[0].version,
               policy_sha: $proposal[0].original_policy_sha, proposal: $proposal[0]}' \
            "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
    elif [[ "$operation" == fail ]]; then
        [[ "$status" == admitted && -f "$failure" && ! -L "$failure" ]] ||
            release_fail 'only an untagged admitted request can record qualification failure'
        candidate_sha=$(candidate_file_size "$failure")
        [[ "$candidate_sha" -le 1048576 ]] || release_fail 'failure evidence exceeds 1 MiB'
        candidate_sha=$(release_sha256 "$failure")
        jq --arg key "$request" --arg sha "$candidate_sha" \
            '.requests[$key] += {status: "failed", failure_sha256: $sha}' \
            "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
    elif [[ "$operation" == qualify ]]; then
        [[ "$status" == admitted || "$status" == qualified ]] || release_fail 'request is not awaiting qualification'
        [[ -n "$candidate" ]] || release_fail 'provide the retained candidate directory'
        candidate_snapshot_bundle "$candidate" "$coordinate_workspace/candidate"
        candidate_check_archive "$coordinate_workspace/candidate" "$coordinate_workspace/archive"
        jq -e --arg key "$request" --argjson fixture "$fixture" \
            --slurpfile ledger "$coordinate_workspace/state.json" \
            '(.mode == "branch" or .mode == "release") and .proposal == $ledger[0].requests[$key].proposal and
             ($fixture or (.qualification.qualified_amd64 == true and .tooling.dirty == false))' \
            "$coordinate_workspace/candidate/candidate.json" > /dev/null ||
            release_fail 'candidate does not qualify this admitted branch request'
        candidate_sha=$(release_sha256 "$coordinate_workspace/candidate/candidate.json")
        if [[ "$fixture" == false ]]; then
            [[ -f "$transfer" && ! -L "$transfer" ]] || release_fail 'native transfer evidence is required'
            selected=$(candidate_file_size "$transfer")
            [[ "$selected" -le 1048576 ]] || release_fail 'transfer evidence exceeds 1 MiB'
            jq -e --arg sha "$candidate_sha" --slurpfile candidate "$coordinate_workspace/candidate/candidate.json" \
                '.passed == true and .rebuilt == false and .native_import == true and
                  .candidate_qualified_amd64 == true and .candidate_sha256 == $sha and
                  .image_id == $candidate[0].image.id and .source_sha == $candidate[0].source_sha and
                  .version == $candidate[0].version' "$transfer" > /dev/null ||
                release_fail 'native transfer evidence does not verify this retained candidate'
        fi
        [[ "$fixture" == true || "$artifact" =~ ^[1-9][0-9]*$ ]] ||
            release_fail 'qualification must identify the retained Actions artifact'
        if [[ "$status" == qualified ]]; then
            jq -e --arg key "$request" --arg sha "$candidate_sha" \
                '.requests[$key].candidate_sha256 == $sha' "$coordinate_workspace/state.json" > /dev/null ||
                release_fail 'a different candidate already owns this request; restore the retained bytes'
            jq --arg key "$request" '.requests[$key]' "$coordinate_workspace/state.json"
            return
        fi
        jq --arg key "$request" --arg sha "$candidate_sha" --arg artifact "$artifact" \
            --slurpfile candidate "$coordinate_workspace/candidate/candidate.json" \
            '.requests[$key] += {status: "qualified", candidate_sha256: $sha,
               candidate: {image_id: $candidate[0].image.id, archive_sha256: $candidate[0].archive.sha256,
                 run: $candidate[0].run, artifact_id: $artifact}}' "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
    elif [[ "$operation" == tag ]]; then
        [[ -n "$candidate" ]] || release_fail 'tagging requires the retained candidate bytes'
        candidate_sha=$(jq -r --arg key "$request" '.requests[$key].candidate_sha256' "$coordinate_workspace/state.json")
        candidate_snapshot_bundle "$candidate" "$coordinate_workspace/candidate" "$candidate_sha"
        candidate_check_archive "$coordinate_workspace/candidate" "$coordinate_workspace/archive"
        if [[ "$fixture" == false ]]; then
            artifact=$(jq -r --arg key "$request" '.requests[$key].candidate.artifact_id' "$coordinate_workspace/state.json")
            timeout 65s curl --fail --silent --show-error --max-time 45 --connect-timeout 10 \
                --proto '=https' --header "Authorization: Bearer ${GH_TOKEN:?}" \
                --output "$coordinate_workspace/artifact.json" \
                "https://api.github.com/repos/$repository/actions/artifacts/$artifact"
            jq -e -L "$RELEASE_ROOT/tools/release" --arg id "$artifact" \
                --slurpfile candidate "$coordinate_workspace/candidate/candidate.json" \
                --slurpfile request "$coordinate_workspace/state.json" --arg key "$request" \
                'include "candidate"; candidate_artifact_matches($candidate[0]; $request[0].requests[$key].event; $id)' \
                "$coordinate_workspace/artifact.json" > /dev/null ||
                release_fail 'retained artifact is missing, expired, or belongs to another source'
        fi
        # Re-run current policy and reservation checks before a tag mutation.
        if [[ "$release_request" == false ]]; then
            jq -n -L "$RELEASE_ROOT/tools/release" --arg line "$line" \
                --slurpfile ledger "$coordinate_workspace/state.json" \
                'include "publication"; proposer_state($ledger[0]; $line)' > "$coordinate_workspace/proposer-state.json"
            jq --arg key "$request" '.requests[$key].event' "$coordinate_workspace/state.json" > "$coordinate_workspace/event.json"
            bash "$RELEASE_ROOT/tools/release/propose.sh" --repo "$coordinate_workspace/repo" \
                --repository "$repository" --event "$coordinate_workspace/event.json" \
                --state "$coordinate_workspace/proposer-state.json" > "$coordinate_workspace/current-proposal.json"
        fi
        if [[ "$status" != qualified ]]; then
            jq -e --arg key "$request" '.requests[$key].tag_object_sha != null' \
                "$coordinate_workspace/state.json" > /dev/null || release_fail 'request has no qualified candidate'
            tag=$(jq -r --arg key "$request" '.requests[$key].proposal.intended_tag' "$coordinate_workspace/state.json")
            object=$(coordinate_git ls-remote --refs "$remote" "refs/tags/$tag")
            jq -e --arg key "$request" --arg object "${object%%$'\t'*}" \
                '.requests[$key].tag_object_sha == $object' "$coordinate_workspace/state.json" > /dev/null ||
                release_fail 'reserved tag is missing or changed'
            jq --arg key "$request" '.requests[$key]' "$coordinate_workspace/state.json"
            return
        fi
        version=$(jq -r --arg key "$request" '.requests[$key].version' "$coordinate_workspace/state.json")
        tag="v$version"
        [[ "$release_request" == true ]] || jq -e --arg line "$line" --arg version "$version" \
            'any(.lines[]; .line == $line and (.blocked_versions | index($version)) == null)' \
            "$coordinate_workspace/policy.json" > /dev/null || release_fail 'version was blocked'
        jq -cn --arg key "$request" --slurpfile ledger "$coordinate_workspace/state.json" \
            '{schema_version: 1, request_key: $key, source_sha: $ledger[0].requests[$key].source_sha,
              version: $ledger[0].requests[$key].version,
              policy_sha: $ledger[0].requests[$key].policy_sha,
              candidate_sha256: $ledger[0].requests[$key].candidate_sha256}' > "$coordinate_workspace/annotation.json"
        now=$(jq -r --arg key "$request" '.requests[$key].tag_intent.epoch // empty' "$coordinate_workspace/state.json")
        [[ -n "$now" ]] || now=$(date +%s)
        {
            printf 'object %s\ntype commit\ntag %s\n' "$source" "$tag"
            printf 'tagger Release automation <release@example.invalid> %s +0000\n\n' "$now"
            cat "$coordinate_workspace/annotation.json"
        } > "$coordinate_workspace/tag-object"
        object=$(coordinate_git mktag < "$coordinate_workspace/tag-object")
        selected=$(coordinate_git rev-parse "$object^{commit}")
        [[ "$selected" == "$source" ]] || release_fail 'tag source differs'
        if jq -e --arg key "$request" '.requests[$key].tag_intent != null' "$coordinate_workspace/state.json" > /dev/null; then
            jq -e --arg key "$request" --arg object "$object" \
                '.requests[$key].tag_intent.object_sha == $object' "$coordinate_workspace/state.json" > /dev/null ||
                release_fail 'reconstructed tag differs from recorded intent'
        else
            jq --arg key "$request" --arg object "$object" --arg epoch "$now" \
                '.requests[$key].tag_intent = {object_sha: $object, epoch: $epoch}' \
                "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
            mv "$coordinate_workspace/next.json" "$coordinate_workspace/state.json"
            expected=$(coordinate_write "$remote" "$state_ref" "$expected" 'chore(release): record tag intent')
        fi
        jq --arg key "$request" --arg object "$object" \
            '.requests[$key] += {status: "tagged", tag_object_sha: $object}' \
            "$coordinate_workspace/state.json" > "$coordinate_workspace/next.json"
        mv "$coordinate_workspace/next.json" "$coordinate_workspace/state.json"
        coordinate_write "$remote" "$state_ref" "$expected" 'chore(release): reserve qualified tag' "$tag" "$object" >&2
        jq --arg key "$request" '.requests[$key]' "$coordinate_workspace/state.json"
        return
    fi
    if jq -e --slurpfile next "$coordinate_workspace/next.json" '. == $next[0]' \
        "$coordinate_workspace/state.json" > /dev/null; then
        jq --arg key "$request" '.requests[$key]' "$coordinate_workspace/state.json"
        return
    fi
    mv "$coordinate_workspace/next.json" "$coordinate_workspace/state.json"
    coordinate_write "$remote" "$state_ref" "$expected" "chore(release): $operation request" >&2
    if [[ "$operation" == allocate && -n "$output" ]]; then
        coordinate_export "$request" "$output"
    fi
    jq --arg key "$request" '.requests[$key]' "$coordinate_workspace/state.json"
}

main "$@"

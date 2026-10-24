#!/usr/bin/env bash
# Collect read-only GitHub evidence and bind it to a source/version proposal.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"

github_workspace=
github_output=
github_repository=
github_api_count=0
github_api_bytes=0

cleanup_github() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "$github_workspace" ]]; then
        rm -rf -- "$github_workspace"
    fi
    exit "$exit_status"
}

# Only GET requests to this fixed service are supported. The token is scoped
# to this collector step and never passed to source builds or client tests.
github_get() {
    local path=$1 destination=$2 raw sha bytes

    github_api_count=$((github_api_count + 1))
    [[ "$github_api_count" -le 500 ]] || release_fail 'GitHub evidence request limit exceeded'
    [[ "$path" == "/repos/$github_repository/"* && "$path" != *$'\n'* ]] ||
        release_fail 'unexpected GitHub API path'
    raw="$github_output/api/response-$github_api_count.json"
    timeout --signal=TERM --kill-after=5s 65s curl \
        --fail --silent --show-error --max-time 45 --connect-timeout 10 \
        --retry 2 --retry-max-time 50 --max-filesize 2097152 \
        --proto '=https' --tlsv1.2 \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --header "Authorization: Bearer ${GH_TOKEN:?a read-only GH_TOKEN is required}" \
        --dump-header "$github_workspace/headers" \
        --output "$raw" "https://api.github.com$path"
    bytes=$(wc -c < "$raw")
    github_api_bytes=$((github_api_bytes + bytes))
    [[ "$github_api_bytes" -le 16777216 ]] || release_fail 'raw GitHub evidence exceeds 16 MiB'
    cp "$raw" "$destination"
    jq -e 'type == "object" or type == "array"' "$destination" > /dev/null
    sha=$(release_sha256 "$raw")
    jq -cn --arg path "$path" --arg file "api/${raw##*/}" --arg sha "$sha" \
        '{path: $path, file: $file, sha256: $sha}' >> "$github_output/api-inventory.jsonl"
}

github_list() {
    local path=$1 destination=$2 next="$1" page=0 cursor suffix

    : > "$github_workspace/pages.jsonl"
    while [[ -n "$next" ]]; do
        page=$((page + 1))
        [[ "$page" -le 20 ]] || release_fail 'GitHub evidence pagination limit exceeded'
        github_get "$next" "$github_output/api/list-$github_api_count.json"
        jq -ce 'if type == "array" then . else error("expected a list") end' \
            "$github_output/api/list-$((github_api_count - 1)).json" >> "$github_workspace/pages.jsonl"
        next=
        # Follow only the next cursor on the same API path. Never follow a
        # response URL to another service or forward credentials to it.
        cursor=$(sed -nE 's/^[Ll]ink:.*<([^>]+)>; rel="next".*/\1/p' "$github_workspace/headers" | tr -d '\r')
        if [[ -n "$cursor" ]]; then
            suffix=${path%%\?*}
            [[ "$cursor" == "https://api.github.com$suffix?"* ]] ||
                release_fail 'unexpected GitHub pagination URL'
            next=${cursor#https://api.github.com}
        fi
    done
    jq -s 'add // []' "$github_workspace/pages.jsonl" > "$destination"
}

github_permission() {
    local login=$1

    [[ "$login" =~ ^[A-Za-z0-9-]+$ ]] || release_fail 'invalid GitHub login'
    github_get "/repos/$github_repository/collaborators/$login/permission" \
        "$github_output/api/permission-$login.json"
    jq '.permission == "admin" or .permission == "maintain" or .permission == "write"' \
        "$github_output/api/permission-$login.json" > "$github_workspace/can-write"
}

github_reviewed_pr() {
    local number=$1 branch=$2 revision=$3 login permission approvers=0

    [[ "$number" =~ ^[1-9][0-9]*$ ]] || release_fail 'invalid PR number'
    github_get "/repos/$github_repository/pulls/$number" "$github_output/api/pr-$number.json"
    jq -e -L "$RELEASE_ROOT/tools/release" \
        --arg repository "$github_repository" --arg branch "$branch" --arg source "$revision" \
        'include "github"; merged_pr($repository; $branch; $source)' \
        "$github_output/api/pr-$number.json" > /dev/null
    login=$(jq -r '.merged_by.login' "$github_output/api/pr-$number.json")
    github_permission "$login"
    permission=$(cat "$github_workspace/can-write")
    if [[ "$permission" != true ]]; then
        release_fail 'PR merger needs current maintainer write access'
    fi
    github_list "/repos/$github_repository/pulls/$number/reviews?per_page=100" \
        "$github_output/api/reviews-$number.json"
    jq -L "$RELEASE_ROOT/tools/release" --slurpfile pr "$github_output/api/pr-$number.json" \
        'include "github"; review_decisions($pr[0])' "$github_output/api/reviews-$number.json" \
        > "$github_workspace/decisions.json"
    jq -r '.changes[].user.login' "$github_workspace/decisions.json" > "$github_workspace/changes"
    while IFS= read -r login; do
        github_permission "$login"
        permission=$(cat "$github_workspace/can-write")
        if [[ "$permission" == true ]]; then
            release_fail 'PR has an unresolved maintainer change request'
        fi
    done < "$github_workspace/changes"
    jq -r '.approvals[].user.login' "$github_workspace/decisions.json" > "$github_workspace/approvals"
    while IFS= read -r login; do
        github_permission "$login"
        permission=$(cat "$github_workspace/can-write")
        if [[ "$permission" == true ]]; then
            approvers=$((approvers + 1))
        fi
    done < "$github_workspace/approvals"
    [[ "$approvers" -gt 0 ]] || release_fail 'PR needs a maintainer approval of its final head'
}

github_commit_pr() {
    local revision=$1 branch=$2 enforced=${3:-false} number

    github_list "/repos/$github_repository/commits/$revision/pulls?per_page=100" \
        "$github_output/api/associated-$revision.json"
    number=$(jq -er --arg source "$revision" --arg branch "$branch" --arg repository "$github_repository" \
        '[.[] | select(.merge_commit_sha == $source and .base.ref == $branch and
          (.base.repo.full_name | ascii_downcase) == $repository)] | unique_by(.number) |
          if length == 1 then .[0].number else error("missing or ambiguous merged PR") end' \
        "$github_output/api/associated-$revision.json")
    if [[ "$enforced" == true ]]; then
        github_get "/repos/$github_repository/pulls/$number" "$github_output/api/pr-$number.json"
        jq -e -L "$RELEASE_ROOT/tools/release" \
            --arg repository "$github_repository" --arg branch "$branch" --arg source "$revision" \
            'include "github"; merged_pr($repository; $branch; $source)' \
            "$github_output/api/pr-$number.json" > /dev/null
    else
        github_reviewed_pr "$number" "$branch" "$revision"
    fi
    cp "$github_output/api/pr-$number.json" "$github_workspace/selected-pr.json"
}

github_activities() {
    local branch=$1 destination=$2 encoded

    encoded=$(jq -rn --arg ref "refs/heads/$branch" '$ref | @uri')
    github_list "/repos/$github_repository/activity?ref=$encoded&time_period=year&per_page=100" "$destination"
    jq -e --arg ref "refs/heads/$branch" 'type == "array" and
        all(.[]; .ref == $ref and (.node_id | type == "string") and
          (.timestamp | type == "string") and (.after | test("^[0-9a-f]{40}$"))) and
        (unique_by(.node_id) | length) == length' "$destination" > /dev/null ||
        release_fail 'invalid repository activity response'
}

# The durable path checks current enforcement and collects only the new PR.
# Earlier approvals stay in the protected ledger. They are not fetched again.
github_rules() {
    local repo=$1 branch=$2 policy encoded name id

    policy=$(git --no-replace-objects -C "$repo" rev-parse refs/remotes/origin/main)
    git --no-replace-objects -C "$repo" show "$policy:.github/release-automation.json" \
        > "$github_workspace/automation.json"
    jq -e -L "$RELEASE_ROOT/tools/release" --arg repository "$github_repository" \
        'include "publication"; validate_automation($repository) | .enabled == true' \
        "$github_workspace/automation.json" > /dev/null || release_fail 'release automation is inactive'
    for name in main "$branch" release-state; do
        encoded=$(jq -rn --arg branch "$name" '$branch | @uri')
        github_list "/repos/$github_repository/rules/branches/$encoded?per_page=100" \
            "$github_workspace/effective.json"
        jq -r '[.[].ruleset_id] | unique[]' "$github_workspace/effective.json" \
            > "$github_workspace/ruleset-ids"
        : > "$github_workspace/rulesets.jsonl"
        while IFS= read -r id; do
            [[ "$id" =~ ^[1-9][0-9]*$ ]] || release_fail 'invalid covering ruleset ID'
            github_get "/repos/$github_repository/rulesets/$id" "$github_workspace/ruleset.json"
            jq -c '{id, target, enforcement, bypass_actors}' "$github_workspace/ruleset.json" \
                >> "$github_workspace/rulesets.jsonl"
        done < "$github_workspace/ruleset-ids"
        jq -s --slurpfile effective "$github_workspace/effective.json" \
            '{effective: ($effective[0] | sort_by(.ruleset_id, .type)), rulesets: sort_by(.id)}' \
            "$github_workspace/rulesets.jsonl" > "$github_workspace/rules.json"
        if [[ "$name" == release-state ]]; then
            jq -e -L "$RELEASE_ROOT/tools/release" --slurpfile config "$github_workspace/automation.json" \
                'include "publication"; validate_state_rules($config[0].publisher_app_id)' \
                "$github_workspace/rules.json" > /dev/null
        else
            jq -e -L "$RELEASE_ROOT/tools/release" --arg branch "$name" \
                --slurpfile config "$github_workspace/automation.json" \
                'include "publication"; validate_merge_rules($config[0].required_checks.main +
                  (if $branch == "main" then [] else $config[0].required_checks.release end))' \
                "$github_workspace/rules.json" > /dev/null
        fi
        cp "$github_workspace/rules.json" "$github_workspace/rules-${name//\//-}.json"
    done
    id=$(jq -r '.tag_ruleset_id' "$github_workspace/automation.json")
    github_get "/repos/$github_repository/rulesets/$id" "$github_workspace/tag-rules.json"
    jq -e -L "$RELEASE_ROOT/tools/release" --slurpfile config "$github_workspace/automation.json" \
        'include "publication"; validate_tag_rules($config[0].publisher_app_id)' \
        "$github_workspace/tag-rules.json" > /dev/null
    jq -Scn --slurpfile main "$github_workspace/rules-main.json" \
        --slurpfile branch "$github_workspace/rules-${branch//\//-}.json" \
        --slurpfile state "$github_workspace/rules-release-state.json" \
        --slurpfile tags "$github_workspace/tag-rules.json" \
        '{main: $main[0], branch: $branch[0], state: $state[0],
          tags: ($tags[0] | {id, target, enforcement, conditions, rules, bypass_actors})}' > "$github_output/rules-proof.json"
    release_sha256 "$github_output/rules-proof.json" > "$github_output/rules-sha256"
}

github_select_durable() {
    local repo=$1 event=$2 name=$3 source=$4 ledger=$5 branch line fingerprint last number
    local main_sha parents kind policy

    jq -e -L "$RELEASE_ROOT/tools/release" --arg repository "$github_repository" \
        'include "publication"; validate_ledger($repository)' "$ledger" > /dev/null
    jq -e -L "$RELEASE_ROOT/tools/release" --arg name "$name" \
        --arg repository "$github_repository" --arg source "$source" \
        'include "github"; workflow_event($name; $repository; $source)' "$event" \
        > "$github_workspace/durable-event.json"
    branch=$(jq -r '.branch' "$github_workspace/durable-event.json")
    line=${branch#release/}
    github_rules "$repo" "$branch"
    fingerprint=$(cat "$github_output/rules-sha256")
    jq --arg line "$line" '.lines[$line] // null' "$ledger" > "$github_output/line-record.json"
    if jq -e '. == null' "$github_output/line-record.json" > /dev/null; then
        kind=$(jq -r '.kind' "$github_workspace/durable-event.json")
        [[ "$kind" == create ]] ||
            release_fail 'missing original durable creation; do not import old history automatically'
        # Capture and verify the original server creation once. The legacy
        # read-only collector remains available for non-publishing previews.
        github_select_branch "$repo" "$event" "$name" "$source"
        jq -e --slurpfile config "$github_workspace/automation.json" \
            '.timestamp >= $config[0].enforcement_since' \
            "$github_workspace/creation-activity.json" > /dev/null ||
            release_fail 'branch predates enforced admission; reviewed activation is required'
        jq -n --arg branch "$branch" --arg source "$source" --arg fingerprint "$fingerprint" \
            --slurpfile state "$github_output/state.json" \
            '{branch: $branch, cut_sha: $source, last_source_sha: $source,
              enforcement_sha256: $fingerprint, creation: $state[0].creation, updates: []}' \
            > "$github_output/line-record.json"
    else
        jq -e --arg fingerprint "$fingerprint" '.enforcement_sha256 == $fingerprint' \
            "$github_output/line-record.json" > /dev/null ||
            release_fail 'admission rules changed; review and reconcile the enforcement baseline'
        if jq -e --arg branch "$branch" --arg source "$source" \
            'any(.requests[]; .branch == $branch and .source_sha == $source)' "$ledger" > /dev/null; then
            jq --arg branch "$branch" --arg source "$source" \
                '.requests[] | select(.branch == $branch and .source_sha == $source) | .event' \
                "$ledger" > "$github_output/event.json"
            return
        fi
        last=$(jq -r '.last_source_sha' "$github_output/line-record.json")
        jq -e --arg last "$last" '.kind == "update" and .before_sha == $last' \
            "$github_workspace/durable-event.json" > /dev/null ||
            release_fail 'source order gap; retry the missing original branch event first'
        parents=$(git --no-replace-objects -C "$repo" show -s --format=%P "$source")
        [[ "$parents" == "$last" ]] || release_fail 'expected one new squash commit'
        # Effective non-bypassable PR rules supply review/check enforcement.
        # Verify the actual merged PR and main-first references for this update.
        github_list "/repos/$github_repository/commits/$source/pulls?per_page=100" "$github_workspace/associated.json"
        number=$(jq -er --arg branch "$branch" --arg source "$source" \
            '[.[] | select(.base.ref == $branch and .merge_commit_sha == $source)] |
             if length == 1 then .[0].number else error("missing or ambiguous merged PR") end' \
            "$github_workspace/associated.json")
        github_get "/repos/$github_repository/pulls/$number" "$github_workspace/current-pr.json"
        jq -e -L "$RELEASE_ROOT/tools/release" --arg repository "$github_repository" \
            --arg branch "$branch" --arg source "$source" \
            'include "github"; merged_pr($repository; $branch; $source)' \
            "$github_workspace/current-pr.json" > /dev/null
        git --no-replace-objects -C "$repo" show -s --format=%B "$source" > "$github_workspace/message"
        jq -r '.title + "\n" + (.body // "")' "$github_workspace/current-pr.json" > "$github_workspace/pr-message"
        release_validate_maintenance < "$github_workspace/message"
        release_validate_maintenance < "$github_workspace/pr-message"
        policy=$(git --no-replace-objects -C "$repo" rev-parse refs/remotes/origin/main)
        release_backport_commits < "$github_workspace/message" > "$github_workspace/main-commits"
        while IFS= read -r main_sha; do
            release_validate_main_commit "$repo" "$main_sha" "$policy"
            github_commit_pr "$main_sha" main true
            jq -e --slurpfile backport "$github_workspace/current-pr.json" \
                '.merged_at <= $backport[0].merged_at' "$github_workspace/selected-pr.json" > /dev/null ||
                release_fail 'backport source was not merged on main first'
        done < "$github_workspace/main-commits"
        kind=$(jq -rn -L "$RELEASE_ROOT/tools/release" --rawfile message "$github_workspace/message" \
            --slurpfile pr "$github_workspace/current-pr.json" \
            'include "policy"; if fix_request($message; $pr[0].title) then "fix" else "maintenance" end')
        jq -Rn '[inputs | select(length > 0)]' "$github_workspace/main-commits" > "$github_workspace/main.json"
        jq --arg source "$source" --arg before "$last" --arg kind "$kind" \
            --arg ref "https://github.com/$github_repository/pull/$number" \
            --slurpfile commits "$github_workspace/main.json" \
            '.last_source_sha = $source | .updates += [{source_sha: $source, before_sha: $before,
              kind: $kind, decision_ref: $ref, main_commits: $commits[0]}]' \
            "$github_output/line-record.json" > "$github_workspace/line-next.json"
        mv "$github_workspace/line-next.json" "$github_output/line-record.json"
        jq --slurpfile line "$github_output/line-record.json" \
            --arg repository "$github_repository" \
            '. + {schema_version: 1, repository: $repository, forced: false, deleted: false,
              creation_id: $line[0].creation.creation_id,
              creation_policy_sha: $line[0].creation.policy_sha, review: $line[0].updates[-1]}' \
            "$github_workspace/durable-event.json" > "$github_output/event.json"
    fi
    jq -n -L "$RELEASE_ROOT/tools/release" --arg line "$line" \
        --slurpfile ledger "$ledger" --slurpfile record "$github_output/line-record.json" \
        'include "publication"; ($ledger[0] | .lines[$line] = $record[0]) | proposer_state(.; $line)' \
        > "$github_output/state.json"
    bash "$RELEASE_ROOT/tools/release/propose.sh" --validate-source --repo "$repo" \
        --repository "$github_repository" --event "$github_output/event.json" --state "$github_output/state.json" \
        > "$github_output/admitted-source.json"
}

github_select_branch() {
    local repo=$1 event_file=$2 event_name=$3 source=$4 branch cut policy creation_id
    local creation_time creation_policy registration_ref registration_number revision parents
    local number main_sha kind before creation_count update_count

    jq -e -L "$RELEASE_ROOT/tools/release" --arg name "$event_name" \
        --arg repository "$github_repository" --arg source "$source" \
        'include "github"; workflow_event($name; $repository; $source)' \
        "$event_file" > "$github_workspace/event.json"
    branch=$(jq -r '.branch' "$github_workspace/event.json")
    policy=$(git --no-replace-objects -C "$repo" rev-parse refs/remotes/origin/main)
    git --no-replace-objects -C "$repo" show "$policy:.github/release-lines.json" > "$github_workspace/policy.json"
    jq -e -L "$RELEASE_ROOT/tools/release" --arg repository "$github_repository" --arg branch "$branch" \
        'include "policy"; validate_policy($repository) | .lines |
         map(select(.branch == $branch and .status != "retired")) |
         if length == 1 then .[0] else error("unregistered or retired release branch") end' \
        "$github_workspace/policy.json" > "$github_workspace/line.json"
    cut=$(jq -r '.cut_sha' "$github_workspace/line.json")
    github_activities "$branch" "$github_output/branch-activity.json"
    creation_count=$(jq '[.[] | select(.activity_type == "branch_creation")] | length' \
        "$github_output/branch-activity.json")
    [[ "$creation_count" == 1 ]] || release_fail 'missing original creation activity or recreated release branch'
    jq -e 'all(.[]; .activity_type != "force_push" and .activity_type != "branch_deletion")' \
        "$github_output/branch-activity.json" > /dev/null || release_fail 'release branch was deleted or force updated'
    jq -e --arg cut "$cut" '.[] | select(.activity_type == "branch_creation") |
        if .after == $cut then . else error("creation differs from registered cut") end' \
        "$github_output/branch-activity.json" > "$github_workspace/creation-activity.json"
    creation_id=$(jq -r '.node_id' "$github_workspace/creation-activity.json")
    creation_time=$(jq -r '.timestamp' "$github_workspace/creation-activity.json")
    # Repository activity supplies server time and the actual main ref state.
    # Git author/committer dates cannot establish registration chronology.
    github_activities main "$github_output/main-activity.json"
    creation_policy=$(jq -er --arg time "$creation_time" \
        '[.[] | select(.timestamp < $time)] | sort_by(.timestamp) | . as $events | last |
         if . == null then error("missing main activity before creation")
         else .timestamp as $latest |
           if ([$events[] | select(.timestamp == $latest)] | length) != 1
           then error("ambiguous latest main activity") else .after end end' \
        "$github_output/main-activity.json")
    jq -e --arg time "$creation_time" 'all(.[]; .timestamp != $time)' \
        "$github_output/main-activity.json" > /dev/null ||
        release_fail 'main activity and branch creation share a timestamp; chronology is ambiguous'
    git --no-replace-objects -C "$repo" merge-base --is-ancestor "$creation_policy" "$policy"
    git --no-replace-objects -C "$repo" show "$creation_policy:.github/release-lines.json" \
        > "$github_workspace/creation-policy.json"
    registration_ref=$(jq -r '.decision_ref' "$github_workspace/line.json")
    [[ "$registration_ref" == "https://github.com/$github_repository/pull/"* ]] ||
        release_fail 'branch CI requires decision_ref to identify its reviewed main registration PR'
    registration_number=${registration_ref##*/}
    [[ "$registration_number" =~ ^[1-9][0-9]*$ ]] || release_fail 'invalid registration PR reference'
    github_get "/repos/$github_repository/pulls/$registration_number" "$github_workspace/registration.json"
    revision=$(jq -r '.merge_commit_sha' "$github_workspace/registration.json")
    github_reviewed_pr "$registration_number" main "$revision"
    jq -e --arg time "$creation_time" '.merged_at < $time' \
        "$github_output/api/pr-$registration_number.json" > /dev/null ||
        release_fail 'registration PR was not merged before branch creation'
    git --no-replace-objects -C "$repo" merge-base --is-ancestor "$revision" "$creation_policy"
    git --no-replace-objects -C "$repo" show "$revision:.github/release-lines.json" \
        > "$github_workspace/registration-policy.json"
    jq -e --slurpfile line "$github_workspace/line.json" \
        'any(.lines[]; .branch == $line[0].branch and .cut_sha == $line[0].cut_sha and
          .decision_ref == $line[0].decision_ref)' "$github_workspace/registration-policy.json" > /dev/null ||
        release_fail 'registration PR did not contain this release-line decision'
    jq -e --slurpfile line "$github_workspace/line.json" \
        'any(.lines[]; .branch == $line[0].branch and .cut_sha == $line[0].cut_sha and
          .decision_ref == $line[0].decision_ref and .status != "retired")' \
        "$github_workspace/creation-policy.json" > /dev/null || release_fail 'registration did not precede the cut'
    jq -n --arg repository "$github_repository" --arg branch "$branch" --arg cut "$cut" \
        --arg id "$creation_id" --arg policy "$creation_policy" \
        '{schema_version: 1, repository: $repository,
          creation: {branch: $branch, source_sha: $cut, policy_sha: $policy, creation_id: $id},
          updates: [], requests: [], releases: []}' > "$github_output/state.json"
    git --no-replace-objects -C "$repo" rev-list --reverse --first-parent "$cut..$source" \
        > "$github_workspace/updates"
    update_count=$(wc -l < "$github_workspace/updates")
    [[ "$update_count" -le 100 ]] || release_fail 'release review history exceeds collector limit'
    while IFS= read -r revision; do
        parents=$(git --no-replace-objects -C "$repo" show -s --format=%P "$revision")
        [[ "$parents" =~ ^[0-9a-f]{40}$ ]] || release_fail 'release updates must be squash commits'
        github_commit_pr "$revision" "$branch"
        number=$(jq -r '.number' "$github_workspace/selected-pr.json")
        git --no-replace-objects -C "$repo" show -s --format=%B "$revision" > "$github_workspace/message"
        release_validate_maintenance < "$github_workspace/message"
        jq -r '.title + "\n" + (.body // "")' "$github_workspace/selected-pr.json" > "$github_workspace/pr-message"
        release_validate_maintenance < "$github_workspace/pr-message"
        kind=$(jq -rn -L "$RELEASE_ROOT/tools/release" \
            --rawfile message "$github_workspace/message" \
            --slurpfile pr "$github_workspace/selected-pr.json" \
            'include "policy"; if fix_request($message; $pr[0].title)
             then "fix" else "maintenance" end')
        release_backport_commits < "$github_workspace/message" \
            > "$github_workspace/main-commits"
        [[ "$kind" != fix || -s "$github_workspace/main-commits" ]] ||
            release_fail 'fix squash message must retain the full main cherry-pick reference'
        while IFS= read -r main_sha; do
            github_commit_pr "$main_sha" main
            jq -e --slurpfile backport "$github_output/api/pr-$number.json" \
                '.merged_at <= $backport[0].merged_at' "$github_workspace/selected-pr.json" > /dev/null ||
                release_fail 'backport source was not merged on main first'
        done < "$github_workspace/main-commits"
        jq -Rn '[inputs | select(length > 0)]' "$github_workspace/main-commits" > "$github_workspace/main.json"
        jq --arg before "$parents" --arg source "$revision" --arg kind "$kind" \
            --arg ref "https://github.com/$github_repository/pull/$number" \
            --slurpfile main "$github_workspace/main.json" \
            '.updates += [{before_sha: $before, source_sha: $source, kind: $kind,
              decision_ref: $ref, main_commits: $main[0]}]' "$github_output/state.json" \
            > "$github_workspace/next-state.json"
        mv "$github_workspace/next-state.json" "$github_output/state.json"
    done < "$github_workspace/updates"
    kind=$(jq -r '.kind' "$github_workspace/event.json")
    before=$(jq -r '.before_sha // empty' "$github_workspace/event.json")
    if [[ "$kind" == update ]]; then
        jq -e --arg source "$source" --arg before "$before" \
            'any(.[]; .after == $source and .before == $before and
              (.activity_type == "pr_merge" or .activity_type == "push"))' \
            "$github_output/branch-activity.json" > /dev/null || release_fail 'event has no matching server activity'
    fi
    jq --arg id "$creation_id" --arg policy "$creation_policy" \
        --slurpfile state "$github_output/state.json" \
        '. + {schema_version: 1, repository: $state[0].repository, forced: false, deleted: false,
          creation_id: $id, creation_policy_sha: $policy,
          review: (if .kind == "update" then
            .source_sha as $source | $state[0].updates[] | select(.source_sha == $source) else null end)}' \
        "$github_workspace/event.json" > "$github_output/event.json"
    bash "$RELEASE_ROOT/tools/release/propose.sh" --repo "$repo" --repository "$github_repository" \
        --event "$github_output/event.json" --state "$github_output/state.json" > "$github_output/proposal.json"
    jq '.eligibility_limits += [
        "GitHub activity is bounded to one year. Durable creation/request state is not supplied by 05-A.",
        "This version is unreserved. Separate branch updates may propose the same version before 05-B."]' \
        "$github_output/proposal.json" > "$github_workspace/proposal.json"
    mv "$github_workspace/proposal.json" "$github_output/proposal.json"
}

github_preview_source() {
    local repo=$1 ref=$2 branch tag

    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        git --no-replace-objects -C "$repo" rev-parse --verify --end-of-options "$ref^{commit}"
        return
    fi
    [[ "$ref" != -* && "$ref" != *$'\n'* ]] || release_fail 'invalid preview ref'
    branch="refs/remotes/origin/${ref#refs/heads/}"
    tag="refs/tags/${ref#refs/tags/}"
    if [[ "$ref" != refs/tags/* ]] && git -C "$repo" show-ref --verify --quiet "$branch"; then
        if [[ "$ref" != refs/heads/* ]] && git -C "$repo" show-ref --verify --quiet "$tag"; then
            release_fail 'ambiguous preview ref; use refs/heads/NAME or refs/tags/NAME'
        fi
        git --no-replace-objects -C "$repo" rev-parse --verify "$branch^{commit}"
    else git --no-replace-objects -C "$repo" rev-parse --verify --end-of-options "$tag^{commit}"; fi
}

main() {
    local repo="$RELEASE_ROOT" event_file='' event_name='' source='' output=''
    local source_ref=main line='' version='' sha file bytes total=0 ledger='' check_rules=''
    local preview_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo | --event | --event-name | --source-sha | --output | --source-ref | --line | --version | --repository | --ledger | --check-rules)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --repo) repo=$2 ;;
                    --event) event_file=$2 ;;
                    --event-name) event_name=$2 ;;
                    --source-sha) source=$2 ;;
                    --output) output=$2 ;;
                    --source-ref) source_ref=$2 ;;
                    --line) line=$2 ;;
                    --version) version=$2 ;;
                    --repository) github_repository=$2 ;;
                    --ledger) ledger=$2 ;;
                    --check-rules) check_rules=$2 ;;
                esac
                shift 2
                ;;
            --help)
                printf 'Usage: bash tools/release/github.sh --event FILE --event-name NAME --source-sha SHA --repository OWNER/REPO --output DIR [--repo DIR] [--source-ref REF] [--line MAJOR.MINOR] [--version SEMVER]\n'
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done
    release_require_commands git jq sed tr curl timeout mktemp wc find
    release_require_sha256
    github_repository=$(printf '%s' "$github_repository" | tr '[:upper:]' '[:lower:]')
    [[ (-n "$check_rules" || (-f "$event_file" && "$source" =~ ^[0-9a-f]{40}$)) && -n "$output" &&
        "$github_repository" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || release_fail 'missing or invalid workflow input'
    [[ ! -e "$output" ]] || release_fail 'selection output must be a new directory'
    trap cleanup_github EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    github_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-github.XXXXXX")
    mkdir -p "$output/api"
    github_output=$(cd "$output" && pwd -P)
    : > "$github_output/api-inventory.jsonl"
    if [[ -n "$check_rules" ]]; then
        jq -en -L "$RELEASE_ROOT/tools/release" --arg branch "$check_rules" \
            'include "policy"; $branch | startswith("release/") and (.[8:] | line_name)' > /dev/null
        github_rules "$repo" "$check_rules"
        return
    fi
    if [[ -n "$ledger" ]]; then
        [[ "$event_name" != workflow_dispatch && -z "$version" && -z "$line" ]] ||
            release_fail 'durable admission requires an unmodified branch event'
        github_select_durable "$repo" "$event_file" "$event_name" "$source" "$ledger"
        jq -s . "$github_output/api-inventory.jsonl" > "$github_output/api-inventory.json"
        return
    fi
    if [[ "$event_name" == workflow_dispatch ]]; then
        jq -e --arg repository "$github_repository" \
            '(.repository.full_name | ascii_downcase) == $repository' "$event_file" > /dev/null
        sha=$(github_preview_source "$repo" "$source_ref")
        [[ -z "$line" ]] || preview_args+=(--line "$line")
        [[ -z "$version" ]] || preview_args+=(--version "$version")
        bash "$RELEASE_ROOT/tools/release/propose.sh" --repo "$repo" --repository "$github_repository" \
            --source "$sha" "${preview_args[@]}" > "$github_output/proposal.json"
    else
        [[ -z "$line" && -z "$version" && "$source_ref" == main ]] ||
            release_fail 'branch events cannot override source, line, or version'
        github_select_branch "$repo" "$event_file" "$event_name" "$source"
    fi
    jq -s . "$github_output/api-inventory.jsonl" > "$github_workspace/inventory.json"
    sha=$(release_sha256 "$github_output/proposal.json")
    jq -n --arg sha "$sha" --slurpfile proposal "$github_output/proposal.json" \
        --slurpfile api "$github_workspace/inventory.json" \
        '{schema_version: 1, mode: $proposal[0].mode, repository: $proposal[0].repository,
          source_sha: $proposal[0].source_sha, policy_sha: $proposal[0].policy_sha,
          proposal_sha256: $sha, api: $api[0], publishable: false}' > "$github_output/github-evidence.json"
    find "$github_output" -type f -print0 > "$github_workspace/files"
    while IFS= read -r -d '' file; do
        bytes=$(wc -c < "$file")
        total=$((total + bytes))
        [[ "$total" -le 33554432 ]] || release_fail 'GitHub evidence exceeds 32 MiB'
    done < "$github_workspace/files"
    printf 'Selected source and proposal: %s\n' "$github_output/proposal.json"
}

main "$@"

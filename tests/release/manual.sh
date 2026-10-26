#!/usr/bin/env bash
# Sourced by publication.sh. Dispatches use the local Git and API fixtures.
# shellcheck disable=SC2154

reject_manual_event() {
    local name=$1 message=$2 filter=$3 selected

    jq --arg old "$fixture_fix" "$filter" "$manual_event" > "$result-invalid.json"
    selected=$(jq -r .inputs.source_sha "$result-invalid.json")
    expect_github_failure "$name" "$message" coordinate_fixture enqueue \
        --event "$result-invalid.json" --event-name "$GITHUB_EVENT_NAME" --source "$selected"
}

check_resume_release() {
    local original_run=$GITHUB_RUN_ID
    local GITHUB_RUN_ID=$((GITHUB_RUN_ID + 20)) GITHUB_EVENT_NAME=workflow_dispatch
    local GITHUB_EVENT_PATH="$result-resume-event.json"
    local saved_head actual_head

    export GITHUB_RUN_ID GITHUB_EVENT_NAME GITHUB_EVENT_PATH
    jq -n --arg source "$source" --arg branch "$branch" --arg resume "$original_run" \
        '{ref:"main",repository:{full_name:"fixture/kgcache"},sender:{login:"maintainer",id:101},
          inputs:{operation:"Publish RC",source_ref:$branch,source_sha:$source,version:"",
            release_notes:"Recovery must keep the frozen notes.",resume_run_id:$resume}}' > "$GITHUB_EVENT_PATH"
    jq -n --arg workflow "$workflow" --argjson run "$GITHUB_RUN_ID" \
        --slurpfile event "$GITHUB_EVENT_PATH" '{id:$run,event:"workflow_dispatch",head_branch:"main",head_sha:$workflow,
          path:".github/workflows/release.yml",repository:{full_name:"fixture/kgcache"},
          actor:$event[0].sender,triggering_actor:$event[0].sender,created_at:"2026-10-20T00:00:10Z"}' \
        > "$fixture_api/resume-run.json"
    route "/repos/fixture/kgcache/actions/runs/$GITHUB_RUN_ID" resume-run.json
    saved_head=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    coordinate_fixture enqueue --event "$GITHUB_EVENT_PATH" --event-name workflow_dispatch --source "$source" \
        > "$result-resumed.json"
    cmp "$result-tagged.json" "$result-resumed.json"
    coordinate_fixture allocate --request "$key" --output "$result-resumed-selection" > "$result-resumed-allocated.json"
    cmp "$result-tagged.json" "$result-resumed-allocated.json"
    actual_head=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    [[ "$saved_head" == "$actual_head" ]] || release_fail 'resuming changed the frozen request'
    jq --arg wrong "$((original_run + 1))" '.inputs.resume_run_id = $wrong' "$GITHUB_EVENT_PATH" > "$result-wrong-resume.json"
    expect_github_failure resume-wrong-run 'retry its original workflow' coordinate_fixture enqueue \
        --event "$result-wrong-resume.json" --event-name workflow_dispatch --source "$source"
    mutate_api permission.json '.permission = "read"'
    expect_github_failure resume-read-only-actor 'maintainer write access' coordinate_fixture enqueue \
        --event "$GITHUB_EVENT_PATH" --event-name workflow_dispatch --source "$source"
    restore_api permission.json
    jq -en -L "$RELEASE_ROOT/tools/release" --slurpfile request "$result-tagged.json" \
        --arg run "$GITHUB_RUN_ID" --arg original "$original_run" 'include "publication";
        $request[0] as $request |
        ($request | publication_run_matches($original; "")) and
        ($request | publication_run_matches($run; $original)) and
        ($request | publication_run_matches($run; "") | not) and
        ($request | .status = "qualified" | publication_run_matches($run; $original) | not) and
        ($request | del(.tag_object_sha) | publication_run_matches($run; $original) | not) and
        ($request | del(.candidate.artifact_id) | publication_run_matches($run; $original) | not) and
        ($request | .candidate.run.id = $run | publication_run_matches($run; $original) | not) and
        ($request | .candidate.run.workflow_sha = ("f" * 40) | publication_run_matches($run; $original) | not)' > /dev/null
    printf 'Passed: %s tagged recovery preserves the request, artifact, version, tag, and notes\n' "$fixture_name"
}

check_initial_release() {
    local fixture_name=${1:-manual}
    local result="$publication_workspace/$fixture_name"
    local original_repo=$fixture_repo
    local fixture_repo="$result-repo"
    local publication_remote="$result-remote.git"
    local candidate_test_workspace="$result-candidate"
    local manual_event="$result-event.json"
    local source workflow key first_state next_source main_fix second_key actual other_run private_source
    local target=0.4.0 branch
    local GITHUB_RUN_ID=9001 GITHUB_SHA GITHUB_WORKFLOW_SHA
    local GITHUB_ACTIONS=true GITHUB_REPOSITORY=fixture/kgcache GITHUB_EVENT_NAME=workflow_dispatch
    local GITHUB_REF=refs/heads/main GITHUB_EVENT_PATH=$manual_event
    local GITHUB_WORKFLOW_REF=fixture/kgcache/.github/workflows/release.yml@refs/heads/main

    if [[ "$fixture_name" == automatic ]]; then
        GITHUB_RUN_ID=9003 GITHUB_EVENT_NAME=repository_dispatch target=0.5.0
    fi
    branch="release/$target-rc"
    export GITHUB_RUN_ID GITHUB_SHA GITHUB_WORKFLOW_SHA GITHUB_ACTIONS GITHUB_REPOSITORY
    export GITHUB_EVENT_NAME GITHUB_REF GITHUB_EVENT_PATH GITHUB_WORKFLOW_REF
    git clone --quiet "$original_repo" "$fixture_repo"
    git -C "$fixture_repo" config user.name 'Release fixture'
    git -C "$fixture_repo" config user.email fixture@example.invalid
    git -C "$fixture_repo" config commit.gpgsign false
    git -C "$fixture_repo" config core.hooksPath /dev/null
    git -C "$fixture_repo" switch --quiet main
    git -C "$fixture_repo" rm --quiet .github/release-lines.json
    source=$(fixture_commit 'chore: prepare reviewed main source')
    fixture_pr 40 "$source" main 2026-10-20T00:00:08Z
    printf 'trusted workflow update\n' > "$fixture_repo/workflow.txt"
    workflow=$(fixture_commit 'ci: update trusted publication workflow')
    fixture_pr 41 "$workflow" main 2026-10-20T00:00:09Z
    GITHUB_SHA=$workflow GITHUB_WORKFLOW_SHA=$workflow
    git -C "$fixture_repo" branch "$branch" "$source"
    git clone --quiet --bare "$fixture_repo" "$publication_remote"
    route "/repos/fixture/kgcache/rules/branches/release%2F$target-rc?per_page=100" merge-rules.json
    jq -n --arg source "$source" --arg branch "$branch" '{ref:"main",repository:{full_name:"fixture/kgcache"},
        sender:{login:"maintainer",id:101},inputs:{operation:"Publish RC",source_ref:$branch,
          source_sha:$source,version:"",release_notes:"Manual candidate notes."}}' > "$manual_event"
    if [[ "$fixture_name" == automatic ]]; then
        jq -n --arg source "$source" --arg branch "$branch" '{action:"initial-rc",repository:{full_name:"fixture/kgcache"},
            sender:{login:"github-actions[bot]",id:41898282},client_payload:{branch:$branch,
              source_sha:$source,creation_run_id:"8001"}}' > "$manual_event"
    fi
    jq -n --arg workflow "$workflow" --arg trigger "$GITHUB_EVENT_NAME" --argjson run "$GITHUB_RUN_ID" \
        --slurpfile event "$manual_event" '{id:$run,event:$trigger,head_branch:"main",head_sha:$workflow,
          path:".github/workflows/release.yml",repository:{full_name:"fixture/kgcache"},
          actor:$event[0].sender,triggering_actor:$event[0].sender,created_at:"2026-10-20T00:00:10Z"}' \
        > "$fixture_api/dispatch-run.json"
    route "/repos/fixture/kgcache/actions/runs/$GITHUB_RUN_ID" dispatch-run.json
    jq -n --arg source "$source" --arg branch "$branch" '{id:8001,event:"create",head_branch:$branch,head_sha:$source,
        path:".github/workflows/initial-rc.yml",repository:{full_name:"fixture/kgcache"},
        actor:{login:"maintainer",id:101},triggering_actor:{login:"maintainer",id:101},created_at:"2026-10-20T00:00:09Z"}' \
        > "$fixture_api/creation-run.json"
    route /repos/fixture/kgcache/actions/runs/8001 creation-run.json
    jq -n --arg source "$source" --arg branch "$branch" '[{node_id:"initial-creation",ref:("refs/heads/" + $branch),
        activity_type:"branch_creation",before:("0" * 40),after:$source,timestamp:"2026-10-20T00:00:09Z"}]' \
        > "$fixture_api/initial-activity.json"
    route "/repos/fixture/kgcache/activity?ref=refs%2Fheads%2Frelease%2F$target-rc&time_period=year&per_page=100" initial-activity.json
    bash "$RELEASE_ROOT/tests/release/manual-child.sh" fixture/kgcache "$branch" "$source"
    expect_github_failure manual-wrong-ref 'must use the release workflow from main' env GITHUB_REF=refs/heads/other \
        bash "$RELEASE_ROOT/tests/release/manual-child.sh" fixture/kgcache "$branch" "$source"
    expect_github_failure manual-wrong-source 'authenticated workflow source' \
        bash "$RELEASE_ROOT/tests/release/manual-child.sh" fixture/kgcache "$branch" "$workflow"
    if [[ "$fixture_name" == manual ]]; then
        reject_manual_event manual-preview 'explicit Publish RC' '.inputs.operation = "Preview"'
        reject_manual_event manual-empty-notes 'nonempty release notes' '.inputs.release_notes = "<!-- empty -->"'
        reject_manual_event manual-explicit-version 'automatic version selection' '.inputs.version = "0.4.0-rc.99"'
        reject_manual_event manual-stable-branch 'manual publication requires' '.inputs.source_ref = "release/0.4.0"'
        reject_manual_event manual-invalid-resume 'invalid original publication run ID' '.inputs.resume_run_id = "invalid"'
        # shellcheck disable=SC2016
        reject_manual_event manual-old-source 'original RC branch creation commit' '.inputs.source_sha = $old'
    else
        mutate_api creation-run.json '.head_sha = ("f" * 40)'
        expect_github_failure automatic-wrong-origin 'creation run differs' coordinate_fixture enqueue \
            --event "$manual_event" --event-name "$GITHUB_EVENT_NAME" --source "$source"
        restore_api creation-run.json
    fi
    mutate_api dispatch-run.json '.head_branch = "other"'
    expect_github_failure manual-run-origin 'dispatch run differs' coordinate_fixture enqueue \
        --event "$manual_event" --event-name "$GITHUB_EVENT_NAME" --source "$source"
    restore_api dispatch-run.json
    mutate_api permission.json '.permission = "read"'
    expect_github_failure manual-read-only-actor 'maintainer write access' coordinate_fixture enqueue \
        --event "$manual_event" --event-name "$GITHUB_EVENT_NAME" --source "$source"
    restore_api permission.json
    mutate_api pr-40.json '.merged_at = "2026-10-18T00:00:00Z"'
    expect_github_failure manual-unenforced-source 'predates enforced review' coordinate_fixture enqueue \
        --event "$manual_event" --event-name "$GITHUB_EVENT_NAME" --source "$source"
    restore_api pr-40.json
    mutate_api initial-activity.json '. + [.[0] | .node_id = "recreated-branch"]'
    expect_github_failure initial-recreated-branch 'recreated branches' coordinate_fixture enqueue \
        --event "$manual_event" --event-name "$GITHUB_EVENT_NAME" --source "$source"
    restore_api initial-activity.json
    git -C "$fixture_repo" switch --quiet -c unreviewed-cut "$source"
    printf 'unreviewed source\n' > "$fixture_repo/unreviewed.txt"
    private_source=$(fixture_commit 'chore: unreviewed branch source')
    git -C "$fixture_repo" push --quiet "$publication_remote" "$private_source:refs/heads/$branch"
    jq --arg source "$private_source" \
        'if .client_payload != null then .client_payload.source_sha = $source else .inputs.source_sha = $source end' \
        "$manual_event" > "$result-unreviewed.json"
    if [[ "$fixture_name" == automatic ]]; then
        mutate_api creation-run.json ".head_sha = \"$private_source\""
    fi
    expect_github_failure initial-unreviewed-source 'reviewed main commit' coordinate_fixture enqueue \
        --event "$result-unreviewed.json" --event-name "$GITHUB_EVENT_NAME" --source "$private_source"
    if [[ "$fixture_name" == automatic ]]; then restore_api creation-run.json; fi
    git -C "$publication_remote" update-ref "refs/heads/$branch" "$source"
    [[ -z "$(git -C "$publication_remote" show-ref --verify refs/heads/release-state 2> /dev/null || true)" ]]

    git -C "$fixture_repo" switch --quiet main
    printf 'reviewed correction\n' > "$fixture_repo/manual-fix.txt"
    main_fix=$(fixture_commit 'fix: correct candidate behavior')
    fixture_pr 42 "$main_fix" main 2026-10-20T00:00:09Z
    git -C "$fixture_repo" push --quiet "$publication_remote" main
    next_source=$(merged_pr_fixture 43 "$branch" 'fix: correct candidate behavior' "$main_fix")
    expect_github_failure initial-request-order 'initial RC request is missing' coordinate_fixture enqueue \
        --event "$publication_workspace/release-event-43.json" --event-name pull_request --source "$next_source"
    if [[ "$fixture_name" == manual ]]; then
        jq --arg run "$GITHUB_RUN_ID" '.inputs.resume_run_id = $run' "$manual_event" > "$result-no-request-resume.json"
        expect_github_failure resume-no-request 'existing tagged candidate request' coordinate_fixture enqueue \
            --event "$result-no-request-resume.json" --event-name workflow_dispatch --source "$source"
    fi
    coordinate_fixture enqueue --event "$manual_event" --event-name "$GITHUB_EVENT_NAME" --source "$source" \
        > "$result-request.json"
    key=$(jq -r .request_key "$result-request.json")
    coordinate_fixture allocate --request "$key" --output "$result-selection" \
        > "$result-allocated.json"
    jq -e --arg source "$source" --arg workflow "$workflow" --arg version "$target-rc.1" '.version == $version and .source_sha == $source and
        .event.workflow_sha == $workflow and .event.workflow_sha != .source_sha and
        .proposal.release_notes.body == .event.notes and (.event.notes | length > 0) and .proposal.release_notes.pr_number == null' \
        "$result-allocated.json" > /dev/null
    printf 'synthetic qualification failure\n' > "$result-failure.txt"
    coordinate_fixture fail --request "$key" --failure "$result-failure.txt" > /dev/null
    coordinate_fixture allocate --request "$key" > "$result-failed-retry.json"
    jq -e --slurpfile original "$result-allocated.json" '.version == $original[0].version and .proposal == $original[0].proposal' \
        "$result-failed-retry.json" > /dev/null
    first_state=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    jq '.inputs.release_notes = "Edited notes after admission."' "$manual_event" > "$result-retry.json"
    coordinate_fixture enqueue --event "$result-retry.json" --event-name "$GITHUB_EVENT_NAME" --source "$source" \
        > "$result-redelivered.json"
    jq -e --slurpfile original "$result-allocated.json" '.version == $original[0].version and .event.notes == $original[0].event.notes' \
        "$result-redelivered.json" > /dev/null
    actual=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    [[ "$first_state" == "$actual" ]]
    other_run=$((GITHUB_RUN_ID + 1))
    jq --argjson run "$other_run" '.id = $run' "$fixture_api/dispatch-run.json" > "$fixture_api/dispatch-other-run.json"
    route "/repos/fixture/kgcache/actions/runs/$other_run" dispatch-other-run.json
    expect_github_failure manual-new-run 'retry its original workflow' env GITHUB_RUN_ID="$other_run" \
        bash "$RELEASE_ROOT/tools/release/coordinate.sh" enqueue --fixture --remote "$publication_remote" \
        --repository fixture/kgcache --event "$manual_event" --event-name "$GITHUB_EVENT_NAME" --source "$source"
    if [[ "$fixture_name" == manual ]]; then
        jq --arg run "$GITHUB_RUN_ID" '.inputs.resume_run_id = $run' "$manual_event" > "$result-untagged-resume.json"
        expect_github_failure resume-untagged 'retry its original workflow' env GITHUB_RUN_ID="$other_run" \
            bash "$RELEASE_ROOT/tools/release/coordinate.sh" enqueue --fixture --remote "$publication_remote" \
            --repository fixture/kgcache --event "$result-untagged-resume.json" --event-name workflow_dispatch --source "$source"
    fi

    mkdir -p "$candidate_test_workspace"
    create_fixture "$result-selection/proposal.json"
    jq --arg run "$GITHUB_RUN_ID" --arg workflow "$workflow" --arg ref "$GITHUB_WORKFLOW_REF" \
        '.run = {id:$run,attempt:"1",workflow_sha:$workflow,workflow_ref:$ref}' \
        "$candidate_test_workspace/good/candidate.json" > "$candidate_test_workspace/candidate-next.json"
    mv "$candidate_test_workspace/candidate-next.json" "$candidate_test_workspace/good/candidate.json"
    refresh_checksums "$candidate_test_workspace/good"
    jq -en -L "$RELEASE_ROOT/tools/release" --argjson run "$GITHUB_RUN_ID" --slurpfile candidate "$candidate_test_workspace/good/candidate.json" \
        --slurpfile request "$result-allocated.json" 'include "candidate";
        {id:77,expired:false,workflow_run:{id:$run,head_sha:$request[0].event.workflow_sha}} as $artifact |
        ($artifact | candidate_artifact_matches($candidate[0]; $request[0].event; "77")) and
        ($artifact | .workflow_run.head_sha = $candidate[0].source_sha |
          candidate_artifact_matches($candidate[0]; $request[0].event; "77") | not) and
        ($artifact | .expired = true | candidate_artifact_matches($candidate[0]; $request[0].event; "77") | not)' > /dev/null
    coordinate_fixture qualify --request "$key" --candidate "$candidate_test_workspace/good" --artifact-id 77 > /dev/null
    coordinate_fixture tag --request "$key" --candidate "$candidate_test_workspace/good" > "$result-tagged.json"
    actual=$(git -C "$publication_remote" rev-parse "refs/tags/v$target-rc.1^{commit}")
    [[ "$actual" == "$source" ]]
    coordinate_fixture tag --request "$key" --candidate "$candidate_test_workspace/good" > "$result-tagged-retry.json"
    cmp "$result-tagged.json" "$result-tagged-retry.json"
    check_resume_release

    coordinate_fixture enqueue --event "$publication_workspace/release-event-43.json" --event-name pull_request --source "$next_source" \
        > "$result-backport.json"
    second_key=$(jq -r .request_key "$result-backport.json")
    jq -e --arg version "$target-rc.2" '.version == $version' "$result-backport.json" > /dev/null
    expect_github_failure manual-backport-order 'earlier source is unresolved' coordinate_fixture allocate --request "$second_key"
    printf 'Passed: %s initial RC without source changes, authorization, frozen retry, artifact origin, and later backport\n' "$fixture_name"
}

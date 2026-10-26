#!/usr/bin/env bash
# Exercise publication identity with local Git remotes and synthetic evidence.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/candidates.sh"
source "${BASH_SOURCE[0]%/*}/github.sh"
source "${BASH_SOURCE[0]%/*}/merged-pr.sh"
source "${BASH_SOURCE[0]%/*}/manual.sh"

publication_workspace=
publication_remote=
publication_registry_container=
publication_api_pid=
publication_registry=
publication_api=
publication_key=
publication_transport=

setup_git_fault() {
    local real_git

    real_git=$(command -v git)
    mkdir -p "$publication_workspace/git-fault"
    cat > "$publication_workspace/git-fault/git" << 'SH'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
    if [[ "$argument" == push && ! -e "$GIT_FIXTURE_FAULT/used" ]]; then
        if [[ "$GIT_FIXTURE_MODE" == conflict ]]; then
            touch "$GIT_FIXTURE_FAULT/used"
            old=$("$GIT_FIXTURE_REAL" -C "$GIT_FIXTURE_REMOTE" rev-parse refs/heads/release-state)
            tree=$("$GIT_FIXTURE_REAL" -C "$GIT_FIXTURE_REMOTE" rev-parse "$old^{tree}")
            other=$("$GIT_FIXTURE_REAL" -C "$GIT_FIXTURE_REMOTE" -c user.name='Release fixture' \
                -c user.email=fixture@example.invalid -c commit.gpgsign=false \
                commit-tree "$tree" -p "$old" -m 'chore: concurrent fixture writer')
            "$GIT_FIXTURE_REAL" -C "$GIT_FIXTURE_REMOTE" update-ref refs/heads/release-state "$other" "$old"
        elif [[ " $* " == *:refs/tags/* ]]; then
            "$GIT_FIXTURE_REAL" "$@"
            touch "$GIT_FIXTURE_FAULT/used"
            exit 75
        fi
    fi
done
exec "$GIT_FIXTURE_REAL" "$@"
SH
    chmod +x "$publication_workspace/git-fault/git"
    export GIT_FIXTURE_REAL="$real_git" GIT_FIXTURE_FAULT="$publication_workspace/git-fault"
    export GIT_FIXTURE_REMOTE="$publication_remote"
}

cleanup_publication_tests() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "$publication_api_pid" ]]; then
        kill "$publication_api_pid" 2> /dev/null || exit_status=1
        wait "$publication_api_pid" 2> /dev/null || true
    fi
    if [[ -n "$publication_registry_container" ]]; then
        if [[ "$exit_status" != 0 ]]; then
            timeout 10s docker logs --tail 40 "$publication_registry_container" >&2 || true
        fi
        timeout 15s docker rm --force "$publication_registry_container" > /dev/null || exit_status=1
    fi
    if [[ -n "$publication_transport" ]] && timeout 10s docker image inspect "$publication_transport" > /dev/null 2>&1; then
        timeout 15s docker image rm "$publication_transport" > /dev/null || exit_status=1
    fi
    [[ -z "$publication_workspace" ]] || rm -rf -- "$publication_workspace"
    exit "$exit_status"
}

coordinate_fixture() {
    local operation=$1

    shift
    bash "$RELEASE_ROOT/tools/release/coordinate.sh" "$operation" --fixture \
        --remote "$publication_remote" --repository fixture/kgcache "$@"
}

setup_publication_rules() {
    local branch encoded

    jq -n '[{type: "deletion"}, {type: "non_fast_forward"},
        {type: "pull_request", parameters: {required_approving_review_count: 1,
          dismiss_stale_reviews_on_push: true, required_review_thread_resolution: true,
          allowed_merge_methods: ["squash"]}},
        {type: "required_status_checks", parameters: {strict_required_status_checks_policy: true,
          required_status_checks: [{context: "PR title", integration_id: 15368}]}}] |
        map(. + {ruleset_id: 1})' > "$fixture_api/merge-rules.json"
    jq -n '["creation", "update", "deletion", "non_fast_forward"] |
        map({type: ., ruleset_id: 2})' > "$fixture_api/state-rules.json"
    printf '%s\n' '{"id":1,"enforcement":"active","target":"branch","bypass_actors":[]}' \
        > "$fixture_api/merge-ruleset.json"
    printf '%s\n' '{"id":2,"enforcement":"active","target":"branch","bypass_actors":[{"actor_id":42,"actor_type":"Integration","bypass_mode":"always"}]}' \
        > "$fixture_api/state-ruleset.json"
    route /repos/fixture/kgcache/rulesets/1 merge-ruleset.json
    route /repos/fixture/kgcache/rulesets/2 state-ruleset.json
    jq -n '{id: 3, target: "tag", enforcement: "active",
        conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
        rules: ["creation", "update", "deletion"] | map({type: .}),
        bypass_actors: [{actor_id: 42, actor_type: "Integration", bypass_mode: "always"}]}' \
        > "$fixture_api/tag-ruleset.json"
    route /repos/fixture/kgcache/rulesets/3 tag-ruleset.json
    for branch in main release/0.2; do
        encoded=$(jq -rn --arg branch "$branch" '$branch | @uri')
        route "/repos/fixture/kgcache/rules/branches/$encoded?per_page=100" merge-rules.json
    done
    route '/repos/fixture/kgcache/rules/branches/release-state?per_page=100' state-rules.json
    git -C "$fixture_repo" switch --quiet main
    jq 'del(.review_bypass) | .repository = "fixture/kgcache" | .enabled = true | .publisher_app_id = 42 | .tag_ruleset_id = 3 |
        .enforcement_since = "2026-10-19T00:00:00Z" | .registry_repository = "docker.io/fixture/kgcache" |
        .required_checks = {main: [{context: "PR title", integration_id: 15368}], release: []}' \
        "$RELEASE_ROOT/.github/release-automation.json" > "$fixture_repo/.github/release-automation.json"
    fixture_commit 'ci: configure fixture publication' > /dev/null
    git -C "$fixture_repo" update-ref refs/heads/release/0.2 "$fixture_backport"
    git clone --quiet --bare "$fixture_repo" "$publication_remote"
}

check_publication_requests() {
    local key patch_key first_head second_head object_type peeled

    coordinate_fixture init > /dev/null
    expect_github_failure missing-creation 'missing original durable creation' \
        coordinate_fixture enqueue --event "$github_test_workspace/update.json" \
        --event-name push --source "$fixture_backport"
    coordinate_fixture enqueue --event "$github_test_workspace/create.json" \
        --event-name push --source "$fixture_cut" > "$publication_workspace/request.json"
    key=$(jq -r '.request_key' "$publication_workspace/request.json")
    publication_key=$key
    first_head=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    coordinate_fixture enqueue --event "$github_test_workspace/ui-create.json" \
        --event-name create --source "$fixture_cut" > "$publication_workspace/duplicate.json"
    cmp "$publication_workspace/request.json" "$publication_workspace/duplicate.json"
    second_head=$(git -C "$publication_remote" rev-parse refs/heads/release-state)
    [[ "$first_head" == "$second_head" ]]
    coordinate_fixture allocate --request "$key" > "$publication_workspace/allocated.json"
    jq -e '.status == "admitted" and .version == "0.2.0"' "$publication_workspace/allocated.json" > /dev/null
    coordinate_fixture enqueue --event "$github_test_workspace/update.json" \
        --event-name push --source "$fixture_backport" > "$publication_workspace/patch.json"
    patch_key=$(jq -r '.request_key' "$publication_workspace/patch.json")
    expect_github_failure out-of-order 'earlier source is unresolved' \
        coordinate_fixture allocate --request "$patch_key"
    expect_github_failure missing-candidate 'retained candidate bytes' coordinate_fixture tag --request "$key"

    jq '.proposal' "$publication_workspace/allocated.json" > "$publication_workspace/proposal.json"
    candidate_test_workspace="$publication_workspace/candidate-fixture"
    mkdir -p "$candidate_test_workspace"
    create_fixture "$publication_workspace/proposal.json"
    coordinate_fixture qualify --request "$key" --candidate "$candidate_test_workspace/good" > /dev/null
    setup_git_fault
    GIT_FIXTURE_MODE=lost PATH="$publication_workspace/git-fault:$PATH" \
        coordinate_fixture tag --request "$key" --candidate "$candidate_test_workspace/good" > "$publication_workspace/tagged.json"
    [[ -f "$publication_workspace/git-fault/used" ]] || release_fail 'lost tag response was not exercised'
    first_head=$(git -C "$publication_remote" rev-parse refs/tags/v0.2.0)
    object_type=$(git -C "$publication_remote" cat-file -t "$first_head")
    peeled=$(git -C "$publication_remote" rev-parse 'refs/tags/v0.2.0^{commit}')
    [[ "$object_type" == tag && "$peeled" == "$fixture_cut" ]]
    coordinate_fixture tag --request "$key" --candidate "$candidate_test_workspace/good" > "$publication_workspace/retried.json"
    cmp "$publication_workspace/tagged.json" "$publication_workspace/retried.json"
    second_head=$(git -C "$publication_remote" rev-parse refs/tags/v0.2.0)
    [[ "$second_head" == "$first_head" ]]
    printf 'Passed: durable identity, source ordering, qualified tag, lost push response, and retry\n'
}

publish_fixture() {
    local operation=$1

    shift
    bash tools/release/publish.sh "$operation" --fixture --remote "$publication_remote" \
        --repository fixture/kgcache --request "$publication_key" \
        --registry "$publication_registry" --api-base "$publication_api" \
        --candidate "$candidate_test_workspace/good" "$@"
}

check_alias_precedence() {
    jq -en -L tools/release 'include "publication";
        {version: "0.3.0", digest: "new"} as $new |
        {version: "0.2.9", digest: "old"} as $old |
        (alias_decision($new; $old; "latest"; "latest") | .advance == false and .target == $new) and
        (alias_decision($old; $new; "latest"; "latest") | .advance == true and .target == $new) and
        (alias_decision({version:"0.2.1+one",digest:"a"}; {version:"0.2.1+two",digest:"b"}; "latest"; "latest") |
          .advance == false and .reason == "equal precedence with different content") and
        ({requests:{k:{version:"0.3.0-rc.1"}}} | alias_plan("k") | .line == null and .latest == null)' > /dev/null
    printf 'Passed: maintenance, prerelease, and metadata alias precedence\n'
}

check_clean_pull() {
    local mode message registry=docker.io/fixture/kgcache
    local record="$publication_workspace/clean-pull-request.json"
    local calls="$publication_workspace/docker-calls"
    local bin="$publication_workspace/verify-bin"

    mkdir "$bin"
    cp tests/release/verify-docker.sh "$bin/docker"
    chmod +x "$bin/docker"
    jq --arg registry "$registry" '.registry = {
        intent: {repository: $registry, engine_id: "shared-engine"},
        uploaded: {digest: ("sha256:" + ("a" * 64))}}' \
        "$publication_workspace/tagged.json" > "$record"
    for mode in missing present daemon-error timeout unrelated-missing; do
        case "$mode" in
            missing) message='fixture reached digest pull' ;;
            present) message='qualified image is already present' ;;
            *) message='cannot confirm the qualified image is absent' ;;
        esac
        : > "$calls"
        VERIFY_FIXTURE_MODE="$mode" VERIFY_FIXTURE_CALLS="$calls" PATH="$bin:$PATH" \
            expect_github_failure "clean-pull-$mode" "$message" \
            bash tools/release/publish.sh verify --request "$publication_key" \
            --registry "$registry" --record "$record" --candidate "$candidate_test_workspace/good" \
            --output "$publication_workspace/clean-pull-$mode"
        if [[ "$mode" == missing ]]; then
            grep -Fq "image pull --platform linux/amd64 $registry@sha256:" "$calls"
        elif grep -Fq 'image pull' "$calls"; then
            release_fail "clean pull reached the registry after $mode"
        fi
        [[ ! -e "$publication_workspace/clean-pull-$mode" ]] ||
            release_fail 'preflight fixture produced a verification receipt'
    done
    jq -en -L tools/release --slurpfile request "$record" '
        include "publication";
        {requests: {test: $request[0]}} as $ledger |
        {passed: true, digest: $request[0].registry.uploaded.digest,
          image_id: $request[0].candidate.image_id,
          candidate_sha256: $request[0].candidate_sha256,
          engine_id: "shared-engine", image_absent_before_pull: true} as $receipt |
        ($ledger | checkpoint("test"; "verified"; $receipt) |
          .requests.test.registry.verified == $receipt) and
        (try ($ledger | checkpoint("test"; "verified";
          $receipt | .image_absent_before_pull = false | .engine_id = "other-engine") | false) catch true) and
        (try ($ledger | checkpoint("test"; "verified";
          $receipt | del(.image_absent_before_pull)) | false) catch true) and
        (try ($ledger | checkpoint("test"; "verified";
          $receipt | .engine_id = "") | false) catch true) and
        (try ($ledger | checkpoint("test"; "verified";
          $receipt | .digest = ("sha256:" + ("b" * 64))) | false) catch true) and
        ($ledger | checkpoint("test"; "verified";
          $receipt | del(.image_absent_before_pull) | .engine_id = "legacy-other-engine") |
          .requests.test.registry.verified.engine_id == "legacy-other-engine")' > /dev/null
    printf 'Passed: shared daemon IDs, explicit absence evidence, and legacy verification receipts\n'
}

seed_registry_transport() {
    local archive="$publication_workspace/seed" path checksum bytes location base separator

    mkdir -p "$archive"
    candidate_check_archive "$candidate_test_workspace/good" "$archive"
    base="http://${publication_registry%%/*}/v2/${publication_registry#*/}"
    : > "$archive/layers.jsonl"
    # This is a test seed for Docker Desktop's split host/daemon loopback.
    # It also exercises recovery when transport succeeded before a checkpoint.
    jq -r '.[0].Config, .[0].Layers[]' "$archive/manifest.json" > "$archive/blobs"
    while IFS= read -r path; do
        tar -xOf "$archive/image.tar" "$path" > "$archive/blob"
        checksum=$(release_sha256 "$archive/blob")
        bytes=$(candidate_file_size "$archive/blob")
        "$GITHUB_FIXTURE_REAL_CURL" --fail --silent --show-error --max-time 30 \
            --request POST --dump-header "$archive/headers" --output /dev/null "$base/blobs/uploads/"
        location=$(sed -nE 's/^[Ll]ocation: (.*)/\1/p' "$archive/headers" | tr -d '\r')
        [[ "$location" == "$base/blobs/uploads/"* ]] || release_fail 'unexpected fixture upload location'
        separator='?'
        [[ "$location" != *\?* ]] || separator='&'
        "$GITHUB_FIXTURE_REAL_CURL" --fail --silent --show-error --max-time 30 \
            --request PUT --header 'Content-Type: application/octet-stream' \
            --data-binary "@$archive/blob" --output /dev/null "$location${separator}digest=sha256:$checksum"
        if [[ "$path" == */layer.tar ]]; then
            jq -cn --arg digest "sha256:$checksum" --argjson size "$bytes" \
                '{mediaType:"application/vnd.oci.image.layer.v1.tar", digest:$digest, size:$size}' >> "$archive/layers.jsonl"
        else
            jq -n --arg digest "sha256:$checksum" --argjson size "$bytes" \
                '{mediaType:"application/vnd.oci.image.config.v1+json", digest:$digest, size:$size}' > "$archive/config-descriptor.json"
        fi
    done < "$archive/blobs"
    jq -sn --slurpfile config "$archive/config-descriptor.json" --slurpfile layers "$archive/layers.jsonl" \
        '{schemaVersion:2, mediaType:"application/vnd.oci.image.manifest.v1+json", config:$config[0], layers:$layers}' \
        > "$archive/registry-manifest.json"
    "$GITHUB_FIXTURE_REAL_CURL" --fail --silent --show-error --max-time 30 --request PUT \
        --header 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
        --data-binary "@$archive/registry-manifest.json" --output /dev/null \
        "$base/manifests/candidate-$publication_key"
}

check_registry_and_api() {
    local port attempt digest image summary asset_id host_os main_fix descendant prior_key

    host_os=$(uname -s)
    publication_registry_container="kgcache-registry-test-${publication_workspace##*.}"
    timeout 120s docker run --detach --name "$publication_registry_container" \
        --publish 127.0.0.1::5000 \
        --env REGISTRY_LOG_LEVEL=error --env OTEL_TRACES_EXPORTER=none \
        --tmpfs /var/lib/registry:rw,mode=0755 \
        registry:3@sha256:01cd312e67026f06f5d89c3e133a4a9adc7cb9eeb9b1194e0b2954dfd770efd2 > /dev/null
    port=$(docker port "$publication_registry_container" 5000/tcp)
    port="127.0.0.1:${port##*:}"
    publication_registry="$port/fixture/kgcache"
    publication_transport="$publication_registry:candidate-$publication_key"
    for ((attempt = 0; attempt < 50; attempt++)); do
        if "$GITHUB_FIXTURE_REAL_CURL" --fail --silent --max-time 2 "http://$port/v2/" > /dev/null; then break; fi
        sleep 0.1
    done
    "$GITHUB_FIXTURE_REAL_CURL" --fail --silent --max-time 2 "http://$port/v2/" > /dev/null
    mkdir -p "$publication_workspace/http"
    node tests/release/github-api.js "$publication_workspace/http" > "$publication_workspace/http/server.log" 2>&1 &
    publication_api_pid=$!
    for ((attempt = 0; attempt < 50; attempt++)); do
        [[ ! -f "$publication_workspace/http/port" ]] || break
        sleep 0.1
    done
    port=$(cat "$publication_workspace/http/port")
    publication_api="http://127.0.0.1:$port"
    if [[ "$host_os" == Darwin ]]; then seed_registry_transport; fi
    publish_fixture upload > "$publication_workspace/uploaded.json"
    publish_fixture upload > "$publication_workspace/upload-retry.json"
    cmp "$publication_workspace/uploaded.json" "$publication_workspace/upload-retry.json"
    expect_github_failure wrong-registry 'publication destination differs' \
        bash tools/release/publish.sh verify --request "$publication_key" \
        --registry docker.io/fixture/different --record "$publication_workspace/uploaded.json" \
        --candidate "$candidate_test_workspace/good" --output "$publication_workspace/wrong-destination"
    digest=$(jq -r '.registry.uploaded.digest' "$publication_workspace/uploaded.json")
    image=$(jq -r '.candidate.image_id' "$publication_workspace/uploaded.json")
    mkdir "$publication_workspace/verification"
    jq -n --arg image "$image" '{passed:true, image_id:$image, synthetic:true, qualified_amd64:false}' \
        > "$publication_workspace/verification/service.json"
    summary=$(release_sha256 "$publication_workspace/verification/service.json")
    jq -n --slurpfile request "$publication_workspace/uploaded.json" --arg sha "$summary" \
        '{passed:true, synthetic:true, native_amd64:false, digest:$request[0].registry.uploaded.digest,
          request_key:$request[0].request_key, candidate_sha256:$request[0].candidate_sha256,
          image_id:$request[0].candidate.image_id, engine_id:$request[0].registry.intent.engine_id,
          image_absent_before_pull:true, service_sha256:$sha}' \
        > "$publication_workspace/verification/verification.json"
    # Start with one already assigned fixed reference to test partial recovery.
    timeout 60s docker buildx imagetools create --prefer-index=false \
        --tag "$publication_registry:0.2.0" "$publication_registry@$digest" > /dev/null
    publish_fixture promote --verification "$publication_workspace/verification" > "$publication_workspace/promoted.json"
    publish_fixture promote --verification "$publication_workspace/verification" > "$publication_workspace/promote-retry.json"
    cmp "$publication_workspace/promoted.json" "$publication_workspace/promote-retry.json"
    printf 'Passed: real local registry digest/config identity, upload retry, fixed promotion, and partial recovery\n'

    printf '{"method":"POST","path":"/releases/1/assets","after":false}\n' > "$publication_workspace/http/fault.json"
    expect_github_failure partial-assets 'missing complete asset' publish_fixture release
    jq -e '.releases | length == 1 and .[0].draft == true' "$publication_workspace/http/state.json" > /dev/null
    printf '{"method":"PATCH","path":"/releases/1","after":true}\n' > "$publication_workspace/http/fault.json"
    publish_fixture release > "$publication_workspace/released.json"
    publish_fixture release > "$publication_workspace/release-retry.json"
    cmp "$publication_workspace/released.json" "$publication_workspace/release-retry.json"
    jq -e '.latest == null and (.releases | length == 1) and
        .releases[0].draft == false and (.releases[0].assets | length == 4)' \
        "$publication_workspace/http/state.json" > /dev/null
    cp "$publication_workspace/http/state.json" "$publication_workspace/http/clean.json"
    asset_id=$(jq -r '.releases[0].assets[0].id | tostring' "$publication_workspace/http/state.json")
    jq --arg id "$asset_id" '.assets[$id] = ("conflicting bytes" | @base64)' \
        "$publication_workspace/http/clean.json" > "$publication_workspace/http/state.json"
    expect_github_failure conflicting-asset 'release asset bytes conflict' publish_fixture release
    cp "$publication_workspace/http/clean.json" "$publication_workspace/http/state.json"
    printf 'Passed: partial assets, lost publication response, asset conflicts, and exact release retry\n'

    printf '{"method":"PATCH","path":"/releases/1","after":false}\n' > "$publication_workspace/http/fault.json"
    expect_github_failure partial-latest 'cannot read back GitHub latest' publish_fixture aliases
    publish_fixture aliases > "$publication_workspace/complete.json"
    publish_fixture aliases > "$publication_workspace/complete-retry.json"
    cmp "$publication_workspace/complete.json" "$publication_workspace/complete-retry.json"
    jq -e '.status == "complete" and .alias.complete.verified == true' "$publication_workspace/complete.json" > /dev/null
    jq -e '.latest == .releases[0].id' "$publication_workspace/http/state.json" > /dev/null
    printf 'Passed: partial latest recovery and completed-request verification\n'

    git -C "$fixture_repo" switch --quiet main
    jq '.lines[0].status = "supported"' "$fixture_repo/.github/release-lines.json" > "$publication_workspace/policy.json"
    cp "$publication_workspace/policy.json" "$fixture_repo/.github/release-lines.json"
    fixture_commit 'chore: support completed fixture line' > /dev/null
    git -C "$fixture_repo" push --quiet "$publication_remote" main
    publication_key=$(jq -r '.request_key' "$publication_workspace/patch.json")
    rm "$publication_workspace/git-fault/used"
    GIT_FIXTURE_MODE=conflict PATH="$publication_workspace/git-fault:$PATH" \
        expect_github_failure stale-state 'state write conflict or failed push' \
        coordinate_fixture allocate --request "$publication_key"
    coordinate_fixture allocate --request "$publication_key" > "$publication_workspace/allocated-patch.json"
    jq -e '.version == "0.2.1"' "$publication_workspace/allocated-patch.json" > /dev/null
    printf 'Passed: the next reviewed source receives the next patch version\n'

    printf 'synthetic qualification failure\n' > "$publication_workspace/failure.txt"
    coordinate_fixture fail --request "$publication_key" --failure "$publication_workspace/failure.txt" > /dev/null
    coordinate_fixture allocate --request "$publication_key" > "$publication_workspace/retried-patch.json"
    jq -e '.version == "0.2.1" and .status == "admitted" and .proposal.reused == true' \
        "$publication_workspace/retried-patch.json" > /dev/null
    coordinate_fixture fail --request "$publication_key" --failure "$publication_workspace/failure.txt" > /dev/null
    prior_key=$publication_key
    printf 'corrected behavior\n' > "$fixture_repo/another-fix.txt"
    main_fix=$(fixture_commit 'fix: correct fixture qualification')
    fixture_pr 4 "$main_fix" main 2026-10-20T00:00:07Z
    git -C "$fixture_repo" switch --quiet --detach "$fixture_backport"
    git -C "$fixture_repo" cherry-pick -x "$main_fix" > /dev/null
    descendant=$(git -C "$fixture_repo" rev-parse HEAD)
    fixture_pr 5 "$descendant" release/0.2 2026-10-20T00:00:08Z
    git -C "$fixture_repo" update-ref refs/heads/release/0.2 "$descendant"
    git -C "$fixture_repo" push --quiet "$publication_remote" main release/0.2
    jq --arg before "$fixture_backport" --arg source "$descendant" '.before = $before | .after = $source' \
        "$github_test_workspace/update.json" > "$publication_workspace/descendant-event.json"
    coordinate_fixture enqueue --event "$publication_workspace/descendant-event.json" \
        --event-name push --source "$descendant" > "$publication_workspace/descendant.json"
    publication_key=$(jq -r '.request_key' "$publication_workspace/descendant.json")
    coordinate_fixture allocate --request "$publication_key" > "$publication_workspace/superseding.json"
    jq -e --arg old "$prior_key" '.version == "0.2.1" and .proposal.supersedes == [$old]' \
        "$publication_workspace/superseding.json" > /dev/null
    expect_github_failure superseded-retry 'request was superseded' coordinate_fixture allocate --request "$prior_key"
    printf 'Passed: failed qualification retry and reviewed descendant reuse without another tag\n'
    check_merged_release_publication
    check_merged_release_publication manual v0.4.0-rc.1 'Manual candidate notes.'
    check_merged_release_publication automatic v0.5.0-rc.1 'Initial release candidate for 0.5.0.'
}

check_publication_protections() {
    mutate_api merge-ruleset.json '.bypass_actors = [{actor_id: 1, actor_type: "RepositoryRole", bypass_mode: "always"}]'
    expect_github_failure bypassable 'bypassable merge rules' coordinate_fixture enqueue \
        --event "$github_test_workspace/create.json" --event-name push --source "$fixture_cut"
    restore_api merge-ruleset.json
    mutate_api merge-rules.json 'map(select(.type != "required_status_checks"))'
    expect_github_failure missing-checks 'missing required status checks' coordinate_fixture enqueue \
        --event "$github_test_workspace/create.json" --event-name push --source "$fixture_cut"
    restore_api merge-rules.json
    mutate_api merge-rules.json 'map(if .type == "pull_request" then .parameters.allowed_merge_methods = ["squash", "merge"] else . end)'
    expect_github_failure merge-method 'missing required PR review protections' coordinate_fixture enqueue \
        --event "$github_test_workspace/create.json" --event-name push --source "$fixture_cut"
    restore_api merge-rules.json
    mutate_api merge-rules.json 'map(select(.type != "pull_request"))'
    expect_github_failure missing-pr 'missing required PR review protections' coordinate_fixture enqueue \
        --event "$github_test_workspace/create.json" --event-name push --source "$fixture_cut"
    restore_api merge-rules.json
    mutate_api merge-rules.json 'map(select(.type != "deletion"))'
    expect_github_failure deletable-branch 'missing branch history protections' coordinate_fixture enqueue \
        --event "$github_test_workspace/create.json" --event-name push --source "$fixture_cut"
    restore_api merge-rules.json
    mutate_api merge-rules.json 'map(select(.type != "non_fast_forward"))'
    expect_github_failure force-pushable-branch 'missing branch history protections' coordinate_fixture enqueue \
        --event "$github_test_workspace/create.json" --event-name push --source "$fixture_cut"
    restore_api merge-rules.json
    mutate_api state-ruleset.json '.bypass_actors = []'
    expect_github_failure writable-state 'only the publisher app' coordinate_fixture enqueue \
        --event "$github_test_workspace/create.json" --event-name push --source "$fixture_cut"
    restore_api state-ruleset.json
    expect_github_failure fixture-remote 'existing local bare repository' \
        bash tools/release/coordinate.sh init --fixture --remote https://github.com/fixture/kgcache.git \
        --repository fixture/kgcache
    expect_github_failure real-fixture 'fixture/' bash tools/release/coordinate.sh init --fixture \
        --remote "$publication_remote" --repository kgxlabs/kgcache
    printf 'Passed: missing protections and remote fixture escapes fail closed\n'
}

check_owner_review_rules() {
    jq -n --slurpfile rules "$fixture_api/merge-rules.json" \
        --slurpfile ruleset "$fixture_api/merge-ruleset.json" \
        '{effective: (($rules[0] | map(if .type == "pull_request" then
            .parameters.required_approving_review_count = 0 else . end)) +
          [$rules[0][] | select(.type == "pull_request") | .ruleset_id = 4]),
          rulesets: [$ruleset[0], {id: 4, target: "branch", enforcement: "active",
            bypass_actors: [{actor_id: 101, actor_type: "User", bypass_mode: "pull_request"}]}]}' \
        > "$publication_workspace/owner-rules.json"
    jq -e -L "$RELEASE_ROOT/tools/release" 'include "publication";
        {login: "maintainer", id: 101} as $owner |
        [{context: "PR title", integration_id: 15368}] as $checks |
        (validate_merge_rules($checks; $owner)) and
        (try (validate_merge_rules($checks) | false) catch true) and
        (try (.rulesets[1].bypass_actors[0].actor_id = 202 |
          validate_merge_rules($checks; $owner) | false) catch true) and
        (try (.rulesets[1].bypass_actors[0].bypass_mode = "always" |
          validate_merge_rules($checks; $owner) | false) catch true) and
        (try (.rulesets[1].bypass_actors += [{actor_id: 202, actor_type: "User", bypass_mode: "pull_request"}] |
          validate_merge_rules($checks; $owner) | false) catch true) and
        (try (.effective += [{type: "required_status_checks", ruleset_id: 4}] |
          validate_merge_rules($checks; $owner) | false) catch true) and
        (try (.effective |= map(select(.ruleset_id != 4)) |
          validate_merge_rules($checks; $owner) | false) catch true) and
        (try (.effective |= map(if .type == "pull_request" and .ruleset_id == 1 then
            .parameters.required_review_thread_resolution = false else . end) |
          validate_merge_rules($checks; $owner) | false) catch true)' \
        "$publication_workspace/owner-rules.json" > /dev/null
    printf 'Passed: owner review bypass cannot bypass CI or branch protections\n'
}

main() {
    local docker_checks=false

    if [[ "${1:-}" == --docker && $# == 1 ]]; then
        docker_checks=true
    elif [[ $# != 0 ]]; then release_fail 'usage: bash tests/release/publication.sh [--docker]'; fi
    release_require_commands git jq timeout curl mktemp tar gzip cmp
    trap cleanup_publication_tests EXIT
    publication_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-publication-tests.XXXXXX")
    github_test_workspace="$publication_workspace/github"
    github_test_logs="$publication_workspace/logs"
    publication_remote="$publication_workspace/remote.git"
    mkdir -p "$github_test_workspace" "$github_test_logs"
    GITHUB_FIXTURE_REAL_CURL=$(command -v curl)
    export GITHUB_FIXTURE_REAL_CURL
    setup_github_fixture
    setup_publication_rules
    check_publication_requests
    check_clean_pull
    check_publication_protections
    check_owner_review_rules
    check_merged_release_prs
    check_initial_release manual
    check_initial_release automatic
    check_alias_precedence
    if [[ "$docker_checks" == true ]]; then check_registry_and_api; fi
    printf 'Publication contracts passed with local Git fixtures. No external writes.\n'
}

main "$@"

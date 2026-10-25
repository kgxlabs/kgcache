#!/usr/bin/env bash
# Build one image from a clean selected commit and retain its tested content.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"
source "${BASH_SOURCE[0]%/*}/candidate-common.sh"

candidate_workspace=
candidate_output=
candidate_tag=
candidate_container=
candidate_phase=initialization

cleanup_candidate() {
    local exit_status=$? failed=false log category

    trap - EXIT
    if [[ -n "$candidate_container" ]]; then
        timeout --signal=TERM --kill-after=2s 5s docker rm --force "$candidate_container" > /dev/null 2>&1 || failed=true
    fi
    if [[ -n "$candidate_tag" ]]; then
        timeout --signal=TERM --kill-after=2s 5s docker image rm "$candidate_tag" > /dev/null 2>&1 || failed=true
    fi
    if [[ -n "$candidate_output" && "$exit_status" != 0 ]]; then
        rm -f "$candidate_output/candidate.json" "$candidate_output/SHA256SUMS" || failed=true
        jq -n --arg phase "$candidate_phase" --argjson status "$exit_status" \
            '{schema_version: 1, passed: false, publishable: false, phase: $phase, exit_status: $status}' \
            > "$candidate_output/failure.json" || failed=true
        if [[ -n "$candidate_workspace" && -d "$candidate_workspace/logs" ]]; then
            for log in "$candidate_workspace/logs/"*.log; do
                [[ -f "$log" ]] || continue
                tail -c 65536 "$log" > "$candidate_output/evidence/logs/${log##*/}" || failed=true
            done
        fi
        for category in source-evidence client-evidence runtime service; do
            if [[ -d "$candidate_workspace/$category" ]]; then
                # The collector checks each command explicitly so cleanup can
                # continue after an evidence-copy failure.
                # shellcheck disable=SC2310
                candidate_collect_evidence "$candidate_workspace/$category" "$category" || failed=true
            fi
        done
        if [[ -d "$candidate_workspace/source/.git" ]]; then
            git -C "$candidate_workspace/source" status --porcelain --untracked-files=normal \
                > "$candidate_output/evidence/source-status.log" || failed=true
        fi
    fi
    if [[ -n "$candidate_workspace" ]]; then
        rm -rf -- "$candidate_workspace" || failed=true
    fi
    if [[ "$exit_status" == 0 && "$failed" == true ]]; then
        rm -f "$candidate_output/candidate.json" "$candidate_output/SHA256SUMS"
        exit_status=1
    fi
    exit "$exit_status"
}

candidate_run_phase() {
    local name=$1 deadline=$2 exit_status=0 log="$candidate_workspace/logs/$1.log"

    shift 2
    candidate_phase=$name
    printf 'Candidate check: %s\n' "$name"
    timeout --signal=TERM --kill-after=10s "$deadline" "$@" > "$log" 2>&1 || exit_status=$?
    tail -c 65536 "$log" > "$candidate_output/evidence/logs/$name.log"
    if [[ "$exit_status" != 0 ]]; then
        cat "$candidate_output/evidence/logs/$name.log" >&2
        release_fail "candidate check failed: $name (status $exit_status)"
    fi
    jq -cn --arg name "$name" '{name: $name, passed: true, log: ("evidence/logs/" + $name + ".log")}' \
        >> "$candidate_workspace/checks.jsonl"
}

candidate_collect_evidence() {
    local input=$1 category=$2 file relative destination bytes

    find "$input" -type f -print0 > "$candidate_workspace/evidence-files" || return 1
    while IFS= read -r -d '' file; do
        relative=${file#"$input/"}
        # Keep JSON evidence intact. Bound text logs, without retaining runtime
        # persistence files or unbounded binary fixture data in the handoff.
        case "$relative" in
            *.json | *.log | *.stdout | *.stderr | *.txt) ;;
            *) continue ;;
        esac
        destination="$candidate_output/evidence/$category/$relative"
        mkdir -p "${destination%/*}" || return 1
        if [[ "$relative" == *.json ]]; then
            # This helper checks its read failure explicitly; return the error
            # so the EXIT trap can continue cleaning other resources.
            # shellcheck disable=SC2310
            bytes=$(candidate_file_size "$file") || return 1
            [[ "$bytes" -le 1048576 ]] || return 1
            cp "$file" "$destination" || return 1
        else tail -c 65536 "$file" > "$destination" || return 1; fi
    done < "$candidate_workspace/evidence-files"
}

main() {
    local proposal='' request_evidence='' repo="$RELEASE_ROOT" artifacts="$RELEASE_ROOT/test-artifacts/release/candidates"
    local allow_emulation=false source source_sha version development mode host engine arch os
    local compiler image runtime_result service_result tooling_revision tooling_dirty=false tooling_sha
    local archive_sha archive_bytes path sha bytes total=0 count=0 attempt=${GITHUB_RUN_ATTEMPT:-1}
    local current_policy tooling_status run_id actual expected
    local runtime_args=() service_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proposal | --request-evidence | --repo | --artifacts)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --proposal) proposal=$2 ;;
                    --request-evidence) request_evidence=$2 ;;
                    --repo) repo=$2 ;;
                    --artifacts) artifacts=$2 ;;
                esac
                shift 2
                ;;
            --allow-emulation)
                allow_emulation=true
                shift
                ;;
            --help)
                printf 'Usage: bash tools/release/qualify.sh --proposal FILE [--request-evidence FILE] [--repo DIR] [--artifacts DIR] [--allow-emulation]\n'
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done
    [[ -n "$proposal" ]] || release_fail '--proposal is required'
    release_require_commands git jq docker timeout bash make tar gzip find head tail wc sort uniq cmp cut mktemp file
    release_require_sha256
    candidate_validate_proposal "$proposal"
    source_sha=$(release_read_field "$proposal" .source_sha)
    version=$(release_read_field "$proposal" .version)
    mode=$(release_read_field "$proposal" .mode)
    actual=$(git --no-replace-objects -C "$repo" cat-file -t "$source_sha")
    [[ "$actual" == commit ]] || release_fail 'selected source commit is missing'
    development=$(git --no-replace-objects -C "$repo" show "$source_sha:build.zig.zon" |
        sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p')
    expected=$(release_read_field "$proposal" .development_version)
    [[ "$development" == "$expected" ]] ||
        release_fail 'selected development version differs from proposal'
    tooling_revision=$(git -C "$RELEASE_ROOT" rev-parse HEAD)
    tooling_sha=$(release_sha256 "$RELEASE_ROOT/tools/release/qualify.sh")
    tooling_status=$(git -C "$RELEASE_ROOT" status --porcelain --untracked-files=normal)
    [[ -z "$tooling_status" ]] || tooling_dirty=true
    if [[ "$mode" == branch || "$mode" == release ]]; then
        current_policy=$(git --no-replace-objects -C "$repo" rev-parse refs/remotes/origin/main)
        expected=$(release_read_field "$proposal" .policy_sha)
        [[ "$mode" == release || "$current_policy" == "$expected" ]] ||
            release_fail 'main policy changed; refresh the proposal before qualification'
        [[ "$tooling_revision" == "$source_sha" && "$tooling_dirty" == false ]] ||
            release_fail 'branch qualification must run from the clean selected tooling commit'
    fi
    arch=$(uname -m)
    os=$(uname -s)
    case "$arch" in
        x86_64 | amd64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) release_fail 'unsupported source-test host architecture' ;;
    esac
    case "$os" in
        Linux) host="linux/$arch" ;;
        Darwin) host="darwin/$arch" ;;
        *) release_fail 'source checks require Linux or macOS' ;;
    esac
    engine=$(candidate_engine)
    [[ "$allow_emulation" == true || ("$host" == linux/amd64 && "$engine" == linux/amd64) ]] ||
        release_fail 'native Linux amd64 source host and engine required; use --allow-emulation for local smoke checks'

    trap cleanup_candidate EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$artifacts"
    artifacts=$(cd "$artifacts" && pwd -P)
    candidate_output=$(mktemp -d "$artifacts/run.XXXXXX")
    candidate_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-candidate.XXXXXX")
    mkdir -p "$candidate_workspace/logs" "$candidate_output/evidence/logs" "$candidate_output/evidence/reports"
    candidate_tooling_inventory > "$candidate_workspace/tooling.jsonl"
    jq -s . "$candidate_workspace/tooling.jsonl" > "$candidate_output/evidence/tooling.json"
    printf 'Candidate evidence: %s\n' "$candidate_output"
    cp "$proposal" "$candidate_output/proposal.json"
    if [[ -n "$request_evidence" ]]; then
        candidate_validate_request "$candidate_output/proposal.json" "$request_evidence"
        cp "$request_evidence" "$candidate_output/evidence/request.json"
        candidate_validate_request "$candidate_output/proposal.json" "$candidate_output/evidence/request.json"
    fi
    proposal="$candidate_output/proposal.json"
    source="$candidate_workspace/source"
    candidate_checkout_source "$repo" "$source_sha" "$source" "$RELEASE_ROOT"
    export PATH="$source/.client-tools/go/bin:$source/.client-tools/node/bin:$PATH"
    export GOTOOLCHAIN=local GOWORK=off
    unset GO_TEST_ARGS NODE_TEST_ARGS CLIENT_PROFILE CLIENT_LIBRARY KGCACHE_TEST_CONTROL
    compiler=$(cd "$source" && bash tools/release/zig.sh --print-path)
    cd "$source"
    export KGCACHE_TEST_ARTIFACT_DIR="$candidate_workspace/source-evidence"
    candidate_run_phase source-unit 600s "$compiler" build test "-Dversion=$version" -Doptimize=ReleaseSafe
    candidate_run_phase source-process 600s "$compiler" build test-integration "-Dversion=$version" -Doptimize=ReleaseSafe
    candidate_run_phase source-build 600s env ZIG="$compiler" bash tests/build/run.sh
    candidate_run_phase source-arm64 600s bash tools/release/build.sh --platform linux/arm64 --version "$version"
    candidate_run_phase source-proposals 300s bash tests/release/proposals.sh
    if [[ -f tests/release/candidates.sh ]]; then
        candidate_run_phase candidate-contracts 300s bash tests/release/candidates.sh
    fi
    if [[ -f tests/release/github.sh ]]; then
        candidate_run_phase github-contracts 300s bash tests/release/github.sh
    fi
    candidate_run_phase source-failures 180s bash tests/release/failures.sh --docker
    candidate_run_phase source-shell 300s make check-shell
    candidate_run_phase client-prepare 600s make deps-clients
    candidate_run_phase client-quality 600s make check-clients

    candidate_assert_checkout "$source" "$source_sha"
    candidate_tag="kgcache-candidate:${candidate_workspace##*.}"
    # The image build has an explicit output file, so no shell pipeline or tag
    # lookup can silently choose a different image after this point.
    candidate_run_phase image-build 650s docker build \
        --platform linux/amd64 \
        --build-arg "SOURCE_REVISION=$source_sha" \
        --build-arg SOURCE_DIRTY=false \
        --build-arg "VERSION=$version" \
        --label "io.kgcache.candidate=${candidate_output##*/}" \
        --iidfile "$candidate_workspace/image-id" \
        --tag "$candidate_tag" "$source"
    image=$(cat "$candidate_workspace/image-id")
    candidate_container="kgcache-candidate-${candidate_workspace##*.}"
    candidate_docker create --name "$candidate_container" --platform linux/amd64 --network none \
        --entrypoint /usr/local/bin/kgcache "$image" --version > /dev/null
    mkdir -p "$candidate_workspace/artifact/bin"
    candidate_docker cp "$candidate_container:/usr/local/bin/kgcache" "$candidate_workspace/artifact/bin/kgcache"
    candidate_docker cp "$candidate_container:/usr/share/kgcache/build-info.json" "$candidate_workspace/artifact/build-info.json"
    # The image record is 0444. Artifact rejection tests mutate owned host
    # copies, so make this extracted record writable without changing its bytes.
    chmod u+w "$candidate_workspace/artifact/build-info.json"
    candidate_docker rm "$candidate_container" > /dev/null
    candidate_container=
    cp "$candidate_workspace/artifact/build-info.json" "$candidate_output/build-info.json"
    candidate_docker image inspect "$image" > "$candidate_output/evidence/image.json"
    candidate_container="kgcache-candidate-${candidate_workspace##*.}"
    candidate_inspect_image "$image" "$candidate_output" "$candidate_container" "$candidate_workspace/inspected"
    candidate_container=
    jq -e --slurpfile proposal "$proposal" '.source.revision == $proposal[0].source_sha and
        .source.dirty == false and .version == $proposal[0].version and
        .development_version == $proposal[0].development_version' \
        "$candidate_output/build-info.json" > /dev/null || release_fail 'built image differs from proposal'
    candidate_run_phase image-artifact 600s bash tests/release/artifact.sh "$candidate_workspace/artifact"
    runtime_args=(--prefix "$candidate_workspace/artifact" --artifacts "$candidate_workspace/runtime")
    service_args=(--image "$image" --artifacts "$candidate_workspace/service")
    if [[ "$allow_emulation" == true ]]; then
        runtime_args+=(--allow-emulation)
        service_args+=(--allow-emulation)
    fi
    candidate_run_phase image-runtime 900s bash tests/release/run.sh "${runtime_args[@]}"
    candidate_run_phase image-service 1900s bash tests/container/run.sh "${service_args[@]}"
    set -- "$candidate_workspace/runtime/"run.*/result.json
    [[ $# == 1 && -f "$1" ]] || release_fail 'missing unique runtime result'
    runtime_result=$1
    set -- "$candidate_workspace/service/"run.*/result.json
    [[ $# == 1 && -f "$1" ]] || release_fail 'missing unique service result'
    service_result=$1
    cp "$runtime_result" "$candidate_output/evidence/reports/runtime.json"
    cp "$service_result" "$candidate_output/evidence/reports/service.json"
    if [[ "$host" == linux/amd64 ]]; then
        export KGCACHE_BIN="$candidate_workspace/artifact/bin/kgcache"
    else export KGCACHE_BIN="$source/zig-out/bin/kgcache"; fi
    export KGCACHE_TEST_ARTIFACT_DIR="$candidate_workspace/client-evidence"
    candidate_run_phase client-go 900s "${GO:-go}" run tests/integration/clients/go/run.go test
    candidate_run_phase client-node 900s "${NODE:-node}" --experimental-strip-types tests/integration/clients/node/run.ts test
    candidate_collect_evidence "$candidate_workspace/runtime" runtime
    candidate_collect_evidence "$candidate_workspace/service" service
    if [[ -d "$candidate_workspace/source-evidence" ]]; then
        candidate_collect_evidence "$candidate_workspace/source-evidence" source
    fi
    if [[ -d "$candidate_workspace/client-evidence" ]]; then
        candidate_collect_evidence "$candidate_workspace/client-evidence" clients
    fi
    cp tests/integration/clients/matrix.json "$candidate_output/evidence/client-matrix.json"
    candidate_assert_checkout "$source" "$source_sha"
    candidate_tooling_inventory > "$candidate_workspace/tooling-final.jsonl"
    jq -s . "$candidate_workspace/tooling-final.jsonl" > "$candidate_workspace/tooling-final.json"
    cmp "$candidate_output/evidence/tooling.json" "$candidate_workspace/tooling-final.json" ||
        release_fail 'qualification tooling changed during the run'

    candidate_phase='image-export'
    timeout --signal=TERM --kill-after=10s 180s docker image save \
        --output "$candidate_workspace/image.tar" "$image"
    timeout --signal=TERM --kill-after=5s 120s gzip -n -c "$candidate_workspace/image.tar" \
        > "$candidate_output/kgcache-linux-amd64.docker.tar.gz"
    archive_sha=$(release_sha256 "$candidate_output/kgcache-linux-amd64.docker.tar.gz")
    archive_bytes=$(candidate_file_size "$candidate_output/kgcache-linux-amd64.docker.tar.gz")
    find "$candidate_output/evidence" -type f -print0 > "$candidate_workspace/evidence-files"
    : > "$candidate_workspace/evidence.jsonl"
    while IFS= read -r -d '' path; do
        sha=$(release_sha256 "$path")
        bytes=$(candidate_file_size "$path")
        total=$((total + bytes))
        count=$((count + 1))
        [[ "$bytes" -le 1048576 && "$total" -le 33554432 && "$count" -le 512 ]] ||
            release_fail 'candidate evidence exceeds its limits'
        jq -cn --arg path "${path#"$candidate_output/"}" --arg sha "$sha" --argjson bytes "$bytes" \
            '{path: $path, sha256: $sha, bytes: $bytes}' >> "$candidate_workspace/evidence.jsonl"
    done < "$candidate_workspace/evidence-files"
    run_id=${GITHUB_RUN_ID:-${candidate_output##*/}}
    jq -n \
        --slurpfile proposal "$proposal" \
        --slurpfile build "$candidate_output/build-info.json" \
        --slurpfile checks "$candidate_workspace/checks.jsonl" \
        --slurpfile evidence "$candidate_workspace/evidence.jsonl" \
        --slurpfile matrix tests/integration/clients/matrix.json \
        --slurpfile service "$service_result" \
        --arg image "$image" \
        --arg archive_sha "$archive_sha" \
        --argjson archive_bytes "$archive_bytes" \
        --arg tooling_revision "$tooling_revision" \
        --argjson tooling_dirty "$tooling_dirty" \
        --arg tooling_sha "$tooling_sha" \
        --arg run_id "$run_id" \
        --arg attempt "$attempt" \
        --arg workflow_ref "${GITHUB_WORKFLOW_REF:-local}" \
        --arg workflow_sha "${GITHUB_WORKFLOW_SHA:-$tooling_revision}" \
        --arg host "$host" \
        --arg engine "$engine" \
        --from-file "$RELEASE_ROOT/tools/release/create-candidate.jq" > "$candidate_output/candidate.json"
    jq -r '"candidate.json", "proposal.json", "build-info.json", .archive.path, .evidence[].path' \
        "$candidate_output/candidate.json" > "$candidate_workspace/files"
    : > "$candidate_output/SHA256SUMS"
    while IFS= read -r path; do
        sha=$(release_sha256 "$candidate_output/$path")
        printf '%s  %s\n' "$sha" "$path" >> "$candidate_output/SHA256SUMS"
    done < "$candidate_workspace/files"
    candidate_phase='bundle-verification'
    candidate_snapshot_bundle "$candidate_output" "$candidate_workspace/verified"
    candidate_check_archive "$candidate_workspace/verified" "$candidate_workspace/archive-check"
    printf 'Candidate retained: %s\n' "$candidate_output"
}

main "$@"

#!/usr/bin/env bash
# Publish retained content. Every remote write follows a durable intent.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/common.sh"
source "${BASH_SOURCE[0]%/*}/candidate-common.sh"

publish_workspace=
publish_container=
publish_remote=
publish_repository=
publish_request=
publish_fixture=false
publish_registry=

cleanup_publish() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "$publish_container" ]]; then
        timeout 10s docker rm --force "$publish_container" > /dev/null 2>&1 || exit_status=1
    fi
    [[ -z "$publish_workspace" ]] || rm -rf -- "$publish_workspace"
    exit "$exit_status"
}

publish_coordinate() {
    local operation=$1
    local options=()

    shift
    [[ "$publish_fixture" == false ]] || options=(--fixture)
    bash "$RELEASE_ROOT/tools/release/coordinate.sh" "$operation" \
        --remote "$publish_remote" --repository "$publish_repository" \
        ${options[@]+"${options[@]}"} "$@"
}

publish_checkpoint() {
    local phase=$1 value=$2

    jq -n --arg phase "$phase" --slurpfile value "$value" \
        '{phase: $phase, value: $value[0]}' > "$publish_workspace/change.json"
    publish_coordinate checkpoint --request "$publish_request" \
        --checkpoint "$publish_workspace/change.json" > "$publish_workspace/request.json"
}

publish_authorize() {
    publish_coordinate tag --request "$publish_request" --candidate "$publish_workspace/bundle" \
        > "$publish_workspace/authorized.json"
}

publish_docker() {
    timeout --signal=TERM --kill-after=10s 300s docker "$@"
}

# Only a registry's explicit missing-manifest response means absence.
# Authentication errors, timeouts, and malformed content stop publication.
publish_manifest() {
    local ref=$1 output=$2 exit_status
    local options=()

    [[ "$publish_fixture" == false ]] || options=(--insecure)
    # The wrapper runs one Docker command. Handle its error explicitly here.
    # shellcheck disable=SC2310
    if publish_docker manifest inspect ${options[@]+"${options[@]}"} "$ref" > "$output.raw" 2> "$output.log"; then
        :
    else
        exit_status=$?
        if rg -q 'manifest unknown|no such manifest' "$output.log"; then
            printf 'null\n' > "$output"
            return
        fi
        cat "$output.log" >&2
        return "$exit_status"
    fi
    publish_docker buildx imagetools inspect "$ref" --raw > "$output.raw"
    publish_docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' > "$output.descriptor"
    jq -e --slurpfile raw "$output.raw" \
        '.digest as $digest | ($digest | test("^sha256:[0-9a-f]{64}$")) and
         (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
          .mediaType == "application/vnd.docker.distribution.manifest.v2+json") and
         $raw[0].schemaVersion == 2 and $raw[0].mediaType == .mediaType and
         ($raw[0].config.digest | test("^sha256:[0-9a-f]{64}$")) and
         ($raw[0].layers | length > 0)' "$output.descriptor" > /dev/null ||
        release_fail 'registry must expose one supported image manifest'
    jq --slurpfile raw "$output.raw" '{digest, media_type: .mediaType, config_digest: $raw[0].config.digest}' \
        "$output.descriptor" > "$output"
}

publish_fixed() {
    local tag=$1 digest=$2 current

    publish_manifest "$publish_registry:$tag" "$publish_workspace/fixed.json"
    current=$(jq -r '.digest // empty' "$publish_workspace/fixed.json")
    [[ -z "$current" || "$current" == "$digest" ]] || release_fail "fixed image reference conflicts: $tag"
    if [[ -z "$current" ]]; then
        publish_authorize
        # Reconcile even if the client loses the successful write response.
        # A failed client response is reconciled by the registry read below.
        # shellcheck disable=SC2310
        if publish_docker buildx imagetools create --prefer-index=false \
            --tag "$publish_registry:$tag" "$publish_registry@$digest" \
            > "$publish_workspace/promote.log" 2>&1; then :; fi
    fi
    publish_manifest "$publish_registry:$tag" "$publish_workspace/fixed.json"
    current=$(jq -r '.digest // empty' "$publish_workspace/fixed.json")
    [[ "$current" == "$digest" ]] || release_fail "fixed reference read-back failed: $tag"
}

publish_upload() {
    local image engine transport digest intent

    image=$(jq -r '.candidate.image_id' "$publish_workspace/request.json")
    engine=$(publish_docker info --format '{{.ID}}')
    transport="candidate-$publish_request"
    if jq -e '.registry.intent != null' "$publish_workspace/request.json" > /dev/null; then
        jq '.registry.intent' "$publish_workspace/request.json" > "$publish_workspace/intent.json"
    else
        jq -n --arg repository "$publish_registry" --arg transport "$transport" --arg engine "$engine" \
            --slurpfile request "$publish_workspace/request.json" \
            '{repository: $repository, transport: $transport, engine_id: $engine,
              image_id: $request[0].candidate.image_id, candidate_sha256: $request[0].candidate_sha256}' \
            > "$publish_workspace/intent.json"
        publish_checkpoint registry_intent "$publish_workspace/intent.json"
    fi
    intent=$(jq -r '.repository' "$publish_workspace/intent.json")
    [[ "$intent" == "$publish_registry" ]] || release_fail 'registry differs from original upload intent'
    publish_manifest "$publish_registry:$transport" "$publish_workspace/uploaded.json"
    if jq -e '. == null' "$publish_workspace/uploaded.json" > /dev/null; then
        # The validated archive is the only source of transport content.
        # The read-only transfer job already executed and inspected this image.
        # The credentialed publisher only loads the checked archive and uploads.
        publish_docker image load --input "$publish_workspace/archive/image.tar" > /dev/null
        publish_docker image tag "$image" "$publish_registry:$transport"
        publish_authorize
        # The next read reconciles a failed or lost client response.
        # shellcheck disable=SC2310
        if publish_docker image push "$publish_registry:$transport" > "$publish_workspace/push.log" 2>&1; then :; fi
        publish_manifest "$publish_registry:$transport" "$publish_workspace/uploaded.json"
    fi
    jq -e --arg image "$image" '.config_digest == $image' "$publish_workspace/uploaded.json" > /dev/null || {
        [[ ! -f "$publish_workspace/push.log" ]] || tail -c 65536 "$publish_workspace/push.log" >&2
        cat "$publish_workspace/uploaded.json" >&2
        release_fail "transport content differs from the qualified image: $image"
    }
    digest=$(jq -r '.digest' "$publish_workspace/uploaded.json")
    publish_manifest "$publish_registry@$digest" "$publish_workspace/digest.json"
    cmp "$publish_workspace/uploaded.json" "$publish_workspace/digest.json" || release_fail 'transport digest read-back differs'
    publish_checkpoint uploaded "$publish_workspace/uploaded.json"
}

# This command has no write credential and makes no ledger or registry writes.
# Run it on a fresh native runner, before importing any saved archive.
publish_verify() {
    local output=$1 image engine digest old_engine actual summary

    image=$(jq -r '.candidate.image_id' "$publish_workspace/request.json")
    digest=$(jq -r '.registry.uploaded.digest' "$publish_workspace/request.json")
    old_engine=$(jq -r '.registry.intent.engine_id' "$publish_workspace/request.json")
    engine=$(publish_docker info --format '{{.ID}}')
    [[ "$engine" != "$old_engine" && -n "$engine" ]] || release_fail 'clean pull requires a different Docker engine'
    # This is an intentional absence check around the single Docker command.
    # shellcheck disable=SC2310
    if publish_docker image inspect "$image" > /dev/null 2>&1; then
        release_fail 'qualified image is already present; use a fresh image store'
    fi
    actual=$(candidate_engine)
    [[ "$actual" == linux/amd64 ]] || release_fail 'registry qualification requires native Linux amd64'
    publish_docker image pull --platform linux/amd64 "$publish_registry@$digest" > "$publish_workspace/pull.log"
    actual=$(publish_docker image inspect "$publish_registry@$digest" --format '{{.Id}}')
    [[ "$actual" == "$image" ]] || release_fail 'pulled image differs from retained candidate'
    publish_container="kgcache-registry-${publish_workspace##*.}"
    candidate_inspect_image "$image" "$publish_workspace/bundle" "$publish_container" "$publish_workspace/image"
    publish_container=
    bash "$RELEASE_ROOT/tests/container/run.sh" --image "$publish_registry@$digest" \
        --artifacts "$publish_workspace/service"
    set -- "$publish_workspace"/service/run.*/result.json
    [[ $# == 1 && -f "$1" ]] || release_fail 'missing registry service result'
    summary=$1
    jq -e --arg image "$image" '.passed == true and .qualified_amd64 == true and
        .image_id == $image and .compose.passed == true' "$summary" > /dev/null
    mkdir -p "$output"
    cp "$summary" "$output/service.json"
    actual=$(release_sha256 "$output/service.json")
    jq -n --arg digest "$digest" --arg image "$image" --arg engine "$engine" --arg summary "$actual" \
        --slurpfile request "$publish_workspace/request.json" \
        '{passed: true, digest: $digest, image_id: $image, engine_id: $engine,
          native_amd64: true, synthetic: false,
          candidate_sha256: $request[0].candidate_sha256, service_sha256: $summary,
          request_key: $request[0].request_key}' > "$output/verification.json"
}

publish_promote() {
    local verification=$1 digest version source_key actual tag

    if jq -e '.registry.verified == null' "$publish_workspace/request.json" > /dev/null; then
        actual=$(release_sha256 "$verification/service.json")
        jq -e --arg sha "$actual" --arg key "$publish_request" --argjson fixture "$publish_fixture" \
            '.passed == true and .request_key == $key and .service_sha256 == $sha and
         ($fixture or (.native_amd64 == true and .synthetic == false))' \
            "$verification/verification.json" > /dev/null || release_fail 'verification receipt differs'
        jq -e --slurpfile request "$publish_workspace/request.json" --argjson fixture "$publish_fixture" \
            '.passed == true and .image_id == $request[0].candidate.image_id and
          ($fixture or (.qualified_amd64 == true and .compose.passed == true))' \
            "$verification/service.json" > /dev/null || release_fail 'registry service qualification differs'
        publish_checkpoint verified "$verification/verification.json"
    fi
    digest=$(jq -r '.registry.uploaded.digest' "$publish_workspace/request.json")
    version=$(jq -r '.proposal.image.version_tag' "$publish_workspace/request.json")
    source_key=$(jq -r '.proposal.image.source_version_key' "$publish_workspace/request.json")
    # Read both fixed targets before assigning either of them.
    for tag in "$version" "src-$source_key"; do
        publish_manifest "$publish_registry:$tag" "$publish_workspace/fixed.json"
        actual=$(jq -r '.digest // empty' "$publish_workspace/fixed.json")
        [[ -z "$actual" || "$actual" == "$digest" ]] || release_fail "fixed image reference conflicts: $tag"
    done
    publish_fixed "$version" "$digest"
    publish_fixed "src-$source_key" "$digest"
    jq -n --arg digest "$digest" --arg version "$version" --arg source "$source_key" \
        '{digest: $digest, tags: [$version, "src-" + $source]}' > "$publish_workspace/fixed-result.json"
    publish_checkpoint fixed "$publish_workspace/fixed-result.json"
}

main() {
    local operation=${1:-} candidate='' record='' verification='' output='' sha expected config

    [[ $# -gt 0 ]] || release_fail 'expected upload, verify, or promote'
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote | --repository | --request | --registry | --candidate | --record | --verification | --output)
                release_require_value "$1" "${2:-}"
                case "$1" in
                    --remote) publish_remote=$2 ;;
                    --repository) publish_repository=$2 ;;
                    --request) publish_request=$2 ;;
                    --registry) publish_registry=$2 ;;
                    --candidate) candidate=$2 ;;
                    --record) record=$2 ;;
                    --verification) verification=$2 ;;
                    --output) output=$2 ;;
                esac
                shift 2
                ;;
            --fixture)
                publish_fixture=true
                shift
                ;;
            *) release_fail "unknown publication argument: $1" ;;
        esac
    done
    release_require_commands git jq docker timeout rg cmp tar gzip mktemp
    release_require_sha256
    [[ "$publish_request" =~ ^[0-9a-f]{64}$ && -n "$candidate" ]] || release_fail 'request and retained candidate are required'
    if [[ "$publish_fixture" == true ]]; then
        [[ "$publish_registry" =~ ^127\.0\.0\.1:[0-9]+/fixture/[a-z0-9_-]+$ &&
            "$publish_repository" == fixture/* ]] || release_fail 'fixtures may publish only to a loopback registry'
        [[ "$operation" != verify ]] || release_fail 'synthetic fixtures cannot claim native verification'
    else
        [[ "$publish_registry" =~ ^docker\.io/[a-z0-9_-]+/[a-z0-9_-]+$ ]] || release_fail 'expected an owned Docker Hub repository'
    fi
    trap cleanup_publish EXIT
    publish_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kgcache-publish.XXXXXX")
    if [[ "$operation" == verify ]]; then
        [[ -f "$record" && -n "$output" && ! -e "$output" ]] || release_fail 'verify requires a record and new output directory'
        cp "$record" "$publish_workspace/request.json"
    else
        publish_coordinate status > "$publish_workspace/state.json"
        jq -e --arg key "$publish_request" '.requests[$key] // error("unknown request")' \
            "$publish_workspace/state.json" > "$publish_workspace/request.json"
    fi
    jq -e --arg key "$publish_request" '.request_key == $key and .tag_object_sha != null' \
        "$publish_workspace/request.json" > /dev/null || release_fail 'publication requires the original tagged request'
    jq -e --arg registry "$publish_registry" \
        '.registry.intent == null or .registry.intent.repository == $registry' \
        "$publish_workspace/request.json" > /dev/null ||
        release_fail 'publication destination differs from the original request'
    expected=$(jq -r '.candidate_sha256' "$publish_workspace/request.json")
    candidate_snapshot_bundle "$candidate" "$publish_workspace/bundle" "$expected"
    candidate_check_archive "$publish_workspace/bundle" "$publish_workspace/archive"
    if [[ "$operation" != verify ]]; then
        publish_coordinate tag --request "$publish_request" --candidate "$candidate" \
            > "$publish_workspace/request.json"
    fi
    if [[ "$publish_fixture" == false && "$operation" != verify ]]; then
        sha=$(git ls-remote --refs "$publish_remote" refs/heads/main)
        sha=${sha%%$'\t'*}
        timeout 65s curl --fail --silent --show-error --max-time 45 --connect-timeout 10 \
            --proto '=https' --header "Authorization: Bearer ${GH_TOKEN:?}" \
            --output "$publish_workspace/config.json" \
            "https://api.github.com/repos/$publish_repository/contents/.github/release-automation.json?ref=$sha" \
            --header 'Accept: application/vnd.github.raw+json'
        config=$(jq -r '.registry_repository' "$publish_workspace/config.json")
        [[ "$config" == "$publish_registry" ]] || release_fail 'registry is not the active owned destination'
    fi
    case "$operation" in
        upload) publish_upload ;;
        verify) publish_verify "$output" ;;
        promote) publish_promote "$verification" ;;
        *) release_fail 'unknown publication operation' ;;
    esac
    if [[ "$operation" != verify ]]; then
        if [[ -n "$output" ]]; then
            [[ ! -e "$output" ]] || release_fail 'output must be a new directory'
            mkdir -p "$output"
            cp "$publish_workspace/request.json" "$output/request.json"
        fi
        cat "$publish_workspace/request.json"
    fi
}

main "$@"

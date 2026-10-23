#!/usr/bin/env bash
# Shared candidate integrity checks. Callers own workspaces and containers.

candidate_docker() {
    timeout --signal=TERM --kill-after=5s 30s docker "$@"
}

candidate_engine() {
    local architecture

    architecture=$(candidate_docker info --format '{{.Architecture}}') ||
        release_fail 'cannot identify the Docker engine'
    case "$architecture" in
        x86_64 | amd64) printf 'linux/amd64\n' ;;
        aarch64 | arm64) printf 'linux/arm64\n' ;;
        *) release_fail "unsupported Docker engine architecture: $architecture" ;;
    esac
}

candidate_file_size() {
    local size

    size=$(wc -c < "$1") || release_fail "cannot measure $1"
    printf '%s\n' "${size//[[:space:]]/}"
}

candidate_assert_checkout() {
    local source=$1 expected=$2 revision source_status

    revision=$(git --no-replace-objects -C "$source" rev-parse HEAD)
    source_status=$(git --no-replace-objects -C "$source" status --porcelain --untracked-files=normal)
    [[ "$revision" == "$expected" ]] || release_fail 'selected checkout source differs'
    if [[ -n "$source_status" ]]; then
        printf '%s\n' "$source_status" >&2
        release_fail 'selected source checkout is dirty'
    fi
}

candidate_checkout_source() {
    local repo=$1 revision=$2 output=$3 cache=$4 runtime

    git -c core.hooksPath=/dev/null clone --quiet --no-hardlinks --no-checkout --no-tags -- "$repo" "$output"
    git -C "$output" -c core.hooksPath=/dev/null checkout --quiet --detach "$revision"
    mkdir -p "$output/.zig-cache" "$output/.client-tools"
    if [[ -d "$cache/.zig-cache/toolchains" ]]; then
        ln -s "$cache/.zig-cache/toolchains" "$output/.zig-cache/toolchains"
    fi
    # Directory-only ignore rules do not match a symlink at their root. Keep
    # real ignored directories and link only their runtime children.
    for runtime in go node; do
        if [[ -d "$cache/.client-tools/$runtime" ]]; then
            ln -s "$cache/.client-tools/$runtime" "$output/.client-tools/$runtime"
        fi
    done
    candidate_assert_checkout "$output" "$revision"
}

candidate_tooling_inventory() {
    local path checksum

    for path in tools/release/qualify.sh tools/release/common.sh tools/release/settings.sh \
        tools/release/candidate-common.sh tools/release/candidate.jq tools/release/create-candidate.jq \
        tools/release/semver.jq tools/release/validate-build-info.jq tools/release/verify.sh \
        tools/container/validate-image.jq; do
        checksum=$(release_sha256 "$RELEASE_ROOT/$path") || return 1
        jq -cn --arg path "$path" --arg sha "$checksum" \
            '{path: $path, sha256: $sha}' || return 1
    done
}

candidate_validate_request() {
    local proposal=$1 evidence=$2 bytes sha

    [[ -f "$evidence" && ! -L "$evidence" ]] ||
        release_fail 'request evidence must be a regular JSON file'
    bytes=$(candidate_file_size "$evidence") || return 1
    [[ "$bytes" -le 1048576 ]] || release_fail 'request evidence exceeds 1 MiB'
    sha=$(release_sha256 "$proposal") || return 1
    jq -e --arg sha "$sha" --slurpfile proposal "$proposal" \
        '.schema_version == 1 and .publishable == false and
          .mode == $proposal[0].mode and .repository == $proposal[0].repository and
          .source_sha == $proposal[0].source_sha and .policy_sha == $proposal[0].policy_sha and
          .proposal_sha256 == $sha' "$evidence" > /dev/null ||
        release_fail 'request evidence differs from the selected proposal'
}

candidate_identity_key() {
    local kind=$1 proposal=$2 encoded

    encoded=$(jq -c --arg kind "$kind" 'if $kind == "request" then
        [1, "request", .repository, .branch, .source_sha]
        else [1, "source-version", .source_sha, .version] end' "$proposal") ||
        release_fail 'cannot encode candidate identity'
    printf '%s' "$encoded" | release_sha256 /dev/stdin
}

candidate_validate_proposal() {
    local proposal=$1 expected actual mode

    jq -es -L "$RELEASE_ROOT/tools/release" 'include "candidate";
        if length == 1 then .[0] | validate_candidate_proposal
        else error("expected one proposal") end' "$proposal" > /dev/null ||
        release_fail 'invalid candidate proposal'
    expected=$(candidate_identity_key source-version "$proposal")
    actual=$(release_read_field "$proposal" .image.source_version_key)
    [[ "$expected" == "$actual" ]] || release_fail 'proposal source/version key differs'
    mode=$(release_read_field "$proposal" .mode)
    if [[ "$mode" == branch ]]; then
        expected=$(candidate_identity_key request "$proposal")
        actual=$(release_read_field "$proposal" .request_key)
        [[ "$expected" == "$actual" ]] || release_fail 'proposal branch request key differs'
    fi
}

candidate_regular_file() {
    local root=$1 path=$2 component current=$1
    local components=()

    IFS=/ read -r -a components <<< "$path"
    for component in "${components[@]}"; do
        current="$current/$component"
        [[ ! -L "$current" ]] || release_fail "candidate file traverses a symbolic link: $path"
    done
    [[ -f "$root/$path" ]] || release_fail "missing regular candidate file: $path"
}

# Snapshot the expected files and verify their complete checksum inventory.
# Only the Docker archive is large; metadata and each evidence file are bounded.
candidate_snapshot_bundle() {
    local input=$1 output=$2 expected_manifest=${3:-} path digest bytes actual line target
    local paths=()

    candidate_regular_file "$input" candidate.json
    bytes=$(candidate_file_size "$input/candidate.json")
    [[ "$bytes" -le 1048576 ]] ||
        release_fail 'candidate manifest exceeds 1 MiB'
    mkdir -p "$output"
    cp "$input/candidate.json" "$output/candidate.json"
    actual=$(release_sha256 "$output/candidate.json")
    [[ -z "$expected_manifest" || "$actual" == "$expected_manifest" ]] ||
        release_fail 'candidate manifest checksum differs from the expected checksum'
    jq -es -L "$RELEASE_ROOT/tools/release" 'include "candidate";
        if length == 1 then .[0] | validate_candidate else error("expected one candidate") end' \
        "$output/candidate.json" > /dev/null || release_fail 'invalid candidate manifest'
    jq -r '.archive.path, "proposal.json", "build-info.json", (.evidence[].path)' \
        "$output/candidate.json" > "$output/files"
    while IFS= read -r path; do
        # The manifest validator restricts paths to these regular bundle files.
        candidate_regular_file "$input" "$path"
        if [[ "$path" == kgcache-linux-amd64.docker.tar.gz ]]; then
            bytes=536870912
        else bytes=1048576; fi
        actual=$(candidate_file_size "$input/$path")
        [[ "$actual" -le "$bytes" ]] || release_fail "candidate file is too large: $path"
        if [[ "$path" == */* ]]; then
            mkdir -p "$output/${path%/*}"
        fi
        cp "$input/$path" "$output/$path"
    done < "$output/files"
    candidate_regular_file "$input" SHA256SUMS
    bytes=$(candidate_file_size "$input/SHA256SUMS")
    [[ "$bytes" -le 1048576 ]] || release_fail 'checksum inventory is too large'
    cp "$input/SHA256SUMS" "$output/SHA256SUMS"
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9a-f]{64}'  '[A-Za-z0-9_./-]+$ ]] || release_fail 'invalid checksum inventory line'
        digest=${line%% *}
        path=${line#*  }
        [[ "$path" == candidate.json ]] || {
            # Require exact membership before resolving any checksum path.
            jq -e --arg path "$path" '.archive.path == $path or $path == "proposal.json" or
                $path == "build-info.json" or any(.evidence[]; .path == $path)' \
                "$output/candidate.json" > /dev/null || release_fail 'unexpected checksum path'
        }
        paths+=("$path")
        actual=$(release_sha256 "$output/$path")
        [[ "$actual" == "$digest" ]] || release_fail "candidate file checksum mismatch: $path"
    done < "$output/SHA256SUMS"
    printf '%s\n' "${paths[@]}" | sort > "$output/actual-paths"
    printf 'candidate.json\n' > "$output/expected-unsorted"
    cat "$output/files" >> "$output/expected-unsorted"
    sort "$output/expected-unsorted" > "$output/expected-paths"
    cmp "$output/actual-paths" "$output/expected-paths" || release_fail 'candidate checksum inventory is incomplete or duplicated'
    jq -e --slurpfile proposal "$output/proposal.json" --slurpfile build "$output/build-info.json" \
        '($proposal | length) == 1 and ($build | length) == 1 and
         .proposal == $proposal[0] and .build == $build[0]' "$output/candidate.json" > /dev/null ||
        release_fail 'candidate metadata files disagree with the manifest'
    candidate_validate_proposal "$output/proposal.json"
    if [[ -f "$output/evidence/request.json" ]]; then
        candidate_validate_request "$output/proposal.json" "$output/evidence/request.json"
    fi
    target=$(release_target linux/amd64)
    jq -e -L "$RELEASE_ROOT/tools/release" \
        --arg target "$target" \
        --arg cpu "$RELEASE_CPU" \
        --arg optimize "$RELEASE_OPTIMIZE" \
        --arg compiler "$ZIG_VERSION" \
        --arg runtime "$RUNTIME_BASE" \
        --from-file "$RELEASE_ROOT/tools/release/validate-build-info.jq" \
        "$output/build-info.json" > /dev/null || release_fail 'invalid candidate build record'
    jq -r '.archive, .evidence[] | [.path, .sha256, .bytes] | @tsv' \
        "$output/candidate.json" > "$output/descriptors"
    while IFS=$'\t' read -r path digest bytes; do
        actual=$(release_sha256 "$output/$path")
        [[ "$actual" == "$digest" ]] || release_fail "candidate descriptor checksum mismatch: $path"
        actual=$(candidate_file_size "$output/$path")
        [[ "$actual" == "$bytes" ]] || release_fail "candidate descriptor size mismatch: $path"
    done < "$output/descriptors"
    jq -e \
        --slurpfile runtime "$output/evidence/reports/runtime.json" \
        --slurpfile service "$output/evidence/reports/service.json" \
        --slurpfile matrix "$output/evidence/client-matrix.json" \
        --slurpfile image "$output/evidence/image.json" \
        --slurpfile tooling "$output/evidence/tooling.json" \
        '. as $candidate | ($runtime | length) == 1 and ($service | length) == 1 and
         $runtime[0].build == .build and $service[0].build == .build and
         $runtime[0].runtime_libraries == "passed" and $runtime[0].elf_inspection == "passed" and
         $runtime[0].process_tests == "passed" and $service[0].passed == true and
         $service[0].compose.passed == true and $service[0].image_id == .image.id and
         $image[0][0].Id == .image.id and $image[0][0].Os == "linux" and $image[0][0].Architecture == "amd64" and
         $runtime[0].native_execution == .qualification.native_image and
         $runtime[0].initial_amd64_qualified == .qualification.native_image and
         $service[0].native_execution == .qualification.native_image and
         $service[0].qualified_amd64 == .qualification.native_image and
         .client_coverage.source_profiles == [$matrix[0].profiles[] | select(.ci == "required") | .id] and
         .client_coverage.image_profiles == $service[0].compose.clients and
         any($tooling[0][]; .path == "tools/release/qualify.sh" and .sha256 == $candidate.tooling.entrypoint_sha256)' \
        "$output/candidate.json" > /dev/null || release_fail 'candidate qualification evidence disagrees'
}

candidate_check_archive() {
    local bundle=$1 workspace=$2 image_id config_path actual layer expected index=0 digest bytes

    mkdir -p "$workspace"
    # The limit also catches concatenated gzip members and excessive expansion.
    # pipefail propagates gzip failure; head places a hard limit on expansion.
    # shellcheck disable=SC2312
    if ! timeout --signal=TERM --kill-after=5s 120s gzip -dc \
        "$bundle/kgcache-linux-amd64.docker.tar.gz" |
        head -c 1073741825 > "$workspace/image.tar"; then
        release_fail 'cannot decompress the candidate archive within its limits'
    fi
    bytes=$(candidate_file_size "$workspace/image.tar")
    [[ "$bytes" -le 1073741824 ]] ||
        release_fail 'candidate image archive exceeds 1 GiB'
    timeout --signal=TERM --kill-after=5s 60s tar -tf "$workspace/image.tar" > "$workspace/members"
    sort "$workspace/members" > "$workspace/sorted-members"
    uniq -d "$workspace/sorted-members" > "$workspace/duplicates"
    [[ ! -s "$workspace/duplicates" ]] || release_fail 'duplicate Docker archive member'
    while IFS= read -r layer; do
        [[ "$layer" =~ ^(manifest.json|index.json|oci-layout|repositories|blobs/|blobs/sha256/|blobs/sha256/[0-9a-f]{64}|[0-9a-f]{64}.json|[0-9a-f]{64}/|[0-9a-f]{64}/(VERSION|json|layer.tar))$ ]] ||
            release_fail 'unsupported or unsafe Docker archive member'
    done < "$workspace/members"
    timeout --signal=TERM --kill-after=5s 60s tar -tvf "$workspace/image.tar" > "$workspace/verbose-members"
    cut -c 1 "$workspace/verbose-members" > "$workspace/unsorted-types"
    sort -u "$workspace/unsorted-types" > "$workspace/types"
    while IFS= read -r layer; do
        [[ "$layer" == - || "$layer" == d ]] || release_fail 'Docker archive contains a link or special file'
    done < "$workspace/types"
    tar -xOf "$workspace/image.tar" manifest.json > "$workspace/manifest.json"
    jq -e 'type == "array" and length == 1 and
        ((.[0].RepoTags // []) | length) == 0 and
        (.[0].Config | test("\\A(blobs/sha256/[0-9a-f]{64}|[0-9a-f]{64}\\.json)\\z")) and
        (.[0].Layers | type == "array" and length > 0 and length <= 128)' \
        "$workspace/manifest.json" > /dev/null || release_fail 'archive must contain exactly one untagged image'
    config_path=$(jq -r '.[0].Config' "$workspace/manifest.json")
    tar -xOf "$workspace/image.tar" "$config_path" > "$workspace/config.json"
    actual=$(release_sha256 "$workspace/config.json")
    image_id=$(release_read_field "$bundle/candidate.json" .image.id)
    [[ "sha256:$actual" == "$image_id" ]] || release_fail 'archive configuration is not the expected image'
    jq -e --slurpfile candidate "$bundle/candidate.json" '
        .os == "linux" and .architecture == "amd64" and .rootfs.type == "layers" and
        .config.Labels["org.opencontainers.image.revision"] == $candidate[0].source_sha and
        .config.Labels["org.opencontainers.image.version"] == $candidate[0].version' \
        "$workspace/config.json" > /dev/null || release_fail 'archive source, version, or platform mismatch'
    jq -e --slurpfile config "$workspace/config.json" \
        '(.[0].Layers | length) == ($config[0].rootfs.diff_ids | length)' \
        "$workspace/manifest.json" > /dev/null || release_fail 'archive layer count differs from image configuration'
    jq -r '.[0].Layers[]' "$workspace/manifest.json" > "$workspace/layers"
    while IFS= read -r layer; do
        # Layer paths must be regular members from the checked archive inventory.
        jq -en --arg path "$layer" '$path | test("\\A(blobs/sha256/[0-9a-f]{64}|[0-9a-f]{64}/layer\\.tar)\\z")' \
            > /dev/null || release_fail 'invalid Docker layer path'
        tar -xOf "$workspace/image.tar" "$layer" > "$workspace/layer.tar"
        actual=$(release_sha256 "$workspace/layer.tar")
        expected=$(jq -r --argjson index "$index" '.rootfs.diff_ids[$index]' "$workspace/config.json")
        [[ "sha256:$actual" == "$expected" ]] || release_fail 'archive layer differs from the expected image'
        index=$((index + 1))
    done < "$workspace/layers"
    # Recent Docker saves include a second OCI index. It must describe this same
    # single image, without reference annotations that could restore named tags.
    if tar -xOf "$workspace/image.tar" index.json > "$workspace/index.json" 2> /dev/null; then
        jq -e '.schemaVersion == 2 and (.manifests | length) == 1 and
            (.annotations // {} | length) == 0 and (.manifests[0].annotations // {} | length) == 0 and
            (.manifests[0].digest | test("\\Asha256:[0-9a-f]{64}\\z"))' \
            "$workspace/index.json" > /dev/null || release_fail 'unexpected OCI index in Docker archive'
        digest=$(jq -r '.manifests[0].digest[7:]' "$workspace/index.json")
        tar -xOf "$workspace/image.tar" "blobs/sha256/$digest" > "$workspace/oci-manifest.json"
        actual=$(release_sha256 "$workspace/oci-manifest.json")
        [[ "$actual" == "$digest" ]] || release_fail 'OCI manifest checksum mismatch'
        jq -e --arg image "$image_id" --slurpfile config "$workspace/config.json" \
            '.schemaVersion == 2 and .config.digest == $image and
             [.layers[].digest] == $config[0].rootfs.diff_ids and
             all(.layers[]; .mediaType == "application/vnd.oci.image.layer.v1.tar" or
               .mediaType == "application/vnd.docker.image.rootfs.diff.tar")' \
            "$workspace/oci-manifest.json" > /dev/null || release_fail 'OCI index describes a different image'
    fi
    if tar -xOf "$workspace/image.tar" repositories > "$workspace/repositories.json" 2> /dev/null; then
        jq -e 'type == "object" and length == 0' "$workspace/repositories.json" > /dev/null ||
            release_fail 'Docker archive must not restore named repositories'
    fi
}

candidate_inspect_image() {
    local image=$1 bundle=$2 container=$3 output=$4 actual_sha actual_version expected_version exit_code

    mkdir -p "$output/bin"
    candidate_docker image inspect "$image" > "$output/image.json"
    jq -e --arg image "$image" 'length == 1 and .[0].Id == $image and
        .[0].Os == "linux" and .[0].Architecture == "amd64"' "$output/image.json" > /dev/null ||
        release_fail 'loaded image identity or platform mismatch'
    candidate_docker create --name "$container" --platform linux/amd64 --network none \
        --read-only --entrypoint /usr/local/bin/kgcache "$image" --version > /dev/null
    candidate_docker cp "$container:/usr/local/bin/kgcache" "$output/bin/kgcache"
    candidate_docker cp "$container:/usr/share/kgcache/build-info.json" "$output/build-info.json"
    candidate_docker start --attach "$container" > "$output/version.log"
    candidate_docker inspect --format '{{.State.ExitCode}}' "$container" > "$output/exit-code"
    exit_code=$(cat "$output/exit-code")
    [[ "$exit_code" == 0 ]] || release_fail 'loaded executable version command failed'
    actual_sha=$(release_sha256 "$output/bin/kgcache")
    actual_version=$(cat "$output/version.log")
    expected_version=$(release_read_field "$bundle/proposal.json" .version)
    [[ "$actual_version" == "kgcache $expected_version" ]] || release_fail 'loaded binary version mismatch'
    jq -e -L "$RELEASE_ROOT/tools/release" \
        --arg sha "$actual_sha" \
        --arg version "$actual_version" \
        --slurpfile image "$output/image.json" \
        --from-file "$RELEASE_ROOT/tools/container/validate-image.jq" \
        "$output/build-info.json" > /dev/null || release_fail 'loaded image metadata mismatch'
    cmp "$bundle/build-info.json" "$output/build-info.json" || release_fail 'loaded build record differs from candidate'
    bash "$RELEASE_ROOT/tools/release/verify.sh" --prefix "$output" --version "$expected_version"
    candidate_docker rm "$container" > /dev/null
}

#!/usr/bin/env bash
# Candidate metadata and archive failures use isolated synthetic bundles.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"
source "${BASH_SOURCE[0]%/*}/../../tools/release/candidate-common.sh"

candidate_test_workspace=
candidate_test_logs=

cleanup_candidate_tests() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "$candidate_test_workspace" ]]; then
        rm -rf -- "$candidate_test_workspace"
    fi
    exit "$exit_status"
}

refresh_checksums() {
    local bundle=$1 path checksum

    jq -r '"candidate.json", "proposal.json", "build-info.json", .archive.path, .evidence[].path' \
        "$bundle/candidate.json" > "$candidate_test_workspace/paths"
    : > "$bundle/SHA256SUMS"
    while IFS= read -r path; do
        checksum=$(release_sha256 "$bundle/$path")
        printf '%s  %s\n' "$checksum" "$path" >> "$bundle/SHA256SUMS"
    done < "$candidate_test_workspace/paths"
}

create_fixture() {
    local bundle="$candidate_test_workspace/good" raw="$candidate_test_workspace/raw"
    local repo="$candidate_test_workspace/repository" revision
    local path checksum bytes config_sha layer_sha evidence_file tooling_revision tooling_sha

    mkdir -p "$bundle/evidence/logs" "$bundle/evidence/reports" "$raw/layer"
    # The caller may have a shallow, detached PR checkout with no origin/main.
    # Keep proposal history and refs inside the fixture, like the saved image.
    if [[ -n "${1:-}" ]]; then
        cp "$1" "$bundle/proposal.json"
    else
        git init --quiet --initial-branch=main "$repo"
        cp "$RELEASE_ROOT/.gitignore" "$repo/.gitignore"
        printf '.{\n    .version = "0.0.0",\n}\n' > "$repo/build.zig.zon"
        git -C "$repo" add .gitignore build.zig.zon
        git -C "$repo" -c core.hooksPath=/dev/null \
            -c user.name='Candidate fixture' -c user.email=fixture@example.invalid \
            -c commit.gpgsign=false commit --quiet -m 'chore: create candidate fixture'
        revision=$(git -C "$repo" rev-parse HEAD)
        git -C "$repo" update-ref refs/remotes/origin/main "$revision"
        bash tools/release/propose.sh --repo "$repo" --repository fixture/kgcache \
            --source "$revision" --version 0.2.0-rc.1+fixture.001 > "$bundle/proposal.json"
    fi
    printf 'synthetic candidate fixture\n' > "$raw/layer/fixture.txt"
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$raw/layer.tar" -C "$raw/layer" fixture.txt
    layer_sha=$(release_sha256 "$raw/layer.tar")
    jq -n \
        --slurpfile proposal "$bundle/proposal.json" \
        --arg diff "sha256:$layer_sha" \
        '{os: "linux", architecture: "amd64", rootfs: {type: "layers", diff_ids: [$diff]},
          config: {Labels: {"org.opencontainers.image.revision": $proposal[0].source_sha,
            "org.opencontainers.image.version": $proposal[0].version}}}' > "$raw/config.json"
    config_sha=$(release_sha256 "$raw/config.json")
    mv "$raw/config.json" "$raw/$config_sha.json"
    mkdir "$raw/$layer_sha"
    mv "$raw/layer.tar" "$raw/$layer_sha/layer.tar"
    jq -n --arg config "$config_sha.json" --arg layer "$layer_sha/layer.tar" \
        '[{Config: $config, RepoTags: null, Layers: [$layer]}]' > "$raw/manifest.json"
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$candidate_test_workspace/fixture.tar" -C "$raw" manifest.json "$config_sha.json" "$layer_sha/layer.tar"
    gzip -n -c "$candidate_test_workspace/fixture.tar" > "$bundle/kgcache-linux-amd64.docker.tar.gz"
    jq -n \
        --slurpfile proposal "$bundle/proposal.json" \
        --arg compiler "$ZIG_VERSION" --arg runtime "$RUNTIME_BASE" \
        '{schema_version: 2, version: $proposal[0].version,
          development_version: $proposal[0].development_version,
          source: {revision: $proposal[0].source_sha, dirty: false}, platform: "linux/amd64",
          target: "x86_64-linux-gnu.2.36", cpu: "baseline", optimize: "ReleaseSafe",
          persistence_test_controls: false,
          compiler: {version: $compiler, archive_sha256: ("1" * 64)}, runtime_base: $runtime,
          binary: {path: "bin/kgcache", sha256: ("2" * 64)}}' > "$bundle/build-info.json"
    jq -n --slurpfile build "$bundle/build-info.json" '{schema_version: 1, build: $build[0],
        native_execution: false, initial_amd64_qualified: false,
        runtime_libraries: "passed", elf_inspection: "passed", process_tests: "passed"}' \
        > "$bundle/evidence/reports/runtime.json"
    jq -n --slurpfile build "$bundle/build-info.json" --arg image "sha256:$config_sha" \
        '{passed: true, build: $build[0], image_id: $image, native_execution: false,
          qualified_amd64: false, compose: {passed: true, clients: ["go-redis-v9.22.0", "node-redis-6.2.1"]}}' \
        > "$bundle/evidence/reports/service.json"
    jq -n --arg image "sha256:$config_sha" '[{Id: $image, Os: "linux", Architecture: "amd64"}]' \
        > "$bundle/evidence/image.json"
    cp tests/integration/clients/matrix.json "$bundle/evidence/client-matrix.json"
    candidate_tooling_inventory > "$candidate_test_workspace/tooling.jsonl"
    jq -s . "$candidate_test_workspace/tooling.jsonl" > "$bundle/evidence/tooling.json"
    jq -nr -L tools/release 'include "candidate"; candidate_phases[]' > "$candidate_test_workspace/phases"
    : > "$candidate_test_workspace/checks.jsonl"
    while IFS= read -r path; do
        printf 'Synthetic phase record, no qualification claim.\n' > "$bundle/evidence/logs/$path.log"
        jq -cn --arg name "$path" '{name: $name, passed: true, log: ("evidence/logs/" + $name + ".log")}' \
            >> "$candidate_test_workspace/checks.jsonl"
    done < "$candidate_test_workspace/phases"
    find "$bundle/evidence" -type f -print0 > "$candidate_test_workspace/evidence-files"
    evidence_file="$candidate_test_workspace/evidence.jsonl"
    : > "$evidence_file"
    while IFS= read -r -d '' path; do
        checksum=$(release_sha256 "$path")
        bytes=$(candidate_file_size "$path")
        jq -cn --arg path "${path#"$bundle/"}" --arg sha "$checksum" --argjson bytes "$bytes" \
            '{path: $path, sha256: $sha, bytes: $bytes}' >> "$evidence_file"
    done < "$candidate_test_workspace/evidence-files"
    checksum=$(release_sha256 "$bundle/kgcache-linux-amd64.docker.tar.gz")
    bytes=$(candidate_file_size "$bundle/kgcache-linux-amd64.docker.tar.gz")
    tooling_revision=$(git rev-parse HEAD)
    tooling_sha=$(release_sha256 tools/release/qualify.sh)
    jq -n \
        --slurpfile proposal "$bundle/proposal.json" \
        --slurpfile build "$bundle/build-info.json" \
        --slurpfile checks "$candidate_test_workspace/checks.jsonl" \
        --slurpfile evidence "$evidence_file" \
        --slurpfile matrix "$bundle/evidence/client-matrix.json" \
        --slurpfile service "$bundle/evidence/reports/service.json" \
        --arg image "sha256:$config_sha" \
        --arg archive_sha "$checksum" --argjson archive_bytes "$bytes" \
        --arg tooling_revision "$tooling_revision" --argjson tooling_dirty true \
        --arg tooling_sha "$tooling_sha" \
        --arg run_id fixture --arg attempt 1 --arg workflow_ref fixture --arg workflow_sha "$tooling_revision" \
        --arg host darwin/arm64 --arg engine linux/arm64 \
        --from-file tools/release/create-candidate.jq > "$bundle/candidate.json"
    refresh_checksums "$bundle"
}

new_case() {
    local name=$1

    mkdir "$candidate_test_workspace/$name"
    cp -R "$candidate_test_workspace/good/." "$candidate_test_workspace/$name/"
}

mutate_manifest() {
    local bundle=$1 filter=$2

    jq "$filter" "$bundle/candidate.json" > "$bundle/next.json"
    mv "$bundle/next.json" "$bundle/candidate.json"
}

expect_candidate_rejection() {
    local name=$1 message=$2 exit_status output

    shift 2
    if bash tests/release/candidate-child.sh "$@" > "$candidate_test_logs/$name.log" 2>&1; then
        release_fail "$name was accepted"
    else exit_status=$?; fi
    output=$(cat "$candidate_test_logs/$name.log")
    [[ "$exit_status" != 0 && "$output" == *"$message"* ]] || {
        cat "$candidate_test_logs/$name.log" >&2
        release_fail "$name failed for an unexpected reason"
    }
    printf 'Passed: %s\n' "$name"
}

check_bundle_failures() {
    local digest

    new_case bad-schema
    mutate_manifest "$candidate_test_workspace/bad-schema" '.schema_version = 2'
    expect_candidate_rejection bad-schema 'schema_version must be 1' bundle \
        "$candidate_test_workspace/bad-schema" "$candidate_test_workspace/check-schema"
    new_case source-mismatch
    mutate_manifest "$candidate_test_workspace/source-mismatch" '.source_sha = ("0" * 40)'
    expect_candidate_rejection source-mismatch 'candidate/proposal identity mismatch' bundle \
        "$candidate_test_workspace/source-mismatch" "$candidate_test_workspace/check-source"
    new_case version-mismatch
    mutate_manifest "$candidate_test_workspace/version-mismatch" '.version = "0.9.0"'
    expect_candidate_rejection version-mismatch 'candidate/proposal identity mismatch' bundle \
        "$candidate_test_workspace/version-mismatch" "$candidate_test_workspace/check-version"
    new_case wrong-platform
    mutate_manifest "$candidate_test_workspace/wrong-platform" '.platform = "linux/arm64"'
    expect_candidate_rejection wrong-platform 'unsupported candidate platform' bundle \
        "$candidate_test_workspace/wrong-platform" "$candidate_test_workspace/check-platform"
    new_case missing-phase
    mutate_manifest "$candidate_test_workspace/missing-phase" '.checks |= map(select(.name != "image-build"))'
    expect_candidate_rejection missing-phase 'missing required checks' bundle \
        "$candidate_test_workspace/missing-phase" "$candidate_test_workspace/check-phase"
    new_case failed-phase
    mutate_manifest "$candidate_test_workspace/failed-phase" '.checks[0].passed = false'
    expect_candidate_rejection failed-phase 'checks did not pass' bundle \
        "$candidate_test_workspace/failed-phase" "$candidate_test_workspace/check-failed"
    new_case archive-corrupt
    printf 'changed' >> "$candidate_test_workspace/archive-corrupt/kgcache-linux-amd64.docker.tar.gz"
    expect_candidate_rejection archive-corrupt 'file checksum mismatch' bundle \
        "$candidate_test_workspace/archive-corrupt" "$candidate_test_workspace/check-corrupt"
    new_case missing-report
    rm "$candidate_test_workspace/missing-report/evidence/reports/runtime.json"
    expect_candidate_rejection missing-report 'missing regular candidate file' bundle \
        "$candidate_test_workspace/missing-report" "$candidate_test_workspace/check-report"
    new_case unsafe-evidence
    mutate_manifest "$candidate_test_workspace/unsafe-evidence" '.evidence[0].path = "../outside"'
    expect_candidate_rejection unsafe-evidence 'invalid evidence inventory' bundle \
        "$candidate_test_workspace/unsafe-evidence" "$candidate_test_workspace/check-path"
    new_case symlink-report
    mv "$candidate_test_workspace/symlink-report/evidence/reports" "$candidate_test_workspace/reports"
    ln -s "$candidate_test_workspace/reports" "$candidate_test_workspace/symlink-report/evidence/reports"
    expect_candidate_rejection symlink-report 'symbolic link' bundle \
        "$candidate_test_workspace/symlink-report" "$candidate_test_workspace/check-link"
    new_case fake-native
    mutate_manifest "$candidate_test_workspace/fake-native" '.qualification.qualified_amd64 = true'
    expect_candidate_rejection fake-native 'qualification/platform flags disagree' bundle \
        "$candidate_test_workspace/fake-native" "$candidate_test_workspace/check-native"
    new_case fake-reports
    mutate_manifest "$candidate_test_workspace/fake-reports" \
        '.qualification = {host: "linux/amd64", engine: "linux/amd64", native_source: true, native_image: true, qualified_amd64: true} |
         .client_coverage.source_binary = "image"'
    refresh_checksums "$candidate_test_workspace/fake-reports"
    expect_candidate_rejection fake-reports 'qualification evidence disagrees' bundle \
        "$candidate_test_workspace/fake-reports" "$candidate_test_workspace/check-reports"
    new_case missing-checksum
    sed '$d' "$candidate_test_workspace/missing-checksum/SHA256SUMS" > "$candidate_test_workspace/short-checksums"
    mv "$candidate_test_workspace/short-checksums" "$candidate_test_workspace/missing-checksum/SHA256SUMS"
    expect_candidate_rejection missing-checksum 'inventory is incomplete' bundle \
        "$candidate_test_workspace/missing-checksum" "$candidate_test_workspace/check-checksums"
    digest=$(release_sha256 "$candidate_test_workspace/good/candidate.json")
    new_case trusted-checksum
    mutate_manifest "$candidate_test_workspace/trusted-checksum" '.run.attempt = "2"'
    refresh_checksums "$candidate_test_workspace/trusted-checksum"
    expect_candidate_rejection trusted-checksum 'expected checksum' bundle \
        "$candidate_test_workspace/trusted-checksum" "$candidate_test_workspace/check-trusted" "$digest"
}

check_archive_failures() {
    local bundle path layer

    new_case multiple-images
    bundle="$candidate_test_workspace/multiple-images"
    mkdir "$bundle/raw"
    cp -R "$candidate_test_workspace/raw/." "$bundle/raw/"
    jq '. + .' "$bundle/raw/manifest.json" > "$bundle/raw/next.json"
    mv "$bundle/raw/next.json" "$bundle/raw/manifest.json"
    tar -cf "$candidate_test_workspace/multiple.tar" -C "$bundle/raw" .
    gzip -n -c "$candidate_test_workspace/multiple.tar" > "$bundle/kgcache-linux-amd64.docker.tar.gz"
    expect_candidate_rejection multiple-images 'unsupported or unsafe' archive "$bundle" "$candidate_test_workspace/check-multiple"
    # A direct archive check still proves the one-image rule after removing the
    # extra './' member prefix used above.
    path=$(jq -r '.[0].Config' "$bundle/raw/manifest.json")
    jq -r '.[0].Layers[]' "$bundle/raw/manifest.json" > "$candidate_test_workspace/raw-layers"
    layer=$(cat "$candidate_test_workspace/raw-layers")
    tar -cf "$candidate_test_workspace/multiple.tar" -C "$bundle/raw" manifest.json "$path" \
        "$layer"
    gzip -n -c "$candidate_test_workspace/multiple.tar" > "$bundle/kgcache-linux-amd64.docker.tar.gz"
    expect_candidate_rejection multiple-image-manifest 'exactly one untagged image' archive \
        "$bundle" "$candidate_test_workspace/check-multiple-manifest"
    jq '.[0:1] | .[0].RepoTags = ["kgcache:must-not-be-restored"]' "$bundle/raw/manifest.json" > "$bundle/raw/next.json"
    mv "$bundle/raw/next.json" "$bundle/raw/manifest.json"
    tar -cf "$candidate_test_workspace/tagged.tar" -C "$bundle/raw" manifest.json "$path" \
        "$layer"
    gzip -n -c "$candidate_test_workspace/tagged.tar" > "$bundle/kgcache-linux-amd64.docker.tar.gz"
    expect_candidate_rejection archive-tags 'exactly one untagged image' archive \
        "$bundle" "$candidate_test_workspace/check-tags"
    jq '.[0].RepoTags = null' "$bundle/raw/manifest.json" > "$bundle/raw/next.json"
    mv "$bundle/raw/next.json" "$bundle/raw/manifest.json"
    path=$(cat "$candidate_test_workspace/raw-layers")
    printf 'changed layer' >> "$bundle/raw/$path"
    path=$(jq -r '.[0].Config' "$bundle/raw/manifest.json")
    tar -cf "$candidate_test_workspace/layer.tar" -C "$bundle/raw" manifest.json "$path" \
        "$layer"
    gzip -n -c "$candidate_test_workspace/layer.tar" > "$bundle/kgcache-linux-amd64.docker.tar.gz"
    expect_candidate_rejection layer-corruption 'layer differs from the expected image' archive \
        "$bundle" "$candidate_test_workspace/check-layer"
}

check_real_candidate() {
    local candidate=$1 allow_emulation=$2 docker_path image checksum bytes exit_status output
    local wrong="$candidate_test_workspace/wrong-real-archive"
    local args=(--candidate "$1")

    release_require_commands docker timeout
    docker_path=$(command -v docker)
    mkdir "$candidate_test_workspace/docker-bin"
    cat > "$candidate_test_workspace/docker-bin/docker" << 'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CANDIDATE_DOCKER_CALLS"
case "$1 ${2:-}" in
    build\ * | buildx\ * | 'image build')
        printf 'a candidate import must never build an image\n' >&2
        exit 99
        ;;
esac
exec "$CANDIDATE_REAL_DOCKER" "$@"
SH
    chmod +x "$candidate_test_workspace/docker-bin/docker"
    if [[ "$allow_emulation" == true ]]; then
        args+=(--allow-emulation)
    fi
    : > "$candidate_test_logs/real-docker-calls.log"
    env PATH="$candidate_test_workspace/docker-bin:$PATH" \
        CANDIDATE_REAL_DOCKER="$docker_path" \
        CANDIDATE_DOCKER_CALLS="$candidate_test_logs/real-docker-calls.log" \
        bash tools/release/import-candidate.sh "${args[@]}" \
        > "$candidate_test_logs/real-import.json" 2> "$candidate_test_logs/real-import.log"
    jq -e '.passed and .rebuilt == false and .publishable == false' \
        "$candidate_test_logs/real-import.json" > /dev/null
    image=$(release_read_field "$candidate/candidate.json" .image.id)
    timeout --signal=TERM --kill-after=3s 15s "$docker_path" image inspect "$image" > /dev/null
    mkdir "$wrong"
    cp -R "$candidate/." "$wrong/"
    # Replace the archive with a different valid image while the expected image
    # is already loaded. Updating the checksums must not hide that substitution.
    cp "$candidate_test_workspace/good/kgcache-linux-amd64.docker.tar.gz" "$wrong/kgcache-linux-amd64.docker.tar.gz"
    checksum=$(release_sha256 "$wrong/kgcache-linux-amd64.docker.tar.gz")
    bytes=$(candidate_file_size "$wrong/kgcache-linux-amd64.docker.tar.gz")
    jq --arg sha "$checksum" --argjson bytes "$bytes" '.archive.sha256 = $sha | .archive.bytes = $bytes' \
        "$wrong/candidate.json" > "$wrong/next.json"
    mv "$wrong/next.json" "$wrong/candidate.json"
    refresh_checksums "$wrong"
    args=(--candidate "$wrong")
    if [[ "$allow_emulation" == true ]]; then
        args+=(--allow-emulation)
    fi
    : > "$candidate_test_logs/wrong-real-docker-calls.log"
    if env PATH="$candidate_test_workspace/docker-bin:$PATH" \
        CANDIDATE_REAL_DOCKER="$docker_path" \
        CANDIDATE_DOCKER_CALLS="$candidate_test_logs/wrong-real-docker-calls.log" \
        bash tools/release/import-candidate.sh "${args[@]}" \
        > "$candidate_test_logs/wrong-real-import.log" 2>&1; then
        release_fail 'a substituted archive was accepted because the expected image already existed'
    else exit_status=$?; fi
    output=$(cat "$candidate_test_logs/wrong-real-import.log")
    [[ "$exit_status" != 0 && "$output" == *'archive configuration is not the expected image'* ]] ||
        release_fail 'wrong real archive failed for an unexpected reason'
    [[ ! -s "$candidate_test_logs/wrong-real-docker-calls.log" ]] ||
        release_fail 'a substituted archive reached Docker before verification'
    printf 'Passed: real image load without a build and rejection of substituted archive with cached image present\n'
}

main() {
    local fixture_revision candidate='' allow_emulation=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --candidate)
                release_require_value "$1" "${2:-}"
                candidate=$2
                shift 2
                ;;
            --allow-emulation)
                allow_emulation=true
                shift
                ;;
            --help)
                printf 'Usage: bash tests/release/candidates.sh [--candidate DIR] [--allow-emulation]\n'
                return
                ;;
            *) release_fail "unknown argument: $1" ;;
        esac
    done
    release_require_commands git jq tar gzip head sort uniq cut cmp wc find mktemp sed
    release_require_sha256
    cd "$RELEASE_ROOT"
    mkdir -p .zig-cache test-artifacts/release/candidate-contracts
    candidate_test_workspace=$(mktemp -d "$RELEASE_ROOT/.zig-cache/candidate-contracts.XXXXXX")
    candidate_test_logs=$(mktemp -d "$RELEASE_ROOT/test-artifacts/release/candidate-contracts/run.XXXXXX")
    trap cleanup_candidate_tests EXIT
    create_fixture ''
    mkdir -p "$candidate_test_workspace/cache/.client-tools/go" "$candidate_test_workspace/cache/.client-tools/node" \
        "$candidate_test_workspace/cache/.zig-cache/toolchains"
    fixture_revision=$(git -C "$candidate_test_workspace/repository" rev-parse HEAD)
    candidate_checkout_source "$candidate_test_workspace/repository" "$fixture_revision" \
        "$candidate_test_workspace/source" "$candidate_test_workspace/cache"
    [[ -d "$candidate_test_workspace/source/.client-tools" && ! -L "$candidate_test_workspace/source/.client-tools" ]] ||
        release_fail 'source runtime cache root must be a real ignored directory'
    [[ -L "$candidate_test_workspace/source/.client-tools/go" ]] || release_fail 'source runtime cache child is missing'
    candidate_assert_checkout "$candidate_test_workspace/source" "$fixture_revision"
    printf 'Passed: isolated checkout remains clean with cached runtime links\n'
    bash tests/release/candidate-child.sh bundle "$candidate_test_workspace/good" "$candidate_test_workspace/valid"
    printf 'Passed: complete synthetic bundle and layer integrity\n'
    check_bundle_failures
    check_archive_failures
    if [[ -n "$candidate" ]]; then
        check_real_candidate "$candidate" "$allow_emulation"
    fi
    printf 'Candidate contract checks passed. Evidence: %s\n' "$candidate_test_logs"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

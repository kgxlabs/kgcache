#!/usr/bin/env bash
# Check specific failures and removal of containers whose clients time out.
set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

# The EXIT trap owns only the fixture workspace and an emergency container name.
failure_workspace=
failure_logs=
failure_probe_id=

cleanup_failures() {
    local status=$?

    trap - EXIT

    if [[ -n "$failure_probe_id" ]]; then
        timeout --signal=TERM --kill-after=2s 5s \
            docker rm --force "$failure_probe_id-runtime" > /dev/null 2>&1 || true
    fi

    if [[ -n "$failure_workspace" ]]; then
        rm -rf -- "$failure_workspace"
    fi

    exit "$status"
}

# Each rejection must have the intended status and a specific explanation.
expect_failure() {
    local name=$1 expected=$2 message=$3 actual output

    shift 3
    if "$@" > "$failure_logs/$name.log" 2>&1; then
        release_fail "$name unexpectedly succeeded; log: $failure_logs/$name.log"
    else
        actual=$?
    fi

    output=$(cat "$failure_logs/$name.log")
    if [[ "$actual" != "$expected" || "$output" != *"$message"* ]]; then
        cat "$failure_logs/$name.log" >&2
        release_fail "$name failed for an unexpected reason (status $actual); log: $failure_logs/$name.log"
    fi

    printf 'Passed: %s\n' "$name"
}

check_git_failure() {
    local real_git revision

    mkdir "$failure_workspace/git-bin"
    cat > "$failure_workspace/git-bin/git" << 'SH'
#!/usr/bin/env bash
if [[ "$1" == status ]]; then
    printf 'simulated Git status failure\n' >&2
    exit 70
fi
exec "$REAL_GIT" "$@"
SH
    chmod +x "$failure_workspace/git-bin/git"

    real_git=$(command -v git)
    revision=$(release_git_revision)

    expect_failure git-status 1 'cannot read Git status' \
        env PATH="$failure_workspace/git-bin:$PATH" REAL_GIT="$real_git" \
        bash tests/release/failure-child.sh git-status "$revision"
}

check_bootstrap_failure() {
    mkdir "$failure_workspace/bootstrap-bin"
    cat > "$failure_workspace/bootstrap-bin/uname" << 'SH'
#!/usr/bin/env bash
printf 'unsupported-review-host\n'
SH
    chmod +x "$failure_workspace/bootstrap-bin/uname"

    expect_failure failed-bootstrap 1 'ZIG must name a compiler executable' \
        env PATH="$failure_workspace/bootstrap-bin:$PATH" \
        bash tests/release/failure-child.sh bootstrap
}

check_missing_dependency() {
    local bash_command

    bash_command=$(command -v bash)
    mkdir "$failure_workspace/dependency-bin"
    printf '#!/bin/sh\nexit 99\n' > "$failure_workspace/dependency-bin/jq"
    chmod +x "$failure_workspace/dependency-bin/jq"

    expect_failure missing-dependency 1 'required command is missing: file' \
        env PATH="$failure_workspace/dependency-bin" \
        "$bash_command" tools/release/verify.sh
}

check_glibc_versions() {
    local parser="$RELEASE_ROOT/tools/release/glibc-versions.awk" output

    printf 'Name: GLIBC_2.2.5\nName: GLIBC_2.36\n' \
        > "$failure_workspace/glibc-valid"
    output=$(awk -v baseline=2.36 -f "$parser" "$failure_workspace/glibc-valid")
    [[ "$output" == *GLIBC_2.2.5* && "$output" == *GLIBC_2.36* ]] ||
        release_fail 'valid glibc requirements were lost'

    printf 'Name: GLIBC_2.37\n' > "$failure_workspace/glibc-new"
    expect_failure glibc-too-new 1 'exceeds glibc baseline 2.36' \
        awk -v baseline=2.36 -f "$parser" "$failure_workspace/glibc-new"

    printf 'Name: GLIBC_2.36.1\n' > "$failure_workspace/glibc-patch"
    expect_failure glibc-new-patch 1 'exceeds glibc baseline 2.36' \
        awk -v baseline=2.36 -f "$parser" "$failure_workspace/glibc-patch"

    printf 'Name: GLIBC_PRIVATE\n' > "$failure_workspace/glibc-private"
    expect_failure glibc-private 1 'unsupported glibc symbol version' \
        awk -v baseline=2.36 -f "$parser" "$failure_workspace/glibc-private"
}

check_image_metadata() {
    local revision version

    revision=$(release_git_revision)
    version=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' build.zig.zon)

    expect_failure image-clean-unknown-revision 1 'clean images require an explicit full Git revision' \
        env TARGETOS=linux TARGETARCH=amd64 SOURCE_REVISION=unknown \
        SOURCE_DIRTY=false VERSION="$version" bash tools/container/build.sh
    expect_failure image-clean-missing-version 1 'clean images require an explicit VERSION' \
        env TARGETOS=linux TARGETARCH=amd64 SOURCE_REVISION="$revision" \
        SOURCE_DIRTY=false VERSION= bash tools/container/build.sh
    expect_failure image-invalid-revision 1 'SOURCE_REVISION must be a full Git revision' \
        env TARGETOS=linux TARGETARCH=amd64 SOURCE_REVISION=invalid \
        SOURCE_DIRTY=true bash tools/container/build.sh
    expect_failure image-invalid-dirty 1 'SOURCE_DIRTY must be true or false' \
        env TARGETOS=linux TARGETARCH=amd64 SOURCE_REVISION=unknown \
        SOURCE_DIRTY=invalid bash tools/container/build.sh
    expect_failure image-invalid-version 1 'VERSION must be SemVer 2.0.0' \
        env TARGETOS=linux TARGETARCH=amd64 SOURCE_REVISION=unknown \
        SOURCE_DIRTY=true VERSION=invalid bash tools/container/build.sh
    expect_failure image-base-mismatch 1 'image base differs from the qualified release base' \
        env TARGETOS=linux TARGETARCH=amd64 SOURCE_REVISION=unknown \
        SOURCE_DIRTY=true VERSION= IMAGE_RUNTIME_BASE=unapproved \
        bash tools/container/build.sh
}

check_docker_timeout() {
    local remaining

    release_require_commands timeout docker

    timeout --signal=TERM --kill-after=5s 15s \
        docker version --format '{{.Server.Version}}' > /dev/null
    timeout --signal=TERM --kill-after=5s 120s \
        docker pull --platform linux/amd64 "$RUNTIME_BASE" \
        > "$failure_logs/pull.log" 2>&1

    failure_probe_id="kgcache-failure-probe-$$"
    expect_failure docker-timeout 1 'runtime probe failed or timed out' \
        bash tests/release/failure-child.sh docker-timeout "$failure_probe_id" \
        "$failure_logs/timeout-container.log"

    remaining=$(timeout --signal=TERM --kill-after=2s 5s \
        docker container ls --all --quiet \
        --filter "name=^/$failure_probe_id-runtime$")
    [[ -z "$remaining" ]] ||
        release_fail 'timed-out probe container was not removed'
    failure_probe_id=

    printf 'Passed: timed-out container removed\n'
}

main() {
    [[ $# == 0 || ($# == 1 && "$1" == --docker) ]] ||
        release_fail 'usage: bash tests/release/failures.sh [--docker]'

    release_require_commands git jq bash mktemp awk

    cd "$RELEASE_ROOT"
    mkdir -p .zig-cache test-artifacts/release/failures

    trap cleanup_failures EXIT
    failure_workspace=$(mktemp -d "$RELEASE_ROOT/.zig-cache/release-failures.XXXXXX")
    failure_logs=$(mktemp -d "$RELEASE_ROOT/test-artifacts/release/failures/run.XXXXXX")

    expect_failure empty-compiler 1 'ZIG must name a compiler executable' \
        env ZIG= bash tests/build/run.sh
    check_git_failure
    check_bootstrap_failure
    check_missing_dependency
    check_glibc_versions
    check_image_metadata
    expect_failure missing-option-value 1 'missing value for --prefix' \
        bash tools/release/build.sh --prefix --allow-dirty
    expect_failure missing-version-value 1 'missing value for --version' \
        bash tools/release/build.sh --version --allow-dirty
    expect_failure invalid-release-version 1 'version must be SemVer 2.0.0' \
        bash tools/release/build.sh --version 0.2.0-01
    expect_failure invalid-verify-version 1 'version must be SemVer 2.0.0' \
        bash tools/release/verify.sh --version v0.2.0
    if [[ ${1:-} == --docker ]]; then
        check_docker_timeout
    fi

    printf 'Failure handling checks passed. Evidence: %s\n' "$failure_logs"
}

main "$@"

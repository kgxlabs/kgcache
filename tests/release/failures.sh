#!/usr/bin/env bash
# Exercise failures that must stop release checks and clean up owned resources.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

cd "$release_root"
[[ $# == 0 || ( $# == 1 && "$1" == --docker ) ]] || release_fail 'usage: bash tests/release/failures.sh [--docker]'
mkdir -p .zig-cache test-artifacts/release/failures
test_root=$(mktemp -d "$release_root/.zig-cache/release-failures.XXXXXX")
logs=$(mktemp -d "$release_root/test-artifacts/release/failures/run.XXXXXX")
test_probe_id=
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$test_probe_id" ]]; then
        timeout --signal=TERM --kill-after=2s 5s docker rm --force "$test_probe_id-runtime" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$test_root"
    exit "$status"
}
trap cleanup EXIT

# Require both the intended exit status and a specific explanation.
expect_failure() {
    local name=$1 expected=$2 message=$3 actual output
    shift 3
    if "$@" >"$logs/$name.log" 2>&1; then
        release_fail "$name unexpectedly succeeded; log: $logs/$name.log"
    else
        actual=$?
    fi
    output=$(cat "$logs/$name.log")
    if [[ "$actual" != "$expected" || "$output" != *"$message"* ]]; then
        cat "$logs/$name.log" >&2
        release_fail "$name failed for an unexpected reason (status $actual); log: $logs/$name.log"
    fi
    printf 'Passed: %s\n' "$name"
}

expect_failure empty-compiler 1 'ZIG must name a compiler executable' \
    env ZIG= bash tests/build/run.sh

mkdir "$test_root/git-bin"
cat >"$test_root/git-bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == status ]]; then
    printf 'simulated Git status failure\n' >&2
    exit 70
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$test_root/git-bin/git"
real_git=$(command -v git)
revision=$(release_git_revision)
expect_failure git-status 1 'cannot read Git status' \
    env PATH="$test_root/git-bin:$PATH" REAL_GIT="$real_git" \
    bash -c 'set -euo pipefail; source "$1/tools/release/common.sh"; release_assert_source "$2"' _ "$release_root" "$revision"

mkdir "$test_root/bootstrap-bin"
cat >"$test_root/bootstrap-bin/uname" <<'SH'
#!/usr/bin/env bash
printf 'unsupported-review-host\n'
SH
chmod +x "$test_root/bootstrap-bin/uname"
# Even the old combined CI command must fail instead of choosing a PATH compiler.
expect_failure failed-bootstrap 1 'ZIG must name a compiler executable' \
    env PATH="$test_root/bootstrap-bin:$PATH" \
    bash -c 'ZIG=$(bash tools/release/zig.sh --print-path) bash tests/build/run.sh'

if [[ ${1:-} == --docker ]]; then
    command -v timeout >/dev/null || release_fail 'GNU timeout is required'
    docker version --format '{{.Server.Version}}' >/dev/null
    timeout --signal=TERM --kill-after=5s 120s docker pull --platform linux/amd64 "$release_runtime" >"$logs/pull.log" 2>&1
    test_probe_id="kgcache-failure-probe-$$"
    expect_failure docker-timeout 1 'runtime probe failed or timed out' \
        bash -c '
            set -euo pipefail
            source "$1/tools/release/common.sh"
            source "$1/tests/release/docker.sh"
            probe_id=$2
            trap probe_cleanup EXIT
            probe_run runtime linux/amd64 "$release_runtime" 2s "$3" \
                sh -c '\''trap "" TERM; while :; do sleep 1; done'\''
        ' _ "$release_root" "$test_probe_id" "$logs/timeout-container.log"
    remaining=$(timeout --signal=TERM --kill-after=2s 5s docker container ls --all --quiet --filter "name=^/$test_probe_id-runtime$")
    [[ -z "$remaining" ]] || release_fail 'timed-out probe container was not removed'
    test_probe_id=
    printf 'Passed: timed-out container removed\n'
fi
printf 'Failure handling checks passed. Evidence: %s\n' "$logs"

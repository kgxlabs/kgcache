#!/usr/bin/env bash
# Own the containers, image tags, and workspace created by one probe run.
# The caller sources common.sh, assigns these three values, and installs the
# probe_cleanup EXIT trap before creating resources. Names are unique per run.

probe_id=
probe_workspace=
probe_evidence_dir=

# Run one named container. Track its name before Docker can create it, including
# when the client times out before returning. Arguments after the log are the
# container command. All Docker client operations have deadlines.
probe_run() {
    local stage=$1 platform=$2 image=$3 deadline=$4 log=$5
    local container exit_code status
    shift 5
    container="$probe_id-$stage"
    if ! timeout --signal=TERM --kill-after=5s 30s docker create \
        --name "$container" --platform "$platform" "$image" "$@" > /dev/null 2> "$log"; then
        cat "$log" >&2
        release_fail "cannot create the $stage probe"
    fi
    status=0
    if timeout --signal=TERM --kill-after=5s "$deadline" docker start --attach "$container" > "$log.stdout" 2>> "$log"; then
        :
    else
        status=$?
    fi
    cat "$log.stdout" >> "$log"
    if [[ "$status" != 0 ]]; then
        cat "$log" >&2
        release_fail "$stage probe failed or timed out (status $status); log: $log"
    fi
    exit_code=$(timeout --signal=TERM --kill-after=5s 10s docker inspect --format '{{.State.ExitCode}}' "$container") ||
        release_fail "cannot inspect the $stage probe"
    [[ "$exit_code" == 0 ]] || release_fail "$stage probe exited with status $exit_code; log: $log"
}

# Preserve the original failure status. Cleanup errors fail an otherwise
# successful run and are reported instead of being silently discarded.
probe_cleanup() {
    local status=$? failed=false stage container_id image_id
    trap - EXIT
    if [[ -n "$probe_id" ]]; then
        for stage in runtime inspection tests; do
            if container_id=$(timeout --signal=TERM --kill-after=2s 5s docker container ls --all --quiet --filter "name=^/$probe_id-$stage$"); then
                if [[ -n "$container_id" ]]; then
                    if [[ "$stage" == tests && -n "$probe_evidence_dir" ]]; then
                        if ! timeout --signal=TERM --kill-after=2s 10s docker cp "$container_id:/evidence/." "$probe_evidence_dir/"; then
                            printf 'release: cannot collect process evidence from %s\n' "$container_id" >&2
                            failed=true
                        fi
                    fi
                    if ! timeout --signal=TERM --kill-after=2s 5s docker rm --force "$container_id" > /dev/null; then
                        printf 'release: cannot remove probe container %s\n' "$container_id" >&2
                        failed=true
                    fi
                fi
            else
                printf 'release: cannot list the %s probe container during cleanup\n' "$stage" >&2
                failed=true
            fi
            if image_id=$(timeout --signal=TERM --kill-after=2s 5s docker image ls --quiet "$probe_id:$stage"); then
                if [[ -n "$image_id" ]]; then
                    if ! timeout --signal=TERM --kill-after=2s 5s docker image rm "$probe_id:$stage" > /dev/null; then
                        printf 'release: cannot remove probe image %s:%s\n' "$probe_id" "$stage" >&2
                        failed=true
                    fi
                fi
            else
                printf 'release: cannot list the %s probe image during cleanup\n' "$stage" >&2
                failed=true
            fi
        done
    fi
    if [[ -n "$probe_workspace" ]]; then
        if ! rm -rf -- "$probe_workspace"; then
            printf 'release: cannot remove probe workspace %s\n' "$probe_workspace" >&2
            failed=true
        fi
    fi
    if [[ "$status" == 0 && "$failed" == true ]]; then status=1; fi
    exit "$status"
}

#!/usr/bin/env bash
# Check or format project shell scripts with pinned tools in Docker.
set -euo pipefail

readonly SHELLCHECK_IMAGE='docker.io/koalaman/shellcheck:v0.11.0'
readonly SHFMT_IMAGE='docker.io/mvdan/shfmt:v3.12.0'

# Resource ownership for the EXIT trap. Containers have a unique label before
# Docker starts them so interrupted clients cannot leave untracked containers.
shell_file_list=
shell_run_id=

fail() {
    printf 'shell checks: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$? failed=false container_ids container_id

    trap - EXIT

    if [[ -n "$shell_run_id" ]]; then
        if container_ids=$(timeout --signal=TERM --kill-after=2s 5s \
            docker container ls --all --quiet \
            --filter "label=kgcache.shell.run=$shell_run_id"); then
            while IFS= read -r container_id; do
                [[ -n "$container_id" ]] || continue
                if ! timeout --signal=TERM --kill-after=2s 5s \
                    docker rm --force "$container_id" > /dev/null; then
                    printf 'shell checks: cannot remove container %s\n' \
                        "$container_id" >&2
                    failed=true
                fi
            done <<< "$container_ids"
        else
            printf 'shell checks: cannot list owned containers during cleanup\n' >&2
            failed=true
        fi
    fi

    if [[ -n "$shell_file_list" ]]; then
        if ! rm -f -- "$shell_file_list"; then
            failed=true
        fi
    fi

    if [[ "$status" == 0 && "$failed" == true ]]; then
        status=1
    fi
    exit "$status"
}

main() {
    local mode=check repo_root mount user_id group_id script command_name \
        engine_arch platform
    local shellcheck_image shfmt_image
    local scripts=() docker_args=()

    case "${1:-}" in
        '') [[ $# == 0 ]] || fail 'unexpected empty argument' ;;
        --write)
            [[ $# == 1 ]] || fail '--write accepts no additional arguments'
            mode='write'
            ;;
        --help)
            printf 'Usage: bash tools/shell/check.sh [--write]\n'
            return
            ;;
        *) fail "unknown argument: $1" ;;
    esac

    for command_name in docker git timeout id mktemp; do
        command -v "$command_name" > /dev/null ||
            fail "required command is missing: $command_name"
    done

    engine_arch=$(timeout --signal=TERM --kill-after=5s 15s \
        docker info --format '{{.Architecture}}')
    case "$engine_arch" in
        x86_64 | amd64)
            platform=linux/amd64
            shellcheck_image="$SHELLCHECK_IMAGE@sha256:b9389b73c8f26f710a7171cb7d8848a34a9c1e07a7865e727c9ec4ce99f9a83f"
            shfmt_image="$SHFMT_IMAGE@sha256:01f6686da9027034e23411b79986a2deda3b604f45c8cf4e606e219ac6331334"
            ;;
        aarch64 | arm64)
            platform=linux/arm64
            shellcheck_image="$SHELLCHECK_IMAGE@sha256:4d7c931ae7ee555483ceac75379369f1bc5f01807be6638d12ede9ce29a27b53"
            shfmt_image="$SHFMT_IMAGE@sha256:34d9cdd0ff81ddb79fe3e9e8ba873e818f56ee8f7b148cd607c68935604d5986"
            ;;
        *)
            fail "unsupported Docker engine architecture: $engine_arch"
            ;;
    esac

    repo_root=$(cd -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
    cd "$repo_root"
    mkdir -p .zig-cache

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    shell_file_list=$(mktemp "$repo_root/.zig-cache/shell-files.XXXXXX")
    shell_run_id=${shell_file_list##*/}

    git ls-files --cached --others --exclude-standard -z -- '*.sh' \
        > "$shell_file_list"
    while IFS= read -r -d '' script; do
        scripts+=("$script")
    done < "$shell_file_list"
    [[ ${#scripts[@]} -gt 0 ]] || fail 'no shell scripts were found'

    mount="type=bind,src=$repo_root,dst=/workspace"
    if [[ "$mode" == check ]]; then
        mount="$mount,readonly"
    fi
    user_id=$(id -u)
    group_id=$(id -g)
    docker_args=(
        run --rm
        --platform "$platform"
        --label "kgcache.shell.run=$shell_run_id"
        --user "$user_id:$group_id"
        --mount "$mount"
        --workdir /workspace
    )

    if [[ "$mode" == write ]]; then
        timeout --signal=TERM --kill-after=5s 180s \
            docker "${docker_args[@]}" "$shfmt_image" -w "${scripts[@]}"
    else
        printf 'Checking shell scripts with ShellCheck 0.11.0...\n'
        timeout --signal=TERM --kill-after=5s 180s \
            docker "${docker_args[@]}" "$shellcheck_image" "${scripts[@]}"

        printf 'Checking shell formatting with shfmt 3.12.0...\n'
        timeout --signal=TERM --kill-after=5s 180s \
            docker "${docker_args[@]}" "$shfmt_image" -d "${scripts[@]}"
    fi
}

main "$@"

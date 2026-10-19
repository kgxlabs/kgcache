#!/usr/bin/env bash

release_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
release_zig_version=0.16.0
release_glibc_version=2.36
release_runtime='docker.io/library/debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587'

release_fail() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

# Print source state only after Git has completed successfully.
release_git_revision() {
    git rev-parse HEAD || release_fail 'cannot read the source revision'
}

release_git_status() {
    git status --porcelain --untracked-files=normal || release_fail 'cannot read Git status'
}

# Require the same clean source revision as the artifact being tested.
release_assert_source() {
    local revision status
    revision=$(release_git_revision) || return 1
    status=$(release_git_status) || return 1
    [[ "$revision" == "$1" ]] || release_fail 'test tools and release must use the same source commit'
    [[ -z "$status" ]] || release_fail 'runtime checks require a clean source tree'
}

release_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

release_platform() {
    case "$1" in
        linux/amd64)
            release_arch=x86_64
            release_file_arch=x86-64
            release_elf_machine='Advanced Micro Devices X86-64'
            release_loader=/lib64/ld-linux-x86-64.so.2
            ;;
        linux/arm64)
            release_arch=aarch64
            release_file_arch=aarch64
            release_elf_machine=AArch64
            release_loader=/lib/ld-linux-aarch64.so.1
            ;;
        *) release_fail "unsupported platform: $1" ;;
    esac
    release_target="$release_arch-linux-gnu.$release_glibc_version"
}

release_check_binary() {
    local description
    [[ -f "$1" && -x "$1" ]] || release_fail "missing executable: $1"
    description=$(file -b "$1")
    [[ "$description" == *'ELF 64-bit LSB'* && "$description" == *"$release_file_arch"* ]] ||
        release_fail "wrong executable format or architecture: $description"
}

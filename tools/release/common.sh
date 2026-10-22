#!/usr/bin/env bash
# Shared release helpers. Only immutable settings are exported through globals.
# Functions print results to stdout and report failures to stderr.

release_fail() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

RELEASE_ROOT=$(cd -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
# Public constant used by the scripts that source this library.
# shellcheck disable=SC2034
readonly RELEASE_ROOT

source "${BASH_SOURCE[0]%/*}/settings.sh"
export LC_ALL=C

# Check dependencies before creating output or starting downloads.
release_require_commands() {
    local command_name

    for command_name in "$@"; do
        if ! command -v "$command_name" > /dev/null 2>&1; then
            release_fail "required command is missing: $command_name"
        fi
    done
}

release_require_sha256() {
    if ! command -v sha256sum > /dev/null 2>&1 &&
        ! command -v shasum > /dev/null 2>&1; then
        release_fail 'SHA-256 requires sha256sum or shasum'
    fi
}

# Validate a long option's value without consuming the next option.
release_require_value() {
    if [[ -z "$2" || "$2" == --* ]]; then
        release_fail "missing value for $1"
    fi
}

release_sha256() {
    local output

    if command -v sha256sum > /dev/null 2>&1; then
        output=$(sha256sum < "$1") || release_fail "cannot checksum $1"
    else
        output=$(shasum -a 256 < "$1") || release_fail "cannot checksum $1"
    fi

    printf '%s\n' "${output%% *}"
}

release_git_revision() {
    git rev-parse HEAD || release_fail 'cannot read the source revision'
}

release_git_status() {
    git status --porcelain --untracked-files=normal ||
        release_fail 'cannot read Git status'
}

# Require the same clean revision as the artifact being tested.
release_assert_source() {
    local revision status

    revision=$(release_git_revision) || return 1
    status=$(release_git_status) || return 1

    [[ "$revision" == "$1" ]] ||
        release_fail 'test tools and release must use the same source commit'
    [[ -z "$status" ]] ||
        release_fail 'runtime checks require a clean source tree'
}

# Platform lookups return one value and never mutate the caller's variables.
release_target() {
    case "$1" in
        linux/amd64) printf 'x86_64-linux-gnu.%s\n' "$GLIBC_VERSION" ;;
        linux/arm64) printf 'aarch64-linux-gnu.%s\n' "$GLIBC_VERSION" ;;
        *) release_fail "unsupported platform: $1" ;;
    esac
}

release_loader() {
    case "$1" in
        linux/amd64) printf '/lib64/ld-linux-x86-64.so.2\n' ;;
        linux/arm64) printf '/lib/ld-linux-aarch64.so.1\n' ;;
        *) release_fail "unsupported platform: $1" ;;
    esac
}

release_machine() {
    case "$1" in
        linux/amd64) printf 'Advanced Micro Devices X86-64\n' ;;
        linux/arm64) printf 'AArch64\n' ;;
        *) release_fail "unsupported platform: $1" ;;
    esac
}

release_check_binary() {
    local binary=$1 platform=$2 description expected

    case "$platform" in
        linux/amd64) expected=x86-64 ;;
        linux/arm64) expected=aarch64 ;;
        *) release_fail "unsupported platform: $platform" ;;
    esac

    [[ -f "$binary" && -x "$binary" ]] ||
        release_fail "missing executable: $binary"
    description=$(file -b -- "$binary") ||
        release_fail "cannot inspect $binary"

    if [[ "$description" != *'ELF 64-bit LSB'* ||
        "$description" != *"$expected"* ]]; then
        release_fail "wrong executable format or architecture: $description"
    fi
}

# Read a scalar from a validated build record. Convert booleans to strings so
# jq's exit status does not confuse a valid false value with a command failure.
release_read_field() {
    jq -er \
        "$2 | if . == null then error(\"missing field\") else tostring end" \
        "$1" ||
        release_fail "cannot read build record field $2 from $1"
}

release_validate_version() {
    local value=$1 name=${2:-version}

    if ! jq --exit-status --null-input -L "$RELEASE_ROOT/tools/release" \
        --arg version "$value" 'include "semver"; $version | semver' > /dev/null; then
        release_fail "$name must be SemVer 2.0.0"
    fi
}

release_development_version() {
    local version

    version=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' \
        "$RELEASE_ROOT/build.zig.zon") || release_fail 'cannot read package version'
    release_validate_version "$version" 'development version'
    printf '%s\n' "$version"
}

# Keep server and test-tool compilation on the same release contract.
# Extra arguments select optional Zig build steps such as integration-tools.
release_compile() {
    local compiler=$1 output=$2 platform=$3 version=$4 target

    shift 4
    target=$(release_target "$platform") || return 1

    timeout --signal=TERM --kill-after=10s 600s \
        "$compiler" build "$@" \
        "-Dtarget=$target" \
        "-Dcpu=$RELEASE_CPU" \
        "-Doptimize=$RELEASE_OPTIMIZE" \
        "-Dversion=$version" \
        --prefix "$output"
}

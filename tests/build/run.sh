#!/usr/bin/env bash
# Check native defaults, foreign builds, and rejection of foreign execution.
set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

check_root=

check_native_build() {
    local compiler=$1 system=$2 description expected version actual

    "$compiler" build --prefix "$check_root/native"

    description=$(file -b "$check_root/native/bin/kgcache")
    case "$system" in
        Darwin) expected=Mach-O ;;
        Linux) expected=ELF ;;
        *) release_fail 'build checks require macOS or Linux' ;;
    esac
    [[ "$description" == *"$expected"* ]] ||
        release_fail "default build is not native: $description"
    version=$(release_development_version)
    actual=$("$check_root/native/bin/kgcache" --version)
    [[ "$actual" == "kgcache $version" ]] ||
        release_fail 'default executable version differs from the package version'
}

check_versions() {
    local compiler=$1 version output executable actual

    "$compiler" build test-build
    jq -e -L "$RELEASE_ROOT/tools/release" \
        'include "semver"; all(.[]; (.value | semver) == .valid)' \
        tests/build/semver-cases.json > /dev/null

    for version in 0.2.0 0.2.0-rc.1 \
        0.2.0-rc.1+local.001 184467440737095516160.2.3; do
        "$compiler" build integration-tools "-Dversion=$version" \
            --prefix "$check_root/versioned"
        "$compiler" build "-Dversion=$version" --prefix "$check_root/versioned"
        for executable in bin/kgcache libexec/kgcache-tests/kgcache-controlled-server; do
            actual=$("$check_root/versioned/$executable" --version)
            [[ "$actual" == "kgcache $version" ]] ||
                release_fail "explicit version differs in $executable"
        done
    done

    for version in '' v0.2.0 0.2.0-01; do
        if "$compiler" build "-Dversion=$version" > "$check_root/version.log" 2>&1; then
            release_fail 'invalid build version was accepted'
        fi
        output=$(cat "$check_root/version.log")
        [[ "$output" == *'version must be SemVer 2.0.0'* ]] ||
            release_fail 'invalid build version failed for an unexpected reason'
    done
}

check_foreign_build() {
    local compiler=$1 target=$2 expected=$3 description

    "$compiler" build "-Dtarget=$target" -Dcpu=baseline \
        --prefix "$check_root/foreign"

    description=$(file -b "$check_root/foreign/bin/kgcache")
    if [[ "$description" != *'ELF 64-bit LSB'* ||
        "$description" != *"$expected"* ]]; then
        release_fail "explicit target produced an unexpected executable: $description"
    fi
}

check_execution_guards() {
    local compiler=$1 target=$2 step output

    for step in run test test-integration; do
        if "$compiler" build "$step" "-Dtarget=$target" \
            > "$check_root/$step.log" 2>&1; then
            release_fail "$step unexpectedly accepted a foreign execution target"
        fi

        output=$(cat "$check_root/$step.log")
        if [[ "$output" != *'cannot run natively on build host'* ]]; then
            cat "$check_root/$step.log" >&2
            release_fail "$step failed for an unexpected reason"
        fi
    done
}

cleanup_build_checks() {
    local status=$?

    trap - EXIT

    if [[ -n "$check_root" ]]; then
        rm -rf -- "$check_root"
    fi

    exit "$status"
}

main() {
    local compiler=${ZIG-zig} system arch \
        target=x86_64-linux-gnu.2.36 expected=x86-64

    [[ -n "$compiler" ]] || release_fail 'ZIG must name a compiler executable'
    release_require_commands "$compiler" file uname mktemp jq sed

    system=$(uname -s)
    arch=$(uname -m)
    if [[ "$system" == Linux && "$arch" == x86_64 ]]; then
        target=aarch64-linux-gnu.2.36
        expected=aarch64
    fi

    cd "$RELEASE_ROOT"
    mkdir -p .zig-cache

    trap cleanup_build_checks EXIT
    check_root=$(mktemp -d "$RELEASE_ROOT/.zig-cache/build-check.XXXXXX")

    check_native_build "$compiler" "$system"
    check_versions "$compiler"
    check_foreign_build "$compiler" "$target" "$expected"
    check_execution_guards "$compiler" "$target"

    printf 'Native defaults, SemVer inputs, explicit Linux output, and foreign run guards passed.\n'
}

main "$@"

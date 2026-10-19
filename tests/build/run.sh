#!/usr/bin/env bash
# Check native defaults, foreign compilation, and rejection of foreign execution.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../../tools/release/common.sh"

check_root=

check_native_build() {
    local compiler=$1 system=$2 description expected
    "$compiler" build --prefix "$check_root/native"
    description=$(file -b "$check_root/native/bin/kgcache")
    case "$system" in
        Darwin) expected=Mach-O ;;
        Linux) expected=ELF ;;
        *) release_fail 'build checks require macOS or Linux' ;;
    esac
    [[ "$description" == *"$expected"* ]] || release_fail "default build is not native: $description"
}

check_foreign_build() {
    local compiler=$1 target=$2 expected=$3 description
    "$compiler" build "-Dtarget=$target" -Dcpu=baseline --prefix "$check_root/foreign"
    description=$(file -b "$check_root/foreign/bin/kgcache")
    if [[ "$description" != *'ELF 64-bit LSB'* || "$description" != *"$expected"* ]]; then
        release_fail "explicit target produced an unexpected executable: $description"
    fi
}

check_execution_guards() {
    local compiler=$1 target=$2 step output
    for step in run test test-integration; do
        if "$compiler" build "$step" "-Dtarget=$target" > "$check_root/$step.log" 2>&1; then
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
    if [[ -n "$check_root" ]]; then rm -rf -- "$check_root"; fi
    exit "$status"
}

main() {
    local compiler=${ZIG-zig} system arch target=x86_64-linux-gnu.2.36 expected=x86-64
    [[ -n "$compiler" ]] || release_fail 'ZIG must name a compiler executable'
    release_require_commands "$compiler" file uname mktemp
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
    check_foreign_build "$compiler" "$target" "$expected"
    check_execution_guards "$compiler" "$target"
    printf 'Native output, explicit Linux output, and foreign run guards passed.\n'
}

main "$@"

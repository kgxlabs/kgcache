#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
zig_command=${ZIG:-zig}
cd "$repo_root"
mkdir -p .zig-cache
check_root=$(mktemp -d "$repo_root/.zig-cache/build-check.XXXXXX")
trap 'rm -rf -- "$check_root"' EXIT

"$zig_command" build --prefix "$check_root/native"
native_description=$(file -b "$check_root/native/bin/kgcache")
case $(uname -s) in
    Darwin) expected_native='Mach-O' ;;
    Linux) expected_native='ELF' ;;
    *) printf 'Build checks require macOS or Linux.\n' >&2; exit 1 ;;
esac
if [[ "$native_description" != *"$expected_native"* ]]; then
    printf 'Default build is not native: %s\n' "$native_description" >&2
    exit 1
fi

foreign_arch=x86_64
foreign_description=x86-64
if [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]; then
    foreign_arch=aarch64
    foreign_description=aarch64
fi
target="$foreign_arch-linux-gnu.2.36"
"$zig_command" build "-Dtarget=$target" -Dcpu=baseline --prefix "$check_root/foreign"
description=$(file -b "$check_root/foreign/bin/kgcache")
if [[ "$description" != *'ELF 64-bit LSB'* || "$description" != *"$foreign_description"* ]]; then
    printf 'Explicit target produced an unexpected executable: %s\n' "$description" >&2
    exit 1
fi

for step in run test test-integration; do
    if "$zig_command" build "$step" "-Dtarget=$target" >"$check_root/guard.log" 2>&1; then
        printf '%s unexpectedly accepted a foreign execution target.\n' "$step" >&2
        exit 1
    fi
    if [[ $(<"$check_root/guard.log") != *'cannot run natively on build host'* ]]; then
        cat "$check_root/guard.log" >&2
        exit 1
    fi
done
printf 'Native output, explicit Linux output, and foreign run guards passed.\n'

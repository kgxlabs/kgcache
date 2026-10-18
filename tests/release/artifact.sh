#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
[[ $# -eq 1 ]] || { printf 'Usage: bash tests/release/artifact.sh RELEASE_PREFIX\n' >&2; exit 1; }
prefix=$(cd "$1" && pwd)
bash tools/release/verify.sh --prefix "$prefix"
test_root=$(mktemp -d "$repo_root/.zig-cache/artifact-check.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin"
cp "$prefix/bin/kgcache" "$test_root/bin/kgcache"
cp "$prefix/build-info.json" "$test_root/build-info.json"
expect_rejection() {
    if bash tools/release/verify.sh --prefix "$test_root" >"$test_root/check.log" 2>&1; then
        printf 'Invalid release artifact was accepted.\n' >&2
        exit 1
    fi
}
printf 'changed' >>"$test_root/bin/kgcache"
expect_rejection
cp "$prefix/bin/kgcache" "$test_root/bin/kgcache"
jq '.target = "wrong-target"' "$prefix/build-info.json" >"$test_root/build-info.json"
expect_rejection
jq '.platform = "linux/arm64" | .target = "aarch64-linux-gnu.2.36"' "$prefix/build-info.json" >"$test_root/build-info.json"
expect_rejection
jq '.source.dirty = true' "$prefix/build-info.json" >"$test_root/build-info.json"
expect_rejection
jq '.persistence_test_controls = true' "$prefix/build-info.json" >"$test_root/build-info.json"
expect_rejection
cp "$prefix/build-info.json" "$test_root/build-info.json"
printf 'not an ELF executable\n' >"$test_root/bin/kgcache"
expect_rejection
rm "$test_root/bin/kgcache"
expect_rejection
printf 'Artifact integrity and invalid-input checks passed.\n'

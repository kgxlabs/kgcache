#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

[[ $# -eq 1 ]] || release_fail 'usage: bash tools/release/inspect.sh RELEASE_PREFIX'
prefix=$1
bash "$(dirname -- "${BASH_SOURCE[0]}")/verify.sh" --prefix "$prefix"
release_platform "$(jq -r .platform "$prefix/build-info.json")"
binary="$prefix/bin/kgcache"
reader=${READELF:-readelf}
header=$("$reader" -h "$binary")
[[ "$header" == *ELF64* && "$header" == *'little endian'* && "$header" == *"$release_elf_machine"* ]] ||
    release_fail 'unexpected ELF class, byte order, or machine'
interpreter=$("$reader" -l "$binary" | sed -nE 's/.*Requesting program interpreter: ([^]]+)\].*/\1/p')
[[ "$interpreter" == "$release_loader" ]] || release_fail "unexpected dynamic loader: $interpreter"
dynamic=$("$reader" -d "$binary")
if [[ "$dynamic" == *'(RPATH)'* || "$dynamic" == *'(RUNPATH)'* ]]; then
    release_fail 'release binary contains a runtime library search path'
fi
needed=$(printf '%s\n' "$dynamic" | sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p' | sort -u)
[[ -n "$needed" ]] || release_fail 'missing dynamic dependency information'
versions=$("$reader" --version-info "$binary" | awk '{for (i=1;i<NF;i++) if ($i == "Name:" && $(i+1) ~ /^GLIBC_/) print $(i+1)}' | sort -u)
[[ -n "$versions" ]] || release_fail 'missing glibc symbol version requirements'
printf '%s\n' "$versions" | awk -v limit="$release_glibc_version" '
    BEGIN {split(limit, allowed, ".")}
    {if ($0 !~ /^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$/) exit 1;
     sub(/^GLIBC_/, ""); split($0, required, ".");
     if (required[1] > allowed[1] || (required[1] == allowed[1] && required[2] > allowed[2]) ||
         (required[1] == allowed[1] && required[2] == allowed[2] && required[3] + 0 > allowed[3] + 0)) exit 1}
' || release_fail "binary requires unsupported glibc symbols (baseline $release_glibc_version)"
needed_json=$(printf '%s\n' "$needed" | jq -R . | jq -s .)
versions_json=$(printf '%s\n' "$versions" | jq -R . | jq -s .)
jq -n --arg interpreter "$interpreter" --argjson needed "$needed_json" --argjson versions "$versions_json" \
    '{class: "ELF64", byte_order: "little", interpreter: $interpreter, needed: $needed, glibc_versions: $versions}'

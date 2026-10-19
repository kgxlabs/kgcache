#!/usr/bin/env bash
# Check the unmodified runtime libraries and the copied release executable.
set -euo pipefail
export LC_ALL=C

main() {
    [[ ! -e /tests && ! -e /probe ]] || {
        printf 'Runtime contains diagnostic or process test tools.\n' >&2
        exit 1
    }
    if command -v zig > /dev/null 2>&1; then
        printf 'Runtime contains a compiler.\n' >&2
        exit 1
    fi
    ldd /usr/local/bin/kgcache
    sha256sum /usr/local/bin/kgcache
}

main "$@"

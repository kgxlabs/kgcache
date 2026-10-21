#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
    printf 'Usage: bash tools/commitlint/check.sh BASE HEAD\n' >&2
    exit 2
fi

lint_root=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
cli="$lint_root/node_modules/@commitlint/cli/cli.js"
if [[ ! -f "$cli" ]]; then
    printf 'Install commit lint tools: npm ci --prefix tools/commitlint --include=dev --ignore-scripts\n' >&2
    exit 1
fi

base_sha=$(git rev-parse --verify --end-of-options "${1}^{commit}")
head_sha=$(git rev-parse --verify --end-of-options "${2}^{commit}")
# Git identifies merge commits by their parent count.
commits=$(git rev-list --reverse --no-merges "$base_sha..$head_sha")
failed=0

while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    printf 'Checking commit %s\n' "$commit"
    if ! git show --no-patch --format=%B "$commit" |
        node "$cli" --config "$lint_root/commitlint.config.js" --strict --verbose; then
        failed=1
    fi
done <<< "$commits"

exit "$failed"

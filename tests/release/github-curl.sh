#!/usr/bin/env bash
# Local GET-only API transport for release-history fixtures.
set -euo pipefail

for argument in "$@"; do
    if [[ "$argument" == http://127.0.0.1:* ]]; then
        [[ -n "${GITHUB_FIXTURE_ROOT:-}" && -n "${GITHUB_FIXTURE_REAL_CURL:-}" ]]
        exec "$GITHUB_FIXTURE_REAL_CURL" "$@"
    fi
done

output='' headers='' url=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            output=$2
            shift 2
            ;;
        --dump-header)
            headers=$2
            shift 2
            ;;
        --header | --max-time | --connect-timeout | --retry | --retry-max-time | --max-filesize | --proto)
            shift 2
            ;;
        --fail | --silent | --show-error | --tlsv1.2) shift ;;
        https://api.github.com/*)
            url=${1#https://api.github.com}
            shift
            ;;
        *)
            printf 'Unsupported fixture curl argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done
[[ -n "$url" && -n "$output" && -n "$headers" ]]
printf 'GET %s\n' "$url" >> "$GITHUB_FIXTURE_ROOT/calls.log"
file=$(jq -er --arg url "$url" '.[$url].file' "$GITHUB_FIXTURE_ROOT/routes.json")
cp "$GITHUB_FIXTURE_ROOT/$file" "$output"
printf 'HTTP/2 200\r\n' > "$headers"
next=$(jq -r --arg url "$url" '.[$url].next // empty' "$GITHUB_FIXTURE_ROOT/routes.json")
if [[ -n "$next" ]]; then
    printf 'Link: <%s>; rel="next"\r\n' "$next" >> "$headers"
fi

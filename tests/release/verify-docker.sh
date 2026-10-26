#!/usr/bin/env bash
# Docker CLI fixture for clean-pull preflight checks. It never pulls an image.
set -euo pipefail

printf '%s\n' "$*" >> "${VERIFY_FIXTURE_CALLS:?}"
case "$*" in
    'info --format {{.ID}}') printf 'shared-engine\n' ;;
    'info --format {{.Architecture}}') printf 'x86_64\n' ;;
    'image inspect sha256:'*)
        case "${VERIFY_FIXTURE_MODE:?}" in
            present) printf '[]\n' ;;
            missing)
                printf 'Error response from daemon: No such image: %s\n' "$3" >&2
                exit 1
                ;;
            daemon-error)
                printf 'Cannot connect to the Docker daemon\n' >&2
                exit 1
                ;;
            timeout)
                printf 'Docker inspect timed out\n' >&2
                exit 124
                ;;
            unrelated-missing)
                printf 'Error response from daemon: No such image: unrelated\n' >&2
                exit 1
                ;;
            *) exit 64 ;;
        esac
        ;;
    'image pull --platform linux/amd64 '*)
        printf 'fixture reached digest pull\n' >&2
        exit 75
        ;;
    *)
        printf 'Unexpected Docker fixture command: %s\n' "$*" >&2
        exit 64
        ;;
esac

#!/usr/bin/env bash
# Immutable inputs shared by the release builder and runtime checks.
# shellcheck disable=SC2034
readonly ZIG_VERSION=0.16.0
readonly GLIBC_VERSION=2.36
readonly RELEASE_CPU=baseline
readonly RELEASE_OPTIMIZE=ReleaseSafe
readonly RUNTIME_BASE='docker.io/library/debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587'

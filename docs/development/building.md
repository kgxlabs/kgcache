# Build versions

[Developer documentation](README.md)

Use Zig 0.16.0. Ordinary builds read their version from `build.zig.zon`.
To build a different version without editing source files:

```sh
zig build -Dversion=0.2.0
zig-out/bin/kgcache --version
```

The executable prints `kgcache 0.2.0` and exits. `--version` must be its only
argument. It does not read configuration or start the server. The server's
`HELLO` reply reports the same effective version. The health command runs
from this same executable. Controlled integration-test servers also use the
selected build version.

## Version format

All build entry points accept [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html):
`MAJOR.MINOR.PATCH`, with optional prerelease identifiers and build metadata.
Pass the version without a `v` prefix.

Examples: `0.2.0`, `0.2.0-rc.1`, `0.2.0+local.001`, and
`0.2.0-rc.1+local.001`. Core numbers and numeric prerelease identifiers cannot
have leading zeroes. Metadata may contain them. Identifiers use ASCII letters,
digits, and hyphens. Whitespace and empty identifiers are rejected. Numeric
fields are kept as strings, with no fixed integer-size limit.

An omitted input uses the development default. An explicit empty `-Dversion`
or missing `--version` value is an error. Docker uses an empty `VERSION` as
the omitted development input; clean image builds require an explicit value.

## Linux artifacts

The release builder accepts the same version:

```sh
bash tools/release/build.sh --version 0.2.0
bash tools/release/verify.sh --version 0.2.0
```

These commands only build and verify local files. They create no Git tags,
registry uploads, or GitHub releases. See [release checks](../../tests/release/README.md)
for prerequisites, platforms, and runtime qualification.

Build records use schema version `2`. `version` is the effective build version.
`development_version` is the default from `build.zig.zon`. Both fields are
required SemVer strings. Existing schema `1` artifacts need rebuilding.
The record also keeps source revision, dirty state, and the binary checksum.
An explicit version changes none of those provenance rules.

`verify.sh --version` checks the expected version in the record. It verifies
the binary checksum and architecture without executing a foreign binary.
The Bookworm runtime and container checks also compare the running executable's
version with its record. Container checks compare the OCI label too.

## Container images

Pass an explicit version as a build argument. Use a local image tag that is
valid for Docker; SemVer build metadata belongs in `VERSION`, not the image tag.

```sh
docker build --platform linux/amd64 \
  --build-arg VERSION=0.2.0-rc.1+local.001 \
  --tag kgcache:local .
docker run --rm --platform linux/amd64 kgcache:local --version
```

This development image records unknown source and dirty state. Its binary,
build record, and OCI version label all carry the explicit version. Without
`VERSION`, the binary and record use the development default and the label
stays empty. For clean images, also supply verified `SOURCE_REVISION` and
`SOURCE_DIRTY=false`. See [container checks](../../tests/container/README.md).

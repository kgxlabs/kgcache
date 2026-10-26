# Build and inspect a version

[Docs](../README.md) / [Contribute](README.md) / Builds

Build the native executable with Zig 0.16.0:

```sh
zig build
zig-out/bin/kgcache --version
```

The ordinary build reads its development version from
[build.zig.zon](../../build.zig.zon). The executable is installed at
`zig-out/bin/kgcache`.

## Select a version

Supply a version as build input instead of editing the package file:

```sh
zig build -Dversion=0.2.0
zig-out/bin/kgcache --version
```

The result prints `kgcache 0.2.0`. Its HELLO metadata reports that same version.
The health command and controlled integration server use the same effective
build input. `--version` must be the executable's only argument; it reads no
config and starts no server.

All build entry points use [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html).
Omit the leading `v`. Valid inputs include `0.2.0`, `0.2.0-rc.1`,
`0.2.0+local.001`, and `0.2.0-rc.1+local.001`.

Core numbers and numeric prerelease identifiers reject leading zeroes.
Build metadata permits them. Identifiers contain ASCII letters, digits, or
hyphens. Empty identifiers and whitespace fail validation. Numeric fields are
stored as strings, without a fixed integer-size limit.

An omitted version uses the package default. An explicit empty `-Dversion`
fails. A missing value after a script's `--version` also fails. Docker treats
an empty `VERSION` as an omitted development input, but a clean image requires
an explicit version.

## Build for another target

Cross-compile without running the result:

```sh
zig build -Dtarget=x86_64-linux-gnu.2.36 -Doptimize=ReleaseSafe \
  --prefix zig-out/linux-amd64
```

Executable run and test steps require a target the build host can run natively.
Compile success does not establish runtime support. Use
[build checks](../../tests/build/README.md) to test those guards.

## Create a Linux artifact

```sh
bash tools/release/build.sh --version 0.2.0
bash tools/release/verify.sh --version 0.2.0
```

These local commands create and verify files. They do not request publication.
The [release checks](../../tests/release/README.md) describe host tools, target
settings, artifact paths, and native Bookworm execution.

The build record uses schema `2`. It contains `version`, the effective input,
and `development_version`, the package default. Both must be valid SemVer.
It also records the source commit, dirty state, target, compiler, runtime base,
and executable checksum. Override input does not change those provenance rules.
Rebuild old schema `1` artifacts before using current qualification tools.

`verify.sh` checks the record, expected version, checksum, and architecture
without running a foreign executable. Runtime checks compare the binary's
reported version too. Image checks also compare the OCI label.

## Build a development image

```sh
docker build --platform linux/amd64 \
  --build-arg VERSION=0.2.0-rc.1+local.001 \
  --tag kgcache:local .
docker run --rm --platform linux/amd64 kgcache:local --version
```

Use a valid Docker tag separately from the SemVer input. A SemVer `+` metadata
suffix is valid in `VERSION`, but not in the image tag.

By default, local builds record unknown source and dirty state. With an explicit
version, the executable, record, and OCI version label agree. Without one, the
executable and record use the development default while the label is empty.

A clean image additionally needs a verified full `SOURCE_REVISION` and
`SOURCE_DIRTY=false`. See [image checks](../../tests/container/README.md)
for those requirements and [candidate qualification](release-candidates.md)
for the exact source-to-image path.

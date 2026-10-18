# Linux release checks

Use Bash, Git, curl, tar with xz support, jq, `file`, and a SHA-256 tool
(`sha256sum` or `shasum`). Run from a clean checkout:

```sh
bash tools/release/build.sh
bash tools/release/verify.sh
bash tests/release/artifact.sh zig-out/release/linux-amd64
```

The build downloads Zig 0.16.0 for the build host, verifies its pinned official
archive checksum, and caches it under `.zig-cache/toolchains`. The output target
is Linux amd64 with baseline CPU features, glibc 2.36, and ReleaseSafe.

Output lives under `zig-out/release/linux-amd64/`:

```text
bin/kgcache
build-info.json
```

The build record includes the package version, source commit, clean/dirty state,
platform, target, mode, compiler version and archive checksum, runtime base,
and executable checksum. It contains no build-host paths or timestamps.
Persistence test controls are disabled in the release server.

Use `--prefix DIR` for an isolated output location. The ordinary `zig-out/bin`
development build does not replace this release output. `--allow-dirty` creates
a marked development artifact; verification rejects it unless that option is
also supplied. Do not use that option for release qualification.

Build the arm64 candidate separately:

```sh
bash tools/release/build.sh --platform linux/arm64
bash tools/release/verify.sh --prefix zig-out/release/linux-arm64
```

An arm64 build is not a runtime support claim. Build success and runtime
qualification are separate checks.

With GNU readelf available, inspect a clean artifact's loader, dependencies,
and glibc symbol requirements:

```sh
bash tools/release/inspect.sh zig-out/release/linux-amd64
```

Set `READELF` to select a compatible reader. This check rejects runtime library
search paths and glibc requirements newer than the selected baseline. Runtime
library resolution must also be checked in the selected Debian filesystem.

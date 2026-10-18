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

Run the Bookworm checks with Docker and GNU `timeout` available:

```sh
bash tests/release/run.sh
```

The Docker engine must run Linux amd64. The runner rejects other engine
architectures by default. On an arm64 development machine with amd64 emulation
enabled, use:

```sh
bash tests/release/run.sh --allow-emulation
```

Emulation provides a smoke check. Its result records `native_execution: false`
and `initial_amd64_qualified: false`. Native amd64 qualification runs in the
`Native Linux amd64 release on Bookworm` CI job. Arm64 remains a build candidate.

The runner requires a clean checkout at the artifact's recorded commit. It builds
the existing Zig process test tools for that target with the pinned compiler.
The `integration-tools` build step exports those tools only when requested.
It never adds them to an ordinary release install.

The test-only Dockerfile has three stages. The runtime stage contains the pinned
Bookworm filesystem and the exact release server. It has no compiler or test
servers. Library resolution and a binary checksum check run in this stage. The inspection
stage adds diagnostic packages for ELF checks. The tests stage adds process
test tools without installing extra runtime libraries. These temporary images
are removed after the run. This Dockerfile is a test fixture for release checks.

The process tests cover raw RESP PING, binary SET/GET, ordered pipelines,
SIGTERM, snapshot reload, AOF reload, and the existing persistence failure cases.
They run the supplied release server. Only cases that need persistence controls
use a separate controlled server. An invalid test-control setting also checks
that the ordinary release server ignores those controls.

Each run saves evidence in a new directory under
`test-artifacts/release/linux-amd64/`. It includes the
build record, ELF report, resolved libraries, process log, and result record.
Failed process cases also save their harness evidence. Use `--prefix DIR` to
select another artifact and `--artifacts DIR` to select an evidence directory.
Compiler objects and verified downloads are cached; test persistence state is
temporary. Each build, inspection, and process phase has a deadline.

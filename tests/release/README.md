# Linux release checks

Use Bash 3.2 or later on macOS or Linux. Install Git, curl, tar with xz support,
jq, `file`, GNU `timeout`, and a SHA-256 tool (`sha256sum` or `shasum`). Scripts
check their dependencies before building or creating release output.
Run from a clean checkout:

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

The build record includes the effective version, development default, source commit, clean/dirty state,
platform, target, mode, compiler version and archive checksum, runtime base,
and executable checksum. It contains no build-host paths or timestamps.
Persistence test controls are disabled in the release server.

Use `--version SEMVER` to select an explicit version without changing
`build.zig.zon`. `verify.sh --version SEMVER` also checks the expected record
version. See the shared [build-version contract](../../docs/BUILDING.md) for
accepted inputs, schema version `2`, and executable version inspection.

Use `--prefix DIR` for an isolated output location. The ordinary `zig-out/bin`
development build does not replace this release output. `--allow-dirty` creates
a marked development artifact; verification rejects it unless that option is
also supplied. Do not use that option for release qualification.

The builder compiles into a temporary directory beside the requested prefix.
It validates the executable and build record before publishing that directory.
Failed builds keep the previous artifact. A lock prevents two builders from
replacing the same output at once. Wait for the build to finish before consuming
the output. A lock left by a forcibly killed build can be removed after checking
that no builder is still using it.

`tools/release/settings.sh` holds the compiler version, glibc baseline, CPU
policy, optimization mode, and pinned Bookworm base. Platform helpers return
values without changing shared variables. Server and helper builds use the
same compile function. JSON creation and validation are in named `.jq` files;
validation errors identify the failing field. ELF parsing runs with `LC_ALL=C`.

Run `bash tests/build/run.sh` with Zig 0.16.0 to check native defaults, the
shared SemVer fixtures, versioned server/test-tool builds, and foreign run
guards. It uses local build outputs and creates no releases.

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
servers. A small shell probe checks library resolution and the binary checksum
in this stage. The inspection
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

All three probe containers have owned names before Docker starts them. Cleanup
removes those containers even when a Docker client times out. Cleanup commands
also have deadlines. Evidence collection and cleanup failures are reported;
the original test failure status is preserved.

Check error handling with `bash tests/release/failures.sh`. Add `--docker` to
also check that a container which ignores TERM is removed after the Docker
client times out. The checks require the intended error status and explanation,
and keep separate logs under `test-artifacts/release/failures/`.
Artifact checks also simulate a metadata writer failure after compilation and
confirm that the previous executable and build record are unchanged.

Run `make check-shell` before submitting script changes. Use `make fmt-shell`
to apply the shared formatting rules. See `tools/shell/README.md` for the pinned
tools and supported hosts.

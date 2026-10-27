# Check release artifacts and automation

[Contributor guide](../../docs/contribute/testing.md) / Release checks

Choose a local contract test, artifact check, or native runtime check below.
These commands test release tooling. The operational procedure is in
[Release and backport kgcache](../../docs/contribute/release-workflow.md).

## Run contract fixtures

From the repository root:

| Command | What it tests |
| --- | --- |
| `bash tests/release/proposals.sh` | Source/version proposals using temporary Git history |
| `bash tests/release/candidates.sh` | Candidate metadata and archive rejection with synthetic bundles |
| `bash tests/release/github.sh` | GitHub evidence collection through a GET-only stub |
| `bash tests/release/publication.sh` | Stored requests, tags, ordering, protection, and retry policy |
| `bash tests/release/publication.sh --docker` | Registry transport and stateful GitHub API behavior |
| `bash tests/release/failures.sh` | Error status, explanations, and previous-artifact preservation |

Proposal fixtures need no compiler, Docker, credentials, or published versions.
GitHub fixtures need no token or network connection to GitHub.

The publication suite checks initial RC requests, recovery of existing branches,
stable patch and numbered RC merges, state creation, reviewed main cuts, branch creation,
actor access, main-first backports, reserved numbering, frozen notes, duplicate
versions, and candidate retries. Historical merge commits in a branch base are
allowed, while a release-request commit with multiple parents is rejected.
Missing PR/history rules, non-squash methods, or extra bypass actors fail.

The Docker publication option needs Docker, Buildx, and Node. It uses temporary
Git repos, a local registry with synthetic images, and a loopback GitHub API.
It tests prerelease assets and notes while preserving stable aliases. Native
Linux tests Docker push; macOS seeds transport through the registry API for
upload recovery. No fixture uploads to Docker Hub or creates a real GitHub
release. Owned registry resources are removed on exit.

## Build and verify an artifact

Use macOS or Linux with Bash 3.2 or newer, Git, curl, tar with xz, jq, `file`,
GNU `timeout`, and `sha256sum` or `shasum`. Dependency checks run before building
or creating release output. Start with a clean checkout:

```sh
bash tools/release/build.sh
bash tools/release/verify.sh
bash tests/release/artifact.sh zig-out/release/linux-amd64
```

The builder downloads Zig 0.16.0 for the host, verifies the pinned official
archive checksum, and caches it under `.zig-cache/toolchains`. The output uses
Linux amd64, baseline CPU features, glibc 2.36, and ReleaseSafe.

```text
zig-out/release/linux-amd64/
  bin/kgcache
  build-info.json
```

Schema `2` build metadata contains the effective and development versions,
source/dirty identity, platform, target, mode, compiler/checksum, runtime base,
and executable checksum. It includes no host paths or timestamps. Persistence
test controls are disabled in the release server.

Supply `--version SEMVER` to the builder for an override and to `verify.sh` for
an expected record value. The [build guide](../../docs/contribute/building.md)
defines its syntax. `--prefix DIR` selects isolated output. Ordinary native
`zig-out/bin` output does not replace it.

`--allow-dirty` creates a marked development artifact. Verification also needs
that flag to accept it. Use a clean artifact for release qualification.

The builder compiles beside the final prefix in a temporary directory, verifies
the executable and metadata, then publishes the directory. Failures retain the
previous artifact. A lock prevents simultaneous replacement. Consume output
only after completion. Before removing a stale lock from a killed builder,
confirm that no builder still uses it.

## Inspect target requirements

The shared [settings](../../tools/release/settings.sh) pin compiler, glibc,
CPU, optimization, and Bookworm base. Server and helper builds use the same
compile function. Platform helpers return values without mutating shared
variables. Named jq files create and validate JSON, with errors identifying
the failing field. ELF inspection uses `LC_ALL=C`.

Build the arm64 candidate separately:

```sh
bash tools/release/build.sh --platform linux/arm64
bash tools/release/verify.sh --prefix zig-out/release/linux-arm64
```

This is compile coverage, not native arm64 support. With GNU readelf available:

```sh
bash tools/release/inspect.sh zig-out/release/linux-amd64
```

Set `READELF` to select a compatible reader. Inspection rejects runtime search
paths and glibc symbols newer than the baseline. It does not replace library
resolution checks inside the intended Debian filesystem.

Run `bash tests/build/run.sh` with Zig 0.16.0 for native defaults, SemVer cases,
versioned server/test-tool builds, and foreign execution guards. It creates no
release.

## Test on Bookworm

With Docker and GNU `timeout` available:

```sh
bash tests/release/run.sh
```

The engine must be Linux amd64 by default. Development emulation needs:

```sh
bash tests/release/run.sh --allow-emulation
```

Emulated results report `native_execution: false` and
`initial_amd64_qualified: false`. The required **Native Linux amd64 release on
Bookworm** job provides native evidence. Arm64 remains a compile candidate.

The runner requires a clean checkout at the artifact's recorded commit. It
builds process test tools with the pinned compiler and target. The
`integration-tools` step exports them only when requested; normal release
installation never includes them.

[Dockerfile](Dockerfile) has runtime, inspection, and test stages. Runtime
contains the exact artifact and pinned Bookworm filesystem without a compiler
or test server. A small probe checks binary checksum and resolved libraries.
The inspection stage adds ELF tools. The test stage adds process fixtures,
without adding runtime libraries that could hide a missing dependency.

Process cases run the supplied release server for raw PING, binary SET/GET,
pipelines, SIGTERM, snapshot/AOF reload, and persistence failures. Only cases
needing persistence controls use a controlled server. An invalid-control case
also verifies that the ordinary release ignores test-only settings.

## Read failure evidence

Each run creates a directory under `test-artifacts/release/linux-amd64` with
its build record, ELF report, resolved libraries, process log, and result.
Failed process cases keep their harness evidence. `--prefix DIR` chooses an
artifact; `--artifacts DIR` chooses an evidence parent. Objects and verified
downloads are cached, while persistence fixtures stay temporary.

Build, inspection, and process phases have deadlines. Probe containers receive
owned names before startup, so cleanup can remove them even after a Docker
client times out. Cleanup is bounded too. Evidence/cleanup failures are
reported while preserving the original test failure status.

Add `--docker` to the failure suite to prove that a TERM-ignoring container is
removed after its client times out. It keeps separate logs under
`test-artifacts/release/failures`. Artifact cases inject metadata-writer failure
after compilation and require unchanged previous executable and record.

For complete source/image qualification and saved transfer, use
[candidate tools](../../docs/contribute/release-candidates.md). Before submitting
script changes, follow [shell conventions](../../tools/shell/README.md), then
run `make fmt-shell` and `make check-shell`.

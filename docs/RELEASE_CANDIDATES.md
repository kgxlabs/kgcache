# Release candidates

The candidate tools build and test one exact source/version pair, save its
image, and verify a later load. They keep all output local. They create no Git
version tags, registry uploads, or GitHub releases.

The [release workflow](RELEASE_WORKFLOW.md) runs these commands in CI and
verifies artifact transfer in a separate job.

Use the prerequisites in [release checks](../tests/release/README.md),
[container checks](../tests/container/README.md), and
[client setup](../tests/integration/clients/README.md). Prepare the pinned Go,
Node, and npm versions before starting. The source builder uses the pinned,
checksum-verified Zig compiler.

## Build and qualify

Create a [proposal](RELEASE_PROPOSALS.md), then qualify it:

```sh
mkdir -p test-artifacts/release
bash tools/release/propose.sh --source HEAD --version 0.2.0-rc.1+local.001 \
  > test-artifacts/release/proposal.json
bash tools/release/qualify.sh --proposal test-artifacts/release/proposal.json
```

The default requires a native Linux amd64 source host and Docker engine.
On a development machine with amd64 emulation, add `--allow-emulation`:

```sh
bash tools/release/qualify.sh --proposal test-artifacts/release/proposal.json \
  --allow-emulation
```

Development results record their actual host and engine. They have
`qualified_amd64: false` when source or image execution was not native Linux
amd64. Passing an emulated run does not qualify a production platform.

`--repo DIR` selects the local source repository. `--artifacts DIR` selects
the output parent. Each attempt gets a new `run.*` directory. The command prints
its location before testing and again when the complete candidate is retained.

The source is a separate clean checkout of the proposal's full commit SHA.
Uncommitted working files are outside that snapshot. No tracked version file
is changed. Each version-bearing build receives the proposed SemVer input.
The candidate records the tooling revision, dirty state, and entrypoint checksum
separately from the selected source. Its evidence also records checksums of
the tooling files used for qualification.

Merged release PR proposals run from their clean selected source commit.
Their version and notes are fixed by the request. A request with an existing reserved tag must
recover its retained candidate instead of rebuilding that version.

CI passes `--request-evidence FILE` from the request collector. Its source,
policy, mode, repository, and proposal checksum must agree. The candidate
retains this record as checksummed `evidence/request.json`. Import validates
the same binding when the record is present.

## What runs

The runner preserves the selected source's existing coverage:

- Unit, process, build-contract, proposal, shell, and failure checks.
- The existing arm64 release compile check, without an arm64 runtime claim.
- Locked client dependency preparation and code-quality checks.
- The full required Go and Node client matrix from the selected registry.
- One real service image build with explicit source, version, and clean state.
- Integrity, Bookworm library/ELF/process, and prepared-image service checks.
- Container health, persistence, recovery, PID 1 lifecycle, Compose, and endpoint
  client checks already provided by the prepared-image runner.

The image ID is captured once. Runtime checks use its extracted binary and
build record. Service checks use that image ID directly. On a native Linux
amd64 source host, the full source-client matrix also runs the extracted image
binary. Development hosts use a native host build for that matrix and record
`source_binary: "host-build"`.

`client_coverage` lists source and image profiles separately. The existing image
endpoint checks use their registered baseline profiles. Each source profile
still runs its full RESP2, RESP3, and default-handshake suite.

Commands have deadlines. Logs are bounded to 64 KiB, JSON evidence files to
1 MiB, and the evidence inventory to 512 files and 32 MiB. Failed attempts retain
a `failure.json`, bounded phase logs, and available source/runtime diagnostics.
They have no completed candidate marker.

## Saved bundle

Successful output contains:

```text
candidate.json
proposal.json
build-info.json
kgcache-linux-amd64.docker.tar.gz
SHA256SUMS
evidence/
```

`candidate.json` uses schema version `1`. It binds the source/version proposal,
schema `2` build record, platform, tested image ID, archive checksum and size,
tooling/run identity, passed phases, client coverage, and checksummed evidence.
Every candidate has `publishable: false`.

The archive format is `docker-archive+gzip`. It comes from
[`docker image save`](https://docs.docker.com/reference/cli/docker/image/save/)
of the resolved image ID. The saved image has no named repository tags.
Compressed archives are limited to 512 MiB and expanded archives to 1 GiB.

These identities stay separate: source commit, binary checksum, image ID,
archive checksum, and any later registry digest. The bundle records their
relationships. Their hashes are not interchangeable.

## Verify a transfer

Copy the complete directory to the receiving process or machine. Then run:

```sh
bash tools/release/import-candidate.sh --candidate /absolute/path/to/candidate
```

Use `--allow-emulation` to inspect a development bundle or use an emulated
Docker engine. This preserves the candidate's original qualification flags.
It does not turn a development result into native qualification.

When the manifest checksum comes from a trusted caller or artifact record,
pass it explicitly:

```sh
bash tools/release/import-candidate.sh --candidate /absolute/path/to/candidate \
  --expected-sha256 EXPECTED_MANIFEST_SHA256
```

The verifier snapshots and checks the required files, full checksum inventory,
proposal/build identities, and qualification reports. Before loading, it checks
the archive's one-image layout, configuration ID, source/version labels,
platform, and every layer's content hash. Named tags and unrelated images fail.

It then uses [`docker image load`](https://docs.docker.com/reference/cli/docker/image/load/)
and compares the loaded image, actual build record, binary checksum, and
`kgcache --version` output. It performs no source build. A JSON result goes to
stdout with `rebuilt: false`. Logs from Docker are kept separate from that JSON.

Checksums establish consistency with the supplied manifest. The caller supplies
the trusted manifest identity and original event/review evidence. A successful
import is evidence of content identity, separate from publication approval.

## Contract tests

Run the metadata and archive rejection fixtures:

```sh
bash tests/release/candidates.sh
make check-shell
```

These use isolated synthetic bundles. They do not run Docker or publish
versions. The complete qualification and import commands above test the real
image path. Reuse the same source/version pair for repeated previews.

To also test a real bundle's load and archive-substitution rejection:

```sh
bash tests/release/candidates.sh --candidate /absolute/path/to/candidate \
  --allow-emulation
```

This invokes the import verifier with image builds blocked. It also proves that
an already loaded expected image cannot hide an archive containing another image.

# Qualify and transfer an image

[Docs](../README.md) / [Contribute](README.md) / Release candidates

A candidate binds one source/version proposal to a tested image and saved
archive. Use this path to reproduce qualification or move the exact image to
another runner. These local commands do not publish tags, images, or releases.

## Prepare the host

Use the tools in [release checks](../../tests/release/README.md),
[container checks](../../tests/container/README.md), and
[client setup](../../tests/integration/clients/README.md). Prepare the pinned
Go, Node, and npm versions. The source builder obtains the pinned,
checksum-verified Zig compiler itself.

Qualification requires native Linux amd64 source execution and a native
Linux amd64 Docker engine by default. A development host can pass
`--allow-emulation`, but its result cannot establish native qualification.

## Build a candidate

```sh
mkdir -p test-artifacts/release
bash tools/release/propose.sh --source HEAD --version 0.2.0-rc.1+local.001 \
  > test-artifacts/release/proposal.json
bash tools/release/qualify.sh --proposal test-artifacts/release/proposal.json
```

For development emulation, add `--allow-emulation` to `qualify.sh`.
`--repo DIR` selects the source repository. `--artifacts DIR` chooses the
output parent. Each attempt gets its own `run.*` directory, printed before
testing and again after successful retention.

The runner checks out the proposal's full SHA into a clean temporary source
snapshot. Uncommitted files do not enter it. It passes version as build input,
without editing a tracked version file. Source identity and tooling identity
are separate: evidence records tooling revision, dirty state, entrypoint
checksum, and checksums of tooling used in qualification.

A release-request proposal has fixed source, version, and notes. Once its tag
is reserved, recover the retained candidate instead of rebuilding that version.
CI also supplies `--request-evidence FILE`. Source, policy, mode, repository,
and proposal checksum must match. The bundle retains its checksummed copy as
`evidence/request.json`, and import validates it when present.

## Read the result

Qualification preserves the selected source's existing test coverage:

| Phase | Evidence |
| --- | --- |
| Source checks | Unit/process/build contracts, proposals, shell and failure cases |
| Clients | Locked dependency setup, code checks, and all required source profiles |
| Build | Explicit source/version/clean-state image and arm64 compile candidate |
| Runtime | Integrity, ELF/library resolution, Bookworm process tests |
| Service | Prepared-image health, persistence, recovery, PID 1, Compose, and endpoint clients |

Arm64 compilation does not claim native arm64 runtime support. The resolved
image ID is captured once. Checks inspect that image's extracted executable
and build record; service checks run the same ID.

On a native Linux amd64 source host, the full source-client matrix uses the
extracted image binary. A development host instead uses its native build and
records `source_binary: "host-build"`. `client_coverage` records source profiles
separately from image endpoint profiles. Full API cases run explicit RESP2 and
RESP3; default protocol is checked in separate handshake/report cases.

Results record the actual source host and Docker engine. If either relevant
execution path is not native Linux amd64, `qualified_amd64` is false. Importing
or rerunning a development result does not promote that flag.

Every phase has a deadline. Logs are capped at 64 KiB, JSON evidence at 1 MiB,
and the evidence inventory at 512 files and 32 MiB. Failed attempts retain
`failure.json`, bounded phase logs, and available diagnostics, without a
completed candidate marker.

## Inspect the bundle

Successful output contains:

```text
candidate.json
proposal.json
build-info.json
kgcache-linux-amd64.docker.tar.gz
SHA256SUMS
evidence/
```

Schema `1` `candidate.json` binds the proposal, schema `2` build record,
platform, tested image ID, archive checksum/size, tooling/run identity,
passed phases, client coverage, and checksummed evidence. Every candidate
records `publishable: false`.

The archive is `docker-archive+gzip`, saved from the resolved image ID. It has
no repository tags. Compressed size is limited to 512 MiB and expanded size
to 1 GiB. Source SHA, binary checksum, image ID, archive checksum, and later
registry digest are different identities. Their relationships are recorded;
the hashes are not interchangeable.

## Verify on the receiving runner

Copy the complete candidate directory, then run:

```sh
bash tools/release/import-candidate.sh --candidate /absolute/path/to/candidate
```

A development bundle or emulated engine needs `--allow-emulation`. This keeps
its original qualification flags. When the caller has a trusted candidate
manifest checksum, bind import to it:

```sh
bash tools/release/import-candidate.sh --candidate /absolute/path/to/candidate \
  --expected-sha256 EXPECTED_MANIFEST_SHA256
```

The verifier snapshots required files and checks the inventory, proposal,
build identities, and qualification reports. Before load, it checks the
archive's one-image layout, config ID, source/version labels, platform, and
every layer hash. Named tags and unrelated images fail.

It loads the archive and compares the actual image, record, executable
checksum, and `kgcache --version`. It does not build from source. JSON goes
to stdout with `rebuilt: false`; Docker logs remain separate.

Checksums prove consistency with the supplied manifest. The caller supplies
its trusted identity and original review/event evidence. Content identity is
separate from approval to publish.

## Test candidate tooling

```sh
bash tests/release/candidates.sh
make check-shell
```

These rejection fixtures use synthetic bundles without Docker or publication.
For a real candidate, also test load and archive substitution:

```sh
bash tests/release/candidates.sh --candidate /absolute/path/to/candidate \
  --allow-emulation
```

That path blocks image builds. It proves that a preloaded expected image cannot
hide an archive containing different bytes. The hosted
[release workflow](release-workflow.md) uses a separate runner for transfer
verification before publication can proceed.

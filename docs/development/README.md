# Developer documentation

[Documentation](../README.md) / Development

Start with [CONTRIBUTING.md](../../CONTRIBUTING.md) for branch setup, style,
checks, commit messages, review, and backports. User instructions are in the
[documentation index](../README.md#use-and-operate-kgcache).

## Build and test

| Guide | Purpose |
| --- | --- |
| [Build versions](building.md) | SemVer inputs, build records, and image provenance |
| [Testing](testing.md) | Test layers, commands, Zig test placement, and fixtures |
| [Client test projects](../../tests/integration/clients/README.md) | Registry, locks, native launchers, and quality checks |
| [Process harness](../../tests/integration/harness/README.md) | Child ownership, deadlines, logs, and failure evidence |
| [Container checks](../../tests/container/README.md) | Service qualification and client smoke tests |
| [Release checks](../../tests/release/README.md) | Build, qualification, transfer, and publication tests |

## Architecture and design

| Guide | Purpose |
| --- | --- |
| [Architecture](architecture.md) | Request flow, ownership, concurrency, config, and repository map |
| [Expiration](expiration.md) | Active sampling, locking, storage layout, and memory cost |
| [Persistence internals](persistence.md) | Snapshot and journal lifecycle boundaries |
| [Snapshot internals](snapshots.md) | Forking, save claims, change accounting, and child draining |
| [AOF internals](aof.md) | Replay, manifests, rewrite publication, and failure state |
| [Errors and logging](errors.md) | Error ownership, reporting boundaries, and trace lifetime |

## Release procedures

| Guide | Purpose |
| --- | --- |
| [Release workflow](release-workflow.md) | RC series, backports, publication, and recovery |
| [Release proposals](release-proposals.md) | Source/version previews and merged PR identity |
| [Release candidates](release-candidates.md) | Qualify exact source/version pairs and verify image transfers |

These pages preserve implementation detail for contributors and maintainers.
Keep user-visible contract changes in [compatibility](../user/compatibility.md),
[commands](../user/commands.md), and the relevant user guide too.

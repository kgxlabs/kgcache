# Contribute

[Docs](../README.md) / Contribute

Build, test, and change kgcache. These guides explain repository workflows and
the design behind the current implementation. For application code and service
operation, use [Develop](../develop/README.md) and [Operate](../operate/README.md).

## Start a change

1. Read [CONTRIBUTING.md](../../CONTRIBUTING.md) for branches, commits, and review.
2. [Build a version](building.md) and inspect its output.
3. [Run the checks](testing.md) for the area you change.
4. Read the relevant design guide before changing an ownership boundary.

## Understand the server

| Guide | What you will learn |
| --- | --- |
| [Architecture](architecture.md) | Request flow, memory ownership, workers, and startup |
| [Errors and logging](errors.md) | Where errors are reported and how traces are consumed |
| [Expiration](expiration.md) | TTL sampling, locking, metadata, and memory cost |
| [Persistence lifecycle](persistence.md) | Shared claims, child ownership, and shutdown ordering |
| [Snapshots](snapshots.md) | Capture, file publication, dirty counts, and retries |
| [AOF](aof.md) | Journal transactions, replay, manifests, and rewrites |

## Maintain a release

- [Release workflow](release-workflow.md): backport a fix, request a candidate,
  configure automation, or recover a failed publication.
- [Release proposals](release-proposals.md): inspect an exact source/version
  choice without publishing it.
- [Release candidates](release-candidates.md): qualify an image and verify its
  saved bundle on another runner.

## Work on a test or tool

The local READMEs are the command reference for each runner:
[build](../../tests/build/README.md),
[process](../../tests/integration/README.md),
[process fixture](../../tests/integration/harness/README.md),
[real clients](../../tests/integration/clients/README.md),
[containers](../../tests/container/README.md),
[releases](../../tests/release/README.md), and
[shell checks](../../tools/shell/README.md).

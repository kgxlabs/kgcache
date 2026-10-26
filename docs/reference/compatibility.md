# Compatibility

[Docs](../README.md) / [Reference](README.md) / Compatibility

kgcache implements a tested subset of Redis RESP2 and RESP3 for a standalone
string cache. The supported surface is defined by the
[command reference](../commands/README.md) and
[protocol reference](protocol.md), not by everything a Redis client exposes.

## Tested clients

The committed [matrix.json](../../tests/integration/clients/matrix.json)
selects these exact required profiles:

| Profile | Package and version | API suite | Runtime | Package manager |
| --- | --- | --- | --- | --- |
| `go-redis-v9.22.0` | `github.com/redis/go-redis/v9` v9.22.0 | `go-redis-v9` | Go 1.26.9 | Go modules from that runtime |
| `go-redis-v9.23.0` | `github.com/redis/go-redis/v9` v9.23.0 | `go-redis-v9` | Go 1.26.9 | Go modules from that runtime |
| `node-redis-6.2.1` | `redis` 6.2.1 | `node-redis-v6` | Node 22.14.0 | npm 10.9.2 |
| `node-redis-6.2.0` | `redis` 6.2.0 | `node-redis-v6` | Node 22.14.0 | npm 10.9.2 |

Every profile runs its API suite with explicit RESP2 and explicit RESP3.
Separate handshake and CLIENT INFO cases omit the protocol option and require
default RESP3, including library labels. Default mode is not a third complete
execution of every API case.

Each profile uses the committed `go.mod`/`go.sum` or
`package.json`/`package-lock.json` from its registry `dependencyDir`.
The table lists exact pins, not version ranges. No prerelease or automatically
discovered client is included.

Start with the [Go](../develop/clients/go.md) or
[Node.js](../develop/clients/node.md) guide for usable settings.

## Supported behavior

| Area | Contract |
| --- | --- |
| Data | Binary-safe string keys and values, including empty strings |
| Key operations | GET, SET with its documented conditions/expiration/GET options, DEL, DBSIZE |
| Connections | Persistent TCP, database selection, ordered pipelines, HELLO switching |
| Protocols | RESP2 and the command-scoped RESP3 replies listed in the protocol reference |
| Client reporting | SETINFO labels and exactly the 22-field CLIENT INFO/LIST subset |
| Introspection | Registry-based COMMAND forms documented in the command reference |
| Persistence | `.kgc` snapshots, AOF replay/recovery/rewrite, and documented clean-stop behavior |
| Service image | Non-root Linux amd64 image, PING health probe, persistent storage, SIGINT/SIGTERM shutdown |

Database 0 is the default. Other indices must be within the server's configured
range, 0 through 15 by default. Leave credentials, connection names, and TLS
settings unset. Library identity reporting through SETINFO may stay enabled.

## Unsupported features

- Other data types and commands, including hashes, lists, sets, sorted sets,
  streams, SCAN, INCR, and standalone TTL/EXPIRE commands.
- Replication, clustering, Sentinel, failover, and replica-read-only clients.
- MULTI/EXEC transactions, WATCH, scripting, pub/sub, and modules.
- Authentication, ACLs, TLS, AUTH, HELLO AUTH, and connection names.
- CLIENT SETNAME/GETNAME/ID/TRACKING, CLIENT LIST filters, standalone INFO,
  COMMAND DOCS, and COMMAND module filtering.
- Client-side caching, tracking, RESP3 pushes, and unlisted RESP3 types or
  request forms.
- Live CONFIG updates, `maxmemory`, and eviction policies.
- Redis RDB loading or a claim of general Redis AOF interchange.

Metadata can contain ACL category names for command introspection. Those
names do not implement users, authorization, or ACL enforcement.

## Capacity and platform limits

There is no enforced total dataset limit or eviction policy. Memory use
includes data, connection buffers, a thread per connection, and persistence
copy-on-write pages. Allocation can fail, and an OS/container memory limit
can kill the server. Compatibility tests do not establish a throughput or
high-connection-count guarantee.

Requests are limited to 1 MiB and 1,024 array elements per command. See
[Protocol limits](protocol.md#request-limits) for exact counting and failures.

Native image qualification covers Linux amd64. Running that image through
arm64 emulation does not establish native arm64 support. Storage durability
and child-safety limits are documented in
[Persistence](../operate/persistence.md#durability-and-failure-limits).

## Automated coverage

Required client jobs start after Zig unit and process checks pass in
[server/client CI](../../.github/workflows/zig-tests.yml). They use the
[reusable client workflow](../../.github/workflows/client-tests.yml).
The [weekly workflow](../../.github/workflows/weekly-client-compatibility.yml)
repeats the registered required pins without upgrading dependencies.

| Claim | Automated evidence |
| --- | --- |
| Reply semantics and exact RESP2/RESP3 bytes | [Shared fixtures](../../src/protocol/compatibility_fixtures.zig) and [wire tests](../../src/protocol/compatibility_tests.zig), `zig build test` |
| HELLO, protocol switching, CLIENT labels/reports, errors | [HELLO](../../tests/integration/suites/hello_metadata.zig), [CLIENT INFO](../../tests/integration/suites/client_info.zig), and [CLIENT LIST](../../tests/integration/suites/client_list.zig) process cases |
| Go APIs, both explicit modes, and default setup | [go-redis v9 suite](../../tests/integration/clients/go/go-redis/v9), `make test-go` |
| Node APIs, both explicit modes, and default setup | [node-redis v6 suite](../../tests/integration/clients/node/node-redis/v6/tests), `make test-node` |
| Framing, pipelines, limits, concurrency, disconnects, shutdown | [Process suites](../../tests/integration/suites) and [connection tests](../../src/connection) |
| Active expiration and storage changes | [Expiration tests](../../src/expiration.zig) and [storage tests](../../src/storage), `zig build test` |
| Restart, AOF recovery, final snapshots, active children, deadlines | [Persistence process suites](../../tests/integration/suites) and [persistence unit tests](../../src/persistence) |
| Image health, PID 1 lifecycle, storage, and endpoint clients | [Container checks](../../tests/container/README.md) and [native release checks](../../tests/release/README.md) |

The client suites exercise strings, binary values, conditional SET, expiration,
databases, client reports, errors, pipelines, persistence, pools, reconnects,
concurrent work, and shutdown cleanup. They do not test every library API.
See [Testing](../contribute/testing.md) to run a category locally.

## Changes to tested support

A new client version needs an explicit registry profile and dependency locks.
Compatible APIs can reuse a suite. A breaking API needs its own suite while
older required profiles remain covered. Removing a profile requires an
explicit support, CI, and documentation change.

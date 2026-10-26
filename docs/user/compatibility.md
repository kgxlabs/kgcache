# Compatibility

[Documentation](../README.md) / Compatibility

kgcache implements a tested, limited Redis RESP2/RESP3 string-cache contract.
It supports the commands in the [command reference](commands.md).
A client library connecting successfully does not make all of its APIs usable.
Use [limits](limits.md) to check the features your application needs.

## Exact tested clients

The source of truth is [matrix.json](../../tests/integration/clients/matrix.json).
These are exact required profiles, not a supported version range. No prerelease
client or automatically discovered version is included.

| Required profile | Library and API suite | Runtime | Package manager |
| --- | --- | --- | --- |
| `go-redis-v9.22.0` | `github.com/redis/go-redis/v9` v9.22.0, `go-redis-v9` | Go 1.26.9 | Go modules from that runtime |
| `go-redis-v9.23.0` | `github.com/redis/go-redis/v9` v9.23.0, `go-redis-v9` | Go 1.26.9 | Go modules from that runtime |
| `node-redis-6.2.1` | `redis` 6.2.1, `node-redis-v6` | Node 22.14.0 | npm 10.9.2 |
| `node-redis-6.2.0` | `redis` 6.2.0, `node-redis-v6` | Node 22.14.0 | npm 10.9.2 |

Every row runs its matching API suite with explicit RESP2 and explicit RESP3.
A separate default-handshake case omits the protocol option and requires RESP3.
Default-mode CLIENT INFO cases also check the negotiated mode and library labels.
The default path is not a third complete run of every API case.
The suites use committed `go.mod`/`go.sum` or `package.json`/`package-lock.json`
files from each profile's `dependencyDir` in the registry.

Both suites test strings and binary data, SET conditions and expiration,
database selection, client reports, ordered pipelines, command errors,
snapshot reload, background persistence replies, connection pools,
reconnection, concurrent clients, and shutdown cleanup. These tests cover
those API uses. They do not cover the full libraries.

See [client examples](clients.md) for setup and
[client test setup](../../tests/integration/clients/README.md) for reproduction.
Adding a compatible version needs an explicit profile and locks. A new API
suite keeps older required profiles. Removing one needs an explicit support,
CI, and documentation change.

## Protocol contract

Requests are nonempty, flat arrays of non-null bulk strings. Empty and binary
keys and values are allowed. Inline commands and general RESP3 request values
are not accepted. Command names and subcommands are case-insensitive.

New connections start in RESP2. `HELLO 2` and `HELLO 3` switch the reply mode
for that connection, including HELLO's own reply. Bare `HELLO` reports the
current mode. Switching does not change the selected database. Invalid HELLO
forms leave the previous mode in place.

| Reply | RESP2 | RESP3 | Used by |
| --- | --- | --- | --- |
| Simple string | `+...\r\n` | Same | PING, successful SET/SELECT/SETINFO, persistence replies |
| Simple error | `-...\r\n` | Same | Command and protocol errors |
| Integer | `:...\r\n` | Same | DEL, DBSIZE, metadata |
| Blob string | `$length\r\n...\r\n` | Same | GET, SET GET, ECHO, PING with a message |
| Null | `$-1\r\n` for missing strings, `*-1\r\n` for unknown COMMAND INFO entries | `_\r\n` | Missing GET, SET null outcomes, unknown command metadata |
| Array | `*count\r\n...` | Same | COMMAND metadata and key extraction |
| Map | Flat key/value array | `%count\r\n...` | HELLO metadata |
| Text report | Bulk string | `=length\r\ntxt:...\r\n` | CLIENT INFO and CLIENT LIST |

RESP3 support is scoped to these replies for the supported commands. There are
no booleans, doubles, big numbers, sets, blob errors, attributes, push messages,
or streamed strings or aggregates. See [unsupported features](limits.md#unsupported-features)
for the related client features.

A missing or expired GET returns RESP2 null bulk or RESP3 null. A SET without
GET returns `OK` when applied and the same protocol's null when NX/XX rejects
it. With GET, SET returns the previous blob value or that protocol's null,
whether the write applies or is rejected. See [SET](commands.md#set).

CLIENT INFO/LIST expose the documented
[22-field subset and SETINFO behavior](commands.md#client).
These reports have no extra Redis fields or filters.

## Automated evidence

All required client profiles run after Zig unit and process checks in
[server and client CI](../../.github/workflows/zig-tests.yml), through the
[reusable client workflow](../../.github/workflows/client-tests.yml).
The jobs validate exact installed dependencies and runtimes. Failure evidence
includes bounded output, server logs, config, and persistence files.

| Claim | Automated category and source |
| --- | --- |
| Shared reply meaning and exact RESP2/RESP3 bytes | [Semantic fixtures](../../src/protocol/compatibility_fixtures.zig), [reply encoder tests](../../src/protocol/compatibility_tests.zig), `zig build test` |
| HELLO, protocol switches, CLIENT INFO/LIST/SETINFO and error recovery | [HELLO process cases](../../tests/integration/suites/hello_metadata.zig), [CLIENT INFO cases](../../tests/integration/suites/client_info.zig), [CLIENT LIST cases](../../tests/integration/suites/client_list.zig), `zig build test-integration` |
| Go API behavior in both modes and the default handshake | [go-redis v9 suite](../../tests/integration/clients/go/go-redis/v9), `make test-go` |
| Node API behavior in both modes and the default handshake | [node-redis v6 suite](../../tests/integration/clients/node/node-redis/v6/tests), `make test-node` |
| Framing, pipelines, request limits, and transport shutdown | [Process suites](../../tests/integration/suites), [connection tests](../../src/connection), `zig build test-integration` and `zig build test` |
| Active expiration and storage semantics | [Expiration tests](../../src/expiration.zig), [storage tests](../../src/storage), `zig build test` |
| Snapshot/AOF restart, recovery, final saves, and child draining | [Persistence process suites](../../tests/integration/suites), [persistence unit tests](../../src/persistence), `zig build test-integration` and `zig build test` |
| Linux amd64 image, health, service lifecycle, and native clients | [Container checks](../../tests/container/README.md), [release checks](../../tests/release/README.md) |

The [developer testing guide](../development/testing.md) explains the test
layers. Passing checks do not prove performance, complete Redis compatibility,
or durability under every filesystem and power-loss condition.

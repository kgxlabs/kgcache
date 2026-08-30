# kgcache

> A compact, Redis-protocol-compatible in-memory cache server, built in Zig.

`kgcache` is an early-stage member of the [kgx](https://github.com/kgxlabs) family. It speaks RESP2 over TCP, keeps string values in memory, and is deliberately small enough to read end-to-end. The project is a practical playground for cache-server fundamentals: command dispatch, protocol handling, ownership, TTL bookkeeping, and concurrent access.

## At a glance

| | |
| --- | --- |
| Protocol | RESP2 over TCP |
| Address | `127.0.0.1:6379` by default — see [Configuration](docs/CONFIGURATION.md) |
| Runtime | Zig 0.16.0+ |
| Data model | Process-local string keys and values |
| Commands | See [Commands](docs/COMMANDS.md) |
| Persistence | Snapshot to a `.kgc` file via `SAVE` (blocking) or `BGSAVE` (forks, non-blocking), automatically or on demand — see `save` in [Configuration](docs/CONFIGURATION.md); AOF journal is in-memory only, not yet durable to disk |

## Quick start

Build and start the server:

```bash
zig build run
```

Then connect from another terminal with any RESP-compatible client. `redis-cli` is convenient:

```console
$ redis-cli
127.0.0.1:6379> PING
PONG

127.0.0.1:6379> SET profile:42 "Ada"
OK

127.0.0.1:6379> GET profile:42
"Ada"

127.0.0.1:6379> DBSIZE
(integer) 1
```

The default build installs the executable at `zig-out/bin/main`. To run with a config file: `./zig-out/bin/main path/to/kgcache.conf` — see [Configuration](docs/CONFIGURATION.md).

## Documentation

| Doc | Covers |
| --- | --- |
| [Commands](docs/COMMANDS.md) | Supported commands and `SET` option families |
| [Configuration](docs/CONFIGURATION.md) | `kgcache.conf` file format, every directive, and known gotchas |
| [Architecture](docs/ARCHITECTURE.md) | Request flow, design direction, concurrency trade-offs, repository layout |
| [Persistence](docs/PERSISTENCE.md) | `SAVE`/`BGSAVE` fork mechanics, reaping, and automatic condition-based saving |
| [Expiration](docs/EXPIRATION.md) | TTL bookkeeping layout, memory cost, and the planned redesign |

## Development

Run the unit test suite:

```bash
zig build test
```

The tests cover RESP parsing and serialization, command dispatch, `DBSIZE`, storage sizing, expiration-index maintenance, and in-memory store behavior.

Useful commands:

```bash
zig fmt src/**/*.zig
zig build
zig build run
zig build test
```

## Scope and current limitations

- Values are strings only; there is no eviction policy, authentication, replication, clustering, pub/sub, transactions, or RESP3.
- The server processes one parsed request per connection read, into a per-connection buffer (1 KiB by default, configurable). Pipelining and requests split across reads are not supported.
- Argument validation remains incomplete for `PING` and `GET`; extra arguments are accepted.
- `COMMAND` is a placeholder, not Redis-compatible introspection.
- The active-expiration worker currently needs a locking fix before it can safely process TTL keys in a running server. Expired keys are still removed by `GET`.

## License
No license file is currently included.

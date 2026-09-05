# kgcache

> An in-memory cache server built in Zig, evolving toward a drop-in Redis replacement.

`kgcache` is the cache component of the infrastructure stack being developed at [kgxlabs](https://github.com/kgxlabs). Its design goals are standalone operation with existing Redis clients and native integration into the future kgx application deployment platform.

Today, kgcache supports a subset of Redis functionality over RESP2, including string storage, expiration, snapshots, and append-only persistence. It is under active development and is not yet a drop-in Redis replacement. See [Current status and compatibility](#current-status-and-compatibility) for known limitations.

The platform vision and roadmap belong at the [kgxlabs organization](https://github.com/kgxlabs). This repository documents the cache component, its implementation, and current compatibility.

## At a glance

| | |
| --- | --- |
| Protocol | RESP2 over TCP |
| Address | `127.0.0.1:6379` by default; see [Configuration](docs/CONFIGURATION.md) |
| Runtime | Zig 0.16.0+ |
| Data model | Process-local string keys and values |
| Commands | See [Commands](docs/COMMANDS.md) |
| Persistence | `.kgc` snapshots and an optional disk-backed AOF journal; see [Persistence](docs/PERSISTENCE.md) and [AOF](docs/AOF.md) |

## Quick start

Build and start the server:

```bash
zig build run
```

Then connect from another terminal with `redis-cli`:

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

The default build installs the executable at `zig-out/bin/kgcache`. To run
with a config file:

```bash
./zig-out/bin/kgcache path/to/kgcache.conf
```

See [Configuration](docs/CONFIGURATION.md) for all settings.

## Documentation

| Doc | Covers |
| --- | --- |
| [Commands](docs/COMMANDS.md) | Supported commands, `SET` options, and compatibility notes |
| [Configuration](docs/CONFIGURATION.md) | `kgcache.conf` file format, every directive, and known gotchas |
| [Architecture](docs/ARCHITECTURE.md) | Role within kgx, request flow, design trade-offs, repository layout |
| [Persistence](docs/PERSISTENCE.md) | Short comparison of snapshots and AOF |
| [Snapshots](docs/SNAPSHOTS.md) | `SAVE`, `BGSAVE`, child cleanup, and automatic saving |
| [Append-only file](docs/AOF.md) | AOF setup, fsync policies, file layout, startup, and rewrite flow |
| [Expiration](docs/EXPIRATION.md) | TTL bookkeeping layout, memory cost, and the planned redesign |

## Development

Run the unit test suite:

```bash
zig build test
```

The tests cover RESP parsing, command dispatch, storage, expiration,
snapshots, AOF loading, fsync policies, and AOF rewrites.

Useful commands:

```bash
zig fmt src/**/*.zig
zig build
zig build run
zig build test
```

## Current status and compatibility

- Values are strings only; there is no eviction policy, authentication, replication, clustering, pub/sub, transactions, or RESP3.
- The server processes one parsed request per connection read, into a per-connection buffer (1 KiB by default, configurable). Pipelining and requests split across reads are not supported.
- Argument validation remains incomplete for `PING` and `GET`; extra arguments are accepted.
- `COMMAND` is a placeholder, not Redis-compatible introspection.
- The active-expiration worker currently needs a locking fix before it can safely process TTL keys in a running server. Expired keys are still removed by `GET`. 

## License
No license file is currently included.

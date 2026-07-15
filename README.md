# kgcache

A Redis-like cache server written in Zig.

`kgcache` is part of the broader [`kgx`](https://github.com/kgxlabs) project, alongside sibling projects such as `kghttp`, which includes `kgbuf` and `kgurl`. The goal is to build a small, understandable cache/database server from first principles while growing toward broad Redis compatibility over time.

This project is early-stage. The current code focuses on RESP parsing/serialization, TCP request handling, command dispatch, and the first command/object abstractions.

## Current Status

| Area | Status | Notes |
|------|--------|-------|
| TCP server | **Started** | Listens on `127.0.0.1:6379` and handles each accepted connection in a thread |
| RESP protocol | **Started** | Parses arrays, bulk strings, simple strings, integers, simple errors, and null bulk strings |
| RESP serialization | **Started** | Serializes bulk strings, simple strings, integers, errors, and basic arrays |
| Commands | **Partial** | `PING`, `ECHO`, and minimal `COMMAND` behavior are wired; `GET` and `SET` are not yet complete |
| Store | **Stub** | Store shape exists, but real key/value storage is still planned |
| Object model | **Started** | String object support exists; more Redis data types are planned |
| CLI client | **Planned** | `kgcache-cli` will provide a first-party command-line client for talking to `kgcache` |

## Requirements

- Zig **0.16.0** or newer

## Getting Started

Build the server:

```bash
zig build
```

Run the server:

```bash
zig build run
```

In another shell, send RESP commands with `redis-cli`:

```bash
redis-cli ping
redis-cli echo hello
```

Run the current tests:

```bash
zig test src/root.zig
```

## Repository Layout

```text
.
├── build.zig              # Zig build configuration
├── src/
│   ├── main.zig           # TCP server entry point
│   ├── resp.zig           # RESP parser and serializer
│   ├── commander.zig      # Command parsing and execution
│   ├── store.zig          # Store interface and current stub
│   ├── object.zig         # Internal object model
│   ├── entry.zig          # Store entry type
│   ├── string.zig         # String helpers
│   └── map/Map.zig        # Future map implementation area
└── README.md
```

## Future Plan

The long-term plan is to include almost everything Redis includes, while keeping the implementation readable and incremental. Compatibility should grow feature by feature instead of hiding unfinished behavior behind broad claims.

Planned areas:

- Core key/value commands: `GET`, `SET`, `DEL`, `EXISTS`, `EXPIRE`, `TTL`, `INCR`, `DECR`, and related variants
- First-party client: `kgcache-cli` for interactive use, scripting, debugging, and local development
- Redis data types: strings, lists, hashes, sets, sorted sets, streams, bitmaps, hyperloglogs, and geospatial indexes
- Command coverage: broad command support across data structures, server introspection, configuration, client handling, and admin commands
- Protocol support: more complete RESP2 behavior, RESP3 support, pipelining, and improved client compatibility
- Storage engine: real in-memory storage, expiration handling, memory accounting, eviction policies, and object encoding strategies
- Persistence: RDB-style snapshots, append-only file behavior, rewrite/compaction, and recovery on startup
- Replication: primary/replica mode, synchronization, backlog handling, and failover-ready internals
- Pub/sub: channel subscriptions, pattern subscriptions, and sharded pub/sub behavior
- Transactions and scripting: `MULTI`/`EXEC`, optimistic locking, Lua-compatible scripting or an equivalent scripting layer
- Clustering: hash slots, cluster metadata, redirects, resharding foundations, and multi-node operation
- Observability: logging, metrics, slow logs, command stats, latency tracking, and debug tooling
- Reliability: fuzz tests for RESP, command conformance tests, integration tests with Redis clients, and benchmarks

## Philosophy

- **Redis-compatible over Redis-shaped** - behavior should match client expectations, not only command names
- **Incremental correctness** - ship small features with tests before widening the surface area
- **Readable internals** - this is part of `kgx`, so the implementation should be easy to inspect and learn from
- **Performance-aware** - use Zig's control over memory and I/O deliberately, but keep clarity first while the design is still forming

## License

No license file is included yet.

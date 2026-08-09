# kgcache

> A compact, Redis-protocol-compatible in-memory cache server, built in Zig.

`kgcache` is an early-stage member of the [kgx](https://github.com/kgxlabs) family. It speaks RESP2 over TCP, keeps string values in memory, and is deliberately small enough to read end-to-end. The project is a practical playground for cache-server fundamentals: command dispatch, protocol handling, ownership, TTL bookkeeping, and concurrent access.

## At a glance

| | |
| --- | --- |
| Protocol | RESP2 over TCP |
| Address | `127.0.0.1:6379` |
| Runtime | Zig 0.16.0+ |
| Data model | Process-local string keys and values |
| Commands | `PING`, `ECHO`, `GET`, `SET`, `DBSIZE`, `COMMAND` |
| Persistence | None — data lives for the server process |

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

The default build installs the executable at `zig-out/bin/main`.

## What it supports today

### Commands

| Command | Behavior |
| --- | --- |
| `PING` | Returns `PONG`. Arguments are currently ignored. |
| `ECHO <message>` | Returns one non-null bulk-string argument. |
| `GET <key>` | Returns a bulk string, or a null bulk string when the key is absent or expired. |
| `SET <key> <value> [options]` | Stores a string value and returns `OK`, unless `GET` requests a value response. |
| `DBSIZE` | Returns the number of stored keys as an RESP integer. |
| `COMMAND <value>` | Placeholder command that returns its first argument; Redis command introspection is not implemented. |

Command names are case-insensitive.

### `SET` options

`SET` recognizes the following option families:

| Family | Options |
| --- | --- |
| Conditional writes | `NX`, `XX` |
| Relative expiration | `EX <seconds>`, `PX <milliseconds>` |
| Absolute expiration | `EXAT <unix-seconds>`, `PXAT <unix-milliseconds>` |
| TTL handling | `KEEPTTL` |
| Response | `GET` |

Expiration records are maintained separately from key/value entries, with an O(1) index for updates and removal. Expired values are removed when read.

## Architecture

```text
RESP client
    │ TCP / RESP2
    ▼
┌─────────────────┐     ┌────────────────┐     ┌─────────────────────┐
│ Command dispatch │ ──▶ │ Store interface │ ──▶ │ Default in-memory   │
│ PING · GET · SET │     │ GET · SET ·     │     │ StringHashMap + TTL │
│ DBSIZE · …       │     │ DBSIZE          │     │ expiration index    │
└─────────────────┘     └────────────────┘     └─────────────────────┘
```

The TCP server runs one detached thread per connection. The storage backend owns its copied keys and string values, and protects operations with a mutex-backed transaction boundary.

## Design direction

The default backend is intentionally straightforward today: a `StringHashMap` stores values, while an `ArrayList` holds expiration records. Each expiring entry keeps an index into that list, allowing expiration metadata to be updated or removed in O(1) time.

### Expiration bookkeeping today

On the current 64-bit target, every stored entry carries an optional `usize` named `exp_index`. It is `16 bytes`, even for persistent keys that have no expiration, so the map's stored object grows from `16 bytes` for the value to `32 bytes` with the index included. This is a deliberate space-for-time trade-off: expiration changes do not need to scan the full expiration list.

Each TTL key also has a `24-byte` expiration record in the `ArrayList` (a borrowed key slice plus an absolute millisecond timestamp). To locate expiration metadata, the backend first finds the key's entry in the hash map, reads its `exp_index`, and then indexes directly into the expiration array. Removing an expiration uses swap-remove: the final record fills the gap, and the moved key's `exp_index` is updated before the list is popped.

| Metadata | Cost on a 64-bit target | Paid by |
| --- | ---: | --- |
| `exp_index: ?usize` | 16 bytes | Every key, including persistent keys |
| Expiration record | 24 bytes | Keys with a TTL |

At larger key counts, that direct per-entry cost looks like this when every key has a TTL:

| Keys | `exp_index` on all keys | Expiration records | Direct total if all expire |
| ---: | ---: | ---: | ---: |
| 100K | 1.6 MB | 2.4 MB | 5.6 MB |
| 1M | 16 MB | 24 MB | 56 MB |
| 10M | 160 MB | 240 MB | 560 MB |
| 100M | 1.6 GB | 2.4 GB | 5.6 GB |

The final column includes the base 16-byte string-value payload as well as the index and expiration record. It excludes hash-table buckets, key slices, allocator overhead, and unused `ArrayList` capacity, so real process memory will be higher.

As the cache grows, the plan is to replace this general-purpose expiration layout with a purpose-built hash-table design that supports efficient random expiration sampling, following the broad strategy used by Redis. That would reduce bookkeeping overhead and make active expiration a better fit for larger keyspaces.

Concurrency is similarly a deliberate trade-off. The server currently uses detached threads and mutex-protected storage transactions, which keeps the code easy to reason about but can move contention to the storage lock under load. If profiling shows that lock contention is the bottleneck, likely next steps are finer-grained/shared locking or a return to an event-loop-oriented architecture.

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

## Repository map

```text
.
├── build.zig
├── src/
│   ├── main.zig                 # TCP server, connection loop, expiry worker
│   ├── resp.zig                 # RESP2 parser and serializer
│   ├── commander.zig            # Command parsing and dispatch
│   ├── commander/               # Individual commands, schemas, requests
│   ├── store/                   # Store abstraction, memory store, test mock
│   ├── storage/                 # Storage abstraction and default backend
│   ├── entry.zig                # Stored-value and expiration metadata
│   └── tests.zig                # Unit-test entry point
└── README.md
```

## Scope and current limitations

`kgcache` is intentionally not a drop-in Redis replacement yet.

- Values are strings only; there is no persistence, eviction policy, authentication, replication, clustering, pub/sub, transactions, or RESP3.
- The server reads into a fixed 1 KiB buffer and processes one parsed request per read. Pipelining and requests split across reads are not supported.
- Argument validation remains incomplete for `PING` and `GET`; extra arguments are accepted.
- `COMMAND` is a placeholder, not Redis-compatible introspection.
- The active-expiration worker currently needs a locking fix before it can safely process TTL keys in a running server. Expired keys are still removed by `GET`.

## License
No license file is currently included.

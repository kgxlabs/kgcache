# Architecture

## Overview

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

## Repository map

```text
.
├── build.zig
├── kgcache.conf.example         # Every config directive, documented, at its default
├── src/
│   ├── main.zig                 # TCP server, connection loop, expiry worker
│   ├── config.zig               # Config struct and defaults
│   ├── config_parser.zig        # kgcache.conf parser
│   ├── resp.zig                 # RESP2 parser and serializer
│   ├── commander.zig            # Command parsing and dispatch
│   ├── commander/               # Individual commands, schemas, requests
│   ├── store/                   # Store abstraction, memory store, test mock
│   ├── storage/                 # Storage abstraction and default backend
│   ├── persistence/             # Snapshot (.kgc) and AOF backends
│   ├── entry.zig                # Stored-value and expiration metadata
│   └── tests.zig                # Unit-test entry point
├── docs/                        # Configuration, commands, and architecture reference
└── README.md
```

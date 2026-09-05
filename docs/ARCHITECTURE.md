# Architecture

## Role within kgx

kgcache is being developed as the cache component of the kgx infrastructure stack, with standalone operation and Redis compatibility as design goals. The broader platform vision and roadmap are owned by the [kgxlabs organization](https://github.com/kgxlabs).

The intended boundary is that kgcache owns the cache protocol, command semantics, in-memory storage, expiration, and optional persistence. The future kgx platform will coordinate service provisioning, networking, credentials, and deployment lifecycle. That platform integration is a goal, not a capability of the current server.

## Current implementation

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

## Storage and concurrency trade-offs

The default backend is intentionally straightforward today: a `StringHashMap` stores values, an `ArrayList` holds TTL bookkeeping, and each expiring entry keeps an index into that list for O(1) updates. Full layout, memory cost, and the planned redesign toward larger keyspaces are in [Expiration bookkeeping](EXPIRATION.md).

Concurrency is similarly a deliberate trade-off. The server currently uses detached threads and mutex-protected storage transactions, which keeps the code easy to reason about but can move contention to the storage lock under load. If profiling shows that lock contention is the bottleneck, likely next steps are finer-grained/shared locking or a return to an event-loop-oriented architecture.

## Persistence

Snapshots use `SAVE`, `BGSAVE`, or automatic `save` rules. AOF records each
write and can rewrite the growing log in a background child. See
[Persistence](PERSISTENCE.md) for a comparison,
[Snapshots](SNAPSHOTS.md) for snapshot details, and
[Append-only file](AOF.md) for AOF.

## Repository map

```text
.
├── build.zig
├── kgcache.conf.example         # Every config directive, documented, at its default
├── src/
│   ├── main.zig                 # Entry point: load config, create/destroy Server
│   ├── server.zig               # Owns the object graph; create/destroy/run
│   ├── connection.zig           # Accept loop and per-connection request loop
│   ├── cron.zig                 # Background housekeeping loop (tick schedule)
│   ├── expiration.zig           # Active expiration round/batch policy
│   ├── change_tracker.zig       # Write counter + last-save timestamp for automatic BGSAVE
│   ├── config.zig               # Config struct, defaults, and CLI/file loading
│   ├── config_parser.zig        # kgcache.conf parser
│   ├── resp.zig                 # RESP2 parser and serializer
│   ├── commander.zig            # Command parsing and dispatch
│   ├── commander/               # Individual commands, schemas, requests
│   ├── store/                   # Store abstraction, memory store, test mock
│   ├── storage/                 # Storage abstraction and default backend
│   ├── persistence/             # Snapshot (.kgc) and AOF backends, SAVE/BGSAVE
│   ├── persistence_state.zig    # Shared in-progress/pid tracking for BGSAVE + AOF rewrite
│   ├── entry.zig                # Stored-value and expiration metadata
│   └── tests.zig                # Unit-test entry point
├── docs/                        # Configuration, commands, and architecture reference
│   ├── CONFIGURATION.md
│   ├── COMMANDS.md
│   ├── ARCHITECTURE.md          # This file: overview, design direction, repo map
│   ├── PERSISTENCE.md           # Snapshot and AOF overview
│   ├── SNAPSHOTS.md             # SAVE, BGSAVE, and automatic saving
│   ├── AOF.md                   # AOF setup, fsync, loading, and rewrites
│   └── EXPIRATION.md            # TTL bookkeeping layout, memory cost, planned redesign
└── README.md
```

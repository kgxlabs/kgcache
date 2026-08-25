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

The default backend is intentionally straightforward today: a `StringHashMap` stores values, an `ArrayList` holds TTL bookkeeping, and each expiring entry keeps an index into that list for O(1) updates. Full layout, memory cost, and the planned redesign toward larger keyspaces are in [Expiration bookkeeping](EXPIRATION.md).

Concurrency is similarly a deliberate trade-off. The server currently uses detached threads and mutex-protected storage transactions, which keeps the code easy to reason about but can move contention to the storage lock under load. If profiling shows that lock contention is the bottleneck, likely next steps are finer-grained/shared locking or a return to an event-loop-oriented architecture.

## Persistence

Snapshots to a `.kgc` file happen three ways: `SAVE` (blocking), `BGSAVE` (forked, non-blocking), or automatically once a configured `save <seconds> <changes>` rule is met. All three converge on the same on-disk format and the same in-progress guard, so only one save is ever writing at a time. See [Persistence](PERSISTENCE.md) for the fork/copy-on-write mechanics `BGSAVE` relies on, how a forked child gets reaped without blocking the parent, and how automatic triggering counts writes and decides when to fire.

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
│   ├── ARCHITECTURE.md          # This file — overview, design direction, repo map
│   ├── PERSISTENCE.md           # BGSAVE fork/COW mechanics, reaping, automatic triggering
│   └── EXPIRATION.md            # TTL bookkeeping layout, memory cost, planned redesign
└── README.md
```

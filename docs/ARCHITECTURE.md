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
│ PING · GET · SET │     │ GET · SET · DEL │     │ StringHashMap + TTL │
│ DEL · DBSIZE · … │     │ DBSIZE          │     │ expiration index    │
└─────────────────┘     └────────────────┘     └─────────────────────┘
```

The TCP server has three layers for client connections:

1. `Server` owns the listener, accepts client streams, and owns the shared
   server object graph.
2. `ConnectionManager` owns each worker from registration through completion.
   Workers are joinable. Completed workers are reaped in bounded passes during
   normal runtime, and all remaining workers are joined during shutdown.
3. `Connection` serves one client session using borrowed Store, Logger, and
   stream references. The worker closes its stream exactly once when the
   session ends.

The storage backend owns its copied keys and string values, and protects
operations with a mutex-backed transaction boundary.

### Command registry

The command registry is the runtime source of command metadata. Request
dispatch uses its command names and accepted argument counts. `COMMAND`
introspection reads the same definitions for flags, categories, and key
positions.

Command handlers keep value-dependent validation and execution. The registry
contains typed metadata only. Protocol response construction stays in the
command and connection layers.

Any Store operation that returns storage-backed data copies it while the
transaction is still locked. The command result owns this copy until RESP
serialization finishes, then `Result.deinit` releases it. This keeps response
bytes valid if another client mutates or removes the stored data.

Store mutations that can complete without changing data return
`MutationResult(T)`. Its outcome is `applied` or `not_applied`, while its
`value` holds any data requested from the operation. `SET` uses the value for
the optional previous value, and `DEL` uses `void`. Each command converts this
store result into the shared command `Result` sent through RESP.

The application supervises `Server.run` and a SIGINT/SIGTERM waiter with
`std.Io.Select`. The signal handler only records the signal and wakes the
waiter. Normal application code cancels and waits for `Server.run`, which
stops cron and closes the listener before AOF and Store cleanup begins. A
server runtime failure reaches the same cleanup boundary and is reported as
an error, while a requested signal shutdown is a normal exit.

At shutdown, the accept loop is stopped first. `ConnectionManager` then marks
connection shutdown, wakes blocked receives with socket shutdown, and joins
every worker. Only after the workers have exited does `Server` release AOF,
Store, Storage, persistence, and allocator-owned state. The logger owner keeps
the logger alive through worker shutdown. A requested shutdown of an idle
connection is cooperative and does not produce an error event.

## Storage and concurrency trade-offs

The default backend is intentionally straightforward today: a `StringHashMap` stores values, an `ArrayList` holds TTL bookkeeping, and each expiring entry keeps an index into that list for O(1) updates. Full layout, memory cost, and the planned redesign toward larger keyspaces are in [Expiration bookkeeping](EXPIRATION.md).

Concurrency is similarly a deliberate trade-off. The server currently uses a
joinable thread per connection and mutex-protected storage transactions. This
keeps ownership and shutdown explicit, but can move contention to the storage
lock and can create many threads under load. Runtime reaping prevents finished
worker records from accumulating without bound.

The current design is separate from the future [fixed worker event-loop
refactor (#123)](https://github.com/kgxlabs/kgcache/issues/123). That refactor
may replace per-connection threads with a fixed number of workers that each
serve many connections. Until that work begins, the current connection manager
remains the ownership and shutdown boundary.

## Persistence

Snapshots use `SAVE`, `BGSAVE`, or automatic `save` rules. AOF records each
write and can rewrite the growing log in a background child. See
[Persistence](PERSISTENCE.md) for a comparison,
[Snapshots](SNAPSHOTS.md) for snapshot details, and
[Append-only file](AOF.md) for AOF.

See [Errors and logging](ERRORS.md) for error ownership, terminal reports,
and trace availability.

## Repository map

```text
.
├── build.zig
├── kgcache.conf.example         # Every config directive, documented, at its default
├── src/
│   ├── main.zig                 # Entry point: load config, create/destroy Server
│   ├── server.zig               # Owns the object graph; create/destroy/run
│   ├── connection.zig           # One client session and request loop
│   ├── connection_manager.zig   # Worker ownership, shutdown, joining, reaping
│   ├── cron.zig                 # Background housekeeping loop (tick schedule)
│   ├── expiration.zig           # Active expiration round/batch policy
│   ├── config.zig               # Config struct, defaults, and CLI/file loading
│   ├── config_parser.zig        # kgcache.conf parser
│   ├── resp.zig                 # RESP2 parser and serializer
│   ├── commander.zig            # Command parsing and dispatch
│   ├── commander/               # Individual commands, schemas, requests
│   ├── store/                   # Store abstraction, memory store, test mock
│   ├── storage/                 # Storage abstraction and default backend
│   ├── persistence/             # Snapshot (.kgc) and AOF backends, SAVE/BGSAVE
│   ├── persistence_state.zig    # Persistence lifecycle, retry, and snapshot change accounting
│   ├── entry.zig                # Stored-value and expiration metadata
│   └── tests.zig                # Unit-test entry point
├── docs/                        # Configuration, commands, and architecture reference
│   ├── CONFIGURATION.md
│   ├── COMMANDS.md
│   ├── ARCHITECTURE.md          # This file: overview, design direction, repo map
│   ├── PERSISTENCE.md           # Snapshot and AOF overview
│   ├── SNAPSHOTS.md             # SAVE, BGSAVE, and automatic saving
│   ├── AOF.md                   # AOF setup, fsync, loading, and rewrites
│   ├── ERRORS.md                # Error propagation, logging, and traces
│   └── EXPIRATION.md            # TTL bookkeeping layout, memory cost, planned redesign
└── README.md
```

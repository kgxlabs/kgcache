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

## Background saving (`BGSAVE`)

`SAVE` writes a full snapshot to disk on the connection thread that asked for it — simple, but the client is stuck waiting for however long the write takes. `BGSAVE` exists to avoid that: it returns `OK` immediately, and does the actual write somewhere else, while the server keeps handling other requests.

That "somewhere else" is a forked child process, and getting this right depends on a few OS-level mechanics that are worth spelling out, since they shape most of the code around it.

### `fork()` and copy-on-write, briefly

`fork()` is a POSIX system call that clones the calling process. Right after it returns, there are two processes — the original (the parent) and a near-identical copy (the child) — each about to continue running from the exact same point in the code, distinguished only by `fork()`'s return value (`0` in the child, the child's real process ID in the parent).

The clone is cheap because the OS doesn't actually copy memory up front. Parent and child start out pointing at the *same* physical memory pages; those pages are marked copy-on-write (COW), meaning the first time either process writes to one, the OS transparently gives that process its own private copy of just that one page. Pages nobody touches are never duplicated at all.

For `BGSAVE`, this is exactly the "snapshot" primitive it needs: the child sees the entire dataset frozen at the instant of `fork()`, and can spend as long as it wants writing that frozen view to disk. Meanwhile the parent keeps serving requests and mutating its own data — those writes trigger COW faults that give the parent private pages, but never touch what the child sees. No lock is held on the dataset for the duration of the write; the OS's own memory model does the isolating.

`KgcBackend.bgsave` (`src/persistence/kgc.zig`) is the whole implementation:

```text
tryStartKgc() fails? ──▶ return SaveAlreadyInProgress, don't fork

fork()
 ├─ child:  close stdin/stdout, dump(storages), then _exit()
 │          (never returns into the caller's connection-handling code)
 └─ parent: record the child's pid, return OK immediately
```

A few details here are load-bearing, not stylistic:

- **The child calls `dump()`, a private helper — never the public `save()`.** `save()` also claims the "in progress" flag before running; since the parent already claimed it before forking, the child would immediately fail its own claim and skip the write entirely if it went through `save()`.
- **The child terminates with the raw `_exit()`, never `std.process.exit()`/libc's `exit()`.** The child is a COW copy of the *whole* parent process, including any atexit handlers registered before the fork and anything sitting unflushed in libc's stdio buffers at that instant. Libc's normal `exit()` would run those handlers and flush those buffers a second time, independently, in a process that has no business repeating either. `_exit()` skips straight to the kernel's exit syscall, doing neither.
- **The child closes its inherited stdin/stdout before doing anything else.** A background child has no use for either, and holding a duplicate of them open can keep whatever's on the other end of that fd waiting indefinitely for an `EOF` that never comes.
- **The child never returns from `bgsave()`.** If it did, execution would fall back into whatever called it — the same per-connection code path the parent is running — now duplicated across two processes sharing the same allocator and inherited sockets.

### Why one background save at a time

Two `BGSAVE`s (or a `SAVE` and a `BGSAVE`) writing to the same `.kgc` file at once would interleave or corrupt the output. `PersistenceState` (`src/persistence_state.zig`) is the guard against that: a small piece of state, shared by every connection thread and the background housekeeping loop, tracking whether a kgc save and/or an AOF rewrite is currently in flight, plus the pid of whichever child is running.

The claim has to happen in the *parent*, before `fork()` — a flag flipped inside the child would only ever exist in the child's own COW-private copy of that memory, invisible to the parent and every other thread, which is exactly the same isolation `BGSAVE` relies on for the snapshot itself working correctly here. `save()` and `bgsave()` both claim the same flag before doing any writing, and `SAVE`/`BGSAVE` share one error for it — whichever asks first wins, the other gets `SaveAlreadyInProgress` immediately.

Since kgcache handles each connection on its own OS thread, this state is genuinely shared across threads, not just across the fork boundary — `PersistenceState` protects it with a mutex rather than a plain flag.

### Reaping: why it can't happen inside `bgsave()`

When a child process exits, the kernel doesn't let it fully disappear until its parent calls `waitpid()` on it — until then it's a "zombie", just sitting in the process table. `bgsave()` itself can't be the one to reap its child: `waitpid()` without `WNOHANG` blocks until the child exits, which would make the parent wait anyway and defeat the entire point of `BGSAVE` being non-blocking.

So reaping happens on its own timeline instead: the background housekeeping loop in `cron.zig` (`cron-interval-ms`, shared with active expiration — see [Configuration](CONFIGURATION.md)) polls with `waitpid(pid, &status, WNOHANG)` on every tick. If the child hasn't exited yet, it's a no-op; once it has, the loop clears `PersistenceState`'s flag and pid, and checks the exit status — a non-zero exit (the child hit a write failure) gets logged to stderr, since there's no other channel left to report it through by that point.

### `exclusive-bg-persistence`

By default, a `BGSAVE` and an AOF background rewrite are mutually exclusive — starting one while the other is running fails immediately rather than forking a second child. Turning this off (`exclusive-bg-persistence no`) is possible but not recommended: two children forked at once means the parent and *both* children share the same COW memory, so every write in the parent afterward risks a page copy being charged against both children instead of one — real Redis operators are advised against running `BGSAVE` and `BGREWRITEAOF` close together for the same reason.

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
└── README.md
```

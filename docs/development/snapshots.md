# Snapshot internals

[Developer documentation](README.md) / Snapshots

For mode selection, paths, save rules, and user-visible guarantees, use the
[user persistence guide](../user/persistence.md#snapshot-setup). Snapshots use
kgcache's `.kgc` format. This page covers child ownership, copy-on-write,
claims, dirty counts, and shutdown completion.

## Background saving (`BGSAVE`)

SAVE writes a full snapshot on the requesting connection's thread. The caller
waits for completion. BGSAVE starts a child and returns once the child is
registered. If an AOF rewrite owns the exclusive persistence claim, it records
one pending save instead.

### `fork()` and copy-on-write

`fork()` creates a child process with the parent's memory view. It returns
zero in the child and the child's PID in the parent. Both continue after the
call, so each branch must have a clear exit path.

The OS initially shares physical pages between parent and child. A write by
either process makes a private copy of that page. This is copy-on-write (COW).
For BGSAVE, the child writes the dataset captured at the fork. The parent can
continue serving requests. Later writes do not change the child's view.
Storage locks protect capture and are not held for the child's full disk write.

```text
              fork()
               │
   ┌───────────┴───────────┐
   ▼                       ▼
 parent                  child
   │                       │
   │ keeps serving        dump(storages): writes the
   │ requests; writes     COW-frozen view to disk
   │ trigger private       │
   │ COW copies             _exit()  (never returns)
   ▼
 returns Background saving started
```

The request has three possible outcomes:

```text
BGSAVE request
 ├─ another save is active: return an error
 ├─ an exclusive AOF rewrite is active: schedule one save
 └─ otherwise: start saving

When saving starts:
fork()
 ├─ child:  close stdin/stdout, dump(storages), then _exit()
 │          (never returns into the caller's connection-handling code)
 └─ parent: capture the change count, record the child's pid and origin,
            then return started immediately
```

A few details here are load-bearing, not stylistic:

- **The child calls `dump()`, a private helper, never the public `save()`.** `save()` also claims the "in progress" flag before running; since the parent already claimed it before forking, the child would immediately fail its own claim and skip the write entirely if it went through `save()`.
- **The child terminates with the raw `_exit()`, never `std.process.exit()`/libc's `exit()`.** The child is a COW copy of the *whole* parent process, including any atexit handlers registered before the fork and anything sitting unflushed in libc's stdio buffers at that instant. Libc's normal `exit()` would run those handlers and flush those buffers a second time, independently, in a process that has no business repeating either. `_exit()` skips straight to the kernel's exit syscall, doing neither.
- **The child closes its inherited stdin/stdout before doing anything else.** A background child has no use for either, and holding a duplicate of them open can keep whatever's on the other end of that fd waiting indefinitely for an `EOF` that never comes.
- **The child never returns from `bgsave()`.** If it did, execution would fall back into whatever called it, the same per-connection code path the parent is running, now duplicated across two processes sharing the same allocator and inherited sockets.

### Why one background save at a time

Each save writes a unique temporary file. Saves still share one publication
slot and dirty-change counter. `PersistenceState` serializes that lifecycle
so one completion cannot replace a newer snapshot or account for the same
changes twice. It tracks the save/rewrite claims and child PIDs for connection
threads, cron, and shutdown.

The claim has to happen in the *parent*, before `fork()`: a flag flipped inside the child would only ever exist in the child's own COW-private copy of that memory, invisible to the parent and every other thread, which is exactly the same isolation `BGSAVE` relies on for the snapshot itself working correctly here. `SAVE` and `BGSAVE` share one "save already in progress" error. Repeated manual requests while a save is active are errors, not a queue.

`BGSAVE` accepts either no argument or one case-insensitive `SCHEDULE` token.
Both forms follow the same policy. When an AOF rewrite blocks the save, one
pending save is recorded and repeated requests coalesce into it. This is an
intentional difference from Redis: bare `BGSAVE` schedules in this case too.

Connection threads and cron share this state. `PersistenceState` protects its
lifecycle transitions with a mutex.

### Reaping: why it can't happen inside `bgsave()`

When a child process exits, the kernel doesn't let it fully disappear until its parent calls `waitpid()` on it: until then it's a "zombie", just sitting in the process table. `bgsave()` itself can't be the one to reap its child: `waitpid()` without `WNOHANG` blocks until the child exits, which would make the parent wait anyway and defeat the entire point of `BGSAVE` being non-blocking.

During normal operation, reaping happens on its own timeline: the background housekeeping loop in `cron.zig` (`cron-interval-ms`, shared with active expiration; see [Configuration](../user/configuration.md)) polls with `waitpid(pid, &status, WNOHANG)` on every tick.

```text
tick 1: fork() ── child starts dumping
tick 2: waitpid(WNOHANG) → still running → no-op
tick 3: waitpid(WNOHANG) → still running → no-op
tick 4: waitpid(WNOHANG) → exited
          ├─ success: publish the snapshot, then account for captured changes
          └─ failure: keep all changes dirty; the parent reports the failure
        then clear the in-progress flag
```

If the child has not exited yet, the poll is a no-op. Once it has,
`PersistenceState` clears the recorded child, returns its status and captured
change count, and keeps the save claim active until cron finishes accounting
for the result. The child writes and syncs a unique temporary file. After a
successful child exit, the parent replaces the snapshot with that file.
Only then are the captured changes marked as saved. A failed child or failed
replacement leaves every change dirty. The child exits without logging;
the parent reports `BackgroundSaveFailed` for an ordinary exit of 1, or the
existing reaper error for a wait or abnormal-exit failure. The child's original
error and trace are temporarily unavailable. Cron releases the save claim only
after this work is complete. See [Errors and logging](errors.md).

During shutdown, kgcache stops accepting work and stops cron, then drains and
joins all client workers. A worker can start `BGSAVE` while it is finishing a
request, so the server checks for tracked children after the workers have
joined. The server logs each operation and PID, then polls both children under
one shared `persistence-shutdown-grace-ms` budget (default 10000 ms). At expiry,
it reports a timeout and sends `SIGKILL` to remaining children. Zero skips the
graceful wait, but completed children are still collected before termination.
Shutdown does not retry a failed final save.

The budget starts once, after workers join. Finishing an operation does not
reset the time limit.

After termination, the server allows up to 1000 ms to collect child exits. If a
child remains unresolved, it returns an error and retains resources still needed
by persistence. This bounds child polling, not disk operations, client draining,
or the kernel's ability to terminate a process. A killed child may leave a
snapshot temporary file; it is not treated as a completed snapshot.

The server reaps the child and handles its result before releasing snapshot
state or the borrowed logger. A successful save becomes the latest completed
snapshot, covering the data captured when the child forked. A failed save does
not mark those changes as saved; the previous completed snapshot remains the
latest one. Shutdown reports the failure and continues safe cleanup. See
[AOF shutdown](aof.md#shutdown) for the rewrite and final flush order.

### `exclusive-bg-persistence`

By default, a `BGSAVE` and an AOF background rewrite are mutually exclusive. A manual `BGSAVE` or `BGREWRITEAOF` request for the other kind is scheduled and starts after the active operation finishes. Repeated requests coalesce into one scheduled operation. If that operation cannot start, it remains scheduled and is tried again. Starting a scheduled save does not count as a successful save.

Turning exclusivity off (`exclusive-bg-persistence no`) is possible but not recommended. It lets one `BGSAVE` and one AOF rewrite run at the same time. Two children then share the parent's COW memory, so every later parent write may require page copies for both children.

## Final shutdown save

With AOF off, the server can start a final snapshot after workers join and
existing children settle. It uses the drain context's remaining budget.
The child does not get a fresh grace period. Success must publish the snapshot
before its captured changes become clean. Failure preserves dirty state and
returns a shutdown error. There is no retry after a failed final attempt.

The exact setting behavior and forced-stop limits are in
[user shutdown guarantees](../user/persistence.md#shutdown-and-failure-limits).

## Automatic background saving (condition-based snapshots)

Beyond on-demand `SAVE`/`BGSAVE`, kgcache can trigger a `BGSAVE` on its own once enough writes have piled up: the same idea as `redis-server`'s `save <seconds> <changes>` directive (see [Configuration](../user/configuration.md#automatic-background-saving-save) for the config format). This needs two things: something that counts writes, and something that periodically checks whether a configured rule has been satisfied.

### Counting writes: `PersistenceState`

`PersistenceState` (`src/persistence_state.zig`) owns the full snapshot lifecycle. Along with the in-progress state described above, it tracks the number of writes since the last completed snapshot and the time of that snapshot. Keeping these values together makes claiming, capturing, completing, and retrying a save one coordinated operation.

- `recordChange()` uses an atomic increment, so write paths do not need the persistence-state lock.
- `dueForSave()` reads the atomic change count and last-save time without blocking writers.
- Save lifecycle transitions and completion accounting run while holding the persistence-state lock.
- `markSaved()` subtracts only the count captured for that snapshot. Changes recorded later remain dirty for the next save.

`recordChange()` is called from `NotifierStorage`, the same vantage point that already sees every write for AOF journaling, on every `put`, `remove`, and lazy-expiration removal during `get` (Redis's own dirty counter counts expiry-driven removals too).

Before either save path accesses the dataset, `MemoryStore` acquires every storage lock. For `BGSAVE`, the parent captures the change count after `fork()` and before it records the in-flight child. No write can complete between the fork and that capture, so the count describes exactly the mutations visible to the child. For synchronous `SAVE`, the locks remain held through the dump and its completion accounting.

### Deciding when to trigger: the cron tick

Every `cron-interval-ms` tick, after reaping any finished background-save child, the housekeeping loop asks `PersistenceState.dueForSave(now, config.save_rules)`: for each configured rule, is the change count at least `changes`, and have at least `seconds` seconds elapsed since the last successful save? Any single matching rule is enough to trigger a `BGSAVE`.

```text
Write path (every db, every put/remove):
  NotifierStorage.put()/remove() ──▶ PersistenceState.recordChange()
                                       (atomic increment, no state lock)

Trigger path (every cron-interval-ms tick):
  cron tick
    │
    ▼
  PersistenceState.dueForSave(now, config.save_rules)
    │  any rule: elapsed_seconds ≥ rule.seconds AND changes ≥ rule.changes ?
    ▼ yes
  Store.bgsave() locks every storage and forks
    │
    ├─ child dumps to disk, exits
    └─ parent captures change count and records the in-flight child
         │
         ▼ (a later tick)
  PersistenceState.reapKgc() notices the child exited
    │
    ├─ success: PersistenceState.markSaved(captured_change_count, now)
    │             (changes → changes - captured count, last-save → now)
    └─ failure: preserve the change count and last-save time
```

An automatic save failure starts a retry cooldown. Cron keeps evaluating the save rules, but it does not try another automatic `BGSAVE` until `bgsave-retry-delay-ms` has elapsed. `SaveAlreadyInProgress` does not start the cooldown because it means another persistence operation already owns the claim. A successful save clears any existing cooldown.

Automatic saves remain immediate attempts and are never scheduled behind an
AOF rewrite.

### Why the reset can't happen at the trigger call site

`markSaved()` has to run once a save has *actually finished writing to disk*. Where that moment occurs differs between the two save paths, which is why the reset logic is split across two call sites instead of one:

```text
SAVE (synchronous)                    BGSAVE (forked)
───────────────────                   ────────────────
MemoryStore locks every storage       MemoryStore locks every storage
  → KgcBackend.dump() runs on           → KgcBackend forks
    the connection thread               → parent captures the change count
  → KgcBackend captures the count        → child writes the frozen snapshot
  → markSaved() runs before return       → cron waits for reapKgc()
                                         → markSaved() runs only on success
```

Reaping a **failed** child (non-zero exit) does not call `markSaved()`, because no snapshot was successfully written. The change count and last-save timestamp remain unchanged, so an automatic save remains due and can retry after its cooldown.

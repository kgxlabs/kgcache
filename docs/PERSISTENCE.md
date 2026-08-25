# Persistence

How `SAVE`/`BGSAVE` write a `.kgc` snapshot, why `BGSAVE` is safe to run alongside live traffic, and how automatic condition-based saving decides when to trigger one on its own.

## Background saving (`BGSAVE`)

`SAVE` writes a full snapshot to disk on the connection thread that asked for it — simple, but the client is stuck waiting for however long the write takes. `BGSAVE` exists to avoid that: it returns `OK` immediately, and does the actual write somewhere else, while the server keeps handling other requests.

That "somewhere else" is a forked child process, and getting this right depends on a few OS-level mechanics that are worth spelling out, since they shape most of the code around it.

### `fork()` and copy-on-write, briefly

`fork()` is a POSIX system call that clones the calling process. Right after it returns, there are two processes — the original (the parent) and a near-identical copy (the child) — each about to continue running from the exact same point in the code, distinguished only by `fork()`'s return value (`0` in the child, the child's real process ID in the parent).

The clone is cheap because the OS doesn't actually copy memory up front. Parent and child start out pointing at the *same* physical memory pages; those pages are marked copy-on-write (COW), meaning the first time either process writes to one, the OS transparently gives that process its own private copy of just that one page. Pages nobody touches are never duplicated at all.

For `BGSAVE`, this is exactly the "snapshot" primitive it needs: the child sees the entire dataset frozen at the instant of `fork()`, and can spend as long as it wants writing that frozen view to disk. Meanwhile the parent keeps serving requests and mutating its own data — those writes trigger COW faults that give the parent private pages, but never touch what the child sees. No lock is held on the dataset for the duration of the write; the OS's own memory model does the isolating.

```text
              fork()
               │
   ┌───────────┴───────────┐
   ▼                       ▼
 parent                  child
   │                       │
   │ keeps serving        dump(storages) — writes the
   │ requests; writes     COW-frozen view to disk
   │ trigger private       │
   │ COW copies             _exit()  (never returns)
   ▼
 returns OK immediately
```

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

So reaping happens on its own timeline instead: the background housekeeping loop in `cron.zig` (`cron-interval-ms`, shared with active expiration — see [Configuration](CONFIGURATION.md)) polls with `waitpid(pid, &status, WNOHANG)` on every tick.

```text
tick 1: fork() ── child starts dumping
tick 2: waitpid(WNOHANG) → still running → no-op
tick 3: waitpid(WNOHANG) → still running → no-op
tick 4: waitpid(WNOHANG) → exited        → clear pid/in-progress flag
                                             non-zero exit? log to stderr
```

If the child hasn't exited yet, the poll is a no-op. Once it has, the loop clears `PersistenceState`'s flag and pid, and checks the exit status — a non-zero exit (the child hit a write failure) gets logged to stderr, since there's no other channel left to report it through by that point.

### `exclusive-bg-persistence`

By default, a `BGSAVE` and an AOF background rewrite are mutually exclusive — starting one while the other is running fails immediately rather than forking a second child. Turning this off (`exclusive-bg-persistence no`) is possible but not recommended: two children forked at once means the parent and *both* children share the same COW memory, so every write in the parent afterward risks a page copy being charged against both children instead of one — real Redis operators are advised against running `BGSAVE` and `BGREWRITEAOF` close together for the same reason.

## Automatic background saving (condition-based snapshots)

Beyond on-demand `SAVE`/`BGSAVE`, kgcache can trigger a `BGSAVE` on its own once enough writes have piled up — the same idea as `redis-server`'s `save <seconds> <changes>` directive (see [Configuration](CONFIGURATION.md#automatic-background-saving-save) for the config format). This needs two things: something that counts writes, and something that periodically checks whether a configured rule has been satisfied.

### Counting writes: `ChangeTracker`

`ChangeTracker` (`src/change_tracker.zig`) tracks two things: a dirty counter (writes since the last save) and the timestamp of the last save. It's deliberately atomics-only, no mutex:

- Incrementing the counter (`recordChange`) only needs "don't lose concurrent increments" — a single-field atomicity guarantee, not a multi-step critical section, so `fetchAdd` is enough.
- Resetting it (`markSaved`) uses `swap(0, ...)` rather than "read, then separately write 0" — one indivisible op, so a concurrent `recordChange()` either lands before the swap (counted, then reset) or after it (preserved for the next round). Nothing is silently dropped, and no lock is required.

`recordChange()` is called from `NotifierStorage` — the same vantage point that already sees every write for AOF journaling — on every `put`, `remove`, and lazy-expiration removal during `get` (Redis's own dirty counter counts expiry-driven removals too).

### Deciding when to trigger: the cron tick

Every `cron-interval-ms` tick, after reaping any finished background-save child, the housekeeping loop asks `ChangeTracker.dueForSave(now, config.save_rules)`: for each configured rule, has at least `changes` writes happened in the last `seconds` seconds since the last save? Any single matching rule (OR'd together) is enough to trigger a `BGSAVE`.

```text
Write path (every db, every put/remove):
  NotifierStorage.put()/remove() ──▶ ChangeTracker.recordChange()
                                       (atomic fetchAdd, no lock)

Trigger path (every cron-interval-ms tick):
  cron tick
    │
    ▼
  ChangeTracker.dueForSave(now, config.save_rules)
    │  any rule: elapsed_seconds ≥ rule.seconds AND dirty ≥ rule.changes ?
    ▼ yes
  Store.bgsave() ── fork() ── child dumps to disk, exits
    │
    ▼ (a later tick)
  PersistenceState.reapKgc() notices the child exited
    │
    ▼
  ChangeTracker.markSaved(now)   (dirty → 0, last_save → now)
```

A failed trigger attempt (`bgsave()` returning an error) is logged to stderr and otherwise ignored — it's just re-evaluated on the next tick, the same as any other transient failure in the cron loop.

### Why the reset can't happen at the trigger call site

`markSaved()` has to run once a save has *actually finished writing to disk* — and where that moment is differs between the two save paths, which is why the reset logic is split across two call sites instead of one:

```text
SAVE (synchronous)                    BGSAVE (forked)
───────────────────                   ────────────────
MemoryStore.save()                    Store.bgsave() returns as soon as
  → dump() runs on this thread,          fork() succeeds — the child
    blocking the caller                  hasn't written anything yet
  → the dump is done by the time
    save() returns                    markSaved() has to wait for
  → markSaved() runs right there        PersistenceState.reapKgc() to
                                         observe the child has exited
                                         (see "Reaping" above) — it runs
                                         from the cron loop, not from
                                         bgsave()'s call site
```

Reaping a **failed** child (non-zero exit) still calls `markSaved()`. This is a deliberate choice: without it, `dueForSave()` would stay true forever after one failed attempt (e.g. a full disk), and cron would retry a doomed fork on every single tick instead of waiting for the next rule match. Resetting means a persistently failing save is retried once per window, not once per tick — the tradeoff is that a single transient failure delays the next attempt until the counter climbs back up, rather than retrying immediately.

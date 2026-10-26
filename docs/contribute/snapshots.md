# Understand snapshot saves

[Docs](../README.md) / [Contribute](README.md) / Snapshot internals

kgcache snapshots use its own `.kgc` format. This guide explains how a save
captures data, publishes a file, and accounts for writes. Command syntax is
in [SAVE](../commands/save.md) and [BGSAVE](../commands/bgsave.md).

The implementation is split between [MemoryStore](../../src/store/mem_store.zig),
[KgcBackend](../../src/persistence/kgc.zig), and
[PersistenceState](../../src/persistence_state.zig).

## Compare the two save paths

| Stage | SAVE | BGSAVE |
| --- | --- | --- |
| Claim | Parent claims the shared save slot | Parent claims it before fork |
| Capture | Store holds every storage lock | Store holds every lock through fork and dirty-count capture |
| Write | Requesting thread writes and syncs | Child writes and syncs its frozen memory view |
| Completion | Publish and account before returning | Parent reaps, publishes, and accounts later |
| Request result | Return after the save finishes | Return after the child is tracked, or report scheduling |

Each attempt writes a unique temporary file. Saves still share publication
and dirty-count accounting, so the lifecycle is serialized. This prevents an
older completion from replacing a newer snapshot or cleaning the same changes
twice.

## Keep the fork boundary explicit

`fork()` returns zero in the child and the child PID in the parent. The OS
shares memory pages until a write makes a private copy. The child therefore
sees the dataset captured at fork while the parent resumes serving clients.
Storage locks are not held for the child's full disk write.

The child closes stdin and stdout. This avoids holding an inherited output
pipe open after the parent finishes. It calls the private dump path, which
must not attempt to claim the parent's save slot again.

On success it calls `_exit(0)`; on a caught failure it calls `_exit(1)`.
It never returns into the parent's connection loop. It must not use normal
process exit, which could run copied exit handlers or flush copied stdio
buffers. It must not call the copied Logger.

Other inherited runtime locks remain a risk. The [error guide](errors.md)
describes the temporary status-only reporting contract and its follow-up work.

## Completion and publication

During normal operation, cron polls `waitpid` with `WNOHANG`. Waiting inside
the BGSAVE request would block the parent and defeat background execution.

After the child exits, state releases child tracking but keeps the save claim
through result handling. On success, the parent replaces the snapshot with
the child's synced temporary file. Only successful publication marks captured
changes saved. A child failure or replacement failure leaves every change dirty
and keeps the previous complete snapshot.

Cron releases the claim after publication and accounting. An ordinary failed
exit becomes `BackgroundSaveFailed`; wait and abnormal-exit errors preserve the
source the parent can identify. The child's original failure is unavailable.

The rename is atomic but lacks parent-directory fsync. A killed child can leave
a temporary file, which is not a completed snapshot. See the shared
[persistence limits](persistence.md#keep-the-limits-visible).

## Count changes without losing later writes

`NotifierStorage` calls `recordChange()` for applied puts, removals, and
expiration-driven removals. The count uses an atomic increment so write paths
do not need the persistence-state mutex.

`dueForSave()` reads the count and last successful save time. Lifecycle changes
and completion accounting use the state lock. `markSaved()` subtracts the
captured count rather than setting the counter to zero. Changes after capture
therefore remain due for a later snapshot.

For BGSAVE, all storage locks prevent a write between fork and the parent's
count capture. For SAVE, those locks remain held through dumping and completion
accounting. Keep these boundaries together when changing the save path.

## Schedule manual and automatic work

Manual BGSAVE accepts an optional `SCHEDULE`, but both forms follow the same
kgcache policy. An active save is an error. With exclusive background work, an
active AOF rewrite records one pending save instead. Repeated requests coalesce.
A pending start failure preserves the request for retry.

Automatic saves evaluate each `save <seconds> <changes>` rule on a cron tick.
Both thresholds must match for a rule. Any matching rule can trigger a save.
Automatic saves attempt immediately and do not queue behind a rewrite.

A failed automatic save starts the `bgsave-retry-delay-ms` cooldown. A busy save
does not, because another operation already owns the claim. Success clears the
cooldown. Starting a save never updates the successful-save time.

## Handle a final shutdown snapshot

After workers and existing children finish, snapshot-only shutdown can require
one final save. It uses the drain context's remaining budget, without a fresh
deadline. A successful existing save can make the final save unnecessary.
A failed final attempt returns a shutdown error and is not retried.

Keep the snapshot backend, storage, and logger alive through child completion.
The full ordering and unresolved-child policy are in
[persistence shutdown](persistence.md#shutdown-order). Public policy is in
[operator shutdown](../operate/shutdown.md).

## Verify a change

Run `zig build test` and `zig build test-integration`. Use
[kgc_tests.zig](../../src/persistence/kgc_tests.zig) for backend failures and
[process suites](../../tests/integration/suites) for restart, final save,
publication failure, child timing, and signal behavior. Assert stored data and
process result, not just the presence of a file.

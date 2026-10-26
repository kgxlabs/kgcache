# Understand persistence lifecycle

[Docs](../README.md) / [Contribute](README.md) / Persistence lifecycle

Persistence connects storage locks, journal records, background children, and
server teardown. Read this before changing their order. Operators should use
[persistence](../operate/persistence.md) and [shutdown](../operate/shutdown.md)
for settings and data-loss limits.

## Know the owners

| Component | Owns or coordinates |
| --- | --- |
| Server | Snapshot backend, optional journal, Store, storage instances, shared persistence state |
| Store | Transactions that protect reads, mutations, and snapshot capture |
| NotifierStorage | Journal preparation/publication and change counting around applied mutations |
| PersistenceState | Save/rewrite claims, child PIDs, pending work, retries, and dirty counts |
| Cron | Normal-runtime child reaping, result handling, scheduled work, and automatic attempts |
| Drain context | One shutdown deadline, result accounting, and first-error retention |

Sources: [server.zig](../../src/server.zig),
[notifier_storage.zig](../../src/storage/notifier_storage.zig),
[persistence_state.zig](../../src/persistence_state.zig), and
[drain.zig](../../src/persistence/drain.zig).

## Preserve mutation order

A journal-backed mutation prepares its record before touching storage. If
preparation fails, the mutation never runs. If storage fails, the prepared
record is aborted. After an applied mutation, publication adds the prepared
bytes without an allocation or disk operation and cannot fail.

Flush and sync happen separately. They can fail after memory and the journal
buffer have changed. Preserve that distinction in errors and retries. A
conditional write that does not apply must not publish a mutation record.
See [AOF transaction flow](aof.md#write-path).

## Capture a snapshot consistently

The Store takes all storage locks before accessing the full dataset. A
background save forks while those locks prevent writes. The parent captures
the dirty-change count before releasing capture locks and registering the
completed start. That count describes the child's frozen view.

A successful publication subtracts only the captured count. Later changes
stay dirty. A failed save preserves dirty state. See
[snapshot completion](snapshots.md#completion-and-publication).

## Coordinate background work

SAVE and BGSAVE share a save claim. Only one AOF rewrite can run at once.
With the default exclusivity policy, a save and rewrite cannot overlap.
A manual request blocked by the other kind records one pending request.
Repeated requests coalesce. A failed start keeps the request pending for retry.

Automatic work attempts immediately and does not join the manual queue.
Starting work is not successful completion. Result handling must run before
releasing a claim that guards publication or accounting.

## Shutdown order

1. Stop the accept loop and cron.
2. Shut down client sockets and join all workers. A finishing worker can still
   have started persistence, so inspect children after joining.
3. Drain tracked snapshot and rewrite children with backends and Logger alive.
4. Settle a completed rewrite or snapshot, including rollback on failure.
5. With AOF off, start a required final snapshot if dirty state and policy need
   one and budget remains. Use the same context and deadline.
6. Finish the journal's final flush and applicable sync after rewrite state is
   settled, then close resources that no child or pending completion needs.
7. Report the first shutdown error after remaining safe cleanup.

The drain context starts one monotonic `persistence-shutdown-grace-ms` budget
after worker joining. The default is 10000 ms. Repeated drain calls and a final
snapshot do not restart it. Zero skips graceful waiting; completed children
are still collected before termination.

At expiry, remaining children receive SIGKILL. A further 1000 ms permits reaping.
If a child remains unresolved, report an error and retain its resources.
Do not close a backend or release storage while child ownership is uncertain.

This deadline bounds polling. It does not bound worker draining, filesystem
calls, or every cleanup path. A forced outer stop can still interrupt data
publication. Shutdown does not retry a failed final save.

## Report child results

Children exit with 0 or 1 and avoid the copied logger. The parent reports a
failed snapshot or rewrite as a generic operation failure. Child source errors
and traces remain unavailable under the current contract.

An AOF failure cached by cron is not logged again during shutdown. It can still
make shutdown fail when shutdown handles that completion. Completion failures
and cleanup failures are separate errors. See [error reporting](errors.md).

## Keep the limits visible

Temporary data files are synced before rename, but their parent directory is
not fsynced. [#64](https://github.com/kgxlabs/kgcache/issues/64) tracks this gap.
Forked encoding, allocation, and I/O still need a full safety review under
[#118](https://github.com/kgxlabs/kgcache/issues/118). Stream collection remains
[#227](https://github.com/kgxlabs/kgcache/issues/227).

These are limits of current behavior. Passing clean-restart or child-timeout
tests does not remove them. Preserve the public limits when changing these
internals, and update the relevant [automated tests](testing.md).

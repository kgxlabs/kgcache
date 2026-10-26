# Persistence internals

[Developer documentation](README.md) / Persistence

For mode selection, configuration, crash-loss limits, and shutdown guarantees,
use the [user persistence guide](../user/persistence.md).

The server owns the snapshot backend, optional journal backend, Store, storage
instances, and shared `PersistenceState`. The Store takes storage transactions
for reads and mutations. Snapshot capture takes every storage lock so the
forked view and captured dirty count describe the same state.

`NotifierStorage` prepares a journal record before mutation and publishes it
only after an applied change. Aborted preparation does not add a journal record.
Publication cannot return an error. A separate flush/sync can fail after the
change is applied. Error reporting must preserve that distinction.

`PersistenceState` owns save claims, tracked child PIDs, pending manual work,
retry state, and dirty-change accounting. A successful snapshot subtracts the
captured change count. Later writes stay dirty. A failed save preserves the
count. Cron reaps completed work and dispatches pending work during normal use.

Shutdown stops cron and joins client workers before draining children. Result
handling runs while backends and the borrowed logger are alive. The same drain
context covers existing children and any required final snapshot. It preserves
the shared deadline across repeated drain calls.

Use [snapshot internals](snapshots.md) for copy-on-write, claim timing, and dirty
counts. Use [AOF internals](aof.md) for file replay, rewrite publication,
rollback, and write failures. [Errors and logging](errors.md) describes the
current generic child-failure boundary.

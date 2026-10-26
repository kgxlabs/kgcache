# Change the append-only journal

[Docs](../README.md) / [Contribute](README.md) / AOF internals

The journal must describe applied mutations in storage order. This guide covers
record preparation, file replay, manifest changes, and rewrite recovery.
Operators should use [persistence](../operate/persistence.md) for mode choices,
fsync policy, and data-loss limits.

Sources: [aof.zig](../../src/persistence/aof.zig),
[journal_interface.zig](../../src/persistence/journal_interface.zig),
[aof_loader.zig](../../src/persistence/aof_loader.zig), and
[manifest.zig](../../src/persistence/manifest.zig).

## Write path

Every journal-backed change follows four steps:

```text
prepare record -> mutate storage -> publish record -> request flush
```

Preparation encodes the record and reserves buffer space. It changes no stored
data and publishes no bytes. If storage fails, abort the prepared record.
After an applied mutation, `Record.publish()` appends the reserved bytes without
allocating or doing disk I/O. It returns `void` and cannot fail.

`NotifierStorage` then requests a separate `.if_required` flush. Puts, removals,
lazy expiration, and active expiration all use this flow. A rejected conditional
write has no mutation record.

| Flush mode | Behavior | Caller |
| --- | --- | --- |
| `.if_required` | Write and sync for `always`; leave buffered records for `everysec` and `no` | Mutation notification |
| `.unconditional` | Write buffered records now; sync according to policy | Cron and final cleanup |

For `always`, the applied command returns success only after that flush and
sync succeed. Publication and durability are distinct stages.

## File layout and records

The `appenddirname` directory is relative to `dir`. With default names, a
rewritten log can contain:

```text
appendonlydir/
  appendonly.aof.1.base
  appendonly.aof.2.incr
  appendonly.aof.manifest
```

The base reconstructs live data captured for a rewrite. Incremental files hold
later mutations. The manifest selects their replay order. Before the first
rewrite it names only the initial incremental file.

Records are flat RESP command arrays, independent of the connection's reply
mode. The command encoder emits SELECT when needed, followed by canonical SET
or DEL records. Expiration is encoded as absolute PXAT time so a restart does
not restart a relative TTL.

Replaying calls the shared request decoder and normal command execution with
journaling disabled. Startup reconciliation removes generated AOF data files
absent from the manifest. That directory must contain only journal-owned data.

## Replay and tail recovery

Startup reads the manifest, replays the base, then replays incrementals in
order. Each file is currently read fully into memory. Its buffer coexists with
the restored dataset and command allocations. [#173](https://github.com/kgxlabs/kgcache/issues/173)
tracks streamed input.

| Result at a file boundary | Action |
| --- | --- |
| Complete commands through EOF | Continue |
| Unfinished last command of the final incremental, recovery enabled | Truncate to the last executed-command boundary, warn, and continue |
| Unfinished base or earlier incremental | Fail and preserve bytes |
| Unfinished final command with recovery disabled | Fail and preserve bytes |
| Malformed input, invalid command, or resource failure | Fail and preserve bytes |

`aof-load-truncated yes` enables only the second row. The safe boundary advances
after successful execution, not just successful decoding. Recovery drops the
unfinished command and everything after its start. It does not search for
later commands.

An invalid header or terminator remains malformed at EOF. Open, read, and
truncation errors fail startup. Log the recovery warning only after truncation
succeeds. The format has no checksum, so a damaged length can resemble an
interrupted final write.

## Rewrite publication

A rewrite replaces accumulated mutation history with a new base of live data.
New writes continue in an incremental file while the child writes its base.

The parent must publish the new incremental before it forks:

```text
old base + old incrementals
    -> create and publish a new incremental
    -> switch new writes to it
    -> fork a child to write a new base
    -> on child success, publish new base + live incremental
    -> remove retired files
```

If the child fails or the server stops, the existing manifest still names every
incremental containing writes. Publishing the base earlier would lose that
safety. A successful child exit alone is not a settled rewrite; parent result
handling must finish the manifest transition.

Manifest replacement writes and syncs a temporary file before rename. The
rename is atomic, but parent-directory fsync is missing. Preserve that limit
in operator-facing durability claims.

On failure, do not publish the new base. Try to remove its incomplete file and
keep the manifest and incrementals containing writes. If deletion fails,
startup reconciliation can remove the orphan later. Failed rollback can leave
rewrite state unsettled; resources needed by that state must stay open.

## Trigger a rewrite

Only one rewrite can run. With default exclusivity, a manual BGREWRITEAOF
blocked by a save records one pending rewrite. Repeated pending requests
coalesce. A failed start keeps it pending. An active rewrite remains an error,
and AOF must be enabled before scheduling is possible.

Automatic rewriting is an immediate attempt, outside the manual queue. By
default, it requires at least 67,108,864 bytes of AOF and incremental growth
of at least 100% of base size. Before any base exists, only the minimum-size
check applies. A percentage of zero disables automatic attempts while leaving
the manual command available. A failed rewrite delays automatic retry by
60 seconds.

With `exclusive-bg-persistence no`, one save and one rewrite can overlap.
Separate children increase copy-on-write memory pressure. The claims and
pending-work design are in [persistence lifecycle](persistence.md).

## Write failures

A preparation failure stops the mutation. A storage failure aborts its prepared
record. Neither publishes the failed change.

A flush or sync can fail after mutation and publication. Memory and the buffer
then contain the change, but disk state is uncertain. `abort()` on an already
published record does nothing. Keep that record for retry.

During a client command, the handler logs the source failure and sends
`ERR something went wrong` if output is safe, then closes. The reply does not
prove rollback or confirmed durability.

The journal records a failed flush. New preparations then return
`JournalWriteBlocked`, preventing further mutations. Cron retries flushing.
A successful flush clears the failed state and permits writes again.

## Shutdown

Use the shared [shutdown order](persistence.md#shutdown-order). Settle rewrite
completion before final journal flush and sync. A failed rewrite is reported
as `AofRewriteFailed` even if rollback succeeds. Do not report a cached failure
a second time after cron already reported it.

The live AOF file closes after rewrite state is settled and the final flush is
attempted. If the rewrite cannot settle, retain the resources it needs and
return a shutdown error. Other errors allow remaining safe cleanup, with the
first useful error retained.

## Verify a change

Run `zig build test` and `zig build test-integration`. The
[AOF tests](../../src/persistence/aof_tests.zig) cover journal and rewrite state.
[Process suites](../../tests/integration/suites) cover replay, tail repair,
restart, active-child stops, failures, and final flushing. Check restored data,
manifest contents, and process result together.

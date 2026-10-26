# Persistence and shutdown

[Documentation](../README.md) / Persistence

kgcache offers `.kgc` snapshots and an optional append-only file (AOF).
Both keep data across restarts, with different crash-loss tradeoffs.
Neither is replication or a backup service.

| Mode | Startup source | Normal writes | Clean SIGINT/SIGTERM stop |
| --- | --- | --- | --- |
| Native defaults | Snapshot if present | Memory; periodic saves off | Save dirty data because `shutdown-save yes` |
| Snapshot with save rules | Snapshot if present | Memory, plus full snapshots when rules match | Save remaining dirty data |
| AOF | Manifest and AOF files, instead of snapshot | Append write records with the selected fsync policy | Settle children, then flush; sync for `always`/`everysec` |
| Disposable cache | Existing snapshot still loads if present | Memory | No automatic save with `shutdown-save no` |

The published image and Compose example use AOF with `appendfsync everysec`.
The native executable defaults to AOF off. Use fresh storage for disposable
cache data. Turning persistence off does not delete existing files, and manual
SAVE/BGSAVE can still write snapshots.

## Snapshot setup

Create a data directory and put this in `kgcache.conf`:

```conf
dir ./data
dbfilename dump.kgc
appendonly no
save 60 1
shutdown-save yes
```

```sh
mkdir -p data
./zig-out/bin/kgcache kgcache.conf
```

A relative `dir` uses the server's working directory, not the config file's
directory. The directory must exist and be readable and writable by the
server identity. See [persistence paths](configuration.md#persistence-paths).

`SAVE` writes a full snapshot and blocks the caller until it finishes.
`BGSAVE` writes a snapshot in a child while the parent serves clients.
A completed snapshot covers the data captured for that save. Later writes
can be lost after a crash. The old complete snapshot stays in place until
a new snapshot is successfully published.

A `save <seconds> <changes>` rule starts BGSAVE once both thresholds match.
Multiple rules are allowed. Any matching rule can trigger a save. `save ""`
disables periodic saving. It does not disable manual saves or shutdown saves.
See [save settings](configuration.md#automatic-background-saving-save).

Snapshots use kgcache's own format. They cannot load Redis RDB data.
Changing paths does not move or convert existing files.

## AOF setup

Use a dedicated directory and these settings:

```conf
dir ./data
appendonly yes
appenddirname appendonlydir
appendfilename appendonly.aof
appendfsync everysec
```

kgcache creates the AOF subdirectory under the existing `dir`. It owns that
subdirectory and can remove AOF files absent from its manifest. Do not put
unrelated files there or share writable persistence directories between servers.

With AOF on, startup loads AOF instead of the snapshot. SAVE and BGSAVE can
still write snapshots. The log contains applied mutations, including absolute
expiration deadlines. BGREWRITEAOF compacts live data into a new base while
new writes continue in an incremental file. See [AOF settings](configuration.md#aof-settings)
for automatic rewrite and recovery controls.

### Fsync policies

Writing moves buffered bytes to OS memory. Fsync asks the OS to send them to
the storage device. A successful write alone does not prove power-loss safety.

| `appendfsync` | Normal behavior | Clean stop | Limit |
| --- | --- | --- | --- |
| `always` | Write and fsync before an applied write returns successfully | Final write and fsync | Depends on storage and filesystem honoring sync |
| `everysec` | Cron writes on ticks; fsync runs at most once per second | Final write and fsync | About one second is a normal target, not a hard loss bound |
| `no` | Cron writes on ticks and leaves sync to the OS | Final write without fsync | Machine failure can lose data not committed by the OS |

Cron delays, slow storage, I/O failure, and forced termination can widen loss.
An acknowledged write with `everysec` or `no` can still be in kgcache's buffer.
A process crash can lose that buffer. A clean stop must finish successfully
for its final flush guarantee to apply.

### Recovery and write errors

Startup replays the manifest's base, then its incremental files. With
`aof-load-truncated yes`, only an unfinished last command in the final
incremental file can be removed. Recovery truncates to the last successfully
executed command and logs a warning. Malformed commands, unfinished base/earlier
files, and resource errors stop startup and preserve the files. Set
`aof-load-truncated no` to reject an unfinished tail too. There is no checksum,
so some damaged lengths can look like an interrupted final write.

A failed AOF preparation prevents the mutation. A later flush/sync failure can
happen after memory and the journal buffer changed. The client then receives
a generic error and the connection closes. That response does not prove a
rollback. New writes are blocked while the journal is failed. Cron retries
flushing; a successful flush clears the blocked state.

## Shutdown and failure limits

SIGINT and SIGTERM request normal shutdown. The server stops accepting work
and stops cron. It shuts down client sockets to wake blocked reads/writes and
joins workers. It then drains tracked snapshot and rewrite children.

All child waits share `persistence-shutdown-grace-ms`, default 10000 ms,
starting after workers join. With AOF off and `shutdown-save yes`, remaining
dirty data needs a final snapshot within that same budget. A successful
existing save can remove that need. A required final save that fails or times
out makes the process exit with code 1. Shutdown does not retry it.

At budget expiry, kgcache signals remaining children with SIGKILL and allows
up to 1000 ms to reap them. Zero grace skips the wait and cannot start a
required final save. If a child remains unresolved, shutdown reports an error
and retains resources it still needs.

AOF rewrite completion is settled before the final journal flush and sync.
A failed rewrite keeps the manifest and incremental files containing writes;
its unfinished base is not published. Unsettled rewrite state prevents closing
the resources it still needs. Shutdown reports errors after safe cleanup.

This budget bounds child polling. It does not bound worker draining, disk
calls, or every cleanup step. Allow a longer outer supervisor timeout than the
child budget. The [service example](service.md#resource-limits-and-shutdown)
uses 30 seconds. SIGKILL, an OOM kill, power loss, or an outer timeout can stop
shutdown before data is saved.

Background persistence is experimental. Forked children can still encounter
inherited runtime locks. The parent reports ordinary child failures as generic
operation errors; it does not yet receive the child's source error or trace.
Snapshot and manifest replacement sync temporary file data, then rename.
Directory fsync is absent, so a power loss just after rename can still lose
the new directory entry. Successful fsync and a persistent volume do not
replace backups or storage failure testing.

## Verify and inspect

Use a separate copy of data for recovery experiments. Preserve failed files
before changing settings. [Container operation](service.md) covers permissions,
volume reuse, and service logs. PING/health checks show protocol response, not
durable storage.

[Automated persistence evidence](compatibility.md#automated-evidence) includes
snapshot/AOF restarts, recovery errors, shutdown saves, child deadlines, and
active persistence. The [developer persistence guide](../development/persistence.md)
explains lifecycle ownership, rewrite publication, and failure reporting.

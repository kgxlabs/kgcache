# Persistence

[Docs](../README.md) / [Operate](README.md) / Persistence

Choose how kgcache reloads data after a restart. Snapshots save the dataset
at a point in time. An append-only file (AOF) records changes and replays them
at startup. Both need writable storage that survives the process.

## Choose a mode

| Need | Settings | Restart source |
| --- | --- | --- |
| Keep snapshot data on a clean stop | `appendonly no`, `shutdown-save yes` | `.kgc` snapshot |
| Save snapshots during runtime too | Add one or more `save` rules | Last completed `.kgc` snapshot |
| Record changes between snapshots | `appendonly yes`, choose `appendfsync` | AOF manifest and its files |
| Disposable cache | Fresh storage, `appendonly no`, `save ""`, `shutdown-save no` | Empty unless a snapshot was explicitly saved |

Native defaults use AOF off, periodic saves off, and shutdown saves on. The
published image and Compose example use AOF with `appendfsync everysec`.

With AOF enabled, startup loads AOF instead of the snapshot. SAVE and BGSAVE
can still write snapshots. Turning automatic persistence off does not delete
old files or prevent manual saves. Use a fresh data directory when you need
an empty disposable cache.

## Use snapshots

Create `./data` and save these settings in your config:

```conf
dir ./data
dbfilename dump.kgc
appendonly no
save 60 1
shutdown-save yes
```

The rule requests a background save once at least 60 seconds and one change
have accumulated since the saved baseline. Any matching rule can trigger a
save when there are several rules. `save ""` disables periodic saves.

Use [SAVE](../commands/save.md) to write synchronously, or
[BGSAVE](../commands/bgsave.md) to request a background snapshot. A snapshot
captures all databases. Data written after its capture can be lost on a crash.
A failed replacement keeps the old complete snapshot.

Snapshots use kgcache's `.kgc` format. Redis RDB files cannot be loaded.
Changing a filename does not convert a data format.

## Use an append-only file

```conf
dir ./data
appendonly yes
appenddirname appendonlydir
appendfilename appendonly.aof
appendfsync everysec
```

Create `./data` first. kgcache creates the AOF subdirectory. Keep it dedicated
to this server: startup may remove AOF files absent from the manifest.
The manifest selects a base file and incremental files for replay. Preserve
the whole directory when copying AOF data.

### Choose an fsync policy

A write transfers bytes to OS memory. Fsync asks the OS to commit them to
storage. The policy controls when the server requests that sync:

| Policy | While running | On a successful clean stop |
| --- | --- | --- |
| `always` | Write and fsync before an applied write returns success | Final write and fsync |
| `everysec` | Cron writes buffered records and fsyncs at most once per second | Final write and fsync |
| `no` | Cron writes buffered records; the OS controls syncing | Final write without fsync |

With `everysec` or `no`, acknowledged writes can still be in kgcache's own
buffer. A process crash can lose those bytes. About one second is a normal
target for `everysec`, not a hard loss bound. Cron delays, slow storage, and
I/O errors can widen it.

### Rewrite a growing AOF

[BGREWRITEAOF](../commands/bgrewriteaof.md) creates a compact base while new
writes continue in an incremental file. Automatic rewriting uses
`auto-aof-rewrite-percentage` and `auto-aof-rewrite-min-size`. Set the percentage
to zero to disable automatic rewrites without disabling the manual command.

Keep `exclusive-bg-persistence yes` unless you have a reason to overlap
snapshot and rewrite children. Concurrent children can increase memory use.

### Recover an interrupted last write

With `aof-load-truncated yes`, startup can discard an incomplete last command
in the final incremental file. It truncates to the last successfully executed
command and logs a warning. An incomplete base or earlier incremental file,
a malformed command, or a resource error stops startup and preserves the files.
Set the option to `no` to reject the unfinished final tail too.

There is no checksum. Some damaged lengths can look like an interrupted tail.
Copy failed files before changing recovery settings.

## Stop and back up data

Use the clean-stop procedure in [Shutdown and restart](shutdown.md). After
the process exits successfully, copy the data directory to a new location
before testing recovery or upgrading across a data-format change. For a native
server that uses `dir ./data`, and a backup path that does not already exist:

```sh
cp -R ./data ./data.backup
```

For a container, retain and back up its volume through your storage tooling.
Do not copy a live AOF directory file by file while rewrites can change its
manifest. A volume that you reuse at restart is not a separate backup.

## Durability and failure limits

A required shutdown save or flush must finish successfully for its guarantee
to apply. Forced termination can interrupt it. Directory fsync after snapshot
and manifest replacement is absent, so power loss can lose a new directory
entry even after file data was synced.

Background persistence is experimental. Forked children can encounter inherited
runtime locks, and their original source errors are not yet reported to the
parent. The parent reports generic operation failures. See
[shutdown limits](shutdown.md#shutdown-limits) and the
[internal persistence design](../contribute/persistence.md) for the exact boundary.

An AOF preparation error prevents its mutation. A later flush or sync failure
can follow an applied mutation. The client receives a generic error and the
connection closes. New writes are blocked while the journal is failed; cron
retries flushing, and a successful flush clears that state. A write error
does not prove a rollback.

For the complete settings, use the
[configuration reference](../reference/configuration.md#persistence).
Automated restart and recovery coverage is linked from
[Compatibility](../reference/compatibility.md#automated-coverage).

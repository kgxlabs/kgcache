# Append-only file (AOF)

The append-only file keeps a record of each write. On restart, kgcache
replays that record to rebuild the data in memory.

Use AOF when losing all writes since the last snapshot would be a problem.
Snapshots and AOF can both be enabled, but they have different jobs:

| Method | What it stores | Main trade-off |
| --- | --- | --- |
| Snapshot | A full copy of the data at one point in time | Simple and compact, but newer writes are not in it |
| AOF | Each write command, in order | Keeps newer writes, but the log grows until it is rewritten |

When `appendonly yes` is set, startup uses AOF and does not load
`dump.kgc`. `SAVE` and `BGSAVE` still work and still write snapshots.

## Turn AOF on

Add this to `kgcache.conf`:

```text
appendonly yes
appendfsync everysec
```

`everysec` is the default and is the best choice for most uses. See
[AOF settings](CONFIGURATION.md#aof-settings) for every AOF option.

## Write and fsync are different

AOF data moves through two stages:

```text
kgcache buffer
      |
      | write
      v
OS memory
      |
      | fsync, or a later OS write
      v
storage device
```

`write` moves data out of kgcache and into OS memory. That data usually
survives a kgcache process crash, but it may be lost if the machine loses
power.

`fsync` asks the OS to push the data to the storage device before returning.
It gives stronger safety, but it is slower.

### Fsync policies

| Policy | During normal use | What may be lost |
| --- | --- | --- |
| `always` | Write and fsync before the write command returns `OK` | No acknowledged write under normal storage behavior |
| `everysec` | Cron writes buffered commands on each tick and fsyncs at most once per second | Up to about one second after power loss |
| `no` | Cron writes buffered commands, but kgcache never asks for fsync | Whatever the OS has not written before power loss |

All three policies write buffered commands regularly. `no` does not mean
"keep the data only in kgcache memory." It means "let the OS decide when to
write it to the storage device."

On a clean shutdown:

- `always` and `everysec` finish with an fsync.
- `no` writes pending commands and closes the file without fsync.

SIGINT and SIGTERM do not yet run the clean shutdown path. The accept loop
must first gain a safe way to wake up and drain connection threads.

## Files on disk

After the first rewrite, the default directory looks like this:

```text
appendonlydir/
|-- appendonly.aof.1.base
|-- appendonly.aof.2.incr
`-- appendonly.aof.manifest
```

- A `base` file describes the current data as a short list of commands.
- An `incr` file holds writes made after that base was created.
- The manifest lists the files that belong to the current AOF.

Before the first rewrite, there is no base file. The manifest points to the
first incremental file.

Do not place unrelated files in this directory. At startup, kgcache removes
AOF data files that are not listed in the manifest.

## What is written

AOF files use RESP commands, the same command format clients send:

```text
SELECT 2
SET session:42 active PXAT 1788500000000
DEL old-key
```

Using commands keeps loading simple: kgcache reads each command and runs it
through the normal command path.

Expiry times use the absolute `PXAT` form. A relative timeout such as
`PX 5000` would start a new five-second timer on every restart. An absolute
time keeps the original expiry time.

## Startup

With `appendonly yes`, startup follows this order:

```text
read manifest
      |
      v
replay base file
      |
      v
replay incremental files in order
      |
      v
remove old AOF files not listed in the manifest
      |
      v
start serving requests
```

If the final incremental file ends with half of a command,
`aof-load-truncated yes` removes that incomplete command and continues.
An incomplete base file or an earlier incremental file is always an error.
Set `aof-load-truncated no` to make an incomplete final command an error too.

## Rewrite

The AOF grows with every write, even when many writes replace the same key.
A rewrite makes a smaller base file from the data that is still live.

Run one by hand:

```console
127.0.0.1:6379> BGREWRITEAOF
OK
```

The command returns after the background child starts. The child writes the
new base while the parent keeps serving requests.

Before forking, the parent opens a new incremental file and updates the
manifest:

```text
old base + old incr files
            |
            | open and publish new incr
            v
new client writes go to new incr
            |
            | fork
            v
child writes new base
            |
            | child succeeds
            v
manifest switches to new base + new incr
            |
            v
old files are removed
```

Publishing the new incremental file before the fork matters. If the rewrite
fails or the server stops, the manifest still names every file that contains
new writes.

The manifest is replaced by writing and syncing a temporary file, then
renaming it. The rename itself is atomic. The current Zig file API does not
provide directory fsync here, so a power loss just after the rename still
has a small risk of leaving the old directory entry.

## Automatic rewrite

The default settings start a rewrite when both are true:

1. The total AOF size is at least 67,108,864 bytes.
2. Incremental data has grown to at least 100% of the base size.

Before the first base exists, only the minimum size check is used.

Set this to disable automatic rewrites:

```text
auto-aof-rewrite-percentage 0
```

`BGREWRITEAOF` still works when automatic rewriting is off. After a failed
rewrite, kgcache waits 60 seconds before trying another automatic rewrite.

## Write failures

If an AOF write or fsync fails, kgcache records the failure. New client
writes then fail instead of being accepted without a working journal.

Cron keeps trying to flush. A later successful flush clears the failure, so
the server can recover after a short problem such as a full disk that was
cleaned up.

Only one AOF rewrite can run at a time. By default, an AOF rewrite and
`BGSAVE` also cannot run at the same time. See
[`exclusive-bg-persistence`](CONFIGURATION.md#exclusive-bg-persistence-recommendation).

# SAVE

[Commands](README.md) / SAVE

Write a snapshot of all databases and wait for it to finish.

## Syntax

```text
SAVE
```

## Examples

```console
127.0.0.1:6379> SET example:saved hello
OK
127.0.0.1:6379> SAVE
OK
```

## Behavior

SAVE writes kgcache's `.kgc` format to the path chosen by `dir` and `dbfilename`.
It saves every database, regardless of the caller's SELECT setting. The caller
waits for completion, and storage work may wait while the snapshot is written.

Only one save can run at a time. SAVE returns `ERR save already in progress`
if another save owns the save claim. An exclusive active AOF rewrite can also
prevent a synchronous save. Use [BGSAVE](bgsave.md) to request background work.

SAVE remains available when periodic saving is off and when AOF is enabled.
With AOF enabled, startup still loads AOF rather than this snapshot.

A completed save has [filesystem and power-loss limits](../operate/persistence.md).
It is not a Redis RDB file or a guarantee that every later write survives a crash.

## Return information

RESP2 and RESP3 both return the simple string `OK` after a successful save.
A failure returns an error.

## Related commands

[BGSAVE](bgsave.md), [BGREWRITEAOF](bgrewriteaof.md).

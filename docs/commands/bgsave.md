# BGSAVE

[Commands](README.md) / BGSAVE

Start or schedule a snapshot without waiting for its disk write to finish.

## Syntax

```text
BGSAVE [SCHEDULE]
```

## Examples

```sh
redis-cli BGSAVE
```

When no save or conflicting rewrite is active, this returns
`Background saving started`. This reply confirms that work started, not that
the snapshot finished successfully. Inspect server logs for later failures.

## Behavior

BGSAVE captures all databases, then writes a snapshot in a child process. The
parent can serve later commands while the child writes. Capturing the data and
starting the child can still pause other work.

With `exclusive-bg-persistence yes`, an active AOF rewrite makes BGSAVE record
one pending save. It returns `Background saving scheduled`, and cron starts
that save after the rewrite finishes. Repeated pending requests coalesce into
that one save. A save already running returns `ERR save already in progress`.

The optional SCHEDULE token is case-insensitive. In kgcache, bare BGSAVE and
BGSAVE SCHEDULE have the same scheduling behavior. This differs from Redis.
Another option is a syntax error. Extra arguments are an argument-count error.

With `exclusive-bg-persistence no`, one save and one rewrite may overlap.
There can still be only one save at a time.

Read [persistence](../operate/persistence.md) for file paths, recovery, and
shutdown guarantees. Background persistence remains experimental.

## Return information

RESP2 and RESP3 both return one simple string:

- `Background saving started` when a child starts.
- `Background saving scheduled` when a pending save is recorded.

A later child failure does not change the reply already sent to the client.

## Related commands

[SAVE](save.md), [BGREWRITEAOF](bgrewriteaof.md).

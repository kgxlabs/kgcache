# BGREWRITEAOF

[Commands](README.md) / BGREWRITEAOF

Start or schedule a compact base file for the append-only log.

## Syntax

```text
BGREWRITEAOF
```

## Examples

With `appendonly yes` in the server configuration:

```sh
redis-cli BGREWRITEAOF
```

When no conflicting operation is active, this returns
`Background append only file rewriting started`. The work finishes later.

## Behavior

The rewrite captures live data in a background child. New writes continue in an
incremental file. On successful completion, the parent publishes a manifest
that selects the new base and the live incremental data.

With `exclusive-bg-persistence yes`, an active save makes this command record
one pending rewrite. Cron starts it after the save finishes. Repeated pending
requests coalesce. With `exclusive-bg-persistence no`, one save and one rewrite
may overlap.

AOF must be enabled. Otherwise the reply is `ERR AOF is disabled`. An active
rewrite returns `ERR rewrite already in progress`. Arguments are not accepted.

A started or scheduled reply does not prove the rewrite completed. Inspect
server logs for its result. A failed rewrite does not publish its unfinished
base. Read [persistence](../operate/persistence.md) for recovery and failure limits.

## Return information

RESP2 and RESP3 both return one simple string:

- `Background append only file rewriting started` when a child starts.
- `Background append only file rewriting scheduled` when a pending rewrite is recorded.

## Related commands

[BGSAVE](bgsave.md), [SAVE](save.md).

# CLIENT LIST

[Commands](README.md) / CLIENT LIST

List the server's live connections.

## Syntax

```text
CLIENT LIST
```

## Examples

```sh
redis-cli CLIENT LIST
redis-cli -3 CLIENT LIST
```

The reply includes the connection running the command. Keep another redis-cli
session open to see more than one row. Row values change as connections perform
work or disconnect.

## Behavior

Each row contains the [22 CLIENT INFO fields](client-info.md#fields). Rows are
sorted by ascending connection ID. LIST has no filters. Arguments such as
`ID` or `TYPE` return `ERR wrong number of arguments`.

Each row describes one connection at its capture time. The rows do not form
one simultaneous snapshot of every connection. A connection can close after
its row is captured and still appear in that response. Finished connections
are excluded even if their records have not yet been removed.

The caller's row includes LIST's own dispatch as `cmd=client|list`. It includes
the request bytes and excludes the current response bytes. Other rows show
their most recently published state. The
[CLIENT INFO counter rules](client-info.md#counter-timing) apply to each row.

## Return information

RESP2 returns one bulk string. RESP3 returns one `txt:` verbatim string.
The text contains one row per live connection, with a trailing LF on each row.

## Related commands

[CLIENT INFO](client-info.md), [CLIENT SETINFO](client-setinfo.md).

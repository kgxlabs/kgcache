# SELECT

[Commands](README.md) / SELECT

Choose the logical database used by this connection.

## Syntax

```text
SELECT index
```

## Examples

Use one interactive session so both commands run on the same connection:

```console
127.0.0.1:6379> SELECT 1
OK
127.0.0.1:6379[1]> SET example:message hello
OK
127.0.0.1:6379[1]> SELECT 0
OK
```

## Behavior

New connections start in database 0. The index must be an unsigned decimal
integer smaller than the configured `databases` count. The default count is
16, so the default valid range is 0 through 15.

The selection belongs to the connection. It does not affect another connection,
and a new connection does not inherit the previous selection. Client libraries
can select a database during setup; see the [client guides](../develop/README.md).
HELLO protocol switches preserve the selection.

A rejected SELECT leaves the previous database selected. A malformed integer
returns `ERR malformed command request`. An index outside the configured range
returns `ERR DB index is out of range`.

## Return information

RESP2 and RESP3 both return the simple string `OK` after a successful selection.

## Related commands

[GET](get.md), [SET](set.md), [DBSIZE](dbsize.md), [HELLO](hello.md).

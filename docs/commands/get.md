# GET

[Commands](README.md) / GET

Read a string value from the selected database.

## Syntax

```text
GET key
```

## Examples

```console
127.0.0.1:6379> SET example:message hello
OK
127.0.0.1:6379> GET example:message
"hello"
127.0.0.1:6379> DEL example:message
(integer) 1
127.0.0.1:6379> GET example:message
(nil)
```

## Behavior

GET returns the stored bytes. Empty values are valid and differ from a missing
key. An expired key behaves as absent and is removed when GET reads it.

The connection's [SELECT](select.md) setting determines which database is read.
GET takes exactly one key. Use separate commands, or a pipeline, for more keys.
`MGET` is unsupported.

## Return information

| Result | RESP2 | RESP3 |
| --- | --- | --- |
| Existing value | Bulk string | Blob string |
| Missing or expired key | Null bulk string, `$-1\r\n` | Null, `_\r\n` |

Client libraries turn these replies into native values. For example, go-redis
returns `redis.Nil` for a missing GET, and node-redis returns JavaScript `null`.

## Related commands

[SET](set.md), [DEL](del.md), [SELECT](select.md).

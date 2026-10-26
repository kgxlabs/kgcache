# PING

[Commands](README.md) / PING

Check that the server can answer on this connection.

## Syntax

```text
PING [message]
```

## Examples

```console
127.0.0.1:6379> PING
PONG
127.0.0.1:6379> PING hello
"hello"
```

## Behavior

Without an argument, PING returns `PONG`. With one argument, it returns the
argument's exact bytes. More than one argument is an error.

A successful PING checks basic protocol response. It does not check persistence,
data integrity, or available memory. Use the server's health command for a
bounded process probe.

## Return information

| Request | RESP2 | RESP3 |
| --- | --- | --- |
| `PING` | Simple string `PONG` | Simple string `PONG` |
| `PING message` | Bulk string containing `message` | Blob string containing `message` |

## Related commands

[ECHO](echo.md), [HELLO](hello.md), [CLIENT INFO](client-info.md).

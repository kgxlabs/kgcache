# ECHO

[Commands](README.md) / ECHO

Return a message without changing it.

## Syntax

```text
ECHO message
```

## Examples

```console
127.0.0.1:6379> ECHO "hello world"
"hello world"
127.0.0.1:6379> ECHO ""
""
```

## Behavior

The message is one bulk-string argument. It may be empty or contain binary
data. The server returns its bytes without treating them as a command or key.
Missing or extra arguments are errors.

## Return information

RESP2 returns a bulk string. RESP3 returns a blob string. Both use the same
`$length\r\n...\r\n` wire form for this reply.

## Related commands

[PING](ping.md), [GET](get.md).

# CLIENT INFO

[Commands](README.md) / CLIENT INFO

Inspect the connection that sent the command.

## Syntax

```text
CLIENT INFO
```

## Examples

```sh
redis-cli CLIENT INFO
redis-cli -3 CLIENT INFO
```

Each command reports its own connection. Look for `db=0`, `resp=2` or `resp=3`,
and `cmd=client|info`. IDs, addresses, ages, labels, and counters vary by session.
To inspect a connection after changing its settings, run CLIENT INFO within
that connection's interactive session.

## Fields

The reply has exactly these 22 fields, in this order:

| Field | Meaning |
| --- | --- |
| `id` | Positive connection ID, not reused during this server run. |
| `addr` | Peer address and port. |
| `laddr` | Local address and port. |
| `fd` | Socket file descriptor. |
| `age` | Whole seconds since registration. |
| `idle` | Whole seconds since the last successful positive read or write. |
| `db` | Selected database index. |
| `cmd` | Last registered, argument-count-valid command dispatched. |
| `resp` | Reply protocol, 2 or 3. |
| `lib-name` | Library name set through CLIENT SETINFO, initially empty. |
| `lib-ver` | Library version set through CLIENT SETINFO, initially empty. |
| `tot-net-in` | Bytes successfully received on the connection. |
| `tot-net-out` | Bytes successfully sent on the connection. |
| `tot-cmds` | Registered, argument-count-valid commands dispatched. |
| `name` | Empty. Connection naming is unsupported. |
| `sub` | `0`. Pub/sub is unsupported. |
| `psub` | `0`. Pattern subscriptions are unsupported. |
| `ssub` | `0`. Sharded subscriptions are unsupported. |
| `watch` | `0`. WATCH is unsupported. |
| `multi` | `-1`. Transactions are unsupported. |
| `multi-mem` | `0`. Transactions are unsupported. |
| `redir` | `-1`. Tracking redirection is unsupported. |

IPv6 endpoints use `[address]:port`. Age and idle use monotonic time. Negative
durations are clamped to zero. Byte and command counters stop increasing at
`18446744073709551615`, the maximum unsigned 64-bit value.

## Counter timing

Incoming bytes are counted before dispatch. They may include later commands
already received in the same pipeline. Outgoing bytes count actual successful
writes, including a prefix sent before a later write failure.

CLIENT INFO counts its own dispatch and received bytes. Its current reply bytes
have not yet been sent, so they are excluded from `tot-net-out`.

`cmd` uses names such as `get`, `hello`, and `client|info`. A recognized handler
counts even if it returns an option or value-validation error. Unknown commands,
wrong argument counts, unsupported CLIENT subcommands, and malformed or
incomplete requests do not update `cmd` or `tot-cmds`.

A successful SELECT or HELLO is visible to the next CLIENT INFO in a pipeline.
A rejected change preserves the prior database or protocol. Library labels
reflect successful SETINFO calls on the same connection.

## Return information

RESP2 returns one bulk string. RESP3 returns one `txt:` verbatim string.
The text contains space-separated `field=value` tokens and a trailing LF.

No extra fields are implied by Redis's CLIENT INFO output. Further diagnostics
are tracked in [#179](https://github.com/kgxlabs/kgcache/issues/179).
Additional arguments return `ERR wrong number of arguments`.

## Related commands

[CLIENT LIST](client-list.md), [CLIENT SETINFO](client-setinfo.md),
[HELLO](hello.md), [SELECT](select.md).

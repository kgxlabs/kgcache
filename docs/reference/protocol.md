# Protocol specification

[Docs](../README.md) / [Reference](README.md) / Protocol

kgcache accepts Redis-style commands over TCP. Connections begin in RESP2.
HELLO can select RESP2 or RESP3 replies for the supported command set.

## Command requests

Both modes accept the same request grammar: a nonempty, flat RESP array of
non-null bulk strings. The first element is the command name. The rest are
its arguments. Names and option tokens are case-insensitive unless a command
documents otherwise. Keys and values retain their exact bytes.

For example, these escaped bytes encode `GET greeting`:

```text
*2\r\n$3\r\nGET\r\n$8\r\ngreeting\r\n
```

The example displays CRLF as `\r\n` for readability. On the wire they are
actual carriage-return and line-feed bytes. Inline commands, nested request
arrays, null arguments, and general RESP3 request values are unsupported.

## Select a reply mode

[HELLO](../commands/hello.md) without a version reports the current mode.
`HELLO 2` selects RESP2; `HELLO 3` selects RESP3. The selected mode applies to
HELLO's own reply and later commands, including the next command in a pipeline.
Switching preserves the selected database. Rejected HELLO forms leave the
connection's previous mode intact. Repeated switches are allowed.

## Reply types

| Meaning | RESP2 | RESP3 |
| --- | --- | --- |
| Simple string | `+text\r\n` | Same |
| Simple error | `-ERR text\r\n` or the command's error class | Same |
| Integer | `:number\r\n` | Same |
| Blob string | `$length\r\nbytes\r\n` | Same |
| Missing string or SET null result | `$-1\r\n` | `_\r\n` |
| Unknown COMMAND INFO entry | `*-1\r\n` | `_\r\n` |
| Array | `*count\r\n` followed by elements | Same |
| HELLO metadata | Flat key/value array | `%count\r\n` followed by key/value pairs |
| CLIENT INFO/LIST text | Bulk string | `=length\r\ntxt:body\r\n` |

Lengths count bytes. The RESP3 text-report length includes the four bytes
`txt:`. Array counts count elements; map counts count key/value pairs.

RESP3 support is limited to these command replies. Booleans, doubles, big
numbers, sets, blob errors, attributes, pushes, other verbatim formats,
and streamed strings or aggregates are unsupported.

GET of an absent or expired key returns the missing-string form. SET without
GET returns `OK` when applied and null when NX/XX rejects it. SET with GET
returns the previous value or null whether the write applies or is rejected.
See each [command page](../commands/README.md) for its exact return rules.

## Request limits

| Limit | Value |
| --- | --- |
| Encoded command bytes | 1,048,576 bytes (1 MiB) |
| Array elements | 1,024, including the command name |
| Default initial input buffer | 1,024 bytes |

The byte limit includes RESP headers, names, bodies, and endings. Limits
apply to each command, not the total pipeline. The input buffer grows to
the cap and retains its capacity until the connection ends. Setting
`connection-buffer-size` above the cap is accepted but its initial allocation
is clamped; the request limit does not change.

Declared lengths or counts above a limit are rejected before waiting for
the payload. The server sends
`-ERR protocol error: request limit exceeded\r\n` when possible, then closes.
Earlier replies and mutations remain valid. Buffer growth can briefly retain
both the old and new buffers. Reply buffers and dataset memory are separate costs.

## Transport behavior

Requests may span reads, and one read may contain several requests. The
server executes a complete pipeline prefix before waiting for an unfinished
tail. It executes complete commands in order and returns replies in that order.
At EOF, an otherwise valid incomplete request is discarded without execution.

A command validation error usually permits later requests. Malformed RESP
receives one protocol error when possible and ends the session. A reply write
or flush failure ends the session without adding an error to partial output
or executing later commands. Peer resets and broken pipes close quietly.

Each reply finishes before the next command begins on that connection.
A slow reader can block its worker while socket output waits for space.
A successful local write does not prove the peer read the bytes. A disconnect
does not undo earlier applied writes. Shutdown wakes blocked socket reads
and writes before joining workers.

See [Pipelines](../develop/pipelining.md) for client APIs and
[Compatibility](compatibility.md#automated-coverage) for wire and process tests.

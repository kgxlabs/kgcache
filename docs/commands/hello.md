# HELLO

[Commands](README.md) / HELLO

Select the connection's reply protocol and read server metadata.

## Syntax

```text
HELLO [2 | 3]
```

## Examples

Ask redis-cli to connect with RESP3, then inspect the metadata:

```sh
redis-cli -3 HELLO 3
```

The reply includes `server` with value `kgcache` and `proto` with value `3`.
The version and connection ID depend on the running server.

To switch an existing connection, enter `HELLO 2` or `HELLO 3` inside its
interactive redis-cli session. Use bare `HELLO` to inspect its current mode.

## Behavior

Every new TCP connection starts in RESP2. HELLO 2 selects RESP2. HELLO 3 selects
RESP3. The selected mode applies to HELLO's own reply and all later replies on
that connection. A connection may switch repeatedly, including in a pipeline.

Bare HELLO reports the current mode without changing it. Switching protocols
preserves the selected database and library labels.

kgcache does not accept HELLO AUTH or SETNAME options. Leave credentials and
connection names unset in client settings.

| Rejected request | Error |
| --- | --- |
| Version is not a valid signed 64-bit integer | `ERR malformed command request` |
| Integer version is neither 2 nor 3 | `NOPROTO unsupported protocol version` |
| Supported version followed by extra arguments | `ERR unsupported option` |

Validation checks the version before additional arguments. A rejected request
preserves the current protocol and leaves the connection usable.

## Return information

The reply contains these seven fields, in this order:

| Field | Value |
| --- | --- |
| `server` | `kgcache` |
| `version` | The effective version of the running build. |
| `proto` | The selected protocol, 2 or 3. |
| `id` | The connection's positive integer ID. |
| `mode` | `standalone` |
| `role` | `master` |
| `modules` | Empty array. |

RESP2 returns a flat key/value array. RESP3 returns a map. Connection IDs are
not reused during one server run. They may restart after the server restarts.

The protocol reference describes the
[supported reply types](../reference/protocol.md).

## Related commands

[CLIENT INFO](client-info.md), [SELECT](select.md), [PING](ping.md).

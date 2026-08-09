# Commands

| Command | Behavior |
| --- | --- |
| `PING` | Returns `PONG`. Arguments are currently ignored. |
| `ECHO <message>` | Returns one non-null bulk-string argument. |
| `GET <key>` | Returns a bulk string, or a null bulk string when the key is absent or expired. |
| `SET <key> <value> [options]` | Stores a string value and returns `OK`, unless `GET` requests a value response. |
| `SELECT <index>` | Switches the connection's active database. Returns an error if `index` is out of range. |
| `DBSIZE` | Returns the number of stored keys as an RESP integer. |
| `SAVE` | Writes a `.kgc` snapshot of all databases to disk (see [Configuration](CONFIGURATION.md) for `snapshot-path`). Returns an error if the write fails. |
| `COMMAND <value>` | Placeholder command that returns its first argument; Redis command introspection is not implemented. |

Command names are case-insensitive.

## `SET` options

`SET` recognizes the following option families:

| Family | Options |
| --- | --- |
| Conditional writes | `NX`, `XX` |
| Relative expiration | `EX <seconds>`, `PX <milliseconds>` |
| Absolute expiration | `EXAT <unix-seconds>`, `PXAT <unix-milliseconds>` |
| TTL handling | `KEEPTTL` |
| Response | `GET` |

Expiration records are maintained separately from key/value entries, with an O(1) index for updates and removal. Expired values are removed when read.

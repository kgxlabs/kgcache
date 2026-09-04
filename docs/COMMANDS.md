# Commands

| Command | Behavior |
| --- | --- |
| `PING` | Returns `PONG`. Arguments are currently ignored. |
| `ECHO <message>` | Returns one non-null bulk-string argument. |
| `GET <key>` | Returns a bulk string, or a null bulk string when the key is absent or expired. |
| `SET <key> <value> [options]` | Stores a string value and returns `OK`, unless `GET` requests a value response. |
| `SELECT <index>` | Switches the connection's active database. Returns an error if `index` is out of range. |
| `DBSIZE` | Returns the number of stored keys as an RESP integer. |
| `SAVE` | Writes a `.kgc` snapshot of all databases to disk (see [Configuration](CONFIGURATION.md) for `snapshot-path`), and blocks the calling connection until the write finishes. Returns an error if the write fails or a save is already in progress. |
| `BGSAVE` | Same snapshot as `SAVE`, but returns `OK` immediately and does the actual write in a forked background process, so the connection that issued it isn't blocked. Returns an error immediately, without forking, if a save is already in progress. Also triggered automatically by the background housekeeping loop when a configured `save` rule is met — see [Configuration](CONFIGURATION.md#automatic-background-saving-save). See [Snapshots](SNAPSHOTS.md#background-saving-bgsave) for how this works and what it guards against. |
| `BGREWRITEAOF` | Starts an AOF rewrite in a forked background process and returns `OK`. Returns an error if AOF is off, another rewrite is running, or the rewrite cannot start. See [Append-only file](AOF.md#rewrite). |
| `COMMAND <value>` | Placeholder command that returns its first argument; Redis command introspection is not implemented. |

Command names are case-insensitive.

`SAVE` and `BGSAVE` share one "a save is already running" guard. Only one
can write a snapshot at a time. By default, `BGSAVE` and `BGREWRITEAOF`
also cannot run at the same time.

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

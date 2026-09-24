# Commands

This reference describes the currently implemented command subset. Full Redis compatibility is a development goal; support for RESP2 does not imply that all Redis clients or workloads are supported. Known command deviations are recorded below. For connection behavior and other server limitations, see [Current status and compatibility](../README.md#current-status-and-compatibility).

| Command | Behavior |
| --- | --- |
| `PING [message]` | Returns `PONG` without an argument, or returns one non-null bulk-string argument unchanged. |
| `ECHO <message>` | Returns one non-null bulk-string argument. |
| `GET <key>` | Returns a bulk string, or a null bulk string when the key is absent or expired. |
| `SET <key> <value> [options]` | Stores a string value. Without `GET`, returns `OK` when the write applies and a null bulk string when `NX` or `XX` rejects it. With `GET`, returns the previous value or a null bulk string when no value existed. |
| `DEL <key> [key ...]` | Removes the given keys and returns the number of keys that existed and were removed. |
| `SELECT <index>` | Switches the connection's active database. Returns an error if `index` is out of range. |
| `DBSIZE` | Returns the number of stored keys as an RESP integer. |
| `SAVE` | Writes a `.kgc` snapshot of all databases to disk (see [Configuration](CONFIGURATION.md) for `snapshot-path`), and blocks the calling connection until the write finishes. Returns an error if the write fails or a save is already in progress. |
| `BGSAVE [SCHEDULE]` | Starts a background snapshot and returns `Background saving started`. The optional `SCHEDULE` token is case-insensitive. Both forms return `Background saving scheduled` when an AOF rewrite is active and background persistence is exclusive. The save starts after the rewrite finishes. An active save is still an error. See [Snapshots](SNAPSHOTS.md#background-saving-bgsave). |
| `BGREWRITEAOF` | Starts an AOF rewrite and returns `Background append only file rewriting started`. It returns `Background append only file rewriting scheduled` when a save is active and background persistence is exclusive. The rewrite starts after the save finishes. AOF being off or an active rewrite remains an error. See [Append-only file](AOF.md#rewrite). |
| `COMMAND <value>` | Placeholder command that returns its first argument; Redis command introspection is not implemented. |

Command names are case-insensitive.

`SAVE` and `BGSAVE` share one "a save is already running" guard, and only one
AOF rewrite can run at a time. With the default `exclusive-bg-persistence yes`,
a manual `BGSAVE` or `BGREWRITEAOF` is scheduled when the other kind is active.
One pending request is remembered, and repeated requests of that kind coalesce
into it. The scheduled work starts after the active operation finishes.
With `exclusive-bg-persistence no`, one save and one rewrite may overlap.

Unlike Redis, kgcache gives bare `BGSAVE` the same scheduling behavior as
`BGSAVE SCHEDULE`. During an AOF rewrite, either form schedules the save when
background persistence is exclusive.

## `SET` options

`SET` recognizes the following option families:

| Family | Options |
| --- | --- |
| Conditional writes | `NX`, `XX` |
| Relative expiration | `EX <seconds>`, `PX <milliseconds>` |
| Absolute expiration | `EXAT <unix-seconds>`, `PXAT <unix-milliseconds>` |
| TTL handling | `KEEPTTL` |
| Response | `GET` |

`NX` applies the write only when the key does not exist. `XX` applies it only
when the key exists. When either condition rejects the write, the current value
and its expiration remain unchanged.

Without `GET`, a rejected conditional write returns a null bulk string. `GET`
changes the response to the value that existed before the command, or a null
bulk string when the key did not exist. This is true whether the conditional
write applies or is rejected.

Expiration records are maintained separately from key/value entries, with an O(1) index for updates and removal. Expired values are removed when read.

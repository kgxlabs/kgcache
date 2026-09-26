# Commands

This reference covers the commands currently implemented by kgcache. Command
names and subcommand names are case-insensitive. kgcache supports a subset of
Redis commands over RESP2, but full Redis compatibility is still a development
goal. For connection behavior and other server limitations, see
[Current status and compatibility](../README.md#current-status-and-compatibility).

The commands below start with connection and database selection, move through
key operations, then cover persistence and command introspection.

## `PING`

`PING [message]`

Returns the simple string `PONG` without an argument. With one non-null bulk
string argument, returns that message as a bulk string.

## `ECHO`

`ECHO <message>`

Returns the non-null bulk string argument unchanged.

## `SELECT`

`SELECT <index>`

Switches the connection to the database at `index` and returns `OK`. The index
must be within the configured database range. Subsequent key commands on that
connection use the selected database.

## `SET`

`SET <key> <value> [options]`

Stores a string value in the selected database. Without `GET`, returns `OK`
when the write applies, or a null bulk string when `NX` or `XX` rejects it.
With `GET`, returns the previous value, or a null bulk string if no value
existed, whether the write applies or is rejected.

| Family | Options |
| --- | --- |
| Conditional writes | `NX`, `XX` |
| Relative expiration | `EX <seconds>`, `PX <milliseconds>` |
| Absolute expiration | `EXAT <unix-seconds>`, `PXAT <unix-milliseconds>` |
| TTL handling | `KEEPTTL` |
| Response | `GET` |

`NX` applies the write only when the key does not exist. `XX` applies it only
when the key exists. A rejected write leaves the current value and its
expiration unchanged. `GET` changes the response to the value that existed
before the command.

Only one conditional option, one expiration or TTL option, and one response
option can be used in a single `SET` command. Expired values are removed when
read. See [Expiration](EXPIRATION.md) for the current expiration behavior.

## `GET`

`GET <key>`

Returns the string value as a bulk string. Returns a null bulk string when the
key is absent or expired.

## `DEL`

`DEL <key> [key ...]`

Removes the given keys from the selected database. Returns the number of keys
that existed and were removed as an integer.

## `DBSIZE`

`DBSIZE`

Returns the number of stored keys in the selected database as an integer.

## `SAVE`

`SAVE`

Writes a `.kgc` snapshot of all databases to disk and blocks the calling
connection until the write finishes. Returns `OK` on success, or an error if
the write fails or a save is already running. The output path is set by
`snapshot-path` in [Configuration](CONFIGURATION.md).

## `BGSAVE`

`BGSAVE [SCHEDULE]`

Starts a background snapshot and returns `Background saving started`. The
optional `SCHEDULE` token is case-insensitive. With the default
`exclusive-bg-persistence yes`, either form returns
`Background saving scheduled` if an AOF rewrite is active. The save starts
after the rewrite finishes. An active save is still an error.

Unlike Redis, kgcache gives bare `BGSAVE` the same scheduling behavior as
`BGSAVE SCHEDULE`. See [Snapshots](SNAPSHOTS.md#background-saving-bgsave).

## `BGREWRITEAOF`

`BGREWRITEAOF`

Starts an AOF rewrite and returns
`Background append only file rewriting started`. With the default
`exclusive-bg-persistence yes`, it returns
`Background append only file rewriting scheduled` if a save is active. The
rewrite starts after the save finishes. It returns an error when AOF is off or
another rewrite is already running. See [Append-only file](AOF.md#rewrite).

`SAVE` and `BGSAVE` share one guard against concurrent saves. Only one AOF
rewrite can run at a time. One pending request of each kind is remembered, and
repeated requests of that kind coalesce into it. With
`exclusive-bg-persistence no`, one save and one rewrite may overlap.

## `COMMAND`

`COMMAND [subcommand]`

Without a subcommand, returns registry metadata for every supported command.
Each RESP2 metadata entry has ten fields: name, arity, flags, first key, last
key, key step, ACL categories, tips, key specifications, and subcommands. Tips
and subcommand details are currently empty.

| Subcommand | Behavior |
| --- | --- |
| `COUNT` | Returns the number of supported commands as an integer. |
| `LIST [FILTERBY PATTERN <pattern> \| FILTERBY ACLCAT <category>]` | Returns supported command names as an array. `PATTERN` supports `*` and `?`; `ACLCAT` accepts a category with or without a leading `@`. |
| `INFO [name ...]` | Returns metadata for the named commands, or all commands when no names are given. Unknown names produce a null array entry. |
| `GETKEYS <command> [arguments ...]` | Returns the key arguments of a supported command. |
| `GETKEYSANDFLAGS <command> [arguments ...]` | Returns each key with its access flags as a `[key, flags]` entry. |

`COMMAND DOCS` and `COMMAND LIST FILTERBY MODULE` are not supported. Key
extraction requires a supported command with key arguments and validates its
argument count and types, but not every command-specific option.

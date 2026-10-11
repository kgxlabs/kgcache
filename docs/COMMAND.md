# Commands

This reference covers the commands currently implemented by kgcache. Command
names and subcommand names are case-insensitive. kgcache supports a subset of
Redis commands over RESP2 and RESP3, but full Redis compatibility is still a
development goal. For connection behavior and other server limitations, see
[Current status and compatibility](../README.md#current-status-and-compatibility).

The commands below start with connection and database selection, move through
key operations, then cover persistence and command introspection.

Invalid argument counts return `ERR wrong number of arguments` for every
command. The connection remains open so the client can send another request.

## `PING`

`PING [message]`

Returns the simple string `PONG` without an argument. With one non-null bulk
string argument, returns that message as a bulk string.

## `ECHO`

`ECHO <message>`

Returns the non-null bulk string argument unchanged.

## `HELLO`

`HELLO [2|3]`

Returns seven ordered metadata fields for the requesting connection. New
connections start in RESP2. `HELLO 2` selects RESP2 and returns a flat key/value
array. `HELLO 3` selects RESP3 and returns a map. Bare `HELLO` reports the current
mode without changing it. The selected mode applies to HELLO's own reply and
subsequent commands, including commands in the same pipeline. HELLO preserves
the selected database.

| Field | Value |
| --- | --- |
| `server` | `kgcache` |
| `version` | The kgcache package version used for this build |
| `proto` | The connection's current protocol version, initially `2` |
| `id` | The connection's positive integer ID, never reused within a server run |
| `mode` | `standalone` |
| `role` | `master` |
| `modules` | An empty array |

IDs may restart after a server restart. Unsupported integer versions return
`NOPROTO unsupported protocol version`. Invalid or out-of-range integers return
`ERR malformed command request`. Additional arguments, including `AUTH` and
`SETNAME` options, return `ERR unsupported option`. Rejected requests preserve
the current mode and leave the connection usable.

`COMMAND INFO HELLO` reports arity `-1`, the `fast` flag, the `@connection`
and `@fast` categories, and no keys.

## `CLIENT`

`CLIENT INFO`

Returns one space-separated row with a trailing LF. RESP2 sends a bulk string;
RESP3 sends a `txt:` verbatim string. Identity, peer/local endpoints, descriptor,
age, and idle time come from the requesting connection's owned snapshot.
IPv6 endpoints use `[address]:port`. Age and idle use whole monotonic seconds,
with negative durations clamped to zero.

The field order is `id`, `addr`, `laddr`, `fd`, `age`, `idle`, `db`, `cmd`,
`resp`, `lib-name`, `lib-ver`, `tot-net-in`, `tot-net-out`, `tot-cmds`, then
`name`, `sub`, `psub`, `ssub`, `watch`, `multi`, `multi-mem`, and `redir`.
The fixed indicators are an empty `name`, zero subscription/watch counts,
`multi=-1`, `multi-mem=0`, and `redir=-1`.

`tot-net-in` counts successful network read bytes once, before dispatch,
including received pipeline tails. `tot-net-out` counts bytes actually sent,
including prefixes sent before a later write failure. INFO includes its received
bytes and excludes its current reply bytes. Successful positive reads and writes
update activity; idle measures the time since the last such transfer. Byte and
command totals saturate at `18446744073709551615` (`maxInt(u64)`).

`cmd` is the canonical registered handler name, such as `get`, `hello`, or
`client|info`. `tot-cmds` increments immediately before each successfully bound
handler call, including calls that return an error. Unknown commands, binding
arity errors, unsupported CLIENT forms, incomplete input, and malformed frames
do not change the count or last command. INFO includes its own dispatch.

At this checkpoint, `db=0` and `resp=2` are registration defaults. They do not
yet track changes made through HELLO or SELECT. Both library labels are empty.

Bare `CLIENT` and extra INFO arguments return `ERR wrong number of arguments`.
Unknown subcommands, including `SETINFO` and `LIST`, return `ERR unsupported
option`. These errors leave the connection usable. `COMMAND INFO CLIENT`
reports container arity `-2`, the `fast` flag, `@connection` and `@fast`
categories, and no keys. INFO itself accepts exactly one subcommand argument.

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
`dir` and `dbfilename` in [Configuration](CONFIGURATION.md).

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

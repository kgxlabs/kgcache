# Commands

[Documentation](../README.md) / Commands

This reference covers the implemented Redis RESP2/RESP3 string-cache commands.
Names and subcommands are case-insensitive. See [compatibility](compatibility.md)
for reply encodings and tested clients, and [limits](limits.md) for unsupported
features. All commands below have command/unit or real-process coverage;
[automated evidence](compatibility.md#automated-evidence) links the test categories.

The commands below start with connection and database selection, move through
key operations, then cover persistence and command introspection.

Argument binding rejects invalid counts with `ERR wrong number of arguments`.
Command-specific validation follows below. Expected command errors leave the
connection usable.

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
| `version` | The effective kgcache version used for this build, see [build versions](../development/building.md) |
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

`cmd` is the canonical registered handler name, such as `get`, `hello`,
`client|info`, `client|list`, or `client|setinfo`. `tot-cmds` increments immediately
before each successfully bound handler call, including calls that return an
error. Unknown commands, binding arity errors, unsupported CLIENT forms,
incomplete input, and malformed frames do not change the count or last command.
INFO includes its own dispatch.

`db` and `resp` report the selected database and protocol, initially `0` and `2`.
The session publishes their current values after handler execution and before
reply output, including expected command errors. A valid HELLO or SELECT is
visible to the next INFO in the same pipeline. Rejected changes preserve the
previous selection. Library labels start empty and reflect successful SETINFO
calls on this connection.

`CLIENT LIST`

Returns one text payload containing a row for each live connection, including
the caller, sorted by ascending connection ID. Each row uses INFO's 22 fields
and trailing LF, with the same RESP2 bulk and RESP3 `txt:` verbatim encoding.
LIST takes no filters. Additional arguments, including ID and TYPE filters,
return `ERR wrong number of arguments` before dispatch.

LIST includes registered connections until their worker finishes. Finished
workers are excluded even before cleanup removes their records. A connection
captured before it closes can still appear in that response. Each row is
consistent at its own capture time; the rows are not one simultaneous snapshot
of all connections. A captured row remains valid even if its connection closes or its labels change.

The caller's row includes LIST's own dispatch as `cmd=client|list` and in
`tot-cmds`. Its incoming bytes are counted, and its current reply bytes are
excluded. Other rows contain their most recently published database, protocol,
labels, command name, and counters.

`CLIENT SETINFO LIB-NAME <value>`

`CLIENT SETINFO LIB-VER <value>`

Retains the library name or version and returns `OK`. Command, subcommand, and
attribute names are case-insensitive; valid value bytes are preserved exactly.
Values may be empty or contain printable ASCII bytes from `!` through `~`.
Whitespace, control bytes, NUL, and non-ASCII bytes return `ERR syntax error`.
Unknown attributes return `ERR unsupported option`. Invalid values or a failed
replacement preserve the previous label. Repeated calls replace a
label; an empty value clears it. The next INFO in a pipeline sees the change.
Labels belong to one connection and are not stored in cache data or persistence
files. The existing encoded-request limit applies, with no shorter label limit.

SETINFO takes exactly an attribute and a value. Wrong arity is rejected before
dispatch and does not change `cmd` or `tot-cmds`. Attribute and content errors
occur in the recognized handler and count as `client|setinfo` dispatches.

Bare `CLIENT` and extra INFO/LIST arguments return `ERR wrong number of arguments`.
Unknown subcommands, including `SETNAME`, `GETNAME`, `ID`, and `TRACKING`,
return `ERR unsupported option`. These errors leave the connection usable.
Remaining diagnostics are tracked in
[#179](https://github.com/kgxlabs/kgcache/issues/179). These 22 fields are the
current report contract, not the full Redis CLIENT INFO/LIST output.

`COMMAND INFO CLIENT` reports container arity `-2`, no flags or keys, the
`@connection` and `@slow` categories, and its supported subcommand metadata.
`COMMAND INFO client|info` reports arity `2`, the `fast` flag, and `@connection`
and `@fast`. `COMMAND INFO client|setinfo` reports arity `4`, no flags or keys,
and `@connection` and `@slow`.
`COMMAND INFO client|list` reports arity `2`, the `admin` flag, no keys, and
`@admin`, `@connection`, `@slow`, and `@dangerous`.

## `SELECT`

`SELECT <index>`

Switches the connection to the database at `index` and returns `OK`. The index
must be within the configured database range. Subsequent key commands on that
connection use the selected database. The default is database 0. With the
default `databases 16`, valid indices are 0 through 15. An invalid index
returns an error and preserves the previous selection.

## `SET`

`SET <key> <value> [options]`

Stores a string value in the selected database. Without `GET`, returns `OK`
when the write applies, or null when `NX` or `XX` rejects it.
With `GET`, returns the previous value as a blob string, or null if no value
existed, whether the write applies or is rejected. Null is `$-1\r\n` in RESP2
and `_\r\n` in RESP3.

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
before the command. An ordinary applied SET clears the old TTL. KEEPTTL
preserves it. A supplied expiration replaces it.

Only one conditional option, one expiration or TTL option, and one response
option can be used in a single `SET` command. Expiration arguments must be
positive decimal integers and fit the supported millisecond timestamp range.
Missing values, overflow, unknown options, and repeated option groups return
an error before writing. Expired values are removed when
read, and cron also removes sampled expired keys. See
[expiration limits](limits.md#capacity-and-expiration).

## `GET`

`GET <key>`

Returns the string value as a blob string. Returns null when the
key is absent or expired: `$-1\r\n` in RESP2 and `_\r\n` in RESP3.

## `DEL`

`DEL <key> [key ...]`

Removes the given keys from the selected database. Returns the number of keys
that existed and were removed as an integer.

## `DBSIZE`

`DBSIZE`

Returns the number of stored keys in the selected database as an integer.
Expired entries can remain in this count until lazy or active cleanup removes them.

## `SAVE`

`SAVE`

Writes a `.kgc` snapshot of all databases to disk and blocks the calling
connection until the write finishes. Returns `OK` on success, or an error if
the write fails or a save is already running. The output path is set by
`dir` and `dbfilename` in [Configuration](configuration.md).

## `BGSAVE`

`BGSAVE [SCHEDULE]`

Starts a background snapshot and returns `Background saving started`. The
optional `SCHEDULE` token is case-insensitive. With the default
`exclusive-bg-persistence yes`, either form returns
`Background saving scheduled` if an AOF rewrite is active. The save starts
after the rewrite finishes. An active save is still an error.

Unlike Redis, kgcache gives bare `BGSAVE` the same scheduling behavior as
`BGSAVE SCHEDULE`. See [Snapshots](../development/snapshots.md#background-saving-bgsave).

## `BGREWRITEAOF`

`BGREWRITEAOF`

Starts an AOF rewrite and returns
`Background append only file rewriting started`. With the default
`exclusive-bg-persistence yes`, it returns
`Background append only file rewriting scheduled` if a save is active. The
rewrite starts after the save finishes. It returns an error when AOF is off or
another rewrite is already running. See [Append-only file](../development/aof.md#rewrite).

`SAVE` and `BGSAVE` share one guard against concurrent saves. Only one AOF
rewrite can run at a time. One pending request of each kind is remembered, and
repeated requests of that kind coalesce into it. With
`exclusive-bg-persistence no`, one save and one rewrite may overlap.

## `COMMAND`

`COMMAND [subcommand]`

Without a subcommand, returns registry metadata for every supported command.
Each RESP2 metadata entry has ten fields: name, arity, flags, first key, last
key, key step, ACL categories, tips, key specifications, and subcommands. Tips
are empty. CLIENT includes INFO, LIST, and SETINFO subcommand details, also
available by their case-insensitive full names through COMMAND INFO.

| Subcommand | Behavior |
| --- | --- |
| `COUNT` | Returns the number of supported top-level commands as an integer. |
| `LIST [FILTERBY PATTERN <pattern> \| FILTERBY ACLCAT <category>]` | Returns supported top-level command names as an array. `PATTERN` supports `*` and `?`; `ACLCAT` accepts a category with or without a leading `@`. |
| `INFO [name ...]` | Returns metadata for the named commands, or all commands when no names are given. Unknown names produce a null array entry (`*-1\r\n`) in RESP2 and null (`_\r\n`) in RESP3. Known entries keep the same array layout in both modes. |
| `GETKEYS <command> [arguments ...]` | Returns the key arguments of a supported command. |
| `GETKEYSANDFLAGS <command> [arguments ...]` | Returns each key with its access flags as a `[key, flags]` entry. |

`COMMAND DOCS` and `COMMAND LIST FILTERBY MODULE` are not supported. Key
extraction requires a supported command with key arguments and validates its
argument count and types, but not every command-specific option.

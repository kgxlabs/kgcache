# COMMAND

[Commands](README.md) / COMMAND

Discover the implemented commands, their metadata, and their key arguments.

## Syntax

```text
COMMAND
COMMAND COUNT
COMMAND LIST [FILTERBY PATTERN pattern | FILTERBY ACLCAT category]
COMMAND INFO [name ...]
COMMAND GETKEYS command [argument ...]
COMMAND GETKEYSANDFLAGS command [argument ...]
```

## Examples

```console
127.0.0.1:6379> COMMAND COUNT
(integer) 13
127.0.0.1:6379> COMMAND LIST FILTERBY PATTERN g*
1) "get"
127.0.0.1:6379> COMMAND GETKEYS SET example:message hello
1) "example:message"
127.0.0.1:6379> COMMAND INFO unknown-command
1) (nil)
```

Use `COMMAND INFO GET SET` to inspect specific commands. Use `COMMAND INFO`
without names, or bare `COMMAND`, to return all top-level metadata.

## Subcommands

### COUNT

Return the number of top-level commands. CLIENT and COMMAND each count once;
their subcommands are not separate top-level entries.

### LIST

Return top-level command names, in registry order. With no filter, list every
name. PATTERN accepts `*` for any sequence and `?` for one byte. Patterns match
the lowercase names case-sensitively. ACLCAT accepts a known category with or
without a leading `@`, such as `read` or `@read`.

The filter keywords and category names are case-insensitive. There is one
optional filter, not a combination of filters. MODULE filtering is unsupported.

### INFO

Return one metadata entry per requested name, in request order. Names are
case-insensitive. CLIENT children can be queried as `client|info`,
`client|list`, and `client|setinfo`. COMMAND children use names such as
`command|getkeys`. These full names are metadata names, not callable commands.

Each known entry is an array with ten fields:

| Position | Field |
| --- | --- |
| 1 | Canonical command name. |
| 2 | Redis-style arity, including the command name. |
| 3 | Command flags. |
| 4 | First key position, or 0 when there are no keys. |
| 5 | Last key position, or 0 when there are no keys. |
| 6 | Key step, or 0 when there are no keys. |
| 7 | ACL category names. |
| 8 | Tips, currently an empty array. |
| 9 | Key specifications. |
| 10 | Subcommand metadata. |

A positive arity is an exact count. A negative arity describes a minimum
count. Some handlers apply further bounds or option validation.

Flags and ACL categories describe command metadata. They do not implement an
ACL or authentication system. HELLO's metadata reports arity `-1`, `fast`,
`@connection`, and `@fast`. CLIENT's parent entry reports arity `-2`, no flags
or keys, and its supported child entries.

An unknown name produces a null entry without failing the whole request.

### GETKEYS and GETKEYSANDFLAGS

Parse a supported command request and return its key arguments.
GETKEYSANDFLAGS pairs each key with an array of access flags.

| Command | Key access flags |
| --- | --- |
| GET | `RO`, `access` |
| SET without GET | `OW`, `update` |
| SET with GET | `RW`, `access`, `update` |
| DEL | `RM`, `delete` |

Key extraction validates command existence, argument counts, and key positions.
It does not execute the command or validate every handler-specific option.
A command with no keys is an error, not an empty key result.

## Return information

COUNT returns an integer. LIST, INFO, GETKEYS, GETKEYSANDFLAGS, and bare COMMAND
return arrays in both protocols. Known metadata entries keep the same array
layout in RESP2 and RESP3.

For an unknown INFO entry, RESP2 uses a null array, `*-1\r\n`, and RESP3 uses
null, `_\r\n`. This RESP2 form differs from GET and SET's null bulk string.

Unsupported subcommands such as DOCS return `ERR unsupported option`.
Expected validation errors leave the connection usable.

## Related commands

[GET](get.md), [SET](set.md), [DEL](del.md), [HELLO](hello.md),
[CLIENT INFO](client-info.md).

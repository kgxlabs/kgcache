# CLIENT SETINFO

[Commands](README.md) / CLIENT SETINFO

Attach a library name or version to this connection.

## Syntax

```text
CLIENT SETINFO LIB-NAME value
CLIENT SETINFO LIB-VER value
```

## Examples

Run these in one interactive session:

```console
127.0.0.1:6379> CLIENT SETINFO LIB-NAME example-client
OK
127.0.0.1:6379> CLIENT SETINFO LIB-VER 1.0.0
OK
127.0.0.1:6379> CLIENT SETINFO LIB-NAME ""
OK
```

CLIENT INFO in that session now reports an empty `lib-name` and `lib-ver=1.0.0`.
The labels appear in CLIENT LIST too.

## Behavior

The name, subcommand, and attribute are case-insensitive. Values preserve their
exact bytes. A value may be empty or contain printable ASCII bytes from `!`
through `~`. Whitespace, control bytes, NUL, and non-ASCII bytes are rejected.

Repeated calls replace the selected label. An empty value clears it. An invalid
value or failed replacement leaves the prior label intact. The next CLIENT INFO
in a pipeline observes the change.

Labels belong to the live connection. They are not cache keys and are not saved
in persistence files. The encoded-request limit bounds their size; there is no
separate shorter label limit.

| Rejected request | Error |
| --- | --- |
| Missing or extra arguments | `ERR wrong number of arguments` |
| Unknown attribute | `ERR unsupported option` |
| Invalid value bytes | `ERR syntax error` |

Attribute and value errors occur within the recognized SETINFO handler and
count toward `tot-cmds`. Wrong argument counts are rejected before dispatch.

## Return information

RESP2 and RESP3 both return the simple string `OK` on success.

## Related commands

[CLIENT INFO](client-info.md), [CLIENT LIST](client-list.md), [HELLO](hello.md).

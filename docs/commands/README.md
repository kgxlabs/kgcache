# Commands

[Docs](../README.md) / Commands

Use these commands to work with strings, select a database, inspect a
connection, and save data. This is kgcache's complete command set.

Each command page includes its syntax, examples, and RESP2/RESP3 replies.
Examples with a `127.0.0.1:6379>` prompt run inside an interactive `redis-cli`
session. Start the server with the [quick start](../get-started/README.md), then
run `redis-cli` in another terminal.

## Strings and keys

| Command | Description |
| --- | --- |
| [SET](set.md) | Store a value, with optional conditions and expiration. |
| [GET](get.md) | Read a value. |
| [DEL](del.md) | Remove one or more keys. |
| [DBSIZE](dbsize.md) | Count stored keys in the selected database. |

## Connections

| Command | Description |
| --- | --- |
| [PING](ping.md) | Check that a connection responds. |
| [ECHO](echo.md) | Return a message unchanged. |
| [SELECT](select.md) | Change the connection's database. |
| [HELLO](hello.md) | Select RESP2 or RESP3 and read server metadata. |
| [CLIENT INFO](client-info.md) | Inspect the current connection. |
| [CLIENT LIST](client-list.md) | Inspect live connections. |
| [CLIENT SETINFO](client-setinfo.md) | Set a connection's library labels. |

## Persistence and discovery

| Command | Description |
| --- | --- |
| [SAVE](save.md) | Write a snapshot and wait for completion. |
| [BGSAVE](bgsave.md) | Start or schedule a background snapshot. |
| [BGREWRITEAOF](bgrewriteaof.md) | Start or schedule an AOF rewrite. |
| [COMMAND](command.md) | Read command metadata and find key arguments. |

## Using the reference

Square brackets mark optional arguments. A vertical bar separates choices.
Command names, subcommands, and command options are case-insensitive. Keys,
values, and library labels preserve their bytes.

Commands travel as arrays of non-null bulk strings, even with RESP3 selected.
The [protocol reference](../reference/protocol.md) defines the request grammar,
reply types, and connection error behavior.

These pages describe kgcache, whose command set and semantics are limited.
Check [compatibility](../reference/compatibility.md) before using another
Redis command or a client feature. That page also links automated coverage.

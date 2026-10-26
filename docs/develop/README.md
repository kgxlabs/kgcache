# Develop with kgcache

[Docs](../README.md) / Develop

Use kgcache as a shared string cache for an application. A value can be text,
encoded JSON, or binary data. The server stores those bytes without interpreting
their content.

## Connect in your language

- [Go with go-redis](clients/go.md)
- [Node.js with node-redis](clients/node.md)

Each guide installs an exact tested client, opens a connection, writes a
value with an expiration, and reads it back. Both clients use RESP3 by default.
The guides also show explicit RESP2 settings.

## Work with data

- [Strings and expiration](strings.md): choose keys, replace values, and
  use conditional writes.
- [Pipelines](pipelining.md): reduce round trips when several commands can
  travel together.
- [Command reference](../commands/README.md): find syntax and exact replies.

## Check an existing Redis application

Start with [Compatibility](../reference/compatibility.md). A working connection
does not make every client API available. Match the commands and features your
application uses to that contract. In particular, leave credentials and
connection names unset, and use a standalone TCP endpoint.

Server contributors should use [Contribute](../contribute/README.md).

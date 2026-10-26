# Strings and expiration

[Docs](../README.md) / [Develop](README.md) / Strings

kgcache stores a key and a value as bytes. Use a string for a small cache
entry, serialized object, or binary payload. Values have no server-side schema.
Commands such as GET and SET operate on the selected database.

Run the examples in an interactive `redis-cli` session against a server from
the [quick start](../get-started/README.md). The `>` prompt is shown for context;
type only the command after it.

## Store a value

```console
> SET user:42:name Ada
OK
> GET user:42:name
"Ada"
> SET user:42:name Grace
OK
> GET user:42:name
"Grace"
```

SET creates the key or replaces its value. Key names are case-sensitive.
Choose a consistent prefix, such as `user:42:name`, to separate application data.
The colon is a naming convention, not a hierarchy in the server.

Strings are binary-safe, including empty keys and values. Use a client library
when data contains arbitrary bytes. Every encoded request must fit within the
[protocol limits](../reference/protocol.md#request-limits).

## Expire cache entries

```console
> SET page:home "cached response" EX 60
OK
> GET page:home
"cached response"
```

`EX` sets a lifetime in seconds. Use `PX` for milliseconds or `EXAT`/`PXAT`
for an absolute Unix deadline. After expiration, GET returns null. Cron also
removes sampled expired keys. Removal is not an exact per-key timer, so DBSIZE
can include entries that have expired but have not been removed.

An ordinary SET removes the previous expiration. Add `KEEPTTL` to retain it
when replacing a value:

```console
> SET page:home "new response" KEEPTTL
OK
```

There are no standalone EXPIRE or TTL commands. Assign expiration through SET.
See [SET options](../commands/set.md) for valid combinations.

## Write with a condition

Use `NX` to create an entry only when it is absent:

```console
> DEL task:42:result
(integer) 0
> SET task:42:result pending NX
OK
> SET task:42:result running NX
(nil)
> GET task:42:result
"pending"
```

The DEL result may be `1` if the key existed before this example. The second
conditional write leaves the existing value and expiration unchanged.
`XX` performs the opposite condition: it writes only when a key exists.

Add `GET` to SET when you need the old value. The reply is the value from
before the command, even when a condition rejects the write. A null reply
with GET therefore does not by itself mean the write was rejected.

## Select a database

```console
> SELECT 1
OK
> SET greeting hello
OK
> GET greeting
"hello"
> SELECT 0
OK
```

Selection belongs to the connection. A newly opened connection starts in
database 0. Use the database option in your client so each pooled connection
selects it during setup. The default configuration has databases 0 through 15.
Databases separate key namespaces; they are not an access-control boundary.

## Handle cache misses and write errors

GET returns null for an absent or expired key. Treat that as a cache miss,
fetch the value from its source, and use SET to cache it again. Go and Node
map null differently; the [Go](clients/go.md) and [Node.js](clients/node.md)
guides explain the return values.

A disconnect can happen after a write applies but before its reply arrives.
An AOF flush error can also follow an applied write. An error does not prove
the write was rolled back. Choose retries based on whether repeating the
operation is safe for your application.

## Next steps

Read [SET](../commands/set.md), [GET](../commands/get.md), and
[Pipelines](pipelining.md). For data kept across restarts, see
[Persistence](../operate/persistence.md).

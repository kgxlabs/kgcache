# Pipelines

[Docs](../README.md) / [Develop](README.md) / Pipelines

A pipeline sends several commands on one connection before waiting for each
reply. Use it when independent cache operations can share a network round trip.
kgcache processes complete commands in order and returns replies in that order.

## Go

With a connected client from the [Go guide](clients/go.md), queue commands on
`Pipeline`, then execute the batch:

```go
pipe := client.Pipeline()
pipe.Set(ctx, "pipeline:go", "hello", time.Minute)
getResult := pipe.Get(ctx, "pipeline:go")
_, execErr := pipe.Exec(ctx)
if execErr != nil {
    panic(execErr)
}
fmt.Println(getResult.Val())
```

The result is `hello`. `ctx`, `fmt`, and `time` come from the complete Go
example. Use `Pipeline`, since `TxPipeline` requires transactions.

## Node.js

With a connected client from the [Node.js guide](clients/node.md), use
`execAsPipeline()` to send a batch without MULTI/EXEC:

```js
const replies = await client.multi()
  .set('pipeline:node', 'hello')
  .get('pipeline:node')
  .del('pipeline:node')
  .execAsPipeline();
console.log(replies);
```

The result is `['OK', 'hello', 1]`. Calling `exec()` instead requires a Redis
transaction, which kgcache does not implement.

## Ordering and errors

A valid command error leaves the connection usable. Later complete commands
can still execute. A malformed frame or an oversized request ends the session.
A reply write failure also ends the session and prevents later commands on
that connection from running. Earlier successful writes remain applied.

A pipeline is not atomic. Other clients can write between its commands.
If the connection fails, some commands may already have run. Inspect individual
results where available and decide which operations are safe to retry.

The request limits apply to each command, not the whole batch. A pipeline can
exceed 1 MiB in total if every command fits the limit. A slow reader can block
its connection's worker while the server sends a reply. See the
[protocol reference](../reference/protocol.md#transport-behavior).

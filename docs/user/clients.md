# Connect Go and Node clients

[Documentation](../README.md) / Clients

Start kgcache on `127.0.0.1:6379` with [getting started](getting-started.md).
The examples use exact versions from the [tested client table](compatibility.md#exact-tested-clients).
Use Go 1.26.9 or Node 22.14.0 with npm 10.9.2 to match those profiles.

## Connection settings

- Use a single standalone endpoint. Cluster and Sentinel clients are unsupported.
- Database 0 is the default. `DB` in Go and `database` in Node select another
  database at connection setup. The index must be `0` through `databases - 1`
  from the server config, by default `0` through `15`.
- Leave username and password unset. AUTH, ACLs, and HELLO AUTH are unsupported.
- Leave Go `ClientName` and Node `name` unset. CLIENT SETNAME and HELLO SETNAME
  are unsupported. Library identity labels from CLIENT SETINFO are supported.
- Use plain TCP. TLS, client-side caching, tracking, pub/sub, transactions,
  scripting, and unlisted commands are unsupported.

Both tested clients select RESP3 by default. Set the option to 2 for RESP2,
or to 3 for an explicit RESP3 connection. A plain server connection starts in
RESP2 until the client's handshake changes it.

## Go

Create a new example directory outside the kgcache repository:

```sh
mkdir kgcache-go-example
cd kgcache-go-example
go mod init example.com/kgcache-demo
go get github.com/redis/go-redis/v9@v9.22.0
```

Save this as `main.go`:

```go
package main

import (
    "context"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

func main() {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    client := redis.NewClient(&redis.Options{
        Addr: "127.0.0.1:6379",
        DB:   0,
    })
    defer client.Close()

    if err := client.Set(ctx, "example:go", "hello", time.Minute).Err(); err != nil {
        panic(err)
    }
    value, err := client.Get(ctx, "example:go").Result()
    if err != nil {
        panic(err)
    }
    fmt.Println(value)
    if err := client.Del(ctx, "example:go").Err(); err != nil {
        panic(err)
    }
}
```

Run `go run .`. It prints `hello`. The omitted `Protocol` uses the client's
default RESP3 handshake. For explicit RESP2, use these options in the same
program and run it again:

```go
client := redis.NewClient(&redis.Options{
    Addr:     "127.0.0.1:6379",
    DB:       0,
    Protocol: 2,
})
```

A missing GET is `redis.Nil`. String-result APIs such as `SetArgs` also use
`redis.Nil` for a null SET reply. The boolean APIs `SetNX` and `SetXX` instead
return `false` for a rejected condition. Handle these results separately from
connection or server errors. Retain the generated
`go.mod` and `go.sum` for repeatable application builds.

## Node.js

Create a new example directory outside the kgcache repository:

```sh
mkdir kgcache-node-example
cd kgcache-node-example
npm init -y
npm install --save-exact redis@6.2.1
```

Save this as `example.mjs`:

```js
import { createClient } from 'redis';

const client = createClient({
  socket: {
    host: '127.0.0.1',
    port: 6379,
    connectTimeout: 3000,
    reconnectStrategy: false,
  },
  database: 0,
  commandOptions: { timeout: 3000 },
});
client.on('error', (error) => console.error(error.message));

try {
  await client.connect();
  await client.set('example:node', 'hello', { expiration: { type: 'EX', value: 60 } });
  console.log(await client.get('example:node'));
  await client.del('example:node');
} finally {
  if (client.isOpen) client.destroy();
}
```

Run `node example.mjs`. It prints `hello`. The omitted `RESP` uses the
client's default RESP3 handshake. For explicit RESP2, add `RESP: 2` to the
same options object and run it again:

```js
const client = createClient({
  RESP: 2,
  socket: { host: '127.0.0.1', port: 6379, connectTimeout: 3000, reconnectStrategy: false },
  database: 0,
  commandOptions: { timeout: 3000 },
});
```

A missing GET or a conditional SET null result is JavaScript `null`. Keep the
generated `package-lock.json`; later installs can use `npm ci`.

## Pipelines and failures

Ordered pipelines of supported commands work. In node-redis, `multi()` with
`execAsPipeline()` sends a pipeline without a Redis transaction. `exec()`
requires MULTI/EXEC, which kgcache does not implement. In Go, use `Pipeline`,
not `TxPipeline`.

A connection can fail after a command has applied but before its reply reaches
the client. A generic internal error can also follow an applied write whose
AOF flush failed. Do not assume that an error rolled the write back. Decide
whether retries are safe for your application. See [persistence](persistence.md)
and [transport limits](limits.md#requests-and-connections).

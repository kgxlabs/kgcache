# Connect with Go

[Docs](../../README.md) / [Develop](../README.md) / Go

Use go-redis to write and read string values from a running kgcache server.
This guide uses Go 1.26.9 and go-redis v9.22.0, one of the exact
[tested profiles](../../reference/compatibility.md#tested-clients).
Start a server on `127.0.0.1:6379` with the
[quick start](../../get-started/README.md) before running the program.

## Install

Create an application directory outside the kgcache checkout:

```sh
mkdir kgcache-go-example
cd kgcache-go-example
go mod init example.com/kgcache-demo
go get github.com/redis/go-redis/v9@v9.22.0
```

Keep `go.mod` and `go.sum` with your application to retain its resolved dependencies.

## Connect, write, and read

Save this as `main.go`:

```go
package main

import (
    "context"
    "errors"
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
    if errors.Is(err, redis.Nil) {
        fmt.Println("cache miss")
        return
    }
    if err != nil {
        panic(err)
    }
    fmt.Println(value)
    if err := client.Del(ctx, "example:go").Err(); err != nil {
        panic(err)
    }
}
```

```sh
go run .
```

Expected output:

```text
hello
```

The client negotiates RESP3 because `Protocol` is omitted. Its normal library
identity reporting can stay enabled. kgcache accepts CLIENT SETINFO.

## Use RESP2

Replace the connection options in the same program with:

```go
client := redis.NewClient(&redis.Options{
    Addr:     "127.0.0.1:6379",
    DB:       0,
    Protocol: 2,
})
```

Run the program again. It prints the same value. Set `Protocol: 3` when you
want to select RESP3 explicitly.

## Select a database and handle results

Set `DB` to the required index. The default server accepts 0 through 15;
database 0 is used when the client option is omitted. Client pools apply
the option to each new connection.

A missing GET is `redis.Nil`. String-result APIs such as `SetArgs` also use
`redis.Nil` for a null SET reply. `SetNX` and `SetXX` return `false` when the
condition rejects the write. Handle those outcomes separately from network
or server errors.

Leave `Username`, `Password`, `ClientName`, and TLS settings unset. Use a
standalone client. Cluster, Sentinel, transactions, pub/sub, tracking, and
client-side caching are outside the [supported contract](../../reference/compatibility.md).

## Next steps

Read [Strings and expiration](../strings.md), [Pipelines](../pipelining.md),
and the [SET reference](../../commands/set.md).

# Quick start

[Docs](../README.md) / Get started

Start kgcache, write a value, and read it using the Redis command-line client.
You need Docker with Linux containers and a host installation of `redis-cli`.
To use Zig instead, follow [Install kgcache](install.md#build-from-source),
then continue at **Write and read a value** below.

## Start a server

```sh
docker run --detach --rm --name kgcache --platform linux/amd64 \
  --publish 127.0.0.1:6379:6379 --volume kgcache-data:/data \
  --stop-timeout 30 kgxlabs/kgcache:0.1.0
```

This starts the Linux amd64 release in the background. It exposes
port 6379 on your machine's loopback address and stores data in a named volume.
Arm64 hosts need amd64 emulation. If port 6379 is occupied, use another host
port, such as `--publish 127.0.0.1:6380:6379`, and add `-p 6380` to the
`redis-cli` commands below.

Check that the server responds:

```sh
redis-cli PING
```

Expected reply: `PONG`.

## Write and read a value

```sh
redis-cli SET greeting hello
redis-cli GET greeting
```

The replies are `OK` and `hello`. Each command opens its own connection. The
second command can read the value because both use database 0 on the same server.

Give a value a 60-second lifetime:

```sh
redis-cli SET greeting hello EX 60
redis-cli -3 GET greeting
```

The replies are `OK` and `hello`. `-3` selects RESP3 for that connection.
After the value expires, GET returns null. `redis-cli` normally displays
that as `(nil)` in an interactive terminal.

Remove the value:

```sh
redis-cli DEL greeting
```

The result is `1` if the key still exists, or `0` if it has expired.
See [Strings and expiration](../develop/strings.md) for conditional writes.

## Stop and start again

For a native source build, press Ctrl+C in the server terminal. Restart it
with the same launch command and data directory. The commands below apply
to the Docker example.

```sh
docker stop kgcache
```

The command requests a clean stop and allows 30 seconds before forced
termination. The container is removed because it used `--rm`. The data volume
remains. Run the original Docker command again to reuse it.

The image uses an append-only file by default. A native source build uses
snapshots with AOF off. Read [Persistence](../operate/persistence.md) before
depending on restart or shutdown behavior.

## Next steps

- Connect an application with [Go](../develop/clients/go.md) or
  [Node.js](../develop/clients/node.md).
- Run a local service with [Docker Compose](../operate/docker.md).
- Look up [commands](../commands/README.md) and [tested compatibility](../reference/compatibility.md).

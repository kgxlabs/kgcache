# Quick start

[Docs](../README.md) / Get started

Start kgcache, write a value, and read it using the Redis command-line client.
You need Docker with Linux containers and a host installation of `redis-cli`.
To use Zig instead, follow [Install kgcache](install.md#build-from-source),
then continue at **Write and read a value** below.

## Start a server

```sh
docker run -d --name kgcache -p 127.0.0.1:6379:6379 kgxlabs/kgcache:latest
```

This starts the server in the background with its bundled config. It exposes
port 6379 on your machine's loopback address. Keep this address because kgcache
has no authentication. If port 6379 is occupied, use another host port, such as
`-p 127.0.0.1:6380:6379`, and add `-p 6380` to the `redis-cli` commands below.

The published image supports Linux amd64. Arm64 hosts need amd64 emulation.
Add `--platform linux/amd64` to select that platform explicitly and avoid
Docker's platform warning.

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
docker stop --timeout 30 kgcache
docker start kgcache
```

`docker stop` requests a clean stop and allows 30 seconds before forced
termination. `docker start` reuses the stopped container and its data.
Use it instead of running `docker run` again with the same container name.

This example stores data inside the container. Removing the container also
removes its data. To keep data when replacing a container, use the
[named-volume example](../operate/docker.md#keep-data-when-replacing-a-container).

The image uses an append-only file by default. A native source build uses
snapshots with AOF off. Read [Persistence](../operate/persistence.md) before
depending on restart or shutdown behavior.

## Next steps

- Connect an application with [Go](../develop/clients/go.md) or
  [Node.js](../develop/clients/node.md).
- Run a local service with [Docker Compose](../operate/docker.md).
- Look up [commands](../commands/README.md) and [tested compatibility](../reference/compatibility.md).

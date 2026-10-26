# Health and monitoring

[Docs](../README.md) / [Operate](README.md) / Monitoring

Use the built-in probe to check that a listener answers PING. Use process
logs and CLIENT reports to investigate a connection or persistence failure.

## Check a native listener

Run the health command with the same config and endpoint overrides used by
the server:

```sh
./zig-out/bin/kgcache healthcheck kgcache.conf --port 7000
```

Omit the file and port override when probing the native defaults:

```sh
./zig-out/bin/kgcache healthcheck
```

Success prints nothing and exits 0. A failure prints one short stderr line
and exits 1. In a shell, `echo $?` immediately after the command prints its
exit status.

The probe requires the exact PONG simple-string reply. Connect, send, and
read share a 1000 ms monotonic network deadline. The probe returns after that
reply without waiting for the peer to close.

## Match the endpoint

The probe accepts numeric IPv4 addresses. It maps `0.0.0.0` to `127.0.0.1`.
It rejects port 0 because a separate process cannot discover an ephemeral
listener from its config. The server itself can use port 0.

The probe loads config using the usual defaults, file, and CLI precedence.
It rejects `--ready-fd`, does not create a server, and does not open or test
the persistence directory. Its network deadline does not include config
filesystem access or process startup.

## Check a container

For the Compose example:

```sh
docker compose ps
docker compose exec -T kgcache /usr/local/bin/kgcache healthcheck /etc/kgcache/kgcache.conf
docker compose logs --tail 100 kgcache
```

The image's health settings are listed in [Docker](docker.md#understand-the-image-layout).
A running container can still be starting or unhealthy. Restart policies
respond to process exit, not to unhealthy status alone.

## Inspect client connections

```sh
redis-cli CLIENT INFO
redis-cli CLIENT LIST
```

INFO describes that command's connection. LIST reports live connections in
ascending ID order. The default `redis-cli` invocation opens a new connection
for each command, so its ID changes between invocations. Use an interactive
session when you want to inspect repeated commands on one connection.

Reports contain exactly 22 fields. Read [CLIENT INFO](../commands/client-info.md)
for their meaning and counter timing. LIST filters and the full Redis
diagnostic schema are unsupported. There is no standalone INFO command.

## Interpret health and logs

PONG shows basic service response. It does not prove disk sync, data integrity,
available capacity, or recovery completeness. Check application data and
persistence logs for those questions.

The default logger writes informational events to stdout and errors to stderr.
Retain both when reporting a failure. See
[Troubleshooting](troubleshooting.md) for the next checks after an error.

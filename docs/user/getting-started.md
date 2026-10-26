# Getting started

[Documentation](../README.md) / Getting started

kgcache stores string keys and string or binary values in memory. This guide
uses the default database, database 0. Read [compatibility](compatibility.md)
and [limits](limits.md) before connecting an application.

## Run the image

Follow [Try it](../../README.md#try-it) for the published release candidate,
a named data volume, and the first SET/GET commands. The image uses AOF by
default. Its data directory is `/data`, and the service runs as UID/GID 10001.
Host port 6379 is published on loopback. Install `redis-cli` separately.

For a local source image and full service settings, use the
[service guide](service.md). Image builds and releases are Linux amd64.

## Build from source

Install Zig 0.16.0, Git, and `redis-cli`. Run:

```sh
git clone https://github.com/kgxlabs/kgcache.git
cd kgcache
zig build
mkdir -p data
./zig-out/bin/kgcache --dir ./data
```

The executable listens on `127.0.0.1:6379`. In another terminal:

```sh
redis-cli PING
redis-cli SET greeting hello PX 60000
redis-cli GET greeting
redis-cli -3 GET greeting
```

Expect `PONG`, `OK`, `hello`, and `hello`. `-3` asks redis-cli to select
RESP3. A raw TCP connection starts in RESP2.

The native defaults use 16 databases and snapshots, with AOF off. A clean
SIGINT or SIGTERM stop saves dirty data by default. Periodic snapshots are
off. Use a fresh data directory for a separate server.
See [persistence](persistence.md) for the failure and shutdown limits.

## Change the port or use a config file

Copy [kgcache.conf.example](../../kgcache.conf.example) to `kgcache.conf`,
then pass it to the executable. CLI settings override file settings:

```sh
./zig-out/bin/kgcache kgcache.conf --port 7000
redis-cli -h 127.0.0.1 -p 7000 PING
```

The server loads settings once at startup. Restart it to apply changes.
See [configuration](configuration.md) for every supported directive.

## Connect an application

Use the [Go and Node examples](clients.md) for default RESP3 or explicit
RESP2. Leave credentials and connection names unset. Database 0 works with
the default settings.

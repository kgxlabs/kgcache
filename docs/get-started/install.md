# Install kgcache

[Docs](../README.md) / [Get started](README.md) / Install

Use the published container image to try kgcache without a compiler. Build
from source when you want a native executable or want to change the server.

## Run the container image

Follow the [quick start](README.md) for a runnable Docker command and the
first SET/GET requests. The image for this release is
`kgxlabs/kgcache:0.1.0`, for Linux amd64.
Its [release record](https://github.com/kgxlabs/kgcache/releases/tag/v0.1.0)
identifies the source and image digest.

For local builds, persistent volumes, and custom settings, use the
[Docker guide](../operate/docker.md).

## Build from source

Install Git and Zig 0.16.0. Install `redis-cli` separately for the connection
examples. From a terminal, run:

```sh
git clone https://github.com/kgxlabs/kgcache.git
cd kgcache
zig build -Doptimize=ReleaseSafe
mkdir -p data
./zig-out/bin/kgcache --dir ./data
```

The executable runs in the foreground and listens on `127.0.0.1:6379`.
Keep that terminal open. In another terminal, check the listener:

```sh
redis-cli PING
```

Expected reply: `PONG`. Continue with the
[quick start](README.md#write-and-read-a-value) to store data.

Press Ctrl+C in the server terminal to request a clean stop. The default
configuration saves dirty snapshot data in `./data`. See
[Shutdown and restart](../operate/shutdown.md) for exit status and time limits.

## Start with a config file

From the checkout root, copy the example and edit it:

```sh
cp kgcache.conf.example kgcache.conf
./zig-out/bin/kgcache kgcache.conf --dir ./data --port 7000
```

The command-line values replace the file's directory and port. Connect with
`redis-cli -p 7000 PING`. The data directory must already exist.
[Configure a server](../operate/configuration.md) explains settings and paths.

## Rebuild after an update

Stop the running server, update the checkout, and run the build command again.
Then start the new executable with the same config and data directory.
Rebuilding does not replace a running process. Check release notes and retain
a separate data copy before changing a server that holds data you need.

Contributor build records and version inputs are documented in
[Build versions](../contribute/building.md).

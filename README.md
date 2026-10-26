# kgcache

kgcache is an in-memory string cache built in Zig. It serves a tested subset
of Redis commands over RESP2 and RESP3. Use it to cache strings or binary
values, expire keys, and keep data across restarts with snapshots or an
append-only file.

kgcache is experimental. It fits local services and cache workloads that use
its [supported commands](docs/commands/README.md). Check the
[compatibility reference](docs/reference/compatibility.md) before connecting
an existing Redis application.

## Quick start

Start the Linux amd64 release with Docker:

```sh
docker run --detach --rm --name kgcache --platform linux/amd64 \
  --publish 127.0.0.1:6379:6379 --volume kgcache-data:/data \
  --stop-timeout 30 kgxlabs/kgcache:0.1.0
```

Use an installed `redis-cli` to write and read a value:

```sh
redis-cli SET greeting hello
redis-cli GET greeting
```

The replies are `OK` and `hello`. Run `docker stop kgcache` to stop the server.
The named volume keeps its data. See the [quick start](docs/get-started/README.md)
for a walkthrough, or [installation](docs/get-started/install.md) to build
from source. Arm64 hosts need amd64 emulation for this image.

## Documentation

- [Get started](docs/get-started/README.md): run a server and try commands.
- [Develop with kgcache](docs/develop/README.md): use strings, connect Go or
  Node.js, and send pipelines.
- [Operate kgcache](docs/operate/README.md): configure, store data, monitor,
  and stop a service.
- [Commands](docs/commands/README.md): syntax, examples, and replies for each
  supported command.
- [Reference](docs/reference/README.md): tested clients, protocol, limits,
  and configuration settings.

<a id="current-status-and-compatibility"></a>

The [compatibility reference](docs/reference/compatibility.md) describes the
current contract. kgcache has no authentication, TLS, eviction, replication,
or clustering. Keep the service on a trusted network.

These docs describe `main`. The image above contains the source recorded in
[v0.1.0](https://github.com/kgxlabs/kgcache/releases/tag/v0.1.0).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) to make a change. The
[contributor guides](docs/contribute/README.md) cover tests, architecture,
internal design, and release procedures.

## License

This repository does not currently include a license file.

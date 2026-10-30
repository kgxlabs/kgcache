<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/images/kgcache-transparent-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset=".github/images/kgcache-transparent-light.svg">
    <img src=".github/images/kgcache-transparent-light.svg" alt="kgcache logo" width="160" height="160">
  </picture>
</p>

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

Start kgcache with Docker:

```sh
docker run -d --name kgcache -p 127.0.0.1:6379:6379 kgxlabs/kgcache:latest
```

The image includes a default config. The port is limited to localhost because
kgcache has no authentication. The image supports Linux amd64. Arm64 hosts need
amd64 emulation; add `--platform linux/amd64` to select it explicitly.

Use an installed `redis-cli` to write and read a value:

```sh
redis-cli SET greeting hello
redis-cli GET greeting
```

The replies are `OK` and `hello`. Run `docker stop --timeout 30 kgcache` to stop
the server and `docker start kgcache` to start it again. Data stays in the
container. To keep data when replacing the container, use a
[named volume](docs/operate/docker.md#keep-data-when-replacing-a-container).
See the [quick start](docs/get-started/README.md) for a walkthrough, or
[installation](docs/get-started/install.md) to build from source.

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

These docs describe `main`. The image name selects the `latest` tag. Its
source and digest are recorded in the
[latest release](https://github.com/kgxlabs/kgcache/releases/latest).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) to make a change. The
[contributor guides](docs/contribute/README.md) cover tests, architecture,
internal design, and release procedures.

## License

This repository does not currently include a license file.

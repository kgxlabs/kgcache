# kgcache

An in-memory string cache built in Zig, with a tested subset of the Redis
RESP2 and RESP3 protocols.

Store string or binary values, set expiration times, and keep data across
restarts with snapshots or an append-only file. Use kgcache for local services,
development, and small cache workloads whose commands fit the
[compatibility contract](docs/user/compatibility.md).
There is no authentication, eviction, replication, or clustering.
See [limits](docs/user/limits.md) before choosing it for a workload.

## Try it

The published image below is a [release candidate](https://github.com/kgxlabs/kgcache/releases/tag/v0.1.0-rc.2)
for Linux amd64. Arm64 hosts need amd64 emulation.

```sh
docker run --rm --name kgcache --platform linux/amd64 \
  -p 127.0.0.1:6379:6379 -v kgcache-data:/data \
  --stop-timeout 30 kgxlabs/kgcache:0.1.0-rc.2
```

In another terminal, use an installed `redis-cli`:

```sh
redis-cli SET greeting hello
redis-cli GET greeting
redis-cli -3 GET greeting
```

The replies are `OK`, `hello`, and `hello`. Stop the service with
`docker stop kgcache`. The named volume keeps its data.
For a source build, see [getting started](docs/user/getting-started.md).

<a id="current-status-and-compatibility"></a>

## Use kgcache

| Task | Guide |
| --- | --- |
| Start from an image or source | [Getting started](docs/user/getting-started.md) |
| Run and operate a service | [Service guide](docs/user/service.md) |
| Connect an application | [Go and Node examples](docs/user/clients.md) |
| Check client versions and RESP support | [Compatibility](docs/user/compatibility.md) |
| Find commands and SET options | [Command reference](docs/user/commands.md) |
| Change settings | [Configuration](docs/user/configuration.md) |
| Choose restart and durability behavior | [Persistence](docs/user/persistence.md) |
| Assess unsupported features and limits | [Limits](docs/user/limits.md) |

The guides describe current `main`. A published image contains the behavior
of its release source. Check its release notes when using an older version.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks and PR guidance.
The [developer docs](docs/development/README.md) cover testing, architecture,
internal design, and release procedures. The [documentation index](docs/README.md)
links both audiences.

## License

No license file is currently included.

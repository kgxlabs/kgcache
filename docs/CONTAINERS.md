# Run kgcache with Docker Compose

The root [docker-compose.yml](../docker-compose.yml) builds a local Linux
amd64 service. It publishes port 6379 on host loopback and stores data in a
named volume.
The service has no authentication. Keep it on a trusted network.

## Prerequisites

Use Docker with Linux containers, BuildKit, and the Compose plugin. Compose
must support `config --format json` and `up --wait --wait-timeout`.
Check the installed tools with `docker version`, `docker buildx version`,
and `docker compose version`. Arm64 hosts need amd64 emulation; local
emulation does not qualify native amd64 execution.

Install host `redis-cli` for the connection examples. It is not included in
the service image. Go, Node, and Zig are not needed to build or run this example.
The first build downloads the pinned base image and compiler.

## Build, start, and connect

Run from the repository root:

```sh
docker compose config --quiet
docker compose build
docker compose up --wait --wait-timeout 120
docker compose ps
redis-cli -h 127.0.0.1 -p 6379 PING
redis-cli -h 127.0.0.1 -p 6379 SET compose-example:value hello
redis-cli -h 127.0.0.1 -p 6379 GET compose-example:value
redis-cli -h 127.0.0.1 -p 6379 DEL compose-example:value
docker compose logs --tail 100 kgcache
```

The replies are `PONG`, `OK`, `hello`, and `1`. Build explicitly before
starting: the local example uses `pull_policy: never`. Rebuild after changing
server source. Use `up` to replace a container when its image changes.

The startup command waits up to 120 seconds for the image health check.
Larger data replays may need a longer wait and health start period. A running
container may still be starting or unhealthy. A successful protocol probe
does not prove that writes reached durable storage.

If port 6379 is occupied, Compose fails to bind it. Inspect the existing
service before choosing another host port. Services in the same Compose
network connect to `kgcache:6379`, independently of the published host port.

## Stop, restart, and replace

```sh
docker compose stop
docker compose start
docker compose up --wait --wait-timeout 120
docker compose up --force-recreate --wait --wait-timeout 120
docker compose down
```

`stop` retains the container. `start` starts that stopped container; the next
`up --wait` waits for health. `--force-recreate` creates a new container using
the same volume. Ordinary `down` removes containers and the network but keeps
the named volume.

Keep the same Compose project name when reusing storage. By default, the
project name comes from the checkout directory. Moving or renaming it can
select a new volume. For a stable name, set `COMPOSE_PROJECT_NAME` before
every command, or pass the same `--project-name` each time.

Before rolling back across data-format changes, stop the service and keep
a separate copy of its data. Reusing a volume recovers its existing files.
It is not restoration from a backup. Do not mount one writable data directory
into concurrent kgcache instances.

### Reset all example data

The following command permanently deletes this project's data volume:

```sh
docker compose down --volumes
```

Use it only for an intentional reset. Do not use it to fix startup failures
or during ordinary upgrades.

## Image defaults

| Setting | Value |
| --- | --- |
| Executable | `/usr/local/bin/kgcache` |
| Config | `/etc/kgcache/kgcache.conf` |
| Data and working directory | `/data` |
| User and group | `10001:10001` |
| Internal listener | `0.0.0.0:6379` |
| Persistence | AOF enabled, `appendfsync everysec` |
| Periodic snapshots | Disabled with `save ""` |
| Shutdown snapshots | Enabled when AOF is off and data is dirty |

The image owns `/data` as UID/GID 10001. Docker initializes a fresh named
volume from the image directory. Existing volumes retain their permissions;
the service does not repair ownership at startup.

For a host bind mount, prepare a dedicated directory with access for that
identity. For example, on a Linux host:

```sh
sudo install -d -o 10001 -g 10001 -m 0750 /absolute/path/to/data
```

Replace the placeholder with your dedicated data directory. Avoid changing
ownership recursively on an unrelated parent. Docker Desktop binds pass
through its Linux VM, so host permissions can behave differently. Prefer
the default named volume unless you need host access to the files.

## Customize config

Settings apply in this order: built-in defaults, config file, then CLI
directives. Copy `containers/kgcache.conf` to `kgcache.local.conf` in the
repository root and edit it. Ensure UID 10001 can read it. Save this override
as `docker-compose.config.yml` next to the root Compose file:

```yaml
services:
  kgcache:
    volumes:
      - type: bind
        source: ./kgcache.local.conf
        target: /etc/kgcache/kgcache.conf
        read_only: true
        bind:
          create_host_path: false
```

```sh
docker compose -f docker-compose.yml -f docker-compose.config.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.config.yml up --wait --wait-timeout 120
```

Use both file arguments for later lifecycle commands too. A missing config
file fails instead of creating a directory. The server and inherited health
check read the same mounted file. If you change the internal port, update
the published mapping as well.

### Override the internal port on the command line

Supplying `command` replaces the image's default CMD, including its config
argument. Docker does not infer the health endpoint from that command.

After building the local image, save this complete deployment as
`docker-compose.port.yml` in the repository root. Run it by itself with
`docker compose -f docker-compose.port.yml up --wait --wait-timeout 120`:

```yaml
services:
  kgcache:
    image: kgcache:local
    pull_policy: never
    platform: linux/amd64
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    command: ["/etc/kgcache/kgcache.conf", "--port", "7000"]
    healthcheck:
      test:
        - CMD
        - /usr/local/bin/kgcache
        - healthcheck
        - /etc/kgcache/kgcache.conf
        - --port
        - "7000"
    ports:
      - "127.0.0.1:7000:7000"
    volumes:
      - kgcache-data:/data
    stop_grace_period: 30s
    mem_limit: 512m
    cpus: 1.0
volumes:
  kgcache-data:
```

This keeps the server, probe, and published port in agreement. Merging a new
port list into the base file can retain both mappings. Use this complete
file on its own. Connect from the host with `redis-cli -p 7000`.

## Persistence modes

Use supported settings in the shared config:

| Mode | Settings | Storage |
| --- | --- | --- |
| Default service | `appendonly yes`, `appendfsync everysec` | Persistent volume |
| Snapshot-only | `appendonly no`, `save ""`, `shutdown-save yes` | Persistent volume; saves dirty data on clean stop |
| Disposable cache | `appendonly no`, `save ""`, `shutdown-save no` | Fresh, dedicated storage |

These modes are separate from Compose `profiles`. Disabling automatic writes
does not erase existing files. With AOF off, startup still loads an existing
snapshot. Explicit `SAVE` and `BGSAVE` can still write snapshots. Use fresh
storage for disposable data without those commands.

`everysec` normally targets about one second of unflushed writes under normal
I/O progress. It is not a universal loss bound. A client acknowledgement does
not prove durable storage. A volume is neither a backup nor a failover system.
See [Persistence](PERSISTENCE.md), [AOF](AOF.md), and [Snapshots](SNAPSHOTS.md)
for recovery behavior and filesystem limits. Docker kill does not simulate
host power loss.

## Resource limits and shutdown

The Compose example uses one CPU and 512 MiB for a small development workload.
These are limits, not reserved capacity or application memory accounting.
There is no eviction policy. A workload that outgrows the limit can be killed
by the container runtime. Change `cpus` and `mem_limit` for your workload.

Compose allows 30 seconds for SIGTERM shutdown before forced termination.
The internal persistence child budget defaults to 10000 ms, followed by up
to 1000 ms for reaping after termination is requested. That budget does not
bound client draining, filesystem calls, or all cleanup. Review the outer
allowance when raising the budget or using slow storage. See
[AOF shutdown](AOF.md#shutdown) for the current lifecycle contract.

CPU, memory, storage, and stop timing belong in deployment configuration.
Host kernel settings, swap, storage latency, and file-descriptor limits need
assessment for the target machine. Containers share its Linux kernel;
Docker Desktop uses a Linux VM. The image does not change host settings.

## Health and restart behavior

Inspect health directly:

```sh
docker compose exec -T kgcache /usr/local/bin/kgcache healthcheck /etc/kgcache/kgcache.conf
docker inspect --format '{{json .State.Health}}' "$(docker compose ps -q kgcache)"
docker compose logs --tail 100 kgcache
```

The default probe checks RESP PING every 30 seconds, with a 2-second outer
timeout, a 60-second start period, and 3 retries. Adjust startup timing for
large replays. Endpoint changes must apply to both server and probe.

The local example has no restart policy. For an unattended service, an
operator can add `restart: unless-stopped` under `services.kgcache`.
Restart policies respond to process exits, not an unhealthy status alone.
Repeated config or permission failures need correction. Inspect the logs,
run `docker compose stop`, fix the cause, and start the service again.

Dependent Compose applications can use `depends_on` with
`condition: service_healthy`. Applications still need connection retries
for later disconnects.

## Troubleshooting and tests

Start with logs, config and health arguments, data permissions, and inner
versus outer timeout settings. Preserve the volume while investigating.

See [container checks](../tests/container/README.md) for the qualification
command, failure artifacts, and CI usage.

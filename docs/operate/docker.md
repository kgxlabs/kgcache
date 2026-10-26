# Run with Docker and Compose

[Docs](../README.md) / [Operate](README.md) / Docker

Use the published image for a quick trial, or build the checked-out source
with Compose. Both use a persistent data directory at `/data`.
The [quick start](../get-started/README.md) provides the published-image command.

## Build the local service

Install Docker with Linux containers, BuildKit, and the Compose plugin. These
commands require Compose support for `config --format json` and
`up --wait --wait-timeout`. Install host `redis-cli` for connection checks.
The build downloads its pinned base image and Zig compiler; host Zig is not needed.

From the checkout root, run:

```sh
docker compose config --quiet
docker compose build
docker compose up --wait --wait-timeout 120
docker compose ps
redis-cli PING
```

Expected reply: `PONG`. The root [docker-compose.yml](../../docker-compose.yml)
builds `kgcache:local` for Linux amd64, publishes host loopback port 6379, and
mounts a named volume. Arm64 hosts need amd64 emulation. Rebuild explicitly
after a source change because the service uses `pull_policy: never`.

The startup wait uses the image's health check. A large data replay may need
a longer wait and a longer health start period.

## Understand the image layout

| Item | Value |
| --- | --- |
| Executable | `/usr/local/bin/kgcache` |
| Default config | `/etc/kgcache/kgcache.conf` |
| Working directory and data | `/data` |
| User and group | `10001:10001` |
| Container listener | `0.0.0.0:6379` |
| Default persistence | AOF with `appendfsync everysec` |
| Health check | PING, every 30 seconds, 2-second outer timeout |
| Startup allowance | 60 seconds before failed probes count |
| Health failure threshold | 3 failed probes |

The image owns `/data` as UID/GID 10001. Docker initializes a new named volume
from that directory. Existing volumes retain their permissions. The image
does not repair their ownership at startup.

For a bind-mounted data directory on Linux, prepare a dedicated path:

```sh
sudo install -d -o 10001 -g 10001 -m 0750 /absolute/path/to/data
```

Docker Desktop uses a Linux VM, so host permissions can differ. A named volume
is the simpler default for the examples.

## Use a config file

Copy `containers/kgcache.conf` to `kgcache.local.conf` in the checkout root.
Edit the copy and make it readable by UID 10001. Save this override as
`docker-compose.config.yml` beside the root Compose file:

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

Use both `-f` arguments for later commands too. A missing config fails instead
of creating a directory. The server and health command read the same file.

If you change the container port, also change the published mapping and health
endpoint. A command override replaces the image's whole CMD, including its
config argument. Docker does not infer a health endpoint from that override.
To try a different internal port without changing the Compose example:

```sh
docker run --detach --rm --name kgcache-port --platform linux/amd64 \
  --publish 127.0.0.1:7000:7000 --volume kgcache-port-data:/data \
  --stop-timeout 30 \
  --health-cmd 'kgcache healthcheck /etc/kgcache/kgcache.conf --port 7000' \
  kgxlabs/kgcache:0.1.0-rc.2 /etc/kgcache/kgcache.conf --port 7000
redis-cli -p 7000 PING
```

Stop it with `docker stop kgcache-port`. The server, health command, and port
mapping now agree. This example uses its own data volume.

## Stop, restart, or replace

```sh
docker compose stop
docker compose start
docker compose up --wait --wait-timeout 120
docker compose up --force-recreate --wait --wait-timeout 120
docker compose down
```

`stop` keeps the container. `start` restarts it. `up --force-recreate` replaces
it while reusing storage. `down` removes containers and the network, but keeps
the volume. Keep the same Compose project name to select the same volume.
Set `COMPOSE_PROJECT_NAME` or use the same `--project-name` on every invocation
when the checkout directory name may change.

To deliberately erase the example's data, run `docker compose down --volumes`.
This deletes the volume permanently. Preserve data while investigating failures.
Do not attach one writable data directory to multiple running servers.

## Set resource and stop limits

The local example limits the container to one CPU and 512 MiB. These are
container limits, not a server eviction policy. The OS can kill the process
when it runs out of memory. Size the service for its data, connections, and
persistence copy-on-write cost.

Compose allows 30 seconds for a clean stop. Read
[Shutdown and restart](shutdown.md) before changing that allowance or the
internal persistence budget. A container restart policy acts on process exit;
an unhealthy status alone does not restart the process. The example has no
restart policy. An operator can add `restart: unless-stopped` for unattended use.

## Inspect the service

```sh
docker compose logs --tail 100 kgcache
docker compose exec -T kgcache /usr/local/bin/kgcache healthcheck /etc/kgcache/kgcache.conf
docker inspect --format '{{json .State.Health}}' "$(docker compose ps -q kgcache)"
```

See [Health and monitoring](monitoring.md) for probe behavior and connection
reports. The [container test guide](../../tests/container/README.md) describes
automated volume, PID 1, shutdown, and native-client checks.

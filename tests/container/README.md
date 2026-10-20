# Container image checks

Requires Bash 3.2 or newer, Docker with Linux containers, GNU `timeout`, jq,
and standard Unix tools. Compose must support `config --format json`,
`up --wait --wait-timeout`, and `port`. Source builds also need BuildKit.
The runner checks these prerequisites before creating resources.

For operator instructions, see [Docker Compose](../../docs/CONTAINERS.md).
Build and qualify from the repository root:

```sh
bash tests/container/run.sh --build --artifacts test-artifacts/container
```

The source path derives a deployment from `docker-compose.yml`, builds under
a unique tag, and resolves its image ID once. Builds have a separate
10-minute deadline. To qualify an already loaded image without rebuilding
or pulling it implicitly:

```sh
bash tests/container/run.sh --image IMAGE \
  --artifacts test-artifacts/container
```

Replace `IMAGE` with a local tag, image ID, or already pulled digest reference.
Every Compose service must use the resolved image ID. Registry manifest
digests and local image IDs are recorded separately. The Dockerfile supplies
the pinned base and checks it against the release
settings. Local builds read the package version from `build.zig.zon`. They
record `SOURCE_REVISION=unknown` and `SOURCE_DIRTY=true` by default. The image
version label stays empty unless `VERSION` is supplied; the build record always
contains the package version.

Release CI verifies a clean checkout, then supplies `SOURCE_REVISION`,
`SOURCE_DIRTY=false`, and `VERSION`. Clean builds require a full Git revision
and a version that matches the package. Invalid metadata and a base that differs
from the release settings fail the build. Development images cannot qualify
as clean release candidates. CI checks both build paths.

An arm64 Docker engine needs `--allow-emulation` on the runner. Emulated
results do not qualify native amd64 execution. The runner records the resolved
image ID and build record. It never publishes an image.

The image starts directly as UID/GID 10001 with `/data` as its working
directory. Mount storage at `/data`. Its config enables AOF with
`appendfsync everysec`. No anonymous volume is declared.

## Health check

The image declares this exec-form health command:

```dockerfile
HEALTHCHECK --interval=30s --timeout=2s --start-period=60s --retries=3 CMD ["/usr/local/bin/kgcache", "healthcheck", "/etc/kgcache/kgcache.conf"]
```

The command sends RESP2 PING with one 1000 ms network deadline. Exact PONG
exits 0 silently. Failures exit 1 with one short diagnostic. It needs no
redis-cli, curl, netcat, or shell probe. PONG checks basic response; it does
not verify fsync, disk durability, free capacity, or data integrity.

Docker starts health status at `starting`. A successful probe makes it
`healthy`. Before the first success, failures during the 60-second start
period do not count toward the three failures needed for `unhealthy`.
After a success, later failures count even during that period. Increase the
start period for larger replay workloads. Keep the outer timeout above the internal network
deadline; it also covers process startup and config loading. See
[Docker health timing](https://docs.docker.com/reference/dockerfile/#healthcheck).

Prefer a read-only config mount at `/etc/kgcache/kgcache.conf` when changing
the bind or port. Both processes then read the same endpoint. Wildcard bind
`0.0.0.0` probes `127.0.0.1`. Use a concrete internal port even when Docker
publishes an ephemeral host port.

Changing CMD does not change the health command. If the server uses another
config path or endpoint overrides, update the health command to match. For
example, this Compose fragment pairs both port overrides:

```yaml
services:
  kgcache:
    image: kgcache:local
    command: ["/etc/kgcache/kgcache.conf", "--port", "7000"]
    volumes:
      - data:/data
    healthcheck:
      test: ["CMD", "/usr/local/bin/kgcache", "healthcheck", "/etc/kgcache/kgcache.conf", "--port", "7000"]
      interval: 30s
      timeout: 2s
      start_period: 60s
      retries: 3
volumes:
  data:
```

See [Compose health overrides](https://docs.docker.com/reference/compose-file/services/#healthcheck).
The probe does not discover another process's CLI settings. A mismatched
port fails when no service responds there. Health status alone does not
identify the intended server if another service responds on that endpoint.

## Runner coverage

The runner uses Docker-assigned loopback ports, a read-only root, and mounted
storage. Binary RESP data stays in files and is compared with `cmp`.
Resources carry a unique run label. Docker commands and network operations
have deadlines. A full run has a 30-minute deadline plus cleanup time.
The runner collects bounded logs and state before removing
its resources, including after interruption. `--artifacts` preserves evidence.

The suite covers replacement, fresh volumes, bind ownership, read-only storage,
invalid config, storage errors during stop, and abrupt recovery with AOF
`always`, an established `everysec` durable prefix, and a saved snapshot.
It repeats BGSAVE and AOF rewrite and checks that only PID 1 remains after
completion. Active-child stop cases briefly pause a real child with SIGSTOP,
send SIGTERM to PID 1, then resume the child. Idle and slow clients stay connected.

Health cases inspect the exact command and timing, observe `starting` and
`healthy`, and check a mounted config with a different port. A gated replay
fixture proves startup failures stay within the allowance before loading
existing AOF data. A stopped PID 1 leaves a TCP listener open while probes
time out, become `unhealthy`, and recover after SIGCONT. The Compose test
fixture checks paired and mismatched command/health overrides. Shutdown
checks also require a bounded failed probe while a persistence child settles.
Fixture gates and signal controls are only in the test runner.

The bounded workload uses 4,096 keys with 4 KiB values, one CPU, and a 256 MiB
container limit. Results record image size, startup and replay wall time,
mean time for 64 sequential PING round trips, and cgroup v2 memory peaks.
Timing includes the Bash client startup. These are workload measurements.
The container limit does not add application memory accounting or eviction.

Build `--target diagnostic` to add ELF and process inspection tools. The final
runtime has no compiler or test server. Normal startup does not use a shell.

## Compose coverage

The same command runs the existing image/health suite and Compose checks
against one image. Compose variants come from the checked-in model. Tests
cover service-name DNS from a peer, inherited security and resource settings,
host access, config mounts, paired port overrides,
stop/start, replacement, snapshot-only and disposable modes, missing/invalid
config, parallel projects, and occupied host ports.

Cleanup checks resource ownership and removes only this run's resources,
including its test volumes. User volumes remain untouched. Failure artifacts
include resolved deployments, image/platform and Docker versions,
health history, exit/OOM state, and relevant persistence evidence.

## Exact guide check and CI handoff

In an isolated environment, also exercise the literal `docker-compose.yml`
and guide commands with fixed host port 6379:

```sh
bash tests/container/run.sh --build --guide --artifacts test-artifacts/container
```

This mode requires host `redis-cli` and refuses an existing `kgcache:local`
tag. It builds that tag through the checked-in file. A unique project name
keeps containers, networks, and volumes scoped to the check. Ordinary local
qualification uses unique tags and engine-assigned loopback host ports.

Use `--image` after importing a candidate or pulling a registry digest.
The qualification command never publishes an image.

Follow the [shell style](../../tools/shell/README.md). Run `make fmt-shell`
and `make check-shell` after editing scripts.

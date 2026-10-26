# Qualify a container image

[Contributor guide](../../docs/contribute/testing.md) / Container checks

Run the container suite after changing the image, deployment, health command,
persistence lifecycle, or endpoint smoke tests. It builds or accepts one image,
then tests that exact image through isolated Docker and Compose resources.
For service use, read [Run with Docker](../../docs/operate/docker.md).

## Prepare the host

Use macOS or Linux with Bash 3.2 or newer, Linux containers, Docker Buildx,
GNU `timeout`, jq, Make, and standard Unix tools. Source builds need BuildKit.
Compose must support `config --format json`, `up --wait --wait-timeout`, and
`port`.

Prepare the Go, Node, and npm pins in the
[client registry](../integration/clients/matrix.json). The runner prefers
`.client-tools/go/bin` and `.client-tools/node/bin` when available. It checks
prerequisites before creating resources. Locked dependency setup can use the
network, in isolated profile workspaces.

Native qualification requires a Linux amd64 Docker engine. On an arm64
machine with amd64 emulation, add `--allow-emulation`. The result records the
actual engine and cannot qualify native execution through emulation.

## Build and test the source image

From the repository root:

```sh
bash tests/container/run.sh --build --artifacts test-artifacts/container
```

The runner derives its deployment from [docker-compose.yml](../../docker-compose.yml),
builds a unique local tag with a separate 10-minute build deadline, and resolves
the image ID once. Compose services then use that ID.

Local builds use the package version and default source metadata
`SOURCE_REVISION=unknown`, `SOURCE_DIRTY=true`. Their version label is empty
unless `VERSION` is supplied. An explicit version changes the binary, record,
and label; `development_version` still records the package default.

A clean image requires an explicit valid SemVer and full source revision with
`SOURCE_DIRTY=false`. Build checks reject invalid metadata or a runtime base
that differs from [release settings](../../tools/release/settings.sh).
Development metadata cannot qualify a clean release image. See
[build versions](../../docs/contribute/building.md).

## Test an existing image

Import or pull the intended image first, then supply its local reference:

```sh
bash tests/container/run.sh --image IMAGE \
  --artifacts test-artifacts/container
```

`IMAGE` can be a local tag, ID, or already pulled digest reference. The runner
neither rebuilds it nor pulls a replacement implicitly. It records registry
manifest digests separately from local image IDs and never publishes an image.
Use this path after [candidate import](../../docs/contribute/release-candidates.md)
or a clean registry pull.

## Test the literal guide commands

In an isolated environment with host port 6379 free:

```sh
bash tests/container/run.sh --build --guide --artifacts test-artifacts/container
```

This mode additionally needs host `redis-cli`. It refuses an existing
`kgcache:local` tag and builds that tag through the checked-in Compose file.
A unique project name scopes its containers, networks, and volumes. Ordinary
qualification uses unique tags and Docker-assigned loopback host ports.

## Understand the checks

| Area | Required observations |
| --- | --- |
| Layout and identity | Executable version, build record, OCI label, platform, and resolved image agree |
| Isolation | UID/GID 10001, `/data`, read-only root, mounted storage, and inherited security/resource settings |
| Persistence | Replacement/restart, fresh volume, bind ownership, snapshot/AOF recovery, and stop-time errors |
| Process lifecycle | PID 1, idle and slow clients, repeated BGSAVE/rewrite, child reaping, and active-child SIGTERM |
| Health | Declared command/timing, startup allowance, healthy/unhealthy transitions, and endpoint overrides |
| Compose | Peer DNS, host access, config mounts, stop/start/replacement, parallel projects, and occupied ports |
| Clients | Baseline Go and Node smoke checks against the prepared endpoint |

The image uses AOF `everysec`, runs directly without a startup shell, and
declares no anonymous volume. The layout check saves `version.log` after
comparing the executable and record. An empty development OCI label is valid
only when the binary and record use the package default.

Recovery includes AOF `always`, an established `everysec` durable prefix,
and a saved snapshot. Abrupt-stop cases do not simulate host power loss.
Repeated persistence operations must leave only PID 1 after completion.
Active-child tests pause a real child with SIGSTOP, signal PID 1 with SIGTERM,
then resume the child while connected clients remain open.

The bounded workload uses 4096 keys with 4 KiB values, one CPU, and a 256 MiB
container limit. It records image size, startup/replay time, mean time for
64 sequential PING round trips, and cgroup v2 memory peaks. Timing includes
Bash client startup. These are workload measurements, not a general performance
or memory-eviction guarantee.

### Health behavior

The image's exec probe runs the built-in health command. It requires exact
PONG within a shared 1000 ms network deadline, exits 0 silently on success,
and exits 1 with one short diagnostic on failure. No redis-cli or shell probe
is installed for normal health checking.

The declared Docker timing is 30-second intervals, a 2-second outer timeout,
a 60-second start period, and 3 retries. The suite checks `starting` and
`healthy`, delayed startup replay, later `unhealthy`, and recovery after a
paused PID 1 resumes. It also checks a failed bounded probe during shutdown.

Paired command/health endpoint changes must succeed; mismatched changes must
fail when no service answers there. The probe does not discover another
process's CLI overrides. PONG proves protocol response, not durable writes or
the identity of a service sharing the endpoint. See
[monitoring](../../docs/operate/monitoring.md) for operator use.

### Client endpoints

The runner's baseline clients test default, RESP2, and RESP3 handshakes, binary
values, nontransactional pipelines, and command-error recovery. The caller owns
the server. The full version matrix remains in native client CI.

To test another caller-owned endpoint:

```sh
export KGCACHE_SMOKE_HOST=127.0.0.1
export KGCACHE_SMOKE_PORT=6379
make smoke-go CLIENT_PROFILE=go-redis-v9.22.0
make smoke-node CLIENT_PROFILE=node-redis-6.2.1
```

Programs use unique keys, close their clients, and bound network work. Profile
installation and compilation have separate runner deadlines.

## Read evidence and cleanup results

Use `--artifacts DIR` to preserve each run's deployments, image/platform and
Docker versions, client logs, health history, exit/OOM state, and useful
persistence evidence. Binary RESP values remain files and are compared with
`cmp`, rather than being stored in shell variables.

The full suite has a 30-minute deadline plus cleanup time. Docker and network
commands are also bounded. Resources have a unique run label. The runner
collects state before removing only its own containers, networks, and test
volumes, including after interruption. User volumes remain untouched.

For ELF/process inspection, build the `diagnostic` target. The runtime target
has no compiler or test server. The required **Native Linux amd64 release on
Bookworm** job runs both guide and prepared-image paths.

For script edits, follow [shell conventions](../../tools/shell/README.md),
then run `make fmt-shell` and `make check-shell`.

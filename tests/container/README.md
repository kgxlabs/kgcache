# Container image checks

Requires Bash 3.2 or newer, Docker with BuildKit, GNU `timeout`, jq, and
standard Unix file tools. Build from the repository root:

```sh
docker build --platform linux/amd64 --tag kgcache:local .
bash tests/container/run.sh --image kgcache:local \
  --artifacts test-artifacts/container
```

The Dockerfile supplies the pinned base and checks it against the release
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
`appendfsync everysec`. No anonymous volume or health check is declared.

The runner uses Docker-assigned loopback ports, a read-only root, and mounted
storage. Binary RESP data stays in files and is compared with `cmp`.
Resources carry a unique run label. Docker commands and network operations
have deadlines. A full run has a 15-minute deadline plus cleanup time.
The runner collects bounded logs and state before removing
its resources, including after interruption. `--artifacts` preserves evidence.

The suite covers replacement, fresh volumes, bind ownership, read-only storage,
invalid config, storage errors during stop, and abrupt recovery with AOF
`always`, an established `everysec` durable prefix, and a saved snapshot.
It repeats BGSAVE and AOF rewrite and checks that only PID 1 remains after
completion. Active-child stop cases briefly pause a real child with SIGSTOP,
send SIGTERM to PID 1, then resume the child. Idle and slow clients stay connected.

The bounded workload uses 4,096 keys with 4 KiB values, one CPU, and a 256 MiB
container limit. Results record image size, startup and replay wall time,
mean time for 64 sequential PING round trips, and cgroup v2 memory peaks.
Timing includes the Bash client startup. These are workload measurements.
The container limit does not add application memory accounting or eviction.

Build `--target diagnostic` to add ELF and process inspection tools. The final
runtime has no compiler or test server. Normal startup does not use a shell.

Follow the [shell style](../../tools/shell/README.md). Run `make fmt-shell`
and `make check-shell` after editing scripts.

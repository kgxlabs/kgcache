# Container image checks

Requires Bash 3.2 or newer, Docker with BuildKit, GNU `timeout`, jq, and
standard Unix file tools. Build from a clean checkout:

```sh
source tools/release/settings.sh
docker build --platform linux/amd64 \
  --build-arg "RUNTIME_BASE=$RUNTIME_BASE" \
  --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  --build-arg SOURCE_DIRTY=false \
  --build-arg VERSION=0.0.0 --tag kgcache:local .
bash tests/container/run.sh --image kgcache:local \
  --artifacts test-artifacts/container
```

For uncommitted changes, keep the default `SOURCE_DIRTY=true`.
An arm64 Docker engine needs `--allow-emulation` on the runner. Emulated
results do not qualify native amd64 execution. The runner records the resolved
image ID and build record. It never publishes an image.

The image starts directly as UID/GID 10001 with `/data` as its working
directory. Mount storage at `/data`. Its config enables AOF with
`appendfsync everysec`. No anonymous volume or health check is declared.

The runner uses Docker-assigned loopback ports, a read-only root, and mounted
storage. Binary RESP data stays in files and is compared with `cmp`.
Resources carry a unique run label. Docker commands and network operations
have deadlines. The runner collects bounded logs and state before removing
its resources, including after interruption. `--artifacts` preserves evidence.

Build `--target diagnostic` to add ELF and process inspection tools. The final
runtime has no compiler or test server. Normal startup does not use a shell.

Follow the [shell style](../../tools/shell/README.md). Run `make fmt-shell`
and `make check-shell` after editing scripts.

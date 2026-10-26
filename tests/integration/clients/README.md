# Run real-client compatibility tests

[Contributor guide](../../../docs/contribute/testing.md) / Client suites

The Go and Node suites execute real library APIs against a spawned kgcache.
Use them after changing commands, handshakes, connection lifecycle, or shared
client fixtures. The exact required versions and API suites are documented in
[compatibility](../../../docs/reference/compatibility.md).

## Install the pinned tools

Use Zig 0.16.0, Go 1.26.9, Node 22.14.0, and Node's bundled npm 10.9.2. Put the
runtimes on PATH. Launchers verify them and never download a runtime.

Alternatively, unpack official runtime distributions into ignored directories
`.client-tools/go` and `.client-tools/node` at the repository root. Make prepends
their `bin` paths. This leaves global tools unchanged. Verify that local setup:

```sh
.client-tools/go/bin/go version
.client-tools/node/bin/node .client-tools/node/lib/node_modules/npm/bin/npm-cli.js --version
```

Dependency preparation uses committed locks and can need network access.
[matrix.json](matrix.json) maps profiles to exact clients, runtimes, API suites,
and dependency directories. A compatible version can share a suite, but keeps
its own locks. No command discovers or upgrades a client version.

## Run a suite

From the repository root:

```sh
make test-go
make test-node
```

Each target builds a Debug server, prepares dependencies, and runs every required
profile for that language. Full API cases use explicit RESP2 and RESP3.
Separate handshake and CLIENT INFO cases require default RESP3 with identity
reporting enabled.

For Zig plus both languages, use `make test`. It attempts every group and exits
nonzero if any group fails. `make test-zig` selects just the Zig groups.

Select a profile or library:

```sh
make test-go CLIENT_PROFILE=go-redis-v9.22.0
make deps-node CLIENT_LIBRARY=node-redis
make test-go CLIENT_PROFILE=go-redis-v9.22.0 GO_TEST_ARGS='-run TestHandshake'
make test-node CLIENT_PROFILE=node-redis-6.2.1 NODE_TEST_ARGS='--testPathPatterns=pipeline'
```

Use selectors on individual language targets. Aggregate targets cover both
required language sets. Unknown profiles, conflicting selectors, and wrong-
language selections fail. Empty or fixture-only test selections also fail
because they execute no real client case.

## Check code and dependencies

```sh
make deps-clients
make list-clients
make check-clients
```

`deps-go` and `deps-node` prepare one language. Node preparation also installs
the root's locked quality tools. `check-go` runs gofmt checks and go vet.
`check-node` runs strict TypeScript, local ESLint, and Prettier. Apply formatting
with `make fmt-go` or `make fmt-node`. To select another Go executable, use
`make GO=/absolute/path/to/go check-go`.

Every profile runs in a temporary copy of its API suite and shared fixture,
with that profile's locked dependencies. Resolved client versions are verified.
The workspace is removed after success, failure, or cancellation, while
artifacts remain outside it. Baseline manifests and locks stay unchanged.

The standard-library launchers support `list`, `validate`, `deps`, `test`, and
`smoke`, with `--profile ID` or `--library NAME`:
[Go launcher](go/run.go) and [Node launcher](node/run.ts).

## Inspect failures

Set `KGCACHE_TEST_ARTIFACT_DIR=test-artifacts` to retain evidence. Make resolves
that path and supplies an absolute `KGCACHE_BIN` before entering suite folders.
Go retains bounded native output plus config, server logs, exits, and persistence
files. Node retains Jest results and bounded bundles, then removes fixture data.

Cases cover binary strings, SET conditions/expiration, databases, reports,
pipelines, command errors, snapshot restart, background replies, pools,
reconnection, concurrency, isolation, and connected-client shutdown. Use a
focused native filter after reading the failed case and logs.

## Use the native test command

From `go/go-redis/v9`, after dependency setup:

```sh
KGCACHE_BIN=/absolute/path/to/kgcache GOTOOLCHAIN=local GOWORK=off \
  go test -mod=readonly -count=1 -timeout=5m ./...
```

Go runs shared fixture checks before client cases and disables test caching.
From `node/node-redis/v6`, direct `npm test` is also usable with the absolute
`KGCACHE_BIN` supplied. Keep the pinned runtime and committed locks in both paths.

## Check an existing endpoint

The smoke action borrows a server owned by its caller:

```sh
export KGCACHE_SMOKE_HOST=127.0.0.1
export KGCACHE_SMOKE_PORT=6379
make smoke-go CLIENT_PROFILE=go-redis-v9.22.0
make smoke-node CLIENT_PROFILE=node-redis-6.2.1
```

Programs use unique keys, bounded network deadlines, and closed clients. They
check default, RESP2, and RESP3 setup. The [container runner](../../container/README.md)
uses them against its prepared image. Full version-matrix execution stays in
[client CI](../../../.github/workflows/client-tests.yml), gated by
[Zig checks](../../../.github/workflows/zig-tests.yml). The
[weekly workflow](../../../.github/workflows/weekly-client-compatibility.yml)
reuses the same registry and tests with separate status names.

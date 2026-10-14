# Client test projects

The node-redis v6 suite runs real clients against kgcache with explicit RESP2 and
RESP3, plus a default handshake check. It covers strings and binary values,
database selection, client reports, SET options and expiration, ordered pipelines,
command errors, snapshot reload, and background persistence replies.
The go-redis v9 suite remains planned and runs its bootstrap placeholder.

Use Go 1.26.9 and Node 22.14.0 with its bundled npm 10.9.2. Put those tools on
`PATH`. The launchers check installed versions and never download runtimes.
The server build and Zig tests need only Zig 0.16.0.

You can also unpack the official Go distribution into `.client-tools/go` and
the official Node distribution into `.client-tools/node` at the repository root.
Make prepends their `bin` directories to `PATH`, including Node's bundled npm.
This ignored local setup leaves global tools and shell settings unchanged.
Verify Go with `.client-tools/go/bin/go version` and bundled npm with
`.client-tools/node/bin/node .client-tools/node/lib/node_modules/npm/bin/npm-cli.js --version`.

Run all test groups from the repository root:

```sh
make test
```

This runs Zig unit and process tests, plus the Go and Node client test targets.
Client targets build the server and prepare their pinned dependencies before
execution. Every test group is attempted even if another group fails. The command
returns a nonzero result when any test group fails.

Select one test group with `make test-zig`, `make test-go`, or `make test-node`.

Run individual steps with:

```sh
make build
make test-unit test-integration
make deps-clients
make list-clients
make check-clients
```

`deps-go` and `deps-node` prepare one language independently. `deps-node` also
installs the Node root's locked quality tools. `check-go` checks gofmt and go vet;
`check-node` runs strict TypeScript checks, local ESLint, and Prettier.
`fmt-go` and `fmt-node` apply formatting.
An alternate Go executable can be selected with `make GO=/path/to/go check-go`.

`test-go` and `test-node` build the
Debug server and prepare dependencies. [Client CI](../../../.github/workflows/client-tests.yml)
has separate Go and Node jobs after [unit and process integration tests](../../../.github/workflows/zig-tests.yml)
pass. Node CI runs its pinned compatibility profile and
uploads failure evidence.

Select a registered profile or filter required profiles by library:

```sh
make deps-go CLIENT_PROFILE=go-redis-v9.22.0
make deps-node CLIENT_LIBRARY=node-redis
make test-go CLIENT_PROFILE=go-redis-v9.22.0
make test-node CLIENT_PROFILE=node-redis-6.2.1 NODE_TEST_ARGS='--testPathPatterns=pipeline'
```

The Node example selects its pipeline cases. Conflicting
selectors, unknown profiles, and profiles for the wrong language fail. Default
language commands select all required profiles. Use selectors with individual
language commands; aggregate commands cover both required language sets.

Each native launcher accepts `list`, `validate`, `deps`, or `test`, followed by
`--profile ID` or `--library NAME`. Go's launcher uses only Go's standard library,
and Node's launcher uses only Node's standard library.

The Makefile supplies an absolute `KGCACHE_BIN` for the built server. Set
`KGCACHE_TEST_ARTIFACT_DIR=test-artifacts` to retain diagnostics;
the Makefile resolves it before entering suite directories. Node retains Jest
results and bounded failure bundles, then removes each fixture's temporary data.
Fixture-only and empty Node selections fail because they execute no client cases.
Direct `npm test` is usable from `node/node-redis/v6` with an absolute `KGCACHE_BIN`
supplied by the caller.

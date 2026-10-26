# Test a change

[Docs](../README.md) / [Contribute](README.md) / Testing

Choose the smallest test layer that exercises the behavior, then run the checks
required for the changed area. Run commands from the repository root with
Zig 0.16.0.

## Run the core checks

```sh
zig fmt --check build.zig build.zig.zon src tests
zig build
zig build test
zig build test-integration
```

Unit tests cover in-process behavior. Process tests start an executable and
check real TCP replies, files, exits, and restarts. Both must pass before the
required client jobs run.

| Layer | Command or guide | Main purpose |
| --- | --- | --- |
| Unit | `zig build test` | Decoding, exact reply bytes, commands, storage, ownership, and persistence failures |
| Process | `zig build test-integration` | Framing, config, protocol negotiation, restart, health, and shutdown |
| Real clients | [Client runner](../../tests/integration/clients/README.md) | Registered Go and Node API suites with exact dependencies |
| Build | [Build checks](../../tests/build/README.md) | Native defaults, version inputs, and foreign execution guards |
| Containers | [Container runner](../../tests/container/README.md) | Image identity, health, volumes, PID 1, and client endpoints |
| Releases | [Release checks](../../tests/release/README.md) | Exact artifacts, qualification, transfer, and publication logic |
| Shell | `make check-shell` | ShellCheck and shfmt through pinned tool images |

`make test` attempts the Zig, Go, and Node groups and reports any failed group.
It does not run every row above. Use the [compatibility reference](../reference/compatibility.md)
for the link between public claims and automated coverage.

## Add a Zig test

The unit root is [src/tests.zig](../../src/tests.zig). It imports the source and
test modules whose tests run under `zig build test`. Add a new test module there
once. Keep a direct source import when that source still has inline tests.

Use inline tests for a small local behavior or a private declaration. Put a
larger group in a nearby `*_tests.zig` file when that keeps the implementation
readable. One module can use both forms. There is no required size threshold.

For example, [mem_store_tests.zig](../../src/store/mem_store_tests.zig) imports
the memory store it tests. AOF has private inline tests and public journal tests
in [aof_tests.zig](../../src/persistence/aof_tests.zig). Both modules remain in
the unit root. Private cron tests stay in [cron.zig](../../src/cron.zig).

`zig test src/example.zig` follows only that file's imports. It does not replace
the project test root when related tests live elsewhere.

## Keep fixtures close to their owner

Test through replies, state changes, interfaces, and errors where practical.
Do not make a production declaration public only to move a test.

Put a component's fixture next to its tests. Use a nearby helper when inline
and separate tests share it, as with
[aof_test_helpers.zig](../../src/persistence/aof_test_helpers.zig). Use
[src/tests/helpers.zig](../../src/tests/helpers.zig) for fixtures shared across
component boundaries. Keep test-only imports with their callers.

Split production code around a responsibility and a useful interface. A large
number of tests alone is not a reason to split it.

## Add a process or client case

Use the existing [process fixture](../../tests/integration/harness/README.md)
or the language's shared client fixture. Each test owns its child, temporary
data, and port. Keep network operations and cleanup bounded. Reap the child on
success, failure, and cancellation.

Set `KGCACHE_TEST_ARTIFACT_DIR` to retain failed configs, logs, exits, and useful
persistence evidence. A test that needs a live endpoint must use the reported
READY address instead of guessing a port.

The client registry is [matrix.json](../../tests/integration/clients/matrix.json).
Add an exact profile and locks through review. Compatible client versions can
share an API suite. A new suite must preserve older required profiles unless
an explicit support decision retires them.

## Move tests without losing coverage

Record the passing result and tests being moved first. Preserve test names,
assertions, setup, and cleanup through each extraction. After a small move,
run formatting, `zig build test`, `zig build`, and `git diff --check`.

Confirm that the unit root still reaches every moved test and every remaining
inline test. Explain an intentional coverage change separately from a file move.

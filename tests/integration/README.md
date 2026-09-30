# Process integration tests

Run `zig build test-integration` to build kgcache and run the Zig integration runner. `zig build test` remains the unit suite. The runner calls suite files in `tests/integration/suites/`. The PING smoke suite starts kgcache with isolated data, checks the exact PONG reply over TCP, then sends SIGTERM and reaps the process.

## Planned baseline cases

The first case is implemented. Add the remaining cases in later steps:

1. SET a small value and GET returns it.
2. SELECT another database and confirm the value is isolated.
3. Invalid configuration exits with status 1 and no READY signal.
4. Several idle clients remain connected while SIGTERM shuts down cleanly.
5. Stop and restart on the same selected port, then connect again.
6. Run two servers at once with separate ports and data directories.

Each case must check replies or exit status from a real kgcache process. The harness must reap every child on success and failure.

# Process integration tests

Run `zig build test-integration` to build kgcache and run the Zig integration runner. `zig build test` runs the unit suite. The runner calls suite files in `tests/integration/suites/`. The PING smoke suite checks the exact PONG reply over TCP.

The process harness in `tests/integration/harness/` owns each child from start through reaping. It enforces deadlines, captures bounded logs, and removes the fixture's temporary data. Set `KGCACHE_TEST_ARTIFACT_DIR` to keep a failed fixture's config and logs. The harness suite checks bad startup, malformed READY, timeouts, restarts, port conflicts, and two live servers.

## Planned baseline cases

Add these behavior cases in later steps:

1. SET a small value and GET returns it.
2. SELECT another database and confirm the value is isolated.
3. Several idle clients remain connected while SIGTERM shuts down cleanly.

Each case must check replies or exit status from a real kgcache process. The harness must reap every child on success and failure.

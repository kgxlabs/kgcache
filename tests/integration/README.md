# Process integration tests

Run `zig build test-integration` to build kgcache and run this separate Zig runner. `zig build test` remains the unit suite. The runner currently checks that it receives an absolute path to the built executable and that the file exists. It does not start kgcache yet.

## Planned baseline cases

Add these as real process tests in steps 4 through 6:

1. PING returns the exact PONG reply, then SIGTERM exits cleanly.
2. SET a small value and GET returns it.
3. SELECT another database and confirm the value is isolated.
4. Invalid configuration exits with status 1 and no READY signal.
5. Several idle clients remain connected while SIGTERM shuts down cleanly.
6. Stop and restart on the same selected port, then connect again.
7. Run two servers at once with separate ports and data directories.

Each case must check replies or exit status from a real kgcache process. The harness must reap every child on success and failure.

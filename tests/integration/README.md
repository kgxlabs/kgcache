# Process integration tests

Run `zig build test-integration` to build kgcache and run the Zig integration runner. `zig build test` runs the unit suite. The runner calls suite files in `tests/integration/suites/`.

The baseline suite checks PING, SET/GET, database isolation, invalid config startup, idle client shutdown, reconnection after restart, and two simultaneous servers. Each case checks replies or exit status from a real kgcache process.

The process harness in `tests/integration/harness/` owns each child from start through reaping. It enforces deadlines, captures bounded logs, and removes the fixture's temporary data. Set `KGCACHE_TEST_ARTIFACT_DIR` to keep a failed fixture's config and logs. The harness suite checks bad startup, malformed READY, timeouts, restarts, port conflicts, and two live servers.

The two server case requires separate ports and data directories. It confirms that data written to one server is absent from the other, then checks that the second server still responds after the first stops.

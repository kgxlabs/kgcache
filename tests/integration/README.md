# Process integration tests

Run `zig build test-integration` to build kgcache and run the Zig integration runner. `zig build test` runs the unit suite. The runner calls suite files in `tests/integration/suites/`.

The baseline suite checks PING, SET/GET, recovery after command errors, database isolation, invalid config startup, idle client shutdown, reconnection after restart, and two simultaneous servers. Each case checks replies or exit status from a real kgcache process.

The PING cases check PONG without a message and exact bulk string replies for
ordinary, empty, and binary messages containing NUL, CRLF, and a non-ASCII byte.

The command error cases send an invalid SET, BGSAVE, or COMMAND request, read
the error, then send PING on the same TCP connection and require PONG. They also
check that invalid SET requests leave the stored value intact and that binary
option bytes do not appear in the error response.

The process harness in `tests/integration/harness/` owns each child from start through reaping. It enforces deadlines, captures bounded logs, and removes the fixture's temporary data. Set `KGCACHE_TEST_ARTIFACT_DIR` to keep a failed fixture's config and logs. The harness suite checks bad startup, malformed READY, timeouts, restarts, port conflicts, and two live servers.

The two server case requires separate ports and data directories. It confirms that data written to one server is absent from the other, then checks that the second server still responds after the first stops.

Current split-request and pipelined-request failures are tracked in [issue #160](https://github.com/kgxlabs/kgcache/issues/160).

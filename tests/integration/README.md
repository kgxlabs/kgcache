# Process integration tests

Run `zig build test-integration` to build kgcache and run the Zig integration runner. `zig build test` runs the unit suite. The runner calls suite files in `tests/integration/suites/`.

The baseline suite checks PING, SET/GET/DEL, retained pipeline tails, recovery after command errors, database isolation, invalid config startup, idle client shutdown, reconnection after restart, and two simultaneous servers. Each case checks replies or exit status from a real kgcache process.

The PING cases check PONG without a message and exact bulk string replies for
ordinary, empty, and binary messages containing NUL, CRLF, and a non-ASCII byte.

The DEL cases remove several keys in one command, mix existing and missing keys,
and repeat keys. They check the removal count, the resulting key values, and
that an unrelated key remains intact.

The command error cases send an invalid SET, BGSAVE, or COMMAND request, read
the error, then send PING on the same TCP connection and require PONG. They also
check that invalid SET requests leave the stored value intact and that binary
option bytes do not appear in the error response.

The configuration cases use `databases`, `dir`, `dbfilename`, `appenddirname`,
and `appendfilename` with a real process. They check the first and last valid
database indices and reject the next index. Snapshot cases call `SAVE`, then
restart and read the saved data. AOF cases use `appendfsync always`, then
restart and read the journaled data without a snapshot. Both use relative and
absolute persistence directories and check the expected files. The config
file sits in another subdirectory, and the cases require no persistence files
in the working directory or under the config file's directory.

Listener precedence cases keep a control server running on an OS-selected
loopback port and put that occupied port and `bind 0.0.0.0` in the target's
file. CLI overrides select `127.0.0.1` and port 0. READY must report loopback
with a different selected port, and both servers must answer PING. These
cases cover config paths before, between, and after overrides, startup
without a config file, and `./-cache.conf`.

Startup rejection cases cover unknown and removed file and CLI names,
invalid overrides, missing values, duplicate paths, invalid readiness
arguments, and bare `--`. Invalid file values must still fail when the CLI
supplies valid replacements. Every rejection requires exit status 1, no
READY notification, one error event carrying the expected source error,
and a reaped child. A multiline return trace belongs to that single event.

See [Configuration](../../docs/CONFIGURATION.md#redis-config-compatibility)
for the supported config subset and the `.kgc` and port 0 differences.

The process harness in `tests/integration/harness/` owns each child from start through reaping. It enforces deadlines, captures bounded logs, and removes the fixture's temporary data. Set `KGCACHE_TEST_ARTIFACT_DIR` to keep a failed fixture's config and logs. The harness suite checks bad startup, malformed READY, timeouts, restarts, port conflicts, and two live servers.

The two server case requires separate ports and data directories. It confirms that data written to one server is absent from the other, then checks that the second server still responds after the first stops.

The retained-tail case uses a small connection buffer and sends a pipeline
larger than it, with three complete commands and an unfinished fourth. It reads
the first three replies and checks the unchanged value from another connection.
It then finishes the fourth command and checks the new value.
Deterministic connection tests cover exact read splits, including binary and
empty bodies.

# Run process integration tests

[Contributor guide](../../docs/contribute/testing.md) / Process tests

The process suite starts real kgcache executables and checks TCP replies,
files, restarts, logs, and exits. Use it after changing service behavior or a
boundary that unit tests cannot exercise alone.

## Run

Use Zig 0.16.0 from the repository root:

```sh
zig build test-integration
```

For retained failure evidence:

```sh
KGCACHE_TEST_ARTIFACT_DIR=test-artifacts/process zig build test-integration
```

The runner calls [suites](suites) against a built server. `zig build test`
runs units separately. Make provides `make test-integration`, `make test-unit`,
and `make test-zig`. `make test` attempts Zig and the required
[Go/Node clients](clients/README.md). CI runs clients only after the Zig gate.

## Find coverage

| Area | What cases check |
| --- | --- |
| Basic commands | PING message forms, binary SET/GET, multi-key DEL, and selected-database isolation |
| Request framing | Split requests, complete pipeline prefixes, retained unfinished tails, growth, and limits |
| Errors | Command errors preserve the connection and stored values; malformed frames close it |
| Protocol setup | HELLO modes, switching, metadata, and rejected setup without state changes |
| Client reports | Exact 22-field INFO/LIST shape, counters, library labels, visibility, and filters |
| Startup | File/CLI precedence, database range, paths, invalid settings, and readiness failures |
| Health | Exact PING/PONG, deadlines, malformed peers, and silent success/error result |
| Persistence | Snapshot/AOF reload, tail recovery, shutdown saves, active children, failures, and reaping |
| Connections | Restart on the same endpoint, two independent servers, resets, and connected-client shutdown |
| Backpressure | Unread large replies, independent observer progress, and blocked-writer cancellation |

Use the [compatibility reference](../../docs/reference/compatibility.md) for
which behavior is part of the public contract. Test results do not imply full
Redis conformance or a throughput guarantee.

## Add a case

Use the [process fixture](harness/README.md). It owns child startup, readiness,
temporary data, deadlines, output capture, stopping, and reaping. Connect to its
reported address. Two-server cases need separate data directories and ports.

Assert the reply or exit that establishes the behavior. Persistence cases also
check restored data and expected files. Config cases deliberately put the file
in another directory to distinguish working-directory paths from config paths.

For a rejection, require the intended source error, exit code 1, no READY line,
and a reaped child. One error event can include a multiline return trace.
Set `report_failures = false` when a case expects and inspects failure output.

## Preserve the hard boundaries

### Framing and command recovery

Retained-tail cases use a small initial buffer and a pipeline larger than that
buffer. They require replies for its complete prefix before finishing the tail.
They check the value through another connection before and after tail completion.

Limit cases send oversized declared counts or lengths without the missing
payload. Require the earlier valid replies, the limit error, and bounded close.
Check earlier applied writes from another connection. Deterministic unit tests
cover exact read splits, empty bodies, and binary bytes.

### CLIENT reports

INFO cases compare exact byte deltas without relying on socket read grouping.
They check self-dispatch timing, handler errors versus rejected bindings,
connection-local counts, protocol/database changes, and SETINFO ownership.
LIST adds sorted IDs, caller inclusion, disconnect/reconnect visibility,
label replacement, and rejected filters before dispatch.

Unit cases inject allocation failures and concurrent snapshot changes. A real
socket case leaves a 1 MiB LIST reply unread, checks observer PING and released
collection locking, then requires shutdown to join the writer within five
seconds. Keep this coverage when changing report formatting or locking.

### Transport cancellation

Backpressure cases seed a 16 MiB value through AOF replay. A small-buffer reader
requests GET then DEL but leaves the GET body unread. The later DEL must remain
pending while another client completes PING and DBSIZE.

SIGTERM must wake blocked writers and idle readers and finish within the
fixture's five-second stop deadline. Reset cases require continued observer
progress and no internal error log for expected peer termination. Scripted I/O
units separately check original error reporting, owner cleanup, and no appended
error bytes or later command after partial output fails.

## Diagnose a failure

Read the case name, process result, stdout, stderr, and generated config before
rerunning it. The fixture drains output while the child runs, so full pipes
cannot hide a deadlock. Retained evidence stays outside the removed temporary
data directory. A forced cleanup kill fails a case that expected a clean stop.

# Errors and logging

kgcache keeps the error returned by the operation that failed. Storage, Store,
command, snapshot, and journal code return that source to their caller. They
do not log it on the way up. A catch either recovers, cleans up, or passes the
source to a boundary that can report it.

## Reporting boundaries

| Boundary | Responsibility |
| --- | --- |
| Application | Report configuration, server creation, runtime, and shutdown failures. Return a nonzero process status. |
| Connection | Send a fixed RESP error for expected client errors. Report internal failures once and send a generic RESP error when output is safe. Report unexpected read/write failures once with their original source. |
| Cron | Report failed automatic work, then retry on a later tick when appropriate. A busy save or rewrite is an expected condition. |
| Persistence child | Exit with status 0 on success or 1 on a caught failure. The parent reports a failed operation once through cron or shutdown. |
| Server shutdown | Report failed child exits, wait failures, and result handling failures. Return the first shutdown error after completing remaining safe cleanup. |

A failed operation and a failed cleanup are separate errors, so each can have
its own event. Repeated cron attempts are separate operations. A peer closing
its connection, malformed client input, and expected command validation errors
do not create internal error events.

Peer resets and broken pipes end the session quietly. A reply write or flush
failure ends the session without appending an error reply to partial output
or executing a later command. Encoding validation checks the whole reply
before output starts, so validation failures can produce a generic
internal-error reply safely. Live reply, command, frame, and input owners are
released on every exit. Earlier successful mutations remain applied.

A write can change memory and publish its AOF record before the separate flush
or sync fails. Publication itself cannot return an error. The connection
handler reports the flush or sync failure with a generic client error, which
does not mean that the write was rolled back. If AOF writing becomes blocked,
later writes return `JournalWriteBlocked` until the server recovers or restarts.
See [AOF](AOF.md#write-failures) for persistence behavior.

## Logger and traces

`Logger` is a borrowed interface. The application keeps its implementation
alive while the server and its threads use it. `DefaultLogger` writes ordinary
messages to stdout and error events to stderr. `NoopLogger` and `TestLogger`
use the same interface, so domain code can run with either one without changes.
The logger implementation must handle concurrent calls.

Reports from operations within the parent pass the original error and
`@errorReturnTrace()` to `logger.err`. A trace describes the error return path,
not whether an operation partly succeeded. It can be absent if error return
tracing is disabled by the build or unavailable at the call site. The project build
enables tracing for the executable and tests in every optimization mode,
including release modes. Logger sinks must consume a trace during the call;
they cannot keep its pointer. `DefaultLogger` ignores its own output failures
because it has no other sink through which to report them.

Persistence children do not call the logger. When a `BGSAVE` or
`BGREWRITEAOF` child exits with status 1, the parent reports
`BackgroundSaveFailed` or `AofRewriteFailed`. The original child error,
failing stage, and trace are temporarily unavailable. Generic completion
reports carry no trace; abnormal exits and wait failures retain the errors
the parent can identify. A failed rewrite is still reported when its rollback
succeeds. A cached AOF failure is reported once across cron retries and shutdown.

This is a temporary mitigation for inherited logger locks. Background
persistence remains experimental: other inherited runtime locks may still
block child work, and shutdown has no strict deadline. Source-aware reporting
and the remaining child writer review are tracked in
[issue #118](https://github.com/kgxlabs/kgcache/issues/118), standard-stream
collection in [issue #227](https://github.com/kgxlabs/kgcache/issues/227),
and shutdown budgets in [issue #162](https://github.com/kgxlabs/kgcache/issues/162).

Tests may ignore errors while removing scratch files or closing a backend in
deferred fixture cleanup. Those cleanup calls are outside the assertion under
test. Production cleanup preserves its source or has an explicit reason for
ignoring a secondary failure.

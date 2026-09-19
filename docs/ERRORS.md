# Errors and logging

kgcache keeps the error returned by the operation that failed. Storage, Store,
command, snapshot, and journal code return that source to their caller. They
do not log it on the way up. A catch either recovers, cleans up, or passes the
source to a boundary that can report it.

## Reporting boundaries

| Boundary | Responsibility |
| --- | --- |
| Application | Report configuration, server creation, runtime, and shutdown failures. Return a nonzero process status. |
| Connection | Send a fixed RESP error for expected client errors. Report internal failures once and send a generic RESP error when possible. Report response write failures. |
| Cron | Report failed automatic work, then retry on a later tick when appropriate. A busy save or rewrite is an expected condition. |
| Persistence child | Report a failed save or rewrite before exiting. The parent accounts for the exit without repeating the child's report. The parent reports its own reaper failures. |

A failed operation and a failed cleanup are separate errors, so each can have
its own event. Repeated cron attempts are separate operations. A peer closing
its connection, malformed client input, and expected command validation errors
do not create internal error events.

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

Terminal reports pass the original error and `@errorReturnTrace()` to
`logger.err`. A trace describes the error return path, not whether an
operation partly succeeded. It can be absent if error return tracing is
disabled by the build or unavailable at the call site. The project build
enables tracing for the executable and tests in every optimization mode,
including release modes. Logger sinks must consume a trace during the call;
they cannot keep its pointer. `DefaultLogger` ignores its own output failures
because it has no other sink through which to report them.

Persistence children currently use the borrowed logger directly to report
their own errors. The production application passes `DefaultLogger`. Sending
child errors to the parent through a pipe is future work. The current logger
uses a mutex for threads, and its behavior after `fork()` has not been proven
safe in all conditions.

Tests may ignore errors while removing scratch files or closing a backend in
deferred fixture cleanup. Those cleanup calls are outside the assertion under
test. Production cleanup preserves its source or has an explicit reason for
ignoring a secondary failure.

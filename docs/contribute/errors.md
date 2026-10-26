# Trace an error

[Docs](../README.md) / [Contribute](README.md) / Errors and logging

Follow an error to the boundary that can act on it. Domain code returns the
original source error. It does not log each time the error passes through a
layer. A catch should recover, clean up, or pass that source onward.

## Find the reporting boundary

| Boundary | What it reports |
| --- | --- |
| Application | Invalid startup input, server creation, runtime, and shutdown failures; process exit is nonzero |
| Connection | Expected command errors as RESP replies; internal and unexpected transport failures once |
| Cron | A failed automatic attempt, followed by a later retry when supported |
| Parent persistence handling | Failed children, wait failures, and completion failures |
| Shutdown | The first shutdown error after all remaining safe cleanup |

A failed operation and a failed cleanup are separate events. Repeated cron
attempts are also separate operations. A busy save/rewrite is expected control
flow. Malformed requests, command validation errors, peer resets, and broken
pipes do not create internal error events.

The main sources are [main.zig](../../src/main.zig),
[session.zig](../../src/connection/session.zig),
[cron.zig](../../src/cron.zig), and
[drain.zig](../../src/persistence/drain.zig).

## Check whether output has started

The connection can send a generic internal-error reply only while output is
safe. Reply validation checks the complete reply before encoding starts,
including nested lengths. A validation failure can therefore still produce an
error reply.

A socket write or flush can fail after a prefix reached the peer. That failure
ends the session. It adds no error bytes to the partial reply and executes no
later command. The session releases its reply, command, frame, and input owners
on every exit. Earlier successful writes remain applied.

## Separate mutation from durability

A storage change can succeed before its AOF flush or sync fails. Journal record
publication cannot return an error. The connection reports a later flush/sync
failure once and returns a generic client error when safe, then closes.

Do not interpret that error as rollback. The memory change and published
journal record can already exist. New writes return `JournalWriteBlocked`
while the journal is failed. Cron can recover the write path through a later
successful flush. See [AOF failures](aof.md#write-failures).

## Use the logger correctly

[Logger](../../src/logger.zig) is a borrowed interface. Its owner must outlive
the server, workers, persistence result handling, and cleanup. Implementations
must accept concurrent calls.

`DefaultLogger` writes ordinary messages to stdout and errors to stderr.
`NoopLogger` and `TestLogger` implement the same interface. The default sink
ignores failures in its own output because it has no second reporting sink.

Within the parent process, pass the original error and `@errorReturnTrace()`
to `logger.err`. Consume a trace during that call. A sink cannot retain its
pointer. A trace describes the return path, not whether an operation partly
succeeded.

The build enables error return tracing for the server and tests in every
optimization mode. A trace may still be unavailable at a particular call site.
A generic child completion report deliberately carries no trace.

## Understand child failures

Persistence children exit with status 0 on success or 1 on a caught failure.
They do not call a copied logger. The parent turns an ordinary failed exit
into `BackgroundSaveFailed` or `AofRewriteFailed`.

The original child error, stage, and trace do not yet cross the process boundary.
Abnormal exits and wait errors retain whatever source the parent can identify.
Cron and shutdown share cached AOF completion state so one failure is reported
once, including a failed rewrite whose rollback succeeds.

Snapshot output setup and publication run in the parent. Those failures retain
their source error. Publication happens only after a successful child exit.

Removing child logging avoids an inherited logger lock. It does not prove the
whole child path is fork-safe: encoding, allocation, clocks, and I/O may still
encounter other inherited runtime locks. [#118](https://github.com/kgxlabs/kgcache/issues/118)
tracks source reporting and the remaining child-writer review.
[#227](https://github.com/kgxlabs/kgcache/issues/227) tracks stream collection.

Shutdown bounds child polling and can terminate overdue children. It retains
backends when reaping is unresolved. Disk calls and all cleanup do not have a
single strict deadline. See [persistence shutdown](persistence.md#shutdown-order).

## Review cleanup code

Production cleanup should preserve a source error or explain why a secondary
failure is ignored. Tests may ignore scratch-file removal or backend-close
errors in deferred fixture cleanup when those calls are outside the assertion
being tested. Keep that distinction visible in reviews.

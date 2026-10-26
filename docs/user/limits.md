# Limits

[Documentation](../README.md) / Limits

Use kgcache when your workload fits its [tested string-cache contract](compatibility.md).
These limits apply to current `main`.

## Unsupported features

Only the [listed commands and options](commands.md) are implemented. In
particular, kgcache has no hashes, lists, sets, sorted sets, streams, scan API,
TTL query/update commands, or increment commands. SET can assign expiration.
There is no Redis module system or COMMAND DOCS support.

There is no replication, failover, clustering, Sentinel, transactions,
WATCH, scripting, pub/sub, ACL, authentication, or TLS. CLIENT SETNAME,
GETNAME, ID, TRACKING, and LIST filters are unsupported. Client-side caching,
RESP3 pushes, and unlisted RESP3 reply types are unsupported. See the exact
[protocol contract](compatibility.md#protocol-contract).

The service has no access control. Keep it on a trusted network. A successful
client connection does not make higher-level client features available.

## Capacity and expiration

Values and keys are strings of bytes. There is no `maxmemory` setting,
eviction policy, or enforced total dataset size. Memory pressure can make
allocation fail or cause an OS/container kill. Budget for values, keys,
connection buffers, threads, and persistence copy-on-write memory.

Expiration is active. Cron samples TTL keys under storage transactions,
shares one time budget across databases, and rotates the first database.
GET also removes an expired key when it reads it. Cleanup is not immediate
at the exact expiration time. DBSIZE can count expired entries until cleanup.
The older warning that active expiration needs a locking fix is obsolete.
The [configuration reference](configuration.md#directives) lists cron and
active-expiration controls; the [developer design](../development/expiration.md)
explains the storage layout and tests.

## Requests and connections

Each encoded command is limited to 1 MiB and 1,024 array elements, including
the command name. These are per-command limits. A complete pipeline can be
larger. The input buffer starts at 1 KiB by default and grows up to the cap.
Oversized declared lengths/counts receive a protocol error, then the connection
closes without waiting for the payload. Valid but unfinished input at EOF is
not executed. See [request limits](configuration.md#tcp-request-limits).

Complete commands execute in order, including commands split across reads.
Command validation errors leave the connection usable. Malformed RESP ends
the session after a protocol error. A reply write or flush failure ends the
session without appending an error to partial output or running later commands.
Earlier successful commands stay applied.

A reply finishes before the next command starts. A slow reader can block its
connection's worker when socket send space fills. A successful local socket
write does not prove the peer read it. Shutdown wakes blocked socket reads and
writes before joining workers.

The implementation uses one joinable thread per connection and shared storage
locks. No high-connection-count or throughput claim follows from compatibility
tests. Measure your workload on its target machine.

## Persistence and platforms

Snapshots use kgcache's `.kgc` format. Redis RDB files are unsupported. AOF
replay accepts the kgcache command subset; this is not general Redis persistence
interchange. Filesystem, power-loss, and shutdown limits are in
[persistence](persistence.md#shutdown-and-failure-limits).

Background persistence is experimental. A forked child may still encounter
inherited runtime locks. Child errors currently reach the parent as generic
operation failures. The server bounds child polling, but it has no strict
deadline for all cleanup.

Published service images and native release qualification cover Linux amd64.
Arm64 emulation can run the image; it does not establish native arm64 support.

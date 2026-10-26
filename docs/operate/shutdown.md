# Shutdown and restart

[Docs](../README.md) / [Operate](README.md) / Shutdown

Use SIGINT or SIGTERM to stop kgcache normally. Give persistence enough time
to finish, and check the exit result before replacing the process.

## Stop the server

For a foreground native process, press Ctrl+C. A supervisor can send SIGTERM
to the process it owns. For the examples in these docs:

```sh
docker stop kgcache
```

Or, for the local Compose service:

```sh
docker compose stop
docker compose ps -a
docker inspect --format '{{.State.ExitCode}}' "$(docker compose ps -aq kgcache)"
docker compose logs --tail 100 kgcache
```

SIGINT and SIGTERM use the same normal shutdown path. Exit code 0 means that
path completed without a reported error. Exit code 1 means startup, runtime,
or cleanup failed. A supervisor's forced termination can end the process
before its own exit result is produced. The inspect command above reads the
retained Compose container's server exit code. A successful `docker stop`
command alone does not establish that code. The quick-start container uses
`--rm`, so it does not retain inspect state after stopping. Use the Compose
service when recording a stop result for recovery or backup work.

## What a clean stop saves

The server stops accepting connections and stops cron. It closes client
sockets to wake blocked reads and writes, then joins the client workers.
It waits for tracked snapshot and rewrite children before releasing their data.

With AOF off and `shutdown-save yes`, it saves remaining dirty snapshot data.
It skips a new save if an existing successful save covered all changes.
A required final snapshot failure makes shutdown fail; it is not retried.

With AOF on, it settles rewrite state before its final flush. `always` and
`everysec` also fsync the file. `no` does not request a final fsync. See
[Persistence](persistence.md) for the limits of each mode.

## Set the child wait budget

`persistence-shutdown-grace-ms` defaults to 10000 ms. It starts after client
workers join and is shared by all persistence children. A final shutdown
snapshot must use the time left in that same budget.

At expiry, kgcache reports a timeout, sends SIGKILL to remaining children,
and allows up to 1000 ms to reap them. Zero grace skips the wait and cannot
start a required final snapshot. Unresolved children leave shutdown in error;
resources they still need are retained.

The Docker examples allow 30 seconds for the whole stop. Increase that outer
allowance when increasing the child budget or using slow storage. The
budgets cover different parts of the process.

## Shutdown limits

The child budget bounds polling. It does not bound worker draining,
filesystem calls, or all cleanup. A clean stop has no strict total deadline.
SIGKILL, an OOM kill, power loss, or a supervisor timeout can interrupt it.

A background command's initial success reply only means the operation started
or was scheduled. Check logs for its eventual result. A failed rewrite keeps
the manifest and incremental files containing writes and does not publish
its unfinished base. An unresolved rewrite keeps required resources open.

## Restart with the same data

Start the native executable with the same config and working directory. For
the published Docker example, run the original start command with the same
named volume. For Compose, use the same project name:

```sh
docker compose start
docker compose up --wait --wait-timeout 120
redis-cli PING
```

Expected reply: `PONG`. Check a known application value too. A successful
PING proves protocol response, not that all expected data was recovered.

Before a version change, retain a separate data copy and read the target
release's notes. Reusing a data volume is recovery from those files, not a
rollback plan. Do not run two writers against the same persistence directory.

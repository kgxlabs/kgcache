# Troubleshooting

[Docs](../README.md) / [Operate](README.md) / Troubleshooting

Start with the launch command, config, stdout, and stderr. Preserve persistence
files while investigating. Changing paths or deleting a volume can hide the
original failure and its data.

## The server does not start

| Symptom | Check |
| --- | --- |
| Unknown directive or flag | Use a name from the [configuration reference](../reference/configuration.md). Redis config files can include unsupported settings. |
| Invalid value or malformed line | Check numeric ranges, required values, file quoting, and trailing text. There are no inline comments. |
| Address already in use | Check which service owns the port. Pick another port and use it in clients and health probes too. |
| Data path or permission failure | Create `dir`, resolve it from the process working directory, and check the server identity's permissions. |
| AOF replay failure | Copy the complete AOF directory before changing settings. Check the recovery boundary below. |

Startup errors are written to stderr and exit with status 1. To simplify a
reproduction, use a separate empty data directory and a small config. Keep
the original directory unchanged.

## A client cannot connect

First check the endpoint with `redis-cli -h 127.0.0.1 -p 6379 PING`. If the
probe works, compare the client's host, port, database, credentials, and
connection-name settings with the [client guides](../develop/README.md).

A handshake can fail because the client requests AUTH, SETNAME, tracking,
or another unsupported feature. Library identity reporting through SETINFO
can remain enabled. Check the exact [tested versions](../reference/compatibility.md#tested-clients).

For Docker, distinguish the published host port from the port inside the
container. Applications in the same Compose network use `kgcache:6379`.
Host examples use `127.0.0.1:6379`.

## A command fails or returns null

Look up the command's [syntax and returns](../commands/README.md). GET null
means absent or expired. SET null depends on its options: with GET, a
successful new write can still return null because no old value existed.

Command errors normally leave the connection usable. A malformed or oversized
request ends the session. The [protocol reference](../reference/protocol.md)
describes these boundaries. A disconnect or AOF error does not prove a write
was rolled back; check the resulting value before choosing a retry.

## Data is missing after restart

Check the exact `dir`, `dbfilename`, AOF settings, working directory, and
Compose project name. A changed path or project can select different storage.
Check the selected logical database too.

Then check the previous exit result and logs. A killed process may not have
saved dirty snapshot data or flushed its AOF buffer. AOF startup takes
precedence over a snapshot. See [Persistence](persistence.md) for the loss
window of each policy.

`aof-load-truncated yes` repairs only an incomplete final command in the
last incremental file. It does not repair malformed commands, earlier files,
or arbitrary corruption. Retain the complete failed directory for a report.

## Shutdown times out

Compare the supervisor's total stop allowance with
`persistence-shutdown-grace-ms`. The inner budget starts after client workers
join. It is not a whole-process deadline. Read
[Shutdown and restart](shutdown.md#shutdown-limits) before increasing timeouts.

## Report a reproducible problem

Include the version or source commit, OS/CPU, config, launch command, client
version and protocol, smallest failing sequence, expected result, and both
log streams. Remove credentials and private values from the report. Follow
[CONTRIBUTING.md](../../CONTRIBUTING.md) to file it.

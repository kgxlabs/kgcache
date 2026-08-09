# Configuration

kgcache runs entirely off built-in defaults — mirroring `redis-server` — until you hand it a config file as the first argument:

```bash
./zig-out/bin/main path/to/kgcache.conf
```

Omit the argument and it starts from `Config.default()` (`src/config.zig`): `127.0.0.1:6379`, 16 databases, a `dump.kgc` snapshot in the current directory, and so on.

A config file is one directive per line, `directive value`, the same shape as `redis.conf`:

```
port 7000
num-databases 4
```

Blank lines and lines starting with `#` are ignored. Anything else is validated strictly at startup: an unrecognized directive, a directive with no value, or a value that doesn't fit its type all fail the process with a message on stderr rather than being silently ignored — the same fail-fast-on-bad-config behavior as `redis-server`.

## Directives

| Directive | Default | Meaning |
| --- | --- | --- |
| `bind` | `127.0.0.1` | Address the TCP server binds to |
| `port` | `6379` | TCP port the server listens on |
| `reuse-address` | `yes` | Sets `SO_REUSEADDR` on the listening socket (`yes`/`no`) |
| `connection-buffer-size` | `1024` | Per-connection read buffer size, in bytes |
| `num-databases` | `16` | Number of selectable databases (`SELECT 0` .. `num-databases - 1`) |
| `snapshot-path` | `dump.kgc` | Path to the `.kgc` snapshot file loaded on startup and written by `SAVE` |
| `active-expire-interval-ms` | `100` | How often the active-expiration worker sweeps for expired keys |
| `active-expire-budget-ms` | `10` | Time budget per sweep before the worker yields |
| `active-expire-batch-size` | `20` | Keys sampled per expiration batch, per database |
| `active-expire-threshold-percent` | `25` | Batch expiry rate that triggers an immediate next batch on the same database |

See [`kgcache.conf.example`](../kgcache.conf.example) for a file with every directive documented inline.

## `snapshot-path` gotchas

- Must end in `.kgc`.
- A relative path resolves against the server's current working directory, not the config file's location.
- The parent directory must already exist — it is not created automatically.
- `~` is not expanded, since that's a shell feature rather than something the config parser does; use an absolute path like `/Users/you/dump.kgc` instead of `~/dump.kgc`.

## Not yet configurable

- AOF path/fsync policy — the AOF backend has no disk-backed store yet.
- Memory/eviction limits — no `maxmemory` support yet.

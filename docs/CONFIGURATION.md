# Configuration

kgcache runs entirely off built-in defaults — mirroring `redis-server` — until you hand it a config file as the first argument:

```bash
./zig-out/bin/kgcache path/to/kgcache.conf
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
| `snapshot-path` | `dump.kgc` | Path to the `.kgc` snapshot file loaded on startup and written by `SAVE`/`BGSAVE` |
| `cron-interval-ms` | `100` | How often background work runs, including expiration, AOF flushing, save checks, and child cleanup |
| `active-expire-budget-ms` | `10` | Time budget per expiration sweep before the worker yields |
| `active-expire-batch-size` | `20` | Keys sampled per expiration batch, per database |
| `active-expire-threshold-percent` | `25` | Batch expiry rate that triggers an immediate next batch on the same database |
| `exclusive-bg-persistence` | `yes` | Whether a `BGSAVE` and an AOF background rewrite are prevented from running at the same time (`yes`/`no`). See [Snapshots](SNAPSHOTS.md#background-saving-bgsave). |
| `save` | none (disabled) | One or more `save <seconds> <changes>` rules for triggering an automatic `BGSAVE`. May repeat; see below. |
| `appendonly` | `no` | Turn the append-only file on (`yes`/`no`) |
| `appendfsync` | `everysec` | Fsync policy: `always`, `everysec`, or `no` |
| `append-dirname` | `appendonlydir` | Directory that holds AOF data and its manifest |
| `append-filename` | `appendonly.aof` | Base name used to build AOF file names |
| `auto-aof-rewrite-percentage` | `100` | Rewrite after incremental data grows by this percentage; `0` disables automatic rewrites |
| `auto-aof-rewrite-min-size` | `67108864` | Minimum total AOF size before automatic rewrite, in bytes |
| `aof-load-truncated` | `yes` | Remove an incomplete command at the end of the last incremental file (`yes`/`no`) |

See [`kgcache.conf.example`](../kgcache.conf.example) for a file with every directive documented inline.

## `snapshot-path` gotchas

- Must end in `.kgc`.
- A relative path resolves against the server's current working directory, not the config file's location.
- The parent directory must already exist — it is not created automatically.
- `~` is not expanded, since that's a shell feature rather than something the config parser does; use an absolute path like `/Users/you/dump.kgc` instead of `~/dump.kgc`.

## `exclusive-bg-persistence` recommendation

Keep the default, `yes`, unless you have a clear reason to change it.

`BGSAVE` and `BGREWRITEAOF` each start a child process. If both run at the
same time, writes made by the parent can use much more memory. With `yes`,
only one of these jobs can run at a time.

## Automatic background saving (`save`)

By default, kgcache only saves when a client runs `SAVE` or `BGSAVE`. Add
one or more `save <seconds> <changes>` lines to enable automatic `BGSAVE`:

```
save 3600 1
save 300 100
save 60 10000
```

Each line is one rule. A rule matches when both its time and write count
have been reached. A save starts when any rule matches.

With no `save` line, automatic saving is off. Manual `SAVE` and `BGSAVE`
still work. See [Snapshots](SNAPSHOTS.md#automatic-background-saving-condition-based-snapshots)
for the write counter and rule checks.

## AOF settings

`appendonly yes` turns on the append-only file. With AOF on, startup loads
the AOF and does not load `snapshot-path`. `SAVE` and `BGSAVE` still write
snapshots.

`appendfsync` controls when AOF data is forced to the storage device:

| Value | Behavior |
| --- | --- |
| `always` | Write and fsync before a write command returns `OK` |
| `everysec` | Write from cron and fsync at most once per second |
| `no` | Write from cron and let the OS decide when to fsync |

`append-dirname` is resolved from the process working directory. kgcache
owns this directory and may remove AOF data files that are not listed in
the manifest. Do not share it with other files.

`append-filename` is a base name, not a full path. For example,
`appendonly.aof` produces names such as `appendonly.aof.1.base`,
`appendonly.aof.2.incr`, and `appendonly.aof.manifest`.

Automatic rewrite starts only after both size checks pass. The minimum size
uses plain bytes, so write `67108864`, not `64mb`. Set
`auto-aof-rewrite-percentage 0` to disable automatic rewrites without
disabling manual `BGREWRITEAOF`.

`aof-load-truncated yes` only repairs an incomplete command at the end of
the last incremental file. Damage in a base or earlier incremental file
still stops startup.

See [Append-only file](AOF.md) for the file layout, startup flow, rewrite
flow, and failure behavior.

## Not yet configurable

- Memory/eviction limits — no `maxmemory` support yet.

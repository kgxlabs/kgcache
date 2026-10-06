# Configuration

kgcache starts with built-in defaults. To use a config file, pass its path as a positional argument:

```bash
./zig-out/bin/kgcache path/to/kgcache.conf
```

Without a config file, kgcache uses its built-in defaults: `127.0.0.1:6379`, 16 databases, and `dump.kgc` in the current directory for snapshots. Command-line overrides apply after the optional file.

Use `--<directive> <value>` to override any supported setting:

```bash
./zig-out/bin/kgcache path/to/kgcache.conf --port 7000 --databases 4
./zig-out/bin/kgcache --port 7000 path/to/kgcache.conf --databases 4
./zig-out/bin/kgcache --port 7000 --databases 4 path/to/kgcache.conf
./zig-out/bin/kgcache --dir 'data files' --save 60 1 --save 300 10
./zig-out/bin/kgcache path/to/kgcache.conf --save ''
./zig-out/bin/kgcache --port 7000 ./-cache.conf
```

The shell supplies each value as one argument. Single-value directives consume
one argument, and `--save` consumes two numbers or one empty argument. kgcache
keeps argument bytes unchanged: shell grouping quotes are removed by the shell,
while literal quotes and backslashes remain part of a string value. Required
values are consumed by position, even when they start with a hyphen. For example,
`--dir --` supplies the literal directory value `--`, and `--port --appendonly`
fails port validation. An override requesting more values than remain fails with
`MissingValue`. `--save 60 cache.conf` fails changes validation because its second
argument is a required value. Use separate arguments, such as `--port 7000`;
`--port=7000` is not supported.

The optional config path may appear before, between, or after options. Its position
does not change the defaults, file, then CLI application order. After a complete
option, an extra positional token is the path: `--save 60 1 cache.conf` is valid,
and `--save 60 1 2` treats `2` as a path. A second path is rejected.

At an argument boundary, a bare `--` fails with `UnknownFlag`. For a config
filename that starts with a hyphen, use a path such as `./-cache.conf`.

The process option `--ready-fd <fd>` requires a decimal descriptor of at least 3
and at most 2147483647, and may appear only once. The descriptor must be open
and inherited by the child process. It is separate from config directives.

For single-value settings, the last CLI occurrence wins. Every CLI and file
occurrence is validated, even if a later value replaces it. The first `--save`
replaces all file save rules; further CLI rules append in order. `--save ''`
clears rules collected so far, and later rules can enable automatic saving again.

A config file has one directive per line, in the form `directive value`:

```
port 7000
databases 4
```

Blank lines and lines starting with `#` are ignored. Anything else is validated strictly at startup. An unrecognized directive, a missing value, or a value outside its accepted range stops startup before server creation. The application logger reports the source error, and the process exits with status 1. The default logger writes error events to stderr.

Names and `yes`/`no` or enum spellings are case-sensitive. Whitespace around a
line is trimmed. Except for `save`, the trimmed text after the name is one value, so
unquoted strings may contain spaces or tabs. `save` separates values on spaces
or tabs outside quotes. Inline comments are not supported; a `#` after a
directive is part of its value.

For every directive except `save`, the last occurrence supplies the value. Every occurrence must have a valid value. Repeated `save` directives collect rules in file order, with `save ""` clearing earlier rules.

## Quotes and empty values

A double quote at the start of a value groups that value. For `save`, quote
each number separately; quoted and unquoted numbers can be mixed:

```conf
dir "data files"
port "7000"
save "60" 1
```

Outer quotes are removed. Inner spaces and tabs are kept, so `dir " data files "`
keeps both surrounding spaces. This line contains an actual tab between `data`
and `files`, which is kept in the directory name:

```conf
dir "data	files"
```

Inside quotes, only `\"` (a literal quote) and `\\` (a literal backslash) are
escapes. `\n`, `\t`, and other escapes are rejected. Unquoted backslashes and
embedded quotes stay literal. Single quotes have no special meaning in a file.

File quotes now group values instead of becoming part of the path. If an older
config expected literal surrounding quotes, escape them:

| File line | Directory name |
| --- | --- |
| `dir "data files"` | `data files` |
| `dir "\"data files\""` | `"data files"` |
| `dir "a\"b\\c"` | `a"b\c` |

A closing quote must be followed by spaces, tabs, or the end of the line.
For settings other than `save`, no further value is allowed. Unclosed quotes,
unsupported escapes, line breaks inside quotes, adjacent fragments such as
`save "60"1`, and trailing text such as `dir "data" extra` fail with
`MalformedLine`.

Values are decoded before validation. `save ""` clears only save rules; it
does not reset other settings. `port ""`, `dir ""`, and `port " 7000 "` fail
with `InvalidValue`. A missing value fails with `MalformedLine`.

## Directives

Append any CLI form below to `./zig-out/bin/kgcache`, with an optional config path.

| Directive | CLI example | Default | Meaning |
| --- | --- | --- | --- |
| `bind` | `--bind 127.0.0.1` | `127.0.0.1` | IPv4 address the TCP server binds to |
| `port` | `--port 7000` | `6379` | TCP port; `0` asks the OS to select an available port |
| `reuse-address` | `--reuse-address yes` | `yes` | Sets `SO_REUSEADDR` on the listening socket (`yes`/`no`) |
| `connection-buffer-size` | `--connection-buffer-size 2048` | `1024` | Per-connection read buffer size, in bytes |
| `databases` | `--databases 4` | `16` | Number of selectable databases (`SELECT 0` .. `databases - 1`) |
| `dir` | `--dir 'data files'` | `.` | Shared directory for snapshots and the AOF directory |
| `dbfilename` | `--dbfilename state.kgc` | `dump.kgc` | Snapshot filename within `dir`, loaded on startup and written by `SAVE`/`BGSAVE` |
| `cron-interval-ms` | `--cron-interval-ms 100` | `100` | How often background work runs, including expiration, AOF flushing, save checks, and child cleanup |
| `active-expire-budget-ms` | `--active-expire-budget-ms 10` | `10` | Time budget per expiration sweep before the worker yields |
| `active-expire-batch-size` | `--active-expire-batch-size 20` | `20` | Keys sampled per expiration batch, per database |
| `active-expire-threshold-percent` | `--active-expire-threshold-percent 25` | `25` | Batch expiry rate that triggers an immediate next batch on the same database |
| `exclusive-bg-persistence` | `--exclusive-bg-persistence yes` | `yes` | Whether a `BGSAVE` and an AOF background rewrite are prevented from running at the same time (`yes`/`no`). See [Snapshots](SNAPSHOTS.md#background-saving-bgsave). |
| `save` | `--save 60 1` | none (disabled) | One or more `save <seconds> <changes>` rules for triggering an automatic `BGSAVE`. May repeat; see below. |
| `appendonly` | `--appendonly yes` | `no` | Turn the append-only file on (`yes`/`no`) |
| `appendfsync` | `--appendfsync always` | `everysec` | Fsync policy: `always`, `everysec`, or `no` |
| `appenddirname` | `--appenddirname history` | `appendonlydir` | Directory name within `dir` that holds AOF data and its manifest |
| `appendfilename` | `--appendfilename journal.aof` | `appendonly.aof` | Base name used to build AOF file names |
| `auto-aof-rewrite-percentage` | `--auto-aof-rewrite-percentage 100` | `100` | Rewrite after incremental data grows by this percentage; `0` disables automatic rewrites |
| `auto-aof-rewrite-min-size` | `--auto-aof-rewrite-min-size 67108864` | `67108864` | Minimum total AOF size before automatic rewrite, in bytes |
| `aof-load-truncated` | `--aof-load-truncated yes` | `yes` | Remove an incomplete command at the end of the last incremental file (`yes`/`no`) |
| `bgsave-retry-delay-ms` | `--bgsave-retry-delay-ms 5000` | `5000` | Wait after an automatic background save fails before retrying; `0` means no retry delay |

See [`kgcache.conf.example`](../kgcache.conf.example) for a file with every directive documented inline.

## Numeric ranges

All limits are inclusive. `usize` is the size of a machine word in the server build.

| Directive | Accepted range |
| --- | --- |
| `port` | 0 to 65535; `0` selects an available TCP port |
| `connection-buffer-size` | 1 to maximum `usize` |
| `databases` | 1 to 4294967295 |
| `cron-interval-ms` | 1 to 9223372036854775807 |
| `active-expire-budget-ms` | 1 to 127 |
| `active-expire-batch-size` | 1 to 127 |
| `active-expire-threshold-percent` | 1 to 100 |
| `save <seconds> <changes>` | `seconds`: 1 to 9223372036854775807; `changes`: 1 to 4294967295 |
| `auto-aof-rewrite-percentage` | 0 to 4294967295; `0` disables automatic rewrites |
| `auto-aof-rewrite-min-size` | 0 to maximum `usize` |
| `bgsave-retry-delay-ms` | 0 to 9223372036854775807; `0` means no retry delay |

## Persistence paths

```conf
databases 16
dir ./data
dbfilename dump.kgc
appenddirname appendonlydir
appendfilename appendonly.aof
```

This config uses `./data/dump.kgc` for snapshots and
`./data/appendonlydir` for AOF files. These paths use the final settings after
CLI overrides are applied.

- A relative `dir` resolves from the process working directory, not the config file's location. The process working directory is not changed.
- `dir` must already exist. Give the user running kgcache read and write access for persistence operations. kgcache creates the AOF subdirectory when AOF is enabled.
- `dbfilename` must be a nonempty filename ending in `.kgc`, without path separators.
- `appenddirname` must be a nonempty directory name without path separators. `.` and `..` are rejected.
- `~` is not expanded. Use an absolute `dir` such as `/absolute/path/to/data` instead of a home-directory shorthand.

For a relative directory, prepare it from the working directory where you
will start kgcache:

```bash
mkdir -p ./data
```

Changing persistence paths or file names selects new locations. It does not
move, rename, or convert existing persistence files.

### Existing config files

Update existing config files to use the supported names:

| Removed directive | Use |
| --- | --- |
| `num-databases` | `databases` |
| `append-dirname` | `appenddirname` |
| `append-filename` | `appendfilename` |
| `snapshot-path` | `dir` and `dbfilename` |

Removed names stop startup with an unknown-directive error. There are no
aliases or a legacy path mode.

## Redis config compatibility

kgcache supports the directives listed in this page. Redis names are used
for the supported database and persistence settings. A complete Redis
config file may contain unsupported directives, which stop startup.

File quotes follow the [rules above](#quotes-and-empty-values). Numeric sizes
use decimal bytes, such as `67108864`; size suffixes such as `64mb` are not
supported.

| Setting or format | kgcache | Redis |
| --- | --- | --- |
| Snapshot files | `.kgc` format, with `dbfilename dump.kgc` by default | RDB format, with `dbfilename dump.rdb` by default |
| `port 0` | Starts a TCP listener on an OS-selected port | Disables the TCP listener |

The Redis defaults and port behavior are documented in the
[Redis 8.2 example configuration](https://github.com/redis/redis/blob/8.2/redis.conf).
kgcache does not read or write Redis RDB snapshots. Renaming an RDB file
to `.kgc` does not convert it.

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
have been reached. A save starts when any rule matches. Both fields must be
positive: `seconds` is at most 9223372036854775807 and `changes` is at most
4294967295.

With no `save` line, automatic saving is off. `save ""` clears earlier file rules,
and `--save ''` clears file rules and earlier CLI rules. Manual `SAVE` and `BGSAVE`
still work. See [Snapshots](SNAPSHOTS.md#automatic-background-saving-condition-based-snapshots)
for the write counter and rule checks.

To replace file rules with one CLI rule after a clear:

```bash
./zig-out/bin/kgcache cache.conf --save '' --save 60 1
```

## AOF settings

`appendonly yes` turns on AOF. Startup then loads AOF and skips the
snapshot. `SAVE` and `BGSAVE` still write snapshots using the directory
configured by `dir` and the filename configured by `dbfilename`.

`appendfsync` controls when AOF data is forced to the storage device:

| Value | Behavior |
| --- | --- |
| `always` | Write and fsync before an applied write command returns to the client |
| `everysec` | Write from cron and fsync at most once per second |
| `no` | Write from cron and let the OS decide when to fsync |

`appenddirname` names a directory within `dir`. kgcache
owns this directory and may remove AOF data files that are not listed in
the manifest. Do not share it with other files.

`appendfilename` is a base name, not a full path. For example,
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

- Memory/eviction limits: no `maxmemory` support yet.
- Live settings through RESP `CONFIG`: tracked in [#171](https://github.com/kgxlabs/kgcache/issues/171).

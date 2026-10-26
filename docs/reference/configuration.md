# Configuration reference

[Docs](../README.md) / [Reference](README.md) / Configuration

This page defines the native defaults and accepted configuration input.
For a working setup, use [Configure kgcache](../operate/configuration.md).
The image has its own config, described in
[Docker](../operate/docker.md#understand-the-image-layout).

## Server invocation

```text
kgcache [config-file] [--directive value ...]
kgcache healthcheck [config-file] [--directive value ...]
kgcache --version
```

The config path can appear before, between, or after complete directive
options. Only one path is allowed. Defaults load first, then the file, then
CLI settings. Settings are read once at startup; there is no live CONFIG API.

## Network and databases

| Directive | Native default | Accepted values and meaning |
| --- | --- | --- |
| `bind` | `127.0.0.1` | Numeric IPv4 listener address |
| `port` | `6379` | 0 through 65535; 0 requests an OS-selected port |
| `reuse-address` | `yes` | `yes` or `no`; controls SO_REUSEADDR |
| `connection-buffer-size` | `1024` | Bytes, 1 through the maximum machine word; initial capacity is clamped to 1 MiB |
| `databases` | `16` | 1 through 4294967295; valid SELECT indices are 0 through count minus 1 |

The buffer setting does not change the fixed
[request limits](protocol.md#request-limits). There is no `maxmemory` setting.
Port 0 creates an ephemeral listener; it does not disable TCP.

## Persistence

| Directive | Native default | Accepted values and meaning |
| --- | --- | --- |
| `dir` | `.` | Nonempty path without NUL, resolved from the process working directory |
| `dbfilename` | `dump.kgc` | Nonempty `.kgc` basename, without path separators; `.` and `..` are invalid |
| `save` | No rules | Positive `<seconds> <changes>`, or one empty value to clear rules |
| `shutdown-save` | `yes` | `yes` or `no`; final dirty snapshot on a normal stop when AOF is off |
| `appendonly` | `no` | `yes` or `no`; AOF startup takes precedence over snapshot loading |
| `appendfsync` | `everysec` | `always`, `everysec`, or `no` |
| `appenddirname` | `appendonlydir` | Nonempty directory basename without separators; `.` and `..` are invalid |
| `appendfilename` | `appendonly.aof` | Text prefix for AOF parts and the manifest; use a simple filename |
| `auto-aof-rewrite-percentage` | `100` | 0 through 4294967295; 0 disables automatic rewrites |
| `auto-aof-rewrite-min-size` | `67108864` | Bytes, 0 through the maximum machine word |
| `aof-load-truncated` | `yes` | `yes` or `no`; repair an incomplete final command in the last incremental file |
| `exclusive-bg-persistence` | `yes` | `yes` or `no`; serialize snapshot and rewrite children when yes |
| `persistence-shutdown-grace-ms` | `10000` | 0 through 4294967295 ms; shared child budget after workers join |
| `bgsave-retry-delay-ms` | `5000` | 0 through 9223372036854775807 ms; automatic-save retry delay |

`dir` must exist and permit persistence access by the server identity. The
server creates `appenddirname` within it. `dbfilename` selects the snapshot
inside `dir`. Neither `~` expansion nor automatic file relocation occurs.
Path validation for the two basenames rejects `/`, `\`, and NUL.

The AOF subdirectory belongs to kgcache. Startup reconciliation can remove
its unreferenced AOF files. Keep it separate from unrelated data. Changing
`appendfilename` changes the selected manifest and file prefix.

Use [Persistence](../operate/persistence.md) for fsync, recovery, and rewrite
behavior. Use [Shutdown](../operate/shutdown.md) for the shared grace deadline,
zero-budget behavior, forced child termination, and total-stop limits.

## Background work

| Directive | Native default | Accepted values and meaning |
| --- | --- | --- |
| `cron-interval-ms` | `100` | 1 through 9223372036854775807 ms between cron rounds |
| `active-expire-budget-ms` | `10` | 1 through 127 ms shared by an expiration round across databases |
| `active-expire-batch-size` | `20` | 1 through 127 sampled keys per batch |
| `active-expire-threshold-percent` | `25` | 1 through 100; expired percentage that requests another batch in that database |

Cron handles expiration, AOF flushing, automatic persistence checks, and
child completion. Active expiration samples keys under storage transactions
and rotates the first database in each round. GET also removes expired keys.

## Save rules

```conf
save 3600 1
save 300 100
save 60 10000
```

Each rule requires both elapsed seconds and accumulated changes. Any matching
rule can start a background save. Seconds must be 1 through 9223372036854775807;
changes must be 1 through 4294967295. Periodic saving is off with no rules.

In a file, rules append in order. `save ""` clears the rules collected so far.
On the CLI, the first `--save` replaces the file's rules; later `--save`
options append or clear:

```sh
./zig-out/bin/kgcache kgcache.conf --save '' --save 60 1
```

An empty rule list disables periodic saves. It does not disable manual
SAVE/BGSAVE or a required shutdown save.

## File grammar

Use one `directive value` per line. Blank lines and lines beginning with `#`
after trimming are ignored. Names, boolean values, and enum values are
case-sensitive. Unknown directives, missing values, invalid ranges, and
malformed quotes stop startup. Every occurrence is validated, including
one replaced by a later value.

For settings other than `save`, the last occurrence wins. The trimmed text
after the name is a single value, so an unquoted path can contain spaces.
Save rules split on spaces or tabs outside quotes. Inline comments are
unsupported: `#` after a directive is part of its value.

### Quoted values

An opening double quote groups a value:

```conf
dir "data files"
dbfilename "state.kgc"
save "60" "1"
save ""
```

Inside quotes, only `\"` and `\\` are escapes. Other escapes, including `\n`
and `\t`, are invalid. Single quotes have no special meaning in a config file.
Unquoted quotes and backslashes remain literal unless the value begins with
a double quote.

A closing quote must be followed by whitespace or the line ending. Except
for `save`, another value is invalid. Unclosed quotes, literal line breaks
inside quotes, adjacent fragments such as `save "60"1`, and trailing text
such as `dir "data" extra` are malformed.

The grouped value is validated after decoding. For example, `dir ""` and
`port " 7000 "` are invalid. To retain literal quote characters in a directory
name, use escaped quotes, such as `dir "\"data files\""`.

### Command-line values

The shell groups CLI values. It removes its grouping quotes before kgcache
receives the arguments. The config-file quote parser is not applied again.

```sh
./zig-out/bin/kgcache --dir 'data files' --port 7000
```

Single-value directives consume one argument. `--save` consumes two numeric
arguments or one empty argument. Required values are consumed by position,
even when they start with `-`. Thus `--dir --` supplies the directory `--`,
while `--port --appendonly` fails value validation.

Use separate arguments, not `--port=7000`. A bare `--` at an option boundary
is an unknown flag. Prefix a config filename beginning with `-` with `./`.
A second positional path is rejected. All occurrences must validate before
their final precedence is applied.

## Process options

`--ready-fd <fd>` is a server process option for launchers. The decimal
descriptor must be 3 through 2147483647, already open, inherited by the
server, and supplied once. It is not a config directive and is rejected
in health mode. See the [process harness](../../tests/integration/harness/README.md)
for readiness and ownership.

`healthcheck` must be the first argument. A config literally named
`healthcheck` can be passed as `./healthcheck` in server mode. Health mode
uses the same directive grammar and precedence; its endpoint and exit behavior
are documented in [Health and monitoring](../operate/monitoring.md).

`--version` reports the executable's effective version. Contributor build
inputs and records are described in [Build versions](../contribute/building.md).

## Redis configuration differences

Only the listed settings are accepted. Complete Redis config files often
include unsupported directives and will fail startup. Sizes are decimal
bytes; suffixes such as `64mb` are unsupported. Snapshots use `.kgc`, not RDB.

The removed names `num-databases`, `append-dirname`, `append-filename`, and
`snapshot-path` have no aliases. Use `databases`, `appenddirname`,
`appendfilename`, and `dir` plus `dbfilename` respectively.

The canonical implementation is the [directive registry](../../src/config/registry.zig)
with [native defaults](../../src/config.zig). The
[example config](../../kgcache.conf.example) lists every setting with comments.

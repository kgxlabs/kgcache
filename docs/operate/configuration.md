# Configure kgcache

[Docs](../README.md) / [Operate](README.md) / Configuration

Set the listener, data directory, and persistence policy before starting the
server. kgcache reads settings once at startup. Restart the process to apply
a change.

## Create a config file

Start from [kgcache.conf.example](../../kgcache.conf.example), or save a small
config as `kgcache.conf`:

```conf
bind 127.0.0.1
port 6379
databases 16
dir ./data
dbfilename dump.kgc
appendonly no
save ""
shutdown-save yes
```

Prepare the data directory and start the executable from the same working
directory:

```sh
mkdir -p data
./zig-out/bin/kgcache kgcache.conf
```

The server listens on loopback, loads an existing snapshot if present, and
saves dirty data on a clean stop. This file disables periodic snapshots.
See [Persistence](persistence.md) to choose a different policy.

## Override a setting

Use `--<directive> <value>` after the executable:

```sh
./zig-out/bin/kgcache kgcache.conf --port 7000 --databases 4
```

Connect with `redis-cli -p 7000 PING`. Configuration is applied in this order:

1. Built-in defaults.
2. The optional config file.
3. Command-line settings.

The config path can appear before or after complete options. Its position
does not change precedence. Pass values as separate arguments; `--port=7000`
is unsupported.

Single-value settings use the last occurrence, but every supplied value must
be valid. Save rules have separate append and clear behavior described in
the [configuration reference](../reference/configuration.md#save-rules).

## Choose data paths

`dir` is relative to the process working directory, not to the config file.
The server does not change that working directory. With the example above,
the snapshot is `./data/dump.kgc`. With AOF enabled, its directory is
`./data/appendonlydir` by default.

Create `dir` before starting. Give the server identity read and write access.
The server creates the AOF subdirectory when needed. It owns the files in
that subdirectory, so keep unrelated data elsewhere.

Use `dir` plus `dbfilename` for snapshots. Changing a path selects another
location; it does not move or convert existing files. The old directive names
`snapshot-path`, `num-databases`, `append-dirname`, and `append-filename` are
unsupported. There are no legacy aliases.

## Check the result

Startup rejects unknown directives, missing values, and invalid values before
creating the server. Check stderr and the process exit status if startup fails.
There is no CONFIG command to read or change live settings. Retain the config
and launch command as your record of the running setup.

Supply the same listener settings to the health command:

```sh
./zig-out/bin/kgcache healthcheck kgcache.conf --port 7000
```

For mounted container configs, follow [Docker configuration](docker.md#use-a-config-file).
For all defaults, ranges, quoting rules, and CLI forms, see the
[configuration reference](../reference/configuration.md).

# Use the process fixture

[Process tests](../README.md) / Harness

[server_process.zig](server_process.zig) owns a server from startup through
reaping. Use it instead of creating a second process-control path in a test.
Each instance gets a temporary working directory and its own selected port.

## Start and connect

The fixture writes a config, adds `--ready-fd`, starts the child, and reads:

```text
READY 127.0.0.1 <port>\n
```

That line is sent only after the listener is ready. Use its address for network
operations. A default fixture config sets:

| Setting | Value |
| --- | --- |
| `bind` | `127.0.0.1` |
| `port` | `0`, selecting an OS-assigned port |
| `cron-interval-ms` | `20` |
| `appenddirname` | `aof` |
| `appendfilename` | `appendonly.aof` |
| `reuse-address` | `yes` |

It otherwise uses `dir .` and `dbfilename dump.kgc` unless extra config
changes them. kgcache port 0 selects a port; Redis port 0 disables TCP. See
[configuration](../../../docs/reference/configuration.md) for that difference.

## Control config and argument placement

`config_subpath` defaults to `kgcache.conf`, relative to the child's working
directory. Its parent directories are created. Use `config/kgcache.conf` to
check relative path behavior with a config file outside the data directory.

Set `config_subpath = null` to write no config and start with CLI arguments.
`extra_config` applies only when a config file exists. `extra_args` is borrowed:
keep the slice and its bytes alive through start and restart.

`config_arg_index` counts how many extra arguments precede the config path.
Zero puts the path first; `extra_args.len` puts it last. Choose an index between
complete options, at most the argument count:

```zig
.{
    .extra_args = &.{ "--bind", "127.0.0.1", "--port", "0" },
    .config_arg_index = 2,
}
```

The index is ignored without a config path. Use `./-cache.conf` for a filename
starting with a hyphen. A bare `--` is an invalid kgcache argument.

For invalid readiness tests, set `auto_ready_fd = false` and supply the test
arguments yourself. Output capture, startup deadlines, and child cleanup still
apply even when readiness is expected to fail.

## Set deadlines and retain evidence

| Option | Default |
| --- | ---: |
| `startup_timeout_ms` | 5000 |
| `read_timeout_ms` | 3000 |
| `stop_timeout_ms` | 5000 |

The fixture drains stdout and stderr while the child runs, retaining up to
16 KiB of each. Failure output is printed once with its cause. `artifact_dir`
keeps failed configs and logs outside the temporary directory. The runner passes
it from `KGCACHE_TEST_ARTIFACT_DIR`.

Use `report_failures = false` for expected failures whose logs are asserted by
the test itself. The fixture still owns stopping and reaping.

## Restart and stop

A restart must reuse the chosen endpoint. With a config file, the fixture writes
the selected port into the next config. It also appends `--port <selected-port>`
after all overrides, including an initial `--port 0`. The next READY line must
report that same port.

Normal stop sends SIGTERM and waits for a normal exit within the stop deadline.
An overdue child is sent SIGKILL and reaped, then the case fails. Failed startup
also kills and reaps before reporting. Temporary data is removed after cleanup.
Go and Node fixtures follow this same readiness and process-ownership contract.

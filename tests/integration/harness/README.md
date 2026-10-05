# Process fixture

`server_process.zig` creates a separate temporary directory for each server and runs the child with that directory as its working directory. It writes the config with:

- `bind 127.0.0.1`
- `port 0`, so the OS selects an available port
- `cron-interval-ms 20`, short enough for tests without a busy loop
- `appenddirname aof` and `appendfilename appendonly.aof`
- `reuse-address yes`, so a stopped fixture can restart on its selected port

The fixture uses the default `dir .` and `dbfilename dump.kgc` unless a
test supplies these settings in its extra config.

The fixture relies on kgcache's `port 0` behavior to select an available
TCP port. Redis uses `port 0` to disable TCP. See
[Redis config compatibility](../../../docs/CONFIGURATION.md#redis-config-compatibility)
for this difference.

`config_subpath` selects the config file location relative to the child's
working directory. It defaults to `kgcache.conf`. The fixture creates its
parent directories. For example, `config/kgcache.conf` lets a test check
that relative `dir` settings use the working directory even when the
config file is elsewhere.

Set `config_subpath = null` for startup without a config file. The fixture
does not write a config file in that mode; supply settings such as
`--bind 127.0.0.1 --port 0` through `extra_args`. `extra_config` is used
only when a config file is present.

`config_arg_index` is the number of `extra_args` placed before the config
path. Its default of 0 places the path before overrides. Set it to
`extra_args.len` to place the path after overrides, or use an index
between complete options to place it between overrides. The index must
not exceed `extra_args.len`; it is ignored when the config path is omitted.
The fixture borrows `extra_args`, so keep the arguments and their bytes
alive through startup and restart.

For example, this places the path between two overrides:

```zig
.{
    .extra_args = &.{ "--bind", "127.0.0.1", "--port", "0" },
    .config_arg_index = 2,
}
```

Use `config_subpath = "./-cache.conf"` for a filename starting with a hyphen.
A bare `--` is rejected by kgcache; it does not mark the start of a path.

The fixture adds `--ready-fd <fd>` automatically. Set `auto_ready_fd = false`
when testing invalid readiness arguments supplied through `extra_args`.
These cases still capture logs, enforce the startup deadline, and reap
the child after failure.

Use the address from the child's `READY` line. Default deadlines are 5 seconds
for startup and shutdown, and 3 seconds for protocol reads. Override them with
`startup_timeout_ms`, `stop_timeout_ms`, and `read_timeout_ms`.

The fixture captures up to 16 KiB each of stdout and stderr while the child
runs and removes its temporary directory after each test. Pass `artifact_dir`
to retain failed fixtures' config and logs; the runner supplies it from
`KGCACHE_TEST_ARTIFACT_DIR`. Set `report_failures = false` for expected failures
whose logs the test checks itself.

When a test case fails, the fixture stops and reaps its child, then prints the captured stdout and stderr once. Startup and shutdown failures report their cause with the same output.

## Process contract

Start the executable in its own data directory with `<config_subpath> --ready-fd <fd>` by default. The config path can be omitted or placed among the override arguments. The child writes `READY 127.0.0.1 <port>\n` to that pipe after it starts listening. Parse the port from this line.

A restart writes the selected port into the next config when a file is
present and appends `--port <selected-port>` after all override arguments.
This keeps the same address even when the initial overrides contain
`--port 0`, including startup without a config file. The fixture requires
the same port in the next READY line. If startup fails or reaches its
deadline, kill and reap the child before reporting the error.

To stop, send SIGTERM and wait for a normal exit within the deadline. If the child stays alive, send SIGKILL and reap it. Capture stdout and stderr while it runs so full pipes cannot block the child. Go and Node client harnesses can follow this same contract.

# Use the process fixture

[Process tests](../README.md) / Harness

[server_process.zig](server_process.zig) owns a server from startup through
reaping. Use it instead of creating a second process-control path in a test.
Each instance gets a temporary working directory and its own selected port.

## Controlled persistence tests

`kgcache-controlled-server` starts from
[controlled_server.zig](../../../src/tests/controlled_server.zig). It shares the
normal [application's](../../../src/application.zig) startup, readiness, and
cleanup code. Its [controller](../../../src/tests/persistence_controller.zig)
starts inert. The application's one-time setup callback installs a drain hook
and fork, file-sync, and child-wait adapters after Server creation, before
supervision starts.

Each backend adapter saves the original fork function and I/O value. Its copied
I/O vtable replaces only file sync and keeps the original userdata. The wait
adapter delegates to the saved process function. It preserves null poll results,
source errors, and raw wait status. The kill function is unchanged.

Keep the controller, saved dependencies, copied vtables, and owned descriptors
at stable addresses through application cleanup. The entry closes controller
descriptors after the application returns. One controlled Server uses the
test-only active-controller pointer per process. Lifecycle hook contexts still
belong to each Server's caller.

`zig build test-integration` builds and runs the controlled entry as needed.
`zig build integration-tools` installs it without running it, at
`zig-out/libexec/kgcache-tests/kgcache-controlled-server`. Both executable
entries share the [effective version input](../../../docs/contribute/building.md#select-a-version).

Use `control_child` (`kgc` or `aof`) and `control_stage` (`before_write` or
`synced`, the default) to select the first matching fork attempt. That selection
is consumed even if the fork fails. Parent SAVE, startup I/O, journal flush,
other backends, and later children pass through without a gate.

| Stage | Meaning |
| --- | --- |
| `before_write` | The selected child has closed stdin and stdout and is held before its output work. Parent preparation may already have run. Release it or request failure. |
| `synced` | The selected child's output sync succeeded and the child is still held alive. File close may follow. |
| `draining` | Cron and workers have joined. Server reached its initial persistence drain while the selected child was still tracked. |
| `reaped` | A real wait collected the selected child's raw exit status. Publication and cleanup may still follow. |

The generic drain hook also runs for an empty drain. The controller emits a
`draining` record only for a tracked selected child. A final-save-only child
starts after that initial hook and produces no extra `draining` record.
Require real child reaping, publication, and restart checks for those results.

### Control pipes and commands

The [pipe protocol](../../../src/tests/test_control_protocol.zig) belongs to the
test harness. The normal executable does not parse `KGCACHE_TEST_CONTROL`.
Version and health modes return before the controlled entry activates controls.
The fixture supplies this setting with inherited descriptors of at least 3:

```text
KGCACHE_TEST_CONTROL="<event-write-fd> <release-read-fd> <kgc|aof> <before_write|synced>"
```

| Pipe | Fixture owns | Controlled process owns |
| --- | --- | --- |
| Events | Reader | Controller's writer, also inherited by fork children |
| Release | Writer | Controller's reader, also inherited by fork children |
| Readiness | Reader | Application's writer |

The fixture marks its event reader and release writer close-on-exec. It closes
its copies of the inherited ends when startup returns. The controller validates
the full setting before adopting its descriptors. Its close operation also
handles incomplete setup. Early process exit closes any unadopted inherited
descriptors. The application owns readiness delivery separately.

Each event is one raw `Event` struct write. It carries the server PID, selected
child PID, operation ID `1`, backend, stage, and status. The fixture checks
identity across events. For `reaped`, status is the child's real raw wait status,
including signal bits when shutdown uses SIGKILL.

`releaseChild()` writes `r`. `failChildWrite()` writes `f`; at `before_write`,
that makes the child exit with status 1 before backend output work. It cannot
return into application code or call the copied parent logger. At `synced`,
only `r` permits the child to continue.

The child polls the release pipe for at most 15000 ms. A failed event write
exits with 90. A timeout or failed poll exits with 91. A failed read, EOF, an
invalid command, or `f` at `synced` exits with 92. Closing the fixture's release
writer wakes a held child with EOF, so a lost harness cannot hold it indefinitely.

## Start and connect

The fixture writes a config, adds `--ready-fd`, starts the child, and reads:

```text
READY 127.0.0.1 <port>\n
```

That line reports the actual bound address after listener and cron startup.
The caller's ready hook runs before the write. A hook failure prevents output;
a write failure fails startup. The application closes its writer after a write
attempt, or during cleanup if notification was skipped. Use the reported address
for network operations. A default fixture config sets:

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
An overdue server process is sent SIGKILL and reaped, then the case fails.
Failed startup kills and reaps a live server before reporting.
Temporary data is removed after cleanup.
Go and Node fixtures follow this same readiness and process-ownership contract.

Always defer fixture destruction, including when assertions can fail with a
child still gated. If a live server still has a release writer, destruction
closes it and requests a normal stop so the parent can reap the held child.
It then closes control descriptors and forces parent cleanup if needed.

# Process fixture

`server_process.zig` creates a separate temporary directory for each server and runs the child with that directory as its working directory. It writes the config with:

- `bind 127.0.0.1`
- `port 0`, so the OS selects an available port
- `cron-interval-ms 20`, short enough for tests without a busy loop
- `snapshot-path dump.kgc`
- `append-dirname aof` and `append-filename appendonly.aof`
- `reuse-address yes`, so a stopped fixture can restart on its selected port

Use the address from the child's `READY` line. The fixture sets deadlines for startup, protocol reads, and shutdown. It captures up to 16 KiB each of stdout and stderr while the child runs. It removes the temporary directory after each test. Set `KGCACHE_TEST_ARTIFACT_DIR` to retain the config and bounded logs for failed tests.

## Process contract

Start the executable in its own data directory with `kgcache.conf --ready-fd <fd>`. The child writes `READY 127.0.0.1 <port>\n` to that pipe after it starts listening. Parse the port from this line. A restart writes that port into the next config and requires the same port in the next READY line. If startup fails or reaches its deadline, kill and reap the child before reporting the error.

To stop, send SIGTERM and wait for a normal exit within the deadline. If the child stays alive, send SIGKILL and reap it. Capture stdout and stderr while it runs so full pipes cannot block the child. Go and Node client harnesses can follow this same contract.

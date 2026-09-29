# Process fixture configuration

The process harness in later steps will create a separate temporary directory for each server fixture and run the child with that directory as its working directory. Write its config there with:

- `bind 127.0.0.1`
- `port 0`, so the OS selects an available port
- `cron-interval-ms 20`, short enough for tests without a busy loop
- `snapshot-path dump.kgc`
- `append-dirname aof` and `append-filename appendonly.aof`

The child working directory makes the snapshot and AOF paths unique to that fixture. Use the READY address from the child process to find the selected port. Keep each fixture's files separate, including when two servers run at once.

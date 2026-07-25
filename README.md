# kgcache

`kgcache` is a small Redis-protocol-compatible, in-memory cache server written in Zig. It listens on `127.0.0.1:6379` and currently supports storing and retrieving string values over RESP2.

It is an early-stage project in the [`kgx`](https://github.com/kgxlabs) family. The implementation favors a small, inspectable codebase while command and protocol compatibility grow incrementally.

## Current capabilities

| Area | Available behavior |
| --- | --- |
| Server | TCP server on `127.0.0.1:6379`; each connection is handled on a detached thread |
| Storage | Process-local, in-memory string key/value store backed by `StringHashMap` |
| Commands | `PING`, `ECHO`, `GET`, and `SET`; command names are case-insensitive |
| RESP | Parses RESP2 arrays, bulk strings (including null), simple strings, integers, and errors; serializes the same value types |
| Errors | Returns RESP error replies for malformed requests and unsupported commands or argument types |

## Requirements

- Zig 0.16.0 or newer
- Optional: `redis-cli` for the examples below

## Run it

Build the server:

```bash
zig build
```

Run it:

```bash
zig build run
```

The installed executable is named `main` and is written to `zig-out/bin/main`.

In another terminal, use a RESP-compatible client such as `redis-cli`:

```bash
redis-cli PING
# PONG

redis-cli SET greeting hello
# OK

redis-cli GET greeting
# "hello"

redis-cli GET missing
# (nil)

redis-cli ECHO hello
# "hello"
```

The values live only for the lifetime of the server process.

## Command behavior

| Command | Current behavior |
| --- | --- |
| `PING` | Responds with the simple string `PONG`. Arguments are currently ignored. |
| `ECHO <message>` | Returns `<message>` as a bulk string. Exactly one non-null bulk-string argument is required. |
| `SET <key> <value>` | Stores a string value and returns `OK`. Extra arguments are currently ignored; conditional and expiration options are not implemented. |
| `GET <key>` | Returns the stored bulk string, or a null bulk string when the key does not exist. Extra arguments are currently ignored. |
| `COMMAND <value>` | Placeholder only: returns its first argument; no Redis command introspection is implemented. |

## Development

Run the project test step:

```bash
zig build test
```

The source tree contains tests for RESP parsing and serialization, command dispatch, and the in-memory store.

## Repository layout

```text
.
├── build.zig
├── src/
│   ├── main.zig              # TCP server and connection loop
│   ├── resp.zig              # RESP parser, serializer, and protocol errors
│   ├── commander.zig         # Command dispatch
│   ├── commander/            # PING, ECHO, GET, SET, and command abstractions
│   ├── store/                # Store interface, in-memory store, and mock store
│   ├── object.zig            # Internal string object representation
│   └── tests.zig             # Test entry point
└── README.md
```

## Current limitations

- Only in-memory string values are supported; data is not persisted.
- No expiration, eviction, transactions, pub/sub, replication, clustering, authentication, or RESP3 support.
- The server uses a fixed 1 KiB read buffer and handles one parsed request per read, so pipelining and requests split across reads are not supported yet.
- Command argument validation is intentionally incomplete for `PING`, `GET`, and `SET`.
- The built-in `COMMAND` handler is a placeholder, not Redis-compatible introspection.

## License

No license file is currently included.

# kgcache documentation

Build an application with kgcache or run it as a service. Start with a
working example, then use the reference pages for exact behavior.

## Get started

- [Quick start](get-started/README.md): start a server, store a value, and
  read it from another connection.
- [Install kgcache](get-started/install.md): use the published image or
  compile the executable.

## Develop with kgcache

- [Strings and expiration](develop/strings.md): choose keys, write values,
  and replace entries with conditions or a lifetime.
- [Go](develop/clients/go.md): install go-redis and connect your application.
- [Node.js](develop/clients/node.md): install node-redis and connect your application.
- [Pipelines](develop/pipelining.md): send several commands on one connection.

## Operate kgcache

- [Docker and Compose](operate/docker.md): build, configure, and replace a container.
- [Configure a server](operate/configuration.md): load a file and override settings.
- [Persistence](operate/persistence.md): choose snapshots or an append-only file.
- [Shutdown and restart](operate/shutdown.md): stop a service and check its result.
- [Health and monitoring](operate/monitoring.md): probe the service and inspect connections.
- [Network access](operate/security.md): choose a trusted listener and network.
- [Troubleshooting](operate/troubleshooting.md): diagnose startup, client, and storage failures.

## Look up behavior

- [Commands](commands/README.md): one page for each command, with examples and replies.
- [Compatibility](reference/compatibility.md): exact tested clients and supported features.
- [Protocol](reference/protocol.md): request grammar, RESP2/RESP3 encodings, and transport limits.
- [Configuration reference](reference/configuration.md): defaults, ranges, and file grammar.

## Contribute to kgcache

The [contributor guides](contribute/README.md) cover development, testing,
architecture, and releases. Start with [CONTRIBUTING.md](../CONTRIBUTING.md)
when opening a change.

These pages describe current `main`. A release contains the behavior of its
recorded source commit. Use its release notes when running a published image.

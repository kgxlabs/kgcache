# Network access

[Docs](../README.md) / [Operate](README.md) / Network access

Run kgcache on a trusted network. The server has no authentication, ACLs, or
TLS. Anyone who can reach the listener can use its supported commands,
including commands that change data or request persistence.

## Bind a native server

The native default is loopback:

```conf
bind 127.0.0.1
port 6379
```

This accepts connections from the same host. Binding another address changes
who can reach the service. Use host and network access controls appropriate
to the listener. Database selection is a namespace choice, not isolation
between trusted and untrusted clients.

## Publish a container port

The image listens on `0.0.0.0` inside the container. The examples restrict the
published host port to loopback:

```text
127.0.0.1:6379:6379
```

Containers on an attached Docker network can reach the container directly.
Choose network membership deliberately. The Compose example also drops
capabilities, uses a non-root identity, and makes the root filesystem read-only.
These settings do not add client authentication.

## Configure clients

Leave credentials and connection names unset in the tested clients. AUTH,
HELLO AUTH, CLIENT SETNAME, and HELLO SETNAME are unsupported. A password in a
Redis URL does not protect this server; it makes the client request a feature
the server does not provide.

Use the [Go](../develop/clients/go.md) or [Node.js](../develop/clients/node.md)
connection settings, then check the
[compatibility reference](../reference/compatibility.md) for other client features.

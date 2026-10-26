# Connect with Node.js

[Docs](../../README.md) / [Develop](../README.md) / Node.js

Use node-redis to write and read string values from a running kgcache server.
This guide uses Node 22.14.0, npm 10.9.2, and the `redis` package at 6.2.1,
one of the exact [tested profiles](../../reference/compatibility.md#tested-clients).
Start a server on `127.0.0.1:6379` with the
[quick start](../../get-started/README.md) first.

## Install

Create an application directory outside the kgcache checkout:

```sh
mkdir kgcache-node-example
cd kgcache-node-example
npm init -y
npm install --save-exact redis@6.2.1
```

Keep `package.json` and `package-lock.json` with your application. Use `npm ci`
for later installs from that lock.

## Connect, write, and read

Save this as `example.mjs`:

```js
import { createClient } from 'redis';

const client = createClient({
  socket: {
    host: '127.0.0.1',
    port: 6379,
    connectTimeout: 3000,
    reconnectStrategy: false,
  },
  database: 0,
  commandOptions: { timeout: 3000 },
});
client.on('error', (error) => console.error(error.message));

try {
  await client.connect();
  await client.set('example:node', 'hello', { expiration: { type: 'EX', value: 60 } });
  const value = await client.get('example:node');
  console.log(value === null ? 'cache miss' : value);
  await client.del('example:node');
} finally {
  if (client.isOpen) client.destroy();
}
```

```sh
node example.mjs
```

Expected output:

```text
hello
```

The client negotiates RESP3 because `RESP` is omitted. Library identity
reporting can stay enabled. kgcache accepts CLIENT SETINFO. The example
disables reconnect attempts so a failed endpoint returns an error promptly.

## Use RESP2

Add `RESP: 2` to the same connection options:

```js
const client = createClient({
  RESP: 2,
  socket: {
    host: '127.0.0.1',
    port: 6379,
    connectTimeout: 3000,
    reconnectStrategy: false,
  },
  database: 0,
  commandOptions: { timeout: 3000 },
});
```

Run the program again. It prints the same value. Use `RESP: 3` when you want
to select RESP3 explicitly.

## Select a database and handle results

Set `database` to the required index. The default server accepts 0 through 15.
Database 0 is used when the option is omitted. A Redis URL can also select
a database with its path, such as `redis://127.0.0.1:6379/1`.

A missing GET and a null SET result are JavaScript `null`. Check them separately
from rejected promises caused by network or server errors.

Leave credentials and the connection `name` unset. Use plain TCP and a
standalone client. Cluster, Sentinel, transactions, pub/sub, tracking, and
client-side caching are outside the [supported contract](../../reference/compatibility.md).

## Next steps

Read [Strings and expiration](../strings.md), [Pipelines](../pipelining.md),
and the [SET reference](../../commands/set.md).

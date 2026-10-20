import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { createClient, RESP_TYPES } from 'redis';

export async function smoke(host: string, port: number): Promise<void> {
  assert(host.length > 0, 'host is required');
  assert(Number.isInteger(port) && port > 0 && port <= 65535, 'invalid port');

  for (const protocol of [undefined, 2, 3] as const) {
    const client = createClient({
      socket: { host, port, connectTimeout: 2000, socketTimeout: 2000, reconnectStrategy: false },
      commandOptions: { timeout: 2000 },
      database: 0,
      disableOfflineQueue: true,
      ...(protocol === undefined ? {} : { RESP: protocol }),
    }).withTypeMapping({ [RESP_TYPES.BLOB_STRING]: Buffer });

    const errors: Error[] = [];
    const key = `kgcache-smoke:node:${randomBytes(12).toString('hex')}`;
    const deadline = setTimeout(() => {
      errors.push(new Error('smoke exceeded 15 seconds'));

      if (client.isOpen) {
        client.destroy();
      }
    }, 15000);

    client.on('error', (error: Error) => errors.push(error));

    try {
      await client.connect();
      assert.equal(await client.ping(), 'PONG');
      const info = await client.clientInfo();
      assert.equal(info.resp, protocol ?? 3);
      const value = Buffer.from([98, 0, 255, 13, 10, 118]);
      assert.equal(await client.set(key, value), 'OK');
      assert.deepEqual(await client.get(key), value);
      const replies = await client
        .multi()
        .set(key, 'first')
        .get(key)
        .set(key, 'second')
        .get(key)
        .execAsPipeline();

      assert.deepEqual(replies, ['OK', Buffer.from('first'), 'OK', Buffer.from('second')]);
      await assert.rejects(client.sendCommand(['GET']), /wrong number of arguments/);
      assert.equal(await client.ping(), 'PONG');
      assert.equal((await client.clientInfo()).id, info.id);
      assert.deepEqual(errors, []);
      await client.del(key);
    } finally {
      clearTimeout(deadline);

      if (client.isOpen) {
        client.destroy();
      }
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    assert.equal(process.argv.length, 4, 'usage: smoke.ts HOST PORT');
    await smoke(process.argv[2]!, Number(process.argv[3]));
    console.log('node-redis: default, RESP2, RESP3 passed');
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Node endpoint smoke: ${message.slice(0, 1000)}`);
    process.exitCode = 1;
  }
}

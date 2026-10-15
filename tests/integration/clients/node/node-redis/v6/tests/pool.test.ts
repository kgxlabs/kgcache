import fs from 'node:fs';
import net from 'node:net';
import { once } from 'node:events';
import { parseReport } from '@/harness/report';
import { within } from '@/harness/server';
import type { Server } from '@/harness/server';
import { command, poll, protocols, withFixture, withPoolConnections } from '@/node-redis/v6/client';
import type { Client, Pool } from '@/node-redis/v6/client';

test.each(protocols)('pool expands and reuses idle connections in RESP %i', async (protocol) => {
  await withFixture('pool-reuse', protocol, async ({ connectPool, signal }) => {
    const pool = await connectPool({ database: 1, clientInfoTag: 'pool' });
    expect(pool.totalClients).toBe(1);
    let original: bigint[] = [];

    await withPoolConnections(pool, signal, async (clients) => {
      original = await connectionIDs(clients, protocol);
      expect(pool.clientsInUse).toBe(3);
      expect(pool.totalClients).toBe(3);
    });

    await poll(
      async () => pool.idleClients,
      (idle) => idle === 3,
      signal,
    );
    await withPoolConnections(pool, signal, async (clients) => {
      const reused = await connectionIDs(clients, protocol);
      expect(new Set(reused)).toEqual(new Set(original));

      for (const [index, client] of clients.entries()) {
        const key = `reused:${index}`;
        const value = `value:${index}`;
        expect(await command(client, client.set(key, value))).toBe('OK');
        expect(await command(client, client.get(key))).toBe(value);
      }
    });
  });
});

test.each(protocols)(
  'concurrent pool commands retain complete results in RESP %i',
  async (protocol) => {
    await withFixture('concurrent-pool', protocol, async ({ connectPool, signal }) => {
      const pool = await connectPool();
      const values = ['alpha:', 'bravo:', 'charlie:', 'delta:'].map((value) => value.repeat(64));
      expect(await command(pool, pool.set('shared', values[0]!))).toBe('OK');

      const workers = values.map(async (value, worker) => {
        try {
          for (let iteration = 0; iteration < 12; iteration++) {
            signal.throwIfAborted();

            const key = `worker:${worker}`;
            const expected = `${worker}:${iteration}:${value}`;
            expect(await command(pool, pool.set(key, expected))).toBe('OK');
            expect(await command(pool, pool.get(key))).toBe(expected);
            expect(await command(pool, pool.set('shared', value))).toBe('OK');
            expect(values).toContain(await command(pool, pool.get('shared')));
          }
        } catch (cause) {
          pool.destroy();
          throw cause;
        }
      });

      const results = await Promise.allSettled(workers);

      for (const result of results) {
        if (result.status === 'rejected') {
          throw result.reason;
        }
      }

      expect(await command(pool, pool.ping())).toBe('PONG');
      expect(pool.tasksQueueLength).toBe(0);
    });
  },
);

test.each(protocols)(
  'malformed peer leaves held pool connections intact in RESP %i',
  async (protocol) => {
    await withFixture('malformed-peer', protocol, async ({ connectPool, server, signal }) => {
      const pool = await connectPool({ database: 1, clientInfoTag: 'pool' });

      await withPoolConnections(pool, signal, async (clients) => {
        const original = await connectionIDs(clients, protocol);
        await malformedPeer(server);

        for (const [index, client] of clients.entries()) {
          const key = `healthy:${index}`;
          const value = `intact:${index}`;
          expect(await command(client, client.ping())).toBe('PONG');
          expect(await command(client, client.set(key, value))).toBe('OK');
          expect(await command(client, client.get(key))).toBe(value);
        }

        expect(await connectionIDs(clients, protocol)).toEqual(original);
      });
    });
  },
);

test('an assertion while holding pool connections releases callbacks and all owners', async () => {
  let pool: Pool | undefined;
  let server: Server | undefined;
  let released = false;

  await expect(
    withFixture(
      'pool-assertion-cleanup',
      3,
      async (fixture) => {
        server = fixture.server;
        pool = await fixture.connectPool();

        try {
          await withPoolConnections(pool, fixture.signal, async (clients) => {
            expect(clients).toHaveLength(3);
            expect(await command(clients[0]!, clients[0]!.ping())).toBe('intentional pool failure');
          });
        } finally {
          released = pool.clientsInUse === 0 && pool.tasksQueueLength === 0;
        }
      },
      { artifactDir: null },
    ),
  ).rejects.toThrow('intentional pool failure');

  expect(released).toBe(true);
  expect(pool!.isOpen).toBe(false);
  expect(pool!.totalClients).toBe(0);
  expect(pool!.listenerCount('error')).toBe(0);
  expect(server!.pid).toBeUndefined();
  expect(fs.existsSync(server!.dataDir)).toBe(false);
});

async function connectionIDs(clients: Client[], protocol: 2 | 3): Promise<bigint[]> {
  const ids: bigint[] = [];

  for (const client of clients) {
    const info = parseReport(await command(client, client.sendCommand(['CLIENT', 'INFO'])))[0]!;
    expect(info.fields).toMatchObject({
      db: '1',
      resp: String(protocol),
      'lib-name': 'node-redis(pool)',
      'lib-ver': '6.2.1',
    });
    expect(info.id).toBeGreaterThan(0n);
    ids.push(info.id);
  }

  expect(new Set(ids).size).toBe(clients.length);

  return ids;
}

async function malformedPeer(server: Server): Promise<void> {
  const socket = new net.Socket();
  const controller = new AbortController();
  const chunks: Buffer[] = [];
  const errors: unknown[] = [];
  const onData = (chunk: Buffer) => {
    chunks.push(chunk);

    if (chunks.reduce((bytes, data) => bytes + data.length, 0) > 1024) {
      socket.destroy(new Error('raw peer reply exceeded 1024 bytes'));
    }
  };

  const onError = (error: Error) => errors.push(error);
  let onClose!: () => void;
  const closed = new Promise<void>((resolve) => {
    onClose = resolve;
  });

  socket.once('close', onClose);
  socket.on('data', onData);
  socket.on('error', onError);

  try {
    const connected = once(socket, 'connect', { signal: controller.signal });
    socket.connect(server.address!);
    await within(connected, 3000, () => socket.destroy());
    socket.write('*1\r\n:42\r\n');
    await within(closed, 3000, () => socket.destroy());
    expect(errors).toEqual([]);
    expect(Buffer.concat(chunks).toString()).toBe('-ERR protocol error: invalid RESP type\r\n');
  } catch (cause) {
    errors.push(cause);
  } finally {
    controller.abort();
    socket.destroy();

    try {
      await within(closed, 3000, () => socket.destroy());
    } catch (cause) {
      errors.push(cause);
    }

    socket.off('close', onClose);
    socket.off('data', onData);
    socket.off('error', onError);
  }

  if (errors.length) {
    throw new AggregateError(errors, 'malformed peer exchange failed');
  }
}

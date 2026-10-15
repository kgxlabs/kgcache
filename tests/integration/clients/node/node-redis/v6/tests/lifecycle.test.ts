import fs from 'node:fs';
import { parseReport } from '@/harness/report';
import type { Server } from '@/harness/server';
import {
  clientVersion,
  command,
  poll,
  protocols,
  withFixture,
  withPoolConnections,
} from '@/node-redis/v6/client';
import type { Client } from '@/node-redis/v6/client';

test.each(protocols)(
  'original client recovers at the same endpoint in RESP %i',
  async (protocol) => {
    await withFixture('restart-recovery', protocol, async (fixture) => {
      const { connect, server, signal, allowDisconnect } = fixture;
      const client = await connect({ database: 1, clientInfoTag: 'recovery', recovery: true });
      expect(await command(client, client.ping())).toBe('PONG');
      const address = server.address;
      const events = allowDisconnect(client, true);

      await server.stop();
      await poll(
        async () => client.isReady,
        (ready) => !ready,
        signal,
      );
      await expect(client.ping()).rejects.toThrow();
      await server.start(signal);
      expect(server.address).toEqual(address);
      await poll(
        async () => client.isReady,
        (ready) => ready,
        signal,
      );
      allowDisconnect(client, false);

      expect(events.errors.length).toBeGreaterThan(0);
      expect(events.reconnects).toBeGreaterThan(0);
      expect(await command(client, client.set('after-restart', 'recovered'))).toBe('OK');
      expect(await command(client, client.get('after-restart'))).toBe('recovered');

      const info = await command(client, client.clientInfo());
      expect(info).toMatchObject({
        db: 1,
        resp: protocol,
        libName: 'node-redis(recovery)',
        libVer: clientVersion,
      });

      const observer = await connect();
      expect(await command(observer, observer.get('after-restart'))).toBeNull();
    });
  },
);

test.each(protocols)('fresh client uses a changed endpoint in RESP %i', async (protocol) => {
  await withFixture(
    'endpoint-change',
    protocol,
    async ({ connect, close, server, signal }) => {
      const oldClient = await connect();
      expect(await command(oldClient, oldClient.ping())).toBe('PONG');
      const address = server.address;
      const directory = server.dataDir;
      await close(oldClient);
      await server.stop();
      await server.start(signal);
      expect(server.address).not.toEqual(address);
      expect(server.dataDir).toBe(directory);

      const client = await connect({ database: 1 });
      expect(await command(client, client.set('new-endpoint', 'current-address'))).toBe('OK');
      expect(await command(client, client.get('new-endpoint'))).toBe('current-address');

      const info = await command(client, client.clientInfo());
      expect(info).toMatchObject({
        db: 1,
        resp: protocol,
        laddr: `${server.address!.host}:${server.address!.port}`,
      });
    },
    { newPortOnRestart: true },
  );
});

test.each(protocols)(
  'server stops with idle pool and client still connected in RESP %i',
  async (protocol) => {
    await withFixture('idle-client-shutdown', protocol, async (fixture) => {
      const { connect, connectPool, close, server, signal, allowDisconnect } = fixture;
      const pool = await connectPool();
      let members: Client[] = [];

      await withPoolConnections(pool, signal, async (clients) => {
        members = clients;
        const ids: bigint[] = [];

        for (const client of clients) {
          const report = parseReport(
            await command(client, client.sendCommand(['CLIENT', 'INFO'])),
          )[0]!;

          ids.push(report.id);
        }

        expect(new Set(ids).size).toBe(3);
      });

      await poll(
        async () => pool.idleClients,
        (idle) => idle === 3,
        signal,
      );
      const client = await connect();
      expect(await command(client, client.ping())).toBe('PONG');
      expect(client.isOpen).toBe(true);
      expect(pool.isOpen).toBe(true);
      allowDisconnect(client, true);
      allowDisconnect(pool, true);

      await server.stop();
      expect(server.pid).toBeUndefined();
      expect(server.exitStatus).toEqual({ code: 0, signal: null });
      await close(client);
      await close(pool);
      expect(client.isOpen).toBe(false);
      expect(pool.isOpen).toBe(false);
      expect(pool.tasksQueueLength).toBe(0);

      // The pinned pool can retain closed entries after an outage.
      for (const member of members) {
        expect(member.isOpen).toBe(false);
        expect(member.isReady).toBe(false);
      }
    });
  },
);

test('recovery deadline stops reconnect work and removes client and process owners', async () => {
  let client: Client | undefined;
  let server: Server | undefined;
  let reconnects = 0;

  await expect(
    withFixture(
      'recovery-deadline',
      3,
      async (fixture) => {
        server = fixture.server;
        client = await fixture.connect({ recovery: true });
        const events = fixture.allowDisconnect(client, true);
        await server.stop();
        await poll(
          async () => client!.isReady,
          (ready) => !ready,
          fixture.signal,
        );

        try {
          await poll(
            async () => client!.isReady,
            (ready) => ready,
            fixture.signal,
          );
        } finally {
          reconnects = events.reconnects;
        }
      },
      { scenarioTimeoutMs: 1000, artifactDir: null },
    ),
  ).rejects.toThrow('operation exceeded');

  expect(reconnects).toBeGreaterThan(0);
  expect(client!.isOpen).toBe(false);
  expect(client!.listenerCount('error')).toBe(0);
  expect(client!.listenerCount('reconnecting')).toBe(0);
  expect(client!.listenerCount('end')).toBe(0);
  expect(server!.pid).toBeUndefined();
  expect(fs.existsSync(server!.dataDir)).toBe(false);
});

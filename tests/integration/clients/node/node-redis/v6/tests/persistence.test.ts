import fs from 'node:fs';
import path from 'node:path';
import { RESP_TYPES } from 'redis';
import { command, protocols, withFixture } from '@/node-redis/v6/client';

test.each(protocols)(
  'SAVE restores text and binary values through fresh clients in RESP %i',
  async (protocol) => {
    await withFixture(
      'save-reload',
      protocol,
      async ({ server, connect, close, signal }) => {
        const original = await connect();
        const originalDb1 = await connect({ database: 1 });
        const key = Buffer.from([0, 255, 128]);
        const value = Buffer.from([255, 128, 0, 13, 10]);
        expect(await command(original, original.set('text', 'saved text'))).toBe('OK');
        expect(await command(original, original.set(key, value))).toBe('OK');
        expect(await command(originalDb1, originalDb1.set('text', 'saved DB 1'))).toBe('OK');
        expect(await command(original, original.sendCommand(['SAVE']))).toBe('OK');
        const snapshot = path.join(server.dataDir, 'state.kgc');
        expect(fs.statSync(snapshot).size).toBeGreaterThan(0);
        await close(originalDb1);
        await close(original);
        const address = server.address;
        await server.stop();
        expect(fs.existsSync(snapshot)).toBe(true);
        await server.start(signal);
        expect(server.address).toEqual(address);
        const restored = await connect();
        const restoredDb1 = await connect({ database: 1 });
        expect(restored).not.toBe(original);
        expect(await command(restored, restored.get('text'))).toBe('saved text');
        expect(await command(restoredDb1, restoredDb1.get('text'))).toBe('saved DB 1');
        const binary = restored.withTypeMapping({ [RESP_TYPES.BLOB_STRING]: Buffer });
        expect(await command(binary, binary.get(key))).toEqual(value);
        expect(await command(restored, restored.get('missing'))).toBeNull();
      },
      { scenarioTimeoutMs: 60000 },
    );
  },
);

test.each(protocols)('BGSAVE replies and leaves a healthy client in RESP %i', async (protocol) => {
  await withFixture(
    'bgsave-smoke',
    protocol,
    async ({ connect }) => {
      const client = await connect();
      expect(await command(client, client.set('key', 'snapshot value'))).toBe('OK');
      expect(await command(client, client.bgSave())).toMatch(
        /^Background saving (started|scheduled)$/,
      );
      expect(await command(client, client.ping())).toBe('PONG');
    },
    { scenarioTimeoutMs: 60000 },
  );
});

test.each(protocols)(
  'BGREWRITEAOF replies and leaves a healthy client in RESP %i',
  async (protocol) => {
    await withFixture(
      'bgrewriteaof-smoke',
      protocol,
      async ({ connect }) => {
        const client = await connect();
        expect(await command(client, client.set('key', 'AOF value'))).toBe('OK');
        expect(await command(client, client.bgRewriteAof())).toMatch(
          /^Background append only file rewriting (started|scheduled)$/,
        );
        expect(await command(client, client.ping())).toBe('PONG');
      },
      { extraConfig: 'appendonly yes\nappendfsync always\n', scenarioTimeoutMs: 60000 },
    );
  },
);

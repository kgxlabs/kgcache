import fs from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';
import { command, withFixture } from '@/node-redis/v6/client';
import type { Client } from '@/node-redis/v6/client';
import type { Server } from '@/harness/server';

test.each([
  { protocol: 2 as const, expected: 2 },
  { protocol: 3 as const, expected: 3 },
  { protocol: undefined, expected: 3 },
])('native handshake with RESP $protocol reports $expected', async ({ protocol, expected }) => {
  await withFixture('native-handshake', protocol, async ({ connect }) => {
    const client = await connect();
    expect(client.isReady).toBe(true);
    expect(await command(client, client.ping())).toBe('PONG');
    const info = await command(client, client.clientInfo());
    expect(info.resp).toBe(expected);
    expect(info.libName).toBe('node-redis');
    expect(info.libVer).toBe('6.2.1');
  });
});

test('assertion failure after connection preserves the failure and cleans all owners', async () => {
  let client: Client | undefined;
  let server: Server | undefined;
  await expect(
    withFixture(
      'assertion-cleanup',
      3,
      async (fixture) => {
        server = fixture.server;
        client = await fixture.connect();
        expect(await command(client, client.ping())).toBe('intentional assertion failure');
      },
      { artifactDir: null },
    ),
  ).rejects.toThrow('intentional assertion failure');
  expect(client!.isOpen).toBe(false);
  expect(server!.pid).toBeUndefined();
  expect(fs.existsSync(server!.dataDir)).toBe(false);
});

test('scenario deadline cancels waiting work and closes the connected client', async () => {
  let client: Client | undefined;
  await expect(
    withFixture(
      'scenario-deadline',
      3,
      async ({ connect, signal }) => {
        client = await connect();
        await delay(10000, undefined, { signal });
      },
      { scenarioTimeoutMs: 150, artifactDir: null },
    ),
  ).rejects.toThrow('operation exceeded');
  expect(client!.isOpen).toBe(false);
});

test('unexpected transport events fail the owning case', async () => {
  await expect(
    withFixture(
      'transport-observation',
      2,
      async ({ connect }) => {
        const client = await connect();
        client.emit('error', new Error('injected transport failure'));
        expect(await command(client, client.ping())).toBe('PONG');
      },
      { artifactDir: null },
    ),
  ).rejects.toThrow('injected transport failure');
});

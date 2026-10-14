import { command, poll, protocols, withFixture } from '@/node-redis/v6/client';

describe.each(protocols)('SET expiration RESP %i', (protocol) => {
  test.each(['EX', 'PX', 'EXAT', 'PXAT'] as const)(
    '%s expires after an immediate read',
    async (type) => {
      await withFixture(`expiration-${type}`, protocol, async ({ connect, signal }) => {
        const client = await connect();
        const values = {
          EX: 2,
          PX: 1500,
          EXAT: Math.ceil(Date.now() / 1000) + 2,
          PXAT: Date.now() + 1500,
        };

        expect(
          await command(
            client,
            client.set('expiring', 'value', {
              expiration: { type, value: values[type] },
            }),
          ),
        ).toBe('OK');
        expect(await command(client, client.get('expiring'))).toBe('value');

        expect(
          await poll(
            () => command(client, client.get('expiring')),
            (value) => value === null,
            signal,
          ),
        ).toBeNull();
      });
    },
  );

  test('KEEPTTL preserves the deadline while replacing the value', async () => {
    await withFixture('expiration-keepttl', protocol, async ({ connect, signal }) => {
      const client = await connect();

      expect(
        await command(
          client,
          client.set('key', 'old', {
            expiration: { type: 'PX', value: 1500 },
          }),
        ),
      ).toBe('OK');
      expect(await command(client, client.get('key'))).toBe('old');

      expect(await command(client, client.set('key', 'new', { expiration: 'KEEPTTL' }))).toBe('OK');
      expect(await command(client, client.get('key'))).toBe('new');

      expect(
        await poll(
          () => command(client, client.get('key')),
          (value) => value === null,
          signal,
        ),
      ).toBeNull();
    });
  });

  test('overwrite clears expiry and survives the former deadline', async () => {
    await withFixture('expiration-cleared', protocol, async ({ connect, signal }) => {
      const client = await connect();
      const oldDeadline = Date.now() + 1500;

      expect(
        await command(
          client,
          client.set('key', 'old', {
            expiration: { type: 'PXAT', value: oldDeadline },
          }),
        ),
      ).toBe('OK');
      expect(await command(client, client.get('key'))).toBe('old');

      expect(await command(client, client.set('key', 'new'))).toBe('OK');

      await poll(
        async () => {
          expect(await command(client, client.get('key'))).toBe('new');

          return Date.now();
        },
        (now) => now >= oldDeadline + 250,
        signal,
      );

      expect(await command(client, client.get('key'))).toBe('new');
    });
  });
});

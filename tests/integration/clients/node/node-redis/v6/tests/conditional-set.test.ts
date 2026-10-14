import { command, protocols, withFixture } from '@/node-redis/v6/client';

interface SetCase {
  name: string;
  exists: boolean;
  condition?: 'NX' | 'XX';
  get: boolean;
  reply: string | null;
  stored: string | null;
}

const cases: SetCase[] = [
  {
    name: 'NX inserts missing key',
    exists: false,
    condition: 'NX',
    get: false,
    reply: 'OK',
    stored: 'new',
  },
  {
    name: 'NX skips existing key',
    exists: true,
    condition: 'NX',
    get: false,
    reply: null,
    stored: 'old',
  },
  {
    name: 'XX skips missing key',
    exists: false,
    condition: 'XX',
    get: false,
    reply: null,
    stored: null,
  },
  {
    name: 'XX replaces existing key',
    exists: true,
    condition: 'XX',
    get: false,
    reply: 'OK',
    stored: 'new',
  },
  { name: 'GET inserts and returns null', exists: false, get: true, reply: null, stored: 'new' },
  {
    name: 'GET replaces and returns old value',
    exists: true,
    get: true,
    reply: 'old',
    stored: 'new',
  },
  {
    name: 'NX GET inserts and returns null',
    exists: false,
    condition: 'NX',
    get: true,
    reply: null,
    stored: 'new',
  },
  {
    name: 'NX GET skips and returns old value',
    exists: true,
    condition: 'NX',
    get: true,
    reply: 'old',
    stored: 'old',
  },
  {
    name: 'XX GET skips and returns null',
    exists: false,
    condition: 'XX',
    get: true,
    reply: null,
    stored: null,
  },
  {
    name: 'XX GET replaces and returns old value',
    exists: true,
    condition: 'XX',
    get: true,
    reply: 'old',
    stored: 'new',
  },
];

describe.each(protocols)('conditional SET RESP %i', (protocol) => {
  test.each(cases)('$name', async (row) => {
    await withFixture(row.name, protocol, async ({ connect }) => {
      const client = await connect();
      if (row.exists) {
        expect(await command(client, client.set('key', 'old'))).toBe('OK');
      }

      expect(
        await command(
          client,
          client.set('key', 'new', {
            condition: row.condition,
            GET: row.get,
          }),
        ),
      ).toBe(row.reply);
      expect(await command(client, client.get('key'))).toBe(row.stored);
    });
  });
});

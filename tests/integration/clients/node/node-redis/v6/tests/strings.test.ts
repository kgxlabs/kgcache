import { RESP_TYPES } from 'redis';
import { command, protocols, withFixture } from '@/node-redis/v6/client';

describe.each(protocols)('strings RESP %i', (protocol) => {
  test('text, empty keys/values, null, DEL counts, and DBSIZE', async () => {
    await withFixture('strings-text', protocol, async ({ connect }) => {
      const client = await connect();
      expect(await command(client, client.dbSize())).toBe(0);
      expect(await command(client, client.echo('hello\r\nworld'))).toBe('hello\r\nworld');
      expect(await command(client, client.echo(''))).toBe('');
      expect(await command(client, client.get('missing'))).toBeNull();
      expect(await command(client, client.set('key', 'value'))).toBe('OK');
      expect(await command(client, client.get('key'))).toBe('value');
      expect(await command(client, client.set('', ''))).toBe('OK');
      expect(await command(client, client.get(''))).toBe('');
      expect(await command(client, client.dbSize())).toBe(2);
      expect(await command(client, client.del(['key', '', 'missing']))).toBe(2);
      expect(await command(client, client.del(['key', 'missing']))).toBe(0);
      expect(await command(client, client.dbSize())).toBe(0);
    });
  });

  test('public Buffer reply mapping preserves exact binary bytes', async () => {
    await withFixture('strings-binary', protocol, async ({ connect }) => {
      const client = await connect();
      const binary = client.withTypeMapping({ [RESP_TYPES.BLOB_STRING]: Buffer });
      const key = Buffer.from([0, 255, 13, 10, 128, 61]);
      const value = Buffer.from([255, 0, 128, 13, 10, 195, 40]);
      expect(await command(binary, binary.echo(value))).toEqual(value);
      expect(await command(binary, binary.set(key, value))).toBe('OK');
      expect(await command(binary, binary.get(key))).toEqual(value);
      expect(await command(binary, binary.set(Buffer.alloc(0), Buffer.alloc(0)))).toBe('OK');
      expect(await command(binary, binary.get(Buffer.alloc(0)))).toEqual(Buffer.alloc(0));
      expect(await command(binary, binary.get(Buffer.from('missing')))).toBeNull();
      expect(await command(binary, binary.dbSize())).toBe(2);
      expect(await command(binary, binary.del(key))).toBe(1);
    });
  });
});

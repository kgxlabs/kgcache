import { command, protocols, withFixture } from '@/node-redis/v6/client';

test.each(protocols)(
  'nontransactional pipeline preserves all reply positions in RESP %i',
  async (protocol) => {
    await withFixture('ordered-pipeline', protocol, async ({ connect }) => {
      const client = await connect();

      const replies = await command(
        client,
        client
          .multi()
          .set('a', 'first')
          .get('a')
          .get('missing')
          .set('b', 'second')
          .del('a')
          .get('a')
          .dbSize()
          .echo('tail')
          .ping()
          .execAsPipeline(),
      );

      expect(replies).toHaveLength(9);
      expect(replies).toEqual(['OK', 'first', null, 'OK', 1, null, 1, 'tail', 'PONG']);

      expect(await command(client, client.get('b'))).toBe('second');
      expect(await command(client, client.ping())).toBe('PONG');
    });
  },
);

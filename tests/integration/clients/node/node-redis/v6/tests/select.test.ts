import { command, protocols, withFixture } from '@/node-redis/v6/client';

describe.each(protocols)('database selection RESP %i', (protocol) => {
  test('initial DB 1 is isolated from a separately owned DB 0 connection', async () => {
    await withFixture('initial-database', protocol, async ({ connect }) => {
      const db1 = await connect({ database: 1 });
      const db0 = await connect();
      expect(await command(db1, db1.set('shared-key', 'one'))).toBe('OK');
      expect(await command(db0, db0.get('shared-key'))).toBeNull();
      expect(await command(db0, db0.set('shared-key', 'zero'))).toBe('OK');
      expect(await command(db1, db1.get('shared-key'))).toBe('one');
      expect(await command(db0, db0.get('shared-key'))).toBe('zero');
      expect((await command(db1, db1.clientInfo())).db).toBe(1);
      expect((await command(db0, db0.clientInfo())).db).toBe(0);
    });
  });

  test('explicit SELECT and a rejected selection preserve per-connection state', async () => {
    await withFixture('explicit-select', protocol, async ({ connect }) => {
      const selected = await connect();
      const peer = await connect();
      expect(await command(selected, selected.set('key', 'zero'))).toBe('OK');
      expect(await command(selected, selected.select(1))).toBeUndefined();
      expect(await command(selected, selected.get('key'))).toBeNull();
      expect(await command(selected, selected.set('key', 'one'))).toBe('OK');
      await expect(command(selected, selected.select(2))).rejects.toThrow(/DB|database/i);
      expect(await command(selected, selected.get('key'))).toBe('one');
      expect((await command(selected, selected.clientInfo())).db).toBe(1);
      expect(await command(peer, peer.get('key'))).toBe('zero');
      expect((await command(peer, peer.clientInfo())).db).toBe(0);
      expect(await command(selected, selected.select(0))).toBeUndefined();
      expect(await command(selected, selected.get('key'))).toBe('zero');
    });
  });
});

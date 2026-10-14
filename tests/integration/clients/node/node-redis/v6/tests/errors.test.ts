import { ErrorReply } from 'redis';
import { parseReport } from '@/harness/report';
import { command, protocols, withFixture } from '@/node-redis/v6/client';

const invalidCommands = [
  { args: ['GET'], message: 'ERR wrong number of arguments' },
  { args: ['SET', 'key'], message: 'ERR wrong number of arguments' },
  { args: ['SET', 'key', 'value', 'NX', 'XX'], message: 'ERR syntax error' },
  { args: ['SELECT', '2'], message: 'ERR DB index is out of range' },
  { args: ['CLIENT', 'UNKNOWN'], message: 'ERR unsupported option' },
  { args: ['INFO'], message: 'ERR unknown command' },
];

describe.each(protocols)('command error recovery RESP %i', (protocol) => {
  test.each(invalidCommands)(
    '$args is a command rejection and preserves the same connection',
    async ({ args, message }) => {
      await withFixture(`command-error-${args.join('-')}`, protocol, async ({ connect }) => {
        const client = await connect();
        const before = parseReport(
          await command(client, client.sendCommand(['CLIENT', 'INFO'])),
        )[0]!;

        const rejected = command(client, client.sendCommand(args));
        await expect(rejected).rejects.toBeInstanceOf(ErrorReply);
        await expect(rejected).rejects.toThrow(message);
        expect(await command(client, client.ping())).toBe('PONG');
        const after = parseReport(
          await command(client, client.sendCommand(['CLIENT', 'INFO'])),
        )[0]!;

        expect(after.id).toBe(before.id);
        expect(after.fields.resp).toBe(String(protocol));
      });
    },
  );

  test('same-turn commands keep ordered outcomes around a rejected pipeline command', async () => {
    await withFixture('pipeline-error-recovery', protocol, async ({ connect }) => {
      const client = await connect();
      const before = parseReport(await command(client, client.sendCommand(['CLIENT', 'INFO'])))[0]!;
      // Queue all native calls before yielding so node-redis pipelines this batch.
      const pending = [
        command(client, client.set('key', 'value')),
        command(client, client.sendCommand(['SET', 'broken'])),
        command(client, client.get('key')),
        command(client, client.del('key')),
        command(client, client.get('key')),
      ];

      const outcomes = await Promise.allSettled(pending);
      expect(outcomes).toHaveLength(5);
      expect(outcomes[0]).toEqual({ status: 'fulfilled', value: 'OK' });
      expect(outcomes[1]).toEqual({ status: 'rejected', reason: expect.any(ErrorReply) });
      if (outcomes[1]!.status === 'rejected') {
        expect(outcomes[1]!.reason.message).toBe('ERR wrong number of arguments');
      }

      expect(outcomes.slice(2)).toEqual([
        { status: 'fulfilled', value: 'value' },
        { status: 'fulfilled', value: 1 },
        { status: 'fulfilled', value: null },
      ]);
      expect(await command(client, client.ping())).toBe('PONG');
      const after = parseReport(await command(client, client.sendCommand(['CLIENT', 'INFO'])))[0]!;
      expect(after.id).toBe(before.id);
    });
  });
});

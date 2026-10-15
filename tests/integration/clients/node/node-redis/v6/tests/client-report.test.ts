import { RESP_TYPES } from 'redis';
import { parseReport } from '@/harness/report';
import { clientVersion, command, withFixture } from '@/node-redis/v6/client';

test.each([2 as const, 3 as const, undefined])(
  'caller report and identity RESP %s',
  async (protocol) => {
    await withFixture('caller-report', protocol, async ({ connect, server }) => {
      const client = await connect();
      const precise = client.withTypeMapping({ [RESP_TYPES.NUMBER]: String });

      const hello = await command(precise, precise.hello());
      expect(hello).toMatchObject({
        server: 'kgcache',
        proto: String(protocol ?? 3),
        mode: 'standalone',
        role: 'master',
        modules: [],
      });

      const rows = parseReport(await command(client, client.sendCommand(['CLIENT', 'INFO'])));
      expect(rows).toHaveLength(1);

      const report = rows[0]!;
      expect(report.id).toBe(BigInt(hello.id));
      expect(report.id).toBeGreaterThan(0n);
      expect(report.fields).toMatchObject({
        laddr: `${server.address!.host}:${server.address!.port}`,
        db: '0',
        cmd: 'client|info',
        resp: String(protocol ?? 3),
        'lib-name': 'node-redis',
        'lib-ver': clientVersion,
        name: '',
        sub: '0',
        psub: '0',
        ssub: '0',
        watch: '0',
        multi: '-1',
        'multi-mem': '0',
        redir: '-1',
      });
      expect(report.fields.addr).toMatch(/^127\.0\.0\.1:[1-9][0-9]*$/);
      expect(BigInt(report.fields.fd)).toBeGreaterThanOrEqual(0n);
      expect(report.counters['tot-net-in']).toBeGreaterThan(0n);
      expect(report.counters['tot-net-out']).toBeGreaterThan(0n);
      expect(report.counters['tot-cmds']).toBeGreaterThan(0n);
      expect(report.counters.age).toBeGreaterThanOrEqual(report.counters.idle);

      const native = await command(client, client.clientInfo());
      expect(BigInt(native.id)).toBe(report.id);
      expect(native.libName).toBe(report.fields['lib-name']);
      expect(native.libVer).toBe(report.fields['lib-ver']);
      expect(native.resp).toBe(protocol ?? 3);

      expect(
        await command(
          client,
          client.sendCommand(['CLIENT', 'SETINFO', 'LIB-NAME', 'retained-name']),
        ),
      ).toBe('OK');
      expect(
        await command(client, client.sendCommand(['CLIENT', 'SETINFO', 'LIB-VER', '9.8.7'])),
      ).toBe('OK');
      expect(await command(client, client.ping())).toBe('PONG');

      const retained = parseReport(
        await command(client, client.sendCommand(['CLIENT', 'INFO'])),
      )[0]!;

      expect(retained.id).toBe(report.id);
      expect(retained.fields['lib-name']).toBe('retained-name');
      expect(retained.fields['lib-ver']).toBe('9.8.7');
      expect(retained.counters['tot-cmds']).toBeGreaterThan(report.counters['tot-cmds']);
    });
  },
);

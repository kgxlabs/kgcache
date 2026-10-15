import { parseReport } from '@/harness/report';
import { clientVersion, command, poll, protocols, withFixture } from '@/node-redis/v6/client';

test.each(protocols)('CLIENT LIST retains independent live peers in RESP %i', async (protocol) => {
  await withFixture('live-client-list', protocol, async ({ connect, close, signal }) => {
    const caller = await connect();
    const peerProtocol = protocol === 2 ? 3 : 2;
    const peer = await connect({ protocol: peerProtocol, database: 1, clientInfoTag: 'peer' });
    expect(
      await command(peer, peer.sendCommand(['CLIENT', 'SETINFO', 'LIB-VER', 'peer-version'])),
    ).toBe('OK');
    const callerInfo = parseReport(
      await command(caller, caller.sendCommand(['CLIENT', 'INFO'])),
    )[0]!;

    const peerInfo = parseReport(await command(peer, peer.sendCommand(['CLIENT', 'INFO'])))[0]!;
    const rows = parseReport(await command(caller, caller.sendCommand(['CLIENT', 'LIST'])));
    expect(rows).toHaveLength(2);

    const ids = rows.map((row) => row.id);
    expect(ids).toContain(callerInfo.id);
    expect(ids).toContain(peerInfo.id);
    expect(ids[0]!).toBeLessThan(ids[1]!);
    expect(rows.find((row) => row.id === callerInfo.id)!.fields).toMatchObject({
      db: '0',
      resp: String(protocol),
      'lib-name': 'node-redis',
      'lib-ver': clientVersion,
    });
    expect(rows.find((row) => row.id === peerInfo.id)!.fields).toMatchObject({
      db: '1',
      resp: String(peerProtocol),
      'lib-name': 'node-redis(peer)',
      'lib-ver': 'peer-version',
    });

    const native = await command(caller, caller.clientList());
    expect(native.map((row) => BigInt(row.id))).toEqual(ids);
    expect(native.find((row) => BigInt(row.id) === peerInfo.id)).toMatchObject({
      db: 1,
      resp: peerProtocol,
      libName: 'node-redis(peer)',
      libVer: 'peer-version',
    });

    await close(peer);

    const remaining = await poll(
      async () => parseReport(await command(caller, caller.sendCommand(['CLIENT', 'LIST']))),
      (reports) => reports.every((row) => row.id !== peerInfo.id),
      signal,
    );

    expect(remaining.map((row) => row.id)).toEqual([callerInfo.id]);
    expect(await command(caller, caller.ping())).toBe('PONG');
  });
});

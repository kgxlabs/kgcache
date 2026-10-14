import fs from 'node:fs';
import { Server } from './server.ts';

test('READY selects a loopback port and stop/start preserves directory and endpoint', async () => {
  const server = new Server();
  try {
    await server.start();
    const address = server.address;
    expect(address).toEqual({ host: '127.0.0.1', port: expect.any(Number) });
    expect(address!.port).toBeGreaterThan(0);
    expect(server.pid).toBeGreaterThan(0);
    await server.stop();
    expect(server.pid).toBeUndefined();
    expect(server.exitStatus).toEqual({ code: 0, signal: null });
    expect(fs.existsSync(server.dataDir)).toBe(true);
    await server.start();
    expect(server.address).toEqual(address);
  } finally {
    await server.cleanup();
  }

  await server.cleanup();
  expect(fs.existsSync(server.dataDir)).toBe(false);
});

test('independent fixtures own different processes, endpoints, and directories', async () => {
  const first = new Server();
  const second = new Server();
  try {
    await first.start();
    await second.start();
    expect(first.address).not.toEqual(second.address);
    expect(first.pid).not.toEqual(second.pid);
    expect(first.dataDir).not.toEqual(second.dataDir);
    await first.cleanup();
    expect(second.pid).toBeGreaterThan(0);
  } finally {
    await Promise.allSettled([first.cleanup(), second.cleanup()]).then((results) => {
      for (const result of results) {
        if (result.status === 'rejected') {
          throw result.reason;
        }
      }
    });
  }
});

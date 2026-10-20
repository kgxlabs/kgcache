import net from 'node:net';
import { smoke } from '@/node-redis/v6/smoke';
import { Server } from '@/harness/server';

test('endpoint smoke accepts a native service and rejects an unavailable endpoint', async () => {
  const server = new Server();

  try {
    await server.start();
    const address = server.address!;
    await smoke(address.host, address.port);
    await server.stop();
    await expect(smoke(address.host, address.port)).rejects.toThrow();
  } finally {
    await server.cleanup();
  }
});

test('endpoint smoke rejects a peer that speaks another protocol', async () => {
  const server = net.createServer((socket) => {
    socket.setTimeout(1000, () => socket.destroy());
    socket.resume();
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
  });

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));

  try {
    const address = server.address() as net.AddressInfo;
    await expect(smoke('127.0.0.1', address.port)).rejects.toThrow();
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { getEventListeners } from 'node:events';
import { PassThrough } from 'node:stream';
import { readReady, Server } from '@/harness/server';

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

test.each([
  'READY 127.0.0.1 0\n',
  'READY 127.0.0.1 65536\n',
  'READY localhost 1234\n',
  'READY 127.0.0.1 1234\nextra\n',
  'x'.repeat(129),
])('rejects malformed READY %j and removes listeners', async (record) => {
  const stream = new PassThrough();
  const pending = readReady(stream, new Promise(() => {}), 1000);
  try {
    stream.write(record);
    await expect(pending).rejects.toThrow(/malformed|oversized/);
    expect(stream.listenerCount('data')).toBe(0);
    expect(stream.listenerCount('end')).toBe(0);
    expect(stream.listenerCount('error')).toBe(0);
  } finally {
    stream.destroy();
  }
});

test('accepts split READY and removes cancellation listeners', async () => {
  const stream = new PassThrough();
  const controller = new AbortController();
  const pending = readReady(stream, new Promise(() => {}), 1000, controller.signal);
  try {
    stream.write('REA');
    stream.write('DY 127.0.0.1 ');
    stream.write('1234\n');
    await expect(pending).resolves.toEqual({ host: '127.0.0.1', port: 1234 });
    expect(stream.listenerCount('data')).toBe(0);
    expect(stream.listenerCount('end')).toBe(0);
    expect(stream.listenerCount('error')).toBe(0);
    expect(getEventListeners(controller.signal, 'abort')).toEqual([]);
  } finally {
    stream.destroy();
  }
});

test.each(['EOF', 'error', 'exit', 'deadline', 'cancel'])(
  '%s releases READY listeners',
  async (kind) => {
    const stream = new PassThrough();
    const controller = new AbortController();
    let close!: () => void;
    const closed = new Promise<void>((resolve) => {
      close = resolve;
    });

    const pending = readReady(stream, closed, kind === 'deadline' ? 20 : 1000, controller.signal);
    try {
      if (kind === 'EOF') {
        stream.end();
      } else if (kind === 'error') {
        stream.emit('error', new Error('injected stream failure'));
      } else if (kind === 'exit') {
        close();
      } else if (kind === 'cancel') {
        controller.abort(new Error('caller cancelled'));
      }

      await expect(pending).rejects.toThrow();
      expect(stream.listenerCount('data')).toBe(0);
      expect(stream.listenerCount('end')).toBe(0);
      expect(stream.listenerCount('error')).toBe(0);
      expect(getEventListeners(controller.signal, 'abort')).toEqual([]);
    } finally {
      close();
      stream.destroy();
    }
  },
);

test.each([
  { extraConfig: 'unknown-option yes\n' },
  { executable: '/absolute/path/to/nonexistent-kgcache' },
  { executable: process.execPath, extraArgs: ['-e', 'process.exit(7)'] },
  { executable: process.execPath, extraArgs: ['-e', 'setInterval(() => {}, 1000)'] },
])('startup failure reaps children and supports repeated cleanup: %j', async (options) => {
  const server = new Server({ ...options, startupTimeoutMs: 100, artifactDir: null });
  try {
    await expect(server.start()).rejects.toThrow('server startup failed');
    expect(server.pid).toBeUndefined();
    expect(server.exitStatus).toBeDefined();
  } finally {
    await server.cleanup();
    await server.cleanup();
  }

  expect(fs.existsSync(server.dataDir)).toBe(false);
});

test('startup cancellation reaps a running child with fresh cleanup ownership', async () => {
  const server = new Server({
    executable: process.execPath,
    extraArgs: ['-e', 'setInterval(() => {}, 1000)'],
    artifactDir: null,
  });

  const controller = new AbortController();
  try {
    const pending = server.start(controller.signal);
    const pid = server.pid!;
    controller.abort();
    await expect(pending).rejects.toThrow('server startup failed');
    expect(() => process.kill(pid, 0)).toThrow();
    expect(getEventListeners(controller.signal, 'abort')).toEqual([]);
  } finally {
    await server.cleanup();
  }
});

test('forced stop fails, drains bounded logs, reaps the child, and retains evidence', async () => {
  const artifacts = fs.mkdtempSync(path.join(os.tmpdir(), 'kgcache-node-artifacts-'));
  const server = new Server({
    executable: process.execPath,
    extraArgs: [
      '-e',
      `const fs = require('node:fs');
       process.on('SIGTERM', () => {});
       process.stdout.write('o'.repeat(32768));
       process.stderr.write('e'.repeat(32768));
       fs.writeSync(3, 'READY 127.0.0.1 1234\\n');
       setInterval(() => {}, 1000);`,
    ],
    stopTimeoutMs: 50,
    artifactDir: artifacts,
    reportFailures: false,
  });

  try {
    await server.start();
    const pid = server.pid!;
    await expect(server.stop()).rejects.toThrow('operation exceeded');
    expect(() => process.kill(pid, 0)).toThrow();
    expect(server.stdout.length).toBe(16384);
    expect(server.stderr.length).toBe(16384);
    expect(server.exitStatus).toEqual({ code: null, signal: 'SIGKILL' });
    const bundle = path.join(artifacts, fs.readdirSync(artifacts)[0]!);
    expect(fs.readFileSync(path.join(bundle, 'kgcache.conf'), 'utf8')).toContain('port 0');
    expect(JSON.parse(fs.readFileSync(path.join(bundle, 'failure.json'), 'utf8'))).toMatchObject({
      terminationReason: 'forced SIGKILL',
      exitStatus: { code: null, signal: 'SIGKILL' },
    });
  } finally {
    await server.cleanup();
    fs.rmSync(artifacts, { recursive: true, force: true });
  }
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

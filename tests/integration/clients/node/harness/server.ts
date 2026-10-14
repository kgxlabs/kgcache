import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { Readable } from 'node:stream';

export interface ServerOptions {
  executable?: string;
  extraArgs?: string[];
  extraConfig?: string;
  startupTimeoutMs?: number;
  stopTimeoutMs?: number;
  artifactDir?: string | null;
  reportFailures?: boolean;
}

interface ExitStatus {
  code: number | null;
  signal: NodeJS.Signals | null;
}

const logLimit = 16 * 1024;

/** Owns the process and its directory across explicit stop/start cycles. */
export class Server {
  readonly dataDir: string;
  readonly options: ServerOptions;
  address?: { host: string; port: number };
  exitStatus?: ExitStatus;
  config = '';
  stdout = Buffer.alloc(0);
  stderr = Buffer.alloc(0);
  private child?: ChildProcess;
  private closed?: Promise<void>;
  private processError?: Error;
  private cleaned = false;
  private reported = false;
  terminationReason = 'not started';

  constructor(options: ServerOptions = {}) {
    this.options = options;
    this.dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kgcache-node-'));
  }

  async start(signal?: AbortSignal): Promise<void> {
    if (this.cleaned || this.child) {
      throw new Error('fixture is cleaned or already running');
    }

    const executable = this.options.executable ?? process.env.KGCACHE_BIN;
    if (!executable || !path.isAbsolute(executable)) {
      throw new Error('KGCACHE_BIN must be an absolute executable path');
    }

    signal?.throwIfAborted();
    this.config = [
      'bind 127.0.0.1',
      `port ${this.address?.port ?? 0}`,
      'reuse-address yes',
      'cron-interval-ms 20',
      'databases 2',
      'save ""',
      'appendonly no',
      'dbfilename state.kgc',
      'appenddirname aof',
      'appendfilename appendonly.aof',
      this.options.extraConfig ?? '',
      '',
    ].join('\n');
    const configPath = path.join(this.dataDir, 'kgcache.conf');
    fs.writeFileSync(configPath, this.config);
    this.stdout = Buffer.alloc(0);
    this.stderr = Buffer.alloc(0);
    this.exitStatus = undefined;
    this.processError = undefined;
    this.terminationReason = 'running';
    const child = spawn(
      executable,
      [...(this.options.extraArgs ?? []), configPath, '--ready-fd', '3'],
      { cwd: this.dataDir, stdio: ['ignore', 'pipe', 'pipe', 'pipe'], shell: false },
    );

    this.child = child;
    this.closed = new Promise((resolve) => {
      child.once('close', (code, exitSignal) => {
        this.exitStatus = { code, signal: exitSignal };
        resolve();
      });
    });
    child.on('error', (error) => {
      this.processError = error;
    });
    this.drain(child.stdout, 'stdout');
    this.drain(child.stderr, 'stderr');
    const ready = child.stdio[3] as Readable;

    try {
      const address = await readReady(
        ready,
        this.closed,
        this.options.startupTimeoutMs ?? 5000,
        signal,
      );

      if (child.exitCode !== null || child.signalCode !== null || this.processError) {
        throw new Error('child exited during startup', { cause: this.processError });
      }

      if (this.address && address.port !== this.address.port) {
        throw new Error('restart changed the endpoint');
      }

      this.address = address;
    } catch (cause) {
      this.terminationReason = 'startup failure';
      await this.terminate();
      this.retainFailure('harness-startup', cause);
      throw new Error('server startup failed', { cause });
    } finally {
      ready.destroy();
    }
  }

  async stop(): Promise<void> {
    if (!this.child) {
      return;
    }

    const child = this.child;
    this.terminationReason = 'SIGTERM';
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
    }

    try {
      await within(this.closed!, this.options.stopTimeoutMs ?? 5000, () => {
        this.terminationReason = 'forced SIGKILL';
        child.kill('SIGKILL');
      });
      if (this.processError || this.exitStatus?.code !== 0) {
        throw new Error(`server stop failed: ${JSON.stringify(this.exitStatus)}`, {
          cause: this.processError,
        });
      }
    } catch (cause) {
      await this.terminate();
      this.retainFailure('harness-stop', cause);
      throw cause;
    } finally {
      await this.terminate();
    }
  }

  async cleanup(): Promise<void> {
    if (this.cleaned) {
      return;
    }

    try {
      await this.stop();
    } finally {
      fs.rmSync(this.dataDir, { recursive: true, force: true });
      this.cleaned = true;
    }
  }

  get pid(): number | undefined {
    return this.child?.pid;
  }

  retainFailure(label: string, cause: unknown): void {
    if (this.reported) {
      return;
    }

    this.reported = true;
    const artifactRoot =
      this.options.artifactDir === undefined
        ? process.env.KGCACHE_TEST_ARTIFACT_DIR
        : this.options.artifactDir;

    if (artifactRoot === null) {
      return;
    }

    if (this.options.reportFailures !== false) {
      console.error(
        `${label}: ${String(cause)}\n${this.stdout.toString()}\n${this.stderr.toString()}`,
      );
    }

    if (!artifactRoot) {
      return;
    }

    const safeLabel = label.replace(/[^a-zA-Z0-9.-]/g, '_').slice(0, 120);
    fs.mkdirSync(artifactRoot, { recursive: true });
    const destination = fs.mkdtempSync(path.join(path.resolve(artifactRoot), `${safeLabel}-`));
    const files = fs.readdirSync(this.dataDir, { recursive: true }).slice(0, 64);
    const listing = files.map((file) => {
      const relative = String(file);
      const filename = path.join(this.dataDir, relative);
      const stat = fs.lstatSync(filename);
      const checksum =
        stat.isFile() && stat.size <= 1024 * 1024
          ? createHash('sha256').update(fs.readFileSync(filename)).digest('hex')
          : undefined;

      return { path: relative, bytes: stat.size, sha256: checksum };
    });

    fs.writeFileSync(path.join(destination, 'kgcache.conf'), this.config.slice(0, logLimit));
    fs.writeFileSync(path.join(destination, 'stdout.log'), this.stdout);
    fs.writeFileSync(path.join(destination, 'stderr.log'), this.stderr);
    fs.writeFileSync(
      path.join(destination, 'failure.json'),
      JSON.stringify(
        {
          label,
          cause: String(cause).slice(0, logLimit),
          processError: this.processError?.message,
          address: this.address,
          exitStatus: this.exitStatus,
          terminationReason: this.terminationReason,
          files: listing,
        },
        null,
        2,
      ),
    );
  }

  private drain(stream: Readable | null, target: 'stdout' | 'stderr'): void {
    stream?.on('data', (chunk: Buffer) => {
      this[target] = Buffer.concat([
        this[target],
        chunk.subarray(0, logLimit - this[target].length),
      ]);
    });
    stream?.on('error', (error) => {
      this.processError = error;
    });
  }

  private async terminate(): Promise<void> {
    const child = this.child;
    if (!child) {
      return;
    }

    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
    }

    await within(this.closed!, 3000, () => {
      for (const stream of child.stdio) {
        stream?.destroy();
      }
    });
    child.removeAllListeners();
    for (const stream of child.stdio) {
      stream?.removeAllListeners();
      stream?.destroy();
    }

    this.child = undefined;
    this.closed = undefined;
  }
}

/** Reads one bounded readiness record and removes every temporary listener. */
export async function readReady(
  stream: Readable,
  closed: Promise<void>,
  timeoutMs: number,
  signal?: AbortSignal,
): Promise<{ host: string; port: number }> {
  let bytes = '';
  let onData: (chunk: Buffer) => void;
  let onEnd: () => void;
  let onError: (error: Error) => void;
  let onAbort: () => void;
  const record = new Promise<{ host: string; port: number }>((resolve, reject) => {
    onData = (chunk) => {
      bytes += chunk.toString('ascii');
      if (bytes.length > 128) {
        reject(new Error('oversized READY record'));
        return;
      }

      if (!bytes.includes('\n')) {
        return;
      }

      const match = /^READY 127\.0\.0\.1 ([1-9][0-9]{0,4})\n$/.exec(bytes);
      const port = Number(match?.[1]);
      if (!match || port > 65535) {
        reject(new Error(`malformed READY: ${JSON.stringify(bytes)}`));
        return;
      }

      resolve({ host: '127.0.0.1', port });
    };

    onEnd = () => reject(new Error('READY EOF'));
    onError = (error) => reject(new Error('READY stream failed', { cause: error }));
    onAbort = () => reject(new Error('startup cancelled', { cause: signal?.reason }));
    stream.on('data', onData);
    stream.once('end', onEnd);
    stream.once('error', onError);
    signal?.addEventListener('abort', onAbort, { once: true });
    if (signal?.aborted) {
      onAbort();
    }

    closed.then(() => reject(new Error('child closed before READY')), reject);
  });

  try {
    return await within(record, timeoutMs, () => stream.destroy());
  } finally {
    stream.off('data', onData!);
    stream.off('end', onEnd!);
    stream.off('error', onError!);
    signal?.removeEventListener('abort', onAbort!);
  }
}

/** Cancels owned work on timeout and always observes its eventual settlement. */
export async function within<T>(
  work: Promise<T>,
  timeoutMs: number,
  cancel: () => void,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          try {
            cancel();
            reject(new Error(`operation exceeded ${timeoutMs}ms`));
          } catch (cause) {
            reject(new Error(`cancellation failed after ${timeoutMs}ms`, { cause }));
          }
        }, timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

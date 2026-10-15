import { createClient, createClientPool } from 'redis';
import { setTimeout as delay } from 'node:timers/promises';
import { Server, within } from '@/harness/server';
import type { ServerOptions } from '@/harness/server';

export const protocols = [2, 3] as const;

interface ClientOptions {
  protocol?: 2 | 3;
  database?: number;
  clientInfoTag?: string;
}

export type Client = ReturnType<typeof newClient>;
export type Pool = ReturnType<typeof newPool>;

interface OwnedClient {
  client: Client | Pool;
  errors: Error[];
  state: { closing: boolean; closed: boolean };
  onError: (error: Error) => void;
  onEnd: () => void;
  onReconnect: () => void;
}

export interface Fixture {
  server: Server;
  signal: AbortSignal;
  connect: (options?: ClientOptions) => Promise<Client>;
  connectPool: (options?: ClientOptions) => Promise<Pool>;
  close: (client: Client | Pool) => Promise<void>;
}

export async function withFixture(
  name: string,
  protocol: 2 | 3 | undefined,
  body: (fixture: Fixture) => Promise<void>,
  options: ServerOptions & { scenarioTimeoutMs?: number } = {},
): Promise<void> {
  const label = `node-redis-6.2.1-RESP${protocol ?? 'default'}-${name}`;
  const server = new Server({ ...options, failureLabel: label });
  const clients: OwnedClient[] = [];
  const controller = new AbortController();
  const errors: unknown[] = [];

  let work: Promise<void> | undefined;
  const onTerminate = () => {
    const cause = new Error('native suite received SIGTERM');
    errors.push(cause);
    controller.abort(cause);

    for (const owned of clients) {
      owned.state.closing = true;
      destroy(owned.client);
    }
  };

  process.once('SIGTERM', onTerminate);

  try {
    await server.start(controller.signal);

    work = body({
      server,
      signal: controller.signal,
      connect: async (clientOptions = {}) => {
        controller.signal.throwIfAborted();

        const client = newClient(server, { protocol, ...clientOptions });
        const owned = ownClient(client);
        clients.push(owned);
        await command(client, client.connect());
        controller.signal.throwIfAborted();

        return client;
      },
      connectPool: async (clientOptions = {}) => {
        controller.signal.throwIfAborted();

        const pool = newPool(server, { protocol, ...clientOptions });
        clients.push(ownClient(pool));
        await command(pool, pool.connect());
        controller.signal.throwIfAborted();

        return pool;
      },
      close: async (client) => {
        const owned = clients.find((entry) => entry.client === client);

        if (!owned) {
          throw new Error('client does not belong to this fixture');
        }

        await closeClient(owned);
      },
    });

    await within(work, options.scenarioTimeoutMs ?? 45000, () => {
      controller.abort(new Error('scenario deadline'));

      for (const owned of clients) {
        owned.state.closing = true;
        destroy(owned.client);
      }
    });
  } catch (cause) {
    errors.push(cause);
  } finally {
    controller.abort();

    if (work) {
      // Cancellation must settle the body before the process and directory go away.
      await within(
        work.catch(() => {}),
        3000,
        () => {},
      ).catch((cause: unknown) => errors.push(cause));
    }

    for (const owned of clients.reverse()) {
      try {
        await closeClient(owned);
      } catch (cause) {
        errors.push(cause);
      }

      errors.push(...owned.errors);
    }

    try {
      await server.stop();
    } catch (cause) {
      errors.push(cause);
    }

    if (errors.length) {
      try {
        server.retainFailure(label, new AggregateError(errors, `${name}: case failed`));
      } catch (cause) {
        errors.push(cause);
      }
    }

    try {
      await server.cleanup();
    } catch (cause) {
      errors.push(cause);
    }

    process.off('SIGTERM', onTerminate);
  }

  if (errors.length === 1) {
    throw errors[0];
  }

  if (errors.length) {
    throw new AggregateError(errors, `${name}: scenario and cleanup failures`);
  }
}

export async function command<T>(
  client: Pick<Client, 'isOpen' | 'destroy'>,
  work: Promise<T>,
): Promise<T> {
  return within(work, 3000, () => destroy(client));
}

/** Polls observable state with cancellable delays and a separate deadline. */
export async function poll<T>(
  read: () => Promise<T>,
  accepts: (value: T) => boolean,
  signal: AbortSignal,
  timeoutMs = 5000,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;

  while (true) {
    signal.throwIfAborted();
    const value = await read();

    if (accepts(value)) {
      return value;
    }

    if (Date.now() >= deadline) {
      throw new Error(`poll exceeded ${timeoutMs}ms; last value: ${String(value)}`);
    }

    await delay(20, undefined, { signal });
  }
}

/** Holds native pool leases until the body finishes, including after a failed assertion. */
export async function withPoolConnections(
  pool: Pool,
  signal: AbortSignal,
  body: (clients: Client[]) => Promise<void>,
  count = 3,
): Promise<void> {
  const clients: Client[] = [];
  const errors: unknown[] = [];
  let ready!: () => void;
  let release!: () => void;
  const acquired = new Promise<void>((resolve) => {
    ready = resolve;
  });

  const released = new Promise<void>((resolve) => {
    release = resolve;
  });

  const tasks = Array.from({ length: count }, () =>
    pool.execute(async (client) => {
      clients.push(client);

      if (clients.length === count) {
        ready();
      }

      await released;
    }),
  );

  const settled = Promise.allSettled(tasks);

  try {
    await within(acquired, 3000, release);
    signal.throwIfAborted();
    await body(clients);
  } catch (cause) {
    errors.push(cause);
  } finally {
    release();

    try {
      const results = await within(settled, 3000, () => destroy(pool));

      for (const result of results) {
        if (result.status === 'rejected') {
          errors.push(result.reason);
        }
      }
    } catch (cause) {
      errors.push(cause);
    }
  }

  if (errors.length === 1) {
    throw errors[0];
  }

  if (errors.length) {
    throw new AggregateError(errors, 'pool body and lease cleanup failed');
  }
}

function newClient(server: Server, options: ClientOptions) {
  return createClient(nativeOptions(server, options));
}

function newPool(server: Server, options: ClientOptions) {
  return createClientPool(nativeOptions(server, options), {
    minimum: 1,
    maximum: 3,
    acquireTimeout: 3000,
    cleanupDelay: 60000,
  });
}

function nativeOptions(server: Server, options: ClientOptions) {
  if (!server.address) {
    throw new Error('server has no current address');
  }

  return {
    ...(options.protocol === undefined ? {} : { RESP: options.protocol }),
    database: options.database ?? 0,
    clientInfoTag: options.clientInfoTag,
    socket: {
      ...server.address,
      connectTimeout: 3000,
      socketTimeout: 3000,
      reconnectStrategy: false as const,
    },
    commandOptions: { timeout: 3000 },
    disableOfflineQueue: true,
  };
}

function ownClient(client: Client | Pool): OwnedClient {
  const errors: Error[] = [];
  const state = { closing: false, closed: false };
  const owned: OwnedClient = {
    client,
    errors,
    state,
    onError: (error) => errors.push(error),
    onEnd: () => {
      if (!state.closing) {
        errors.push(new Error('unexpected client end'));
      }
    },
    onReconnect: () => errors.push(new Error('unexpected reconnect')),
  };

  client.on('error', owned.onError);
  client.on('end', owned.onEnd);
  client.on('reconnecting', owned.onReconnect);

  return owned;
}

async function closeClient(owned: OwnedClient): Promise<void> {
  const { state } = owned;

  if (state.closed) {
    return;
  }

  state.closing = true;

  try {
    if (owned.client.isOpen) {
      await within(owned.client.close(), 3000, () => destroy(owned.client));
    }
  } finally {
    destroy(owned.client);
    owned.client.off('error', owned.onError);
    owned.client.off('end', owned.onEnd);
    owned.client.off('reconnecting', owned.onReconnect);
    state.closed = true;
  }
}

function destroy(
  client: Pick<Client, 'isOpen' | 'destroy'> & { cleanupTimeout?: NodeJS.Timeout },
): void {
  clearTimeout(client.cleanupTimeout);

  if (client.isOpen) {
    client.destroy();
  }
}

export const reportFields = [
  'id',
  'addr',
  'laddr',
  'fd',
  'age',
  'idle',
  'db',
  'cmd',
  'resp',
  'lib-name',
  'lib-ver',
  'tot-net-in',
  'tot-net-out',
  'tot-cmds',
  'name',
  'sub',
  'psub',
  'ssub',
  'watch',
  'multi',
  'multi-mem',
  'redir',
] as const;

type Field = (typeof reportFields)[number];

export interface Report {
  fields: Record<Field, string>;
  id: bigint;
  counters: Record<'age' | 'idle' | 'tot-net-in' | 'tot-net-out' | 'tot-cmds', bigint>;
}

/** Validates the complete ordered contract before building a field lookup. */
export function parseReport(reply: unknown): Report[] {
  if (typeof reply !== 'string' || !reply.endsWith('\n')) {
    throw new Error('CLIENT report must be native text ending with LF');
  }

  return reply
    .slice(0, -1)
    .split('\n')
    .map((line) => {
      const tokens = line.split(' ');

      if (tokens.length !== reportFields.length) {
        throw new Error(`CLIENT report expected 22 fields, got ${tokens.length}`);
      }

      const pairs = tokens.map((token, index) => {
        const separator = token.indexOf('=');
        const field = token.slice(0, separator);

        if (separator < 1 || field !== reportFields[index]) {
          throw new Error(
            `CLIENT report field ${index}: expected ${reportFields[index]}, got ${field}`,
          );
        }

        return [field, token.slice(separator + 1)];
      });

      const fields = Object.fromEntries(pairs) as Record<Field, string>;
      const counters = {
        age: decimal(fields.age),
        idle: decimal(fields.idle),
        'tot-net-in': decimal(fields['tot-net-in']),
        'tot-net-out': decimal(fields['tot-net-out']),
        'tot-cmds': decimal(fields['tot-cmds']),
      };

      return { fields, id: decimal(fields.id), counters };
    });
}

function decimal(value: string): bigint {
  if (!/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`CLIENT report expected unsigned decimal, got ${value}`);
  }

  return BigInt(value);
}

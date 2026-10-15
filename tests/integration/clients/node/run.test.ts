import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { withProfileWorkspace } from './run.ts';
import type { NodeProfile } from './run.ts';

test('profile overlay preserves TypeScript layout and cleans up after success and failure', async () => {
  for (const fail of [false, true]) {
    const { root, row } = workspaceFixture();
    let workspace = '';
    const failure = new Error('native verification failed');

    try {
      const work = withProfileWorkspace(root, row, new AbortController().signal, async (active) => {
        workspace = path.resolve(active.dir, '../../..');
        assert.equal(
          fs.readFileSync(path.join(active.dir, 'package.json'), 'utf8'),
          'selected manifest',
        );
        assert.equal(
          fs.readFileSync(path.join(active.dir, 'package-lock.json'), 'utf8'),
          'selected lock',
        );
        assert.equal(fs.readFileSync(path.join(active.dir, '.node-version'), 'utf8'), '22.14.0');
        assert.equal(
          fs.readFileSync(path.join(active.dir, 'tests', 'case.test.ts'), 'utf8'),
          'scenario source',
        );
        assert.equal(
          fs.readFileSync(path.join(active.dir, '../../harness/server.ts'), 'utf8'),
          'shared fixture',
        );
        assert.equal(
          fs.readFileSync(path.join(active.dir, '../../tsconfig.json'), 'utf8'),
          'root tsconfig',
        );

        for (const name of ['profiles', 'node_modules', 'coverage', 'dist']) {
          assert.equal(fs.existsSync(path.join(active.dir, name)), false);
        }

        if (fail) {
          throw failure;
        }
      });

      if (fail) {
        await assert.rejects(work, (cause) => cause === failure);
      } else {
        await work;
      }

      assert.equal(fs.existsSync(workspace), false);
      assert.equal(
        fs.readFileSync(path.join(root, row.suite.suiteDir, 'package.json'), 'utf8'),
        'baseline manifest',
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});

test('cancelled and linked sources cannot leave a dependency workspace alive', async () => {
  const { root, row } = workspaceFixture();
  const controller = new AbortController();
  controller.abort(new Error('caller cancelled'));
  let called = false;

  try {
    await assert.rejects(
      withProfileWorkspace(root, row, controller.signal, async () => {
        called = true;
      }),
      /caller cancelled/,
    );
    assert.equal(called, false);

    fs.symlinkSync(
      path.join(root, 'node/harness/server.ts'),
      path.join(root, row.suite.suiteDir, 'linked.ts'),
    );
    const before = new Set(
      fs.readdirSync(os.tmpdir()).filter((name) => name.startsWith(`kgcache-${row.id}-`)),
    );

    await assert.rejects(
      withProfileWorkspace(root, row, new AbortController().signal, async () => {
        called = true;
      }),
      /symbolic link/,
    );

    const after = new Set(
      fs.readdirSync(os.tmpdir()).filter((name) => name.startsWith(`kgcache-${row.id}-`)),
    );

    assert.deepEqual(after, before);
    assert.equal(called, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function workspaceFixture(): { root: string; row: NodeProfile } {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kgcache-node-source with spaces-'));
  const row: NodeProfile = {
    id: 'node-fixture-1.0.1',
    suiteId: 'node-fixture-v1',
    clientVersion: '1.0.1',
    runtimeVersion: '22.14.0',
    packageManagerVersion: '10.9.2',
    dependencyDir: 'node/fixture/v1/profiles/node-fixture-1.0.1',
    protocols: [2, 3],
    expectedDefaultProtocol: 3,
    ci: 'advisory',
    suite: {
      id: 'node-fixture-v1',
      language: 'node',
      library: 'fixture',
      apiGeneration: 'v1',
      package: 'fixture',
      suiteDir: 'node/fixture/v1',
      status: 'ready',
    },
    dir: '',
  };

  row.dir = path.join(root, row.dependencyDir);

  for (const [relative, contents] of Object.entries({
    'node/package.json': 'root manifest',
    'node/tsconfig.json': 'root tsconfig',
    'node/harness/server.ts': 'shared fixture',
    'node/fixture/v1/tests/case.test.ts': 'scenario source',
    'node/fixture/v1/package.json': 'baseline manifest',
    'node/fixture/v1/package-lock.json': 'baseline lock',
    'node/fixture/v1/.node-version': '22.14.0',
    'node/fixture/v1/profiles/node-fixture-1.0.1/package.json': 'selected manifest',
    'node/fixture/v1/profiles/node-fixture-1.0.1/package-lock.json': 'selected lock',
    'node/fixture/v1/profiles/node-fixture-1.0.1/.node-version': '22.14.0',
    'node/fixture/v1/node_modules/ignored': 'generated',
    'node/fixture/v1/coverage/ignored': 'generated',
    'node/fixture/v1/dist/ignored': 'generated',
  })) {
    const file = path.join(root, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, contents);
  }

  return { root, row };
}

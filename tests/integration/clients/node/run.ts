import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

interface Suite {
  id: string;
  language: 'go' | 'node';
  library: string;
  apiGeneration: string;
  package: string;
  suiteDir: string;
  status: 'planned' | 'ready';
}

interface Profile {
  id: string;
  suiteId: string;
  clientVersion: string;
  runtimeVersion: string;
  packageManagerVersion?: string;
  dependencyDir: string;
  protocols: (2 | 3)[];
  expectedDefaultProtocol: 2 | 3;
  ci: 'required' | 'advisory';
}

interface Registry {
  profiles: Profile[];
  suites: Map<string, Suite>;
}

interface Options {
  action: 'list' | 'validate' | 'deps' | 'test';
  profile: string;
  library: string;
  testArgs: string[];
}

export interface NodeProfile extends Profile {
  packageManagerVersion: string;
  suite: Suite;
  dir: string;
}

const nodeRoot = fs.realpathSync(import.meta.dirname);
const root = fs.realpathSync(path.join(nodeRoot, '..'));
const stableVersion = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const identifier = /^[a-z][a-z0-9.-]*$/;
const nativeTimeoutMs = 5 * 60 * 1000;
const toolingPins = {
  '@eslint/js': '10.0.1',
  '@stylistic/eslint-plugin': '5.10.0',
  '@types/node': '22.14.0',
  eslint: '10.12.0',
  globals: '17.13.0',
  prettier: '3.9.10',
  typescript: '5.9.3',
  'typescript-eslint': '8.71.2',
};

const suiteToolingPins = {
  '@types/jest': '30.0.0',
  '@types/node': '22.14.0',
  jest: '30.2.0',
  'ts-jest': '29.4.14',
  typescript: '5.9.3',
};

async function main(): Promise<void> {
  const controller = new AbortController();
  const onInterrupt = () => controller.abort(new Error('launcher interrupted'));
  process.once('SIGINT', onInterrupt);
  process.once('SIGTERM', onInterrupt);

  try {
    await run(process.argv.slice(2), controller.signal);
  } catch (error) {
    console.error(`Node client profiles: ${errorMessage(error)}`);
    process.exitCode = error instanceof CommandError ? error.exitCode : 1;
  } finally {
    process.off('SIGINT', onInterrupt);
    process.off('SIGTERM', onInterrupt);
  }
}

async function run(args: string[], signal: AbortSignal): Promise<void> {
  const options = parseArgs(args);
  const rows = selectProfiles(loadRegistry(), options);
  validateProject(nodeRoot, projectRuntime(nodeRoot), toolingPins);

  for (const row of rows) {
    const runtime = fs.readFileSync(path.join(row.dir, '.node-version'), 'utf8').trim();

    if (runtime !== row.runtimeVersion) {
      throw new Error(`${row.id}: .node-version does not match runtimeVersion`);
    }

    validateProject(row.dir, row, {
      [row.suite.package]: row.clientVersion,
      ...suiteToolingPins,
    });
  }

  if (options.action === 'list') {
    for (const row of rows) {
      console.log(
        `${row.id}  ${row.suite.id}  ${row.suite.status}  Node ${row.runtimeVersion}  npm ${row.packageManagerVersion}  ${row.ci}`,
      );
    }

    return;
  }

  await validateRuntime(rows, signal);

  if (options.action === 'validate') {
    validateInstalled(nodeRoot, toolingPins);

    for (const row of rows) {
      console.log(`${row.id}: locked profile metadata validated (${row.suite.status} suite)`);
    }

    return;
  }

  if (options.action === 'deps') {
    await command('npm', ['ci', '--no-audit', '--no-fund'], nodeRoot, signal);
    validateInstalled(nodeRoot, toolingPins);

    // Prepare source suites for quality checks and direct native execution.
    const suites = new Map(rows.map((row) => [row.suite.suiteDir, row.suite]));

    for (const suite of suites.values()) {
      const dir = registryDir(suite.suiteDir);
      const version = dependencyPins(readJson(path.join(dir, 'package.json')))[suite.package];

      if (!matches(stableVersion, version)) {
        throw new Error(`${suite.id}: source suite must pin a stable client version`);
      }

      validateProject(dir, projectRuntime(dir), { [suite.package]: version, ...suiteToolingPins });
      await command('npm', ['ci', '--no-audit', '--no-fund'], dir, signal);
      validateInstalled(dir, { [suite.package]: version, ...suiteToolingPins });
    }
  } else {
    resolveTestPaths();
    await command(
      process.execPath,
      ['--experimental-strip-types', '--test', 'run.test.ts'],
      nodeRoot,
      signal,
    );
  }

  for (const row of rows) {
    if (options.action === 'test' && row.suite.status !== 'ready') {
      throw new Error(`${row.id}: client suite is still planned`);
    }

    await withProfileWorkspace(root, row, signal, async (active) => {
      await command('npm', ['ci', '--no-audit', '--no-fund'], active.dir, signal);
      validateInstalled(active.dir, {
        [active.suite.package]: active.clientVersion,
        ...suiteToolingPins,
      });

      if (options.action === 'test') {
        await runTests(
          active,
          [...splitArguments(process.env.NODE_TEST_ARGS ?? ''), ...options.testArgs],
          signal,
        );
      } else {
        console.log(`${active.id}: locked dependencies validated (${active.suite.status} suite)`);
      }
    });
  }
}

export async function withProfileWorkspace(
  sourceRoot: string,
  row: NodeProfile,
  signal: AbortSignal,
  body: (active: NodeProfile) => Promise<void>,
): Promise<void> {
  signal.throwIfAborted();

  const workspace = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `kgcache-${row.id}-`)));
  const errors: unknown[] = [];
  console.log(`${row.id}: isolated workspace: ${workspace}`);

  try {
    const active = { ...row, dir: path.join(workspace, row.suite.suiteDir) };

    for (const relative of [row.suite.suiteDir, 'node/harness']) {
      fs.cpSync(path.join(sourceRoot, relative), path.join(workspace, relative), {
        recursive: true,
        filter: (source) => {
          signal.throwIfAborted();

          if (
            [
              'profiles',
              'node_modules',
              '.git',
              '.workspaces',
              'coverage',
              'dist',
              'build',
              'test-artifacts',
            ].includes(path.basename(source))
          ) {
            return false;
          }

          if (fs.lstatSync(source).isSymbolicLink()) {
            throw new Error(`workspace source must not be a symbolic link: ${source}`);
          }

          return true;
        },
      });
    }

    for (const name of ['package.json', 'tsconfig.json']) {
      copyRegularFile(path.join(sourceRoot, 'node', name), path.join(workspace, 'node', name));
    }

    for (const name of ['package.json', 'package-lock.json', '.node-version']) {
      copyRegularFile(path.join(row.dir, name), path.join(active.dir, name));
    }

    signal.throwIfAborted();
    await body(active);
  } catch (cause) {
    errors.push(cause);
  } finally {
    try {
      fs.rmSync(workspace, { recursive: true, force: true });
    } catch (cause) {
      errors.push(cause);
    }
  }

  if (errors.length === 1) {
    throw errors[0];
  }

  if (errors.length) {
    throw new AggregateError(errors, 'profile execution and workspace cleanup failed');
  }
}

function copyRegularFile(source: string, destination: string): void {
  if (!fs.lstatSync(source).isFile()) {
    throw new Error(`workspace source must be a regular file: ${source}`);
  }

  fs.copyFileSync(source, destination);
}

function projectRuntime(
  dir: string,
): Pick<NodeProfile, 'runtimeVersion' | 'packageManagerVersion'> {
  const manifest = readJson(path.join(dir, 'package.json'));
  const engines = object(manifest.engines, `${dir}: engines`);

  if (!matches(stableVersion, engines.node) || !matches(stableVersion, engines.npm)) {
    throw new Error(`${dir}: project runtimes must be exact stable pins`);
  }

  return { runtimeVersion: engines.node, packageManagerVersion: engines.npm };
}

function resolveTestPaths(): void {
  const binary = process.env.KGCACHE_BIN;

  if (!binary || !path.isAbsolute(binary) || !fs.statSync(binary).isFile()) {
    throw new Error('KGCACHE_BIN must be an absolute regular executable path');
  }

  fs.accessSync(binary, fs.constants.X_OK);

  if (process.env.KGCACHE_TEST_ARTIFACT_DIR) {
    process.env.KGCACHE_TEST_ARTIFACT_DIR = path.resolve(process.env.KGCACHE_TEST_ARTIFACT_DIR);
  }
}

async function runTests(row: NodeProfile, testArgs: string[], signal: AbortSignal): Promise<void> {
  const binary = process.env.KGCACHE_BIN;

  if (!binary || !path.isAbsolute(binary)) {
    throw new Error('KGCACHE_BIN must be an absolute executable path');
  }

  fs.accessSync(binary, fs.constants.X_OK);
  const artifactRoot = process.env.KGCACHE_TEST_ARTIFACT_DIR;
  const resultDir = artifactRoot
    ? path.join(path.resolve(artifactRoot), row.id)
    : fs.mkdtempSync(path.join(os.tmpdir(), `${row.id}-results-`));

  fs.mkdirSync(resultDir, { recursive: true });
  const resultFile = path.join(resultDir, 'jest-results.json');
  fs.rmSync(resultFile, { force: true });
  console.log(`${row.id}: native client tests; results: ${resultFile}`);

  try {
    await command(
      'npm',
      ['test', '--', ...testArgs, '--json', `--outputFile=${resultFile}`],
      row.dir,
      signal,
      false,
      { KGCACHE_CLIENT_PROFILE: row.id },
    );
    const results = readJson(resultFile);

    if (!Array.isArray(results.testResults)) {
      throw new Error(`${row.id}: Jest did not report test results`);
    }

    let executed = 0;
    const clientRoot = path.join(row.dir, 'tests') + path.sep;

    for (const raw of results.testResults as unknown[]) {
      const suite = object(raw, 'Jest suite');

      if (typeof suite.name !== 'string' || !suite.name.startsWith(clientRoot)) {
        continue;
      }

      if (!Array.isArray(suite.assertionResults)) {
        throw new Error(`${row.id}: missing client assertion results`);
      }

      for (const assertion of suite.assertionResults as unknown[]) {
        const { status } = object(assertion, 'Jest assertion');

        if (status === 'passed' || status === 'failed') {
          executed += 1;
        }
      }
    }

    if (!executed) {
      throw new Error(`${row.id}: zero executed client cases (fixture checks do not count)`);
    }

    console.log(`${row.id}: ${executed} client cases executed`);
  } catch (cause) {
    try {
      fs.writeFileSync(
        path.join(resultDir, 'runner-failure.json'),
        JSON.stringify(
          {
            profile: row.id,
            suite: row.suite.id,
            clientVersion: row.clientVersion,
            runtimeVersion: row.runtimeVersion,
            packageManagerVersion: row.packageManagerVersion,
            protocols: row.protocols,
            exitCode: cause instanceof CommandError ? cause.exitCode : 1,
            reason: errorMessage(cause).slice(0, 16384),
          },
          null,
          2,
        ),
      );
    } catch (reportCause) {
      throw new CommandError(
        `${errorMessage(cause)}; failure report: ${errorMessage(reportCause)}`,
        cause instanceof CommandError ? cause.exitCode : 1,
        new AggregateError([cause, reportCause], 'native execution and reporting failed', {
          cause: reportCause,
        }),
      );
    }

    throw cause;
  }
}

function splitArguments(input: string): string[] {
  const args: string[] = [];
  let token = '';
  let quote = '';
  let escaped = false;
  let started = false;

  for (const character of input) {
    if (escaped) {
      token += character;
      escaped = false;
    } else if (character === '\\' && quote !== "'") {
      escaped = true;
      started = true;
    } else if (quote) {
      if (character === quote) {
        quote = '';
      } else {
        token += character;
      }
    } else if (character === '"' || character === "'") {
      quote = character;
      started = true;
    } else if (/\s/.test(character)) {
      if (started) {
        args.push(token);
        token = '';
        started = false;
      }
    } else {
      token += character;
      started = true;
    }
  }

  if (escaped || quote) {
    throw new Error('NODE_TEST_ARGS contains an unfinished escape or quote');
  }

  if (started) {
    args.push(token);
  }

  return args;
}

function parseArgs(args: string[]): Options {
  const [action, ...rest] = args;

  if (action !== 'list' && action !== 'validate' && action !== 'deps' && action !== 'test') {
    throw new Error(
      'usage: run.ts list|validate|deps|test [--profile ID | --library NAME] [-- test arguments]',
    );
  }

  const options: Options = { action, profile: '', library: '', testArgs: [] };

  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index];

    if (arg === '--') {
      options.testArgs = rest.slice(index + 1);
      break;
    }

    const value = rest[index + 1];

    if ((arg !== '--profile' && arg !== '--library') || value === undefined) {
      throw new Error(`unknown argument or missing value: ${arg}`);
    }

    const key = arg === '--profile' ? 'profile' : 'library';

    if (options[key]) {
      throw new Error(`duplicate selector: ${arg}`);
    }

    options[key] = value;
    index += 1;
  }

  if (options.profile && options.library) {
    throw new Error('--profile and --library cannot be combined');
  }

  if (action !== 'test' && options.testArgs.length) {
    throw new Error('test arguments are only allowed with test');
  }

  return options;
}

function loadRegistry(): Registry {
  const matrix = readJson(path.join(root, 'matrix.json'));
  checkFields(matrix, ['schemaVersion', 'suites', 'profiles'], 'registry');

  if (
    matrix.schemaVersion !== 1
    || !Array.isArray(matrix.suites)
    || !matrix.suites.length
    || !Array.isArray(matrix.profiles)
    || !matrix.profiles.length
  ) {
    throw new Error('registry requires schemaVersion 1, suites, and profiles');
  }

  const suites = new Map<string, Suite>();

  for (const suite of matrix.suites as unknown[]) {
    checkFields(
      suite,
      ['id', 'language', 'library', 'apiGeneration', 'package', 'suiteDir', 'status'],
      'suite',
    );

    if (!matches(identifier, suite.id) || suites.has(suite.id)) {
      throw new Error(`invalid or duplicate suite ID ${suite.id}`);
    }

    if (
      (suite.language !== 'go' && suite.language !== 'node')
      || !matches(identifier, suite.library)
      || !matches(identifier, suite.apiGeneration)
      || typeof suite.package !== 'string'
      || !suite.package
    ) {
      throw new Error(`${suite.id}: invalid language, library, API, or package`);
    }

    if (suite.status !== 'planned' && suite.status !== 'ready') {
      throw new Error(`${suite.id}: status must be planned or ready`);
    }

    if (suite.suiteDir !== `${suite.language}/${suite.library}/${suite.apiGeneration}`) {
      throw new Error(`${suite.id}: suiteDir must match language/library/API generation`);
    }

    registryDir(suite.suiteDir);
    suites.set(suite.id, {
      id: suite.id,
      language: suite.language,
      library: suite.library,
      apiGeneration: suite.apiGeneration,
      package: suite.package,
      suiteDir: suite.suiteDir,
      status: suite.status,
    });
  }

  const ids = new Set<string>();
  const profiles: Profile[] = [];

  for (const profile of matrix.profiles as unknown[]) {
    checkFields(
      profile,
      [
        'id',
        'suiteId',
        'clientVersion',
        'runtimeVersion',
        'packageManagerVersion',
        'dependencyDir',
        'protocols',
        'expectedDefaultProtocol',
        'ci',
      ],
      'profile',
    );
    const suite = typeof profile.suiteId === 'string' ? suites.get(profile.suiteId) : undefined;

    if (
      !matches(identifier, profile.id)
      || ids.has(profile.id)
      || typeof profile.suiteId !== 'string'
      || !suite
    ) {
      throw new Error(`${profile.id}: invalid/duplicate ID or unknown suite`);
    }

    ids.add(profile.id);

    if (typeof profile.clientVersion !== 'string') {
      throw new Error(`${profile.id}: versions must be exact stable pins`);
    }

    const clientVersion =
      suite.language === 'go' ? profile.clientVersion.replace(/^v/, '') : profile.clientVersion;

    const npmVersion = profile.packageManagerVersion;

    if (
      !matches(stableVersion, clientVersion)
      || (suite.language === 'go' && !profile.clientVersion.startsWith('v'))
      || !matches(stableVersion, profile.runtimeVersion)
      || (suite.language === 'node' && !matches(stableVersion, npmVersion))
      || (npmVersion !== undefined && !matches(stableVersion, npmVersion))
    ) {
      throw new Error(`${profile.id}: versions must be exact stable pins`);
    }

    if (profile.ci !== 'required' && profile.ci !== 'advisory') {
      throw new Error(`${profile.id}: ci must be required or advisory`);
    }

    if (
      !Array.isArray(profile.protocols)
      || !profile.protocols.every(isProtocol)
      || new Set(profile.protocols).size !== profile.protocols.length
      || !isProtocol(profile.expectedDefaultProtocol)
      || !profile.protocols.includes(profile.expectedDefaultProtocol)
    ) {
      throw new Error(`${profile.id}: invalid protocols or expected default`);
    }

    if (
      typeof profile.dependencyDir !== 'string'
      || (profile.dependencyDir !== suite.suiteDir
        && !profile.dependencyDir.startsWith(`${suite.suiteDir}/profiles/`))
    ) {
      throw new Error(`${profile.id}: dependencyDir must belong to its suite`);
    }

    registryDir(profile.dependencyDir);
    profiles.push({
      id: profile.id,
      suiteId: profile.suiteId,
      clientVersion: profile.clientVersion,
      runtimeVersion: profile.runtimeVersion,
      ...(npmVersion === undefined ? {} : { packageManagerVersion: npmVersion }),
      dependencyDir: profile.dependencyDir,
      protocols: profile.protocols,
      expectedDefaultProtocol: profile.expectedDefaultProtocol,
      ci: profile.ci,
    });
  }

  return { profiles, suites };
}

function selectProfiles({ profiles, suites }: Registry, options: Options): NodeProfile[] {
  const selected: NodeProfile[] = [];

  for (const profile of profiles) {
    const suite = suites.get(profile.suiteId);

    if (!suite) {
      throw new Error(`${profile.id}: unknown suite ${profile.suiteId}`);
    }

    if (options.profile) {
      if (profile.id !== options.profile) {
        continue;
      }

      if (suite.language !== 'node') {
        throw new Error(`${profile.id} belongs to ${suite.language}, not Node`);
      }
    } else if (
      suite.language !== 'node'
      || profile.ci !== 'required'
      || (options.library && suite.library !== options.library)
    ) {
      continue;
    }

    if (!profile.packageManagerVersion) {
      throw new Error(`${profile.id}: missing npm pin`);
    }

    selected.push({
      ...profile,
      packageManagerVersion: profile.packageManagerVersion,
      suite,
      dir: registryDir(profile.dependencyDir),
    });
  }

  if (!selected.length) {
    throw new Error(`no Node profiles match profile=${options.profile} library=${options.library}`);
  }

  return selected;
}

function validateProject(
  dir: string,
  row: Pick<NodeProfile, 'runtimeVersion' | 'packageManagerVersion'>,
  pins: Record<string, string>,
): void {
  const manifest = readJson(path.join(dir, 'package.json'));
  const lock = readJson(path.join(dir, 'package-lock.json'));
  const engines = object(manifest.engines, `${dir}: engines`);

  if (
    manifest.private !== true
    || manifest.type !== 'module'
    || manifest.packageManager !== `npm@${row.packageManagerVersion}`
    || engines.node !== row.runtimeVersion
    || engines.npm !== row.packageManagerVersion
    || lock.lockfileVersion !== 3
    || lock.name !== manifest.name
  ) {
    throw new Error(`${dir}: manifest/lock must match the pinned Node/npm profile`);
  }

  const packages = object(lock.packages, `${dir}: lock packages`);
  const declared = dependencyPins(manifest);
  const locked = dependencyPins(object(packages[''], `${dir}: lock root`));

  for (const [name, version] of Object.entries(pins)) {
    const installedLock = object(
      packages[`node_modules/${name}`],
      `${dir}: lock entry for ${name}`,
    );

    if (
      declared[name] !== version
      || locked[name] !== version
      || installedLock.version !== version
      || installedLock.link
    ) {
      throw new Error(`${dir}: manifest and lock must pin ${name} ${version}`);
    }
  }
}

async function validateRuntime(rows: NodeProfile[], signal: AbortSignal): Promise<void> {
  const first = rows[0];

  if (!first) {
    throw new Error('no Node profiles selected');
  }

  if (
    rows.some(
      (row) =>
        row.runtimeVersion !== first.runtimeVersion
        || row.packageManagerVersion !== first.packageManagerVersion,
    )
  ) {
    throw new Error(
      'selected profiles require different Node/npm versions; invoke each --profile separately with its pinned runtime',
    );
  }

  if (process.versions.node !== first.runtimeVersion) {
    throw new Error(
      `selected profiles require Node ${first.runtimeVersion}; installed runtime is ${process.versions.node}`,
    );
  }

  const npmVersion = await command('npm', ['--version'], nodeRoot, signal, true);

  if (npmVersion !== first.packageManagerVersion) {
    throw new Error(
      `selected profiles require npm ${first.packageManagerVersion}; installed npm is ${npmVersion} (use the pinned Node distribution's bundled npm)`,
    );
  }
}

function validateInstalled(dir: string, pins: Record<string, string>): void {
  for (const [name, version] of Object.entries(pins)) {
    const installed = readJson(path.join(dir, 'node_modules', name, 'package.json'));

    if (installed.version !== version) {
      throw new Error(`${dir}: installed ${name} must be ${version}`);
    }
  }
}

function dependencyPins(manifest: Record<string, unknown>): Record<string, unknown> {
  return {
    ...object(manifest.devDependencies ?? {}, 'devDependencies'),
    ...object(manifest.dependencies ?? {}, 'dependencies'),
  };
}

function readJson(filename: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(fs.readFileSync(filename, 'utf8'));

    return object(value, filename);
  } catch (cause) {
    throw new Error(`read ${filename}: ${errorMessage(cause)}`, { cause });
  }
}

function checkFields(
  value: unknown,
  fields: string[],
  label: string,
): asserts value is Record<string, unknown> {
  for (const key of Object.keys(object(value, label))) {
    if (!fields.includes(key)) {
      throw new Error(`${label}: unknown field ${key}`);
    }
  }
}

function matches(pattern: RegExp, value: unknown): value is string {
  return typeof value === 'string' && pattern.test(value);
}

function isProtocol(value: unknown): value is 2 | 3 {
  return value === 2 || value === 3;
}

function registryDir(relative: unknown): string {
  if (
    typeof relative !== 'string'
    || !relative
    || path.isAbsolute(relative)
    || path.posix.normalize(relative) !== relative
    || relative.includes('\\')
  ) {
    throw new Error(`invalid registry directory ${JSON.stringify(relative)}`);
  }

  const dir = fs.realpathSync(path.join(root, relative));

  if (!dir.startsWith(root + path.sep) || !fs.statSync(dir).isDirectory()) {
    throw new Error(`directory ${relative} must stay inside the registry root`);
  }

  return dir;
}

async function command(
  executable: string,
  args: string[],
  dir: string,
  signal: AbortSignal,
  capture = false,
  extraEnv: NodeJS.ProcessEnv = {},
): Promise<string> {
  signal.throwIfAborted();

  const child = spawn(executable, args, {
    cwd: dir,
    stdio: capture ? ['inherit', 'pipe', 'inherit'] : 'inherit',
    shell: false,
    detached: true,
    env: {
      ...process.env,
      ...extraEnv,
      ...(process.env.KGCACHE_TEST_ARTIFACT_DIR
        ? { KGCACHE_TEST_ARTIFACT_DIR: path.resolve(process.env.KGCACHE_TEST_ARTIFACT_DIR) }
        : {}),
    },
  });

  let output = '';
  let failure: Error | undefined;
  let expired = false;
  let forceTimer: ReturnType<typeof setTimeout> | undefined;
  child.stdout?.on('data', (chunk: Buffer) => {
    output += chunk.toString().slice(0, 16384 - output.length);
  });
  child.on('error', (error) => {
    failure = error;
  });
  const closed = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    child.once('close', (code, signal) => resolve({ code, signal }));
  });

  const terminate = (signal: NodeJS.Signals) => {
    if (!child.pid) {
      return;
    }

    try {
      process.kill(-child.pid, signal);
    } catch (cause) {
      if (!isMissingProcess(cause)) {
        failure = new Error('terminate native process group', { cause });
      }
    }
  };

  const timer = setTimeout(() => {
    expired = true;
    terminate('SIGTERM');
    forceTimer = setTimeout(() => terminate('SIGKILL'), 3000);
  }, nativeTimeoutMs);

  const onAbort = () => {
    failure = new Error('native command cancelled', { cause: signal.reason });
    terminate('SIGTERM');
    clearTimeout(forceTimer);
    forceTimer = setTimeout(() => terminate('SIGKILL'), 3000);
  };

  signal.addEventListener('abort', onAbort, { once: true });

  if (signal.aborted) {
    onAbort();
  }

  try {
    const result = await closed;

    if (child.pid && processGroupExists(child.pid)) {
      failure ??= new Error('native command retained a process group after exit');
      terminate('SIGTERM');
      const deadline = Date.now() + 3500;

      while (processGroupExists(child.pid) && Date.now() < deadline) {
        await delay(20);
      }

      terminate('SIGKILL');
    }

    if (failure || expired || result.code !== 0) {
      throw new CommandError(
        `${executable} ${args.join(' ')}: ${failure?.message ?? (expired ? `exceeded ${nativeTimeoutMs}ms` : `exit ${result.code}, signal ${result.signal ?? 'none'}`)}`,
        result.code !== null && result.code > 0 ? result.code : 1,
        failure,
      );
    }

    return output.trim();
  } finally {
    clearTimeout(timer);
    clearTimeout(forceTimer);
    signal.removeEventListener('abort', onAbort);
    child.removeAllListeners();
    child.stdout?.removeAllListeners();
  }
}

function processGroupExists(pid: number): boolean {
  try {
    process.kill(-pid, 0);

    return true;
  } catch (cause) {
    if (isMissingProcess(cause)) {
      return false;
    }

    throw cause;
  }
}

function isMissingProcess(cause: unknown): boolean {
  return cause instanceof Error && 'code' in cause && cause.code === 'ESRCH';
}

function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }

  return value as Record<string, unknown>;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

class CommandError extends Error {
  exitCode: number;

  constructor(message: string, exitCode: number, cause?: Error) {
    super(message, { cause });
    this.exitCode = exitCode;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}

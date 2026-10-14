'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = fs.realpathSync(path.join(__dirname, '..'));
const stableVersion = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const identifier = /^[a-z][a-z0-9.-]*$/;
const toolingPins = {
  '@eslint/js': '10.0.1',
  eslint: '10.12.0',
  globals: '17.13.0',
  prettier: '3.9.10',
};

function readJson(filename) {
  try {
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch (cause) {
    throw new Error(`read ${filename}: ${cause.message}`, { cause });
  }
}

function checkFields(object, fields, label) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) {
    throw new Error(`${label} must be an object`);
  }
  for (const key of Object.keys(object)) {
    if (!fields.includes(key)) {
      throw new Error(`${label}: unknown field ${key}`);
    }
  }
}

function matches(pattern, value) {
  return typeof value === 'string' && pattern.test(value);
}

function registryDir(relative) {
  if (
    typeof relative !== 'string' ||
    !relative ||
    path.isAbsolute(relative) ||
    path.posix.normalize(relative) !== relative ||
    relative.includes('\\')
  ) {
    throw new Error(`invalid registry directory ${JSON.stringify(relative)}`);
  }
  const dir = fs.realpathSync(path.join(root, relative));
  if (!dir.startsWith(root + path.sep) || !fs.statSync(dir).isDirectory()) {
    throw new Error(`directory ${relative} must stay inside the registry root`);
  }
  return dir;
}

function loadRegistry() {
  const matrix = readJson(path.join(root, 'matrix.json'));
  checkFields(matrix, ['schemaVersion', 'suites', 'profiles'], 'registry');
  if (
    matrix.schemaVersion !== 1 ||
    !Array.isArray(matrix.suites) ||
    !matrix.suites.length ||
    !Array.isArray(matrix.profiles) ||
    !matrix.profiles.length
  ) {
    throw new Error('registry requires schemaVersion 1, suites, and profiles');
  }
  const suites = new Map();
  for (const suite of matrix.suites) {
    checkFields(
      suite,
      [
        'id',
        'language',
        'library',
        'apiGeneration',
        'package',
        'suiteDir',
        'status',
      ],
      'suite',
    );
    if (!matches(identifier, suite.id) || suites.has(suite.id)) {
      throw new Error(`invalid or duplicate suite ID ${suite.id}`);
    }
    if (
      !['go', 'node'].includes(suite.language) ||
      !matches(identifier, suite.library) ||
      !matches(identifier, suite.apiGeneration) ||
      typeof suite.package !== 'string' ||
      !suite.package
    ) {
      throw new Error(
        `${suite.id}: invalid language, library, API, or package`,
      );
    }
    if (!['planned', 'ready'].includes(suite.status)) {
      throw new Error(`${suite.id}: status must be planned or ready`);
    }
    if (
      suite.suiteDir !==
      `${suite.language}/${suite.library}/${suite.apiGeneration}`
    ) {
      throw new Error(
        `${suite.id}: suiteDir must match language/library/API generation`,
      );
    }
    registryDir(suite.suiteDir);
    suites.set(suite.id, suite);
  }
  const ids = new Set();
  for (const profile of matrix.profiles) {
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
    const suite = suites.get(profile.suiteId);
    if (!matches(identifier, profile.id) || ids.has(profile.id) || !suite) {
      throw new Error(`${profile.id}: invalid/duplicate ID or unknown suite`);
    }
    ids.add(profile.id);
    const clientVersion =
      suite.language === 'go' && typeof profile.clientVersion === 'string'
        ? profile.clientVersion.replace(/^v/, '')
        : profile.clientVersion;
    if (
      !matches(stableVersion, clientVersion) ||
      (suite.language === 'go' && !profile.clientVersion.startsWith('v')) ||
      !matches(stableVersion, profile.runtimeVersion) ||
      (suite.language === 'node' &&
        !matches(stableVersion, profile.packageManagerVersion))
    ) {
      throw new Error(`${profile.id}: versions must be exact stable pins`);
    }
    if (!['required', 'advisory'].includes(profile.ci)) {
      throw new Error(`${profile.id}: ci must be required or advisory`);
    }
    if (
      !Array.isArray(profile.protocols) ||
      profile.protocols.some((protocol) => ![2, 3].includes(protocol)) ||
      new Set(profile.protocols).size !== profile.protocols.length ||
      !profile.protocols.includes(profile.expectedDefaultProtocol)
    ) {
      throw new Error(`${profile.id}: invalid protocols or expected default`);
    }
    if (
      typeof profile.dependencyDir !== 'string' ||
      (profile.dependencyDir !== suite.suiteDir &&
        !profile.dependencyDir.startsWith(`${suite.suiteDir}/profiles/`))
    ) {
      throw new Error(`${profile.id}: dependencyDir must belong to its suite`);
    }
    registryDir(profile.dependencyDir);
  }
  return { matrix, suites };
}

function parseArgs(args) {
  const [action, ...rest] = args;
  if (!['list', 'validate', 'deps', 'test'].includes(action)) {
    throw new Error(
      'usage: run.cjs list|validate|deps|test [--profile ID | --library NAME] [-- test arguments]',
    );
  }
  const options = { action, profile: '', library: '', testArgs: [] };
  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index];
    if (arg === '--') {
      options.testArgs = rest.slice(index + 1);
      break;
    }
    if (
      !['--profile', '--library'].includes(arg) ||
      index + 1 === rest.length
    ) {
      throw new Error(`unknown argument or missing value: ${arg}`);
    }
    const key = arg.slice(2);
    if (options[key]) {
      throw new Error(`duplicate selector: ${arg}`);
    }
    options[key] = rest[++index];
  }
  if (options.profile && options.library) {
    throw new Error('--profile and --library cannot be combined');
  }
  if (action !== 'test' && options.testArgs.length) {
    throw new Error('test arguments are only allowed with test');
  }
  return options;
}

function selectProfiles({ matrix, suites }, options) {
  const selected = [];
  for (const profile of matrix.profiles) {
    const suite = suites.get(profile.suiteId);
    if (options.profile) {
      if (profile.id !== options.profile) continue;
      if (suite.language !== 'node') {
        throw new Error(`${profile.id} belongs to ${suite.language}, not Node`);
      }
    } else if (
      suite.language !== 'node' ||
      profile.ci !== 'required' ||
      (options.library && suite.library !== options.library)
    ) {
      continue;
    }
    if (profile.dependencyDir !== suite.suiteDir) {
      throw new Error(
        `${profile.id}: separate dependency workspaces require the step 04 runner`,
      );
    }
    selected.push({
      ...profile,
      suite,
      dir: registryDir(profile.dependencyDir),
    });
  }
  if (!selected.length) {
    throw new Error(
      `no Node profiles match profile=${options.profile} library=${options.library}`,
    );
  }
  return selected;
}

function validateProject(dir, row, pins) {
  const manifest = readJson(path.join(dir, 'package.json'));
  const lock = readJson(path.join(dir, 'package-lock.json'));
  if (
    manifest.private !== true ||
    manifest.type !== 'commonjs' ||
    manifest.packageManager !== `npm@${row.packageManagerVersion}` ||
    manifest.engines?.node !== row.runtimeVersion ||
    manifest.engines?.npm !== row.packageManagerVersion ||
    lock.lockfileVersion !== 3 ||
    lock.name !== manifest.name
  ) {
    throw new Error(
      `${dir}: manifest/lock must match the pinned Node/npm profile`,
    );
  }
  for (const [name, version] of Object.entries(pins)) {
    const declared =
      manifest.dependencies?.[name] ?? manifest.devDependencies?.[name];
    const locked =
      lock.packages?.['']?.dependencies?.[name] ??
      lock.packages?.['']?.devDependencies?.[name];
    const installedLock = lock.packages?.[`node_modules/${name}`];
    if (
      declared !== version ||
      locked !== version ||
      installedLock?.version !== version ||
      installedLock.link
    ) {
      throw new Error(`${dir}: manifest and lock must pin ${name} ${version}`);
    }
  }
}

function command(executable, args, dir, capture = false) {
  const result = spawnSync(executable, args, {
    cwd: dir,
    stdio: capture ? ['inherit', 'pipe', 'inherit'] : 'inherit',
    encoding: 'utf8',
    shell: false,
  });
  if (result.error || result.status !== 0) {
    const error = new Error(
      `${executable} ${args.join(' ')}: ${result.error?.message ?? `exit ${result.status}, signal ${result.signal ?? 'none'}`}`,
      { cause: result.error },
    );
    error.exitCode = result.status > 0 ? result.status : 1;
    throw error;
  }
  return result.stdout?.trim();
}

function validateRuntime(rows) {
  const first = rows[0];
  if (
    rows.some(
      (row) =>
        row.runtimeVersion !== first.runtimeVersion ||
        row.packageManagerVersion !== first.packageManagerVersion,
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
  const npmVersion = command('npm', ['--version'], __dirname, true);
  if (npmVersion !== first.packageManagerVersion) {
    throw new Error(
      `selected profiles require npm ${first.packageManagerVersion}; installed npm is ${npmVersion} (use the pinned Node distribution's bundled npm)`,
    );
  }
}

function validateInstalled(dir, pins) {
  for (const [name, version] of Object.entries(pins)) {
    const installed = readJson(
      path.join(dir, 'node_modules', name, 'package.json'),
    );
    if (installed.version !== version) {
      throw new Error(`${dir}: installed ${name} must be ${version}`);
    }
  }
}

function run(args) {
  const options = parseArgs(args);
  const rows = selectProfiles(loadRegistry(), options);
  validateProject(__dirname, rows[0], toolingPins);
  for (const row of rows) {
    const runtime = fs
      .readFileSync(path.join(row.dir, '.node-version'), 'utf8')
      .trim();
    if (runtime !== row.runtimeVersion) {
      throw new Error(`${row.id}: .node-version does not match runtimeVersion`);
    }
    validateProject(row.dir, row, {
      [row.suite.package]: row.clientVersion,
      jest: '30.2.0',
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
  if (options.action === 'test') {
    for (const row of rows) {
      if (row.suite.status === 'planned') {
        throw new Error(
          `${row.id}: suite ${row.suite.id} is planned; no client scenarios exist yet`,
        );
      }
    }
    throw new Error(
      'client execution requires the actual Node scenario implementation',
    );
  }
  validateRuntime(rows);
  if (options.action === 'deps') {
    command('npm', ['ci', '--no-audit', '--no-fund'], __dirname);
  }
  validateInstalled(__dirname, toolingPins);
  for (const row of rows) {
    if (options.action === 'deps') {
      command('npm', ['ci', '--no-audit', '--no-fund'], row.dir);
    }
    validateInstalled(row.dir, {
      [row.suite.package]: row.clientVersion,
      jest: '30.2.0',
    });
    console.log(
      `${row.id}: locked dependencies validated (${row.suite.status} suite)`,
    );
  }
}

try {
  run(process.argv.slice(2));
} catch (error) {
  console.error(`Node client profiles: ${error.message}`);
  process.exitCode = error.exitCode ?? 1;
}

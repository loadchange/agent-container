#!/usr/bin/env node

/**
 * Per-session host command broker for agent-container.
 *
 * Security boundary:
 * - The launcher, the session directory, and its manifests are trusted.
 * - A connected guest is untrusted until it proves possession of the 256-bit
 *   session token.
 * - Every command is selected from the launcher's manifest and runs under a
 *   dynamically generated sandbox-exec profile.
 * - This is still an explicit host-code-execution capability. sandbox-exec is
 *   a deprecated macOS interface, and allowing process/network access means
 *   callers can execute arbitrary language-runtime code inside the declared
 *   filesystem boundary. Do not expose the TCP listener outside a host-only
 *   interface.
 *
 * Protocol: one request per TCP connection, one JSON object per line.
 * Client -> broker:
 *   {"v":1,"type":"run","token":"...","command":"node","cwd":"/...",
 *    "argv":[...],"env":{...},"stdin":true}
 *   {"type":"stdin","data":"<base64>"} ...
 *   {"type":"stdin_end"}
 *   {"type":"signal","signal":"SIGINT|SIGTERM|SIGHUP"}
 * Broker -> client:
 *   {"type":"start","pid":123}
 *   {"type":"stdout|stderr","data":"<base64>"} ...
 *   {"type":"exit","code":0,"signal":null,"status":0}
 *   {"type":"error","code":"...","message":"..."}
 *
 * PTYs, terminal resize, file-descriptor passing, and reconnecting to a
 * detached service are intentionally out of scope for this first version.
 */

import { constants as fsConstants } from 'node:fs';
import {
  access,
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  rename,
  rm,
  stat,
} from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';
import { timingSafeEqual } from 'node:crypto';

const FILES = Object.freeze({
  commands: 'host-commands.tsv',
  roots: 'host-roots.tsv',
  toolRoots: 'host-tool-roots.txt',
  token: 'host-exec-token',
  endpoint: 'host-exec-endpoint',
});

const LIMITS = Object.freeze({
  // Manifests are expanded into repeated SBPL filters. Keep both the source
  // and generated-profile bounds deliberately small to avoid amplification.
  // The command catalog is different: entries select executables already
  // covered by a tool root and therefore do not add SBPL rules. It must fit a
  // normal /usr/bin + Homebrew PATH catalog.
  rootManifestBytes: 64 * 1024,
  rootManifestLines: 128,
  commandManifestBytes: 4 * 1024 * 1024,
  commandManifestLines: 4096,
  manifestPathBytes: 4096,
  sandboxProfileBytes: 128 * 1024,
  requestLineBytes: 512 * 1024,
  protocolLineBytes: 256 * 1024,
  argvCount: 256,
  argvItemBytes: 64 * 1024,
  argvTotalBytes: 256 * 1024,
  envCount: 128,
  envNameBytes: 128,
  envValueBytes: 32 * 1024,
  envTotalBytes: 256 * 1024,
  stdinFrameBytes: 64 * 1024,
  stdinTotalBytes: 64 * 1024 * 1024,
  connections: 32,
  activeCommands: 8,
  authenticationMs: 15_000,
  terminateGraceMs: 1_000,
  launcherPollMs: 500,
});

const SAFE_COMMAND_NAME = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/;
const SAFE_ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const TOKEN_PATTERN = /^[0-9a-f]{64}$/;
const ALLOWED_REQUEST_KEYS = new Set([
  'v',
  'type',
  'token',
  'command',
  'cwd',
  'argv',
  'env',
  'stdin',
]);
const RESERVED_ENV_PATTERN = /^(?:AGENT_|HOST_|HOME$|PATH$|SHELL$|USER$|LOGNAME$|TMPDIR$|TMP$|TEMP$|PWD$|OLDPWD$|SHLVL$|_$|SSH_AUTH_SOCK$|BASH_ENV$|ENV$|CDPATH$|GLOBIGNORE$|SHELLOPTS$|NODE_OPTIONS$|NODE_PATH$|PYTHONHOME$|PYTHONPATH$|PYTHONSTARTUP$|RUBYOPT$|PERL5OPT$|GIT_CONFIG(?:_GLOBAL|_SYSTEM|_COUNT|_KEY_[0-9]+|_VALUE_[0-9]+)?$|XDG_(?:CONFIG|CACHE|DATA|STATE)_HOME$|SSLKEYLOGFILE$|DYLD_.*|LD_.*)/;
const SECRET_ENV_PATTERN = /(?:^|_)(?:TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|COOKIE|PRIVATE_KEY|API_KEY)(?:$|_)/i;
const FORWARDED_HOST_ENV = new Set([
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'LC_MESSAGES',
  'TZ',
  'USER',
  'LOGNAME',
]);

// These paths are part of the macOS runtime, not user-selected tool roots.
// system.sb supplies most dylib/framework rules; the explicit paths cover
// normal command lookup and libc configuration used by CLI runtimes.
const SYSTEM_READ_ROOTS = Object.freeze([
  '/System',
  '/Library/Apple',
  '/bin',
  '/sbin',
  '/usr/bin',
  '/usr/sbin',
  '/usr/lib',
  '/usr/share',
  '/private/etc',
  '/private/var/db/timezone',
]);
const SYSTEM_EXEC_ROOTS = Object.freeze([
  '/bin',
  '/sbin',
  '/usr/bin',
  '/usr/sbin',
]);

class BrokerError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'BrokerError';
    this.code = code;
  }
}

function usage() {
  return `Usage: host-exec-broker.mjs \\
  --session-dir ABSOLUTE_DIR \\
  --bind-address IPV4 \\
  --launcher-pid PID \\
  --real-home ABSOLUTE_DIR \\
  --exec-home ABSOLUTE_DIR \\
  --sandbox-bin ABSOLUTE_EXECUTABLE`;
}

function fail(code, message) {
  throw new BrokerError(code, message);
}

function byteLength(value) {
  return Buffer.byteLength(value, 'utf8');
}

function hasUnsafePathCharacters(value) {
  return value.includes('\0') || value.includes('\n') || value.includes('\r');
}

function pathContains(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype;
}

function sbplQuote(value) {
  if (hasUnsafePathCharacters(value)) {
    fail('UNSAFE_PATH', 'A sandbox path contains a NUL or newline.');
  }
  return `"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === 'EPERM';
  }
}

function validateBindAddress(value) {
  if (!net.isIPv4(value)) {
    fail('INVALID_ARGUMENT', '--bind-address must be one IPv4 address.');
  }
  const octets = value.split('.').map(Number);
  if (value === '0.0.0.0' || value === '255.255.255.255' || octets[0] >= 224) {
    fail('INVALID_ARGUMENT', '--bind-address must be a specific unicast IPv4 address, not wildcard, broadcast, or multicast.');
  }
}

function parseArguments(argv) {
  const values = new Map();
  const allowed = new Set([
    '--session-dir',
    '--bind-address',
    '--launcher-pid',
    '--real-home',
    '--exec-home',
    '--sandbox-bin',
  ]);

  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(name) || value === undefined || value === '') {
      fail('INVALID_ARGUMENT', usage());
    }
    if (values.has(name)) {
      fail('INVALID_ARGUMENT', `Duplicate option: ${name}`);
    }
    values.set(name, value);
  }
  for (const name of allowed) {
    if (!values.has(name)) {
      fail('INVALID_ARGUMENT', `Missing ${name}.\n${usage()}`);
    }
  }

  const launcherPidText = values.get('--launcher-pid');
  if (!/^[1-9][0-9]{0,9}$/.test(launcherPidText)) {
    fail('INVALID_ARGUMENT', '--launcher-pid must be a positive decimal PID.');
  }
  const launcherPid = Number(launcherPidText);
  if (!Number.isSafeInteger(launcherPid) || launcherPid <= 1 || launcherPid === process.pid) {
    fail('INVALID_ARGUMENT', '--launcher-pid is unsafe.');
  }

  const bindAddress = values.get('--bind-address');
  validateBindAddress(bindAddress);
  return {
    sessionDirInput: values.get('--session-dir'),
    bindAddress,
    launcherPid,
    realHomeInput: values.get('--real-home'),
    execHomeInput: values.get('--exec-home'),
    sandboxBinInput: values.get('--sandbox-bin'),
  };
}

async function canonicalDirectory(input, label) {
  if (!path.isAbsolute(input) || hasUnsafePathCharacters(input)
    || byteLength(input) > LIMITS.manifestPathBytes) {
    fail('UNSAFE_PATH', `${label} must be an absolute path without NULs or newlines.`);
  }
  let resolved;
  try {
    resolved = await realpath(input);
    const info = await stat(resolved);
    if (!info.isDirectory()) {
      fail('UNSAFE_PATH', `${label} is not a directory.`);
    }
  } catch (error) {
    if (error instanceof BrokerError) throw error;
    fail('UNSAFE_PATH', `${label} cannot be resolved as a directory.`);
  }
  return resolved;
}

async function canonicalExecutable(input, label) {
  if (!path.isAbsolute(input) || hasUnsafePathCharacters(input)
    || byteLength(input) > LIMITS.manifestPathBytes) {
    fail('UNSAFE_PATH', `${label} must be an absolute executable path.`);
  }
  let resolved;
  try {
    resolved = await realpath(input);
    const info = await stat(resolved);
    if (!info.isFile()) {
      fail('UNSAFE_PATH', `${label} is not a regular file.`);
    }
    await access(resolved, fsConstants.X_OK);
  } catch (error) {
    if (error instanceof BrokerError) throw error;
    fail('UNSAFE_PATH', `${label} is not an executable regular file.`);
  }
  return resolved;
}

async function readTrustedManifest(
  sessionDir,
  filename,
  { required = true, maxBytes = LIMITS.rootManifestBytes } = {},
) {
  const manifestPath = path.join(sessionDir, filename);
  let info;
  try {
    info = await lstat(manifestPath);
  } catch (error) {
    if (!required && error?.code === 'ENOENT') return '';
    fail('INVALID_MANIFEST', `${filename} is missing.`);
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > maxBytes) {
    fail('INVALID_MANIFEST', `${filename} must be a small, non-symlink regular file.`);
  }
  const value = await readFile(manifestPath, 'utf8');
  if (value.includes('\0')) {
    fail('INVALID_MANIFEST', `${filename} contains a NUL byte.`);
  }
  return value;
}

function manifestLines(
  value,
  filename,
  { allowEmpty = false, maxLines = LIMITS.rootManifestLines } = {},
) {
  const normalized = value.endsWith('\n') ? value.slice(0, -1) : value;
  if (normalized === '') {
    if (allowEmpty) return [];
    fail('INVALID_MANIFEST', `${filename} is empty.`);
  }
  const lines = normalized.split('\n');
  if (lines.length > maxLines || lines.some((line) => line === '' || line.includes('\r'))) {
    fail('INVALID_MANIFEST', `${filename} has empty, CR-containing, or excessive lines.`);
  }
  return lines;
}

async function parseCanonicalRootLines(value, filename, realHome, execHome, withMode) {
  const roots = [];
  const seen = new Set();
  for (const line of manifestLines(value, filename, { allowEmpty: true })) {
    let mode = 'ro';
    let rootInput = line;
    if (withMode) {
      const fields = line.split('\t');
      if (fields.length !== 2 || !['ro', 'rw'].includes(fields[0])) {
        fail('INVALID_MANIFEST', `${filename} must contain mode<TAB>canonical-root.`);
      }
      [mode, rootInput] = fields;
    } else if (line.includes('\t')) {
      fail('INVALID_MANIFEST', `${filename} must contain one canonical root per line.`);
    }
    const root = await canonicalDirectory(rootInput, `${filename} root`);
    if (root !== rootInput) {
      fail('INVALID_MANIFEST', `${filename} contains a non-canonical root.`);
    }
    if (root === '/' || pathContains(root, realHome)) {
      fail('INVALID_MANIFEST', `${filename} may not expose / or the complete real home.`);
    }
    if (withMode && (pathContains(root, execHome) || pathContains(execHome, root))) {
      fail('INVALID_MANIFEST', `${filename} roots may not overlap the isolated execution home.`);
    }
    const duplicateKey = withMode ? root : `${mode}\0${root}`;
    if (seen.has(duplicateKey)) {
      fail('INVALID_MANIFEST', `${filename} contains a duplicate root.`);
    }
    seen.add(duplicateKey);
    roots.push({ mode, path: root });
  }
  return roots;
}

function validateRootRelationships(roots) {
  for (let left = 0; left < roots.length; left += 1) {
    for (let right = left + 1; right < roots.length; right += 1) {
      const a = roots[left];
      const b = roots[right];
      if (a.path === b.path && a.mode !== b.mode) {
        fail('INVALID_MANIFEST', 'host-roots.tsv assigns two modes to one root.');
      }
      // A writable parent would silently make a declared read-only child
      // writable. A read-only parent with a narrower writable child is safe.
      if ((a.mode === 'rw' && b.mode === 'ro' && pathContains(a.path, b.path))
        || (b.mode === 'rw' && a.mode === 'ro' && pathContains(b.path, a.path))) {
        fail('INVALID_MANIFEST', 'A writable root may not contain a read-only root.');
      }
    }
  }
}

async function loadConfiguration(argumentsValue) {
  const sessionDir = await canonicalDirectory(argumentsValue.sessionDirInput, '--session-dir');
  const realHome = await canonicalDirectory(argumentsValue.realHomeInput, '--real-home');
  const execHome = await canonicalDirectory(argumentsValue.execHomeInput, '--exec-home');
  if (realHome === execHome || !pathContains(realHome, execHome)) {
    fail('UNSAFE_PATH', '--exec-home must be a narrower directory below --real-home.');
  }
  const sandboxBin = await canonicalExecutable(argumentsValue.sandboxBinInput, '--sandbox-bin');

  const tokenText = await readTrustedManifest(sessionDir, FILES.token, { maxBytes: 1024 });
  const token = tokenText.endsWith('\n') ? tokenText.slice(0, -1) : tokenText;
  if (!TOKEN_PATTERN.test(token) || tokenText !== `${token}\n`) {
    fail('INVALID_MANIFEST', `${FILES.token} must contain exactly one lowercase 64-hex token and a newline.`);
  }

  const rootText = await readTrustedManifest(sessionDir, FILES.roots);
  const roots = await parseCanonicalRootLines(rootText, FILES.roots, realHome, execHome, true);
  if (roots.length === 0) {
    fail('INVALID_MANIFEST', `${FILES.roots} must declare at least one execution root.`);
  }
  validateRootRelationships(roots);

  const toolRootText = await readTrustedManifest(sessionDir, FILES.toolRoots);
  const toolRootRecords = await parseCanonicalRootLines(
    toolRootText,
    FILES.toolRoots,
    realHome,
    execHome,
    false,
  );
  const toolRoots = toolRootRecords.map((record) => record.path);

  const commandText = await readTrustedManifest(sessionDir, FILES.commands, {
    maxBytes: LIMITS.commandManifestBytes,
  });
  const commands = new Map();
  for (const line of manifestLines(commandText, FILES.commands, {
    maxLines: LIMITS.commandManifestLines,
  })) {
    const fields = line.split('\t');
    if (fields.length !== 3 || !['first', 'fallback'].includes(fields[0])) {
      fail('INVALID_MANIFEST', `${FILES.commands} must contain first|fallback<TAB>name<TAB>absolute-executable.`);
    }
    const [mode, name, executableInput] = fields;
    if (!SAFE_COMMAND_NAME.test(name) || name === '.' || name === '..') {
      fail('INVALID_MANIFEST', `${FILES.commands} contains an unsafe command name.`);
    }
    if (commands.has(name)) {
      fail('INVALID_MANIFEST', `${FILES.commands} contains a duplicate command name.`);
    }
    const executable = await canonicalExecutable(executableInput, `Executable for ${name}`);
    const inSystemRoot = SYSTEM_EXEC_ROOTS.some((root) => pathContains(root, executable));
    const inToolRoot = toolRoots.some((root) => pathContains(root, executable));
    if (!inSystemRoot && !inToolRoot) {
      fail('INVALID_MANIFEST', `Executable for ${name} is outside the declared read-only tool roots.`);
    }
    commands.set(name, Object.freeze({ mode, name, executable }));
  }

  const tempDir = path.join(execHome, '.cache', 'agent-container', 'host-exec-tmp');
  await mkdir(tempDir, { recursive: true, mode: 0o700 });

  return Object.freeze({
    ...argumentsValue,
    sessionDir,
    realHome,
    execHome,
    sandboxBin,
    token,
    tokenBuffer: Buffer.from(token, 'ascii'),
    roots: Object.freeze(roots),
    toolRoots: Object.freeze(toolRoots),
    commands,
    tempDir,
  });
}

function isForwardableEnvironmentName(name) {
  return SAFE_ENV_NAME.test(name)
    && byteLength(name) <= LIMITS.envNameBytes
    && !RESERVED_ENV_PATTERN.test(name)
    && !SECRET_ENV_PATTERN.test(name);
}

function validateRequest(request, configuration) {
  if (!isPlainObject(request)
    || Object.keys(request).some((key) => !ALLOWED_REQUEST_KEYS.has(key))
    || request.v !== 1
    || request.type !== 'run') {
    fail('INVALID_REQUEST', 'The first frame is not a supported run request.');
  }

  if (typeof request.token !== 'string' || !TOKEN_PATTERN.test(request.token)) {
    fail('AUTH_FAILED', 'Authentication failed.');
  }
  const suppliedToken = Buffer.from(request.token, 'ascii');
  if (suppliedToken.length !== configuration.tokenBuffer.length
    || !timingSafeEqual(suppliedToken, configuration.tokenBuffer)) {
    fail('AUTH_FAILED', 'Authentication failed.');
  }

  if (typeof request.command !== 'string' || !SAFE_COMMAND_NAME.test(request.command)) {
    fail('INVALID_REQUEST', 'command is not a safe basename.');
  }
  const command = configuration.commands.get(request.command);
  if (!command) {
    fail('COMMAND_DENIED', 'The requested command is not enabled for this session.');
  }

  if (typeof request.cwd !== 'string' || !path.isAbsolute(request.cwd)
    || hasUnsafePathCharacters(request.cwd) || byteLength(request.cwd) > 4096) {
    fail('INVALID_REQUEST', 'cwd must be a bounded absolute path.');
  }

  if (!Array.isArray(request.argv) || request.argv.length > LIMITS.argvCount) {
    fail('INVALID_REQUEST', 'argv is not a bounded string array.');
  }
  let argvBytes = 0;
  for (const argument of request.argv) {
    if (typeof argument !== 'string' || argument.includes('\0')
      || byteLength(argument) > LIMITS.argvItemBytes) {
      fail('INVALID_REQUEST', 'argv contains an invalid or oversized item.');
    }
    argvBytes += byteLength(argument);
  }
  if (argvBytes > LIMITS.argvTotalBytes) {
    fail('INVALID_REQUEST', 'argv exceeds the total byte limit.');
  }

  if (!isPlainObject(request.env) || Object.keys(request.env).length > LIMITS.envCount) {
    fail('INVALID_REQUEST', 'env is not a bounded object.');
  }
  let envBytes = 0;
  const forwardedEnvironment = {};
  for (const [name, value] of Object.entries(request.env)) {
    if (!isForwardableEnvironmentName(name) || typeof value !== 'string'
      || value.includes('\0') || byteLength(value) > LIMITS.envValueBytes) {
      fail('INVALID_REQUEST', 'env contains a reserved, invalid, or oversized entry.');
    }
    envBytes += byteLength(name) + byteLength(value);
    forwardedEnvironment[name] = value;
  }
  if (envBytes > LIMITS.envTotalBytes) {
    fail('INVALID_REQUEST', 'env exceeds the total byte limit.');
  }
  if (typeof request.stdin !== 'boolean') {
    fail('INVALID_REQUEST', 'stdin must be a boolean.');
  }

  return { command, request, forwardedEnvironment };
}

async function resolveRequestCwd(cwdInput, configuration) {
  let cwd;
  try {
    cwd = await realpath(cwdInput);
    const info = await stat(cwd);
    if (!info.isDirectory()) fail('CWD_DENIED', 'cwd is not a directory.');
  } catch (error) {
    if (error instanceof BrokerError) throw error;
    fail('CWD_DENIED', 'cwd cannot be resolved.');
  }
  const allowed = pathContains(configuration.execHome, cwd)
    || configuration.roots.some((root) => pathContains(root.path, cwd));
  if (!allowed) {
    fail('CWD_DENIED', 'cwd is outside the declared execution roots.');
  }
  return cwd;
}

function sandboxPathRules(operation, paths) {
  if (paths.length === 0) return '';
  const filters = paths.map((value) => `    (subpath ${sbplQuote(value)})`).join('\n');
  return `  (allow ${operation}\n${filters})\n`;
}

function sandboxLiteralRules(operation, paths) {
  if (paths.length === 0) return '';
  const filters = paths.map((value) => `    (literal ${sbplQuote(value)})`).join('\n');
  return `  (allow ${operation}\n${filters})\n`;
}

function sandboxAncestorRules(paths) {
  const unique = [...new Set(paths)];
  if (unique.length === 0) return '';
  const filters = unique.map((value) => `    (path-ancestors ${sbplQuote(value)})`).join('\n');
  return `  (allow file-read-metadata file-test-existence\n${filters})\n`;
}

function buildSandboxProfile(configuration) {
  const readOnlyRoots = configuration.roots
    .filter((root) => root.mode === 'ro')
    .map((root) => root.path);
  const writableRoots = configuration.roots
    .filter((root) => root.mode === 'rw')
    .map((root) => root.path);
  const readable = [
    ...SYSTEM_READ_ROOTS,
    ...configuration.toolRoots,
    ...readOnlyRoots,
    ...writableRoots,
    configuration.execHome,
  ];
  const executable = [
    ...SYSTEM_EXEC_ROOTS,
    ...configuration.toolRoots,
    ...readOnlyRoots,
    ...writableRoots,
    configuration.execHome,
  ];
  const writable = [...writableRoots, configuration.execHome];

  return [
    '(version 1)\n',
    '(deny default)\n',
    '(import "system.sb")\n',
    '  (allow process*)\n',
    '  (allow network*)\n',
    sandboxPathRules('file-read* file-test-existence', readable),
    sandboxPathRules('file-map-executable', executable),
    sandboxPathRules('file-write*', writable),
    sandboxAncestorRules(readable),
  ].join('');
}

function buildCommandSandboxProfile(configuration, command) {
  const baseProfile = buildSandboxProfile(configuration);
  if (command.name !== 'git') return baseProfile;
  const gitConfig = path.join(configuration.realHome, '.gitconfig');
  const gitXdgConfig = path.join(configuration.realHome, '.config', 'git');
  const sshMetadata = [
    'config',
    'known_hosts',
    'known_hosts.old',
    'allowed_signers',
  ].map((name) => path.join(configuration.realHome, '.ssh', name));
  return [
    baseProfile,
    sandboxLiteralRules('file-read* file-test-existence', [gitConfig, ...sshMetadata]),
    sandboxPathRules('file-read* file-test-existence', [gitXdgConfig]),
    sandboxAncestorRules([gitConfig, gitXdgConfig, ...sshMetadata]),
  ].join('');
}

function buildChildEnvironment(configuration, command, forwardedEnvironment) {
  const commandHome = command.name === 'git' ? configuration.realHome : configuration.execHome;
  const environment = {
    HOME: commandHome,
    PATH: process.env.PATH || '/usr/bin:/bin:/usr/sbin:/sbin',
    SHELL: '/bin/sh',
    TMPDIR: `${configuration.tempDir}${path.sep}`,
    XDG_CONFIG_HOME: path.join(commandHome, '.config'),
    XDG_CACHE_HOME: path.join(configuration.execHome, '.cache'),
    XDG_DATA_HOME: path.join(configuration.execHome, '.local', 'share'),
    XDG_STATE_HOME: path.join(configuration.execHome, '.local', 'state'),
    AGENT_CONTAINER_HOST_EXEC: '1',
  };
  for (const name of FORWARDED_HOST_ENV) {
    const value = process.env[name];
    if (typeof value === 'string' && !value.includes('\0')) environment[name] = value;
  }
  // Authentication socket authority comes only from the launcher's controlled
  // broker environment, never from a guest request.
  if (typeof process.env.SSH_AUTH_SOCK === 'string'
    && path.isAbsolute(process.env.SSH_AUTH_SOCK)
    && !hasUnsafePathCharacters(process.env.SSH_AUTH_SOCK)) {
    environment.SSH_AUTH_SOCK = process.env.SSH_AUTH_SOCK;
  }
  Object.assign(environment, forwardedEnvironment);
  return environment;
}

function strictBase64(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > Math.ceil(LIMITS.stdinFrameBytes / 3) * 4 + 4
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    fail('INVALID_STDIN', 'stdin data is not bounded canonical base64.');
  }
  const decoded = Buffer.from(value, 'base64');
  if (decoded.length > LIMITS.stdinFrameBytes || decoded.toString('base64') !== value) {
    fail('INVALID_STDIN', 'stdin data is not bounded canonical base64.');
  }
  return decoded;
}

function signalExitStatus(signal) {
  const number = os.constants.signals[signal];
  return Number.isInteger(number) ? Math.min(255, 128 + number) : 125;
}

function sendFrame(socket, frame) {
  if (socket.destroyed) return false;
  try {
    return socket.write(`${JSON.stringify(frame)}\n`);
  } catch {
    return false;
  }
}

function sendError(socket, error) {
  const code = error instanceof BrokerError ? error.code : 'INTERNAL_ERROR';
  const message = error instanceof BrokerError ? error.message : 'The host executor failed internally.';
  sendFrame(socket, { type: 'error', code, message });
}

function closeSocketSoon(socket) {
  if (socket.destroyed) return;
  socket.pause();
  socket.end();
  if (typeof socket.destroySoon === 'function') socket.destroySoon();
  const forceTimer = setTimeout(() => socket.destroy(), 250);
  forceTimer.unref();
  socket.once('close', () => clearTimeout(forceTimer));
}

function killProcessGroup(context, signal) {
  if (!context.child?.pid) return;
  try {
    process.kill(-context.child.pid, signal);
  } catch (error) {
    if (error?.code !== 'ESRCH') {
      process.stderr.write(`host-exec-broker: failed to send ${signal} to process group ${context.child.pid}: ${error.message}\n`);
    }
  }
}

function terminateContext(context, immediate = false) {
  if (!context.child?.pid) return;
  killProcessGroup(context, immediate ? 'SIGKILL' : 'SIGTERM');
  if (!immediate && !context.killTimer) {
    context.killTimer = setTimeout(() => killProcessGroup(context, 'SIGKILL'), LIMITS.terminateGraceMs);
    context.killTimer.unref();
  }
}

function enterTerminalState(context) {
  if (context.terminal) return;
  context.terminal = true;
  context.phase = 'terminal';
  context.buffer = '';
  context.inputPaused = true;
  if (context.authTimer) clearTimeout(context.authTimer);
  context.authTimer = undefined;
  context.socket.pause();
  return true;
}

function failContext(context, error) {
  if (!enterTerminalState(context)) return;
  sendError(context.socket, error);
  terminateContext(context);
  closeSocketSoon(context.socket);
}

function attachOutputStream(stream, socket, type) {
  stream.on('data', (chunk) => {
    const writable = sendFrame(socket, { type, data: chunk.toString('base64') });
    if (!writable && !socket.destroyed) {
      stream.pause();
      socket.once('drain', () => stream.resume());
    }
  });
}

async function spawnRequest(context, validated, configuration, activeContexts) {
  if (activeContexts.size >= LIMITS.activeCommands) {
    fail('BUSY', 'This host executor has reached its active-command limit.');
  }
  // Reserve the slot before the asynchronous cwd lookup. Without this, a
  // burst of requests can all observe the same pre-spawn count and exceed the
  // advertised per-session concurrency bound.
  activeContexts.add(context);
  let cwd;
  try {
    cwd = await resolveRequestCwd(validated.request.cwd, configuration);
  } catch (error) {
    activeContexts.delete(context);
    throw error;
  }
  if (context.terminal || context.socket.destroyed) {
    activeContexts.delete(context);
    return;
  }

  const profile = buildCommandSandboxProfile(configuration, validated.command);
  if (byteLength(profile) > LIMITS.sandboxProfileBytes) {
    activeContexts.delete(context);
    fail('INVALID_MANIFEST', 'The generated command sandbox profile is too large.');
  }
  const childEnvironment = buildChildEnvironment(
    configuration,
    validated.command,
    validated.forwardedEnvironment,
  );
  let child;
  try {
    child = spawn(
      configuration.sandboxBin,
      ['-p', profile, validated.command.executable, ...validated.request.argv],
      {
        cwd,
        env: childEnvironment,
        detached: true,
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    );
  } catch (error) {
    activeContexts.delete(context);
    throw error;
  }
  context.child = child;
  context.phase = 'running';
  context.stdinExpected = validated.request.stdin;

  attachOutputStream(child.stdout, context.socket, 'stdout');
  attachOutputStream(child.stderr, context.socket, 'stderr');

  child.once('spawn', () => {
    context.authTimer && clearTimeout(context.authTimer);
    context.authTimer = undefined;
    sendFrame(context.socket, {
      type: 'start',
      pid: child.pid,
      command: validated.command.name,
      mode: validated.command.mode,
    });
    if (!context.stdinExpected) child.stdin.end();
  });

  child.once('error', (error) => {
    failContext(
      context,
      new BrokerError('SPAWN_FAILED', `Unable to start the allowed host command: ${error.message}`),
    );
    terminateContext(context, true);
  });

  child.once('close', (code, signal) => {
    activeContexts.delete(context);
    // End every background descendant that remains in this request's process
    // group whenever its leader exits. Deliberate setsid-style daemonization is
    // outside the protocol contract and cannot be contained by a PGID alone.
    killProcessGroup(context, 'SIGTERM');
    if (!context.killTimer) {
      context.killTimer = setTimeout(
        () => killProcessGroup(context, 'SIGKILL'),
        LIMITS.terminateGraceMs,
      );
      context.killTimer.unref();
    }
    const status = Number.isInteger(code) ? Math.max(0, Math.min(255, code)) : signalExitStatus(signal);
    if (enterTerminalState(context)) {
      sendFrame(context.socket, {
        type: 'exit',
        code: Number.isInteger(code) ? code : null,
        signal: signal || null,
        status,
      });
      closeSocketSoon(context.socket);
    }
    context.completed = true;
  });

  // The request and the first stdin frames commonly arrive in one TCP packet.
  // Revisit anything retained while cwd resolution and spawn were in flight.
  if (context.buffer !== '') {
    processBufferedLines(context, configuration, activeContexts);
  }
}

function processBufferedLines(context, configuration, activeContexts) {
  if (context.terminal) return;
  while (!context.inputPaused && !context.terminal) {
    const newline = context.buffer.indexOf('\n');
    if (newline === -1) break;
    const line = context.buffer.slice(0, newline);
    context.buffer = context.buffer.slice(newline + 1);
    if (line === '' || line.includes('\r')) {
      throw new BrokerError('INVALID_FRAME', 'Protocol frames must be non-empty LF-delimited JSON.');
    }
    const lineLimit = context.phase === 'awaiting_request'
      ? LIMITS.requestLineBytes
      : LIMITS.protocolLineBytes;
    if (byteLength(line) > lineLimit) {
      throw new BrokerError('INVALID_FRAME', 'A protocol frame exceeds its byte limit.');
    }
    let frame;
    try {
      frame = JSON.parse(line);
    } catch {
      throw new BrokerError('INVALID_FRAME', 'A protocol frame is not valid JSON.');
    }

    if (context.phase === 'awaiting_request') {
      const validated = validateRequest(frame, configuration);
      if (context.authTimer) clearTimeout(context.authTimer);
      context.authTimer = undefined;
      context.phase = 'starting';
      void spawnRequest(context, validated, configuration, activeContexts).catch((error) => {
        failContext(context, error);
      });
      continue;
    }
    if (!isPlainObject(frame) || typeof frame.type !== 'string') {
      throw new BrokerError('INVALID_FRAME', 'A streaming frame is invalid.');
    }
    if (context.phase === 'starting') {
      // TCP data may carry request and stdin frames together. Retain them until
      // the child pipe exists instead of dropping early input.
      context.buffer = `${line}\n${context.buffer}`;
      break;
    }
    if (context.phase !== 'running' || !context.child) {
      throw new BrokerError('INVALID_FRAME', 'No command is accepting streaming frames.');
    }

    if (frame.type === 'stdin') {
      if (!context.stdinExpected || context.stdinEnded || Object.keys(frame).some((key) => !['type', 'data'].includes(key))) {
        throw new BrokerError('INVALID_STDIN', 'stdin is disabled or already ended.');
      }
      const decoded = strictBase64(frame.data);
      context.stdinBytes += decoded.length;
      if (context.stdinBytes > LIMITS.stdinTotalBytes) {
        throw new BrokerError('INVALID_STDIN', 'stdin exceeds the per-command byte limit.');
      }
      if (!context.child.stdin.write(decoded)) {
        context.inputPaused = true;
        context.socket.pause();
        context.child.stdin.once('drain', () => {
          context.inputPaused = false;
          context.socket.resume();
          try {
            processBufferedLines(context, configuration, activeContexts);
          } catch (error) {
            failContext(context, error);
          }
        });
      }
    } else if (frame.type === 'stdin_end') {
      if (!context.stdinExpected || context.stdinEnded || Object.keys(frame).length !== 1) {
        throw new BrokerError('INVALID_STDIN', 'stdin_end is unexpected.');
      }
      context.stdinEnded = true;
      context.child.stdin.end();
    } else if (frame.type === 'signal') {
      if (Object.keys(frame).some((key) => !['type', 'signal'].includes(key))
        || !['SIGINT', 'SIGTERM', 'SIGHUP'].includes(frame.signal)) {
        throw new BrokerError('INVALID_SIGNAL', 'Only SIGINT, SIGTERM, and SIGHUP may be forwarded.');
      }
      killProcessGroup(context, frame.signal);
    } else {
      throw new BrokerError('INVALID_FRAME', 'Unsupported streaming frame type.');
    }
  }

  const bufferedLimit = context.phase === 'awaiting_request'
    ? LIMITS.requestLineBytes
    : LIMITS.protocolLineBytes;
  if (byteLength(context.buffer) > bufferedLimit) {
    throw new BrokerError('INVALID_FRAME', 'An unterminated protocol frame exceeds its byte limit.');
  }
}

async function writeEndpoint(configuration, address, port) {
  const endpointPath = path.join(configuration.sessionDir, FILES.endpoint);
  try {
    const existing = await lstat(endpointPath);
    if (!existing.isFile() || existing.isSymbolicLink()) {
      fail('UNSAFE_PATH', `${FILES.endpoint} is not a safe replaceable regular file.`);
    }
  } catch (error) {
    if (error instanceof BrokerError) throw error;
    if (error?.code !== 'ENOENT') throw error;
  }

  const temporaryPath = path.join(
    configuration.sessionDir,
    `.${FILES.endpoint}.${process.pid}.${Date.now()}.tmp`,
  );
  const handle = await open(temporaryPath, 'wx', 0o600);
  try {
    await handle.writeFile(`${address}:${port}\n`, 'utf8');
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await rename(temporaryPath, endpointPath);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
  return endpointPath;
}

async function main() {
  const argumentsValue = parseArguments(process.argv.slice(2));
  if (!isPidAlive(argumentsValue.launcherPid)) {
    fail('LAUNCHER_GONE', 'The launcher PID is not alive.');
  }
  const configuration = await loadConfiguration(argumentsValue);
  const sandboxProfile = buildSandboxProfile(configuration);
  if (byteLength(sandboxProfile) > LIMITS.sandboxProfileBytes) {
    fail('INVALID_MANIFEST', 'The generated sandbox profile is too large.');
  }

  const activeContexts = new Set();
  const sockets = new Set();
  let shuttingDown = false;
  let endpointPath;
  let launcherTimer;

  const server = net.createServer((socket) => {
    if (shuttingDown || sockets.size >= LIMITS.connections) {
      sendError(socket, new BrokerError('BUSY', 'The host executor is not accepting another connection.'));
      closeSocketSoon(socket);
      return;
    }
    socket.setNoDelay(true);
    socket.setEncoding('utf8');
    sockets.add(socket);
    const context = {
      socket,
      phase: 'awaiting_request',
      buffer: '',
      child: undefined,
      stdinExpected: false,
      stdinEnded: false,
      stdinBytes: 0,
      inputPaused: false,
      completed: false,
      killTimer: undefined,
      authTimer: undefined,
      terminal: false,
    };

    context.authTimer = setTimeout(() => {
      failContext(
        context,
        new BrokerError('AUTH_TIMEOUT', 'The authenticated request was not received in time.'),
      );
    }, LIMITS.authenticationMs);
    context.authTimer.unref();

    socket.on('data', (chunk) => {
      if (context.terminal) return;
      context.buffer += chunk;
      try {
        processBufferedLines(context, configuration, activeContexts);
      } catch (error) {
        failContext(context, error);
      }
    });
    socket.on('error', () => {
      enterTerminalState(context);
      if (!context.child) activeContexts.delete(context);
      terminateContext(context);
      socket.destroy();
    });
    socket.on('close', () => {
      sockets.delete(socket);
      enterTerminalState(context);
      if (!context.child) activeContexts.delete(context);
      if (!context.completed) terminateContext(context);
    });
  });

  const removeEndpoint = async () => {
    if (!endpointPath) return;
    try {
      const info = await lstat(endpointPath);
      if (info.isFile() && !info.isSymbolicLink()) await rm(endpointPath);
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        process.stderr.write(`host-exec-broker: unable to remove endpoint: ${error.message}\n`);
      }
    }
    endpointPath = undefined;
  };

  const shutdown = async (reason, status = 0) => {
    if (shuttingDown) return;
    shuttingDown = true;
    if (launcherTimer) clearInterval(launcherTimer);
    server.close();
    for (const context of activeContexts) terminateContext(context);
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => setTimeout(resolve, LIMITS.terminateGraceMs + 50));
    for (const context of activeContexts) terminateContext(context, true);
    await removeEndpoint();
    if (reason) process.stderr.write(`host-exec-broker: ${reason}\n`);
    process.exit(status);
  };

  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, () => void shutdown(`received ${signal}`, 128 + os.constants.signals[signal]));
  }
  process.on('uncaughtException', (error) => {
    process.stderr.write(`host-exec-broker: uncaught exception: ${error.stack || error.message}\n`);
    void shutdown('fatal broker exception', 70);
  });
  process.on('unhandledRejection', (error) => {
    process.stderr.write(`host-exec-broker: unhandled rejection: ${error?.stack || error}\n`);
    void shutdown('fatal broker rejection', 70);
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen({ host: configuration.bindAddress, port: 0, exclusive: true }, resolve);
  });
  const address = server.address();
  if (!isPlainObject(address) || address.family !== 'IPv4') {
    await shutdown('listener did not receive an IPv4 address', 70);
    return;
  }
  endpointPath = await writeEndpoint(configuration, address.address, address.port);

  // This is the only structured readiness output. Launchers may wait for either
  // this line or the atomically published endpoint file.
  process.stdout.write(`${JSON.stringify({
    type: 'ready',
    address: address.address,
    port: address.port,
    endpoint: `${address.address}:${address.port}`,
  })}\n`);

  launcherTimer = setInterval(() => {
    if (!isPidAlive(configuration.launcherPid)) {
      void shutdown('launcher exited; terminating host commands', 0);
    }
  }, LIMITS.launcherPollMs);
  launcherTimer.unref();
}

main().catch((error) => {
  const code = error instanceof BrokerError ? error.code : 'INTERNAL_ERROR';
  process.stderr.write(`host-exec-broker: ${code}: ${error.message}\n`);
  process.exitCode = error instanceof BrokerError ? 64 : 70;
});

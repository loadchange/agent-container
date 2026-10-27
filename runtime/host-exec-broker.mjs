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
 * An authenticated {"v":1,"type":"catalog","token":"..."} request instead
 * returns the complete enabled command catalog as one
 * {"type":"catalog","commands":[{"name":...,"mode":"first|fallback"},...]}
 * line and closes; guest session helpers use it to create local PATH shims.
 *
 * The command manifest is either staged directly by the launcher
 * (host-commands.tsv) or generated here from a launcher-staged catalog
 * specification (host-catalog.json) that freezes the host PATH directories,
 * deny/first policy, and the resolved Node.js and Xcode/CommandLineTools
 * executables. Building the catalog in-process replaces a per-candidate
 * fork/exec walk in the shell launcher with plain syscalls.
 *
 * PTYs, terminal resize, file-descriptor passing, and reconnecting to a
 * detached service are intentionally out of scope for this first version.
 *
 * Full host access (--access full):
 * The launcher opts one client out of the sandbox entirely. The same protocol
 * and the same token authenticate the guest, but a command then
 * - runs directly (no sandbox-exec) as the macOS user, with the real HOME and
 *   this broker's inherited environment (launcher-internal names removed);
 * - may start in any host directory (a cwd below the guest's /host mount is
 *   mapped back to the host path; a guest-only cwd falls back to HOME with a
 *   note on stderr);
 * - is selected from the whole PATH catalog with no tool-root containment;
 * - may leave background processes behind: the process group is only
 *   signalled when the guest disconnects early, never after a normal exit.
 *   A background process that keeps the output pipes open is cut loose after
 *   a short idle period instead of hanging the guest forever.
 * A second listener on the same host-only address relays authenticated,
 * allowlisted loopback ports. Its first line is
 *   AGENT-CONTAINER-TUNNEL/1 <token> <port>\n
 * and everything after it is an unmodified byte stream to 127.0.0.1:<port>.
 * Nothing here is a security boundary against the guest: possession of the
 * token is the whole authorization. Do not expose the listeners beyond the
 * VM gateway address.
 */

import { constants as fsConstants } from 'node:fs';
import {
  access,
  lstat,
  mkdir,
  open,
  readdir,
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
  catalog: 'host-catalog.json',
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
  commandManifestLines: 8192,
  catalogSpecificationBytes: 256 * 1024,
  catalogDirectories: 64,
  catalogNameListEntries: 512,
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
  connections: 64,
  activeCommands: 32,
  authenticationMs: 15_000,
  terminateGraceMs: 1_000,
  launcherPollMs: 500,
  // A finished command's socket is force-closed only after its queued output
  // has stopped draining for this long (normally the guest closes first).
  closeStallMs: 30_000,
  // Full access mode only.
  fullEnvCount: 1024,
  exitDrainMs: 400,
  tunnelPorts: 64,
  tunnelConnections: 128,
  tunnelAuthBytes: 160,
  tunnelAuthMs: 5_000,
  tunnelConnectMs: 5_000,
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

// Full access mode (--access full). With no sandbox, the name filters shrink
// to the variables that are meaningless or harmful once they cross the VM
// boundary: guest identity and path variables, shell start-up injection
// points, guest Git configuration, and image-specific Corepack/pnpm paths.
// Reserved names are dropped rather than rejected so a guest client that
// disagrees about the list can never turn a harmless difference into a failed
// command. Secret-looking names are forwarded: the guest already holds them.
const GUEST_HOST_ROOT = '/host';
const FULL_RESERVED_ENV_PATTERN = /^(?:AGENT_|HOST_|HOME$|PATH$|SHELL$|USER$|LOGNAME$|TMPDIR$|TMP$|TEMP$|PWD$|OLDPWD$|SHLVL$|_$|SSH_AUTH_SOCK$|XDG_RUNTIME_DIR$|BASH_ENV$|ENV$|CDPATH$|GLOBIGNORE$|SHELLOPTS$|PYTHONHOME$|PYTHONPATH$|NODE_PATH$|GIT_CONFIG(?:_GLOBAL|_SYSTEM|_COUNT|_KEY_[0-9]+|_VALUE_[0-9]+)?$|COREPACK_.*|PNPM_CONFIG_.*|IS_SANDBOX$|DYLD_.*|LD_.*)/;
// The launcher's private protocol variables never reach a host command.
const LAUNCHER_INTERNAL_ENV_PATTERN = /^(?:AGENT_CONTAINER_|AGENT_WORKSPACE_)/;
const TUNNEL_AUTH_PATTERN = /^AGENT-CONTAINER-TUNNEL\/1 ([0-9a-f]{64}) ([1-9][0-9]{0,4})$/;

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

// Stock macOS developer commands are /usr/bin shims that consult xcrun and
// mutable caches. Catalog entries for these names are frozen to the selected
// Xcode/CommandLineTools executables so the sandbox never needs ambient
// developer-cache behavior.
const DEVELOPER_SHIM_COMMANDS = Object.freeze(new Set([
  'ar', 'as', 'c++', 'cc', 'clang', 'clang++', 'gcc', 'git', 'ld', 'libtool',
  'lipo', 'make', 'nm', 'otool', 'pip3', 'python3', 'ranlib', 'size',
  'strings', 'strip', 'swift', 'swiftc', 'xcodebuild',
]));

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
  --sandbox-bin ABSOLUTE_EXECUTABLE
  (or, for full host access, replace the last two options with
   --access full [--tunnel-ports PORT[,PORT...]])`;
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
    '--access',
    '--tunnel-ports',
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

  const access = values.get('--access') ?? 'sandboxed';
  if (access !== 'sandboxed' && access !== 'full') {
    fail('INVALID_ARGUMENT', '--access must be sandboxed or full.');
  }
  for (const name of ['--session-dir', '--bind-address', '--launcher-pid', '--real-home']) {
    if (!values.has(name)) {
      fail('INVALID_ARGUMENT', `Missing ${name}.\n${usage()}`);
    }
  }
  for (const name of ['--exec-home', '--sandbox-bin']) {
    if (access === 'sandboxed' && !values.has(name)) {
      fail('INVALID_ARGUMENT', `Missing ${name}.\n${usage()}`);
    }
    // Full access has no sandbox and no isolated home. Refuse the options
    // instead of silently ignoring them so a caller can never believe it is
    // still confined.
    if (access === 'full' && values.has(name)) {
      fail('INVALID_ARGUMENT', `${name} is not used with --access full.`);
    }
  }
  if (access === 'sandboxed' && values.has('--tunnel-ports')) {
    fail('INVALID_ARGUMENT', '--tunnel-ports requires --access full.');
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
    access,
    sessionDirInput: values.get('--session-dir'),
    bindAddress,
    launcherPid,
    realHomeInput: values.get('--real-home'),
    execHomeInput: values.get('--exec-home') ?? null,
    sandboxBinInput: values.get('--sandbox-bin') ?? null,
    tunnelPortsInput: values.get('--tunnel-ports') ?? '',
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

async function manifestFileExists(sessionDir, filename) {
  try {
    const info = await lstat(path.join(sessionDir, filename));
    return info.isFile() && !info.isSymbolicLink();
  } catch {
    return false;
  }
}

function validateCatalogNameList(value, label) {
  if (!Array.isArray(value) || value.length > LIMITS.catalogNameListEntries) {
    fail('INVALID_MANIFEST', `${FILES.catalog} ${label} is not a bounded array.`);
  }
  const names = new Set();
  for (const name of value) {
    if (typeof name !== 'string' || !SAFE_COMMAND_NAME.test(name)) {
      fail('INVALID_MANIFEST', `${FILES.catalog} ${label} contains an unsafe command name.`);
    }
    names.add(name);
  }
  return names;
}

function validateCatalogPathField(value, label) {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value !== 'string' || !path.isAbsolute(value)
    || hasUnsafePathCharacters(value) || value.includes('\t')
    || byteLength(value) > LIMITS.manifestPathBytes) {
    fail('INVALID_MANIFEST', `${FILES.catalog} ${label} must be one absolute path.`);
  }
  return value;
}

async function readCatalogSpecification(sessionDir) {
  const specificationPath = path.join(sessionDir, FILES.catalog);
  let info;
  try {
    info = await lstat(specificationPath);
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    fail('INVALID_MANIFEST', `${FILES.catalog} cannot be inspected.`);
  }
  if (!info.isFile() || info.isSymbolicLink()
    || info.size > LIMITS.catalogSpecificationBytes) {
    fail('INVALID_MANIFEST', `${FILES.catalog} must be a small, non-symlink regular file.`);
  }
  let raw;
  try {
    raw = JSON.parse(await readFile(specificationPath, 'utf8'));
  } catch {
    fail('INVALID_MANIFEST', `${FILES.catalog} is not valid JSON.`);
  }
  const allowedKeys = new Set([
    'v',
    'pathDirectories',
    'deny',
    'first',
    'nodeCommand',
    'nodeExecPath',
    'developerPath',
    'developerRoot',
  ]);
  if (!isPlainObject(raw)
    || Object.keys(raw).some((key) => !allowedKeys.has(key))
    || raw.v !== 1) {
    fail('INVALID_MANIFEST', `${FILES.catalog} is not a supported catalog specification.`);
  }
  if (!Array.isArray(raw.pathDirectories)
    || raw.pathDirectories.length === 0
    || raw.pathDirectories.length > LIMITS.catalogDirectories) {
    fail('INVALID_MANIFEST', `${FILES.catalog} pathDirectories is not a bounded non-empty array.`);
  }
  const pathDirectories = [];
  for (const directory of raw.pathDirectories) {
    if (typeof directory !== 'string' || !path.isAbsolute(directory)
      || hasUnsafePathCharacters(directory) || directory.includes('\t')
      || byteLength(directory) > LIMITS.manifestPathBytes) {
      fail('INVALID_MANIFEST', `${FILES.catalog} pathDirectories contains an unsafe path.`);
    }
    if (!pathDirectories.includes(directory)) pathDirectories.push(directory);
  }
  return Object.freeze({
    pathDirectories: Object.freeze(pathDirectories),
    deny: validateCatalogNameList(raw.deny ?? [], 'deny'),
    first: validateCatalogNameList(raw.first ?? [], 'first'),
    nodeCommand: validateCatalogPathField(raw.nodeCommand, 'nodeCommand'),
    nodeExecPath: validateCatalogPathField(raw.nodeExecPath, 'nodeExecPath'),
    developerPath: validateCatalogPathField(raw.developerPath, 'developerPath'),
    developerRoot: validateCatalogPathField(raw.developerRoot, 'developerRoot'),
  });
}

async function writeGeneratedManifest(sessionDir, filename, content) {
  const destination = path.join(sessionDir, filename);
  const temporaryPath = path.join(
    sessionDir,
    `.${filename}.${process.pid}.${Date.now()}.tmp`,
  );
  const handle = await open(temporaryPath, 'wx', 0o600);
  try {
    await handle.writeFile(content, 'utf8');
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await rename(temporaryPath, destination);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
}

async function usableExecutableFile(candidate) {
  try {
    const info = await stat(candidate);
    if (!info.isFile()) return false;
    await access(candidate, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// Build host-commands.tsv and host-tool-roots.txt from the launcher-frozen
// catalog specification. The walk mirrors the retired shell implementation:
// the first PATH occurrence claims a command name, developer and Node.js
// shims are frozen to their resolved executables, and a symlink whose target
// leaves every declared tool root is skipped rather than poisoning the
// session. Selection here is convenience ordering; the per-command sandbox
// remains the execution boundary.
async function buildCatalogManifests(sessionDir, realHome, execHome, roots, specification) {
  const writableRoots = roots
    .filter((root) => root.mode === 'rw')
    .map((root) => root.path);
  const toolRoots = new Set();

  let nodeRuntimeRoot = null;
  if (specification.nodeExecPath) {
    nodeRuntimeRoot = path.dirname(specification.nodeExecPath);
    if (path.basename(nodeRuntimeRoot) === 'bin') {
      const nodePrefix = path.dirname(nodeRuntimeRoot);
      if (nodePrefix !== '/') nodeRuntimeRoot = nodePrefix;
    }
    if (pathContains(nodeRuntimeRoot, realHome)) {
      nodeRuntimeRoot = path.dirname(specification.nodeExecPath);
    }
    if (nodeRuntimeRoot === '/' || pathContains(nodeRuntimeRoot, realHome)) {
      nodeRuntimeRoot = null;
    }
    if (nodeRuntimeRoot) toolRoots.add(nodeRuntimeRoot);
  }
  if (specification.developerRoot) toolRoots.add(specification.developerRoot);

  const seenNames = new Set();
  const commands = [];
  let droppedByCap = 0;
  for (const directory of specification.pathDirectories) {
    let canonicalDirectory;
    try {
      canonicalDirectory = await realpath(directory);
      if (!(await stat(canonicalDirectory)).isDirectory()) continue;
    } catch {
      continue;
    }
    if (hasUnsafePathCharacters(canonicalDirectory)
      || canonicalDirectory.includes('\t')) {
      continue;
    }

    let directoryRoot = canonicalDirectory;
    for (const managedTree of ['.nvm', '.pyenv']) {
      const managedRoot = path.join(realHome, managedTree);
      if (pathContains(managedRoot, canonicalDirectory)) {
        directoryRoot = managedRoot;
        break;
      }
    }
    if (directoryRoot === canonicalDirectory) {
      if (pathContains('/opt/homebrew', canonicalDirectory)) {
        directoryRoot = '/opt/homebrew';
      } else if (pathContains('/usr/local', canonicalDirectory)) {
        directoryRoot = '/usr/local';
      }
    }
    // A root the manifest loader would reject (/ or an ancestor of the real
    // home) must not fail the whole channel; skip only that directory.
    if (directoryRoot === '/' || pathContains(directoryRoot, realHome)) {
      process.stderr.write(`host-exec-broker: skipping unusable PATH directory ${canonicalDirectory}\n`);
      continue;
    }
    toolRoots.add(directoryRoot);

    let entryNames;
    try {
      entryNames = (await readdir(canonicalDirectory)).sort();
    } catch {
      continue;
    }
    for (const entryName of entryNames) {
      if (!SAFE_COMMAND_NAME.test(entryName)
        || entryName === '.' || entryName === '..') {
        continue;
      }
      if (seenNames.has(entryName)) continue;
      if (specification.deny.has(entryName)) continue;
      const candidate = path.join(canonicalDirectory, entryName);
      // Claim the name only once this occurrence is a usable executable, like
      // normal PATH lookup and the retired shell walk: a plain file earlier in
      // PATH must not suppress a real command of the same name later in PATH.
      if (!(await usableExecutableFile(candidate))) continue;
      seenNames.add(entryName);

      let executable = candidate;
      if (entryName === 'node' && specification.nodeExecPath) {
        let resolvedCandidate = null;
        try {
          resolvedCandidate = await realpath(candidate);
        } catch {
          resolvedCandidate = null;
        }
        if (resolvedCandidate === specification.nodeCommand
          || resolvedCandidate === specification.nodeExecPath) {
          executable = specification.nodeExecPath;
        }
      }
      if (DEVELOPER_SHIM_COMMANDS.has(entryName)
        && candidate === `/usr/bin/${entryName}`
        && specification.developerPath) {
        for (const developerCandidate of [
          path.join(specification.developerPath, 'usr', 'bin', entryName),
          path.join(
            specification.developerPath,
            'Toolchains', 'XcodeDefault.xctoolchain', 'usr', 'bin',
            entryName,
          ),
        ]) {
          if (!(await usableExecutableFile(developerCandidate))) continue;
          if (specification.developerRoot
            && pathContains(specification.developerRoot, developerCandidate)) {
            executable = developerCandidate;
          }
          break;
        }
      }

      let canonicalExecutable;
      try {
        canonicalExecutable = await realpath(executable);
      } catch {
        continue;
      }
      if (hasUnsafePathCharacters(canonicalExecutable)
        || canonicalExecutable.includes('\t')
        || !(await usableExecutableFile(canonicalExecutable))) {
        continue;
      }
      const containingRoots = [
        directoryRoot,
        nodeRuntimeRoot,
        specification.developerRoot,
        ...SYSTEM_EXEC_ROOTS,
      ].filter(Boolean);
      if (!containingRoots.some((root) => pathContains(root, canonicalExecutable))) {
        continue;
      }
      if (writableRoots.some((root) => pathContains(root, canonicalExecutable))
        || pathContains(execHome, canonicalExecutable)) {
        continue;
      }
      if (commands.length >= LIMITS.commandManifestLines) {
        droppedByCap += 1;
        continue;
      }
      commands.push({
        mode: specification.first.has(entryName) ? 'first' : 'fallback',
        name: entryName,
        executable: canonicalExecutable,
      });
    }
  }
  if (droppedByCap > 0) {
    process.stderr.write(`host-exec-broker: command catalog reached its ${LIMITS.commandManifestLines}-entry bound; ${droppedByCap} later PATH commands were dropped\n`);
  }
  if (commands.length === 0) {
    fail('INVALID_MANIFEST', 'No host command could be cataloged from the staged PATH directories.');
  }

  const commandLines = commands
    .map((command) => `${command.mode}\t${command.name}\t${command.executable}\n`)
    .join('');
  if (byteLength(commandLines) > LIMITS.commandManifestBytes) {
    fail('INVALID_MANIFEST', 'The generated host command manifest is too large.');
  }
  const toolRootLines = [...toolRoots].sort().map((root) => `${root}\n`).join('');
  await writeGeneratedManifest(sessionDir, FILES.toolRoots, toolRootLines);
  await writeGeneratedManifest(sessionDir, FILES.commands, commandLines);
}

async function readSessionToken(sessionDir) {
  const tokenText = await readTrustedManifest(sessionDir, FILES.token, { maxBytes: 1024 });
  const token = tokenText.endsWith('\n') ? tokenText.slice(0, -1) : tokenText;
  if (!TOKEN_PATTERN.test(token) || tokenText !== `${token}\n`) {
    fail('INVALID_MANIFEST', `${FILES.token} must contain exactly one lowercase 64-hex token and a newline.`);
  }
  return token;
}

function parseTunnelPorts(value) {
  if (value === '') return [];
  const ports = [];
  for (const text of value.split(',')) {
    if (!/^[1-9][0-9]{0,4}$/.test(text) || Number(text) > 65535) {
      fail('INVALID_ARGUMENT', '--tunnel-ports must be a comma-separated list of TCP ports from 1 to 65535.');
    }
    const port = Number(text);
    if (!ports.includes(port)) ports.push(port);
  }
  if (ports.length > LIMITS.tunnelPorts) {
    fail('INVALID_ARGUMENT', `--tunnel-ports accepts at most ${LIMITS.tunnelPorts} ports.`);
  }
  return ports;
}

// Full access mode: the catalog is simply "what a terminal would find". The
// first PATH occurrence of a name claims it, exactly like lookup, and the
// entry keeps its PATH location (not the symlink target) so multi-call
// binaries still see the name they were invoked as. No tool-root containment
// and no Agent-writable exclusion apply, because nothing is sandboxed and the
// Agent can already write anywhere the account can.
async function buildUnrestrictedCommands(specification) {
  const commands = new Map();
  let droppedByCap = 0;
  for (const directory of specification.pathDirectories) {
    let canonicalPathDirectory;
    try {
      canonicalPathDirectory = await realpath(directory);
      if (!(await stat(canonicalPathDirectory)).isDirectory()) continue;
    } catch {
      continue;
    }
    if (hasUnsafePathCharacters(canonicalPathDirectory)) continue;
    let entryNames;
    try {
      entryNames = (await readdir(canonicalPathDirectory)).sort();
    } catch {
      continue;
    }
    for (const entryName of entryNames) {
      if (!SAFE_COMMAND_NAME.test(entryName)) continue;
      if (commands.has(entryName) || specification.deny.has(entryName)) continue;
      const candidate = path.join(canonicalPathDirectory, entryName);
      if (!(await usableExecutableFile(candidate))) continue;
      if (commands.size >= LIMITS.commandManifestLines) {
        droppedByCap += 1;
        continue;
      }
      commands.set(entryName, Object.freeze({
        mode: specification.first.has(entryName) ? 'first' : 'fallback',
        name: entryName,
        executable: candidate,
      }));
    }
  }
  if (droppedByCap > 0) {
    process.stderr.write(`host-exec-broker: command catalog reached its ${LIMITS.commandManifestLines}-entry bound; ${droppedByCap} later PATH commands were dropped\n`);
  }
  return commands;
}

async function loadFullConfiguration(argumentsValue) {
  const sessionDir = await canonicalDirectory(argumentsValue.sessionDirInput, '--session-dir');
  const realHome = await canonicalDirectory(argumentsValue.realHomeInput, '--real-home');
  const token = await readSessionToken(sessionDir);
  const specification = await readCatalogSpecification(sessionDir);
  if (specification === null) {
    fail('INVALID_MANIFEST', `${FILES.catalog} is missing.`);
  }
  const commands = await buildUnrestrictedCommands(specification);
  if (commands.size === 0) {
    fail('INVALID_MANIFEST', 'No host command could be cataloged from the staged PATH directories.');
  }
  return Object.freeze({
    ...argumentsValue,
    sessionDir,
    realHome,
    token,
    tokenBuffer: Buffer.from(token, 'ascii'),
    commands,
    tunnelPorts: Object.freeze(parseTunnelPorts(argumentsValue.tunnelPortsInput)),
    // Mutable on purpose: the tunnel listener publishes its port after bind.
    runtime: { tunnelPort: 0 },
  });
}

async function loadConfiguration(argumentsValue) {
  const sessionDir = await canonicalDirectory(argumentsValue.sessionDirInput, '--session-dir');
  const realHome = await canonicalDirectory(argumentsValue.realHomeInput, '--real-home');
  const execHome = await canonicalDirectory(argumentsValue.execHomeInput, '--exec-home');
  if (realHome === execHome || !pathContains(realHome, execHome)) {
    fail('UNSAFE_PATH', '--exec-home must be a narrower directory below --real-home.');
  }
  const sandboxBin = await canonicalExecutable(argumentsValue.sandboxBinInput, '--sandbox-bin');

  const token = await readSessionToken(sessionDir);

  const rootText = await readTrustedManifest(sessionDir, FILES.roots);
  const roots = await parseCanonicalRootLines(rootText, FILES.roots, realHome, execHome, true);
  if (roots.length === 0) {
    fail('INVALID_MANIFEST', `${FILES.roots} must declare at least one execution root.`);
  }
  validateRootRelationships(roots);

  // A launcher may stage the complete command manifest directly, or stage a
  // catalog specification for this broker to expand. Generated manifests are
  // re-read through the exact same validation path as staged ones.
  if (!(await manifestFileExists(sessionDir, FILES.commands))) {
    const specification = await readCatalogSpecification(sessionDir);
    if (specification === null) {
      fail('INVALID_MANIFEST', `${FILES.commands} and ${FILES.catalog} are both missing.`);
    }
    await buildCatalogManifests(sessionDir, realHome, execHome, roots, specification);
  }

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

function verifySessionToken(token, configuration) {
  if (typeof token !== 'string' || !TOKEN_PATTERN.test(token)) {
    fail('AUTH_FAILED', 'Authentication failed.');
  }
  const suppliedToken = Buffer.from(token, 'ascii');
  if (suppliedToken.length !== configuration.tokenBuffer.length
    || !timingSafeEqual(suppliedToken, configuration.tokenBuffer)) {
    fail('AUTH_FAILED', 'Authentication failed.');
  }
}

function validateRequest(request, configuration) {
  if (!isPlainObject(request)
    || Object.keys(request).some((key) => !ALLOWED_REQUEST_KEYS.has(key))
    || request.v !== 1
    || request.type !== 'run') {
    fail('INVALID_REQUEST', 'The first frame is not a supported run request.');
  }

  verifySessionToken(request.token, configuration);

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

  const fullAccess = configuration.access === 'full';
  const envLimit = fullAccess ? LIMITS.fullEnvCount : LIMITS.envCount;
  if (!isPlainObject(request.env) || Object.keys(request.env).length > envLimit) {
    fail('INVALID_REQUEST', 'env is not a bounded object.');
  }
  let envBytes = 0;
  const forwardedEnvironment = {};
  for (const [name, value] of Object.entries(request.env)) {
    if (fullAccess) {
      if (!SAFE_ENV_NAME.test(name) || byteLength(name) > LIMITS.envNameBytes
        || typeof value !== 'string' || value.includes('\0')
        || byteLength(value) > LIMITS.envValueBytes) {
        fail('INVALID_REQUEST', 'env contains an invalid or oversized entry.');
      }
      // Guest identity and path variables are dropped, not rejected.
      if (FULL_RESERVED_ENV_PATTERN.test(name)) continue;
    } else if (!isForwardableEnvironmentName(name) || typeof value !== 'string'
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

  // GitHub credentials belong to the macOS operator. The gh sandbox exposes
  // the real GitHub/Git configuration read-only, so these configuration-
  // changing auth operations cannot complete reliably. Reject them after the
  // complete protocol shape is validated but before spawn.
  const ghAuthMutation = !fullAccess
    && command.name === 'gh'
    && request.argv[0] === 'auth'
    && ['login', 'logout', 'refresh', 'setup-git'].includes(request.argv[1]);
  if (ghAuthMutation) {
    fail(
      'HOST_SETUP_REQUIRED',
      `The 'gh auth ${request.argv[1]}' operation needs writable host configuration. Re-run the original command, including its hostname and options, in a normal macOS terminal.`,
    );
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
    fail(
      'CWD_DENIED',
      `cwd ${JSON.stringify(cwdInput)} cannot be resolved on the macOS host. It may be guest-only, removed, inaccessible, or outside the transported workspace.`,
    );
  }
  const allowed = pathContains(configuration.execHome, cwd)
    || configuration.roots.some((root) => pathContains(root.path, cwd));
  if (!allowed) {
    const visibleRoots = configuration.roots
      .slice(0, 4)
      .map((root) => JSON.stringify(root.path))
      .join(', ');
    const remainingRoots = configuration.roots.length > 4
      ? `, plus ${configuration.roots.length - 4} more`
      : '';
    fail(
      'CWD_DENIED',
      `cwd ${JSON.stringify(cwd)} is outside the declared execution roots (${visibleRoots}${remainingRoots}). Start a new invocation whose explicit scope contains it (default singleton: --container-workspace-root; legacy run: --share-ro/--share-rw).`,
    );
  }
  return cwd;
}

// Full access mode has no execution roots. A guest cwd below the /host mount
// is the same directory as the host path without that prefix; any other path
// is tried as given. A directory that exists only inside the guest (for
// example /tmp/scratch) must not make `adb devices` or `xcrun simctl list`
// fail, so the command runs in the real HOME and says so on stderr instead of
// silently guessing: relative arguments are the only thing that can differ.
async function resolveFullCwd(cwdInput, configuration) {
  const candidates = [];
  if (cwdInput === GUEST_HOST_ROOT || cwdInput.startsWith(`${GUEST_HOST_ROOT}/`)) {
    candidates.push(cwdInput.slice(GUEST_HOST_ROOT.length) || '/');
  }
  candidates.push(cwdInput);
  for (const candidate of candidates) {
    try {
      const resolved = await realpath(candidate);
      if ((await stat(resolved)).isDirectory()) return { cwd: resolved, note: null };
    } catch {
      // Try the next candidate.
    }
  }
  return {
    cwd: configuration.realHome,
    note: `host-exec: note: ${JSON.stringify(cwdInput)} does not exist on the macOS host; running in ${JSON.stringify(configuration.realHome)} instead.\n`,
  };
}

// A catalog request answers with the enabled command names and their guest
// PATH mode, then ends the connection. Guest session helpers use it to build
// local shims; command executable paths stay host-side. A full-access broker
// additionally reports its access level and loopback tunnel endpoint so the
// guest never has to be told out of band.
function handleCatalogRequest(context, request, configuration) {
  const allowedKeys = new Set(['v', 'type', 'token']);
  if (!isPlainObject(request)
    || Object.keys(request).some((key) => !allowedKeys.has(key))
    || request.v !== 1) {
    fail('INVALID_REQUEST', 'The first frame is not a supported catalog request.');
  }
  verifySessionToken(request.token, configuration);
  const commands = [...configuration.commands.values()]
    .map((command) => ({ name: command.name, mode: command.mode }));
  const response = { type: 'catalog', commands };
  if (configuration.access === 'full') {
    response.access = 'full';
    if (configuration.runtime.tunnelPort > 0) {
      response.tunnel = {
        port: configuration.runtime.tunnelPort,
        ports: [...configuration.tunnelPorts],
      };
    }
  }
  if (enterTerminalState(context)) {
    sendFrame(context.socket, response);
    closeSocketSoon(context.socket);
  }
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
  if (command.name === 'git') {
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
  if (command.name === 'gh') {
    // The GitHub CLI reads its host list and, when insecure storage was
    // selected, its token from ~/.config/gh. The directory stays read-only:
    // update-state writes fail harmlessly and the broker never widens
    // real-home write access for a guest-driven command.
    const ghConfig = path.join(configuration.realHome, '.config', 'gh');
    return [
      baseProfile,
      sandboxPathRules('file-read* file-test-existence', [ghConfig]),
      sandboxAncestorRules([ghConfig]),
    ].join('');
  }
  return baseProfile;
}

function buildChildEnvironment(configuration, command, forwardedEnvironment) {
  // Host git and gh operate with the operator's real identity and
  // credentials; every other allowed command keeps the isolated home.
  const commandHome = ['git', 'gh'].includes(command.name)
    ? configuration.realHome
    : configuration.execHome;
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
  // broker environment, never from a guest request, and reaches exactly the
  // identity commands that already run with the real HOME. Generic cataloged
  // commands keep an agent-free environment so a guest-driven interpreter
  // cannot borrow the operator's signing authority.
  if (commandHome === configuration.realHome
    && typeof process.env.SSH_AUTH_SOCK === 'string'
    && path.isAbsolute(process.env.SSH_AUTH_SOCK)
    && !hasUnsafePathCharacters(process.env.SSH_AUTH_SOCK)) {
    environment.SSH_AUTH_SOCK = process.env.SSH_AUTH_SOCK;
  }
  Object.assign(environment, forwardedEnvironment);
  return environment;
}

// Full access environment: the broker's own inherited environment is the
// user's terminal environment as the launcher saw it (launcher-internal names
// removed, SSH_AUTH_SOCK present only when the launcher chose to keep it), the
// real HOME replaces any isolated one, and the guest request layers its own
// non-reserved variables on top (locale, TERM, ANDROID_SERIAL, ...).
function buildUnrestrictedEnvironment(configuration, forwardedEnvironment, cwd) {
  const environment = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (typeof value !== 'string' || value.includes('\0')) continue;
    if (LAUNCHER_INTERNAL_ENV_PATTERN.test(name)) continue;
    environment[name] = value;
  }
  environment.HOME = configuration.realHome;
  environment.PWD = cwd;
  if (!environment.PATH) environment.PATH = '/usr/bin:/bin:/usr/sbin:/sbin';
  if (!environment.SHELL) environment.SHELL = '/bin/zsh';
  environment.AGENT_CONTAINER_HOST_EXEC = '1';
  environment.AGENT_HOST_ACCESS = 'full';
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

// Error and catalog replies are one small frame: close promptly so a peer
// that never closes its half cannot hold a connection slot.
//
// After an exit frame (`patient`), megabytes of command output may still be
// queued for a slow guest. Destroying the socket then would discard Node's
// unsent buffer, and closing it while late input (a stdin_end frame racing
// the exit frame) sits unread makes the kernel answer with a reset that also
// discards the output already in flight. So late input is read and ignored,
// the write side is ended, and the socket is destroyed only once the guest
// closes its side or the queued output has stopped draining for a while.
function closeSocketSoon(socket, { patient = false } = {}) {
  if (socket.destroyed) return;
  if (patient) {
    socket.resume();
    socket.end();
    let lastPending = Number.POSITIVE_INFINITY;
    const watchdog = setInterval(() => {
      const pending = socket.writableLength;
      if (pending > 0 && pending < lastPending) {
        lastPending = pending;
        return;
      }
      socket.destroy();
    }, LIMITS.closeStallMs);
    watchdog.unref();
    socket.once('close', () => clearInterval(watchdog));
    return;
  }
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

function attachOutputStream(stream, socket, type, context) {
  // A pipe read error ends this stream; it must not crash the broker.
  stream.on('error', () => {});
  stream.on('data', (chunk) => {
    const writable = sendFrame(socket, { type, data: chunk.toString('base64') });
    // After a full-access leader exits, output that is still flowing keeps the
    // drain window open; only a silent pipe is cut loose.
    if (context.exited) armDrainTimer(context);
    if (!writable && !socket.destroyed) {
      stream.pause();
      socket.once('drain', () => stream.resume());
    }
  });
}

// Full access only. A command may legitimately leave a daemon behind (adb's
// server, an emulator started with `&`). That daemon can still hold this
// command's stdout/stderr, in which case 'close' would never fire and the
// guest would hang for as long as the daemon lives. Once the leader has
// exited, wait for the pipes to go quiet and then stop reading them.
// A pipe this broker paused for backpressure is not quiet: the guest simply
// has not consumed its output yet, and bytes still queued in the OS pipe
// would be lost by destroying it. While the guest socket is alive the timer
// therefore re-arms; once it is gone nothing can consume the output anyway.
function armDrainTimer(context) {
  if (context.drainTimer) clearTimeout(context.drainTimer);
  context.drainTimer = setTimeout(() => {
    context.drainTimer = undefined;
    const { stdout, stderr } = context.child ?? {};
    if (!context.socket.destroyed && (stdout?.isPaused() || stderr?.isPaused())) {
      armDrainTimer(context);
      return;
    }
    stdout?.destroy();
    stderr?.destroy();
  }, LIMITS.exitDrainMs);
}

async function spawnRequest(context, validated, configuration, activeContexts) {
  if (activeContexts.size >= LIMITS.activeCommands) {
    fail('BUSY', 'This host executor has reached its active-command limit.');
  }
  // Reserve the slot before the asynchronous cwd lookup. Without this, a
  // burst of requests can all observe the same pre-spawn count and exceed the
  // advertised per-session concurrency bound.
  activeContexts.add(context);
  const fullAccess = configuration.access === 'full';
  let cwd;
  let cwdNote = null;
  try {
    if (fullAccess) {
      ({ cwd, note: cwdNote } = await resolveFullCwd(validated.request.cwd, configuration));
    } else {
      cwd = await resolveRequestCwd(validated.request.cwd, configuration);
    }
  } catch (error) {
    activeContexts.delete(context);
    throw error;
  }
  if (context.terminal || context.socket.destroyed) {
    activeContexts.delete(context);
    return;
  }

  let spawnFile;
  let spawnArguments;
  let childEnvironment;
  const spawnExtras = {};
  if (fullAccess) {
    // No sandbox: run the cataloged executable directly, as a terminal would,
    // with argv[0] set to the name the guest typed.
    spawnFile = validated.command.executable;
    spawnArguments = validated.request.argv;
    spawnExtras.argv0 = validated.command.name;
    childEnvironment = buildUnrestrictedEnvironment(
      configuration,
      validated.forwardedEnvironment,
      cwd,
    );
  } else {
    const profile = buildCommandSandboxProfile(configuration, validated.command);
    if (byteLength(profile) > LIMITS.sandboxProfileBytes) {
      activeContexts.delete(context);
      fail('INVALID_MANIFEST', 'The generated command sandbox profile is too large.');
    }
    childEnvironment = buildChildEnvironment(
      configuration,
      validated.command,
      validated.forwardedEnvironment,
    );
    spawnFile = configuration.sandboxBin;
    spawnArguments = ['-p', profile, validated.command.executable, ...validated.request.argv];
  }
  let child;
  try {
    child = spawn(
      spawnFile,
      spawnArguments,
      {
        cwd,
        env: childEnvironment,
        detached: true,
        stdio: ['pipe', 'pipe', 'pipe'],
        ...spawnExtras,
      },
    );
  } catch (error) {
    activeContexts.delete(context);
    throw error;
  }
  context.child = child;
  context.phase = 'running';
  context.stdinExpected = validated.request.stdin;

  // A command may stop reading stdin long before the guest stops sending it
  // (`yes | host-command head -1`). The next write then fails with EPIPE; that
  // must only discard the rest of the input, never reach the process-wide
  // uncaught-exception handler that shuts the whole broker down.
  child.stdin.on('error', () => {
    context.stdinBroken = true;
    if (context.inputPaused && !context.terminal) {
      // A 'drain' that will never come was holding further frames back.
      context.inputPaused = false;
      context.socket.resume();
      try {
        processBufferedLines(context, configuration, activeContexts);
      } catch (error) {
        failContext(context, error);
      }
    }
  });

  attachOutputStream(child.stdout, context.socket, 'stdout', context);
  attachOutputStream(child.stderr, context.socket, 'stderr', context);

  child.once('spawn', () => {
    context.authTimer && clearTimeout(context.authTimer);
    context.authTimer = undefined;
    if (cwdNote) {
      sendFrame(context.socket, {
        type: 'stderr',
        data: Buffer.from(cwdNote, 'utf8').toString('base64'),
      });
    }
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

  if (fullAccess) {
    child.once('exit', () => {
      context.exited = true;
      armDrainTimer(context);
    });
  }

  child.once('close', (code, signal) => {
    activeContexts.delete(context);
    if (context.drainTimer) clearTimeout(context.drainTimer);
    context.drainTimer = undefined;
    if (!fullAccess) {
      // End every background descendant that remains in this request's process
      // group whenever its leader exits. Deliberate setsid-style daemonization is
      // outside the protocol contract and cannot be contained by a PGID alone.
      // Full access deliberately skips this: a command that finished normally
      // may have started a service, and stopping it is the Agent's decision.
      killProcessGroup(context, 'SIGTERM');
      if (!context.killTimer) {
        context.killTimer = setTimeout(
          () => killProcessGroup(context, 'SIGKILL'),
          LIMITS.terminateGraceMs,
        );
        context.killTimer.unref();
      }
    }
    const status = Number.isInteger(code) ? Math.max(0, Math.min(255, code)) : signalExitStatus(signal);
    if (enterTerminalState(context)) {
      sendFrame(context.socket, {
        type: 'exit',
        code: Number.isInteger(code) ? code : null,
        signal: signal || null,
        status,
      });
      closeSocketSoon(context.socket, { patient: true });
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
      if (isPlainObject(frame) && frame.type === 'catalog') {
        handleCatalogRequest(context, frame, configuration);
        continue;
      }
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
      // The command already closed its stdin; the frame was validated and is
      // dropped like any input a process never reads.
      if (context.stdinBroken || context.child.stdin.destroyed) continue;
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
      if (!context.stdinBroken && !context.child.stdin.destroyed) context.child.stdin.end();
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

// Loopback tunnel (full access only). The listener shares the broker's
// host-only address but not its framing: after one authentication line the
// connection is an unmodified byte stream, so it is read as raw Buffers and
// never decoded as text. The port allowlist comes from the launcher, the token
// is the same 256-bit session token, and a failed attempt gets no reply at all.
function verifyTunnelAuthentication(line, configuration) {
  const match = TUNNEL_AUTH_PATTERN.exec(line);
  if (!match) return null;
  const supplied = Buffer.from(match[1], 'ascii');
  if (supplied.length !== configuration.tokenBuffer.length
    || !timingSafeEqual(supplied, configuration.tokenBuffer)) {
    return null;
  }
  const port = Number(match[2]);
  return configuration.tunnelPorts.includes(port) ? port : null;
}

// Resolves with a connected loopback socket. Some services listen on the IPv6
// loopback only, so an IPv4 refusal is retried once on ::1; no other address
// is ever tried, which keeps the allowlisted port a loopback-only capability.
function connectLoopback(port) {
  const hosts = ['127.0.0.1', '::1'];
  return new Promise((resolve, reject) => {
    const attempt = (index) => {
      const candidate = net.connect({ host: hosts[index], port, allowHalfOpen: true });
      const timer = setTimeout(
        () => candidate.destroy(new Error('connect timeout')),
        LIMITS.tunnelConnectMs,
      );
      candidate.once('connect', () => {
        clearTimeout(timer);
        candidate.removeAllListeners('error');
        resolve(candidate);
      });
      candidate.once('error', (error) => {
        clearTimeout(timer);
        candidate.destroy();
        if (index + 1 < hosts.length && error?.code === 'ECONNREFUSED') {
          attempt(index + 1);
        } else {
          reject(error);
        }
      });
    };
    attempt(0);
  });
}

// The guest socket stays paused until the upstream exists, so no byte that
// follows the authentication line can be lost or reordered.
//
// Teardown is graceful in both directions: when one side finishes cleanly,
// the other side is ended rather than destroyed, so bytes still queued for a
// slow reader (a service's final burst before it closes, or a request the
// guest sent just before closing) are delivered, under the same stall
// watchdog the command channel uses. Only an error destroys both sides.
async function relayTunnel(socket, port, remainder, tunnelSockets) {
  let upstream;
  const destroyBoth = () => {
    socket.destroy();
    upstream?.destroy();
  };
  socket.on('error', destroyBoth);
  try {
    upstream = await connectLoopback(port);
  } catch {
    socket.destroy();
    return;
  }
  if (socket.destroyed) {
    upstream.destroy();
    return;
  }
  tunnelSockets.add(upstream);
  upstream.on('error', destroyBoth);
  upstream.once('close', (hadError) => {
    tunnelSockets.delete(upstream);
    if (hadError) destroyBoth();
    else closeSocketSoon(socket, { patient: true });
  });
  socket.once('close', (hadError) => {
    if (hadError) destroyBoth();
    else closeSocketSoon(upstream, { patient: true });
  });
  upstream.setNoDelay(true);
  if (remainder.length > 0) upstream.write(remainder);
  socket.pipe(upstream);
  upstream.pipe(socket);
}

function startTunnelServer(configuration, tunnelSockets) {
  const server = net.createServer({ allowHalfOpen: true, pauseOnConnect: true }, (socket) => {
    if (tunnelSockets.size >= LIMITS.tunnelConnections) {
      socket.destroy();
      return;
    }
    tunnelSockets.add(socket);
    socket.once('close', () => tunnelSockets.delete(socket));
    socket.on('error', () => socket.destroy());
    socket.setNoDelay(true);

    let pending = Buffer.alloc(0);
    const authTimer = setTimeout(() => socket.destroy(), LIMITS.tunnelAuthMs);
    const onData = (chunk) => {
      pending = Buffer.concat([pending, chunk]);
      const newline = pending.indexOf(0x0a);
      if (newline === -1) {
        if (pending.length > LIMITS.tunnelAuthBytes) socket.destroy();
        return;
      }
      socket.off('data', onData);
      socket.pause();
      clearTimeout(authTimer);
      const port = newline <= LIMITS.tunnelAuthBytes
        ? verifyTunnelAuthentication(pending.subarray(0, newline).toString('latin1'), configuration)
        : null;
      if (port === null) {
        socket.destroy();
        return;
      }
      void relayTunnel(socket, port, pending.subarray(newline + 1), tunnelSockets);
    };
    socket.on('data', onData);
    socket.resume();
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen({ host: configuration.bindAddress, port: 0, exclusive: true }, () => {
      server.off('error', reject);
      resolve(server);
    });
  });
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
  const fullAccess = argumentsValue.access === 'full';
  const configuration = fullAccess
    ? await loadFullConfiguration(argumentsValue)
    : await loadConfiguration(argumentsValue);
  if (!fullAccess) {
    const sandboxProfile = buildSandboxProfile(configuration);
    if (byteLength(sandboxProfile) > LIMITS.sandboxProfileBytes) {
      fail('INVALID_MANIFEST', 'The generated sandbox profile is too large.');
    }
  } else {
    process.stderr.write('host-exec-broker: FULL HOST ACCESS: commands run as this user without a sandbox\n');
  }

  const activeContexts = new Set();
  const sockets = new Set();
  const tunnelSockets = new Set();
  let tunnelServer;
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
      stdinBroken: false,
      stdinBytes: 0,
      inputPaused: false,
      completed: false,
      killTimer: undefined,
      authTimer: undefined,
      terminal: false,
      // Full access only: leader exit tracking for the output drain window.
      exited: false,
      drainTimer: undefined,
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
    if (tunnelServer) tunnelServer.close();
    for (const tunnelSocket of tunnelSockets) tunnelSocket.destroy();
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
  // The tunnel is a secondary capability: if it cannot start, the command
  // channel still works and the catalog simply omits it.
  if (fullAccess && configuration.tunnelPorts.length > 0) {
    try {
      tunnelServer = await startTunnelServer(configuration, tunnelSockets);
      configuration.runtime.tunnelPort = tunnelServer.address().port;
    } catch (error) {
      tunnelServer = undefined;
      process.stderr.write(`host-exec-broker: loopback tunnel unavailable: ${error.message}\n`);
    }
  }
  endpointPath = await writeEndpoint(configuration, address.address, address.port);

  // This is the only structured readiness output. Launchers may wait for either
  // this line or the atomically published endpoint file.
  const ready = {
    type: 'ready',
    address: address.address,
    port: address.port,
    endpoint: `${address.address}:${address.port}`,
  };
  if (fullAccess) {
    ready.access = 'full';
    ready.tunnelPort = configuration.runtime.tunnelPort;
  }
  process.stdout.write(`${JSON.stringify(ready)}\n`);

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

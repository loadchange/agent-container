# Performance expectations and benchmark protocol

## No unconditional speed claim

The default runtime keeps one Apple Micro-VM alive per profile and host UID.
After the first launch, a new terminal avoids VM creation and uses
`container exec`. That removes an important warm-start cost compared with a
per-invocation VM, but it does not make the complete workflow equivalent to a
native macOS process.

Every warm client still performs host validation, publisher-channel resolution
when using a floating version, one workspace-broker startup, TCP
authentication, private mount-namespace setup, SSHFS readiness, and Agent
initialization. Project I/O crosses raw SFTP/FUSE. Metadata-heavy operations can
therefore be slower than APFS and can have different caching and watcher
semantics.

Online Agent tasks are frequently dominated by provider and model latency. A
single prompt cannot establish container performance.

## Costs to report separately

Measure these phases independently:

1. **Channel resolution**: host HTTPS request, CA handling, and strict parsing
   of the current publisher release.
2. **Cold image build**: base pull, Debian packages, official installer,
   artifact download, and image construction.
3. **Cold singleton creation**: image verification, stopped-container creation
   and inspection, detached VM start, and ready publication.
4. **Warm client attach**: native/state validation through the first successful
   `container exec` setup.
5. **Workspace mount**: broker publication, authenticated connection, SSHFS
   process startup, and mount readiness.
6. **Agent startup**: profile executable initialization before model traffic.
7. **Workspace workload**: file enumeration, Git, builds, tests, and writes over
   SFTP/SSHFS.
8. **Online task**: time to first provider event and total task time, with API
   retries/rate limits reported.
9. **Client cleanup**: Agent-tree cgroup reaches `populated 0`, SSHFS unmounts,
   the broker exits, and no stale mount/exec remains.
10. **Singleton stop/recreate**: explicit container stop and next cold start,
    reported separately from routine client exit.

Do not average a cold build into a warm attach number. Do not count a persistent
VM as leaked merely because the client ended; persistence is the normal design.
Instead verify that the expected named singleton remains and that per-client
broker, SSHFS, and staging resources disappear.

## Test matrix

Use the same machine, power mode, repository revision, exact Agent version,
terminal mode, CPU/memory policy, and explicit proxy/DNS `--container-*`
options. Keep the exact `--container-forward-env` name set and its exported
model/provider values fixed as well. Close unrelated high-I/O programs.
Alternate native and container order to reduce thermal and cache bias.

For each case, run one discarded warmup and at least 20 measured samples. Report
sample count, median (`p50`), `p95`, minimum, maximum, and failures. Retain raw
samples.

Test at least these states:

| State | Required condition |
|---|---|
| Native | Same exact Agent release installed on macOS |
| Cold build | Matching profile image absent or a forced rebuild requested |
| Cold singleton | Matching image warm, profile singleton stopped |
| Warm singleton | Matching singleton already running, no other client |
| Concurrent attach | Two terminals enter two different repositories in the same profile |
| Repeated root switch | Alternate A/B/A/B without stopping the singleton |
| Owner death recovery | One active client whose host launcher is sent `SIGKILL` while another client remains active |
| Legacy `run` | Profile singleton stopped; short-lived Apple-volume path selected explicitly |

Use a leading exact-version option to remove channel traffic when isolating
runtime overhead:

```bash
agent-container singleton stop codex
codex-container --container-version 0.146.0 --version
```

Do not mix exact-version samples with floating-channel samples. A cold exact
build still needs network access.

## 1. Native versus warm process startup

Compare the same release and a trivial native probe:

```bash
/usr/bin/time -p claude --version
/usr/bin/time -p claude-container --container-version 1.2.3 --version

/usr/bin/time -p codex --version
/usr/bin/time -p codex-container --container-version 0.146.0 --version
```

Replace example versions with real matching releases. Confirm the singleton is
already running before recording warm samples. Report the first client after
`singleton stop` separately.

A `--version` probe measures launcher, mount, and process setup; it does not
exercise a repository scan or model network request.

## 2. Workspace transport

Run identical commands in the same checkout natively and through the Agent
environment or a deterministic guest command path:

1. `git status --porcelain=v1`;
2. `rg --files`, including output count;
3. a recursive stat/file-enumeration workload;
4. a representative read-heavy build or test;
5. a representative write-heavy task to disposable files;
6. rename and delete cycles;
7. host edit followed by guest read;
8. guest edit followed by host read.

Record repository file count, total bytes, average file size, nesting depth,
Git status size, and tool versions. SSHFS caches attributes and directory
entries briefly, so test both cold and warm caches. Never compare workloads
whose host and guest toolchains differ materially without disclosing it.

File watchers need a separate result. Test the actual framework's watch mode
with host-side and guest-side edits. A successful ordinary read does not imply
that FSEvents/inotify-style notifications cross SFTP/FUSE correctly. If polling
or restart is required, report it as a functional limitation rather than a
latency number.

## 3. Multi-project concurrency

The central default-path benchmark is one VM with independent clients:

```bash
# Terminal A
cd /path/A && codex-container

# Terminal B
cd /path/B && codex-container
```

Measure:

- time for A when no other client is active;
- time for B while A is active;
- aggregate read/write throughput while both are busy;
- CPU and memory contention inside the fixed VM allocation;
- whether each process starts in its exact cwd;
- whether A's normal mount view omits B and vice versa;
- whether both clients' changes are immediately visible on their respective
  hosts;
- whether ending A leaves B healthy;
- whether both per-client brokers and mounts disappear after exit.

Also send `SIGKILL` to A's host launcher while its workspace connection is
active. Verify that A's broker and TCP stream close, its guest connector and
SSHFS exit, its complete Agent cgroup disappears, and its mount/session state
is removed. B and the profile singleton must remain healthy throughout.

Because the VM and profile HOME are shared, this is a concurrency and
correctness test, not a claim of hostile-project isolation.

## 4. Fixed Agent task

Use a deterministic non-interactive prompt, exact Agent release, fixed model,
and unchanged repository state. Record separately:

- time until the Agent is ready;
- time to first model event/token;
- provider response time and retry count;
- tool-call time inside the workspace;
- total elapsed time;
- response-cache state when the provider exposes it.

Repeat enough times to expose provider variance. Attribute only the measured
mount/tool portion to the container runtime.

## 5. Host resources and safety

For cold creation, warm clients, concurrent clients, and cleanup, record:

- host RSS, CPU, and energy impact of Apple VM helpers, launcher, broker, and
  SSHFS;
- guest memory pressure under the configured singleton limit;
- broker and SSHFS process counts;
- open file descriptors for the Rust broker and SFTP child;
- `sysctl -n kern.num_files` before, peak, immediately after client exit, and
  one minute later;
- vnode counters used by launcher preflight;
- the expected named singleton state;
- absence of stale per-client staging or FUSE mounts;
- ownership of files created from the guest.

Apple [`container#1097`](https://github.com/apple/container/issues/1097)
concerns VirtioFS. The dynamic workspace is SFTP/SSHFS, so benchmark it
separately from the profile HOME and static configuration mounts that still use
Apple volumes. Legacy `run` is a third category because its workspace and extra
shares use VirtioFS.

Do not run million-file or file-table exhaustion reproducers on a daily-use
machine. Safety overrides do not make an unsafe test safe.

## Historical context

Third-party measurements reported in
[`containerization#729`](https://github.com/apple/containerization/issues/729)
on an M3/macOS 26.4.1 with 4 CPU/4 GiB showed:

| Metric | Docker Desktop | OrbStack | Apple container |
|---|---:|---:|---:|
| Cached startup | 0.329 s | 0.371 s | 0.935 s |
| 1,000 small files | 0.711 s | 0.620 s | 1.257 s |
| 256 MB sequential write | 1,327 MB/s | 1,566 MB/s | 1,280 MB/s |

These are historical third-party numbers for a different lifecycle and
filesystem path. They are not project results and must not be used as expected
performance for the persistent singleton plus SFTP architecture.

## Percentile calculation

Store one elapsed-seconds value per line:

```bash
sort -n samples.txt > samples.sorted.txt
count=$(wc -l < samples.sorted.txt | tr -d '[:space:]')
p50_line=$(( (count * 50 + 99) / 100 ))
p95_line=$(( (count * 95 + 99) / 100 ))
sed -n "${p50_line}p;${p95_line}p" samples.sorted.txt
```

Label both lines and retain the raw file. Use a statistical package for
confidence intervals or significance testing.

## Acceptance criteria

A workload is suitable only when:

- cold build and cold singleton creation are operationally acceptable;
- warm attach `p50` and `p95` are acceptable;
- repository reads, writes, Git, build, and tests are correct over SSHFS;
- watch-mode behavior is verified or explicitly documented;
- concurrent clients retain correct cwd and independent mount lifetimes;
- ending one client does not disturb another;
- active-client host-launcher `SIGKILL` reclaims that broker, connection,
  Agent tree, cgroup, SSHFS mount, and session state without stopping the
  singleton or another client;
- client cleanup leaves no Agent descendant, cgroup leaf, broker, SSHFS, mount,
  token staging, or unexpected native resource;
- singleton stop/recreate is reliable and preserves intended profile HOME;
- host FD/vnode use returns near the relevant baseline;
- the isolation benefit justifies measured overhead.

Publish results per profile, repository class, and lifecycle state. A good
result for one sequential workload must not be generalized to metadata-heavy
monorepos or online Agent tasks.

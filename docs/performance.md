# Performance expectations and benchmark protocol

## No unconditional speedup claim

`agent-container` removes the need for Docker Desktop and uses Apple's native
Virtualization.framework integration and cached OCI content. On a
clone-capable backing filesystem such as APFS, root copies can use copy-on-write
clones. Those properties can reduce idle infrastructure and make warm root
creation efficient. They do **not** prove that every Agent task is faster than
running the same CLI directly on macOS.

Each session still boots a Linux Micro-VM. Workspace I/O crosses VirtioFS, and
Agent workloads often scan many small files. Network latency and model latency
usually dominate an online prompt. Performance therefore depends on the
repository, Agent, toolchain, macOS/container release, and whether the image is
already warm.

Third-party results reported in
[`containerization#729`](https://github.com/apple/containerization/issues/729)
on an M3/macOS 26.4.1 with 4 CPU/4 GiB illustrate the trade-off:

| Metric | Docker Desktop | OrbStack | Apple container |
|---|---:|---:|---:|
| Cached startup | 0.329 s | 0.371 s | 0.935 s |
| 1,000 small files | 0.711 s | 0.620 s | 1.257 s |
| 256 MB sequential write | 1,327 MB/s | 1,566 MB/s | 1,280 MB/s |

These are historical third-party measurements, not project results or
universal constants. The primary comparison for this project is now native
macOS Agent CLI versus the same Agent profile in `agent-container`.

## Separate the costs

Report these phases independently:

1. **Cold build**: base-image pull, npm package download, and image build.
2. **Warm launch**: image already present with a matching fingerprint.
3. **Workspace I/O**: Git status, file enumeration, build, and tests through
   VirtioFS.
4. **Agent startup**: CLI initialization before a network request.
5. **Online task**: API and model latency, reported separately from runtime
   overhead.
6. **Shutdown**: exit latency, remaining VM/container state, and host file
   descriptor recovery.

Do not average a cold build into warm launch results. Do not use a single
online prompt as evidence of container performance.

## Native-versus-container protocol

Use the same machine, power mode, repository revision, Agent version, terminal
mode, CPU/memory policy, proxy, and network. Close unrelated high-I/O programs.
Run one discarded warmup followed by at least 20 measured iterations for each
side, alternating native and container order to reduce thermal and cache bias.

For every metric report sample count, median (`p50`), `p95`, minimum, maximum,
and failures. Retain raw samples.

### 1. Process and VM startup

For each preview or stable profile, compare the same exact top-level version:

```bash
/usr/bin/time -p claude --version
/usr/bin/time -p agent-container claude --version

/usr/bin/time -p codex --version
/usr/bin/time -p agent-container codex --version
```

Confirm that the container image was already built before collecting warm
samples. Record a forced build separately with
`AGENT_CONTAINER_REBUILD=true`.

### 2. Identical local repository work

Run equivalent native and guest commands in the same checkout:

1. `git status --porcelain=v1`;
2. `rg --files`, recording the result count;
3. the repository's normal build and test command;
4. a representative read-heavy task;
5. a representative write-heavy task to disposable files.

The Agent image may not have the same toolchain as the host. Record all tool
versions and do not compare commands whose dependencies differ materially.

### 3. Fixed Agent task

Use a deterministic non-interactive prompt and pin the Agent/model settings.
Record separately:

- time until the Agent process is ready;
- time to first model event or token;
- total task time;
- API retries, rate limiting, and cache status;
- tool execution time inside the workspace.

API and model variance must not be attributed to the container. If the provider
cannot disable or report response caching, disclose that limitation.

### 4. Host resource and safety observations

For every run record:

- host RSS and energy impact;
- `sysctl -n kern.num_files` before, peak, immediately after, and one minute
  after exit;
- vnode counters used by the launcher preflight;
- whether `container list` retains a project-labeled session after exit;
- ownership of a small file written from the guest;
- whether host-side edits become visible to guest watch mode.

Do not run Apple's million-file `#1097` reproducer on a daily-use machine.

## Example p50/p95 calculation

Store one elapsed-seconds value per line, then calculate percentiles without
rounding samples away:

```bash
sort -n samples.txt > samples.sorted.txt
count=$(wc -l < samples.sorted.txt | tr -d '[:space:]')
p50_line=$(( (count * 50 + 99) / 100 ))
p95_line=$(( (count * 95 + 99) / 100 ))
sed -n "${p50_line}p;${p95_line}p" samples.sorted.txt
```

Label the two output lines clearly in the benchmark report. Use a proper
statistics tool when confidence intervals or significance testing are needed.

## Acceptance criteria

The runtime is suitable for a workload only when all of the following hold:

- warm `p50` and `p95` overhead are measured and acceptable for that workload;
- repository build/test and Git worktree/submodule flows are correct;
- writes retain the host numeric UID/GID;
- repeated exits leave no project-labeled containers;
- host FD/vnode use returns near baseline;
- file watching is either verified or explicitly documented as unsupported;
- the isolation benefit justifies measured startup and VirtioFS costs.

Results should be published per profile and repository class. A good result for
one Agent or a sequential-write workload must not be generalized to all Agent
CLIs or metadata-heavy monorepos.

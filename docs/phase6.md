# Phase 6 — Graceful Self-Destruction Protocol

## Overview

Phase 5 gave ferrite eyes: it can observe its own resource consumption. Phase 6 gives it teeth: when resources are critically exhausted, ferrite destroys itself — or the container it is monitoring — gracefully.

The self-destruction protocol is the culmination of ferrite's design philosophy: *make something that dies*. The runtime does not merely crash when memory is exhausted; it logs its final state, attempts a graceful shutdown, and only escalates to forceful termination when necessary.

## Implementation

### Module: `src/ferrite/destruction.nim`

#### `DestructionConfig`

```nim
type
  DestructionMode = enum
    dmGraceful,   ## SIGTERM first, then SIGKILL after grace period
    dmImmediate   ## SIGKILL immediately (no grace period)

  DestructionConfig = object
    memThresholdPct*: float       # Memory usage % that triggers destruction
    inodeThresholdPct*: float     # Inode usage % that triggers destruction
    diskThresholdPct*: float      # Disk usage % that triggers destruction
    cgroupMemThresholdPct*: float # Cgroup memory % that triggers destruction (0 = ignore)
    mode*: DestructionMode        # Graceful or immediate destruction
    gracePeriodMs*: int           # Milliseconds to wait before SIGKILL
    checkIntervalMs*: int         # Milliseconds between resource checks
    logPath*: string              # Filesystem path to monitor (default "/")
```

Default thresholds are **95%** for memory, inodes, and disk. Cgroup memory threshold is disabled by default (set to 0).

#### `SelfDestructor`

```nim
type
  SelfDestructor = object
    config*: DestructionConfig
    decayLog*: DecayLog
    monitorPid*: Pid              # Target process to kill (0 = self)
    isAlive*: bool                # Set to false after destruction is triggered
    destructionTime*: float       # Epoch time when destruction started
    sigtermSent*: bool            # True if SIGTERM has been sent
```

The `SelfDestructor` is a stateful monitor that:
1. Samples resources into its `DecayLog` on each check.
2. Evaluates thresholds against the latest sample.
3. Initiates destruction (SIGTERM → wait → SIGKILL, or immediate SIGKILL).
4. Tracks whether it is still alive or already destroyed.

#### `evaluateThresholds(sd): seq[string]`

Checks all configured thresholds and returns a list of human-readable breach descriptions. Returns an empty seq if all clear.

Example output:
```
@["MEMORY_CRITICAL: 96.5%", "DISK_CRITICAL: 97.2%"]
```

#### `shouldDestroy(sd): bool`

Convenience: returns `true` if `evaluateThresholds` returns any breaches.

#### `gracefulDestroy(sd)`

Initiates or continues graceful destruction:
- **First call**: sends `SIGTERM` to the monitored process, records the timestamp.
- **Subsequent calls**: if the grace period has elapsed, sends `SIGKILL` and sets `isAlive = false`.
- **Before grace period expires**: logs remaining wait time.

#### `immediateDestroy(sd)`

Sends `SIGKILL` immediately and sets `isAlive = false`. No grace period.

#### `checkAndDestroy(sd)`

The main periodic check. Should be called on a timer (e.g. every `checkIntervalMs`).

Flow:
1. If already destroyed, return.
2. If already destroying (SIGTERM sent), continue the graceful sequence.
3. Sample resources into the DecayLog.
4. Evaluate thresholds.
5. If breached: log the breach, log a full resource snapshot, then destroy according to mode.

#### `runMonitored(cmd, args, config): cint`

High-level wrapper that runs a command with self-destruction monitoring.

1. Forks the command as a child process.
2. Parent enters a monitoring loop:
   - Checks if child has exited (non-blocking `waitpid`).
   - Calls `checkAndDestroy` on the child.
   - Sleeps for `checkIntervalMs`.
3. If thresholds are breached, the child is terminated.
4. Returns the child's exit code (or 128 + signal if killed).

#### `logDestructionConfig(cfg)` / `logDestructionState(sd)`

Human-readable logging of configuration and current state to stderr (via `logDecay`).

### Threshold Evaluation

The destructor uses the same monitoring primitives as Phase 5:

| Threshold | Source | Default |
|-----------|--------|---------|
| Memory | `/proc/self/status` VmRSS vs `/proc/meminfo` MemTotal | 95% |
| Cgroup memory | `memory.current` vs `memory.max` | disabled |
| Inodes | `statvfs(2)` f_files vs f_ffree | 95% |
| Disk | `statvfs(2)` f_blocks vs f_bfree | 95% |

Any single threshold breach triggers destruction.

## Testing

Tests live in `tests/test_destruction.nim`:

- **Configuration**: `initDestructionConfig()` returns correct defaults and accepts overrides.
- **Initialization**: `initSelfDestructor()` creates an alive monitor with empty DecayLog.
- **Threshold evaluation**: `evaluateThresholds()` returns empty when all clear, `shouldDestroy()` is `true` when thresholds are set to 0%.
- **Destruction actions**: `immediateDestroy()` sets `isAlive = false`; `gracefulDestroy()` sets `sigtermSent` on first call and `isAlive = false` after grace period.
- **DecayLog integration**: `checkAndDestroy()` samples the log even when not destroying.
- **Logging**: `logDestructionConfig()` and `logDestructionState()` do not crash.
- **Integration**: `runMonitored("/bin/true")` returns 0, `/bin/false` returns 1, exit codes are propagated.

Most tests run without root. Integration tests that actually fork processes require root.

## Usage

### Basic monitoring loop

```nim
import ferrite/destruction
import ferrite/monitor

var sd = initSelfDestructor(initDestructionConfig(
  memThresholdPct = 90.0,
  mode = dmGraceful,
  gracePeriodMs = 3000
))

logDestructionConfig(sd.config)

while sd.isAlive:
  checkAndDestroy(sd)
  if sd.isAlive:
    sleep(sd.config.checkIntervalMs)
```

### Run a command with automatic destruction

```nim
let cfg = initDestructionConfig(
  memThresholdPct = 80.0,
  checkIntervalMs = 500
)
let rc = runMonitored("/bin/sh", ["-c", "stress --vm 1 --vm-bytes 1G"], cfg)
echo "Exit code: ", rc
```

If the stressed process pushes memory above 80%, the monitor will:
1. Log the threshold breach.
2. Send SIGTERM to the stress process.
3. Wait 5 seconds (default grace period).
4. Send SIGKILL if still running.
5. Return the exit code.

### Immediate destruction mode

For batch jobs or CI pipelines where graceful shutdown is not needed:

```nim
let cfg = initDestructionConfig(mode = dmImmediate)
let rc = runMonitored("./long-running-job", [], cfg)
```

## Design Decisions

- **Parent monitors child**: `runMonitored` forks the workload and monitors from the parent. This keeps the monitoring logic out of the container's PID namespace and avoids the "who watches the watcher" problem.
- **Graceful by default**: The default mode is `dmGraceful` with a 5-second grace period. This gives applications time to flush buffers, close connections, and write state before being force-killed.
- **Self-targeting**: If `monitorPid` is 0, the destructor targets itself (`getpid()`). This allows a standalone process to monitor and destroy itself.
- **Periodic sampling**: Every `checkAndDestroy` call appends to the `DecayLog`, so trends are available at destruction time for post-mortem logging.
- **No threads**: The monitor loop is a simple `while` + `sleep` in the parent process. No pthreads, no async, no complexity.

## Integration Points

### With Phase 5 (monitor)

`destruction.nim` imports `monitor.nim` and reuses:
- `readMemoryInfo()`, `readFilesystemUsage()`, `readCgroupMemoryStat()`
- `isMemoryCritical()`, `isInodeCritical()`, `isDiskCritical()`
- `DecayLog`, `sample()`, `logResourceSnapshot()`, `logDecay()`

### With Phase 4 (lifecycle)

`runMonitored` can be composed with `runAsInit` for full container lifecycle:

```nim
# Inside a PID namespace, runAsInit forks the real command.
# The parent (init) can create a SelfDestructor and monitor the child.
```

Future integration (Phase 7 CLI) will wire `runMonitored` into the `ferrite run` command with flags like `--self-destruct-mem 90`.

## Next Steps

- Phase 7: CLI expansion (`run`, `exec`, `kill`, `ps`) with self-destruction flags
- Phase 8: OCI runtime spec compatibility

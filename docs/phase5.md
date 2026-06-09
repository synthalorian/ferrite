# Phase 5 — Self-Monitoring (Memory, Inode Tracking)

## Overview

Every container runtime eventually faces resource exhaustion. Phase 5 gives ferrite the ability to observe its own resource consumption — memory footprint, disk usage, and inode exhaustion — and to track these metrics over time. This is the "logs its own decay" part of ferrite's design philosophy.

## Implementation

### Module: `src/ferrite/monitor.nim`

#### `readMemoryInfo(): MemoryInfo`

Reads `/proc/self/status` to extract process memory statistics:

| Field | Source | Meaning |
|-------|--------|---------|
| `vmsize` | `VmSize` | Total virtual memory |
| `vmrss` | `VmRSS` | Resident set size (physical RAM) |
| `vmdata` | `VmData` | Data segment size |
| `vmstk` | `VmStk` | Stack size |
| `vmexe` | `VmExe` | Text (code) segment size |
| `vmlib` | `VmLib` | Shared library usage |
| `vmpte` | `VmPTE` | Page table entries |
| `vmswap` | `VmSwap` | Swap usage |

All values are in bytes. Returns zeros if `/proc` is unavailable.

#### `readFilesystemUsage(path): FilesystemUsage`

Calls `statvfs(2)` on the filesystem containing `path` and returns:

| Field | Meaning |
|-------|---------|
| `totalBytes` | Total filesystem capacity |
| `freeBytes` | Free blocks |
| `availBytes` | Available to non-superuser |
| `usedBytes` | `total - free` |
| `totalInodes` | Total inodes on filesystem |
| `freeInodes` | Free inodes |
| `usedInodes` | `total - free` |
| `blockSize` | Filesystem block size |

#### `readCgroupMemoryStat(cgroupName): CgroupMemoryStat`

Reads cgroup v2 memory controller statistics:

| Field | Source | Meaning |
|-------|--------|---------|
| `current` | `memory.current` | Current memory usage |
| `max` | `memory.max` | Configured limit (0 = unlimited) |
| `anon` | `memory.stat` | Anonymous memory |
| `file` | `memory.stat` | File-backed memory |
| `kernelStack` | `memory.stat` | Kernel stack usage |
| `pagetables` | `memory.stat` | Page tables |
| `percpu` | `memory.stat` | Per-CPU memory |
| `sock` | `memory.stat` | Socket memory |
| `shmem` | `memory.stat` | Shared memory |
| `zswap` | `memory.stat` | Zswap pool |
| `zswapped` | `memory.stat` | Zswapped pages |

If `cgroupName` is empty, reads from the current cgroup.

#### Decay Log — Sampling and Trend Analysis

The `DecayLog` type is a ring buffer of `ResourceSample` values:

```nim
type
  DecayLog = object
    samples: seq[ResourceSample]
    maxSamples: int
```

**API:**

- `initDecayLog(maxSamples)` — create a new ring buffer
- `sample(dl, path)` — take a snapshot and append it (drops oldest if full)
- `latest(dl)` — most recent sample
- `memoryTrend(dl)` — RSS change rate in bytes/second
- `inodeTrend(dl)` — inode usage change rate in inodes/second

#### Threshold Checking

Convenience functions for alerting:

- `isMemoryCritical(mem, thresholdPct, systemTotal)` — RSS above threshold
- `isInodeCritical(fs, thresholdPct)` — inode usage above threshold
- `isDiskCritical(fs, thresholdPct)` — disk usage above threshold
- `checkAllThresholds(path, memThreshold, inodeThreshold, diskThreshold)` — returns list of warning strings

#### Logging

- `logDecay(msg)` — writes `[DECAY <timestamp>] <msg>` to stderr
- `logResourceSnapshot(dl, path)` — logs a full human-readable resource report
- `formatBytes(n)` — converts bytes to "1.50 MiB" style strings

### Data Sources

| Metric | Source | Fallback |
|--------|--------|----------|
| Process memory | `/proc/self/status` | zeros |
| System memory total | `/proc/meminfo` | zeros |
| Filesystem usage | `statvfs(2)` | zeros |
| Cgroup memory | `/sys/fs/cgroup/memory.*` | zeros |

## Testing

Tests live in `tests/test_monitor.nim`:

- **Memory info**: `readMemoryInfo()` returns valid RSS/VmSize
- **Memory percentage**: `memoryUsagePct()` is within [0, 100]
- **Filesystem**: `readFilesystemUsage("/")` returns non-zero totals
- **Inode/disk percentages**: within [0, 100]
- **Cgroup stats**: `readCgroupMemoryStat()` does not crash
- **Decay log**: ring buffer, sampling, `latest()`, trend calculation
- **Thresholds**: critical detection for memory, inodes, disk
- **Formatting**: `formatBytes()` correctness
- **Logging**: `logDecay()` and `logResourceSnapshot()` do not crash

Most tests run without root. Cgroup-specific tests gracefully skip when cgroups v2 is unavailable.

## Usage

### Basic introspection

```nim
import ferrite/monitor

let mem = readMemoryInfo()
echo "RSS: ", formatBytes(mem.vmrss)

let fs = readFilesystemUsage("/")
echo "Inode usage: ", inodeUsagePct(fs), "%"
```

### Tracking decay over time

```nim
var dl = initDecayLog(maxSamples = 60)
for i in 0..<10:
  dl.sample("/")
  sleep(1000)

logResourceSnapshot(dl, "/")
# [DECAY 2024-...] memory rss=12.34 MiB vmsize=56.78 MiB
# [DECAY 2024-...] fs path=/ used=1.2 GiB total=100.0 GiB disk-pct=12.34%
# [DECAY 2024-...] fs inodes used=123456 total=1000000 inode-pct=12.35%
# [DECAY 2024-...] trend memory=+1.00 KiB/s inodes=stable
```

### Threshold alerts

```nim
let warnings = checkAllThresholds("/", 80.0, 90.0, 95.0)
for w in warnings:
  logDecay(w)
```

## Design Decisions

- **Pure proc parsing**: No external libraries. `/proc` and `statvfs(2)` are universal on Linux.
- **Zeros on error**: Rather than raising exceptions for missing `/proc` or cgroup files, monitoring procs return zeroed structs. This makes the module safe to call in restricted environments.
- **Ring buffer for trends**: A fixed-size `seq` with `delete(0)` on overflow. Simple and sufficient for an educational runtime. For production, a circular array would avoid allocation churn.
- **stderr for decay logs**: Monitoring output goes to stderr so it doesn't interfere with the container's stdout.

## Integration Points

Phase 5 is a standalone module. Integration with the container lifecycle (automatic sampling, self-destruction at limits) happens in **Phase 6**.

## Next Steps

- Phase 6: Graceful self-destruction at resource limits
- Phase 7: CLI expansion (`run`, `exec`, `kill`, `ps`)
- Phase 8: OCI runtime spec compatibility

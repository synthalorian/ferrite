# Phase 3: cgroups v2 Resource Control

**Goal:** Limit container resource usage via the unified cgroup v2 hierarchy.

**Status:** ✅ Implemented

**Deliverables:**
- [x] Core implementation (`src/ferrite/cgroups.nim`)
- [x] Tests (`tests/test_cgroups.nim`)
- [x] CLI integration (`src/ferrite.nim`)
- [x] Documentation update

---

## What Was Built

### `src/ferrite/cgroups.nim`

A new module providing:

| Function | Purpose |
|----------|---------|
| `cgroupV2Available` | Detect whether unified cgroup v2 is mounted |
| `availableControllers` | List available controllers (cpu, memory, pids, etc.) |
| `createCgroup` | Create a new cgroup directory |
| `removeCgroup` | Remove an empty cgroup directory |
| `moveProcessToCgroup` | Move a process into a cgroup |
| `enableControllers` | Enable controllers in a cgroup's subtree_control |
| `setCgroupLimits` | Write cpu.max, memory.max, pids.max |
| `readCgroupLimits` | Read back the currently configured limits |
| `setupCgroup` | High-level: create + enable + set limits |
| `applyCgroup` | Full helper: setup + move process |
| `cleanupCgroup` | Best-effort removal |
| `currentCgroup` / `isInCgroup` | Introspection helpers |

### Resource Limit Mapping

| Flag | cgroup v2 File | Format |
|------|---------------|--------|
| `--cpu <pct>` | `cpu.max` | `"quota period"` (e.g. `50000 100000` for 50%) |
| `--mem <bytes>` | `memory.max` | raw byte count |
| `--pids <n>` | `pids.max` | raw count |

All limits are hard limits. A value of `0` (or omitting the flag) means unlimited.

### Integration Points

- `executeInNamespace` and `runInRootfs` accept an optional `cgroupName` parameter
- The parent creates the cgroup and sets limits **before** `clone`
- Immediately after `clone` returns, the child PID is written to `cgroup.procs`
- After `waitpid` returns, the cgroup is removed via `cleanupCgroup`
- `try/finally` in `ferrite.nim` ensures cleanup even on errors

## CLI Changes

The `run` command now accepts resource limit flags:

```bash
# Limit CPU to 50% and memory to 128 MiB
sudo ferrite run --cpu 50 --mem 134217728 -- /bin/sh

# Combined with rootfs
sudo ferrite run --root /var/lib/ferrite/images/alpine \
                 --cpu 25 --mem 67108864 --pids 100 -- /bin/sh
```

When any limit flag is present, ferrite:
1. Verifies cgroups v2 is available
2. Creates a cgroup named `ferrite-<parent-pid>-<timestamp>`
3. Applies the requested limits
4. Moves the container process into the cgroup
5. Cleans up the cgroup after the container exits

## Tests

`tests/test_cgroups.nim` covers:

- cgroups v2 availability detection
- Cgroup create / remove lifecycle
- Process movement into cgroups
- CPU limit setting and read-back
- Memory limit setting and read-back
- PID limit setting and read-back
- Combined limit application
- High-level `applyCgroup` helper
- Cleanup best-effort behavior

All tests skip gracefully when:
- Not run as root
- cgroups v2 is unavailable
- A specific controller (cpu, memory, pids) is not available

## Files Changed

- **New:** `src/ferrite/cgroups.nim`
- **New:** `tests/test_cgroups.nim`
- **Modified:** `src/ferrite.nim` (added `--cpu`, `--mem`, `--pids` flags, cgroup lifecycle)
- **Modified:** `src/ferrite/namespaces.nim` (added `cgroupName` parameter to `executeInNamespace`)
- **Modified:** `src/ferrite/rootfs.nim` (added `cgroupName` parameter to `runInRootfs`, imported cgroups)
- **Modified:** `ferrite.nimble` (added test_cgroups to test task)
- **Modified:** `README.md`
- **New:** `docs/phase3.md`

---

*Generated for opencode sprint. Implement phase by phase. DO NOT RESEARCH. Build directly.*

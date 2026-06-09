# ferrite — Implementation Plan

## Project Overview

Minimal container runtime from scratch. Namespaces, cgroups v2, overlayfs — educational but functional. Logs its own decay and self-destructs gracefully.

**Language:** Nim  
**Constraint:** Make something that dies  
**Stack:** pure Nim (posix wrappers, linux headers)

---

## Phase Breakdown

### Phase 1: Namespace isolation (clone, unshare)

**Goal:** Phase 1: Namespace isolation (clone, unshare)

**Deliverables:**
- [x] Core implementation (`src/ferrite/namespaces.nim`)
- [x] Tests (`tests/test_namespaces.nim`)
- [x] Documentation update (`docs/phase1.md`, `README.md`)

**Notes:**
- Implemented `cloneIsolate`, `unshareNamespaces`, `executeInNamespace`
- Supports all standard Linux namespaces: mount, pid, net, uts, ipc, user, cgroup
- CLI entry point at `src/ferrite.nim` with `run` subcommand 

---

### Phase 2: Root filesystem setup (pivot_root, overlayfs)

**Goal:** Phase 2: Root filesystem setup (pivot_root, overlayfs)

**Deliverables:**
- [x] Core implementation (`src/ferrite/rootfs.nim`)
- [x] Tests (`tests/test_rootfs.nim`)
- [x] Documentation update (`docs/phase2.md`, `README.md`)

**Notes:**
- Implemented `mountOverlay`, `umount`, `pivotRoot`, `prepareRootfs`, `teardownRootfs`, `runInRootfs`
- CLI updated with `--root <path>` flag for overlayfs-backed containers
- Syscall wrappers for mount(2), umount2(2), pivot_root(2), chdir(2), mkdir(2), rmdir(2) 

---

### Phase 3: cgroups v2 resource control

**Goal:** Phase 3: cgroups v2 resource control

**Deliverables:**
- [x] Core implementation (`src/ferrite/cgroups.nim`)
- [x] Tests (`tests/test_cgroups.nim`)
- [x] Documentation update (`docs/phase3.md`, `README.md`)

**Notes:**
- Implemented `setupCgroup`, `applyCgroup`, `cleanupCgroup`
- Supports CPU (cpu.max), memory (memory.max), and PID (pids.max) limits
- CLI updated with `--cpu <pct>`, `--mem <bytes>`, `--pids <n>` flags
- Cgroup created before clone, child moved immediately after, cleaned up after waitpid 

---

### Phase 4: Process lifecycle management (init, reap)

**Goal:** Phase 4: Process lifecycle management (init, reap)

**Deliverables:**
- [x] Core implementation (`src/ferrite/lifecycle.nim`)
- [x] Tests (`tests/test_lifecycle.nim`)
- [x] Documentation update (`docs/phase4.md`, `README.md`)

**Notes:**
- Implemented `runAsInit` with signal forwarding (SIGTERM, SIGINT, SIGHUP, SIGUSR1, SIGUSR2)
- Zombie reaping via waitpid(-1, WNOHANG) after main child exits
- Integrated into `executeInNamespace` and `runInRootfs` when `nsPid` is in namespace set
- Added `ContainerProcess` type with `startContainerInit` and `waitContainer` helpers

---

### Phase 5: Self-monitoring (memory, inode tracking)

**Goal:** Phase 5: Self-monitoring (memory, inode tracking)

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 6: Graceful self-destruction protocol

**Goal:** Phase 6: Graceful self-destruction protocol

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 7: CLI: run, exec, kill, ps

**Goal:** Phase 7: CLI: run, exec, kill, ps

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 8: OCI runtime spec compatibility layer

**Goal:** Phase 8: OCI runtime spec compatibility layer

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

## Architecture Notes

### Key Decisions

- 

### Data Flow

```
[Input] → [Parse] → [Transform] → [Output]
```

### Error Handling Strategy

- 

---

## Testing Strategy

- Unit tests for core functions
- Integration tests for full pipeline
- Benchmarks for performance-critical paths

---

## Open Questions

1. 
2. 

---

*Generated for opencode sprint. Implement phase by phase. DO NOT RESEARCH. Build directly.*

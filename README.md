# ferrite

> Minimal container runtime from scratch. Namespaces, cgroups v2, overlayfs — educational but functional. Logs its own decay and self-destructs gracefully.

**Language:** Nim  
**Constraint:** Make something that dies  
**Stack:** pure Nim (posix wrappers, linux headers)

---

## Features

- Container creation via Linux namespaces (pid, net, mount, uts, ipc)
- cgroups v2 resource limiting (cpu, memory, pids)
- Overlayfs root filesystem
- Self-monitoring: logs memory fragmentation, inode exhaustion
- Graceful self-destruction at resource limits
- OCI runtime spec compatibility (partial)
- Educational mode: verbose explanation of every syscall

---

## Development Plan

1. Phase 1: Namespace isolation (clone, unshare)
2. Phase 2: Root filesystem setup (pivot_root, overlayfs)
3. Phase 3: cgroups v2 resource control
4. Phase 4: Process lifecycle management (init, reap)
5. Phase 5: Self-monitoring (memory, inode tracking)
6. Phase 6: Graceful self-destruction protocol
7. Phase 7: CLI: run, exec, kill, ps
8. Phase 8: OCI runtime spec compatibility layer

---

## Getting Started

### Prerequisites

- Nim toolchain

### Build

```bash
# See PLAN.md for detailed build instructions per phase
cd ferrite
```

### Run

```bash
# See PLAN.md for run instructions
```

---

## Architecture

See `PLAN.md` for detailed architecture decisions and implementation notes.

---

## License

MIT

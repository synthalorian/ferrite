# ferrite

> Minimal container runtime from scratch. Namespaces, cgroups v2, overlayfs — educational but functional. Logs its own decay and self-destructs gracefully.

**Language:** Nim  
**Constraint:** Make something that dies  
**Stack:** pure Nim (posix wrappers, linux headers)

---

## Features

- [x] **Phase 1**: Namespace isolation (`clone`, `unshare`) — `pid`, `net`, `mount`, `uts`, `ipc`, `user`
- [x] **Phase 2**: Root filesystem setup (`pivot_root`, `overlayfs`)
- [ ] **Phase 3**: cgroups v2 resource limiting (`cpu`, `memory`, `pids`)
- [ ] **Phase 4**: Process lifecycle management (init, reap)
- [ ] **Phase 5**: Self-monitoring (memory fragmentation, inode exhaustion)
- [ ] **Phase 6**: Graceful self-destruction at resource limits
- [ ] **Phase 7**: CLI (`run`, `exec`, `kill`, `ps`)
- [ ] **Phase 8**: OCI runtime spec compatibility (partial)

---

## Development

### Prerequisites

- Nim >= 2.0.0
- Linux (kernel 5.x+ for full cgroups v2 support)
- Root or `CAP_SYS_ADMIN` for namespace operations

### Build

```bash
# Compile the runtime
nimble build

# Run tests
nimble test
```

### Phase 1 — Namespace Isolation

Create an isolated process with its own namespaces:

```bash
sudo ./ferrite run -- /bin/sh
```

This creates a new process in separate `pid`, `net`, `mount`, `uts`, `ipc`, and `user` namespaces.

### Phase 2 — Root Filesystem Setup

Run a command inside an isolated root filesystem using overlayfs:

```bash
# Provide a directory as the base image layer
sudo ./ferrite run --root /var/lib/ferrite/images/alpine -- /bin/sh
```

ferrite will:
1. Mount an overlayfs with the provided directory as the read-only lower layer
2. `pivot_root` into the merged view
3. Execute the command

The overlay layout is created automatically under `/tmp/ferrite-<pid>/`.

---

## Architecture

See `PLAN.md`, `docs/phase1.md`, and `docs/phase2.md` for detailed architecture decisions.

---

## License

MIT

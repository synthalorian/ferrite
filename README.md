# ferrite

> Minimal container runtime from scratch. Namespaces, cgroups v2, overlayfs — educational but functional. Logs its own decay and self-destructs gracefully.

**Language:** Nim  
**Constraint:** Make something that dies  
**Stack:** pure Nim (posix wrappers, linux headers)

---

## Features

- [x] **Phase 1**: Namespace isolation (`clone`, `unshare`) — `pid`, `net`, `mount`, `uts`, `ipc`, `user`
- [x] **Phase 2**: Root filesystem setup (`pivot_root`, `overlayfs`)
- [x] **Phase 3**: cgroups v2 resource limiting (`cpu`, `memory`, `pids`)
- [x] **Phase 4**: Process lifecycle management (init, reap)
- [x] **Phase 5**: Self-monitoring (memory fragmentation, inode exhaustion)
- [x] **Phase 6**: Graceful self-destruction at resource limits
- [x] **Phase 7**: CLI (`run`, `exec`, `kill`, `ps`)
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

### Phase 3 — cgroups v2 Resource Control

Limit CPU, memory, and process count for containers:

```bash
# Limit CPU to 50% and memory to 128 MiB
sudo ./ferrite run --cpu 50 --mem 134217728 -- /bin/sh

# Combined with rootfs
sudo ./ferrite run --root /var/lib/ferrite/images/alpine \
                   --cpu 25 --mem 67108864 --pids 100 -- /bin/sh
```

When resource limits are specified, ferrite:
1. Creates a cgroup under `/sys/fs/cgroup/ferrite-<pid>-<timestamp>/`
2. Writes the requested limits (`cpu.max`, `memory.max`, `pids.max`)
3. Moves the container process into the cgroup
4. Cleans up the cgroup after the container exits

### Phase 7 — CLI Commands

ferrite now supports the full container lifecycle:

```bash
# Run a new container
sudo ./ferrite run --root /var/lib/ferrite/images/alpine -- /bin/sh

# Execute a command in a running container
sudo ./ferrite exec ferrite-1234 -- /bin/hostname

# Send a signal to a container
sudo ./ferrite kill ferrite-1234
sudo ./ferrite kill -s SIGKILL ferrite-1234

# List running containers
sudo ./ferrite ps
```

Containers are tracked in `/run/ferrite/` (or `/tmp/ferrite/` as fallback) with JSON state files. Container IDs can be specified with `--id` or auto-generated. The `exec` command uses `setns(2)` to enter the target container's namespaces.

---

## Architecture

See `PLAN.md`, `docs/phase1.md`, `docs/phase2.md`, and `docs/phase3.md` for detailed architecture decisions.

---

## License

MIT

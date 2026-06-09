# Phase 2: Root Filesystem Setup

**Goal:** Provide container root filesystem isolation via `pivot_root(2)` and overlayfs.

## What Was Built

### `src/ferrite/rootfs.nim`

A new module providing:

| Function | Purpose |
|----------|---------|
| `mountOverlay` | Mount an overlayfs combining lower (ro) + upper (rw) layers |
| `umount` | Unmount a filesystem (with optional lazy/detach flags) |
| `pivotRoot` | Change the process root via `pivot_root(2)` |
| `prepareRootfs` | High-level: set up overlayfs layout for a container |
| `teardownRootfs` | Unmount overlayfs and clean up |
| `runInRootfs` | Full pipeline: clone → overlayfs → pivot_root → exec |

### Syscall Wrappers

All syscalls are wrapped directly (no external dependencies):

- `SYS_mount` (165) — `mount(2)`
- `SYS_umount2` (166) — `umount2(2)`
- `SYS_pivot_root` (155) — `pivot_root(2)`
- `SYS_chdir` (80) — `chdir(2)`
- `SYS_mkdir` (83) — `mkdir(2)`
- `SYS_rmdir` (84) — `rmdir(2)`

### Overlayfs Mount Options

The mount string follows the kernel convention:

```
lowerdir=<image>,upperdir=<container>/upper,workdir=<container>/work
```

The merged view is mounted at `<container>/merged`.

### Pivot Root Procedure

`pivotRoot(path)` performs the standard container pivot dance:

1. Ensures the current root is a mount point (bind-mounts if needed).
2. Creates `put_old` inside the new root.
3. Calls `pivot_root(newRoot, newRoot/put_old)`.
4. Changes cwd to `/`.
5. Lazily unmounts the old root and removes `put_old`.

## CLI Changes

The `run` command now accepts `--root <path>`:

```bash
# Run with an overlayfs rootfs
sudo ferrite run --root /var/lib/ferrite/images/alpine -- /bin/sh

# Phase 1 behavior still works (no rootfs)
sudo ferrite run -- /bin/sh
```

When `--root` is provided, ferrite:
1. Creates an overlayfs with the given directory as the lower layer
2. Mounts it under `/tmp/ferrite-<pid>/merged`
3. Pivots into it
4. Executes the command

## Tests

`tests/test_rootfs.nim` covers:

- Overlayfs mount/unmount
- `pivotRoot` in a mount namespace
- `prepareRootfs` / `teardownRootfs` lifecycle
- Integration test: `runInRootfs` with a minimal directory

All tests skip gracefully when not run as root.

## Files Changed

- **New:** `src/ferrite/rootfs.nim`
- **New:** `tests/test_rootfs.nim`
- **Modified:** `src/ferrite.nim` (added `--root` flag, uses `runInRootfs`)
- **Modified:** `ferrite.nimble` (added test_rootfs to test task)
- **Modified:** `README.md`
- **New:** `docs/phase2.md`

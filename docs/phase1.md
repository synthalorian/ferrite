# ferrite — Namespace Isolation

## Phase 1: Namespace isolation (`clone`, `unshare`)

**Goal:** Create isolated processes using Linux namespaces.

**Status:** ✅ Implemented

**Deliverables:**
- [x] Core implementation (`src/ferrite/namespaces.nim`)
- [x] Tests (`tests/test_namespaces.nim`)
- [x] CLI integration (`src/ferrite.nim`)
- [x] Documentation update

---

## Usage

```bash
# Build
nimble build

# Run a shell in an isolated namespace
sudo ./ferrite run -- /bin/sh

# Run tests
nimble test
```

---

## Architecture

### Namespace Flags

The runtime supports all standard Linux namespaces:

| Flag | Value | Description |
|------|-------|-------------|
| `CLONE_NEWNS` | 0x00020000 | Mount namespace |
| `CLONE_NEWPID` | 0x20000000 | PID namespace |
| `CLONE_NEWNET` | 0x40000000 | Network namespace |
| `CLONE_NEWUTS` | 0x04000000 | UTS namespace (hostname) |
| `CLONE_NEWIPC` | 0x08000000 | IPC namespace |
| `CLONE_NEWUSER` | 0x10000000 | User namespace |

### API

```nim
type
  NamespaceFlags* = enum
    nsMount, nsPid, nsNet, nsUts, nsIpc, nsUser

proc cloneIsolate*(flags: set[NamespaceFlags], fn: proc (): cint): Pid
proc unshareNamespaces*(flags: set[NamespaceFlags]): cint
proc executeInNamespace*(flags: set[NamespaceFlags], cmd: string, args: seq[string]): cint
```

### Error Handling Strategy

- Syscalls return `-1` on failure; check `errno` immediately
- Child process errors propagated via exit codes
- Stack allocation failures are fatal (panic)

---

## Testing Strategy

- Unit tests for flag composition and validation
- Integration test: fork child, verify namespace isolation via `/proc/self/ns/`
- Requires root or `CAP_SYS_ADMIN` for `CLONE_NEWNET` and `CLONE_NEWPID`

---

## Implementation Notes

### `clone` vs `unshare`

- **`clone`** — creates a new child process in fresh namespaces. Required for `CLONE_NEWPID` to take effect (init process must be in the new namespace).
- **`unshare`** — moves the calling process into new namespaces. Does not create a new process.

For container runtimes, `clone` is preferred because:
1. The child becomes PID 1 in the new PID namespace
2. Clean process tree isolation
3. Parent can monitor the container from the host

### Stack Allocation

`clone` requires a manually allocated stack for the child. We allocate a `CloneStackSize` (8 MiB) buffer and pass the top address (since x86_64 grows down).

---

*Generated for opencode sprint. Implement phase by phase. DO NOT RESEARCH. Build directly.*

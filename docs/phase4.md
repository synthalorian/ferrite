# Phase 4 — Process Lifecycle Management (init, reap)

## Overview

When `ferrite` creates a new PID namespace, the first process inside that namespace becomes **PID 1** — the init process. In Linux, PID 1 has special responsibilities:

1. **Signal forwarding**: Signals sent to the container must reach the actual application.
2. **Zombie reaping**: Orphaned child processes are re-parented to PID 1; if not reaped via `waitpid()`, they become zombies.
3. **Exit code propagation**: The container's exit code should reflect the application's exit code, not the init process's.

Phase 4 implements a minimal init process that handles all three concerns.

## Implementation

### Module: `src/ferrite/lifecycle.nim`

#### `runAsInit(argv: cstringArray): cint`

The core init routine. Called by the cloned child when `nsPid` is in the requested namespace set.

**What it does:**
1. Installs signal handlers for `SIGTERM`, `SIGINT`, `SIGHUP`, `SIGUSR1`, `SIGUSR2`.
2. Forks a child that resets handlers to default and `execvp()`'s the real container command.
3. Enters a wait loop in the parent (PID 1):
   - Blocks on `waitpid(childPid, ...)`.
   - If interrupted by a signal, forwards the pending signal to the child and retries.
   - Once the child exits, saves its exit status.
4. Does a non-blocking `waitpid(-1, WNOHANG)` sweep to reap any remaining zombies.
5. Returns the child's exit code.

**Exit codes:**
- `0–255`: child exited normally with that code.
- `128 + sig`: child was killed by signal `sig`.
- `127`: fork or exec failed.

#### `runAsInit(cmd: string; args: openArray[string]): cint`

Convenience overload that builds the `argv` array from Nim strings.

#### `ContainerProcess` / `startContainerInit` / `waitContainer`

A small tracking API for callers who want to manage container lifecycle explicitly:

```nim
type
  ProcessState = enum psRunning, psExited, psSignaled

  ContainerProcess = object
    initPid: Pid
    childPid: Pid
    exitCode: cint
    state: ProcessState
```

- `startContainerInit(nss, fn, ctx)` — clones into namespaces and returns a `ContainerProcess`.
- `waitContainer(cp)` — blocks on `waitpid(cp.initPid)`, updates `cp.state` and `cp.exitCode`.

### Integration Points

#### `namespaces.nim`: `executeInNamespace`

When `nsPid ∈ nss`, the cloned child now calls `runAsInit(argv)` instead of `execvp()` directly:

```nim
proc execChild(ctx: pointer): cint {.noconv.} =
  let argv = cast[cstringArray](ctx)
  if nsPid in nss:
    runAsInit(argv)           # PID 1: init with signal forwarding + reaping
  else:
    discard execvp(...)       # No PID namespace: exec directly
```

#### `rootfs.nim`: `runInRootfs`

Same pattern after `pivot_root()`:

```nim
if nsPid in nss:
  runAsInit(argv)
else:
  discard execvp(...)
```

## Signal Forwarding

Signals are caught via `sigaction()` handlers that set volatile boolean flags. In the wait loop:

1. `forwardPendingSignals(childPid)` sends any flagged signals to the real container process via `kill()`.
2. `waitpid()` is restarted after forwarding.

This avoids signal races and ensures every signal delivered to the container's PID 1 reaches the application.

## Zombie Reaping

The init process reaps in two stages:

1. **Main child**: blocking `waitpid(childPid, 0)` captures the container application's exit status.
2. **Stragglers**: after the main child exits, a non-blocking `waitpid(-1, WNOHANG)` loop sweeps up any remaining zombies (orphaned grandchildren, background processes, etc.).

This prevents the container from accumulating zombie processes, which would eventually exhaust the PID limit if one is configured via cgroups.

## Testing

Tests live in `tests/test_lifecycle.nim`:

- **Basic execution**: `runAsInit("/bin/true")` returns 0, `runAsInit("/bin/sh", ["-c", "exit 42"])` returns 42.
- **PID namespace init**: `executeInNamespace({nsPid, ...}, ...)` works correctly with the init layer.
- **Zombie reaping**: A test creates an orphan inside a PID namespace and verifies no zombies remain.
- **Signal forwarding**: Sends `SIGTERM` to the init process and verifies the child receives it (exit code 143).
- **Process tracking**: `startContainerInit` / `waitContainer` correctly capture both normal exits and signal deaths.

## Usage

No CLI changes are required — the init process is used automatically whenever a PID namespace is requested:

```bash
# This now runs with a proper init inside the PID namespace
sudo ./ferrite run --ns pid,net,mount,uts,ipc -- /bin/sh
```

With rootfs:

```bash
sudo ./ferrite run --root /var/lib/ferrite/images/alpine -- /bin/sh
```

The `--ns` flag still controls which namespaces are created; when `pid` is included (the default), the init/reap logic is active.

## Design Decisions

- **Fork + exec instead of direct exec**: Directly exec'ing the application would make it PID 1, but then it would have to handle signals and reaping itself. Most applications don't expect to be PID 1. By forking first, the real application runs as a normal child process.
- **Simple signal flag loop**: More sophisticated approaches (self-pipe, signalfd) exist, but the flag + `kill()` loop is sufficient for an educational container runtime and keeps the code easy to follow.
- **No systemd-style supervision**: We only forward signals and reap zombies. We don't restart crashed processes or manage service dependencies — that's out of scope for a minimal runtime.

## Next Steps

- Phase 5: Self-monitoring (memory fragmentation, inode exhaustion)
- Phase 6: Graceful self-destruction at resource limits
- Phase 7: CLI expansion (`run`, `exec`, `kill`, `ps`)
- Phase 8: OCI runtime spec compatibility

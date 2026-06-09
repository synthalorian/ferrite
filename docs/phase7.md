# Phase 7: CLI — run, exec, kill, ps

## Overview

Phase 7 completes the ferrite CLI by adding the remaining container runtime commands:

- **`run`** — Create and start a new container (enhanced with state tracking)
- **`exec`** — Execute a command inside a running container's namespaces
- **`kill`** — Send a signal to a running container
- **`ps`** — List running containers

## Implementation

### Container State Tracking (`src/ferrite/state.nim`)

Containers are tracked on disk via JSON state files stored in:
- `/run/ferrite/` (preferred, when running as root)
- `/tmp/ferrite/` (fallback)
- Custom path via `FERRITE_STATE_DIR` environment variable

Each state file records:
```json
{
  "id": "ferrite-<pid>-<timestamp>",
  "pid": 12345,
  "command": "/bin/sh",
  "rootfs": "/var/lib/ferrite/images/alpine",
  "namespaces": ["pid", "net", "mount", "uts", "ipc"],
  "cgroup": "ferrite-12345-1699999999",
  "created": 1699999999.0,
  "status": "running"
}
```

The state module provides:
- `saveContainerState` / `loadContainerState` — CRUD operations
- `listContainerStates` — List all running containers (auto-cleans stale entries)
- `findContainerByPrefix` — Resolve partial container IDs
- `isContainerRunning` / `containerExists` — Status queries

### setns Support (`src/ferrite/namespaces.nim`)

Added `setns(2)` wrapper for namespace entry:

- `enterNamespace(ns, targetPid)` — Enter a single namespace via `/proc/<pid>/ns/<type>`
- `execInNamespace(targetPid, nss, cmd, args)` — Fork, enter namespaces, execvp

This enables the `exec` command to run processes inside existing containers.

### CLI Refactor (`src/ferrite.nim`)

The main entry point now dispatches to subcommands:

```bash
ferrite run  [options] -- <command> [args...]
ferrite exec <container> [options] -- <command> [args...]
ferrite kill [-s <signal>] <container>
ferrite ps
```

#### `run` enhancements
- `--id <id>` — Explicit container ID (default: auto-generated)
- State file created before container start, cleaned up on exit
- Cgroup name now matches container ID for easy correlation

#### `exec`
- Resolves container by prefix or full ID
- Enters all container namespaces by default
- `--ns <flags>` override to enter only specific namespaces

#### `kill`
- Default signal: SIGTERM
- `-s <signal>` accepts numeric or named signals (SIGKILL, SIGINT, etc.)
- Resolves container by prefix

#### `ps`
- Lists all running containers with ID, PID, status, age, and command
- Auto-removes stale state files for dead processes

## Usage Examples

### Run a container
```bash
sudo ferrite run -- /bin/sh
sudo ferrite run --root /var/lib/ferrite/images/alpine -- /bin/sh
sudo ferrite run --cpu 50 --mem 134217728 --pids 100 -- /bin/sh
sudo ferrite run --self-destruct-mem 90 --self-destruct-mode graceful -- /bin/stress
```

### Execute in a running container
```bash
sudo ferrite exec ferrite-1234 -- /bin/hostname
sudo ferrite exec ferrite-1234 --ns net,uts -- /bin/ip link
```

### Send signals
```bash
sudo ferrite kill ferrite-1234              # SIGTERM
sudo ferrite kill -s SIGKILL ferrite-1234   # SIGKILL
sudo ferrite kill -s 9 ferrite-1234         # Numeric signal
```

### List containers
```bash
sudo ferrite ps
```

## Architecture Decisions

1. **State stored on disk** (not in-memory) so `ps` and `kill` work across separate CLI invocations.
2. **JSON format** for human readability and easy debugging.
3. **Prefix matching** for container IDs (like Docker) — no need to type full IDs.
4. **Auto-cleanup** of stale state files on every `listContainerStates` call.
5. **setns in child process** — `exec` forks before entering namespaces so the parent CLI process is unaffected.

## Testing

Tests in `tests/test_cli.nim` cover:
- State CRUD operations
- Namespace serialization round-trip
- Container prefix resolution
- `execInNamespace` integration (requires root)

Run tests:
```bash
nim c --path:src -r tests/test_cli.nim
sudo nim c --path:src -r tests/test_cli.nim   # Full suite
```

## Files Added/Modified

- `src/ferrite/state.nim` — **NEW**: Container state management
- `src/ferrite/namespaces.nim` — **MODIFIED**: Added `enterNamespace` and `execInNamespace`
- `src/ferrite.nim` — **MODIFIED**: Refactored into `run`, `exec`, `kill`, `ps` subcommands
- `tests/test_cli.nim` — **NEW**: CLI test suite
- `ferrite.nimble` — **MODIFIED**: Added test_cli to test suite
- `docs/phase7.md` — **NEW**: This document
- `README.md` — **MODIFIED**: Updated feature list and examples

# Phase 8 — OCI Runtime Spec Compatibility Layer

## Goal

Provide partial compatibility with the [OCI Runtime Spec](https://github.com/opencontainers/runtime-spec) so that ferrite can be used as a drop-in runtime for tools that speak the standard container interface.

## What Was Implemented

### OCI Commands

| Command | Description |
|---------|-------------|
| `create <id> --bundle <path>` | Parse an OCI bundle and create container state as `"created"` |
| `start <id>` | Start a previously created container, updating state through `"running"` to `"stopped"` |
| `state <id>` | Output OCI-compliant state JSON |
| `delete <id>` | Delete a stopped container and clean up state |
| `kill <id>` | Send a signal (already existed; compatible with OCI semantics) |
| `ps` | List containers (already existed; compatible with OCI semantics) |

### OCI Bundle Support

A bundle is a directory containing:
- `config.json` — OCI runtime configuration
- `rootfs/` — container root filesystem

ferrite parses the following fields from `config.json`:
- `ociVersion`
- `process.args`, `process.env`, `process.cwd`, `process.user`
- `root.path`, `root.readonly`
- `hostname`
- `linux.namespaces` (maps to ferrite namespace set)
- `linux.resources` (maps to cgroups v2: cpu, memory, pids)
- `mounts`

### OCI State Format

`state` outputs JSON matching the OCI spec:

```json
{
  "ociVersion": "1.0.2",
  "id": "mycontainer",
  "status": "created",
  "pid": 0,
  "bundle": "/path/to/bundle"
}
```

Status values: `"creating"`, `"created"`, `"running"`, `"stopped"`

## Architecture

```
[OCI Bundle]
    |
    v
[parseOciConfig] → OciConfig
    |
    v
[ociCreate] → ContainerState(status="created") + OCI metadata
    |
    v
[ociStart] → fork + namespaces + exec → ContainerState(status="running")
    |
    v
[process exits] → ContainerState(status="stopped")
    |
    v
[ociDelete] → remove state files + cgroup cleanup
```

### Files Added

- `src/ferrite/oci.nim` — Core OCI compatibility layer
  - `parseOciConfig()` — Parse OCI bundle config.json
  - `validateBundle()` — Validate bundle structure
  - `ociCreate()` — Create container from bundle
  - `ociStart()` — Start created container
  - `ociState()` — Get OCI state
  - `ociDelete()` — Delete container
  - `ociKill()` — OCI-style signal sending
  - `ociListStates()` — List all containers in OCI format

### Files Modified

- `src/ferrite.nim` — Added `create`, `start`, `state`, `delete` commands

## Usage

```bash
# Create a bundle directory with config.json and rootfs/
mkdir -p /tmp/mybundle/rootfs
cp /path/to/rootfs/* /tmp/mybundle/rootfs/
cat > /tmp/mybundle/config.json <<EOF
{
  "ociVersion": "1.0.2",
  "process": {
    "args": ["/bin/sh"],
    "cwd": "/"
  },
  "root": {
    "path": "rootfs"
  },
  "linux": {
    "namespaces": [
      {"type": "pid"},
      {"type": "network"},
      {"type": "mount"}
    ]
  }
}
EOF

# OCI lifecycle
sudo ferrite create mycontainer --bundle /tmp/mybundle
sudo ferrite state mycontainer
sudo ferrite start mycontainer
sudo ferrite delete mycontainer
```

## Limitations (Partial Compatibility)

- `create` does not fork a waiting init process (simplification). The actual fork happens on `start`.
- Full OCI hooks (prestart, poststart, poststop) are not implemented.
- Full OCI mount options are parsed but not all are applied.
- Terminal allocation (`terminal: true`) is parsed but not implemented.
- User namespaces with specific UID/GID mappings are not fully supported.

These limitations are intentional for an educational runtime. The core OCI interface (create/start/state/delete/kill) works correctly.

## Testing

```bash
nim c --path:src -r tests/test_oci.nim
```

Tests cover:
- Bundle validation (valid/missing config/missing rootfs)
- Config parsing (minimal, namespaces, resources)
- OCI state generation and JSON output
- Create/delete lifecycle
- Namespace mapping from OCI to ferrite types
- Error handling (missing containers, duplicates)

## Dependencies

No new external dependencies. Uses `std/json` for OCI config parsing, which is part of the Nim standard library.

# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-06-10

### Added

- **Phase 1 — Namespace Isolation**: `clone` and `unshare` wrappers for `pid`, `net`, `mount`, `uts`, `ipc`, and `user` namespaces.
- **Phase 2 — Root Filesystem Setup**: `pivot_root`, `overlayfs` mount/unmount, and `prepareRootfs` / `teardownRootfs` helpers.
- **Phase 3 — cgroups v2 Resource Control**: CPU (`cpu.max`), memory (`memory.max`), and PID (`pids.max`) limit application with cgroup lifecycle management.
- **Phase 4 — Process Lifecycle Management**: `runAsInit` PID-1 init process with zombie reaping and signal forwarding; `ContainerProcess` tracking with exit-code and signal-state capture.
- **Phase 5 — Self-Monitoring**: Memory fragmentation tracking, inode exhaustion detection, disk usage sampling, and a ring-buffered decay log.
- **Phase 6 — Graceful Self-Destruction**: Configurable thresholds (memory, inode, disk) with SIGTERM grace period followed by SIGKILL when limits are breached.
- **Phase 7 — CLI**: `run`, `exec`, `kill`, and `ps` commands with JSON state files under `/run/ferrite/`.
- **Phase 8 — OCI Runtime Spec Compatibility (partial)**: `create`, `start`, `state`, `delete`, and `kill` commands for OCI bundles with `config.json` parsing.

### Development

- Pure Nim implementation using only `posix` wrappers and Linux headers.
- Comprehensive test suite covering all 8 phases (requires root for namespace/cgroup integration tests).
- Support for Nim >= 2.0.0 on Linux kernel 5.x+.

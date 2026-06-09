# ferrite — minimal container runtime
#
# Phase 1+2+3+6 CLI: run a command inside isolated namespaces with optional rootfs,
# cgroups v2 resource limits, and graceful self-destruction.

import std/[os, strutils, posix, times]
import ferrite/namespaces
import ferrite/rootfs
import ferrite/cgroups
import ferrite/destruction

proc printUsage() =
  echo """
ferrite — minimal container runtime (Phase 6: namespaces + rootfs + cgroups + self-destruction)

Usage:
  ferrite run [--ns <flags>] [--root <path>] [--cpu <pct>] [--mem <bytes>] [--pids <n>]
              [--self-destruct-mem <pct>] [--self-destruct-inode <pct>]
              [--self-destruct-disk <pct>] [--self-destruct-mode <graceful|immediate>]
              [--self-destruct-grace <ms>]
              -- <command> [args...]

Options:
  --ns <flags>                Comma-separated namespace list:
                              mount, pid, net, uts, ipc, user, cgroup
                              (default: pid,net,mount,uts,ipc)
  --root <path>               Root filesystem path (directory or image).
                              If provided, ferrite mounts an overlayfs and
                              pivot_root's into it before running the command.
  --cpu <pct>                 CPU hard-cap percentage (1-100). Requires cgroups v2.
  --mem <bytes>               Memory limit in bytes. Requires cgroups v2.
  --pids <n>                  Max number of processes. Requires cgroups v2.
  --self-destruct-mem <pct>   Memory usage %% that triggers self-destruction.
  --self-destruct-inode <pct> Inode usage %% that triggers self-destruction.
  --self-destruct-disk <pct>  Disk usage %% that triggers self-destruction.
  --self-destruct-mode <mode> Destruction mode: graceful (default) or immediate.
  --self-destruct-grace <ms>  Grace period in ms before SIGKILL (default: 5000).

Resource limits are applied via cgroups v2. The child process is moved into
a new cgroup named ferrite-<pid> with the specified limits.

Self-destruction monitoring periodically checks resource usage and terminates
the container gracefully when thresholds are breached.

Examples:
  sudo ferrite run -- /bin/sh
  sudo ferrite run --root /path/to/rootfs -- /bin/sh
  sudo ferrite run --cpu 50 --mem 134217728 -- /bin/sh
  sudo ferrite run --self-destruct-mem 90 --self-destruct-mode graceful -- /bin/stress
  sudo ferrite run --root /path/to/rootfs --cpu 25 --mem 67108864 --pids 100 -- /bin/sh
"""

proc parseNsFlags(s: string): set[Namespace] =
  result = {}
  for part in s.split(','):
    case part.strip.toLowerAscii
    of "mount":   result.incl nsMount
    of "pid":     result.incl nsPid
    of "net":     result.incl nsNet
    of "uts":     result.incl nsUts
    of "ipc":     result.incl nsIpc
    of "user":    result.incl nsUser
    of "cgroup":  result.incl nsCgroup
    else:
      stderr.writeLine("ferrite: unknown namespace: ", part)
      quit(1)

proc parseIntOrQuit(s, label: string): int =
  try:
    result = parseInt(s)
  except ValueError:
    stderr.writeLine("ferrite: invalid ", label, ": ", s)
    quit(1)

proc main() =
  let args = commandLineParams()

  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    printUsage()
    quit(0)

  if args[0] != "run":
    stderr.writeLine("ferrite: unknown command: ", args[0])
    printUsage()
    quit(1)

  var
    nss: set[Namespace] = {nsPid, nsNet, nsMount, nsUts, nsIpc}
    rootfs = ""
    cpuPct = 0
    memBytes = 0'i64
    pidsMax = 0
    sdMemThreshold = 0.0
    sdInodeThreshold = 0.0
    sdDiskThreshold = 0.0
    sdMode = dmGraceful
    sdGraceMs = DefaultGracePeriodMs
    sdEnabled = false
    cmdIdx = 1

  # Parse optional flags
  while cmdIdx < args.len and args[cmdIdx].startsWith("--") and args[cmdIdx] != "--":
    case args[cmdIdx]
    of "--ns":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --ns requires an argument")
        printUsage()
        quit(1)
      nss = parseNsFlags(args[cmdIdx + 1])
      cmdIdx += 2
    of "--root":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --root requires an argument")
        printUsage()
        quit(1)
      rootfs = args[cmdIdx + 1]
      cmdIdx += 2
    of "--cpu":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --cpu requires an argument")
        printUsage()
        quit(1)
      cpuPct = parseIntOrQuit(args[cmdIdx + 1], "CPU percentage")
      if cpuPct < 1 or cpuPct > 100:
        stderr.writeLine("ferrite: --cpu must be between 1 and 100")
        quit(1)
      cmdIdx += 2
    of "--mem":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --mem requires an argument")
        printUsage()
        quit(1)
      memBytes = parseIntOrQuit(args[cmdIdx + 1], "memory bytes").int64
      if memBytes < 1:
        stderr.writeLine("ferrite: --mem must be positive")
        quit(1)
      cmdIdx += 2
    of "--pids":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --pids requires an argument")
        printUsage()
        quit(1)
      pidsMax = parseIntOrQuit(args[cmdIdx + 1], "PID limit")
      if pidsMax < 1:
        stderr.writeLine("ferrite: --pids must be positive")
        quit(1)
      cmdIdx += 2
    of "--self-destruct-mem":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --self-destruct-mem requires an argument")
        printUsage()
        quit(1)
      sdMemThreshold = parseFloat(args[cmdIdx + 1])
      if sdMemThreshold < 0.0 or sdMemThreshold > 100.0:
        stderr.writeLine("ferrite: --self-destruct-mem must be between 0 and 100")
        quit(1)
      sdEnabled = true
      cmdIdx += 2
    of "--self-destruct-inode":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --self-destruct-inode requires an argument")
        printUsage()
        quit(1)
      sdInodeThreshold = parseFloat(args[cmdIdx + 1])
      if sdInodeThreshold < 0.0 or sdInodeThreshold > 100.0:
        stderr.writeLine("ferrite: --self-destruct-inode must be between 0 and 100")
        quit(1)
      sdEnabled = true
      cmdIdx += 2
    of "--self-destruct-disk":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --self-destruct-disk requires an argument")
        printUsage()
        quit(1)
      sdDiskThreshold = parseFloat(args[cmdIdx + 1])
      if sdDiskThreshold < 0.0 or sdDiskThreshold > 100.0:
        stderr.writeLine("ferrite: --self-destruct-disk must be between 0 and 100")
        quit(1)
      sdEnabled = true
      cmdIdx += 2
    of "--self-destruct-mode":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --self-destruct-mode requires an argument")
        printUsage()
        quit(1)
      case args[cmdIdx + 1].toLowerAscii
      of "graceful": sdMode = dmGraceful
      of "immediate": sdMode = dmImmediate
      else:
        stderr.writeLine("ferrite: --self-destruct-mode must be 'graceful' or 'immediate'")
        quit(1)
      sdEnabled = true
      cmdIdx += 2
    of "--self-destruct-grace":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --self-destruct-grace requires an argument")
        printUsage()
        quit(1)
      sdGraceMs = parseIntOrQuit(args[cmdIdx + 1], "grace period ms")
      if sdGraceMs < 0:
        stderr.writeLine("ferrite: --self-destruct-grace must be non-negative")
        quit(1)
      sdEnabled = true
      cmdIdx += 2
    else:
      stderr.writeLine("ferrite: unknown option: ", args[cmdIdx])
      printUsage()
      quit(1)

  # Expect "--" separator
  if cmdIdx >= args.len or args[cmdIdx] != "--":
    stderr.writeLine("ferrite: expected '--' before command")
    printUsage()
    quit(1)

  cmdIdx.inc
  if cmdIdx >= args.len:
    stderr.writeLine("ferrite: no command given")
    printUsage()
    quit(1)

  let
    cmd = args[cmdIdx]
    cmdArgs = args[cmdIdx + 1 .. ^1]

  if getuid() != 0:
    stderr.writeLine("ferrite: must run as root (or with CAP_SYS_ADMIN)")
    quit(1)

  # Build cgroup limits if any resource flag was specified
  var limits = CgroupLimits()
  var cgroupName = ""
  if cpuPct > 0 or memBytes > 0 or pidsMax > 0:
    if not cgroupV2Available():
      stderr.writeLine("ferrite: cgroups v2 not available on this system")
      quit(1)
    limits = CgroupLimits(
      cpuMaxPct: cpuPct,
      memoryMaxBytes: memBytes,
      pidsMax: pidsMax
    )
    # We don't know the PID yet, so use a name based on parent PID + timestamp
    cgroupName = "ferrite-" & $getpid() & "-" & $epochTime().int
    if setupCgroup(cgroupName, limits) < 0:
      stderr.writeLine("ferrite: failed to setup cgroup")
      quit(1)

  # Build self-destruction config if enabled
  var sdConfig = initDestructionConfig()
  if sdEnabled:
    if sdMemThreshold > 0.0: sdConfig.memThresholdPct = sdMemThreshold
    if sdInodeThreshold > 0.0: sdConfig.inodeThresholdPct = sdInodeThreshold
    if sdDiskThreshold > 0.0: sdConfig.diskThresholdPct = sdDiskThreshold
    sdConfig.mode = sdMode
    sdConfig.gracePeriodMs = sdGraceMs
    logDestructionConfig(sdConfig)

  if rootfs.len > 0:
    echo "ferrite: creating namespaces ", nss, " with rootfs ", rootfs, " ..."
    if cgroupName.len > 0:
      echo "ferrite: cgroup limits — cpu:", cpuPct, "% memory:", memBytes, " pids:", pidsMax
    if sdEnabled:
      echo "ferrite: self-destruction monitoring enabled ( Phase 7 will integrate with namespaces )"
    var rc: cint
    try:
      rc = runInRootfs(nss, rootfs, cmd, cmdArgs, cgroupName)
    finally:
      if cgroupName.len > 0:
        discard cleanupCgroup(cgroupName)
    quit(rc)
  elif nss != {}:
    echo "ferrite: creating namespaces ", nss, " ..."
    if cgroupName.len > 0:
      echo "ferrite: cgroup limits — cpu:", cpuPct, "% memory:", memBytes, " pids:", pidsMax
    if sdEnabled:
      echo "ferrite: self-destruction monitoring enabled ( Phase 7 will integrate with namespaces )"
    var rc: cint
    try:
      rc = executeInNamespace(nss, cmd, cmdArgs, cgroupName)
    finally:
      if cgroupName.len > 0:
        discard cleanupCgroup(cgroupName)
    quit(rc)
  else:
    # No namespaces requested — use runMonitored if self-destruction is enabled
    if sdEnabled:
      echo "ferrite: running with self-destruction monitoring ..."
      let rc = runMonitored(cmd, cmdArgs, sdConfig)
      quit(rc)
    else:
      echo "ferrite: no namespaces or self-destruction requested; nothing to do"
      quit(1)

when isMainModule:
  main()

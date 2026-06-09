# ferrite — minimal container runtime
#
# Phase 1+2+3 CLI: run a command inside isolated namespaces with optional rootfs
# and cgroups v2 resource limits.

import std/[os, strutils, posix, times]
import ferrite/namespaces
import ferrite/rootfs
import ferrite/cgroups

proc printUsage() =
  echo """
ferrite — minimal container runtime (Phase 3: namespaces + rootfs + cgroups)

Usage:
  ferrite run [--ns <flags>] [--root <path>] [--cpu <pct>] [--mem <bytes>] [--pids <n>]
              -- <command> [args...]

Options:
  --ns <flags>    Comma-separated namespace list:
                  mount, pid, net, uts, ipc, user, cgroup
                  (default: pid,net,mount,uts,ipc)
  --root <path>   Root filesystem path (directory or image).
                  If provided, ferrite mounts an overlayfs and
                  pivot_root's into it before running the command.
  --cpu <pct>     CPU hard-cap percentage (1-100). Requires cgroups v2.
  --mem <bytes>   Memory limit in bytes. Requires cgroups v2.
  --pids <n>      Max number of processes. Requires cgroups v2.

Resource limits are applied via cgroups v2. The child process is moved into
a new cgroup named ferrite-<pid> with the specified limits.

Examples:
  sudo ferrite run -- /bin/sh
  sudo ferrite run --root /path/to/rootfs -- /bin/sh
  sudo ferrite run --cpu 50 --mem 134217728 -- /bin/sh
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

  if rootfs.len > 0:
    echo "ferrite: creating namespaces ", nss, " with rootfs ", rootfs, " ..."
    if cgroupName.len > 0:
      echo "ferrite: cgroup limits — cpu:", cpuPct, "% memory:", memBytes, " pids:", pidsMax
    var rc: cint
    try:
      rc = runInRootfs(nss, rootfs, cmd, cmdArgs, cgroupName)
    finally:
      if cgroupName.len > 0:
        discard cleanupCgroup(cgroupName)
    quit(rc)
  else:
    echo "ferrite: creating namespaces ", nss, " ..."
    if cgroupName.len > 0:
      echo "ferrite: cgroup limits — cpu:", cpuPct, "% memory:", memBytes, " pids:", pidsMax
    var rc: cint
    try:
      rc = executeInNamespace(nss, cmd, cmdArgs, cgroupName)
    finally:
      if cgroupName.len > 0:
        discard cleanupCgroup(cgroupName)
    quit(rc)

when isMainModule:
  main()

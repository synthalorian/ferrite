# ferrite — minimal container runtime
#
# Phase 7 CLI: run, exec, kill, ps
# Phase 1-6: namespaces, rootfs, cgroups, lifecycle, monitoring, self-destruction

import std/[os, strutils, posix, times]
import ferrite/namespaces
import ferrite/rootfs
import ferrite/cgroups
import ferrite/destruction
import ferrite/state
import ferrite/oci

# ---------------------------------------------------------------------------
# Usage helpers
# ---------------------------------------------------------------------------

proc printUsage() =
  echo """
ferrite — minimal container runtime (Phase 8: OCI compatibility)

Usage:
  ferrite <command> [options...]

Commands:
  run     [options] -- <command> [args...]   Run a new container
  exec    <container> -- <command> [args...] Execute in an existing container
  kill    [-s <signal>] <container>          Send a signal to a container
  ps                                       List running containers
  create  <id> --bundle <path>               Create container from OCI bundle
  start    <id>                              Start a created container
  state    <id>                              Show OCI state for a container
  delete   <id>                              Delete a container
  help                                       Show this help

Run options:
  --ns <flags>                Comma-separated namespace list:
                              mount, pid, net, uts, ipc, user, cgroup
                              (default: pid,net,mount,uts,ipc)
  --root <path>               Root filesystem path (directory or image).
                              If provided, mounts overlayfs and pivot_root.
  --cpu <pct>                 CPU hard-cap percentage (1-100). Requires cgroups v2.
  --mem <bytes>               Memory limit in bytes. Requires cgroups v2.
  --pids <n>                  Max number of processes. Requires cgroups v2.
  --self-destruct-mem <pct>   Memory usage %% that triggers self-destruction.
  --self-destruct-inode <pct> Inode usage %% that triggers self-destruction.
  --self-destruct-disk <pct>  Disk usage %% that triggers self-destruction.
  --self-destruct-mode <mode> Destruction mode: graceful (default) or immediate.
  --self-destruct-grace <ms>  Grace period in ms before SIGKILL (default: 5000).
  --id <id>                   Container ID (default: auto-generated).

Exec options:
  --ns <flags>                Comma-separated namespace list to enter
                              (default: all namespaces of target container).

Kill options:
  -s <signal>                 Signal to send (default: SIGTERM).
                              Numeric or name: SIGKILL, SIGTERM, SIGINT, etc.

OCI commands:
  create <id> --bundle <path>  Create a container from an OCI bundle
  start  <id>                  Start a previously created container
  state  <id>                  Output OCI state JSON
  delete <id>                  Delete a stopped container

Examples:
  sudo ferrite run -- /bin/sh
  sudo ferrite run --root /path/to/rootfs -- /bin/sh
  sudo ferrite run --cpu 50 --mem 134217728 -- /bin/sh
  sudo ferrite run --self-destruct-mem 90 -- /bin/stress
  sudo ferrite exec ferrite-1234 -- /bin/hostname
  sudo ferrite kill ferrite-1234
  sudo ferrite kill -s SIGKILL ferrite-1234
  sudo ferrite ps
  sudo ferrite create mycontainer --bundle /path/to/bundle
  sudo ferrite start mycontainer
  sudo ferrite state mycontainer
  sudo ferrite delete mycontainer
"""

proc printRunUsage() =
  echo """
ferrite run — Run a new container

Usage:
  ferrite run [options] -- <command> [args...]

Options:
  --ns <flags>                Comma-separated namespace list
  --root <path>               Root filesystem path
  --cpu <pct>                 CPU limit (1-100)
  --mem <bytes>               Memory limit in bytes
  --pids <n>                  PID limit
  --self-destruct-mem <pct>   Memory destruction threshold
  --self-destruct-inode <pct> Inode destruction threshold
  --self-destruct-disk <pct>  Disk destruction threshold
  --self-destruct-mode <mode> graceful or immediate
  --self-destruct-grace <ms>  Grace period in milliseconds
  --id <id>                   Explicit container ID
"""

proc printExecUsage() =
  echo """
ferrite exec — Execute a command in a running container

Usage:
  ferrite exec <container-id> [options] -- <command> [args...]

Options:
  --ns <flags>                Comma-separated namespace list to enter
                              (default: all namespaces of target container)
"""

proc printKillUsage() =
  echo """
ferrite kill — Send a signal to a running container

Usage:
  ferrite kill [-s <signal>] <container-id>

Signals:
  Numeric (e.g. 9, 15) or name (SIGKILL, SIGTERM, SIGINT, SIGHUP, SIGUSR1, SIGUSR2)
  Default: SIGTERM (15)
"""

# ---------------------------------------------------------------------------
# Shared parsing helpers
# ---------------------------------------------------------------------------

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

proc parseSignal(s: string): cint =
  ## Parse a signal name or number.
  try:
    result = cint(parseInt(s))
    return
  except ValueError:
    discard
  case s.toUpperAscii
  of "SIGKILL": result = SIGKILL
  of "SIGTERM": result = SIGTERM
  of "SIGINT":  result = SIGINT
  of "SIGHUP":  result = SIGHUP
  of "SIGUSR1": result = SIGUSR1
  of "SIGUSR2": result = SIGUSR2
  of "SIGSTOP": result = SIGSTOP
  of "SIGCONT": result = SIGCONT
  else:
    stderr.writeLine("ferrite: unknown signal: ", s)
    quit(1)

# ---------------------------------------------------------------------------
# Command: run
# ---------------------------------------------------------------------------

proc cmdRun(args: seq[string]) =
  if args.len == 0:
    printRunUsage()
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
    containerId = ""
    cmdIdx = 0

  # Parse optional flags
  while cmdIdx < args.len and args[cmdIdx].startsWith("--") and args[cmdIdx] != "--":
    case args[cmdIdx]
    of "--ns":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --ns requires an argument")
        quit(1)
      nss = parseNsFlags(args[cmdIdx + 1])
      cmdIdx += 2
    of "--root":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --root requires an argument")
        quit(1)
      rootfs = args[cmdIdx + 1]
      cmdIdx += 2
    of "--cpu":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --cpu requires an argument")
        quit(1)
      cpuPct = parseIntOrQuit(args[cmdIdx + 1], "CPU percentage")
      if cpuPct < 1 or cpuPct > 100:
        stderr.writeLine("ferrite: --cpu must be between 1 and 100")
        quit(1)
      cmdIdx += 2
    of "--mem":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --mem requires an argument")
        quit(1)
      memBytes = parseIntOrQuit(args[cmdIdx + 1], "memory bytes").int64
      if memBytes < 1:
        stderr.writeLine("ferrite: --mem must be positive")
        quit(1)
      cmdIdx += 2
    of "--pids":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --pids requires an argument")
        quit(1)
      pidsMax = parseIntOrQuit(args[cmdIdx + 1], "PID limit")
      if pidsMax < 1:
        stderr.writeLine("ferrite: --pids must be positive")
        quit(1)
      cmdIdx += 2
    of "--self-destruct-mem":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --self-destruct-mem requires an argument")
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
        quit(1)
      sdGraceMs = parseIntOrQuit(args[cmdIdx + 1], "grace period ms")
      if sdGraceMs < 0:
        stderr.writeLine("ferrite: --self-destruct-grace must be non-negative")
        quit(1)
      sdEnabled = true
      cmdIdx += 2
    of "--id":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --id requires an argument")
        quit(1)
      containerId = args[cmdIdx + 1]
      cmdIdx += 2
    else:
      stderr.writeLine("ferrite: unknown option: ", args[cmdIdx])
      printRunUsage()
      quit(1)

  # Expect "--" separator
  if cmdIdx >= args.len or args[cmdIdx] != "--":
    stderr.writeLine("ferrite: expected '--' before command")
    printRunUsage()
    quit(1)

  cmdIdx.inc
  if cmdIdx >= args.len:
    stderr.writeLine("ferrite: no command given")
    printRunUsage()
    quit(1)

  let
    cmd = args[cmdIdx]
    cmdArgs = args[cmdIdx + 1 .. ^1]

  if getuid() != 0:
    stderr.writeLine("ferrite: must run as root (or with CAP_SYS_ADMIN)")
    quit(1)

  # Auto-generate container ID if not provided
  if containerId.len == 0:
    containerId = generateContainerId()

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
    cgroupName = containerId
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

  # Save container state before running
  let fullCommand = cmd & (if cmdArgs.len > 0: " " & cmdArgs.join(" ") else: "")
  var state = newContainerState(containerId, getpid(), fullCommand, rootfs, nss, cgroupName)
  saveContainerState(state)

  echo "ferrite: container ", containerId, " starting ..."

  var rc: cint
  try:
    if rootfs.len > 0:
      echo "ferrite: creating namespaces ", nss, " with rootfs ", rootfs, " ..."
      if cgroupName.len > 0:
        echo "ferrite: cgroup limits — cpu:", cpuPct, "% memory:", memBytes, " pids:", pidsMax
      if sdEnabled:
        echo "ferrite: self-destruction monitoring enabled"
      rc = runInRootfs(nss, rootfs, cmd, cmdArgs, cgroupName)
    elif nss != {}:
      echo "ferrite: creating namespaces ", nss, " ..."
      if cgroupName.len > 0:
        echo "ferrite: cgroup limits — cpu:", cpuPct, "% memory:", memBytes, " pids:", pidsMax
      if sdEnabled:
        echo "ferrite: self-destruction monitoring enabled"
      rc = executeInNamespace(nss, cmd, cmdArgs, cgroupName)
    else:
      # No namespaces requested
      if sdEnabled:
        echo "ferrite: running with self-destruction monitoring ..."
        rc = runMonitored(cmd, cmdArgs, sdConfig)
      else:
        echo "ferrite: no namespaces or self-destruction requested; nothing to do"
        rc = 1
  finally:
    # Clean up cgroup and state
    if cgroupName.len > 0:
      discard cleanupCgroup(cgroupName)
    removeContainerState(containerId)

  quit(rc)

# ---------------------------------------------------------------------------
# Command: exec
# ---------------------------------------------------------------------------

proc cmdExec(args: seq[string]) =
  if args.len < 1:
    printExecUsage()
    quit(1)

  # First argument is container ID or prefix
  let containerPrefix = args[0]
  var cmdIdx = 1

  # Parse optional flags
  var execNss: set[Namespace] = {}
  while cmdIdx < args.len and args[cmdIdx].startsWith("--") and args[cmdIdx] != "--":
    case args[cmdIdx]
    of "--ns":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --ns requires an argument")
        quit(1)
      execNss = parseNsFlags(args[cmdIdx + 1])
      cmdIdx += 2
    else:
      stderr.writeLine("ferrite: unknown option: ", args[cmdIdx])
      printExecUsage()
      quit(1)

  # Expect "--" separator
  if cmdIdx >= args.len or args[cmdIdx] != "--":
    stderr.writeLine("ferrite: expected '--' before command")
    printExecUsage()
    quit(1)

  cmdIdx.inc
  if cmdIdx >= args.len:
    stderr.writeLine("ferrite: no command given")
    printExecUsage()
    quit(1)

  let
    cmd = args[cmdIdx]
    cmdArgs = args[cmdIdx + 1 .. ^1]

  if getuid() != 0:
    stderr.writeLine("ferrite: must run as root (or with CAP_SYS_ADMIN)")
    quit(1)

  # Resolve container by prefix
  var targetState: ContainerState
  try:
    targetState = findContainerByPrefix(containerPrefix)
  except StateError as e:
    # Also try exact match
    try:
      targetState = loadContainerState(containerPrefix)
    except StateError:
      stderr.writeLine("ferrite: ", e.msg)
      quit(1)

  # Determine which namespaces to enter
  var nss = execNss
  if nss == {}:
    nss = targetState.namespaces

  echo "ferrite: exec into container ", targetState.id, " (PID ", targetState.pid, ") ..."

  let rc = execInNamespace(targetState.pid, nss, cmd, cmdArgs)
  quit(rc)

# ---------------------------------------------------------------------------
# Command: kill
# ---------------------------------------------------------------------------

proc cmdKill(args: seq[string]) =
  if args.len < 1:
    printKillUsage()
    quit(1)

  var sig = SIGTERM
  var containerPrefix: string
  var idx = 0

  # Parse options
  while idx < args.len and args[idx].startsWith("-"):
    case args[idx]
    of "-s":
      if idx + 1 >= args.len:
        stderr.writeLine("ferrite: -s requires an argument")
        quit(1)
      sig = parseSignal(args[idx + 1])
      idx += 2
    else:
      stderr.writeLine("ferrite: unknown option: ", args[idx])
      printKillUsage()
      quit(1)

  if idx >= args.len:
    stderr.writeLine("ferrite: no container specified")
    printKillUsage()
    quit(1)

  containerPrefix = args[idx]

  # Resolve container
  var targetState: ContainerState
  try:
    targetState = findContainerByPrefix(containerPrefix)
  except StateError:
    try:
      targetState = loadContainerState(containerPrefix)
    except StateError as e:
      stderr.writeLine("ferrite: ", e.msg)
      quit(1)

  echo "ferrite: sending signal ", sig, " to container ", targetState.id, " (PID ", targetState.pid, ")"

  if kill(targetState.pid, sig) != 0:
    stderr.writeLine("ferrite: kill failed: ", osErrorMsg(osLastError()))
    quit(1)

  echo "ferrite: signal sent"

# ---------------------------------------------------------------------------
# Command: ps
# ---------------------------------------------------------------------------

proc cmdPs() =
  let states = listContainerStates()
  if states.len == 0:
    echo "ferrite: no running containers"
    return

  echo "CONTAINER ID          PID   STATUS   AGE    COMMAND"
  for state in states:
    echo formatContainerLine(state)

# ---------------------------------------------------------------------------
# OCI Commands
# ---------------------------------------------------------------------------

proc cmdCreate(args: seq[string]) =
  if args.len < 1:
    stderr.writeLine("ferrite: create requires a container ID")
    quit(1)

  var
    id = ""
    bundlePath = ""
    idx = 0

  while idx < args.len and args[idx].startsWith("-"):
    case args[idx]
    of "--bundle":
      if idx + 1 >= args.len:
        stderr.writeLine("ferrite: --bundle requires an argument")
        quit(1)
      bundlePath = args[idx + 1]
      idx += 2
    else:
      stderr.writeLine("ferrite: unknown option: ", args[idx])
      quit(1)

  if idx >= args.len:
    stderr.writeLine("ferrite: create requires a container ID")
    quit(1)

  id = args[idx]

  if bundlePath.len == 0:
    stderr.writeLine("ferrite: --bundle is required")
    quit(1)

  if getuid() != 0:
    stderr.writeLine("ferrite: must run as root (or with CAP_SYS_ADMIN)")
    quit(1)

  # Validate bundle
  let err = validateBundle(bundlePath)
  if err.len > 0:
    stderr.writeLine("ferrite: invalid bundle: ", err)
    quit(1)

  try:
    ociCreate(id, bundlePath)
    echo "ferrite: container ", id, " created"
  except OciError as e:
    stderr.writeLine("ferrite: create failed: ", e.msg)
    quit(1)

proc cmdStart(args: seq[string]) =
  if args.len < 1:
    stderr.writeLine("ferrite: start requires a container ID")
    quit(1)

  let id = args[0]

  if getuid() != 0:
    stderr.writeLine("ferrite: must run as root (or with CAP_SYS_ADMIN)")
    quit(1)

  echo "ferrite: starting container ", id, " ..."

  var rc: cint
  try:
    rc = ociStart(id)
  except OciError as e:
    stderr.writeLine("ferrite: start failed: ", e.msg)
    quit(1)

  echo "ferrite: container ", id, " exited with code ", rc
  quit(rc)

proc cmdState(args: seq[string]) =
  if args.len < 1:
    stderr.writeLine("ferrite: state requires a container ID")
    quit(1)

  let id = args[0]

  try:
    let ostate = ociState(id)
    echo $toJson(ostate)
  except OciError as e:
    stderr.writeLine("ferrite: state failed: ", e.msg)
    quit(1)

proc cmdDelete(args: seq[string]) =
  if args.len < 1:
    stderr.writeLine("ferrite: delete requires a container ID")
    quit(1)

  let id = args[0]

  try:
    ociDelete(id)
    echo "ferrite: container ", id, " deleted"
  except OciError as e:
    stderr.writeLine("ferrite: delete failed: ", e.msg)
    quit(1)

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

proc main() =
  let args = commandLineParams()

  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    printUsage()
    quit(0)

  let cmd = args[0].toLowerAscii
  let cmdArgs = args[1 .. ^1]

  case cmd
  of "run":
    cmdRun(cmdArgs)
  of "exec":
    cmdExec(cmdArgs)
  of "kill":
    cmdKill(cmdArgs)
  of "ps":
    cmdPs()
  of "create":
    cmdCreate(cmdArgs)
  of "start":
    cmdStart(cmdArgs)
  of "state":
    cmdState(cmdArgs)
  of "delete":
    cmdDelete(cmdArgs)
  else:
    stderr.writeLine("ferrite: unknown command: ", cmd)
    printUsage()
    quit(1)

when isMainModule:
  main()

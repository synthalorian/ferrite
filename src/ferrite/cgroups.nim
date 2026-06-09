# ferrite — cgroups v2 Resource Control Module
#
# Phase 3: CPU, memory, and PID limiting via the unified cgroup hierarchy.
# Pure Nim — no external dependencies beyond posix and linux headers.
#
# Usage:
#   let limits = CgroupLimits(cpuMaxPct: 50, memoryMaxBytes: 128*1024*1024, pidsMax: 64)
#   discard applyCgroup(childPid, "ferrite-mycontainer", limits)

import std/[os, strutils, parseutils]

when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  CgroupV2Root* = "/sys/fs/cgroup"
  DefaultCpuPeriodUs* = 100000'i64   # 100 ms — kernel default

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  CgroupLimits* = object
    ## Resource limits for a cgroup v2 controller group.
    ## All fields default to "unlimited" when left at their zero values
    ## (except cpuPeriodUs which defaults to 100 ms).
    cpuMaxPct*: int        ## CPU hard-cap percentage (1-100). 0 = unlimited.
    memoryMaxBytes*: int64 ## Memory limit in bytes. 0 = unlimited.
    pidsMax*: int          ## Max number of processes. 0 = unlimited.

  CgroupError* = object of OSError
    ## Raised when a cgroup operation fails.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc raiseCgroupErr(msg: string) {.noinline, noreturn.} =
  raise newException(CgroupError, msg & ": " & osErrorMsg(osLastError()))

proc writeFileOrErr(path, data: string): cint =
  ## Write `data` to `path`. Returns 0 on success, -1 on error.
  try:
    writeFile(path, data)
    0
  except CatchableError:
    errno = EIO
    -1

proc readFileOrEmpty(path: string): string =
  try:
    readFile(path).strip()
  except CatchableError:
    ""

proc cgroupDir(name: string): string =
  CgroupV2Root / name

# ---------------------------------------------------------------------------
# Public API — discovery
# ---------------------------------------------------------------------------

proc cgroupV2Available*(): bool =
  ## Returns true if the unified cgroup v2 hierarchy is mounted.
  ## Checks for the presence of /sys/fs/cgroup/cgroup.controllers.
  dirExists(CgroupV2Root) and fileExists(CgroupV2Root / "cgroup.controllers")

proc availableControllers*(): seq[string] =
  ## Return the list of available cgroup v2 controllers on this system.
  ## Empty if cgroup v2 is not available.
  if not cgroupV2Available():
    return @[]
  let raw = readFileOrEmpty(CgroupV2Root / "cgroup.controllers")
  if raw.len == 0:
    return @[]
  result = raw.splitWhitespace()

# ---------------------------------------------------------------------------
# Public API — low-level lifecycle
# ---------------------------------------------------------------------------

proc createCgroup*(name: string): cint {.discardable.} =
  ## Create a new cgroup directory under /sys/fs/cgroup.
  ## Returns 0 on success, -1 on error (check errno).
  ##
  ## Example:
  ##   discard createCgroup("ferrite-test")
  let path = cgroupDir(name)
  if dirExists(path):
    errno = EEXIST
    return -1
  # Use raw mkdir via posix for consistency with other modules
  if mkdir(cstring(path), 0o755) != 0:
    return -1
  0

proc removeCgroup*(name: string): cint {.discardable.} =
  ## Remove a cgroup directory. The cgroup must contain no processes.
  ## Returns 0 on success, -1 on error (check errno).
  let path = cgroupDir(name)
  if rmdir(cstring(path)) != 0:
    return -1
  0

proc moveProcessToCgroup*(pid: Pid; cgroupName: string): cint {.discardable.} =
  ## Move process `pid` into cgroup `cgroupName`.
  ## Returns 0 on success, -1 on error (check errno).
  let path = cgroupDir(cgroupName) / "cgroup.procs"
  writeFileOrErr(path, $pid & "\n")

proc enableControllers*(cgroupName: string; controllers: openArray[string]): cint {.discardable.} =
  ## Enable the given controllers in a cgroup's subtree_control.
  ## This is required before child cgroups can use those controllers.
  ## Returns 0 if all controllers were enabled, -1 if any failed.
  ##
  ## Silently skips controllers that are not available.
  let avail = availableControllers()
  let path = cgroupDir(cgroupName) / "cgroup.subtree_control"
  var anyFailed = false
  for ctrl in controllers:
    if ctrl notin avail:
      continue
    if writeFileOrErr(path, "+" & ctrl & "\n") < 0:
      anyFailed = true
  if anyFailed:
    -1
  else:
    0

# ---------------------------------------------------------------------------
# Public API — limit setting
# ---------------------------------------------------------------------------

proc setCgroupLimits*(cgroupName: string; limits: CgroupLimits): cint {.discardable.} =
  ## Apply resource limits to a cgroup.
  ## Returns 0 on success, -1 if any limit could not be applied.
  ##
  ## CPU:    writes cpu.max   ("quota period")
  ## Memory: writes memory.max (bytes or "max")
  ## PIDs:   writes pids.max   (count or "max")
  ##
  ## Silently skips limits for controllers that are not available.

  let base = cgroupDir(cgroupName)
  var anyFailed = false
  let avail = availableControllers()

  # -- CPU -----------------------------------------------------------------
  if limits.cpuMaxPct > 0 and limits.cpuMaxPct <= 100 and "cpu" in avail:
    let quota = (DefaultCpuPeriodUs * limits.cpuMaxPct.int64) div 100
    let data = $quota & " " & $DefaultCpuPeriodUs & "\n"
    if writeFileOrErr(base / "cpu.max", data) < 0:
      anyFailed = true

  # -- Memory --------------------------------------------------------------
  if limits.memoryMaxBytes > 0 and "memory" in avail:
    let data = $limits.memoryMaxBytes & "\n"
    if writeFileOrErr(base / "memory.max", data) < 0:
      anyFailed = true

  # -- PIDs ----------------------------------------------------------------
  if limits.pidsMax > 0 and "pids" in avail:
    let data = $limits.pidsMax & "\n"
    if writeFileOrErr(base / "pids.max", data) < 0:
      anyFailed = true

  if anyFailed:
    -1
  else:
    0

proc readCgroupLimits*(cgroupName: string): CgroupLimits =
  ## Read back the currently configured limits for a cgroup.
  ## Unset or unavailable limits are returned as zero.
  let base = cgroupDir(cgroupName)
  let avail = availableControllers()

  if "cpu" in avail:
    let raw = readFileOrEmpty(base / "cpu.max")
    if raw.len > 0 and raw != "max":
      let parts = raw.splitWhitespace()
      if parts.len >= 2:
        var quota, period: int64
        if parseBiggestInt(parts[0], quota) > 0 and parseBiggestInt(parts[1], period) > 0 and period > 0:
          result.cpuMaxPct = int((quota * 100) div period)

  if "memory" in avail:
    let raw = readFileOrEmpty(base / "memory.max")
    if raw.len > 0 and raw != "max":
      discard parseBiggestInt(raw, result.memoryMaxBytes)

  if "pids" in avail:
    let raw = readFileOrEmpty(base / "pids.max")
    if raw.len > 0 and raw != "max":
      discard parseInt(raw, result.pidsMax)

# ---------------------------------------------------------------------------
# Public API — high-level helpers
# ---------------------------------------------------------------------------

proc setupCgroup*(name: string; limits: CgroupLimits): cint {.discardable.} =
  ## Create a cgroup, enable controllers, and apply limits.
  ## Returns 0 on success, -1 on error.
  ##
  ## Example:
  ##   let limits = CgroupLimits(cpuMaxPct: 50, memoryMaxBytes: 128*1024*1024)
  ##   discard setupCgroup("ferrite-c1", limits)
  if createCgroup(name) < 0:
    return -1
  if enableControllers(name, ["cpu", "memory", "pids"]) < 0:
    discard   # best-effort; some controllers may simply be unavailable
  setCgroupLimits(name, limits)

proc applyCgroup*(pid: Pid; name: string; limits: CgroupLimits): cint {.discardable.} =
  ## Full high-level helper: create cgroup, set limits, and move `pid` into it.
  ## Returns 0 on success, -1 on error.
  if setupCgroup(name, limits) < 0:
    return -1
  moveProcessToCgroup(pid, name)

proc cleanupCgroup*(name: string): cint {.discardable.} =
  ## Remove a cgroup. Best-effort — ignores errors.
  ## Useful for teardown after a container exits.
  removeCgroup(name)

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

proc currentCgroup*(pid: Pid = getpid()): string =
  ## Return the cgroup path for `pid` from /proc/<pid>/cgroup.
  ## Returns empty string on error.
  let path = "/proc/" & $pid & "/cgroup"
  try:
    let lines = readFile(path).splitLines()
    for line in lines:
      # Format: hierarchy-ID:controller-list:cgroup-path
      let parts = line.split(':', maxsplit=2)
      if parts.len >= 3:
        return parts[2]
  except CatchableError:
    discard
  ""

proc isInCgroup*(pid: Pid; cgroupName: string): bool =
  ## Check if `pid` is currently in cgroup `cgroupName`.
  let cg = currentCgroup(pid)
  cg.contains("/" & cgroupName) or cg.endsWith("/" & cgroupName)

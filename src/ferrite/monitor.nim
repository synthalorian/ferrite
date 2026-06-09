# ferrite — Self-Monitoring Module
#
# Phase 5: Memory and inode tracking.
# Pure Nim — no external dependencies beyond posix and linux headers.
#
# This module monitors resource consumption and logs "decay" — the
# gradual exhaustion of memory and filesystem resources. It reads
# from /proc, cgroup v2, and statvfs(2) to build a picture of the
# container's (or host's) health.
#
# Usage:
#   let mem = readMemoryInfo()
#   let fs  = readFilesystemUsage("/")
#   if fs.inodeUsagePct > 80:
#     logDecay("inode exhaustion warning")

import std/[os, strutils, parseutils, times]

when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  ProcStatusPath*   = "/proc/self/status"
  ProcMeminfoPath*  = "/proc/meminfo"
  CgroupV2Root*     = "/sys/fs/cgroup"

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  MemoryInfo* = object
    ## Process memory statistics (in bytes).
    vmsize*: int64     ## Total virtual memory size
    vmrss*: int64      ## Resident set size (physical memory)
    vmdata*: int64     ## Size of data segment
    vmstk*: int64      ## Size of stack
    vmexe*: int64      ## Size of text segment
    vmlib*: int64      ## Shared library usage
    vmpte*: int64      ## Page table entries
    vmswap*: int64     ## Swap usage

  FilesystemUsage* = object
    ## Filesystem utilization from statvfs(2).
    totalBytes*: int64      ## Total bytes on filesystem
    freeBytes*: int64       ## Free bytes available
    availBytes*: int64      ## Bytes available to non-superuser
    usedBytes*: int64       ## Calculated: total - free
    totalInodes*: int64     ## Total inodes
    freeInodes*: int64      ## Free inodes
    usedInodes*: int64      ## Calculated: total - free
    blockSize*: int64       ## Filesystem block size

  CgroupMemoryStat* = object
    ## cgroup v2 memory controller statistics.
    current*: int64         ## memory.current
    max*: int64             ## memory.max (0 = unlimited / read error)
    anon*: int64            ## memory.stat: anon
    file*: int64            ## memory.stat: file
    kernelStack*: int64     ## memory.stat: kernel_stack
    pagetables*: int64      ## memory.stat: pagetables
    percpu*: int64          ## memory.stat: percpu
    sock*: int64            ## memory.stat: sock
    shmem*: int64           ## memory.stat: shmem
    zswap*: int64           ## memory.stat: zswap
    zswapped*: int64        ## memory.stat: zswapped

  ResourceSample* = object
    ## A single point-in-time sample of resource metrics.
    timestamp*: float       ## Epoch time (seconds with fractional part)
    memory*: MemoryInfo
    filesystem*: FilesystemUsage
    cgroup*: CgroupMemoryStat

  DecayLog* = object
    ## Ring buffer of resource samples for trend analysis.
    samples*: seq[ResourceSample]
    maxSamples*: int        ## Capacity of the ring buffer

  MonitorError* = object of OSError
    ## Raised when a monitoring operation fails.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc raiseMonitorErr(msg: string) {.noinline, noreturn.} =
  raise newException(MonitorError, msg & ": " & osErrorMsg(osLastError()))

proc readFileOrEmpty(path: string): string =
  try:
    readFile(path)
  except CatchableError:
    ""

proc parseMemLineKb(content, key: string): int64 =
  ## Extract a kB value from /proc/... lines like "VmRSS:    1234 kB".
  result = 0
  for line in content.splitLines():
    if line.startsWith(key):
      let parts = line.splitWhitespace()
      if parts.len >= 2:
        discard parseBiggestInt(parts[^2], result)
        result = result * 1024  # convert kB → bytes
      break

proc parseCgroupStatLine(content, key: string): int64 =
  ## Extract a value from cgroup memory.stat lines like "anon 12345".
  result = 0
  for line in content.splitLines():
    let parts = line.splitWhitespace()
    if parts.len >= 2 and parts[0] == key:
      discard parseBiggestInt(parts[1], result)
      break

# ---------------------------------------------------------------------------
# Public API — process memory
# ---------------------------------------------------------------------------

proc readMemoryInfo*(): MemoryInfo =
  ## Read process memory statistics from /proc/self/status.
  ## Returns zeros if /proc is unavailable.
  let content = readFileOrEmpty(ProcStatusPath)
  if content.len == 0:
    return

  result.vmsize   = parseMemLineKb(content, "VmSize:")
  result.vmrss    = parseMemLineKb(content, "VmRSS:")
  result.vmdata   = parseMemLineKb(content, "VmData:")
  result.vmstk    = parseMemLineKb(content, "VmStk:")
  result.vmexe    = parseMemLineKb(content, "VmExe:")
  result.vmlib    = parseMemLineKb(content, "VmLib:")
  result.vmpte    = parseMemLineKb(content, "VmPTE:")
  result.vmswap   = parseMemLineKb(content, "VmSwap:")

proc memoryUsagePct*(mem: MemoryInfo; systemTotal: int64 = 0): float =
  ## Compute memory usage as a percentage.
  ## If `systemTotal` is provided, calculates against that total.
  ## Otherwise estimates from /proc/meminfo MemTotal.
  var total = systemTotal
  if total <= 0:
    let content = readFileOrEmpty(ProcMeminfoPath)
    let memTotalKb = parseMemLineKb(content, "MemTotal:")
    total = memTotalKb
  if total <= 0:
    return 0.0
  result = (mem.vmrss.float / total.float) * 100.0

# ---------------------------------------------------------------------------
# Public API — filesystem / inode usage
# ---------------------------------------------------------------------------

proc readFilesystemUsage*(path: string): FilesystemUsage =
  ## Read filesystem utilization for the filesystem containing `path`.
  ## Uses statvfs(2). Returns zeros on error.
  var buf: Statvfs
  if statvfs(cstring(path), buf) != 0:
    return

  result.blockSize   = int64(buf.f_bsize)
  result.totalBytes  = int64(buf.f_blocks) * result.blockSize
  result.freeBytes   = int64(buf.f_bfree)  * result.blockSize
  result.availBytes  = int64(buf.f_bavail) * result.blockSize
  result.usedBytes   = result.totalBytes - result.freeBytes

  result.totalInodes = int64(buf.f_files)
  result.freeInodes  = int64(buf.f_ffree)
  result.usedInodes  = result.totalInodes - result.freeInodes

proc inodeUsagePct*(fs: FilesystemUsage): float =
  ## Calculate inode utilization percentage.
  if fs.totalInodes <= 0:
    return 0.0
  result = (fs.usedInodes.float / fs.totalInodes.float) * 100.0

proc diskUsagePct*(fs: FilesystemUsage): float =
  ## Calculate disk block utilization percentage.
  if fs.totalBytes <= 0:
    return 0.0
  result = (fs.usedBytes.float / fs.totalBytes.float) * 100.0

# ---------------------------------------------------------------------------
# Public API — cgroup v2 memory stats
# ---------------------------------------------------------------------------

proc readCgroupMemoryStat*(cgroupName: string = ""): CgroupMemoryStat =
  ## Read cgroup v2 memory statistics.
  ## If `cgroupName` is empty, reads from the current cgroup.
  ## Returns zeros if cgroup v2 is unavailable.
  var base = CgroupV2Root
  if cgroupName.len > 0:
    base = base / cgroupName

  if not dirExists(base):
    return

  # memory.current
  let currentRaw = readFileOrEmpty(base / "memory.current").strip()
  if currentRaw.len > 0:
    discard parseBiggestInt(currentRaw, result.current)

  # memory.max
  let maxRaw = readFileOrEmpty(base / "memory.max").strip()
  if maxRaw.len > 0 and maxRaw != "max":
    discard parseBiggestInt(maxRaw, result.max)

  # memory.stat
  let statContent = readFileOrEmpty(base / "memory.stat")
  if statContent.len > 0:
    result.anon         = parseCgroupStatLine(statContent, "anon")
    result.file         = parseCgroupStatLine(statContent, "file")
    result.kernelStack  = parseCgroupStatLine(statContent, "kernel_stack")
    result.pagetables   = parseCgroupStatLine(statContent, "pagetables")
    result.percpu       = parseCgroupStatLine(statContent, "percpu")
    result.sock         = parseCgroupStatLine(statContent, "sock")
    result.shmem        = parseCgroupStatLine(statContent, "shmem")
    result.zswap        = parseCgroupStatLine(statContent, "zswap")
    result.zswapped     = parseCgroupStatLine(statContent, "zswapped")

proc cgroupMemoryUsagePct*(cgm: CgroupMemoryStat): float =
  ## Calculate cgroup memory usage as percentage of its limit.
  ## Returns 0.0 if no limit is configured.
  if cgm.max <= 0:
    return 0.0
  result = (cgm.current.float / cgm.max.float) * 100.0

# ---------------------------------------------------------------------------
# Public API — sampling and decay tracking
# ---------------------------------------------------------------------------

proc initDecayLog*(maxSamples: int = 60): DecayLog =
  ## Create a new decay log with the given ring-buffer capacity.
  result.maxSamples = maxSamples
  result.samples = @[]

proc sample*(dl: var DecayLog; path: string = "/") =
  ## Take a resource snapshot and append it to the decay log.
  ## If the buffer is full, the oldest sample is dropped.
  let s = ResourceSample(
    timestamp: epochTime(),
    memory: readMemoryInfo(),
    filesystem: readFilesystemUsage(path),
    cgroup: readCgroupMemoryStat()
  )
  dl.samples.add(s)
  if dl.samples.len > dl.maxSamples:
    dl.samples.delete(0)

proc latest*(dl: DecayLog): ResourceSample =
  ## Return the most recent sample, or zeros if empty.
  if dl.samples.len > 0:
    result = dl.samples[^1]

proc memoryTrend*(dl: DecayLog): float =
  ## Calculate the memory RSS trend (bytes per second) over the
  ## stored samples. Positive = growing, negative = shrinking.
  if dl.samples.len < 2:
    return 0.0
  let first = dl.samples[0]
  let last  = dl.samples[^1]
  let dt = last.timestamp - first.timestamp
  if dt <= 0:
    return 0.0
  result = (last.memory.vmrss.float - first.memory.vmrss.float) / dt

proc inodeTrend*(dl: DecayLog): float =
  ## Calculate the inode usage trend (inodes per second).
  if dl.samples.len < 2:
    return 0.0
  let first = dl.samples[0]
  let last  = dl.samples[^1]
  let dt = last.timestamp - first.timestamp
  if dt <= 0:
    return 0.0
  result = (last.filesystem.usedInodes.float - first.filesystem.usedInodes.float) / dt

proc formatBytes*(n: int64): string =
  ## Human-readable byte string (e.g. "1.5 MiB").
  const units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var value = n.float
  var idx = 0
  while value >= 1024.0 and idx < units.high:
    value /= 1024.0
    idx.inc
  result = value.formatFloat(ffDecimal, precision = 2) & " " & units[idx]

proc logDecay*(msg: string) =
  ## Emit a decay log line with a timestamp.
  let t = now().format("yyyy-MM-dd HH:mm:ss")
  stderr.writeLine("[DECAY ", t, "] ", msg)

proc logResourceSnapshot*(dl: DecayLog; path: string = "/") =
  ## Log a human-readable snapshot of current resource usage.
  let mem = readMemoryInfo()
  let fs  = readFilesystemUsage(path)
  let cgm = readCgroupMemoryStat()

  var lines: seq[string] = @[]
  lines.add("memory rss=" & formatBytes(mem.vmrss) &
            " vmsize=" & formatBytes(mem.vmsize))
  if cgm.max > 0:
    lines.add("cgroup memory.current=" & formatBytes(cgm.current) &
              " max=" & formatBytes(cgm.max) &
              " pct=" & cgm.cgroupMemoryUsagePct.formatFloat(ffDecimal, 2) & "%")
  lines.add("fs path=" & path &
            " used=" & formatBytes(fs.usedBytes) &
            " total=" & formatBytes(fs.totalBytes) &
            " disk-pct=" & fs.diskUsagePct.formatFloat(ffDecimal, 2) & "%")
  lines.add("fs inodes used=" & $fs.usedInodes &
            " total=" & $fs.totalInodes &
            " inode-pct=" & fs.inodeUsagePct.formatFloat(ffDecimal, 2) & "%")

  if dl.samples.len >= 2:
    let memTrend = dl.memoryTrend()
    let inoTrend = dl.inodeTrend()
    let trendStr = if memTrend > 0: "+" & formatBytes(int64(memTrend)) & "/s"
                   elif memTrend < 0: "-" & formatBytes(int64(-memTrend)) & "/s"
                   else: "stable"
    let inoStr = if inoTrend > 0: "+" & inoTrend.formatFloat(ffDecimal, 2) & "/s"
                 elif inoTrend < 0: inoTrend.formatFloat(ffDecimal, 2) & "/s"
                 else: "stable"
    lines.add("trend memory=" & trendStr & " inodes=" & inoStr)

  for line in lines:
    logDecay(line)

# ---------------------------------------------------------------------------
# Public API — threshold checks
# ---------------------------------------------------------------------------

proc isMemoryCritical*(mem: MemoryInfo; thresholdPct: float = 90.0;
                       systemTotal: int64 = 0): bool =
  ## Returns true if memory usage exceeds the given threshold.
  memoryUsagePct(mem, systemTotal) >= thresholdPct

proc isInodeCritical*(fs: FilesystemUsage; thresholdPct: float = 90.0): bool =
  ## Returns true if inode usage exceeds the given threshold.
  inodeUsagePct(fs) >= thresholdPct

proc isDiskCritical*(fs: FilesystemUsage; thresholdPct: float = 90.0): bool =
  ## Returns true if disk usage exceeds the given threshold.
  diskUsagePct(fs) >= thresholdPct

proc checkAllThresholds*(path: string = "/"; memThreshold: float = 90.0;
                         inodeThreshold: float = 90.0;
                         diskThreshold: float = 90.0): seq[string] =
  ## Check all resource thresholds and return a list of warning strings.
  ## Empty seq means all clear.
  let mem = readMemoryInfo()
  let fs  = readFilesystemUsage(path)
  let cgm = readCgroupMemoryStat()

  result = @[]
  if isMemoryCritical(mem, memThreshold):
    result.add("MEMORY_CRITICAL: rss=" & formatBytes(mem.vmrss))
  if cgm.max > 0 and cgm.cgroupMemoryUsagePct >= memThreshold:
    result.add("CGROUP_MEMORY_CRITICAL: " &
               cgm.cgroupMemoryUsagePct.formatFloat(ffDecimal, 1) & "%")
  if isInodeCritical(fs, inodeThreshold):
    result.add("INODE_CRITICAL: used=" & $fs.usedInodes &
               " total=" & $fs.totalInodes)
  if isDiskCritical(fs, diskThreshold):
    result.add("DISK_CRITICAL: used=" & formatBytes(fs.usedBytes) &
               " total=" & formatBytes(fs.totalBytes))

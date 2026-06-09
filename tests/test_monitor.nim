# ferrite — Self-Monitoring Tests
#
# Phase 5 test suite. Most tests work without root; some require cgroups.
# Run with:  nim c --path:src -r tests/test_monitor.nim

import std/[os, posix, unittest, times]
import ferrite/monitor

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isRoot(): bool = getuid() == 0

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Memory info reading":

  test "readMemoryInfo returns values":
    let mem = readMemoryInfo()
    # VmRSS should be > 0 for any running process
    check mem.vmrss > 0
    # VmSize should be >= VmRSS
    check mem.vmsize >= mem.vmrss

  test "memoryUsagePct returns reasonable value":
    let mem = readMemoryInfo()
    let pct = memoryUsagePct(mem)
    check pct >= 0.0
    check pct <= 100.0

suite "Filesystem usage":

  test "readFilesystemUsage on root returns data":
    let fs = readFilesystemUsage("/")
    check fs.totalBytes > 0
    check fs.blockSize > 0
    # totalInodes may be 0 on filesystems without fixed inode limits (btrfs, zfs)
    check fs.totalInodes >= 0

  test "inodeUsagePct is within bounds":
    let fs = readFilesystemUsage("/")
    let pct = inodeUsagePct(fs)
    check pct >= 0.0
    check pct <= 100.0

  test "diskUsagePct is within bounds":
    let fs = readFilesystemUsage("/")
    let pct = diskUsagePct(fs)
    check pct >= 0.0
    check pct <= 100.0

suite "Cgroup memory stats":

  test "readCgroupMemoryStat returns without error":
    let cgm = readCgroupMemoryStat()
    # current may be 0 if not in a cgroup, but should not crash
    check cgm.current >= 0

  test "cgroupMemoryUsagePct with no limit is zero":
    let cgm = CgroupMemoryStat(current: 1024, max: 0)
    check cgroupMemoryUsagePct(cgm) == 0.0

  test "cgroupMemoryUsagePct calculates correctly":
    let cgm = CgroupMemoryStat(current: 512, max: 1024)
    check cgroupMemoryUsagePct(cgm) == 50.0

suite "Decay log and sampling":

  test "initDecayLog creates empty log":
    let dl = initDecayLog(maxSamples = 10)
    check dl.samples.len == 0
    check dl.maxSamples == 10

  test "sample adds data to log":
    var dl = initDecayLog(maxSamples = 10)
    dl.sample("/")
    check dl.samples.len == 1
    check dl.samples[0].timestamp > 0
    check dl.samples[0].memory.vmrss > 0

  test "sample respects ring buffer limit":
    var dl = initDecayLog(maxSamples = 3)
    dl.sample("/")
    dl.sample("/")
    dl.sample("/")
    dl.sample("/")
    check dl.samples.len == 3

  test "latest returns most recent sample":
    var dl = initDecayLog(maxSamples = 10)
    dl.sample("/")
    sleep(10)  # tiny delay so timestamps differ
    dl.sample("/")
    let last = dl.latest()
    check last.timestamp >= dl.samples[0].timestamp

  test "memoryTrend with no samples is zero":
    let dl = initDecayLog(maxSamples = 10)
    check memoryTrend(dl) == 0.0

  test "memoryTrend with single sample is zero":
    var dl = initDecayLog(maxSamples = 10)
    dl.sample("/")
    check memoryTrend(dl) == 0.0

  test "memoryTrend detects growth":
    var dl = initDecayLog(maxSamples = 10)
    # Simulate growth by manually injecting samples
    let t = epochTime()
    dl.samples.add(ResourceSample(
      timestamp: t,
      memory: MemoryInfo(vmrss: 1000)
    ))
    dl.samples.add(ResourceSample(
      timestamp: t + 1.0,
      memory: MemoryInfo(vmrss: 2000)
    ))
    let trend = memoryTrend(dl)
    check trend > 0.0
    check trend == 1000.0  # 1000 bytes / 1 second

suite "Threshold checks":

  test "isMemoryCritical with low usage is false":
    let mem = MemoryInfo(vmrss: 1024)
    # Against a huge total, this is not critical
    check not isMemoryCritical(mem, 90.0, 1024 * 1024 * 1024)

  test "isMemoryCritical with high usage is true":
    let mem = MemoryInfo(vmrss: 950)
    check isMemoryCritical(mem, 90.0, 1000)

  test "isInodeCritical with low usage is false":
    let fs = FilesystemUsage(totalInodes: 1000, usedInodes: 100)
    check not isInodeCritical(fs, 90.0)

  test "isInodeCritical with high usage is true":
    let fs = FilesystemUsage(totalInodes: 1000, usedInodes: 950)
    check isInodeCritical(fs, 90.0)

  test "isDiskCritical with low usage is false":
    let fs = FilesystemUsage(totalBytes: 1000, usedBytes: 100)
    check not isDiskCritical(fs, 90.0)

  test "isDiskCritical with high usage is true":
    let fs = FilesystemUsage(totalBytes: 1000, usedBytes: 950)
    check isDiskCritical(fs, 90.0)

  test "checkAllThresholds returns empty when all clear":
    let mem = MemoryInfo(vmrss: 1)
    let fs = FilesystemUsage(totalBytes: 1000, usedBytes: 1,
                             totalInodes: 1000, usedInodes: 1)
    let warnings = checkAllThresholds("/", 99.0, 99.0, 99.0)
    check warnings.len == 0

suite "Formatting":

  test "formatBytes handles small values":
    check formatBytes(0) == "0.00 B"
    check formatBytes(512) == "512.00 B"

  test "formatBytes handles KiB":
    check formatBytes(1024) == "1.00 KiB"
    check formatBytes(1536) == "1.50 KiB"

  test "formatBytes handles MiB":
    check formatBytes(1024 * 1024) == "1.00 MiB"

  test "formatBytes handles GiB":
    check formatBytes(1024 * 1024 * 1024) == "1.00 GiB"

suite "logDecay does not crash":

  test "logDecay writes to stderr":
    # Just verify it doesn't raise
    logDecay("test message")
    check true

  test "logResourceSnapshot does not crash":
    var dl = initDecayLog(maxSamples = 10)
    dl.sample("/")
    logResourceSnapshot(dl, "/")
    check true

# ferrite — cgroups v2 Resource Control Tests
#
# Phase 3 test suite. Requires root to write to cgroupfs.
# Run with:  nim c --path:src -r tests/test_cgroups.nim
# Or as root:  sudo nim c --path:src -r tests/test_cgroups.nim

import std/[os, posix, unittest, random]
import ferrite/cgroups

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isRoot(): bool = getuid() == 0

proc randomCgroupName(): string =
  "ferrite-test-" & $getpid() & "-" & $rand(100000)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "cgroups v2 availability":

  test "cgroupV2Available returns a boolean":
    let avail = cgroupV2Available()
    check (avail == true or avail == false)

  test "availableControllers returns a sequence":
    let controllers = availableControllers()
    if cgroupV2Available():
      check controllers.len >= 0
    else:
      check controllers.len == 0

suite "Cgroup lifecycle":

  test "create and remove cgroup":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    else:
      let name = randomCgroupName()
      check createCgroup(name) == 0
      check dirExists(CgroupV2Root / name)
      check removeCgroup(name) == 0
      check not dirExists(CgroupV2Root / name)

  test "create duplicate cgroup fails":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    else:
      let name = randomCgroupName()
      check createCgroup(name) == 0
      check createCgroup(name) < 0   # EEXIST
      check removeCgroup(name) == 0

  test "remove nonexistent cgroup fails":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    else:
      check removeCgroup("ferrite-nonexistent-" & $getpid()) < 0

suite "Process movement":

  test "move current process to cgroup":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    else:
      let name = randomCgroupName()
      check createCgroup(name) == 0
      check moveProcessToCgroup(getpid(), name) == 0
      check isInCgroup(getpid(), name)

      # Move back to root cgroup for cleanup
      discard moveProcessToCgroup(getpid(), "")
      check removeCgroup(name) == 0

suite "CPU limits":

  test "set cpu limit to 50%":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    elif "cpu" notin availableControllers():
      echo "  [SKIP] cpu controller not available"
    else:
      let name = randomCgroupName()
      let limits = CgroupLimits(cpuMaxPct: 50)
      check setupCgroup(name, limits) == 0

      let readBack = readCgroupLimits(name)
      check readBack.cpuMaxPct == 50

      check removeCgroup(name) == 0

  test "set cpu limit to 100%":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    elif "cpu" notin availableControllers():
      echo "  [SKIP] cpu controller not available"
    else:
      let name = randomCgroupName()
      let limits = CgroupLimits(cpuMaxPct: 100)
      check setupCgroup(name, limits) == 0

      let readBack = readCgroupLimits(name)
      check readBack.cpuMaxPct == 100

      check removeCgroup(name) == 0

suite "Memory limits":

  test "set memory limit to 64 MiB":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    elif "memory" notin availableControllers():
      echo "  [SKIP] memory controller not available"
    else:
      let name = randomCgroupName()
      let limits = CgroupLimits(memoryMaxBytes: 64 * 1024 * 1024)
      check setupCgroup(name, limits) == 0

      let readBack = readCgroupLimits(name)
      check readBack.memoryMaxBytes == 64 * 1024 * 1024

      check removeCgroup(name) == 0

suite "PID limits":

  test "set pid limit to 32":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    elif "pids" notin availableControllers():
      echo "  [SKIP] pids controller not available"
    else:
      let name = randomCgroupName()
      let limits = CgroupLimits(pidsMax: 32)
      check setupCgroup(name, limits) == 0

      let readBack = readCgroupLimits(name)
      check readBack.pidsMax == 32

      check removeCgroup(name) == 0

suite "Combined limits":

  test "setup cpu + memory + pids limits":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    else:
      let name = randomCgroupName()
      let limits = CgroupLimits(
        cpuMaxPct: 75,
        memoryMaxBytes: 256 * 1024 * 1024,
        pidsMax: 100
      )
      check setupCgroup(name, limits) == 0

      let readBack = readCgroupLimits(name)
      if "cpu" in availableControllers():
        check readBack.cpuMaxPct == 75
      if "memory" in availableControllers():
        check readBack.memoryMaxBytes == 256 * 1024 * 1024
      if "pids" in availableControllers():
        check readBack.pidsMax == 100

      check removeCgroup(name) == 0

suite "High-level applyCgroup":

  test "applyCgroup creates cgroup and moves process":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    else:
      let name = randomCgroupName()
      let limits = CgroupLimits(cpuMaxPct: 25, memoryMaxBytes: 32 * 1024 * 1024)
      check applyCgroup(getpid(), name, limits) == 0
      check isInCgroup(getpid(), name)

      # Move back to root for cleanup
      discard moveProcessToCgroup(getpid(), "")
      check removeCgroup(name) == 0

suite "Cleanup":

  test "cleanupCgroup removes cgroup":
    if not isRoot():
      echo "  [SKIP] requires root"
    elif not cgroupV2Available():
      echo "  [SKIP] cgroups v2 not available"
    else:
      let name = randomCgroupName()
      check createCgroup(name) == 0
      check dirExists(CgroupV2Root / name)
      discard cleanupCgroup(name)
      check not dirExists(CgroupV2Root / name)

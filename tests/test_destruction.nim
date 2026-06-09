# ferrite — Self-Destruction Protocol Tests
#
# Phase 6 test suite. Tests configuration, threshold evaluation,
# and destruction logic. Most tests do not require root.
# Run with:  nim c --path:src -r tests/test_destruction.nim

import std/[os, posix, unittest, times]
import ferrite/monitor
import ferrite/destruction

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isRoot(): bool = getuid() == 0

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "DestructionConfig":

  test "initDestructionConfig returns sensible defaults":
    let cfg = initDestructionConfig()
    check cfg.memThresholdPct == 95.0
    check cfg.inodeThresholdPct == 95.0
    check cfg.diskThresholdPct == 95.0
    check cfg.cgroupMemThresholdPct == 0.0
    check cfg.mode == dmGraceful
    check cfg.gracePeriodMs == 5000
    check cfg.checkIntervalMs == 1000
    check cfg.logPath == "/"

  test "initDestructionConfig accepts custom values":
    let cfg = initDestructionConfig(
      memThresholdPct = 80.0,
      inodeThresholdPct = 90.0,
      diskThresholdPct = 85.0,
      cgroupMemThresholdPct = 70.0,
      mode = dmImmediate,
      gracePeriodMs = 10000,
      checkIntervalMs = 500,
      logPath = "/tmp"
    )
    check cfg.memThresholdPct == 80.0
    check cfg.inodeThresholdPct == 90.0
    check cfg.diskThresholdPct == 85.0
    check cfg.cgroupMemThresholdPct == 70.0
    check cfg.mode == dmImmediate
    check cfg.gracePeriodMs == 10000
    check cfg.checkIntervalMs == 500
    check cfg.logPath == "/tmp"

suite "SelfDestructor initialization":

  test "initSelfDestructor creates alive monitor":
    let cfg = initDestructionConfig()
    var sd = initSelfDestructor(cfg)
    check sd.isAlive == true
    check sd.monitorPid == 0
    check sd.sigtermSent == false
    check sd.decayLog.samples.len == 0
    check sd.decayLog.maxSamples == 60

  test "initSelfDestructor copies config":
    let cfg = initDestructionConfig(memThresholdPct = 42.0)
    var sd = initSelfDestructor(cfg)
    check sd.config.memThresholdPct == 42.0

suite "Threshold evaluation":

  test "evaluateThresholds returns empty when all clear":
    # Use extremely high thresholds so nothing triggers
    let cfg = initDestructionConfig(
      memThresholdPct = 99.999,
      inodeThresholdPct = 99.999,
      diskThresholdPct = 99.999
    )
    var sd = initSelfDestructor(cfg)
    let triggers = evaluateThresholds(sd)
    check triggers.len == 0

  test "shouldDestroy is false when all clear":
    let cfg = initDestructionConfig(
      memThresholdPct = 99.999,
      inodeThresholdPct = 99.999,
      diskThresholdPct = 99.999
    )
    var sd = initSelfDestructor(cfg)
    check not shouldDestroy(sd)

  test "shouldDestroy is true when thresholds are very low":
    # Use 0% thresholds so anything triggers
    let cfg = initDestructionConfig(
      memThresholdPct = 0.0,
      inodeThresholdPct = 0.0,
      diskThresholdPct = 0.0
    )
    var sd = initSelfDestructor(cfg)
    check shouldDestroy(sd)

suite "Destruction actions":

  test "immediateDestroy sets isAlive to false":
    var sd = initSelfDestructor(initDestructionConfig())
    # Don't actually kill ourselves in tests — monitorPid = 0 would kill test process
    sd.monitorPid = 1  # init is always alive, so kill(1, SIGKILL) is safe to call (will EPERM as non-root)
    immediateDestroy(sd)
    check sd.isAlive == false

  test "gracefulDestroy first call sends SIGTERM flag":
    var sd = initSelfDestructor(initDestructionConfig())
    sd.monitorPid = 1  # safe target (init)
    gracefulDestroy(sd)
    check sd.sigtermSent == true
    check sd.isAlive == true  # still alive during grace period

  test "gracefulDestroy second call after grace period kills":
    var sd = initSelfDestructor(
      initDestructionConfig(gracePeriodMs = 0)
    )
    sd.monitorPid = 1  # safe target
    gracefulDestroy(sd)   # sends SIGTERM
    check sd.sigtermSent == true
    # With gracePeriodMs = 0, second call should immediately SIGKILL
    gracefulDestroy(sd)
    check sd.isAlive == false

suite "DecayLog integration":

  test "checkAndDestroy samples decayLog":
    var sd = initSelfDestructor(
      initDestructionConfig(
        memThresholdPct = 99.999,
        inodeThresholdPct = 99.999,
        diskThresholdPct = 99.999
      )
    )
    check sd.decayLog.samples.len == 0
    checkAndDestroy(sd)  # should sample but not destroy (thresholds too high)
    check sd.decayLog.samples.len == 1
    check sd.isAlive == true

  test "checkAndDestroy with low threshold triggers destruction":
    var sd = initSelfDestructor(
      initDestructionConfig(
        memThresholdPct = 0.0,
        mode = dmImmediate
      )
    )
    sd.monitorPid = 1  # safe target
    check sd.isAlive == true
    checkAndDestroy(sd)
    check sd.isAlive == false

suite "Logging helpers":

  test "logDestructionConfig does not crash":
    let cfg = initDestructionConfig()
    logDestructionConfig(cfg)
    check true

  test "logDestructionState does not crash":
    var sd = initSelfDestructor(initDestructionConfig())
    logDestructionState(sd)
    check true

suite "runMonitored basic":

  test "runMonitored /bin/true returns 0":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/true"):
        echo "  [SKIP] /bin/true not found"
      else:
        let cfg = initDestructionConfig(
          memThresholdPct = 99.999,  # never trigger
          checkIntervalMs = 100
        )
        let rc = runMonitored("/bin/true", [], cfg)
        check rc == 0

  test "runMonitored /bin/false returns 1":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/false"):
        echo "  [SKIP] /bin/false not found"
      else:
        let cfg = initDestructionConfig(
          memThresholdPct = 99.999,
          checkIntervalMs = 100
        )
        let rc = runMonitored("/bin/false", [], cfg)
        check rc == 1

  test "runMonitored propagates exit code":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        let cfg = initDestructionConfig(
          memThresholdPct = 99.999,
          checkIntervalMs = 100
        )
        let rc = runMonitored("/bin/sh", ["-c", "exit 42"], cfg)
        check rc == 42

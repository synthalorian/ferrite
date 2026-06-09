# ferrite — Graceful Self-Destruction Protocol
#
# Phase 6: When resource limits are breached, ferrite destroys itself gracefully.
# Builds on Phase 5 (monitoring) to observe decay and on Phase 4 (lifecycle)
# to terminate processes cleanly.
#
# Pure Nim — no external dependencies beyond posix and linux headers.
#
# Usage:
#   var sd = initSelfDestructor(initDestructionConfig())
#   sd.monitorPid = containerPid
#   while sd.isAlive:
#     sd.checkAndDestroy()
#     sleep(1000)
#
# Or use the high-level wrapper:
#   let rc = runMonitored(cmd, args, config)

import std/[os, strutils, times]

when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

import monitor

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  DefaultGracePeriodMs* = 5000   ## Default time to wait between SIGTERM and SIGKILL
  DefaultCheckIntervalMs* = 1000 ## Default monitoring interval
  DefaultMemThreshold* = 95.0    ## Memory critical threshold (%)
  DefaultInodeThreshold* = 95.0  ## Inode critical threshold (%)
  DefaultDiskThreshold* = 95.0   ## Disk critical threshold (%)

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------


type
  DestructionMode* = enum
    dmGraceful,   ## SIGTERM first, then SIGKILL after grace period
    dmImmediate   ## SIGKILL immediately (no grace period)

  DestructionConfig* = object
    ## Configuration for when and how to self-destruct.
    memThresholdPct*: float       ## Memory usage % that triggers destruction
    inodeThresholdPct*: float     ## Inode usage % that triggers destruction
    diskThresholdPct*: float      ## Disk usage % that triggers destruction
    cgroupMemThresholdPct*: float ## Cgroup memory % that triggers destruction (0 = ignore)
    mode*: DestructionMode        ## Graceful or immediate destruction
    gracePeriodMs*: int           ## Milliseconds to wait before SIGKILL
    checkIntervalMs*: int         ## Milliseconds between resource checks
    logPath*: string              ## Filesystem path to monitor (default "/")

  SelfDestructor* = object
    ## Stateful self-destruction monitor.
    config*: DestructionConfig
    decayLog*: DecayLog
    monitorPid*: Pid              ## Target process to kill (0 = self)
    isAlive*: bool                ## Set to false after destruction is triggered
    destructionTime*: float       ## Epoch time when destruction started
    sigtermSent*: bool            ## True if SIGTERM has been sent

  DestructionError* = object of OSError
    ## Raised when a destruction operation fails.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc raiseDestructionErr(msg: string) {.noinline, noreturn.} =
  raise newException(DestructionError, msg & ": " & osErrorMsg(osLastError()))

proc nowMs(): int64 =
  ## Current time in milliseconds since epoch.
  int64(epochTime() * 1000.0)

proc sendSignal(pid: Pid; sig: cint): bool =
  ## Send a signal to a process. Returns true on success.
  if pid <= 0:
    return false
  result = kill(pid, sig) == 0

# ---------------------------------------------------------------------------
# Public API — configuration
# ---------------------------------------------------------------------------

proc initDestructionConfig*(
    memThresholdPct: float = DefaultMemThreshold;
    inodeThresholdPct: float = DefaultInodeThreshold;
    diskThresholdPct: float = DefaultDiskThreshold;
    cgroupMemThresholdPct: float = 0.0;
    mode: DestructionMode = dmGraceful;
    gracePeriodMs: int = DefaultGracePeriodMs;
    checkIntervalMs: int = DefaultCheckIntervalMs;
    logPath: string = "/"
): DestructionConfig =
  ## Create a default destruction configuration.
  result.memThresholdPct = memThresholdPct
  result.inodeThresholdPct = inodeThresholdPct
  result.diskThresholdPct = diskThresholdPct
  result.cgroupMemThresholdPct = cgroupMemThresholdPct
  result.mode = mode
  result.gracePeriodMs = gracePeriodMs
  result.checkIntervalMs = checkIntervalMs
  result.logPath = logPath

proc initSelfDestructor*(config: DestructionConfig): SelfDestructor =
  ## Create a new self-destructor with the given configuration.
  result.config = config
  result.decayLog = initDecayLog(maxSamples = 60)
  result.monitorPid = 0
  result.isAlive = true
  result.destructionTime = 0.0
  result.sigtermSent = false

# ---------------------------------------------------------------------------
# Public API — threshold evaluation
# ---------------------------------------------------------------------------

proc evaluateThresholds*(sd: SelfDestructor): seq[string] =
  ## Check all configured thresholds and return a list of triggered
  ## condition strings. Empty seq means all clear.
  result = @[]
  let cfg = sd.config

  let mem = readMemoryInfo()
  let fs = readFilesystemUsage(cfg.logPath)
  let cgm = readCgroupMemoryStat()

  if isMemoryCritical(mem, cfg.memThresholdPct):
    result.add("MEMORY_CRITICAL: " &
               memoryUsagePct(mem).formatFloat(ffDecimal, 1) & "%")

  if cfg.cgroupMemThresholdPct > 0.0 and cgm.max > 0 and
     cgm.cgroupMemoryUsagePct >= cfg.cgroupMemThresholdPct:
    result.add("CGROUP_MEMORY_CRITICAL: " &
               cgm.cgroupMemoryUsagePct.formatFloat(ffDecimal, 1) & "%")

  if isInodeCritical(fs, cfg.inodeThresholdPct):
    result.add("INODE_CRITICAL: " &
               fs.inodeUsagePct.formatFloat(ffDecimal, 1) & "%")

  if isDiskCritical(fs, cfg.diskThresholdPct):
    result.add("DISK_CRITICAL: " &
               fs.diskUsagePct.formatFloat(ffDecimal, 1) & "%")

proc shouldDestroy*(sd: SelfDestructor): bool =
  ## Returns true if any threshold is breached.
  evaluateThresholds(sd).len > 0

# ---------------------------------------------------------------------------
# Public API — destruction actions
# ---------------------------------------------------------------------------

proc immediateDestroy*(sd: var SelfDestructor) =
  ## Send SIGKILL to the monitored process (or self if monitorPid == 0).
  ## Sets isAlive = false regardless of whether kill succeeded.
  let target = if sd.monitorPid > 0: sd.monitorPid else: getpid()
  logDecay("DESTRUCTION: sending SIGKILL to PID " & $target)
  discard sendSignal(target, SIGKILL)
  sd.isAlive = false

proc gracefulDestroy*(sd: var SelfDestructor) =
  ## Initiate graceful destruction. Sends SIGTERM on first call.
  ## If called again after gracePeriodMs has elapsed, sends SIGKILL.
  let target = if sd.monitorPid > 0: sd.monitorPid else: getpid()

  if not sd.sigtermSent:
    logDecay("DESTRUCTION: sending SIGTERM to PID " & $target &
             " (grace period: " & $sd.config.gracePeriodMs & " ms)")
    discard sendSignal(target, SIGTERM)
    sd.sigtermSent = true
    sd.destructionTime = epochTime()
  else:
    let elapsedMs = int64((epochTime() - sd.destructionTime) * 1000.0)
    if elapsedMs >= sd.config.gracePeriodMs:
      logDecay("DESTRUCTION: grace period expired (" & $elapsedMs &
               " ms elapsed), sending SIGKILL to PID " & $target)
      discard sendSignal(target, SIGKILL)
      sd.isAlive = false
    else:
      logDecay("DESTRUCTION: waiting for grace period (" &
               $(sd.config.gracePeriodMs - elapsedMs) & " ms remaining)")

proc checkAndDestroy*(sd: var SelfDestructor) =
  ## Evaluate thresholds and take destruction action if needed.
  ## This should be called periodically (e.g. every checkIntervalMs).
  ##
  ## If already in destruction mode (sigtermSent), continues the
  ## graceful shutdown sequence.

  # Already destroyed or destroying
  if not sd.isAlive and not sd.sigtermSent:
    return

  # Continue graceful destruction sequence
  if sd.sigtermSent:
    gracefulDestroy(sd)
    return

  # Sample resources for trend analysis
  sd.decayLog.sample(sd.config.logPath)

  # Check thresholds
  let triggers = evaluateThresholds(sd)
  if triggers.len == 0:
    return

  # Thresholds breached — log and destroy
  logDecay("THRESHOLD BREACH: " & triggers.join("; "))
  logResourceSnapshot(sd.decayLog, sd.config.logPath)

  case sd.config.mode
  of dmGraceful:
    gracefulDestroy(sd)
  of dmImmediate:
    immediateDestroy(sd)

# ---------------------------------------------------------------------------
# Public API — high-level wrappers
# ---------------------------------------------------------------------------

proc runMonitored*(cmd: string; args: openArray[string] = [];
                    config: DestructionConfig = initDestructionConfig()): cint =
  ## Run a command with self-destruction monitoring.
  ##
  ## Forks the command as a child process. A monitor thread (actually
  ## the parent process) periodically checks resource thresholds.
  ## If thresholds are breached, the child is terminated gracefully
  ## (or immediately, depending on config.mode).
  ##
  ## Returns the child's exit code, or 128 + signal if killed.

  let pid = fork()
  if pid < 0:
    stderr.writeLine("ferrite: fork failed: ", osErrorMsg(osLastError()))
    return 127

  if pid == 0:
    # Child path: reset signal handlers and exec the command
    var act: Sigaction
    act.sa_handler = SIG_DFL
    discard sigemptyset(act.sa_mask)
    act.sa_flags = 0
    discard sigaction(SIGTERM, act, nil)
    discard sigaction(SIGINT, act, nil)

    var argv = allocCStringArray(@[cmd] & @args)
    discard execvp(cstring(cmd), argv)
    deallocCStringArray(argv)
    stderr.writeLine("ferrite: execvp failed: ", osErrorMsg(osLastError()))
    quit(127)

  # Parent path: monitor the child
  var sd = initSelfDestructor(config)
  sd.monitorPid = pid

  var childExited = false
  var exitCode: cint = 0

  while not childExited and sd.isAlive:
    # Check if child has exited (non-blocking)
    var status: cint
    let waited = waitpid(pid, status, WNOHANG)
    if waited == pid:
      if WIFEXITED(status):
        exitCode = WEXITSTATUS(status)
      elif WIFSIGNALED(status):
        exitCode = 128 + WTERMSIG(status)
      else:
        exitCode = -1
      childExited = true
      break
    elif waited < 0:
      # Child probably already reaped
      childExited = true
      exitCode = -1
      break

    # Check thresholds and potentially destroy
    checkAndDestroy(sd)

    if not childExited and sd.isAlive:
      sleep(config.checkIntervalMs)

  # If we destroyed the child, wait for it to finish
  if not childExited and not sd.isAlive:
    var status: cint
    discard waitpid(pid, status, 0)

  result = exitCode

proc runMonitored*(argv: cstringArray;
                    config: DestructionConfig = initDestructionConfig()): cint =
  ## Overload that takes a cstringArray (for compatibility with runAsInit).
  var args: seq[string] = @[]
  var i = 1
  while argv[i] != nil:
    args.add($argv[i])
    inc i
  runMonitored($argv[0], args, config)

# ---------------------------------------------------------------------------
# Public API — logging helpers
# ---------------------------------------------------------------------------

proc logDestructionConfig*(cfg: DestructionConfig) =
  ## Log the destruction configuration at startup.
  logDecay("Self-destruction config:")
  logDecay("  mode=" & (if cfg.mode == dmGraceful: "graceful" else: "immediate"))
  logDecay("  memThreshold=" & cfg.memThresholdPct.formatFloat(ffDecimal, 1) & "%")
  logDecay("  inodeThreshold=" & cfg.inodeThresholdPct.formatFloat(ffDecimal, 1) & "%")
  logDecay("  diskThreshold=" & cfg.diskThresholdPct.formatFloat(ffDecimal, 1) & "%")
  if cfg.cgroupMemThresholdPct > 0.0:
    logDecay("  cgroupMemThreshold=" & cfg.cgroupMemThresholdPct.formatFloat(ffDecimal, 1) & "%")
  logDecay("  gracePeriod=" & $cfg.gracePeriodMs & " ms")
  logDecay("  checkInterval=" & $cfg.checkIntervalMs & " ms")

proc logDestructionState*(sd: SelfDestructor) =
  ## Log the current destruction state.
  let state = if not sd.isAlive: "destroyed"
              elif sd.sigtermSent: "destroying (sigterm sent)"
              else: "monitoring"
  logDecay("Self-destructor state: " & state)
  if sd.monitorPid > 0:
    logDecay("  targetPid=" & $sd.monitorPid)
  logDecay("  samples=" & $sd.decayLog.samples.len)

# ferrite — Process Lifecycle Management Module
#
# Phase 4: init process, signal forwarding, and zombie reaping.
# Pure Nim — no external dependencies beyond posix and linux headers.
#
# When a new PID namespace is created, the first process becomes PID 1.
# This module provides a proper init that:
#   - Forks the actual container command
#   - Forwards signals to the container process
#   - Reaps orphaned/zombie child processes
#   - Exits with the same status as the container process
#
# Usage:
#   let rc = runAsInit(argv)   # argv is a cstringArray for execvp

import std/os

when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  SIGTERM = 15
  SIGINT  = 2
  SIGHUP  = 1
  SIGUSR1 = 10
  SIGUSR2 = 12

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  ProcessState* = enum
    psRunning,   ## Container process is still running
    psExited,    ## Container process exited normally
    psSignaled   ## Container process was killed by a signal

  ContainerProcess* = object
    ## Tracks the state of a container's init and its child.
    initPid*: Pid          ## PID of the init process (host view)
    childPid*: Pid         ## PID of the actual container process (in ns)
    exitCode*: cint        ## Exit code of the container process
    state*: ProcessState   ## Current state

# ---------------------------------------------------------------------------
# Signal handling globals (volatile — accessed from signal handlers)
# ---------------------------------------------------------------------------

var
  gPendingSigterm: bool
  gPendingSigint: bool
  gPendingSighup: bool
  gPendingSigusr1: bool
  gPendingSigusr2: bool

# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

proc handleSigterm(sig: cint) {.noconv.} =
  gPendingSigterm = true

proc handleSigint(sig: cint) {.noconv.} =
  gPendingSigint = true

proc handleSighup(sig: cint) {.noconv.} =
  gPendingSighup = true

proc handleSigusr1(sig: cint) {.noconv.} =
  gPendingSigusr1 = true

proc handleSigusr2(sig: cint) {.noconv.} =
  gPendingSigusr2 = true

proc setupSignalHandlers() =
  ## Install signal handlers for signals we want to forward to the child.
  var act: Sigaction
  act.sa_handler = handleSigterm
  discard sigemptyset(act.sa_mask)
  act.sa_flags = 0
  discard sigaction(SIGTERM, act, nil)

  act.sa_handler = handleSigint
  discard sigaction(SIGINT, act, nil)

  act.sa_handler = handleSighup
  discard sigaction(SIGHUP, act, nil)

  act.sa_handler = handleSigusr1
  discard sigaction(SIGUSR1, act, nil)

  act.sa_handler = handleSigusr2
  discard sigaction(SIGUSR2, act, nil)

proc forwardPendingSignals(childPid: Pid) =
  ## Forward any pending signals to the child process.
  if gPendingSigterm:
    discard kill(childPid, SIGTERM)
    gPendingSigterm = false
  if gPendingSigint:
    discard kill(childPid, SIGINT)
    gPendingSigint = false
  if gPendingSighup:
    discard kill(childPid, SIGHUP)
    gPendingSighup = false
  if gPendingSigusr1:
    discard kill(childPid, SIGUSR1)
    gPendingSigusr1 = false
  if gPendingSigusr2:
    discard kill(childPid, SIGUSR2)
    gPendingSigusr2 = false

# ---------------------------------------------------------------------------
# Reaping helpers
# ---------------------------------------------------------------------------

proc reapAllZombies(): Pid =
  ## Reap all available zombie children (non-blocking).
  ## Returns the PID of the last reaped child, or 0 if none.
  result = 0
  while true:
    var status: cint
    let pid = waitpid(-1, status, WNOHANG)
    if pid <= 0:
      break
    result = pid

proc waitForMainChild(childPid: Pid; status: var cint): bool =
  ## Block until `childPid` exits.  Returns true on success.
  ## If interrupted by a signal, returns false so the caller can
  ## forward signals and retry.
  let pid = waitpid(childPid, status, 0)
  if pid == childPid:
    result = true
  elif pid < 0 and errno == EINTR:
    result = false
  else:
    result = true  # unexpected, but don't loop forever

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc runAsInit*(argv: cstringArray): cint =
  ## Run as PID 1 inside a container's PID namespace.
  ##
  ## Forks a child that execvp's `argv[0]` with `argv`.
  ## The parent (this process) forwards signals and reaps zombies
  ## until the child exits, then returns the child's exit status.
  ##
  ## This function never returns on the child path (execvp replaces
  ## the process image).  On the parent path it returns:
  ##   - The child's exit code (0-255) if it exited normally.
  ##   - 128 + signal number if it was killed by a signal.
  ##   - 127 if the fork or exec fails.

  setupSignalHandlers()

  let childPid = fork()
  if childPid < 0:
    stderr.writeLine("ferrite: init fork failed: ", osErrorMsg(osLastError()))
    return 127

  if childPid == 0:
    # Child path: exec the actual container command.
    # Reset signal handlers to default before exec.
    var act: Sigaction
    act.sa_handler = SIG_DFL
    discard sigemptyset(act.sa_mask)
    act.sa_flags = 0
    discard sigaction(SIGTERM, act, nil)
    discard sigaction(SIGINT, act, nil)
    discard sigaction(SIGHUP, act, nil)
    discard sigaction(SIGUSR1, act, nil)
    discard sigaction(SIGUSR2, act, nil)

    discard execvp(argv[0], argv)
    stderr.writeLine("ferrite: init execvp failed: ", osErrorMsg(osLastError()))
    quit(127)

  # Parent path: we are PID 1.  Forward signals and reap zombies.
  var
    childExited = false
    exitCode: cint = 0

  while not childExited:
    # Forward any pending signals before waiting
    forwardPendingSignals(childPid)

    var status: cint
    if waitForMainChild(childPid, status):
      if WIFEXITED(status):
        exitCode = WEXITSTATUS(status)
      elif WIFSIGNALED(status):
        exitCode = 128 + WTERMSIG(status)
      else:
        exitCode = -1
      childExited = true
    else:
      # Interrupted by signal — forward it and continue waiting
      forwardPendingSignals(childPid)

  # Child has exited.  Reap any remaining zombies (non-blocking).
  discard reapAllZombies()

  # Forward any last-minute signals (won't matter much, but be thorough)
  forwardPendingSignals(childPid)

  exitCode

proc runAsInit*(cmd: string; args: openArray[string] = []): cint =
  ## Convenience overload that builds the argv array from Nim strings.
  var argv = allocCStringArray(@[cmd] & @args)
  result = runAsInit(argv)
  deallocCStringArray(argv)

# ---------------------------------------------------------------------------
# Process tracking helpers
# ---------------------------------------------------------------------------

proc waitContainer*(cp: var ContainerProcess): cint =
  ## Block until the container's init process exits.
  ## Updates `cp.state` and `cp.exitCode` and returns the exit code.
  if cp.initPid <= 0:
    cp.state = psExited
    cp.exitCode = -1
    return -1

  var status: cint
  if waitpid(cp.initPid, status, 0) < 0:
    cp.state = psExited
    cp.exitCode = -1
    return -1

  if WIFEXITED(status):
    cp.state = psExited
    cp.exitCode = WEXITSTATUS(status)
  elif WIFSIGNALED(status):
    cp.state = psSignaled
    cp.exitCode = 128 + WTERMSIG(status)
  else:
    cp.state = psExited
    cp.exitCode = -1

  result = cp.exitCode

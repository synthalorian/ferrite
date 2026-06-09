# ferrite — Namespace Isolation Module
#
# Phase 1: clone/unshare wrappers for Linux namespace creation.
# Pure Nim — no external dependencies beyond posix and linux headers.
#
# Usage:
#   let pid = cloneIsolate({nsPid, nsNet, nsMount}, childMain)
#   unshareNamespaces({nsUts, nsIpc})

import std/os

when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

import cgroups
import lifecycle

# ---------------------------------------------------------------------------
# Constants — Linux clone flags and syscall numbers (x86_64)
# ---------------------------------------------------------------------------

const
  CLONE_NEWNS          = 0x00020000   # mount namespace
  CLONE_NEWCGROUP      = 0x02000000   # cgroup namespace
  CLONE_NEWUTS         = 0x04000000   # UTS namespace
  CLONE_NEWIPC         = 0x08000000   # IPC namespace
  CLONE_NEWUSER        = 0x10000000   # user namespace
  CLONE_NEWPID         = 0x20000000   # PID namespace
  CLONE_NEWNET         = 0x40000000   # network namespace

  CLONE_STACK_SIZE     = 1024 * 1024 * 8   # 8 MiB child stack

  SYS_UNSHARE          = 272
  SYS_SETHOSTNAME      = 170
  SIGCHLD              = 17

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  Namespace* = enum
    nsMount, nsPid, nsNet, nsUts, nsIpc, nsUser, nsCgroup

  ChildFn* = proc (ctx: pointer): cint {.noconv.}
    ## Function signature for the child entry point used with cloneIsolate.
    ## Must be {.noconv.} because clone expects a C function pointer.
    ## `ctx` is an opaque pointer passed through from cloneIsolate.

# ---------------------------------------------------------------------------
# Global slots for passing data through clone(2)
#
# These are safe because clone(2) is synchronous: the parent blocks until
# the child has started executing, so there is no race.
# ---------------------------------------------------------------------------

var
  gChildFn: ChildFn
  gChildCtx: pointer
  gChildReady: bool
  gExecNss: set[Namespace]   # passed through clone for executeInNamespace

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc toCloneFlag(ns: Namespace): cint =
  case ns
  of nsMount:  CLONE_NEWNS
  of nsPid:    CLONE_NEWPID
  of nsNet:    CLONE_NEWNET
  of nsUts:    CLONE_NEWUTS
  of nsIpc:    CLONE_NEWIPC
  of nsUser:   CLONE_NEWUSER
  of nsCgroup: CLONE_NEWCGROUP

proc composeFlags(nss: set[Namespace]): cint =
  var flags: cint = SIGCHLD
  for ns in nss:
    flags = flags or toCloneFlag(ns)
  flags

# Minimal syscall wrappers — Nim stdlib does not expose clone/unshare.
proc syscall3(n: clong; a1, a2, a3: clong): clong
  {.importc: "syscall", header: "<unistd.h>".}

proc syscallClone(flags: clong; stack: pointer; ptid, ctid: pointer;
                  regs: pointer): clong
  {.importc: "syscall", header: "<unistd.h>", varargs.}

proc rawClone(flags: clong; stack: pointer): Pid =
  let pid = syscallClone(flags, stack, nil, nil, nil)
  if pid < 0:
    raiseOSError(OSErrorCode(-pid))
  Pid(pid)

proc rawUnshare(flags: clong): cint =
  let rc = syscall3(SYS_UNSHARE, flags, 0, 0)
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

# C-style trampoline required by clone(2).
proc trampoline(): cint {.noconv.} =
  assert gChildReady
  result = gChildFn(gChildCtx)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc unshareNamespaces*(nss: set[Namespace]): cint {.discardable.} =
  ## Move the calling process into new namespaces.
  ## Returns 0 on success, -1 on error (check errno).
  ##
  ## Example:
  ##   if unshareNamespaces({nsUts, nsIpc}) != 0:
  ##     echo "unshare failed: ", osErrorMsg(osLastError())
  rawUnshare(composeFlags(nss).clong)

proc cloneIsolate*(nss: set[Namespace]; fn: ChildFn; ctx: pointer = nil): Pid =
  ## Create a new child process in isolated namespaces.
  ##
  ## The child starts execution at `fn` with the opaque pointer `ctx`.
  ## A fresh stack of 8 MiB is allocated automatically.
  ## The caller must call `waitpid` to reap the child.
  ##
  ## Returns the child PID on success, raises OSError on failure.
  ##
  ## Example:
  ##   proc childMain(ctx: pointer): cint =
  ##     echo "I am PID ", getpid(), " in a new namespace!"
  ##     0
  ##   let pid = cloneIsolate({nsPid, nsNet, nsMount}, childMain)
  ##   discard waitpid(pid, nil, 0)

  let flags = composeFlags(nss).clong

  # Allocate child stack (grows down on x86_64, so pass the *top*).
  let stackBottom = alloc0(CLONE_STACK_SIZE)
  if stackBottom == nil:
    raiseOSError(OSErrorCode(ENOMEM))

  let stackTop = cast[pointer](cast[uint](stackBottom) + CLONE_STACK_SIZE.uint)

  # Populate global slot (safe: clone is synchronous).
  gChildFn = fn
  gChildCtx = ctx
  gChildReady = true

  let pid = rawClone(flags, stackTop)

  # Parent path — child has already consumed the slot.
  gChildReady = false
  gChildCtx = nil
  gChildFn = nil

  if pid < 0:
    # Clone failed — free stack ourselves.
    dealloc(stackBottom)

  pid

proc executeInNamespace*(nss: set[Namespace]; cmd: string;
                          args: openArray[string] = [];
                          cgroupName: string = ""): cint =
  ## High-level helper: clone into namespaces, then execvp(cmd, args) in child.
  ## Blocks until the child exits.  Returns the child's exit status.
  ##
  ## If `cgroupName` is provided, the child is moved into that cgroup after
  ## cloning. The caller is responsible for cgroup cleanup.
  ##
  ## Example:
  ##   let rc = executeInNamespace({nsPid, nsNet, nsMount}, "/bin/sh", ["-c", "hostname"])

  # Pack command + args into a single C-string array.
  var cargs = allocCStringArray(@[cmd] & @args)

  # Use global slot to pass nss through clone (closure capture is illegal for noconv).
  gExecNss = nss

  proc execChild(ctx: pointer): cint {.noconv.} =
    let argv = cast[cstringArray](ctx)
    # When running in a PID namespace we act as init (PID 1).
    # runAsInit forks the real command, forwards signals, and reaps zombies.
    if nsPid in gExecNss:
      runAsInit(argv)
    else:
      discard execvp(cstring(argv[0]), argv)
      # execvp only returns on error
      stderr.writeLine("ferrite: execvp failed: ", osErrorMsg(osLastError()))
      127

  let pid = cloneIsolate(nss, execChild, cargs)

  # Clear the global slot after clone returns
  gExecNss = {}

  # Move child into cgroup immediately after clone
  if cgroupName.len > 0:
    discard moveProcessToCgroup(pid, cgroupName)

  var status: cint
  if waitpid(pid, status, 0) < 0:
    deallocCStringArray(cargs)
    raiseOSError(osLastError())

  deallocCStringArray(cargs)

  if WIFEXITED(status):
    WEXITSTATUS(status)
  elif WIFSIGNALED(status):
    128 + WTERMSIG(status)
  else:
    -1

# ---------------------------------------------------------------------------
# Utility helpers (used by tests and CLI)
# ---------------------------------------------------------------------------

proc currentNamespaces*(): seq[string] =
  ## Read /proc/self/ns/ and return a list of namespace identifiers.
  result = @[]
  for kind, path in walkDir("/proc/self/ns"):
    if kind == pcLinkToFile:
      result.add(path.lastPathPart & "=" & path.expandSymlink.lastPathPart)

proc hostname*(): string =
  ## Get the current hostname (UTS namespace).
  var buf: array[256, char]
  if gethostname(addr buf[0], buf.len.cint) != 0:
    raiseOSError(osLastError())
  result = $cast[cstring](addr buf[0])

proc setHostname*(name: string): cint {.discardable.} =
  ## Set the hostname in the current UTS namespace.
  ## Requires CAP_SYS_ADMIN or root.
  let rc = syscall3(SYS_SETHOSTNAME, cast[clong](cstring(name)), name.len.clong, 0)
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

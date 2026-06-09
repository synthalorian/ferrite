# ferrite — Root Filesystem Module
#
# Phase 2: pivot_root and overlayfs setup.
# Pure Nim — no external dependencies beyond posix and linux headers.
#
# Usage:
#   let rc = mountOverlay("/lower", "/upper", "/work", "/merged")
#   discard pivotRoot("/merged")
#   discard runInRootfs({nsPid, nsMount}, "/path/to/image", "/bin/sh")

import std/os
when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

# Re-export Namespace type so consumers don't need both modules
import namespaces
export namespaces

import cgroups
export cgroups.CgroupLimits
import lifecycle

# ---------------------------------------------------------------------------
# Constants — Linux syscall numbers (x86_64) and mount flags
# ---------------------------------------------------------------------------

const
  SYS_MOUNT      = 165
  SYS_UMOUNT2    = 166
  SYS_PIVOT_ROOT = 155
  SYS_CHDIR      = 80
  SYS_MKDIR      = 83
  SYS_RMDIR      = 84
  SYS_FCHDIR     = 81

  MS_RDONLY*      = 0x00000001
  MS_NOSUID*      = 0x00000002
  MS_NODEV*       = 0x00000004
  MS_NOEXEC*      = 0x00000008
  MS_SYNCHRONOUS* = 0x00000010
  MS_REMOUNT*     = 0x00000020
  MS_BIND*        = 0x00001000
  MS_REC*         = 0x00004000
  MS_PRIVATE*     = 0x00040000
  MS_SLAVE*       = 0x00080000
  MS_SHARED*      = 0x00100000
  MS_LAZYTIME*    = 0x00200000

  MNT_FORCE*      = 0x00000001
  MNT_DETACH*     = 0x00000002
  MNT_EXPIRE*     = 0x00000004
  UMOUNT_NOFOLLOW* = 0x00000008

  S_IRWXU        = 0o700
  S_IRWXUGO      = 0o777

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  RootfsError* = object of OSError
    ## Raised when a rootfs operation fails.

  OverlayConfig* = object
    ## Configuration for an overlayfs mount.
    lowerDir*: string  ## Read-only lower layer (base image)
    upperDir*: string  ## Read-write upper layer (container changes)
    workDir*: string   ## Work directory for overlayfs internals
    target*: string    ## Mount point for the merged view

# ---------------------------------------------------------------------------
# Syscall wrappers
# ---------------------------------------------------------------------------

proc syscall1(n: clong; a1: clong): clong
  {.importc: "syscall", header: "<unistd.h>".}

proc syscall2(n: clong; a1, a2: clong): clong
  {.importc: "syscall", header: "<unistd.h>".}

proc syscall3(n: clong; a1, a2, a3: clong): clong
  {.importc: "syscall", header: "<unistd.h>".}

proc syscall5(n: clong; a1, a2, a3, a4, a5: clong): clong
  {.importc: "syscall", header: "<unistd.h>".}

proc rawMount*(source, target, fstype: cstring; flags: culong; data: cstring): cint =
  ## Low-level mount(2) wrapper. Exported for testing.
  let rc = syscall5(SYS_MOUNT, cast[clong](source), cast[clong](target),
                     cast[clong](fstype), flags.clong, cast[clong](data))
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

proc rawUmount2(target: cstring; flags: cint): cint =
  let rc = syscall2(SYS_UMOUNT2, cast[clong](target), flags.clong)
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

proc rawPivotRoot(newRoot, putOld: cstring): cint =
  let rc = syscall2(SYS_PIVOT_ROOT, cast[clong](newRoot), cast[clong](putOld))
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

proc rawChdir(path: cstring): cint =
  let rc = syscall1(SYS_CHDIR, cast[clong](path))
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

proc rawMkdir(path: cstring; mode: cint): cint =
  let rc = syscall2(SYS_MKDIR, cast[clong](path), mode.clong)
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

proc rawRmdir(path: cstring): cint =
  let rc = syscall1(SYS_RMDIR, cast[clong](path))
  if rc < 0:
    errno = cint(-rc)
    return -1
  0

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc ensureDir(path: string; mode: cint = S_IRWXU.cint): cint =
  ## Create a directory if it doesn't exist. Returns 0 on success.
  if not dirExists(path):
    result = rawMkdir(cstring(path), mode)
    if result < 0 and errno == EEXIST:
      result = 0
  else:
    result = 0

proc isMountPoint(path: string): bool =
  ## Check if `path` is a mount point by comparing st_dev of path and parent.
  var stPath, stParent: Stat
  if stat(cstring(path), stPath) < 0:
    return false
  let parent = parentDir(path)
  if stat(cstring(parent), stParent) < 0:
    return false
  result = stPath.st_dev != stParent.st_dev

proc raiseRootfsErr(msg: string) {.noinline, noreturn.} =
  raise newException(RootfsError, msg & ": " & osErrorMsg(osLastError()))

# ---------------------------------------------------------------------------
# Public API — low-level
# ---------------------------------------------------------------------------

proc mountOverlay*(lowerDir, upperDir, workDir, target: string): cint {.discardable.} =
  ## Mount an overlayfs combining lowerDir (ro) and upperDir (rw) at target.
  ## Creates upperDir, workDir, and target directories if missing.
  ## Returns 0 on success, -1 on error (check errno).
  ##
  ## Example:
  ##   discard mountOverlay("/image", "/containers/c1/upper",
  ##                        "/containers/c1/work", "/containers/c1/root")

  # Ensure overlay directories exist
  if ensureDir(upperDir) < 0: return -1
  if ensureDir(workDir) < 0: return -1
  if ensureDir(target) < 0: return -1

  let opts = "lowerdir=" & lowerDir & ",upperdir=" & upperDir & ",workdir=" & workDir
  result = rawMount("overlay", cstring(target), "overlay", 0, cstring(opts))

proc umount*(target: string; flags: cint = 0): cint {.discardable.} =
  ## Unmount a filesystem at `target`.
  ## Returns 0 on success, -1 on error (check errno).
  ##
  ## Common flags: MNT_DETACH (lazy unmount), MNT_FORCE.
  result = rawUmount2(cstring(target), flags)

proc pivotRoot*(newRoot: string): cint {.discardable.} =
  ## Change the root filesystem to `newRoot` using pivot_root(2).
  ##
  ## This helper:
  ## 1. Ensures the current root is a mount point (bind-mounts if needed).
  ## 2. Creates a `put_old` directory inside newRoot.
  ## 3. Calls pivot_root(newRoot, newRoot/put_old).
  ## 4. Changes cwd to /.
  ## 5. Unmounts the old root and removes put_old.
  ##
  ## Returns 0 on success, -1 on error (check errno).
  ## Requires CAP_SYS_ADMIN.

  let putOld = newRoot / "put_old"

  # Ensure current root is a mount point (required by pivot_root).
  if not isMountPoint("/"):
    if rawMount("/", "/", nil, MS_BIND or MS_REC, nil) < 0:
      return -1

  # Create put_old directory inside new_root.
  if ensureDir(putOld) < 0:
    return -1

  # Perform pivot_root.
  if rawPivotRoot(cstring(newRoot), cstring(putOld)) < 0:
    return -1

  # Change to new root.
  if rawChdir("/") < 0:
    return -1

  # Unmount old root and clean up.
  if rawUmount2("/put_old", MNT_DETACH) < 0:
    # Non-fatal: old root may still have active references.
    discard
  if rawRmdir("/put_old") < 0:
    discard

  0

# ---------------------------------------------------------------------------
# Global slots for passing rootfs data through clone(2)
# ---------------------------------------------------------------------------

var
  gRootfsPath: string
  gContainerDir: string

# ---------------------------------------------------------------------------
# Public API — high-level
# ---------------------------------------------------------------------------

proc prepareRootfs*(imagePath: string; containerDir: string): string =
  ## Set up an overlayfs root filesystem for a container.
  ##
  ## Creates upper, work, and merged directories under `containerDir`.
  ## Mounts overlayfs with `imagePath` as the lower (read-only) layer.
  ## Returns the path to the merged rootfs on success.
  ##
  ## Raises RootfsError on failure.
  ##
  ## Example:
  ##   let rootfs = prepareRootfs("/var/lib/ferrite/images/alpine", "/var/lib/ferrite/c1")

  let
    upperDir = containerDir / "upper"
    workDir  = containerDir / "work"
    merged   = containerDir / "merged"

  if not dirExists(imagePath):
    raiseRootfsErr("image path does not exist: " & imagePath)

  if ensureDir(upperDir) < 0:
    raiseRootfsErr("failed to create upper dir")
  if ensureDir(workDir) < 0:
    raiseRootfsErr("failed to create work dir")
  if ensureDir(merged) < 0:
    raiseRootfsErr("failed to create merged dir")

  if mountOverlay(imagePath, upperDir, workDir, merged) < 0:
    raiseRootfsErr("failed to mount overlayfs")

  result = merged

proc teardownRootfs*(mergedDir: string) {.discardable.} =
  ## Unmount the overlayfs at `mergedDir` and remove the directory.
  ## Ignores errors (idempotent).
  discard umount(mergedDir, MNT_DETACH)
  discard rawRmdir(cstring(mergedDir))

proc runInRootfs*(nss: set[Namespace]; rootfs: string;
                  cmd: string; args: openArray[string] = [];
                  cgroupName: string = ""): cint =
  ## High-level helper: clone into namespaces, set up rootfs via overlayfs +
  ## pivot_root, then execvp(cmd, args) in child.
  ## Blocks until the child exits. Returns the child's exit status.
  ##
  ## If `cgroupName` is provided, the child is moved into that cgroup after
  ## cloning. The caller is responsible for cgroup cleanup.
  ##
  ## If `rootfs` points to a directory with "upper", "work", "merged"
  ## subdirectories, uses those directly. Otherwise creates them under
  ## `/tmp/ferrite-<pid>`.
  ##
  ## Example:
  ##   let rc = runInRootfs({nsPid, nsMount}, "/var/lib/ferrite/images/alpine", "/bin/sh")

  var containerDir: string
  let hasLayout = dirExists(rootfs / "upper") and dirExists(rootfs / "work") and
                  dirExists(rootfs / "merged")
  if hasLayout:
    containerDir = rootfs
  else:
    containerDir = "/tmp/ferrite-" & $getpid()

  gRootfsPath = rootfs
  gContainerDir = containerDir

  var argSeq: seq[string] = @[cmd] & @args
  var cargv = allocCStringArray(argSeq)

  proc rootfsChild(ctx: pointer): cint {.noconv.} =
    let argv = cast[cstringArray](ctx)

    # 1. Set up overlayfs
    var merged: string
    try:
      merged = prepareRootfs(gRootfsPath, gContainerDir)
    except RootfsError:
      stderr.writeLine("ferrite: prepareRootfs failed: ", osErrorMsg(osLastError()))
      return 126

    # 2. Pivot into new root
    if pivotRoot(merged) < 0:
      stderr.writeLine("ferrite: pivot_root failed: ", osErrorMsg(osLastError()))
      return 126

    # 3. Exec the command (or run as init if PID namespace is used)
    if nsPid in nss:
      runAsInit(argv)
    else:
      discard execvp(cstring(argv[0]), argv)
      stderr.writeLine("ferrite: execvp failed: ", osErrorMsg(osLastError()))
      127

  let pid = cloneIsolate(nss, rootfsChild, cargv)

  # Move child into cgroup immediately after clone
  if cgroupName.len > 0:
    discard moveProcessToCgroup(pid, cgroupName)

  gRootfsPath = ""
  gContainerDir = ""

  var status: cint
  if waitpid(pid, status, 0) < 0:
    deallocCStringArray(cargv)
    raiseOSError(osLastError())

  deallocCStringArray(cargv)

  if WIFEXITED(status):
    WEXITSTATUS(status)
  elif WIFSIGNALED(status):
    128 + WTERMSIG(status)
  else:
    -1

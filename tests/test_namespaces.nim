# ferrite — Namespace Isolation Tests
#
# Phase 1 test suite.  Requires root or CAP_SYS_ADMIN for namespace tests.
# Run with:  nim c -r tests/test_namespaces.nim
# Or as root:  sudo nim c -r tests/test_namespaces.nim

import std/[os, posix, unittest]
import ferrite/namespaces

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc getInode(path: string): string =
  try:
    expandSymlink(path).lastPathPart
  except OSError:
    ""

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Namespace flag composition":

  test "empty set yields only SIGCHLD":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      var childRan = false
      proc child(ctx: pointer): cint {.noconv.} =
        childRan = true
        0

      let pid = cloneIsolate({}, child)
      check pid > 0
      var status: cint
      discard waitpid(pid, status, 0)
      check childRan

  test "single namespace flag":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      var ok = false
      proc child(ctx: pointer): cint {.noconv.} =
        ok = true
        0
      let pid = cloneIsolate({nsUts}, child)
      check pid > 0
      var status: cint
      discard waitpid(pid, status, 0)
      check ok

  test "multiple namespace flags":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      var ok = false
      proc child(ctx: pointer): cint {.noconv.} =
        ok = true
        0
      let pid = cloneIsolate({nsUts, nsIpc, nsNet}, child)
      check pid > 0
      var status: cint
      discard waitpid(pid, status, 0)
      check ok

suite "UTS namespace isolation":

  test "hostname differs in new UTS namespace":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      let hostBefore = hostname()

      var childHost: string
      proc child(ctx: pointer): cint {.noconv.} =
        if setHostname("ferrite-test") == 0:
          childHost = hostname()
        else:
          childHost = "ERROR"
        0

      let pid = cloneIsolate({nsUts}, child)
      check pid > 0
      var status: cint
      discard waitpid(pid, status, 0)

      check childHost == "ferrite-test"
      check hostname() == hostBefore   # host unchanged

suite "PID namespace isolation":

  test "child is PID 1 in new PID namespace":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      var childPid: Pid
      proc child(ctx: pointer): cint {.noconv.} =
        childPid = getpid()
        0

      let pid = cloneIsolate({nsPid, nsUts, nsNet, nsIpc, nsMount}, child)
      check pid > 0
      var status: cint
      discard waitpid(pid, status, 0)

      check childPid == 1

suite "unshare":

  test "unshare UTS changes hostname locally":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      let orig = hostname()

      check unshareNamespaces({nsUts}) == 0
      discard setHostname("unshare-test")
      check hostname() == "unshare-test"

      # Restore (best effort — may fail in some container setups)
      discard setHostname(orig)

suite "executeInNamespace":

  test "exec /bin/true returns 0":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/true"):
        echo "  [SKIP] /bin/true not found"
      else:
        let rc = executeInNamespace({nsMount}, "/bin/true")
        check rc == 0

  test "exec /bin/false returns 1":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/false"):
        echo "  [SKIP] /bin/false not found"
      else:
        let rc = executeInNamespace({nsMount}, "/bin/false")
        check rc == 1

  test "exec with arguments":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        let rc = executeInNamespace({nsMount}, "/bin/sh", ["-c", "exit 42"])
        check rc == 42

suite "Namespace inode divergence":

  test "mount namespace inode differs after clone":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      let before = getInode("/proc/self/ns/mnt")
      var after: string
      proc child(ctx: pointer): cint {.noconv.} =
        after = getInode("/proc/self/ns/mnt")
        0
      let pid = cloneIsolate({nsMount}, child)
      check pid > 0
      var status: cint
      discard waitpid(pid, status, 0)
      check after != ""
      check after != before

  test "net namespace inode differs after clone":
    if getuid() != 0:
      echo "  [SKIP] requires root"
    else:
      let before = getInode("/proc/self/ns/net")
      var after: string
      proc child(ctx: pointer): cint {.noconv.} =
        after = getInode("/proc/self/ns/net")
        0
      let pid = cloneIsolate({nsNet}, child)
      check pid > 0
      var status: cint
      discard waitpid(pid, status, 0)
      check after != ""
      check after != before

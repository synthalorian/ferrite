# ferrite — Process Lifecycle Management Tests
#
# Phase 4 test suite. Requires root or CAP_SYS_ADMIN for namespace tests.
# Run with:  nim c --path:src -r tests/test_lifecycle.nim
# Or as root:  sudo nim c --path:src -r tests/test_lifecycle.nim

import std/[os, posix, unittest]
import ferrite/lifecycle
import ferrite/namespaces

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isRoot(): bool = getuid() == 0

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "runAsInit basic execution":

  test "runAsInit /bin/true returns 0":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/true"):
        echo "  [SKIP] /bin/true not found"
      else:
        let rc = runAsInit("/bin/true")
        check rc == 0

  test "runAsInit /bin/false returns 1":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/false"):
        echo "  [SKIP] /bin/false not found"
      else:
        let rc = runAsInit("/bin/false")
        check rc == 1

  test "runAsInit propagates exit code":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        let rc = runAsInit("/bin/sh", ["-c", "exit 42"])
        check rc == 42

  test "runAsInit passes arguments":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        let rc = runAsInit("/bin/sh", ["-c", "test \"$1\" = hello", "_", "hello"])
        check rc == 0

suite "Init process in PID namespace":

  test "executeInNamespace with PID ns uses init process":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        # When nsPid is in the set, the child should be PID 1 (init)
        # and should properly reap.  We test by running a simple command.
        let rc = executeInNamespace({nsPid, nsMount}, "/bin/sh", ["-c", "exit 0"])
        check rc == 0

  test "init process reaps zombie children":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        # In a PID namespace, if a child forks and exits, the grandchild
        # is re-parented to PID 1.  Our init should reap it.
        # We test this by having the main child create an orphan that exits
        # before the main child, so init must reap it before exiting.
        var childResult: cint
        proc child(ctx: pointer): cint {.noconv.} =
          # This runs as PID 1 (init) because we're in a PID namespace
          # Script: fork a background sleep, then wait a bit so it can exit,
          # then exit with a specific code. Init should reap the sleep.
          let rc = runAsInit("/bin/sh", ["-c",
            "(sleep 0.1) &" &            # fork background sleep
            " sleep 0.2;" &               # give sleep time to finish
            " exit 42"])                  # main child exits with 42
          childResult = rc
          rc

        let pid = cloneIsolate({nsPid, nsMount, nsUts}, child)
        check pid > 0
        var status: cint
        discard waitpid(pid, status, 0)
        # Init should have returned the main child's exit code
        check childResult == 42

  test "init forwards signals to child":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        # Start a long-running sleep in a PID namespace.
        # Send SIGTERM to the init process and verify the child exits.
        var initPid: Pid
        proc child(ctx: pointer): cint {.noconv.} =
          initPid = getpid()
          let rc = runAsInit("/bin/sh", ["-c", "sleep 10"])
          rc

        let pid = cloneIsolate({nsPid, nsMount, nsUts}, child)
        check pid > 0

        # Give init time to set up and fork the child
        discard usleep(200_000)

        # Send SIGTERM to init — it should forward to the sleep child
        discard kill(pid, SIGTERM)

        var status: cint
        discard waitpid(pid, status, 0)

        # The child (sleep) should have been killed by SIGTERM (128 + 15 = 143)
        # or init might exit with that code
        let rc = if WIFEXITED(status): WEXITSTATUS(status)
                 elif WIFSIGNALED(status): 128 + WTERMSIG(status)
                 else: -1
        check rc == 143 or rc == 128 + SIGTERM

suite "ContainerProcess tracking":

  test "waitContainer captures normal exit":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      proc child(ctx: pointer): cint {.noconv.} =
        discard usleep(50_000)
        42

      var cp: ContainerProcess
      cp.initPid = cloneIsolate({nsUts}, child)
      cp.state = psRunning
      check cp.initPid > 0

      let rc = waitContainer(cp)
      check rc == 42
      check cp.state == psExited
      check cp.exitCode == 42

  test "waitContainer captures signaled state":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      proc child(ctx: pointer): cint {.noconv.} =
        # Wait to be killed
        discard usleep(500_000)
        0

      var cp: ContainerProcess
      cp.initPid = cloneIsolate({nsUts}, child)
      cp.state = psRunning
      check cp.initPid > 0

      # Send SIGKILL to the init process
      discard kill(cp.initPid, SIGKILL)

      let rc = waitContainer(cp)
      check rc == 128 + SIGKILL
      check cp.state == psSignaled
      check cp.exitCode == 128 + SIGKILL

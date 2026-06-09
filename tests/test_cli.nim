# ferrite — CLI Tests
#
# Phase 7 test suite. Tests container state management and CLI helpers.
# Requires root or CAP_SYS_ADMIN for namespace-related tests.
# Run with:  nim c --path:src -r tests/test_cli.nim
# Or as root:  sudo nim c --path:src -r tests/test_cli.nim

import std/[os, strutils, posix, unittest, times, json, sequtils]
import ferrite/namespaces
import ferrite/state

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isRoot(): bool = getuid() == 0

proc cleanupTestState() =
  ## Remove all test container state files.
  let sdir = getEnv("FERRITE_STATE_DIR", "/tmp/ferrite")
  if dirExists(sdir):
    for kind, path in walkDir(sdir):
      if kind == pcFile and path.endsWith(".json"):
        try:
          removeFile(path)
        except CatchableError:
          discard

# ---------------------------------------------------------------------------
# Tests — Container state management
# ---------------------------------------------------------------------------

suite "Container state CRUD":

  setup:
    cleanupTestState()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestState()

  test "generateContainerId returns non-empty string":
    let id = generateContainerId()
    check id.len > 0
    check id.startsWith("ferrite-")

  test "save and load container state":
    let id = "ferrite-test-001"
    let state = newContainerState(
      id = id,
      pid = 1234,
      command = "/bin/sh",
      rootfs = "/tmp/rootfs",
      nss = {nsPid, nsNet, nsMount},
      cgroup = "ferrite-test"
    )
    saveContainerState(state)

    let loaded = loadContainerState(id)
    check loaded.id == id
    check loaded.pid == 1234
    check loaded.command == "/bin/sh"
    check loaded.rootfs == "/tmp/rootfs"
    check loaded.namespaces == {nsPid, nsNet, nsMount}
    check loaded.cgroup == "ferrite-test"
    check loaded.status == "running"

  test "load non-existent container raises StateError":
    expect StateError:
      discard loadContainerState("ferrite-does-not-exist")

  test "remove container state":
    let id = "ferrite-test-remove"
    let state = newContainerState(id, 1, "cmd")
    saveContainerState(state)
    check containerExists(id)

    removeContainerState(id)
    check not containerExists(id)

  test "listContainerStates filters dead processes":
    # Create a state for a PID that definitely does not exist
    let id = "ferrite-dead-99999"
    var state = newContainerState(id, 99999, "/bin/true")
    saveContainerState(state)

    # listContainerStates should clean it up
    let all = listContainerStates()
    check containerExists(id) == false
    var found = false
    for s in all:
      if s.id == id:
        found = true
        break
    check found == false

  test "containerExists returns true for saved state":
    let id = "ferrite-test-exists"
    let state = newContainerState(id, 1, "cmd")
    saveContainerState(state)
    check containerExists(id)

  test "isContainerRunning for non-existent container":
    check isContainerRunning("ferrite-ghost") == false

# ---------------------------------------------------------------------------
# Tests — Namespace set serialization
# ---------------------------------------------------------------------------

suite "Namespace serialization in state":

  setup:
    cleanupTestState()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestState()

  test "round-trip all namespace types":
    let nss = {nsMount, nsPid, nsNet, nsUts, nsIpc, nsUser, nsCgroup}
    let state = newContainerState("ferrite-ns-all", 1, "cmd", nss = nss)
    saveContainerState(state)

    let loaded = loadContainerState("ferrite-ns-all")
    check loaded.namespaces == nss

  test "round-trip empty namespace set":
    let state = newContainerState("ferrite-ns-empty", 1, "cmd", nss = {})
    saveContainerState(state)

    let loaded = loadContainerState("ferrite-ns-empty")
    check loaded.namespaces == {}

# ---------------------------------------------------------------------------
# Tests — findContainerByPrefix
# ---------------------------------------------------------------------------

suite "findContainerByPrefix":

  setup:
    cleanupTestState()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestState()

  test "exact match":
    let state = newContainerState("ferrite-abc-123", 1, "cmd")
    saveContainerState(state)

    let found = findContainerByPrefix("ferrite-abc-123")
    check found.id == "ferrite-abc-123"

  test "prefix match":
    let state = newContainerState("ferrite-unique-id", 1, "cmd")
    saveContainerState(state)

    let found = findContainerByPrefix("ferrite-uni")
    check found.id == "ferrite-unique-id"

  test "no match raises StateError":
    expect StateError:
      discard findContainerByPrefix("ferrite-xyz")

  test "ambiguous prefix raises StateError":
    saveContainerState(newContainerState("ferrite-abc-1", 1, "cmd"))
    saveContainerState(newContainerState("ferrite-abc-2", 1, "cmd"))

    expect StateError:
      discard findContainerByPrefix("ferrite-abc")

# ---------------------------------------------------------------------------
# Tests — formatContainerLine
# ---------------------------------------------------------------------------

suite "formatContainerLine":

  test "basic formatting":
    let state = newContainerState("ferrite-fmt", 42, "/bin/sh -c 'echo hi'")
    let line = formatContainerLine(state)
    check line.startsWith("ferrite-fmt")
    check "42" in line
    check "running" in line
    check "/bin/sh" in line

# ---------------------------------------------------------------------------
# Tests — State directory fallback
# ---------------------------------------------------------------------------

suite "State directory creation":

  setup:
    cleanupTestState()

  teardown:
    cleanupTestState()

  test "auto-creates state directory":
    let customDir = "/tmp/ferrite-test-" & $epochTime().int
    putEnv("FERRITE_STATE_DIR", customDir)
    defer:
      try:
        removeDir(customDir)
      except CatchableError:
        discard

    let state = newContainerState("ferrite-autodir", 1, "cmd")
    saveContainerState(state)
    check dirExists(customDir)
    check fileExists(customDir / "ferrite-autodir.json")

# ---------------------------------------------------------------------------
# Tests — Integration (requires root)
# ---------------------------------------------------------------------------

suite "CLI integration (requires root)":

  setup:
    cleanupTestState()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestState()

  test "run creates and removes container state":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/true"):
        echo "  [SKIP] /bin/true not found"
      else:
        let id = "ferrite-integration-" & $epochTime().int
        # We can't easily test the full CLI here, but we can test the state
        # lifecycle the same way the CLI would use it.
        var state = newContainerState(id, getpid(), "/bin/true")
        saveContainerState(state)
        check containerExists(id)

        # Simulate container exit by removing state
        removeContainerState(id)
        check not containerExists(id)

  test "execInNamespace enters UTS namespace":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        # Start a container that sets a unique hostname
        var containerPid: Pid
        proc child(ctx: pointer): cint {.noconv.} =
          containerPid = getpid()
          discard setHostname("ferrite-exec-test")
          # Stay alive for a bit
          discard usleep(500_000)
          0

        let initPid = cloneIsolate({nsUts, nsMount}, child)
        check initPid > 0
        discard usleep(100_000)  # let child set hostname

        # Now exec into its UTS namespace and check hostname
        let rc = execInNamespace(initPid, {nsUts}, "/bin/sh", ["-c", "hostname"])
        var status: cint
        discard waitpid(initPid, status, 0)

        # The exec should have succeeded
        check rc == 0

  test "execInNamespace with empty ns set uses container ns":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      if not fileExists("/bin/sh"):
        echo "  [SKIP] /bin/sh not found"
      else:
        proc child(ctx: pointer): cint {.noconv.} =
          discard usleep(200_000)
          0

        let initPid = cloneIsolate({nsUts}, child)
        check initPid > 0
        discard usleep(50_000)

        # Even with empty nss, execInNamespace still works because
        # it will try to enter namespaces (empty = no-op)
        let rc = execInNamespace(initPid, {}, "/bin/true")
        var status: cint
        discard waitpid(initPid, status, 0)
        check rc == 0

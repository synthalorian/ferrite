# ferrite — OCI Runtime Spec Compatibility Tests
#
# Phase 8 test suite. Tests OCI bundle parsing, state management,
# and OCI command lifecycle (create, start, state, delete).
# Run with:  nim c --path:src -r tests/test_oci.nim
#
# Requires root or CAP_SYS_ADMIN for namespace-related tests.

import std/[os, strutils, json, unittest, times, sequtils]
import ferrite/oci
import ferrite/state
import ferrite/namespaces

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isRoot(): bool = getuid() == 0

proc cleanupTestOci() =
  ## Remove all test container state and OCI metadata files.
  let sdir = getEnv("FERRITE_STATE_DIR", "/tmp/ferrite")
  if dirExists(sdir):
    for kind, path in walkDir(sdir):
      if kind == pcFile and (path.endsWith(".json") or path.endsWith(".oci.json")):
        try:
          removeFile(path)
        except CatchableError:
          discard

proc makeTestBundle(path: string; withConfig = true) =
  ## Create a minimal OCI bundle for testing.
  createDir(path / "rootfs")
  if withConfig:
    let config = %*{
      "ociVersion": "1.0.2",
      "process": {
        "terminal": false,
        "user": {"uid": 0, "gid": 0},
        "args": ["/bin/sh"],
        "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        "cwd": "/"
      },
      "root": {
        "path": "rootfs",
        "readonly": false
      },
      "hostname": "test-container",
      "linux": {
        "namespaces": [
          {"type": "pid"},
          {"type": "network"},
          {"type": "mount"},
          {"type": "uts"},
          {"type": "ipc"}
        ]
      }
    }
    writeFile(path / "config.json", $config & "\n")

# ---------------------------------------------------------------------------
# Tests — Bundle validation
# ---------------------------------------------------------------------------

suite "Bundle validation":

  setup:
    cleanupTestOci()

  teardown:
    cleanupTestOci()

  test "valid bundle passes validation":
    let bundleDir = "/tmp/ferrite-test-bundle-" & $epochTime().int
    createDir(bundleDir / "rootfs")
    let config = %*{
      "ociVersion": "1.0.2",
      "process": {"args": ["/bin/sh"]},
      "root": {"path": "rootfs"}
    }
    writeFile(bundleDir / "config.json", $config & "\n")

    check validateBundle(bundleDir) == ""

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "missing config.json fails validation":
    let bundleDir = "/tmp/ferrite-test-bundle-nocfg"
    createDir(bundleDir / "rootfs")

    check validateBundle(bundleDir) == "missing config.json"

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "missing rootfs fails validation":
    let bundleDir = "/tmp/ferrite-test-bundle-norootfs"
    createDir(bundleDir)
    let config = %*{
      "ociVersion": "1.0.2",
      "process": {"args": ["/bin/sh"]}
    }
    writeFile(bundleDir / "config.json", $config & "\n")

    check validateBundle(bundleDir) == "missing rootfs/ directory"

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# Tests — OCI config parsing
# ---------------------------------------------------------------------------

suite "OCI config parsing":

  setup:
    cleanupTestOci()

  teardown:
    cleanupTestOci()

  test "parse minimal config":
    let bundleDir = "/tmp/ferrite-test-parse-" & $epochTime().int
    makeTestBundle(bundleDir)

    let config = parseOciConfig(bundleDir)
    check config.ociVersion == "1.0.2"
    check config.process.args == @["/bin/sh"]
    check config.root.path == "rootfs"
    check config.hostname == "test-container"

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "parse config with namespaces":
    let bundleDir = "/tmp/ferrite-test-ns-" & $epochTime().int
    makeTestBundle(bundleDir)

    let config = parseOciConfig(bundleDir)
    check config.linuxNamespaces.len == 5
    check config.linuxNamespaces[0].nstype == "pid"
    check config.linuxNamespaces[1].nstype == "network"

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "parse config with resources":
    let bundleDir = "/tmp/ferrite-test-res-" & $epochTime().int
    createDir(bundleDir / "rootfs")
    let config = %*{
      "ociVersion": "1.0.2",
      "process": {"args": ["/bin/sh"]},
      "root": {"path": "rootfs"},
      "linux": {
        "resources": {
          "cpu": {"shares": 1024, "quota": 100000, "period": 100000},
          "memory": {"limit": 134217728},
          "pids": {"limit": 100}
        }
      }
    }
    writeFile(bundleDir / "config.json", $config & "\n")

    let parsed = parseOciConfig(bundleDir)
    check parsed.linuxResources.cpuShares == 1024
    check parsed.linuxResources.cpuQuota == 100000
    check parsed.linuxResources.cpuPeriod == 100000
    check parsed.linuxResources.memoryLimit == 134217728
    check parsed.linuxResources.pidsLimit == 100

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "parse missing bundle raises OciError":
    expect OciError:
      discard parseOciConfig("/tmp/ferrite-does-not-exist-12345")

# ---------------------------------------------------------------------------
# Tests — OCI state
# ---------------------------------------------------------------------------

suite "OCI state":

  test "newOciState creates correct structure":
    let state = newOciState("mycontainer", "/path/to/bundle", "created")
    check state.ociVersion == OciVersion
    check state.id == "mycontainer"
    check state.status == "created"
    check state.pid == 0
    check state.bundle == "/path/to/bundle"

  test "toJson produces valid OCI state":
    let state = newOciState("test-id", "/bundle", "running", 1234)
    let j = toJson(state)
    check j{"ociVersion"}.getStr == OciVersion
    check j{"id"}.getStr == "test-id"
    check j{"status"}.getStr == "running"
    check j{"pid"}.getInt == 1234
    check j{"bundle"}.getStr == "/bundle"

# ---------------------------------------------------------------------------
# Tests — OCI create
# ---------------------------------------------------------------------------

suite "OCI create":

  setup:
    cleanupTestOci()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestOci()

  test "create writes state as 'created'":
    let bundleDir = "/tmp/ferrite-test-create-" & $epochTime().int
    makeTestBundle(bundleDir)

    ociCreate("ferrite-oci-test", bundleDir)

    let state = loadContainerState("ferrite-oci-test")
    check state.status == "created"
    check state.id == "ferrite-oci-test"
    check state.rootfs == bundleDir / "rootfs"

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "create with existing ID raises error":
    let bundleDir = "/tmp/ferrite-test-dup-" & $epochTime().int
    makeTestBundle(bundleDir)

    ociCreate("ferrite-dup", bundleDir)

    expect OciError:
      ociCreate("ferrite-dup", bundleDir)

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "create saves OCI metadata":
    let bundleDir = "/tmp/ferrite-test-meta-" & $epochTime().int
    makeTestBundle(bundleDir)

    ociCreate("ferrite-meta", bundleDir)

    let metaPath = "/tmp/ferrite/ferrite-meta.oci.json"
    check fileExists(metaPath)

    let meta = parseJson(readFile(metaPath))
    check meta{"bundle"}.getStr == bundleDir
    check meta{"hostname"}.getStr == "test-container"

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# Tests — OCI state command
# ---------------------------------------------------------------------------

suite "OCI state command":

  setup:
    cleanupTestOci()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestOci()

  test "ociState returns correct state":
    let bundleDir = "/tmp/ferrite-test-state-" & $epochTime().int
    makeTestBundle(bundleDir)

    ociCreate("ferrite-state-test", bundleDir)

    let ostate = ociState("ferrite-state-test")
    check ostate.id == "ferrite-state-test"
    check ostate.status == "created"
    check ostate.bundle == bundleDir

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "ociState for missing container raises error":
    expect OciError:
      discard ociState("ferrite-missing-12345")

# ---------------------------------------------------------------------------
# Tests — OCI delete
# ---------------------------------------------------------------------------

suite "OCI delete":

  setup:
    cleanupTestOci()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestOci()

  test "delete removes container state":
    let bundleDir = "/tmp/ferrite-test-del-" & $epochTime().int
    makeTestBundle(bundleDir)

    ociCreate("ferrite-del-test", bundleDir)
    check containerExists("ferrite-del-test")

    ociDelete("ferrite-del-test")
    check not containerExists("ferrite-del-test")

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "delete cleans up OCI metadata":
    let bundleDir = "/tmp/ferrite-test-del-meta-" & $epochTime().int
    makeTestBundle(bundleDir)

    ociCreate("ferrite-del-meta", bundleDir)
    ociDelete("ferrite-del-meta")

    let metaPath = "/tmp/ferrite/ferrite-del-meta.oci.json"
    check not fileExists(metaPath)

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

  test "delete missing container raises error":
    expect OciError:
      ociDelete("ferrite-missing-99999")

# ---------------------------------------------------------------------------
# Tests — OCI kill
# ---------------------------------------------------------------------------

suite "OCI kill":

  setup:
    cleanupTestOci()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestOci()

  test "ociKill missing container raises error":
    expect OciError:
      ociKill("ferrite-missing-99999", SIGTERM)

# ---------------------------------------------------------------------------
# Tests — Namespace mapping
# ---------------------------------------------------------------------------

suite "Namespace mapping":

  test "OCI namespace types map correctly":
    # Test indirectly via config parsing
    let bundleDir = "/tmp/ferrite-test-nsmap-" & $epochTime().int
    createDir(bundleDir / "rootfs")
    let config = %*{
      "ociVersion": "1.0.2",
      "process": {"args": ["/bin/sh"]},
      "root": {"path": "rootfs"},
      "linux": {
        "namespaces": [
          {"type": "pid"},
          {"type": "network"},
          {"type": "mount"},
          {"type": "uts"},
          {"type": "ipc"},
          {"type": "user"},
          {"type": "cgroup"}
        ]
      }
    }
    writeFile(bundleDir / "config.json", $config & "\n")

    let parsed = parseOciConfig(bundleDir)
    check parsed.linuxNamespaces.len == 7

    try:
      removeDir(bundleDir)
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# Tests — Integration (requires root)
# ---------------------------------------------------------------------------

suite "OCI integration (requires root)":

  setup:
    cleanupTestOci()
    putEnv("FERRITE_STATE_DIR", "/tmp/ferrite")

  teardown:
    cleanupTestOci()

  test "full create-delete lifecycle":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let bundleDir = "/tmp/ferrite-test-lifecycle-" & $epochTime().int
      makeTestBundle(bundleDir)

      let id = "ferrite-oci-lifecycle"
      ociCreate(id, bundleDir)
      check containerExists(id)
      check loadContainerState(id).status == "created"

      # Delete without starting
      ociDelete(id)
      check not containerExists(id)

      try:
        removeDir(bundleDir)
      except CatchableError:
        discard

  test "ociListStates returns created containers":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let bundleDir = "/tmp/ferrite-test-list-" & $epochTime().int
      makeTestBundle(bundleDir)

      ociCreate("ferrite-list-1", bundleDir)
      ociCreate("ferrite-list-2", bundleDir)

      let states = ociListStates()
      var found1, found2 = false
      for s in states:
        if s.id == "ferrite-list-1": found1 = true
        if s.id == "ferrite-list-2": found2 = true
      check found1
      check found2

      try:
        removeDir(bundleDir)
      except CatchableError:
        discard

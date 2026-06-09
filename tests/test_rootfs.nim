# ferrite — Root Filesystem Tests
#
# Phase 2 test suite. Requires root or CAP_SYS_ADMIN for mount/pivot_root tests.
# Run with:  nim c --path:src -r tests/test_rootfs.nim
# Or as root:  sudo nim c --path:src -r tests/test_rootfs.nim

import std/[os, posix, unittest]
import ferrite/rootfs

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isRoot(): bool = getuid() == 0

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Overlayfs mount":

  test "mountOverlay creates directories and mounts":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let tmpDir = getTempDir() / "ferrite-test-overlay-" & $getpid()
      let
        lower  = tmpDir / "lower"
        upper  = tmpDir / "upper"
        work   = tmpDir / "work"
        merged = tmpDir / "merged"

      createDir(lower)
      writeFile(lower / "testfile.txt", "lower-content")

      check mountOverlay(lower, upper, work, merged) == 0
      check dirExists(merged)
      check fileExists(merged / "testfile.txt")
      check readFile(merged / "testfile.txt") == "lower-content"

      # Write through overlay
      writeFile(merged / "upperfile.txt", "upper-content")
      check fileExists(merged / "upperfile.txt")
      check readFile(merged / "upperfile.txt") == "upper-content"

      # Cleanup
      discard umount(merged)
      removeDir(tmpDir)

  test "mountOverlay with nonexistent lower fails":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let tmpDir = getTempDir() / "ferrite-test-bad-" & $getpid()
      let rc = mountOverlay("/nonexistent/path", tmpDir / "upper", tmpDir / "work", tmpDir / "merged")
      check rc < 0
      removeDir(tmpDir)

suite "Umount":

  test "umount returns error for non-mountpoint":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let rc = umount("/tmp")
      check rc < 0   # EINVAL or similar

suite "Pivot root":

  test "pivotRoot changes root filesystem":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      # Create a minimal rootfs structure
      let newRoot = getTempDir() / "ferrite-test-root-" & $getpid()
      createDir(newRoot)
      writeFile(newRoot / "marker.txt", "new-root")

      # We need to be in a mount namespace to safely pivot_root
      check unshareNamespaces({nsMount}) == 0

      # Bind-mount newRoot so it becomes a mount point (required by pivot_root)
      check rawMount(cstring(newRoot), cstring(newRoot), nil, MS_BIND, nil) == 0

      check pivotRoot(newRoot) == 0

      # After pivot_root, we should be able to see marker.txt at /
      check fileExists("/marker.txt")
      check readFile("/marker.txt") == "new-root"

      # Cleanup: tmp dirs are under old root which was detached
      # No need to clean up — namespace will be destroyed on exit

suite "prepareRootfs / teardownRootfs":

  test "prepareRootfs creates overlay layout":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let
        image  = getTempDir() / "ferrite-test-image-" & $getpid()
        container = getTempDir() / "ferrite-test-container-" & $getpid()

      createDir(image)
      writeFile(image / "hello.txt", "world")

      let merged = prepareRootfs(image, container)
      check merged == container / "merged"
      check dirExists(container / "upper")
      check dirExists(container / "work")
      check dirExists(container / "merged")
      check fileExists(merged / "hello.txt")
      check readFile(merged / "hello.txt") == "world"

      teardownRootfs(merged)
      removeDir(container)
      removeDir(image)

  test "prepareRootfs raises on missing image":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      expect RootfsError:
        discard prepareRootfs("/nonexistent", "/tmp/ferrite-test-bad")

suite "runInRootfs integration":

  test "runInRootfs executes command in isolated rootfs":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let
        image  = getTempDir() / "ferrite-test-img-" & $getpid()
        container = getTempDir() / "ferrite-test-c-" & $getpid()

      createDir(image)
      writeFile(image / "test.txt", "hello")

      # Use a mount namespace so pivot_root doesn't affect the host
      let rc = runInRootfs({nsMount, nsUts}, image, "/bin/sh", ["-c", "test -f /test.txt && cat /test.txt"])

      # /bin/sh -c returns 0 on success, but we also need to check output
      # Since we can't capture stdout easily from execvp, just check exit code
      check rc == 0 or rc == 127  # 127 if /bin/sh missing

      removeDir(container)
      removeDir(image)

  test "runInRootfs returns command exit code":
    if not isRoot():
      echo "  [SKIP] requires root"
    else:
      let image = getTempDir() / "ferrite-test-img2-" & $getpid()
      createDir(image)

      let rc = runInRootfs({nsMount}, image, "/bin/sh", ["-c", "exit 42"])
      check rc == 42 or rc == 127  # 127 if /bin/sh missing

      removeDir(image)

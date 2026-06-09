# Package
version       = "0.1.0"
author        = "synth"
description   = "Minimal container runtime from scratch"
license       = "MIT"
srcDir        = "src"
bin           = @["ferrite"]

# Dependencies
requires "nim >= 2.0.0"

# Test task using testament
proc runAllTests*() =
  exec "nim c --path:src -r tests/test_namespaces.nim"
  exec "nim c --path:src -r tests/test_rootfs.nim"
  exec "nim c --path:src -r tests/test_cgroups.nim"
  exec "nim c --path:src -r tests/test_lifecycle.nim"
  exec "nim c --path:src -r tests/test_monitor.nim"
  exec "nim c --path:src -r tests/test_destruction.nim"
  exec "nim c --path:src -r tests/test_cli.nim"
  exec "nim c --path:src -r tests/test_oci.nim"

task test, "Run all tests":
  runAllTests()

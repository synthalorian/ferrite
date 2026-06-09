# ferrite — minimal container runtime
#
# Phase 1+2 CLI: run a command inside isolated namespaces with optional rootfs.

import std/[os, strutils, posix]
import ferrite/namespaces
import ferrite/rootfs

proc printUsage() =
  echo """
ferrite — minimal container runtime (Phase 2: namespaces + rootfs)

Usage:
  ferrite run [--ns <flags>] [--root <path>] -- <command> [args...]

Options:
  --ns <flags>    Comma-separated namespace list:
                  mount, pid, net, uts, ipc, user, cgroup
                  (default: pid,net,mount,uts,ipc)
  --root <path>   Root filesystem path (directory or image).
                  If provided, ferrite mounts an overlayfs and
                  pivot_root's into it before running the command.

Examples:
  sudo ferrite run -- /bin/sh
  sudo ferrite run --root /path/to/rootfs -- /bin/sh
  sudo ferrite run --ns pid,net,mount -- /bin/hostname
"""

proc parseNsFlags(s: string): set[Namespace] =
  result = {}
  for part in s.split(','):
    case part.strip.toLowerAscii
    of "mount":   result.incl nsMount
    of "pid":     result.incl nsPid
    of "net":     result.incl nsNet
    of "uts":     result.incl nsUts
    of "ipc":     result.incl nsIpc
    of "user":    result.incl nsUser
    of "cgroup":  result.incl nsCgroup
    else:
      stderr.writeLine("ferrite: unknown namespace: ", part)
      quit(1)

proc main() =
  let args = commandLineParams()

  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    printUsage()
    quit(0)

  if args[0] != "run":
    stderr.writeLine("ferrite: unknown command: ", args[0])
    printUsage()
    quit(1)

  var
    nss: set[Namespace] = {nsPid, nsNet, nsMount, nsUts, nsIpc}
    rootfs = ""
    cmdIdx = 1

  # Parse optional flags
  while cmdIdx < args.len and args[cmdIdx].startsWith("--") and args[cmdIdx] != "--":
    case args[cmdIdx]
    of "--ns":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --ns requires an argument")
        printUsage()
        quit(1)
      nss = parseNsFlags(args[cmdIdx + 1])
      cmdIdx += 2
    of "--root":
      if cmdIdx + 1 >= args.len:
        stderr.writeLine("ferrite: --root requires an argument")
        printUsage()
        quit(1)
      rootfs = args[cmdIdx + 1]
      cmdIdx += 2
    else:
      stderr.writeLine("ferrite: unknown option: ", args[cmdIdx])
      printUsage()
      quit(1)

  # Expect "--" separator
  if cmdIdx >= args.len or args[cmdIdx] != "--":
    stderr.writeLine("ferrite: expected '--' before command")
    printUsage()
    quit(1)

  cmdIdx.inc
  if cmdIdx >= args.len:
    stderr.writeLine("ferrite: no command given")
    printUsage()
    quit(1)

  let
    cmd = args[cmdIdx]
    cmdArgs = args[cmdIdx + 1 .. ^1]

  if getuid() != 0:
    stderr.writeLine("ferrite: must run as root (or with CAP_SYS_ADMIN)")
    quit(1)

  if rootfs.len > 0:
    echo "ferrite: creating namespaces ", nss, " with rootfs ", rootfs, " ..."
    let rc = runInRootfs(nss, rootfs, cmd, cmdArgs)
    quit(rc)
  else:
    echo "ferrite: creating namespaces ", nss, " ..."
    let rc = executeInNamespace(nss, cmd, cmdArgs)
    quit(rc)

when isMainModule:
  main()

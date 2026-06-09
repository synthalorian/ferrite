# ferrite — Container State Management Module
#
# Phase 7: Track running containers on disk so we can exec, kill, and ps.
# Pure Nim — no external dependencies beyond posix and linux headers.
#
# Usage:
#   let state = newContainerState("ferrite-abc123", pid, cmd, rootfs, nss)
#   saveContainerState(state)
#   let all = listContainerStates()
#   let one = loadContainerState("ferrite-abc123")
#   removeContainerState("ferrite-abc123")

import std/[os, strutils, parseutils, times, json, sequtils]

when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

import namespaces

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  StateDirEnv* = "FERRITE_STATE_DIR"
  DefaultStateDir* = "/run/ferrite"
  FallbackStateDir* = "/tmp/ferrite"

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  ContainerState* = object
    ## On-disk representation of a running container.
    id*: string            ## Unique container identifier
    pid*: Pid              ## Init process PID on the host
    command*: string       ## Original command string
    rootfs*: string        ## Root filesystem path (may be empty)
    namespaces*: set[Namespace]  ## Active namespaces
    cgroup*: string        ## Cgroup name (may be empty)
    created*: float        ## Epoch timestamp
    status*: string        ## "running", "stopped", etc.

  StateError* = object of OSError
    ## Raised when a state operation fails.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc getStateDir(): string =
  ## Return the directory used for container state files.
  ## Prefers $FERRITE_STATE_DIR, then /run/ferrite, then /tmp/ferrite.
  let envDir = getEnv(StateDirEnv)
  if envDir.len > 0:
    return envDir
  if dirExists(DefaultStateDir) or getuid() == 0:
    return DefaultStateDir
  FallbackStateDir

proc ensureStateDir(): string =
  ## Ensure the state directory exists. Returns the path.
  result = getStateDir()
  if not dirExists(result):
    try:
      createDir(result)
      if getuid() == 0:
        discard chmod(cstring(result), 0o755)
    except CatchableError:
      # Fallback to /tmp if we can't create /run/ferrite
      result = FallbackStateDir
      if not dirExists(result):
        createDir(result)

proc statePath(id: string): string =
  ensureStateDir() / id & ".json"

proc nsSetToSeq(nss: set[Namespace]): seq[string] =
  result = @[]
  for ns in nss:
    case ns
    of nsMount:  result.add("mount")
    of nsPid:    result.add("pid")
    of nsNet:    result.add("net")
    of nsUts:    result.add("uts")
    of nsIpc:    result.add("ipc")
    of nsUser:   result.add("user")
    of nsCgroup: result.add("cgroup")

proc seqToNsSet(vals: seq[string]): set[Namespace] =
  result = {}
  for v in vals:
    case v.toLowerAscii
    of "mount":  result.incl nsMount
    of "pid":    result.incl nsPid
    of "net":    result.incl nsNet
    of "uts":    result.incl nsUts
    of "ipc":    result.incl nsIpc
    of "user":   result.incl nsUser
    of "cgroup": result.incl nsCgroup
    else: discard

proc generateContainerId*(): string =
  ## Generate a unique container identifier.
  ## Format: ferrite-<pid>-<timestamp>
  "ferrite-" & $getpid() & "-" & $epochTime().int

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc newContainerState*(id: string; pid: Pid; command: string;
                        rootfs: string = ""; nss: set[Namespace] = {};
                        cgroup: string = ""): ContainerState =
  ## Create a new ContainerState object.
  result.id = id
  result.pid = pid
  result.command = command
  result.rootfs = rootfs
  result.namespaces = nss
  result.cgroup = cgroup
  result.created = epochTime()
  result.status = "running"

proc saveContainerState*(state: ContainerState) =
  ## Write a container state file to disk.
  let path = statePath(state.id)
  let data = %*{
    "id": state.id,
    "pid": int(state.pid),
    "command": state.command,
    "rootfs": state.rootfs,
    "namespaces": nsSetToSeq(state.namespaces),
    "cgroup": state.cgroup,
    "created": state.created,
    "status": state.status
  }
  writeFile(path, $data & "\n")

proc loadContainerState*(id: string): ContainerState =
  ## Read a container state file from disk.
  ## Raises StateError if not found or malformed.
  let path = statePath(id)
  if not fileExists(path):
    raise newException(StateError, "container not found: " & id)

  let raw = readFile(path)
  let j = parseJson(raw)

  result.id = j["id"].getStr
  result.pid = Pid(j["pid"].getInt)
  result.command = j["command"].getStr
  result.rootfs = j["rootfs"].getStr
  result.namespaces = seqToNsSet(j["namespaces"].getElems.mapIt(it.getStr))
  result.cgroup = j["cgroup"].getStr
  result.created = j["created"].getFloat
  result.status = j["status"].getStr

proc removeContainerState*(id: string) =
  ## Remove a container state file. Ignores errors.
  let path = statePath(id)
  if fileExists(path):
    try:
      removeFile(path)
    except CatchableError:
      discard

proc listContainerStates*(): seq[ContainerState] =
  ## Return all containers currently tracked on disk.
  ## Automatically removes state files whose PID is no longer alive.
  result = @[]
  let sdir = ensureStateDir()
  if not dirExists(sdir):
    return

  for kind, path in walkDir(sdir):
    if kind == pcFile and path.endsWith(".json"):
      try:
        let raw = readFile(path)
        let j = parseJson(raw)
        let pid = Pid(j["pid"].getInt)
        # Check if process is still alive.
        # kill(pid, 0) returns 0 if we can signal it, -1 with EPERM if it
        # exists but we lack permission, and -1 with ESRCH if it is dead.
        let alive = kill(pid, 0) == 0 or errno == EPERM
        if alive:
          var state: ContainerState
          state.id = j["id"].getStr
          state.pid = pid
          state.command = j["command"].getStr
          state.rootfs = j["rootfs"].getStr
          state.namespaces = seqToNsSet(j["namespaces"].getElems.mapIt(it.getStr))
          state.cgroup = j["cgroup"].getStr
          state.created = j["created"].getFloat
          state.status = j["status"].getStr
          result.add(state)
        else:
          # Process dead — clean up stale state
          try:
            removeFile(path)
          except CatchableError:
            discard
      except CatchableError:
        # Malformed file — clean up
        try:
          removeFile(path)
        except CatchableError:
          discard

proc isContainerRunning*(id: string): bool =
  ## Check if a container is currently running.
  try:
    let state = loadContainerState(id)
    result = kill(state.pid, 0) == 0
  except CatchableError:
    result = false

proc containerExists*(id: string): bool =
  ## Check if a container state file exists on disk.
  fileExists(statePath(id))

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

proc formatContainerLine*(state: ContainerState): string =
  ## Format a container for `ps` output (single line, space-separated).
  let ageSec = int(epochTime() - state.created)
  let age = if ageSec < 60: $ageSec & "s"
            elif ageSec < 3600: $(ageSec div 60) & "m"
            else: $(ageSec div 3600) & "h"
  state.id & " " & $state.pid & " " & state.status & " " & age & " " & state.command

proc findContainerByPrefix*(prefix: string): ContainerState =
  ## Find a container by a prefix of its ID.
  ## Raises StateError if 0 or >1 matches.
  let all = listContainerStates()
  var matches: seq[ContainerState] = @[]
  for s in all:
    if s.id.startsWith(prefix):
      matches.add(s)
  if matches.len == 0:
    raise newException(StateError, "no container matches: " & prefix)
  if matches.len > 1:
    raise newException(StateError, "ambiguous container prefix: " & prefix)
  result = matches[0]

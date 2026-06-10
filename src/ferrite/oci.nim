# ferrite — OCI Runtime Spec Compatibility Layer
#
# Phase 8: Partial OCI runtime spec compatibility.
# Supports the standard OCI commands: create, start, state, delete, kill, ps.
#
# A bundle is a directory containing:
#   - config.json   (OCI runtime configuration)
#   - rootfs/       (container root filesystem)
#
# Usage:
#   ferrite create mycontainer --bundle /path/to/bundle
#   ferrite start mycontainer
#   ferrite state mycontainer
#   ferrite delete mycontainer
#
# Pure Nim — no external dependencies beyond posix and linux headers.

import std/[os, strutils, json]

when defined(linux):
  import std/posix
else:
  {.error: "ferrite requires Linux".}

import namespaces, rootfs, cgroups, state

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  OciVersion* = "1.0.2"
    ## OCI runtime spec version we claim compatibility with.

  OciConfigFile* = "config.json"
    ## Name of the OCI configuration file inside a bundle.

  OciRootfsDir* = "rootfs"
    ## Name of the rootfs directory inside a bundle.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  OciNamespace* = object
    ## Single OCI namespace entry.
    nstype*: string   ## e.g. "pid", "network", "mount", "uts", "ipc", "user", "cgroup"
    path*: string     ## Optional path to an existing namespace (may be empty)

  OciMount* = object
    ## Single OCI mount entry.
    destination*: string
    source*: string
    mtype*: string
    options*: seq[string]

  OciLinuxResources* = object
    ## Simplified OCI Linux resources (cgroups).
    cpuShares*: int64
    cpuQuota*: int64
    cpuPeriod*: int64
    memoryLimit*: int64
    pidsLimit*: int64

  OciProcess* = object
    ## OCI process configuration.
    terminal*: bool
    user*: tuple[uid: int, gid: int]
    args*: seq[string]
    env*: seq[string]
    cwd*: string

  OciRoot* = object
    ## OCI root filesystem configuration.
    path*: string
    readonly*: bool

  OciConfig* = object
    ## Parsed OCI runtime configuration (simplified subset).
    ociVersion*: string
    hostname*: string
    process*: OciProcess
    root*: OciRoot
    mounts*: seq[OciMount]
    linuxNamespaces*: seq[OciNamespace]
    linuxResources*: OciLinuxResources

  OciState* = object
    ## OCI runtime state as defined by the spec.
    ociVersion*: string
    id*: string
    status*: string
    pid*: int
    bundle*: string
    annotations*: JsonNode

  OciError* = object of OSError
    ## Raised when an OCI operation fails.

# ---------------------------------------------------------------------------
# Internal helpers — namespace mapping
# ---------------------------------------------------------------------------

proc ociNsToFerrite(nstype: string): Namespace =
  ## Map OCI namespace type string to ferrite Namespace enum.
  case nstype.toLowerAscii
  of "pid":      result = nsPid
  of "network":  result = nsNet
  of "mount":    result = nsMount
  of "uts":      result = nsUts
  of "ipc":      result = nsIpc
  of "user":     result = nsUser
  of "cgroup":   result = nsCgroup
  else:
    raise newException(OciError, "unknown OCI namespace type: " & nstype)

proc ferriteNsToOci(ns: Namespace): string =
  ## Map ferrite Namespace enum to OCI namespace type string.
  case ns
  of nsPid:     result = "pid"
  of nsNet:     result = "network"
  of nsMount:   result = "mount"
  of nsUts:     result = "uts"
  of nsIpc:     result = "ipc"
  of nsUser:    result = "user"
  of nsCgroup:  result = "cgroup"

# ---------------------------------------------------------------------------
# Config parsing
# ---------------------------------------------------------------------------

proc parseOciConfig*(bundlePath: string): OciConfig =
  ## Parse an OCI bundle's config.json into an OciConfig object.
  ## Raises OciError if the bundle or config is invalid.
  let configPath = bundlePath / OciConfigFile
  if not fileExists(configPath):
    raise newException(OciError, "config.json not found in bundle: " & bundlePath)

  let rootfsPath = bundlePath / OciRootfsDir
  if not dirExists(rootfsPath):
    raise newException(OciError, "rootfs/ not found in bundle: " & bundlePath)

  let raw = readFile(configPath)
  let j = parseJson(raw)

  result.ociVersion = j{"ociVersion"}.getStr(OciVersion)

  # Root
  if j.hasKey("root"):
    result.root.path = j["root"]{"path"}.getStr("rootfs")
    result.root.readonly = j["root"]{"readonly"}.getBool(false)
  else:
    result.root.path = "rootfs"

  # Process
  if j.hasKey("process"):
    let procJ = j["process"]
    result.process.terminal = procJ{"terminal"}.getBool(false)
    result.process.cwd = procJ{"cwd"}.getStr("/")

    if procJ.hasKey("args"):
      for arg in procJ["args"].getElems:
        result.process.args.add(arg.getStr)

    if procJ.hasKey("env"):
      for env in procJ["env"].getElems:
        result.process.env.add(env.getStr)

    if procJ.hasKey("user"):
      let userJ = procJ["user"]
      result.process.user.uid = userJ{"uid"}.getInt(0)
      result.process.user.gid = userJ{"gid"}.getInt(0)

  # Hostname
  result.hostname = j{"hostname"}.getStr("")

  # Linux namespaces
  if j.hasKey("linux") and j["linux"].hasKey("namespaces"):
    for nsJ in j["linux"]["namespaces"].getElems:
      var ns: OciNamespace
      ns.nstype = nsJ{"type"}.getStr("")
      ns.path = nsJ{"path"}.getStr("")
      if ns.nstype.len > 0:
        result.linuxNamespaces.add(ns)

  # Linux resources (cgroups)
  if j.hasKey("linux") and j["linux"].hasKey("resources"):
    let resJ = j["linux"]["resources"]
    if resJ.hasKey("cpu"):
      result.linuxResources.cpuShares = resJ["cpu"]{"shares"}.getBiggestInt(0)
      result.linuxResources.cpuQuota = resJ["cpu"]{"quota"}.getBiggestInt(0)
      result.linuxResources.cpuPeriod = resJ["cpu"]{"period"}.getBiggestInt(0)
    if resJ.hasKey("memory"):
      result.linuxResources.memoryLimit = resJ["memory"]{"limit"}.getBiggestInt(0)
    if resJ.hasKey("pids"):
      result.linuxResources.pidsLimit = resJ["pids"]{"limit"}.getBiggestInt(0)

  # Mounts
  if j.hasKey("mounts"):
    for mJ in j["mounts"].getElems:
      var m: OciMount
      m.destination = mJ{"destination"}.getStr("")
      m.source = mJ{"source"}.getStr("")
      m.mtype = mJ{"type"}.getStr("")
      if mJ.hasKey("options"):
        for opt in mJ["options"].getElems:
          m.options.add(opt.getStr)
      result.mounts.add(m)

# ---------------------------------------------------------------------------
# OCI state generation
# ---------------------------------------------------------------------------

proc toJson*(state: OciState): JsonNode =
  ## Convert OciState to a JSON object matching the OCI spec.
  result = %*{
    "ociVersion": state.ociVersion,
    "id": state.id,
    "status": state.status,
    "pid": state.pid,
    "bundle": state.bundle
  }
  if state.annotations != nil and state.annotations.len > 0:
    result["annotations"] = state.annotations

proc newOciState*(id, bundle, status: string; pid: int = 0): OciState =
  ## Create a new OciState object.
  result.ociVersion = OciVersion
  result.id = id
  result.status = status
  result.pid = pid
  result.bundle = bundle
  result.annotations = newJObject()

# ---------------------------------------------------------------------------
# OCI operations
# ---------------------------------------------------------------------------

proc ociCreate*(id: string; bundlePath: string) =
  ## Create a new container from an OCI bundle.
  ## Parses the bundle config, validates it, and writes OCI state as "created".
  ## Raises OciError if the container already exists or bundle is invalid.

  if containerExists(id):
    raise newException(OciError, "container already exists: " & id)

  let config = parseOciConfig(bundlePath)

  # Derive namespaces from OCI config (default to standard set if none)
  var nss: set[Namespace]
  if config.linuxNamespaces.len > 0:
    for ns in config.linuxNamespaces:
      nss.incl ociNsToFerrite(ns.nstype)
  else:
    nss = {nsPid, nsNet, nsMount, nsUts, nsIpc}

  # Determine rootfs path (relative to bundle if not absolute)
  var rootfs = config.root.path
  if not rootfs.isAbsolute:
    rootfs = bundlePath / rootfs

  # Build command string for state
  let cmd = if config.process.args.len > 0: config.process.args.join(" ")
            else: ""

  # Save OCI-compatible container state as "created"
  var state = newContainerState(id, 0, cmd, rootfs, nss, "")
  state.status = "created"
  saveContainerState(state)

  # Also save OCI-specific metadata alongside state
  let metaPath = statePath(id).replace(".json", ".oci.json")
  let meta = %*{
    "bundle": bundlePath,
    "ociVersion": config.ociVersion,
    "hostname": config.hostname,
    "process": {
      "terminal": config.process.terminal,
      "cwd": config.process.cwd,
      "args": config.process.args,
      "env": config.process.env,
      "user": {"uid": config.process.user.uid, "gid": config.process.user.gid}
    }
  }
  writeFile(metaPath, $meta & "\n")

proc ociStart*(id: string): cint =
  ## Start a previously created container.
  ## Forks into namespaces and executes the configured process.
  ## Returns the container process exit code.
  ## Updates state through "running" to "stopped".

  var cstate: ContainerState
  try:
    cstate = loadContainerState(id)
  except StateError:
    raise newException(OciError, "container not found: " & id)

  if cstate.status != "created":
    raise newException(OciError, "container must be in 'created' state to start: " & id)

  let metaPath = statePath(id).replace(".json", ".oci.json")
  var bundlePath = ""
  if fileExists(metaPath):
    let meta = parseJson(readFile(metaPath))
    bundlePath = meta{"bundle"}.getStr("")

  # Update state to "running"
  cstate.status = "running"
  cstate.pid = getpid()  # Will be updated after fork
  saveContainerState(cstate)

  let rootfs = cstate.rootfs
  let nss = cstate.namespaces

  # Build command and args from state command string
  var cmd = ""
  var cmdArgs: seq[string] = @[]
  if cstate.command.len > 0:
    let parts = cstate.command.splitWhitespace()
    if parts.len > 0:
      cmd = parts[0]
      cmdArgs = parts[1 .. ^1]

  var rc: cint
  try:
    if rootfs.len > 0:
      rc = runInRootfs(nss, rootfs, cmd, cmdArgs)
    else:
      rc = executeInNamespace(nss, cmd, cmdArgs)
  finally:
    # Mark as stopped
    cstate.status = "stopped"
    cstate.pid = 0
    saveContainerState(cstate)

  result = rc

proc ociState*(id: string): OciState =
  ## Return the OCI state for a container.
  ## Maps ferrite's internal state to the OCI state format.

  var cstate: ContainerState
  try:
    cstate = loadContainerState(id)
  except StateError:
    raise newException(OciError, "container not found: " & id)

  let metaPath = statePath(id).replace(".json", ".oci.json")
  var bundlePath = ""
  if fileExists(metaPath):
    let meta = parseJson(readFile(metaPath))
    bundlePath = meta{"bundle"}.getStr("")

  result = newOciState(id, bundlePath, cstate.status, int(cstate.pid))

proc ociDelete*(id: string) =
  ## Delete a container and its state.
  ## Removes state files. Raises OciError if container is still running.

  var cstate: ContainerState
  try:
    cstate = loadContainerState(id)
  except StateError:
    raise newException(OciError, "container not found: " & id)

  if cstate.status == "running" and cstate.pid > 0:
    if kill(cstate.pid, 0) == 0 or errno == EPERM:
      raise newException(OciError, "cannot delete running container: " & id)

  removeContainerState(id)

  # Clean up OCI metadata
  let metaPath = statePath(id).replace(".json", ".oci.json")
  if fileExists(metaPath):
    try:
      removeFile(metaPath)
    except CatchableError:
      discard

  # Clean up cgroup if present
  if cstate.cgroup.len > 0:
    discard cleanupCgroup(cstate.cgroup)

# ---------------------------------------------------------------------------
# OCI kill (OCI-style wrapper around existing kill)
# ---------------------------------------------------------------------------

proc ociKill*(id: string; signal: cint) =
  ## Send a signal to a container (OCI-style).
  ## Raises OciError if the container is not found or not running.

  var cstate: ContainerState
  try:
    cstate = loadContainerState(id)
  except StateError:
    raise newException(OciError, "container not found: " & id)

  if cstate.pid <= 0:
    raise newException(OciError, "container has no process: " & id)

  if kill(cstate.pid, signal) != 0:
    raise newException(OciError, "kill failed for container " & id & ": " & osErrorMsg(osLastError()))

# ---------------------------------------------------------------------------
# OCI ps — list containers in OCI format
# ---------------------------------------------------------------------------

proc ociListStates*(): seq[OciState] =
  ## List all containers and return their OCI states.
  result = @[]
  for cstate in listContainerStates():
    let metaPath = statePath(cstate.id).replace(".json", ".oci.json")
    var bundlePath = ""
    if fileExists(metaPath):
      let meta = parseJson(readFile(metaPath))
      bundlePath = meta{"bundle"}.getStr("")
    result.add(newOciState(cstate.id, bundlePath, cstate.status, int(cstate.pid)))

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

proc validateBundle*(bundlePath: string): string =
  ## Validate that a directory is a valid OCI bundle.
  ## Returns empty string on success, error message on failure.
  let configPath = bundlePath / OciConfigFile
  if not fileExists(configPath):
    return "missing config.json"

  let rootfsPath = bundlePath / OciRootfsDir
  if not dirExists(rootfsPath):
    return "missing rootfs/ directory"

  try:
    let raw = readFile(configPath)
    let j = parseJson(raw)
    if not j.hasKey("ociVersion"):
      return "missing ociVersion in config.json"
    if not j.hasKey("process"):
      return "missing process in config.json"
    if not j["process"].hasKey("args"):
      return "missing process.args in config.json"
  except CatchableError as e:
    return "invalid config.json: " & e.msg

  result = ""

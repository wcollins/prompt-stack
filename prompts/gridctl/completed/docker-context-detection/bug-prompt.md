# Bug Fix: Docker Context Detection Missing in Runtime Probe

## Context

**Project**: gridctl — a Go CLI that orchestrates "stacks" of MCP (Model Context Protocol) servers and supporting resources. Stacks are described in YAML files and applied via `gridctl apply <stack.yaml>`. Workloads can be container-based (image references run by Docker or Podman) or local processes (stdio/native executables).

**Tech stack**: Go, Cobra for CLI, Docker SDK for Go (`github.com/docker/docker/client`), Podman compatibility via its Docker-compatible socket. Test framework is standard `testing` with table-driven tests.

**Repository layout** (relevant parts):
- `cmd/gridctl/` — Cobra commands (`apply.go`, `info.go`, `destroy.go`, `status.go`, etc.)
- `pkg/controller/` — Stack lifecycle coordinator (`controller.go`)
- `pkg/runtime/` — Runtime abstraction (`detect.go`, `orchestrator.go`, `factory.go`, `interface.go`)
- `pkg/runtime/docker/` — Docker driver (`client.go`, `driver.go`, `init.go`)
- `pkg/dockerclient/` — Thin wrapper interface over the Docker SDK client (enables testing)
- `pkg/config/` — Stack YAML parsing and predicates (`types.go`)

**Architecture note**: `pkg/runtime/detect.go` is the single source of truth for "where is the daemon socket?". `pkg/runtime/docker/client.go` is the only place the Docker SDK client is constructed. The fix lives almost entirely in those two files.

## Investigation Context

Full investigation: `prompts/gridctl/docker-context-detection/bug-evaluation.md`.

Key facts shaping this prompt:

- **Root cause confirmed**: `pkg/runtime/detect.go`'s `autoDetect()` and `resolveExplicit()` only consult `DOCKER_HOST` and a hardcoded `/var/run/docker.sock`. They never read Docker CLI contexts. The fallback `runtime.New()` path also uses `client.FromEnv`, which has the same blind spot.
- **Reproduction is deterministic**: macOS + OrbStack (or Colima, Rancher Desktop, podman-machine, remote-SSH contexts) where the active context lives in `~/.docker/config.json` and `DOCKER_HOST` is unset and the system socket is missing/dangling.
- **Risk is low**: the fix is purely additive — context resolution that fails for any reason falls through to existing behavior. Docker Desktop users (the only users currently working) are not affected because their existing direct socket probe still succeeds.
- **Out of scope intentionally**: `tcp://`/`ssh://` Docker contexts, refactoring podman detection, hardcoding per-product socket paths (e.g., `~/.orbstack/...`). The right primitive is Docker-context awareness, not per-tool special cases.
- **Test gap**: `pkg/runtime/detect_test.go` has zero coverage for `probeSocket` or `autoDetect`. The fix should close this gap with hermetic unit tests.

## Bug Description

`gridctl apply` aborts with `"A container runtime is required but not available"` even when Docker is running, on hosts where the daemon is reached via Docker CLI **contexts** (OrbStack, Colima, Rancher Desktop, podman-machine, remote SSH Docker) without an explicit `DOCKER_HOST`. `docker ps` works in the same shell — proving the daemon is reachable — because the Docker CLI consults the active context. gridctl does not.

Concrete user-visible failure:

```
Error: failed to start stack: A container runtime is required but not available

These workloads need a container runtime:
  - github               (image: ghcr.io/github/github-mcp-server:latest)

Install Docker: https://docs.docker.com/get-docker/
Install Podman: https://podman.io/getting-started/installation

docker daemon not accessible: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

Expected: gridctl resolves the active context's `unix://` endpoint and uses it for the runtime client, just like Docker CLI does.

Who is affected: all macOS users running OrbStack, Colima, Rancher Desktop, podman-machine in context-only configurations; anyone using remote Docker via SSH contexts. Not affected: Docker Desktop users (they have a valid `/var/run/docker.sock`); Linux users with the native daemon socket.

## Root Cause

Docker CLI resolves the daemon endpoint in this order: explicit `--host` → `DOCKER_HOST` env → active context in `~/.docker/config.json` → built-in `default` context (`/var/run/docker.sock`). gridctl implements steps 1, 2, and 4, but is missing step 3.

**Specifically**:

- `pkg/runtime/detect.go:90-114` `autoDetect()` skips contexts.
- `pkg/runtime/detect.go:59-87` `resolveExplicit()` has the same gap on the `docker` branch.
- `pkg/runtime/docker/client.go:13-22` `NewDockerClient()` uses `client.FromEnv`, which honors `DOCKER_HOST` but not contexts — so even the controller-level fallback at `pkg/controller/controller.go:521-526` cannot recover.

The correct logic is to read `${DOCKER_CONFIG:-~/.docker}/config.json`, take `currentContext`, hash it with SHA-256, read `~/.docker/contexts/meta/<hex>/meta.json`, and extract `Endpoints.docker.Host`. If that endpoint is a `unix://` path that probes successfully, use it.

## Fix Requirements

### Required Changes

1. **Add `resolveDockerContext() (string, error)` to `pkg/runtime/detect.go`** that:
   - Reads `${DOCKER_CONFIG:-~/.docker}/config.json`.
   - Returns `("", nil)` (not an error) if the file is missing — that just means no Docker CLI is installed and we should fall through.
   - Parses the JSON and extracts `currentContext`.
   - Returns `("", nil)` if `currentContext` is empty or equals `"default"` — both indicate "use the built-in default", which is the next probe path anyway.
   - Computes `sha256(currentContext)` as a lowercase hex string and reads `<docker-config-dir>/contexts/meta/<hex>/meta.json`.
   - Returns `("", nil)` if the meta file is missing — this happens with stale or corrupt context state; do not fail the entire detection.
   - Parses the meta JSON. Structure (relevant parts only):
     ```json
     { "Endpoints": { "docker": { "Host": "unix:///path/to/socket" } } }
     ```
   - Returns `extractSocketPath(host)` — if the endpoint is not a `unix://` scheme (e.g., `tcp://`, `ssh://`, `npipe://`), `extractSocketPath` already returns `""`, which signals "skip this context, fall through". This is intentional: `tcp://` and `ssh://` are out of scope for this fix.
   - Returns a real error only for unrecoverable conditions you would want to surface (e.g., the config file exists but is unreadable due to permissions). Even then, callers should log-and-continue rather than abort — see wiring below.

2. **Wire `resolveDockerContext()` into `autoDetect()`** (`pkg/runtime/detect.go:90-114`), as a new step between the existing `DOCKER_HOST` check and the existing `/var/run/docker.sock` probe:
   ```
   1. DOCKER_HOST                                  (existing)
   2. Active Docker context (unix endpoint only)   ← NEW
   3. /var/run/docker.sock                         (existing)
   4. Podman sockets                               (existing)
   ```
   If `resolveDockerContext()` returns a non-empty path and `probeSocket()` succeeds on it, return a `RuntimeInfo` for that path. The runtime type should be determined via the existing `detectTypeFromSocket()` helper (a context might point at Podman's socket).
   If `resolveDockerContext()` returns an error, log it via `slog` at debug level and continue to the next probe — do not fail detection because of a broken context file.

3. **Wire `resolveDockerContext()` into `resolveExplicit()`** (`pkg/runtime/detect.go:59-87`), specifically the `RuntimeDocker` branch, between the `DOCKER_HOST` check and the `/var/run/docker.sock` probe. Same fall-through-on-error semantics. This ensures `gridctl apply --runtime docker` and `GRIDCTL_RUNTIME=docker` both honor contexts.

4. **Improve `buildNoRuntimeError()` and the `Ping` error wrap** to show which paths were probed and distinguish failure modes:
   - In `buildNoRuntimeError()` (locate it in `pkg/runtime/detect.go`), append a "Checked:" section listing each probed path and a per-path status. For `/var/run/docker.sock`, distinguish three cases using `os.Lstat`: "not present", "dangling symlink (target missing)", and "present but not responding". For context endpoints, identify them as "context 'orbstack' → /path/to/socket".
   - In `pkg/runtime/docker/client.go:37-43` `Ping`, when wrapping the error, append a hint along the lines of: `"if your Docker daemon runs via a CLI context (OrbStack, Colima, etc.), gridctl now reads ~/.docker/config.json — make sure 'docker context inspect' shows the right endpoint, or set DOCKER_HOST=unix://..."`. Keep it terse — one sentence.

5. **Add unit tests in `pkg/runtime/detect_test.go`**:
   - `TestProbeSocket_DanglingSymlink` — create a tempdir, create a symlink pointing at a non-existent path inside it, assert `probeSocket` returns `false` without panicking.
   - `TestProbeSocket_RealSocket` — `net.Listen("unix", path)` in a tempdir, serve a basic HTTP `/_ping` 200 response on it, assert `probeSocket` returns `true`. Clean up the listener with `t.Cleanup`.
   - `TestProbeSocket_NonSocket` — write a regular file, assert `probeSocket` returns `false`.
   - `TestResolveDockerContext_MissingConfig` — point `DOCKER_CONFIG` at an empty tempdir, assert `resolveDockerContext` returns `("", nil)`.
   - `TestResolveDockerContext_EmptyCurrentContext` — write `config.json` with no `currentContext` field, assert `("", nil)`.
   - `TestResolveDockerContext_DefaultContext` — write `config.json` with `"currentContext": "default"`, assert `("", nil)`.
   - `TestResolveDockerContext_MissingMeta` — write `config.json` with `"currentContext": "ghost"`, do not write the meta file, assert `("", nil)`.
   - `TestResolveDockerContext_TcpEndpointSkipped` — write a meta file with `"Endpoints":{"docker":{"Host":"tcp://example:2375"}}`, assert `("", nil)` (filtered by `extractSocketPath`).
   - `TestResolveDockerContext_UnixEndpoint` — write valid `config.json` + `meta.json` with a `unix:///path/to/sock` endpoint, assert it returns `/path/to/sock`.
   - `TestAutoDetect_ContextWinsOverDanglingDefault` — **the bug regression test**. Set `DOCKER_HOST=""`, `DOCKER_CONFIG=<tempdir>`. Write a valid config + meta pointing at a real listening unix socket in the tempdir. Optionally inject a dangling symlink at a configurable "default" path via a small seam (see "Implementation Guidance" below). Assert `autoDetect()` returns a `RuntimeInfo` with `SocketPath` equal to the context endpoint, runtime type `Docker`.

### Constraints

- **Must not change behavior for Docker Desktop users**. They have a working `/var/run/docker.sock`; the existing probe order plus a new context step earlier means the context step would only resolve their `default` (or no) context, which the implementation returns as `("", nil)`, leaving the existing probe untouched.
- **Must not introduce new dependencies**. Everything needed (`encoding/json`, `crypto/sha256`, `encoding/hex`, `os`, `path/filepath`) is in the standard library.
- **Must not panic on malformed user files**. JSON decode errors, missing files, permission errors all fall through silently (with optional debug-level slog). The user's gridctl invocation must never fail *because their `~/.docker` is malformed*.
- **Must not consult Docker contexts when `DOCKER_HOST` is set**. Explicit env var wins — that's the user's clear intent, and it matches Docker CLI semantics.

### Out of Scope

- `tcp://` / `ssh://` / `npipe://` Docker endpoints — `extractSocketPath` already filters to `unix://`, so they are skipped by construction. Supporting them requires either a richer probe (HTTP-over-TCP) or routing through `client.WithHost`, which is a follow-up.
- Hardcoding per-product socket paths (`~/.orbstack/run/docker.sock`, `~/.colima/default/docker.sock`, etc.). Context-awareness covers the same cases more durably.
- Refactoring Podman detection. Same probe-by-path pattern, same fragility, but a separate, larger conversation (podman has `podman system connection` rather than Docker contexts).
- Adding the active-context info to `gridctl info` output. Nice-to-have; separate PR.
- Changes to `client.FromEnv`-based `NewDockerClient` in `pkg/runtime/docker/client.go`. The fallback path at `pkg/controller/controller.go:521-526` becomes effectively dead once `autoDetect` succeeds on context-only setups, but leave it for backward compatibility.

## Implementation Guidance

### Key Files to Read

- `pkg/runtime/detect.go` — the file you will modify most. Read the full file to understand existing helpers (`buildRuntimeInfo`, `extractSocketPath`, `detectTypeFromSocket`, `formatCheckedSockets`, `buildNoRuntimeError`) before writing new code; reuse them.
- `pkg/runtime/docker/client.go` — understand the existing client construction and Ping wrap; you'll modify the Ping wrap.
- `pkg/runtime/docker/driver.go` — read to confirm how `RuntimeInfo` flows to the client (`NewWithInfo` → `NewDockerClientWithHost(info.DockerHost())`); you do not modify this file but it informs how the new context-discovered path is used.
- `pkg/runtime/orchestrator.go` (specifically lines 165-175 and 605-635) — understand how `Up` calls `Ping` and how `runtimeRequiredError` assembles the user-facing message.
- `pkg/runtime/detect_test.go` — existing test style; mirror it for the new tests.
- `pkg/controller/controller.go:512-527` — confirm controller wiring; no changes needed here.

### Files to Modify

- `pkg/runtime/detect.go` — add `resolveDockerContext()` and wire it into `autoDetect` and `resolveExplicit`. Improve `buildNoRuntimeError` to surface probed paths and dangling-symlink detection.
- `pkg/runtime/docker/client.go` — improve the `Ping` error wrap to hint at Docker contexts.
- `pkg/runtime/detect_test.go` — add unit tests listed above.

### Reusable Components

- `extractSocketPath(host string) string` (`pkg/runtime/detect.go:157-162`) — already filters to `unix://` schemes; use it for the context endpoint.
- `probeSocket(socketPath string) bool` (`pkg/runtime/detect.go:131-154`) — use as-is for the new context-discovered path.
- `buildRuntimeInfo(rt RuntimeType, socketPath string)` — assemble the return value.
- `detectTypeFromSocket(socketPath string) RuntimeType` (`pkg/runtime/detect.go:164-188`) — use this when returning a context-discovered socket, since a context could point at Podman's Docker-compat socket.

### Conventions to Follow

- Error returns: lowercase, no trailing punctuation, no leading capital. Match the style of existing errors in `detect.go`.
- Logging: gridctl uses `log/slog`. For "expected fall-through" cases inside `resolveDockerContext`, debug-level slog with structured fields like `slog.String("context", name), slog.String("path", metaPath)` is appropriate. Do not log at warn/error for missing files.
- Tests: table-driven where it makes sense; standalone `func TestX(t *testing.T)` otherwise. Use `t.TempDir()` and `t.Setenv` for hermetic test state. Do not require Docker to be installed for unit tests.
- File header: existing files use `package runtime` with no license header. Match.

### Implementation Seam for the Regression Test

The hardest test is `TestAutoDetect_ContextWinsOverDanglingDefault`. The cleanest seam:

- `autoDetect()` currently calls `probeSocket("/var/run/docker.sock")` with a hardcoded path. Extract that string to a package-level `var defaultDockerSocketPath = "/var/run/docker.sock"` (lowercase, unexported) so tests can override it via `t.Cleanup`. This is the smallest reasonable change to enable the regression test; do not make it configurable from CLI flags or env vars.
- Alternative: pass the default path through `DetectOptions`. Slightly heavier change; only do this if you find another good reason for it.

### Hashing the Context Name

```go
sum := sha256.Sum256([]byte(contextName))
hex := hex.EncodeToString(sum[:])
metaPath := filepath.Join(dockerConfigDir, "contexts", "meta", hex, "meta.json")
```

This is the Docker CLI's deterministic layout. Verified by reading any system with an OrbStack context configured.

### Resolving `DOCKER_CONFIG` and Home

```go
dir := os.Getenv("DOCKER_CONFIG")
if dir == "" {
    home, err := os.UserHomeDir()
    if err != nil {
        return "", nil // can't find home; fall through silently
    }
    dir = filepath.Join(home, ".docker")
}
```

## Regression Test

### Test Outline

The regression test must reproduce the exact failure trace from the user transcript. Skeleton:

```go
func TestAutoDetect_ContextWinsOverDanglingDefault(t *testing.T) {
    t.Setenv("DOCKER_HOST", "")
    home := t.TempDir()
    t.Setenv("DOCKER_CONFIG", filepath.Join(home, ".docker"))

    // Listen on a real unix socket; serve /_ping 200.
    sockPath := filepath.Join(t.TempDir(), "docker.sock")
    l, err := net.Listen("unix", sockPath)
    if err != nil { t.Fatal(err) }
    t.Cleanup(func() { l.Close() })
    go http.Serve(l, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/_ping" { w.WriteHeader(http.StatusOK); return }
        if strings.Contains(r.URL.Path, "/version") {
            w.Header().Set("Content-Type", "application/json")
            w.Write([]byte(`{"Components":[{"Name":"Engine"}]}`)) // Docker-shaped response
            return
        }
        w.WriteHeader(http.StatusNotFound)
    }))

    // Write Docker config + context meta pointing at sockPath.
    writeDockerContext(t, filepath.Join(home, ".docker"), "test-orb", "unix://"+sockPath)

    // Point the package default at a dangling symlink so the legacy probe path fails.
    danglingDir := t.TempDir()
    danglingTarget := filepath.Join(danglingDir, "missing.sock")
    danglingLink := filepath.Join(danglingDir, "docker.sock")
    if err := os.Symlink(danglingTarget, danglingLink); err != nil { t.Fatal(err) }
    prev := defaultDockerSocketPath
    defaultDockerSocketPath = danglingLink
    t.Cleanup(func() { defaultDockerSocketPath = prev })

    info, err := autoDetect()
    if err != nil { t.Fatalf("autoDetect failed: %v", err) }
    if info.SocketPath != sockPath {
        t.Fatalf("expected context socket %q, got %q", sockPath, info.SocketPath)
    }
    if info.Type != RuntimeDocker {
        t.Fatalf("expected runtime docker, got %q", info.Type)
    }
}
```

`writeDockerContext` is a small test helper that writes `config.json` and the SHA-256-keyed `meta.json` — implement once and reuse across the resolver tests.

### Existing Test Patterns

`pkg/runtime/detect_test.go` uses plain `func TestX(t *testing.T)` and table-driven `t.Run` subtests. Match it. No external assertion library — use `t.Errorf` / `t.Fatalf` with explicit string comparisons.

## Potential Pitfalls

- **`os.Stat` vs `os.Lstat` on symlinks**: `probeSocket` uses `os.Stat`, which follows symlinks. That is correct for "does this socket actually work" — it must follow into the live target. The new dangling-detection logic in `buildNoRuntimeError` is the place to call `os.Lstat` separately, so the user sees a clear "symlink target missing" message without changing the probe's success/failure logic.
- **Docker context hashing edge cases**: the context name `"default"` is the **builtin** context — Docker never writes a meta file for it. Filter it explicitly. Other context names hash with plain SHA-256 of UTF-8 bytes; no trimming, no normalization.
- **Permission errors on `~/.docker/config.json`**: if the user's home dir is unreadable for some reason, treat that as fall-through, not abort. The user's gridctl invocation must not start failing because of a permission glitch in `~/.docker`.
- **Concurrent access**: Tests using `t.Setenv` are not parallel-safe with sibling tests that read the same env var. Do not mark these tests `t.Parallel()`. The package's existing tests do not parallelize, so this matches convention.
- **HTTP server in tests**: use `http.Serve` on the `net.Listener` directly rather than `httptest.NewServer` (which uses TCP). The bare `http.Serve(l, handler)` pattern works fine for unix sockets and is the simplest correct shape.
- **Endpoint scheme variants**: real-world `meta.json` files may have `Host` values like `"unix:///Users/foo/.orbstack/run/docker.sock"` (triple slash because of `unix://` + absolute path). `extractSocketPath` already handles this correctly via `strings.TrimPrefix(host, "unix://")` — confirm in a test.

## Acceptance Criteria

1. `pkg/runtime/detect.go` exports a new `resolveDockerContext()` function with the contract described above.
2. `autoDetect()` calls `resolveDockerContext()` between the `DOCKER_HOST` and the hardcoded socket probe; a successful resolution short-circuits the rest of detection.
3. `resolveExplicit("docker")` calls `resolveDockerContext()` between `DOCKER_HOST` and the hardcoded socket probe.
4. With `DOCKER_HOST` unset, an active context pointing at a `unix://` socket that responds to `/_ping`, and `/var/run/docker.sock` dangling, `autoDetect()` returns a `RuntimeInfo` for the context endpoint.
5. With `DOCKER_HOST` set, the env var still wins over context resolution.
6. With Docker Desktop's configuration (working `/var/run/docker.sock`, no custom context), `autoDetect()` continues to behave exactly as before.
7. Malformed or missing `~/.docker/config.json` does not cause detection to error — it falls through to existing probes.
8. `buildNoRuntimeError` output names each probed path and distinguishes "dangling symlink" from "not present" for the system socket.
9. `pkg/runtime/docker/client.go`'s `Ping` error wrap includes a one-sentence hint about Docker contexts.
10. All new unit tests pass, including `TestAutoDetect_ContextWinsOverDanglingDefault`.
11. Existing tests still pass.
12. `golangci-lint run` is clean for the touched files.
13. `go build ./...` and `go test -race ./pkg/runtime/...` succeed.

## References

- Investigation report: `prompts/gridctl/docker-context-detection/bug-evaluation.md`.
- Docker CLI context layout: `~/.docker/config.json` (top-level `currentContext`); `~/.docker/contexts/meta/<sha256(name)>/meta.json` with `Endpoints.docker.Host`.
- Comparable Go implementations of Docker context resolution: `sigs.k8s.io/kind/pkg/cluster/internal/providers/docker`, `github.com/docker/compose/v2/pkg/api`, `github.com/k3d-io/k3d/v5/pkg/runtimes/docker`.
- gridctl source files: `pkg/runtime/detect.go`, `pkg/runtime/docker/client.go`, `pkg/runtime/docker/driver.go`, `pkg/runtime/orchestrator.go`, `pkg/controller/controller.go`.

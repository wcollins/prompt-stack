# Bug Investigation: Docker Context Detection Missing

**Date**: 2026-05-13
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

`gridctl apply` errors with `"A container runtime is required but not available"` on Macs running OrbStack (and other Docker context–based setups such as Colima, Rancher Desktop, podman-machine, and remote SSH contexts) when `DOCKER_HOST` is unset. The runtime probe in `pkg/runtime/detect.go` only consults `DOCKER_HOST` and a hardcoded `/var/run/docker.sock`, and never reads Docker CLI contexts from `~/.docker/config.json`. The fallback Docker client uses `client.FromEnv`, which has the same limitation. Recommendation: add Docker-context resolution to `autoDetect()` and `resolveExplicit()`. Fix is small (~30 lines + tests), low risk (additive, fails through to existing behavior), and high-value (unblocks the headline `apply` command on a growing portion of the Mac user base).

## The Bug

**Defect**: `./gridctl apply ~/code/stack.yaml` aborts with:

```
Error: failed to start stack: A container runtime is required but not available

These workloads need a container runtime:
  - github               (image: ghcr.io/github/github-mcp-server:latest)

These work without a container runtime:
  - gitlab               (local process)

Install Docker: https://docs.docker.com/get-docker/
Install Podman: https://podman.io/getting-started/installation

docker daemon not accessible: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

**Expected**: gridctl detects the running Docker daemon (via Docker CLI context) and proceeds to start container workloads.

**Actual**: gridctl reports the daemon as unreachable even though it is running. `docker ps` in the same shell succeeds, demonstrating the daemon is reachable through Docker CLI context resolution.

**How discovered**: User reported via `/bug-scout` on gridctl `v0.1.0-beta.9-31-gcb9d05b` while running `gridctl apply` on macOS with OrbStack. The user's local symlink target had transiently disappeared, exposing the bug; updating OrbStack restored the symlink and hid the immediate symptom, but the underlying detection gap remains.

## Root Cause

### Defect Location

- `pkg/runtime/detect.go:90-114` (`autoDetect`) — only checks `DOCKER_HOST` then hardcoded `/var/run/docker.sock`, never Docker contexts.
- `pkg/runtime/detect.go:59-87` (`resolveExplicit`) — same gap when `--runtime docker` is forced.
- `pkg/runtime/detect.go:131-154` (`probeSocket`) — uses `os.Stat`, which follows symlinks; a dangling symlink returns the same false as "no socket installed", so the resulting error cannot distinguish the cases.
- `pkg/runtime/docker/client.go:13-22` (`NewDockerClient`) — uses `client.FromEnv`, which honors `DOCKER_HOST` but not Docker contexts; this is the fallback path at `pkg/controller/controller.go:521-526`.

### Code Path

1. `cmd/gridctl/apply.go:98-145` parses flags and builds the controller config (`Runtime: runtimeFlag`).
2. `pkg/controller/controller.go:512-527` `newRuntime()` calls `runtime.DetectRuntime(DetectOptions{})`.
3. `pkg/runtime/detect.go:43-56` `DetectRuntime` enters `autoDetect()` (no explicit runtime).
4. `pkg/runtime/detect.go:92-98` checks `DOCKER_HOST` — unset, skipped.
5. `pkg/runtime/detect.go:102` probes `/var/run/docker.sock`. On the affected host this is a dangling symlink. `os.Stat` (`detect.go:134`) returns an error, `probeSocket` returns `false`.
6. `pkg/runtime/detect.go:107-111` probes Podman sockets — none present, all `false`.
7. `pkg/runtime/detect.go:113` returns `buildNoRuntimeError`. Controller falls back to `runtime.New()`.
8. `pkg/runtime/docker/driver.go:23-29` constructs a client via `NewDockerClient()`. `client.FromEnv` honors `DOCKER_HOST` (unset), defaulting to `unix:///var/run/docker.sock`. Client construction succeeds.
9. `pkg/runtime/orchestrator.go:170-172` `Up()` calls `runtime.Ping(ctx)`.
10. `pkg/runtime/docker/client.go:37-43` Ping connects to the SDK default `unix:///var/run/docker.sock` (same dangling symlink) and gets the canonical Docker SDK error.
11. `pkg/runtime/orchestrator.go:609-631` `runtimeRequiredError` wraps the inner error into the user-facing message.

### Why It Happens

The fundamental defect is that **gridctl reproduces a small slice of Docker CLI's daemon-discovery logic and stops short of the contexts step**. Docker CLI resolves the daemon endpoint in this order: explicit `--host` flag → `DOCKER_HOST` env var → active context in `~/.docker/config.json` → built-in `default` context (`/var/run/docker.sock` on Unix). gridctl implements steps 1 and 2 and the final fallback, but never step 3. On every platform where the user's daemon is reached via context (OrbStack, Colima, Rancher Desktop, podman-machine, remote SSH contexts), gridctl is blind to it.

`probeSocket`'s use of `os.Stat` is a secondary aggravation: on a dangling symlink it returns the same `false` as for a missing-altogether socket, so the error cannot tell the user "this socket is a broken symlink, your daemon may live elsewhere" — it just says "install Docker", which is unhelpful when Docker is already installed.

### Similar Instances

- Podman socket probing (`pkg/runtime/detect.go:117-129`) is similarly hardcoded. Will miss alternative Podman installations (e.g., podman-machine on Mac, custom Homebrew prefixes). Out of scope for this fix but a candidate for a follow-up that introduces a podman-context equivalent or a candidate-path strategy.
- No other component reads `~/.docker/config.json` or Docker context metadata anywhere in the repo (verified by grep — agent C, Phase 2).

## Impact

### Severity Classification

**High**. Class: first-run discoverability and primary-command blocker. Not a crash, not data loss, not security. But it blocks `gridctl apply` (the headline command) entirely for affected users, and the displayed error misdirects them ("Is the docker daemon running?" — yes, it is). Beta-stage user pain that should not graduate to GA.

### User Reach

- **All OrbStack users on macOS** in any state where `~/.docker/run/docker.sock` is missing or broken (transient during OrbStack startup/upgrade, after reboot before OrbStack starts, or in CI). OrbStack does not set `DOCKER_HOST`; it relies on Docker contexts.
- **Colima users** in context-only configurations (Colima's docs recommend `DOCKER_HOST`, but context-only setups are common in practice).
- **Rancher Desktop users** in similar configurations.
- **Anyone using `docker context create --docker host=ssh://...`** for remote Docker — completely unsupported.
- **Not affected**: Docker Desktop users (it maintains a real `/var/run/docker.sock`), Linux users with native daemon at `/var/run/docker.sock`.

### Workflow Impact

Core-path blocker. `apply` is gridctl's primary action; this bug prevents using gridctl at all for any container-based workload on affected hosts. `info` (always probes) and `destroy --replace` (when cleanup needed) are also blocked.

### Workarounds

1. `export DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock` (or equivalent for other tools) — works, but undocumented in gridctl error output.
2. `gridctl apply --runtime docker` — **does not work**. `resolveExplicit("docker")` reuses the same `DOCKER_HOST → /var/run/docker.sock` probe (`detect.go:62-73`), so it has the same blind spot.
3. Repair the system symlink (`sudo ln -sf ~/.orbstack/run/docker.sock /var/run/docker.sock`) — works, but invasive; user should not need to do this.

None of these are surfaced in the error message. Adequacy: poor.

### Urgency Signals

- gridctl is pre-1.0 (`v0.1.0-beta.9`). Beta is the time to fix discoverability traps before they become folklore in support channels.
- OrbStack adoption on Mac is growing fast in the post–Docker Desktop-licensing-change landscape.
- The error message tells users to install Docker, which they already have — actively negative first-run signal.

## Reproduction

### Minimum Reproduction Steps

1. macOS host with OrbStack installed.
2. Ensure `DOCKER_HOST` is unset: `unset DOCKER_HOST`.
3. Ensure active context is OrbStack: `docker context use orbstack`.
4. Force the symptom by removing or breaking the convenience symlink, e.g. `sudo rm /var/run/docker.sock` (note: an OrbStack upgrade or fresh boot before OrbStack starts also exposes this naturally).
5. Confirm Docker still works: `docker ps` (proves daemon is reachable via context).
6. Confirm gridctl fails: `./gridctl apply <stack-with-image-workload>.yaml`.

Alternative without OrbStack: same setup with Colima after `colima start` without exporting `DOCKER_HOST`, or any host with `docker context create --docker host=ssh://...` and no system socket.

### Affected Environments

- macOS + OrbStack (confirmed via user transcript).
- macOS + Colima in context-only configurations.
- macOS + Rancher Desktop in moby-runtime configurations without explicit `DOCKER_HOST`.
- macOS + podman-machine using the Docker compatibility context.
- Any host (Linux, macOS, WSL) where the active context endpoint is the source of truth and `/var/run/docker.sock` is absent or broken.

### Non-Affected Environments

- Docker Desktop on Mac/Windows (real `/var/run/docker.sock` symlink, valid target).
- Native Linux Docker (`/var/run/docker.sock` is the daemon's actual socket).
- Any host with `DOCKER_HOST` exported (handled by existing `extractSocketPath` path).

### Failure Mode

Hard, deterministic failure with a non-zero exit code. No partial state is created — the orchestrator's `Up()` rejects before any container API call. Re-running `gridctl apply` after the fix lands recovers fully; no cleanup is needed.

## Fix Assessment

### Fix Surface

- **Primary**: `pkg/runtime/detect.go` — new `resolveDockerContext()` function; wire into `autoDetect()` and `resolveExplicit()`.
- **Error UX (same PR)**: `pkg/runtime/detect.go` `buildNoRuntimeError` plus `pkg/runtime/docker/client.go` Ping wrap — surface which paths were probed and distinguish dangling-symlink from socket-not-responding.
- **Tests**: `pkg/runtime/detect_test.go` — add coverage for `probeSocket`, `autoDetect`, dangling symlinks, and Docker context resolution.

Out of scope: hardcoding per-product socket paths (`~/.orbstack/run/...`, `~/.colima/...`); refactoring podman detection; `tcp://`/`ssh://` Docker host support (leave routing through `runtime.New()` + `client.FromEnv` only when `DOCKER_HOST` is explicitly set).

### Risk Factors

Low. The fix is purely additive — `resolveDockerContext()` failures (missing config, malformed JSON, missing meta file, unparseable endpoint) all fall through to existing behavior. Docker Desktop users are unaffected because their direct socket probe still succeeds at the existing position in the probe order. The only behavior change for current passing users is: if a user has *both* a working `/var/run/docker.sock` *and* an active non-`default` Docker context pointing elsewhere, the context will now win — which is the same behavior Docker CLI itself has.

### Regression Test Outline

In `pkg/runtime/detect_test.go`:

- `TestProbeSocket_DanglingSymlink` — create a tempdir, write a symlink pointing at a non-existent target, assert `probeSocket` returns `false` without panicking.
- `TestProbeSocket_RealSocket` — bind a `net.Listen("unix", path)` in a tempdir, serve a `/_ping` 200 response, assert `probeSocket` returns `true`.
- `TestProbeSocket_NonSocket` — write a regular file, assert `probeSocket` returns `false`.
- `TestResolveDockerContext_Missing` — point `DOCKER_CONFIG` at empty tempdir, assert returns `("", nil)`.
- `TestResolveDockerContext_DefaultContext` — write a `config.json` with `currentContext: "default"`, assert returns `("", nil)` (no context resolution; fall through to defaults).
- `TestResolveDockerContext_Valid` — write `config.json` + `meta.json` for a unix endpoint, assert returns the expected socket path.
- `TestAutoDetect_ContextWinsOverDanglingDefault` — full integration: tempdir with a dangling `/var/run/docker.sock` stand-in (via `DOCKER_CONFIG` indirection if possible, otherwise via a probe-path injection seam) and a valid context socket. Assert `autoDetect` returns the context's socket. **This is the bug regression test.**

## Recommendation

**Fix immediately, in a single PR**, with the scope below:

1. New `resolveDockerContext()` in `pkg/runtime/detect.go` that:
   - Reads `${DOCKER_CONFIG:-~/.docker}/config.json`.
   - Skips if `currentContext` is empty or `"default"`.
   - SHA-256 hashes the context name, reads `~/.docker/contexts/meta/<hex>/meta.json`.
   - Parses `Endpoints.docker.Host`. Accepts only `unix://` endpoints (filter out `tcp://`/`ssh://`/`npipe://` — out of scope for this fix; they route through `DOCKER_HOST` when the user opts in).
   - Returns the extracted socket path. All error conditions return `("", nil)` so callers fall through gracefully.
2. Wire into `autoDetect()` between the `DOCKER_HOST` check and the hardcoded `/var/run/docker.sock` probe.
3. Wire into `resolveExplicit("docker")` likewise, between `DOCKER_HOST` and `/var/run/docker.sock`.
4. Improve `buildNoRuntimeError`'s "Checked:" list to include the context endpoint path (with explanation if it was a dangling symlink) and improve the Ping wrap to similarly distinguish failure modes.
5. Add unit tests listed above.

No staging, no feature flag — additive fix with falls-through-on-error semantics is low-enough risk to ship in one PR.

## References

- Docker CLI context resolution order (Docker engine docs): "host > env > context > default" — gridctl currently implements three of four steps.
- Docker CLI context storage layout: `~/.docker/config.json` `currentContext` + `~/.docker/contexts/meta/<sha256>/meta.json` (`Endpoints.docker.Host`).
- Comparable Go implementations: `kind` (`sigs.k8s.io/kind`), `k3d` (`github.com/k3d-io/k3d`), `docker/compose` all read this same context layout.
- gridctl source files referenced: `pkg/runtime/detect.go`, `pkg/runtime/docker/client.go`, `pkg/runtime/docker/driver.go`, `pkg/runtime/orchestrator.go`, `pkg/controller/controller.go`, `pkg/runtime/detect_test.go`.

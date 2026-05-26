# Bug Investigation: stop --force fails to find foreground daemon

**Date**: 2026-05-14
**Project**: gridctl
**Recommendation**: Fix with caveats
**Severity**: Medium
**Fix Complexity**: Small

## Summary

`gridctl stop` and `gridctl stop --force` both report `Error: no stackless daemon is running` when a daemon was started with `gridctl serve --foreground` (or `gridctl apply <stack> --foreground`), even though the daemon is alive, listening on its port, and serving traffic. The `--force` flag's documented contract — terminating an orphan daemon discovered via port-and-process scan when the state file is missing — is broken for the most common foreground launch mode. Fix is small and well-bounded but must use port-ownership rather than argv patterns to identify the orphan, and must explicitly exclude the caller's own PID.

## The Bug

`gridctl stop --force` is documented to "forcibly terminate an orphan daemon discovered via port and process scan when the state file is missing." When the daemon is launched in foreground mode, both halves of that contract fail:

- **Expected**: `stop --force` identifies the foreground gridctl daemon on `:8180` (or the configured port), SIGTERMs it, and exits successfully.
- **Actual**: `stop` returns `Error: no stackless daemon is running` plus the usage banner. The daemon is untouched and still serving traffic.

Discovered during normal CLI use: with the gateway running and visible in the web UI at `localhost:8180` (status Connected, Gateway Active), neither `./gridctl stop` nor `./gridctl stop --force` could shut it down.

## Root Cause

Two compounding defects mean the orphan-fallback path can't see foreground daemons.

### Defect Location

- `cmd/gridctl/stop.go:43-66` — `runStop` falls through to `runStopOrphanFallback` because the state file is absent.
- `pkg/controller/controller.go:114-140` — foreground branch of `Serve` calls `buildAndRunStackless` directly; `state.Save` is only invoked inside `runStacklessDaemonChild` (lines 156-165).
- `pkg/state/orphan_unix.go:48-49` — pgrep pattern `gridctl.*--daemon-child.*--port <port>` requires `--daemon-child` in argv, which a foreground process never has.

### Code Path

1. User runs `./gridctl stop --force`.
2. `runStop()` (stop.go:43) acquires the state lock, calls `state.Load("gridctl")`.
3. Load returns nil because `~/.gridctl/state/gridctl.json` does not exist — foreground mode never wrote one.
4. Control falls into `runStopOrphanFallback()` (stop.go:73).
5. `findOrphan(8180)` is called (orphan_unix.go:30).
6. `probeHealth(8180)` succeeds — the foreground daemon answers `/health` with 200.
7. `runPgrep(8180)` runs `pgrep -f "gridctl.*--daemon-child.*--port 8180"`. The user's process is `gridctl serve --foreground --port 8180` — no `--daemon-child` token — so pgrep exits 1 with no matches.
8. `runPgrep` returns `(0, false, nil)`; `findOrphan` propagates `ok=false`.
9. `runStopOrphanFallback` returns `fmt.Errorf("no stackless daemon is running")` (stop.go:76).

### Why It Happens

The orphan fallback was added in commit `cb9d05b` ("fix: orphan daemon fallback in gridctl stop", PR #621) to resolve issue #618 — a scenario where a daemon launched by `gridctl serve` had its state file prematurely deleted during mid-shutdown but the process kept running. In that scenario, the orphan was always a `--daemon-child` process, so hardcoding `--daemon-child` into the pgrep pattern was deliberate: per the comment at orphan_unix.go:27-29, it guarantees the pattern can never match the `stop` caller itself. The fix did not account for foreground launches, which (a) never write a state file in the first place and (b) have a different argv shape.

### Similar Instances

The same defect affects every non-daemon-fork launch path:

- `gridctl serve --foreground` (this report).
- `gridctl apply <stack> --foreground` — same control flow via `apply.go:108-111` setting `Foreground:true`.
- Any future entry point that runs the gateway directly without going through `runStacklessDaemonChild` / `runDaemonChild`.

The `--daemon-child`-required pattern is structurally fragile: it couples orphan discovery to one specific launch path rather than to the property that actually matters (gridctl is listening on the target port).

## Impact

### Severity Classification

Medium. Functional defect / CLI contract violation. The `--force` flag's documented behavior is unreachable for a major launch mode. Not data-loss, not security, no resource leak — but it makes the CLI lie about the state of the world, which is a real quality bug for a developer tool.

### User Reach

Anyone using `--foreground` mode for `serve` or `apply`. Per saved memory (`feedback_serve_daemonizes.md`), the project owner uses foreground mode intentionally. Likely the most-used launch mode for active local development.

### Workflow Impact

Annoying but not blocking. The dishonest error message is more harmful than the missing kill action: a user reading `no stackless daemon is running` may attempt to start a second daemon, hit `port already in use`, and have to debug a problem the tool concealed.

### Workarounds

- Ctrl-C in the foreground terminal (works when the user has it).
- `kill <pid>` after `lsof -nP -iTCP:8180 -sTCP:LISTEN -t`.
- `pkill -f 'gridctl serve'`.

Adequate but irritating. Each requires the user to know that `stop --force` is lying.

### Urgency Signals

None active. Pre-release (beta-9). No external user reports observed. Internal dev-experience irritation.

## Reproduction

### Minimum Reproduction Steps

1. `make build`
2. Terminal A: `./gridctl serve --foreground --port 8180`
3. Wait until the gateway prints `Gateway Active` (or visit `http://localhost:8180`).
4. Terminal B: `./gridctl stop --force`
5. Observe: `Error: no stackless daemon is running` plus usage banner. Daemon in Terminal A keeps running.

Fully deterministic. Reproduces every time.

### Affected Environments

- macOS (confirmed: Darwin 24.6.0).
- Linux (by code inspection — same `orphan_unix.go` path).

### Non-Affected Environments

- Windows: `pkg/state/orphan_windows.go` makes `FindOrphan` a no-op, so the orphan fallback isn't expected to work there anyway.
- `gridctl serve` without `--foreground`: forks a `--daemon-child` and writes a state file. Stop works normally.
- `gridctl apply <stack>` without `--foreground`: same — state file written, daemon-fork path.

### Failure Mode

The CLI returns an incorrect error and exits non-zero without modifying any state. Daemon continues serving. No corruption, no resource leak. Recoverable trivially via `kill` against the lsof-discovered PID.

## Fix Assessment

### Fix Surface

- `pkg/state/orphan_unix.go` — replace argv-pattern pgrep with port-ownership lookup (e.g. `lsof -nP -iTCP:<port> -sTCP:LISTEN -t`), validate the resulting PID actually belongs to a gridctl process, and exclude `os.Getpid()`.
- New file `pkg/state/orphan_unix_test.go` — direct unit coverage for `FindOrphan` against a real listener that does NOT have `--daemon-child` in argv (e.g. a short-lived helper subprocess bound to a free port).
- `cmd/gridctl/stop_test.go` — optionally extend the existing `findOrphan` seam tests; the higher-level `TestRunStop_OrphanDaemon_WithForce` already covers the success path via stub.

No changes required in `cmd/gridctl/stop.go`, `pkg/controller/controller.go`, or any startup path. Foreground mode continues not to write a state file (out of scope, per design).

### Risk Factors

- **Misidentifying a non-gridctl process listening on the same port** as an orphan and SIGTERMing it. Mitigate: after resolving the listener PID, verify the process executable basename is `gridctl` (`/proc/<pid>/exe` on Linux; `lsof -p <pid> -F n` or `ps -o comm= -p <pid>` on macOS) before declaring an orphan. If the executable name doesn't match, return `ok=false` and let the legacy error stand.
- **Matching the caller itself.** Mitigate: explicitly exclude `os.Getpid()` from the result set (and arguably `os.Getppid()` if shell wrappers ever surface).
- **Cross-platform shell-out behavior.** `lsof` is the deterministic tool for port-to-PID on macOS and Linux. Already shelling out to `pgrep`, so no new dependency category; existing build tag `//go:build !windows` still applies.

### Regression Test Outline

In `pkg/state/orphan_unix_test.go`:

1. **`TestFindOrphan_ForegroundProcess`** — start a child subprocess that:
   - Listens on a free port (use `net.Listen("tcp", "127.0.0.1:0")`, hand the FD to the child, or have the child pick a port and write it back via a pipe).
   - Has an `/health` endpoint returning 200.
   - Has argv that does NOT contain `--daemon-child`.
   Then call `FindOrphan(port)`; assert `(pid == childPid, ok == true, err == nil)`.

2. **`TestFindOrphan_NonGridctlListener`** — start a generic HTTP listener (e.g. `httptest.Server` on a chosen port) that answers `/health` 200. Assert `FindOrphan` returns `ok=false` because the owning process is not gridctl.

3. **`TestFindOrphan_NoListener`** — pick a port with nothing on it; assert `ok=false`.

4. **`TestFindOrphan_ExcludesSelf`** — bind the test process itself to a port and have it answer `/health` 200; assert `FindOrphan` returns `ok=false` (caller filtered out).

If shelling out to `lsof` complicates determinism, add a package-level seam (`var listenerForPort = lookupListenerPort`) that tests can override, mirroring the `findOrphan` seam already used in `cmd/gridctl/stop_test.go`.

## Recommendation

Fix with caveats. The bug is real, reproducible, and breaks the documented contract of `--force`. The fix is small (one function in `orphan_unix.go` plus a new test file), but the caveats matter:

1. Identify the orphan by **port ownership**, not by argv pattern. One process owns a TCP port at a time; that's the deterministic, future-proof signal.
2. **Verify the listener is gridctl** (executable basename check) before treating it as a kill target. Without this, a stale port held by some other process could be SIGTERMed.
3. **Exclude `os.Getpid()`** from results explicitly, since the new pattern is broader than the old `--daemon-child` requirement.
4. **Do not** add `state.Save` to the foreground startup path. Foreground = user-driven lifecycle; adding state-file responsibility there expands cleanup edges and was rejected in earlier scoping.

Out of scope for this fix: refactoring the daemon-vs-foreground state model, retiring `--daemon-child` as an argv marker, or unifying launch paths.

## References

- Issue #618 — original bug that motivated the orphan fallback path (state-file deletion mid-shutdown).
- PR #621 (commit `cb9d05b`) — introduced `pkg/state/orphan_unix.go` and the `--daemon-child`-scoped pgrep pattern that this report supersedes.
- `cmd/gridctl/stop.go:23-24` — comment confirms port hardcoded by design ("Phase 3 of #618 deliberately hardcodes the port for stop fallback").
- `pkg/controller/controller.go:114-140` — foreground branch that bypasses state.Save.

# Bug Fix: stop --force fails to find foreground daemon

## Context

`gridctl` is an MCP (Model Context Protocol) orchestration tool written in Go, organized as a Cobra CLI with three primary subcommands: `apply` (deploy a stack), `serve` (stackless API + Web UI), and `stop` (terminate the running daemon). The daemon listens on a configurable TCP port (default `8180`) and exposes `/health`, `/api/*`, and the embedded web UI.

Two launch modes coexist:

- **Daemon-fork mode** (default for `serve` and `apply`): the parent process forks a child with the hidden `--daemon-child` flag. The child calls `state.Save` to write `~/.gridctl/state/gridctl.json` containing its PID and port, then runs the gateway. The parent waits for `/health` to come up and exits.
- **Foreground mode** (`-f` / `--foreground` flag): the parent runs the gateway directly. No fork, no state file, no `--daemon-child` in argv. The user keeps the terminal and Ctrl-C terminates the daemon.

State is persisted under `~/.gridctl/state/`: `gridctl.json` (the daemon state, only present in daemon-fork mode) and various `*.lock` flock files.

## Investigation Context

Investigation has already established root cause. Key findings the fix must respect:

- **Root cause traced** to `pkg/state/orphan_unix.go:48-49`. The orphan-discovery pgrep pattern requires `--daemon-child` in argv, so foreground processes (which never have that token) are invisible to `stop --force`.
- **Compounding factor** at `pkg/controller/controller.go:114-140`: foreground mode never calls `state.Save`, so the normal `stop` path also can't find the daemon. **Do not change this** — earlier scoping explicitly rejected writing state files in foreground mode (foreground lifecycle is user-driven; adding state-file responsibility expands cleanup edges).
- **Reproduces deterministically** on macOS with `./gridctl serve --foreground --port 8180` then `./gridctl stop --force`.
- **Out of scope**: refactoring the daemon-vs-foreground state model, adding state.Save to foreground mode, retiring `--daemon-child` as a launch marker.
- Full investigation: `/Users/william/code/prompt-stack/prompts/gridctl/stop-force-foreground-daemon/bug-evaluation.md`.

## Bug Description

`gridctl stop --force` is documented to "forcibly terminate an orphan daemon discovered via port and process scan when the state file is missing." When the daemon is launched in foreground mode:

- **Expected**: `stop --force` identifies the gridctl daemon listening on the configured port, SIGTERMs it, exits 0 with `Stopped orphan gridctl daemon (pid N)`.
- **Actual**: `stop --force` returns `Error: no stackless daemon is running` plus the usage banner. Exit 1. Daemon untouched and still serving.

Affects everyone who runs `gridctl serve --foreground` or `gridctl apply <stack> --foreground`.

## Root Cause

`pkg/state/orphan_unix.go` looks for the orphan daemon by running:

```
pgrep -f "gridctl.*--daemon-child.*--port <port>"
```

The `--daemon-child` token in the pattern was deliberate (per the original comment, it guaranteed pgrep could never match the `stop` caller itself). But it also excludes every other valid launch mode. Foreground processes have argv like `gridctl serve --foreground --port 8180` — no `--daemon-child` — so pgrep returns no matches, `FindOrphan` returns `ok=false`, and `runStopOrphanFallback` falls through to the legacy "no stackless daemon is running" error.

The correct signal for "is there a gridctl daemon to stop on this port" is **port ownership**: exactly one process can hold a TCP listen socket on a given port. Identify that PID, verify it's a gridctl process, exclude the caller, and you have a deterministic answer that works across every current and future launch mode.

## Fix Requirements

### Required Changes

1. **Rewrite `FindOrphan` in `pkg/state/orphan_unix.go`** to use port ownership instead of an argv pattern:
   - Keep the `probeHealth(port)` check as the first gate (cheap, validates we're talking to something that looks like gridctl).
   - Replace `runPgrep` with a listener-lookup that returns the PID currently holding `:port` for `LISTEN`. Use `lsof -nP -iTCP:<port> -sTCP:LISTEN -t` (one line per PID, integer only).
   - Filter out `os.Getpid()` from the result set.
   - For each remaining candidate PID, verify it's actually a gridctl process: read the executable basename via `ps -o comm= -p <pid>` (portable across macOS and Linux) and confirm it equals `gridctl`.
   - Return `(pid, true, nil)` only if exactly one candidate remains after filtering. Any other outcome returns `(0, false, nil)`, matching the existing "fall through cleanly on ambiguity" contract.

2. **Add `pkg/state/orphan_unix_test.go`** with direct unit coverage. To keep tests deterministic without shelling out, introduce a package-level seam:

   ```go
   var listenerForPort = lookupListenerPort   // can be overridden in tests
   var executableForPID = lookupExecutable    // can be overridden in tests
   ```

   so the tests can substitute fakes. Tests required:
   - `TestFindOrphan_ForegroundProcess` — fake listener lookup returns a real PID whose executable basename is `gridctl`; assert `(pid, true, nil)`.
   - `TestFindOrphan_NonGridctlListener` — fake listener lookup returns a PID whose executable basename is something else; assert `(0, false, nil)`.
   - `TestFindOrphan_ExcludesSelf` — fake listener lookup returns only `os.Getpid()`; assert `(0, false, nil)`.
   - `TestFindOrphan_NoListener` — fake listener lookup returns empty; assert `(0, false, nil)`.
   - `TestFindOrphan_HealthDown` — fake `/health` probe fails; assert `(0, false, nil)` without touching listener lookup.

3. **Preserve all existing behavior in `cmd/gridctl/stop.go`** — no changes required. The existing `findOrphan` package-level seam means the higher-level tests in `cmd/gridctl/stop_test.go` continue to cover the happy path and `--force`-not-set path with stubs.

### Constraints

- **Do not** call `state.Save` in any new path. Foreground mode must remain stateless — out of scope per investigation.
- **Do not** weaken the "fall through cleanly on ambiguity" contract. If anything looks off (zero or multiple candidates after filtering, executable check fails, health probe fails), return `ok=false` so the user sees the legacy "no stackless daemon is running" error rather than acting on a guess. This preserves the original safety property that motivated the strict pgrep pattern.
- **Do not** match the caller itself. Excluding `os.Getpid()` is required, not optional.
- **Preserve the `//go:build !windows` build tag** on `orphan_unix.go`. Don't add functionality to `orphan_windows.go` — Windows daemon mode is out of scope.

### Out of Scope

- Writing state files for foreground processes.
- Refactoring `--daemon-child` out of the codebase.
- Changes to `cmd/gridctl/stop.go`, `cmd/gridctl/apply.go`, `cmd/gridctl/root.go`, or any controller path.
- Cleanup-on-exit handling.
- Windows support for orphan discovery.
- Cosmetic improvements to the error message in `runStopOrphanFallback` (already informative).

## Implementation Guidance

### Key Files to Read

- `pkg/state/orphan_unix.go` — current implementation. The comment block at lines 14-29 explains *why* the original pattern was strict; respect that intent (don't act on guesswork) when designing the replacement.
- `pkg/state/orphan_windows.go` — no-op stub. Confirms the function's interface and that Windows is intentionally out of scope.
- `cmd/gridctl/stop.go` — orphan fallback caller. Look at `runStopOrphanFallback` (lines 73-89) and the comment at lines 23-24 ("Phase 3 of #618 deliberately hardcodes the port") to understand the contract `FindOrphan` is fulfilling.
- `cmd/gridctl/stop_test.go` — existing test patterns. The `stubFindOrphan` seam at lines 91-96 is the model for the new in-package seams.
- `pkg/state/state.go` — `BaseDir`, `KillDaemon`, and friends; the orphan code does not need to call into them, but reading them confirms how `KillDaemon` consumes the `DaemonState` you return.

### Files to Modify

- `pkg/state/orphan_unix.go` — replace `runPgrep` with port-ownership lookup; add private helpers `lookupListenerPort(port int) ([]int, error)` (lsof shell-out) and `lookupExecutable(pid int) (string, error)` (`ps -o comm= -p <pid>`); add the two `var`-style seams; rewrite `FindOrphan` to compose them.
- `pkg/state/orphan_unix_test.go` — new file, build-tagged `//go:build !windows`. Tests use the seams; do not shell out to `lsof`/`ps` from test code.

### Reusable Components

- `os/exec` for shelling out (already imported in `orphan_unix.go`).
- `strconv.Atoi` and `strings.Fields` for parsing lsof output (already imported).
- `os.Getpid` for the self-exclusion filter.
- `path/filepath.Base` is appropriate if you parse `lsof`'s executable column instead of using `ps -o comm=` (either works; `ps -o comm=` is simpler and produces the bare basename directly).

### Conventions to Follow

- Idiomatic Go error returns: `(value, ok, err)` triple already used by `FindOrphan`. Preserve that signature.
- The existing pattern of distinguishing "expected non-match" (e.g. exit code 1 from `pgrep`) from "real error" by `errors.As(err, &exitErr)` — do the same for `lsof` (exit code 1 when nothing listens on the port).
- Keep helpers lower-cased / unexported in the package.
- Comments: terse, explaining *why* (the safety property — "never act on guesswork") rather than *what*. Match the tone of the existing file header comments.

## Regression Test

### Test Outline

In `pkg/state/orphan_unix_test.go` (new file):

```go
//go:build !windows

package state

// Cover each branch via the seams:
//   - listenerForPort returns the foreground daemon's pid -> (pid, true, nil)
//   - listenerForPort returns a non-gridctl pid -> (0, false, nil)
//   - listenerForPort returns os.Getpid() only -> (0, false, nil)
//   - listenerForPort returns empty -> (0, false, nil)
//   - probeHealth returns false -> (0, false, nil), listener lookup never called
```

Use `t.Cleanup` to restore the package-level vars after each test, exactly as `cmd/gridctl/stop_test.go:stubFindOrphan` does at lines 91-96.

For each test, replace `probeHealth` via a similar `var probeHealthFn = probeHealth` seam (or inline-construct `FindOrphan` with parameters — either approach is acceptable, but the seam pattern is consistent with the rest of the codebase).

### Existing Test Patterns

See `cmd/gridctl/stop_test.go` for:
- The `setTempHomeStop(t)` helper that sandboxes `HOME` to a temp dir — useful if any test happens to construct paths under `state.BaseDir()`.
- The `stubFindOrphan` pattern at lines 91-96 for swapping package-level seams with cleanup.
- Use of real subprocesses (`exec.Command("sleep", "60")`) when a live PID is needed (lines 57-87, 115-146). Most of the new orphan tests should NOT need real subprocesses because the seams obviate it — but a single end-to-end smoke test against a real listener is fine if it's hermetic.

## Potential Pitfalls

- **`lsof` permission edge cases**: on macOS, `lsof -iTCP -sTCP:LISTEN -t` for a port owned by another user can return that user's PID. Verify the executable-name check still rejects it cleanly. The `ps -o comm= -p <pid>` call will succeed regardless of ownership and return the binary name.
- **macOS-vs-Linux `ps -o comm=` output**: both return the basename, but Linux may include the `(name)` suffix for renamed threads. Strip parens/whitespace defensively before comparing to `"gridctl"`.
- **Multiple gridctl processes from prior crashed test runs**: only one can actually be listening on the port (the kernel enforces this), so the listener-lookup approach naturally narrows to one. Don't try to be clever about scanning all gridctl processes — the port owner is the source of truth.
- **Confusing the caller with the orphan**: `os.Getpid()` filter is necessary because the new pattern is broader than the old `--daemon-child` requirement. If a user ran `./gridctl stop --force` and somehow that process bound the port (it doesn't, but be paranoid), the filter prevents self-SIGTERM.
- **lsof output format**: `-t` returns terse output (one PID per line, nothing else). Don't enable other format flags simultaneously or parsing will break.
- **`probeHealth` is the gate**: keep it first. If it fails, do not run `lsof`. This preserves the existing performance/safety property and matches the original code structure.

## Acceptance Criteria

1. `./gridctl serve --foreground --port 8180` (Terminal A), then `./gridctl stop --force` (Terminal B) prints `Stopped orphan gridctl daemon (pid N)` and exits 0; the daemon in Terminal A exits.
2. `./gridctl serve --foreground --port 8180` (Terminal A), then `./gridctl stop` (without `--force`) returns the existing actionable error message containing the discovered PID, `:8180`, and the suggestion to use `--force` (no regression on the no-force path).
3. `./gridctl serve` (no flags) followed by `./gridctl stop` continues to work via the normal state-file path (no regression on the daemon-fork path).
4. With no gridctl daemon running, `./gridctl stop --force` returns `Error: no stackless daemon is running` (no regression on the absent-daemon path).
5. `go test ./...` passes, including the new `pkg/state/orphan_unix_test.go` cases listed above.
6. `golangci-lint run` passes.
7. `pkg/state/orphan_windows.go` is unchanged.
8. No new dependencies are added to `go.mod`.

## References

- Issue #618 — original bug (state-file deleted mid-shutdown).
- PR #621 (commit `cb9d05b`) — introduced `pkg/state/orphan_unix.go` and the strict pgrep pattern this fix replaces.
- `lsof(8)` `-t` flag — terse output; one numeric PID per line.
- `ps -o comm= -p <pid>` — portable POSIX `ps` invocation to get the bare command name for a PID.

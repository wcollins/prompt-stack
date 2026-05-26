# Bug Fix: Unstoppable Daemon After SIGTERM

## Context

`gridctl` is a Go CLI that manages an MCP gateway daemon. The daemon is started either as a foreground process or as a backgrounded `--daemon-child` forked by the parent CLI (see `pkg/controller/daemon.go`). State about the running daemon (PID, port, start time) is persisted as a JSON file at `~/.gridctl/state/<stack>.json` so subsequent invocations of `gridctl stop` / `gridctl status` / `gridctl apply` can find and manage it.

In stackless mode (`gridctl serve`), the daemon serves the MCP gateway HTTP API on a configured port (default `:8180`) plus a web UI and several background loops: session cleanup, MCP server health monitoring, autoscaler ticks, an agent IDE file watcher, and optionally a hot-reload stack watcher.

Tech stack: Go (CLI), Cobra (command framework), standard library context/signal, `slog` for logging, JSON state files, flock-based state locking.

Relevant directories:

- `cmd/gridctl/` — Cobra command implementations.
- `pkg/controller/` — daemon lifecycle, gateway builder, signal handling.
- `pkg/state/` — state file Load/Save/Delete/Lock and PID verification.
- `pkg/mcp/` — gateway, health monitor, autoscaler, cleanup goroutines.

## Investigation Context

Root cause confirmed via static analysis on commit `a8fea96`:

- **Bug 1** — `pkg/controller/gateway_builder.go:1104` deletes the state file inside the SIGTERM handler before the surrounding shutdown sequence completes and before the function returns. If anything downstream blocks (and it empirically does — see Bug 2), the state file is gone while the process is still alive, so `gridctl stop` reports "no stackless daemon is running" despite the daemon still serving traffic.
- **Bug 2** — `cmd/gridctl/apply.go:85` and `:108` pass `context.Background()` to `ctrl.Serve` / `ctrl.Deploy`. That ctx threads through into `gateway.StartHealthMonitor`, `gateway.StartAutoscaler`, the agent IDE watcher (`w.Run(ctx)` at `pkg/controller/gateway_builder.go:397`), and the file watcher (`watcher.Watch(watchCtx)` at line 1027). `waitForShutdown` uses a local `signal.Notify` channel and never cancels the root ctx. Daemon logs prove the process continues running for 11+ hours after "received signal, shutting down".

Risk mitigations baked into the fix requirements below:

- Phase the change in three steps; do not bundle them as one indivisible diff. Land step 1, prove daemon exits under SIGTERM via integration test, then land steps 2 and 3.
- Existing reference implementation in `cmd/gridctl/agent.go:113` uses `signal.NotifyContext(cmd.Context(), syscall.SIGINT, syscall.SIGTERM)` — follow that pattern.
- Stop fallback must not auto-kill arbitrary processes; require both a port-probe signal AND a `pgrep` PID match before reporting an orphan, and require `--force` to actually send a kill signal.

Reproduction confirmed via the evidence chain in the investigation report. Bug occurs deterministically on macOS Darwin 24.6.0; Linux is overwhelmingly likely affected (same Go signal semantics, same context plumbing).

Full investigation: `prompts/gridctl/unstoppable-daemon-after-sigterm/bug-evaluation.md`.

## Bug Description

Running `gridctl stop` returns:

```
Error: no stackless daemon is running
```

…while the daemon is still alive and bound to its configured port. Reproduces deterministically when the daemon has received SIGTERM through any path other than `gridctl stop` itself (manual `kill <pid>`, parent terminal/IDE shutdown, prior failed `gridctl stop`, supervisor SIGTERM).

Expected: `gridctl stop` finds the daemon, sends SIGTERM, waits for graceful shutdown, removes the state file, prints "gridctl stopped".

Actual: state file is gone, daemon process is still alive on its port, `gridctl stop` has no way to find it. Recovery requires manual `kill -9`. Port stays bound; subsequent `gridctl serve` cannot rebind.

## Root Cause

1. **Premature state-file deletion**: `pkg/controller/gateway_builder.go:1104` calls `state.Delete(b.stack.Name)` inside `waitForShutdown`'s signal-receive branch. This runs before `waitForShutdown` returns, before `defer gateway.Close()` runs, and before the rest of the call chain unwinds.
2. **Root context never canceled**: `cmd/gridctl/apply.go:85` (`runServeStackless`) and `cmd/gridctl/apply.go:108` (`runApply`) pass `context.Background()` to the controller. `waitForShutdown` at `pkg/controller/gateway_builder.go:1066-1067` installs a local signal channel but never cancels the root ctx, so ctx-bound goroutines (health monitor, autoscaler, agent IDE watcher, file watcher) never receive a stop signal. The actual blocker on `waitForShutdown` returning is presumed to be inside the shutdown sequence (`gateway.Close()` synchronous client closers, tracing provider Shutdown, telemetry flusher Stop, or HTTPServer.Shutdown) holding resources that themselves depend on the uncanceled ctx.

The correct logic:

- All daemon-child entry points construct a cancellable ctx via `signal.NotifyContext(parentCtx, os.Interrupt, syscall.SIGTERM)` and pass it down.
- `waitForShutdown` listens on `<-ctx.Done()` instead of a local signal channel.
- `state.Delete` happens once, on actual process exit, via a defer in the daemon-child entry — never mid-shutdown.
- `gridctl stop` has a fallback discovery path for orphan processes when the state file is missing.

## Fix Requirements

Land the fix in three sequential phases. Each phase ships as its own PR or commit so the integration test from phase 1 can guard phases 2 and 3.

### Phase 1 — Cancel the root ctx on signal

Required changes:

1. In `cmd/gridctl/apply.go`:
   - In `runServeStackless` (around line 75-86): replace `ctrl.Serve(context.Background())` with a ctx derived from `signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)`. Defer the returned `cancel`.
   - In `runApply` (around line 88-131): same pattern for `ctrl.Deploy(context.Background())`.
   - Use the existing `cmd/gridctl/agent.go:113` line as the reference shape.
2. In `pkg/controller/gateway_builder.go`:
   - In `waitForShutdown` (line 1064-1108): remove the local `signal.Notify(done, …)` setup. Listen on `<-ctx.Done()` instead. Preserve the existing `serverErr` case.
   - Pass `ctx` into `waitForShutdown` (extend its signature) — it already receives `inst, handler, serverErr, verbose`; thread `ctx` from the caller `Run` at line 435.
   - Make `shutdownCtx` derive from `context.Background()` deliberately (it must NOT be a child of `ctx`, because `ctx` is already canceled at this point and the timeout child would fire instantly) — but cap it at 15 seconds as today.
3. Verify nothing else listens on `signal.Notify` for SIGTERM/SIGINT on the daemon-child path that would race with the new ctx-based handling.

### Phase 2 — Defer `state.Delete` to actual process exit

Required changes:

1. In `pkg/controller/controller.go`:
   - In `runStacklessDaemonChild` (line 142-168): after `state.Save(st)` succeeds, add `defer func() { _ = state.Delete("gridctl") }()`. Remove the implicit assumption that `waitForShutdown` will do this.
   - In `runDaemonChild` (line 362-388): same pattern — defer `state.Delete(stack.Name)` immediately after `state.Save(st)` succeeds.
2. In `pkg/controller/gateway_builder.go`:
   - Remove the `state.Delete(b.stack.Name)` call at line 1104 (inside the signal branch).
   - Remove the `state.Delete(b.stack.Name)` call at line 1106 (inside the server-error branch). The defer in the daemon-child entry covers both exit paths.

### Phase 3 — Orphan-discovery fallback in `gridctl stop`

Required changes:

1. In `pkg/state/state.go`:
   - Add `FindOrphan(port int) (pid int, ok bool, err error)`. Implementation: probe `127.0.0.1:<port>/health` with a short timeout; if the probe succeeds, run `pgrep -f "gridctl.*--daemon-child.*--port <port>"`; require BOTH signals (probe succeeded AND exactly one matching PID) before returning `ok=true`. If `pgrep` returns multiple matches, return `ok=false` (ambiguous — let the user disambiguate).
2. In `cmd/gridctl/stop.go`:
   - Add a `--force` flag bound to a package-level `var stopForce bool`.
   - In `runStop`, when `state.Load` returns nil (ENOENT), call `state.FindOrphan(defaultPort)` (use 8180 as default; if a `--port` flag is added later it can override).
   - If `FindOrphan` returns `ok=true`:
     - Without `--force`: return an actionable error: `fmt.Errorf("daemon state file is missing, but a gridctl process (pid %d) is listening on :%d. Run 'gridctl stop --force' to terminate it, or 'kill -9 %d' manually", pid, port, pid)`.
     - With `--force`: synthesize a minimal `DaemonState{PID: pid, Port: port, StackName: "gridctl"}` and call `state.KillDaemon` to reuse the existing SIGTERM-then-SIGKILL grace flow.
   - If `FindOrphan` returns `ok=false`: keep the existing "no stackless daemon is running" error.

### Constraints

- Do NOT change the wire shape of the state JSON file. Existing daemons must remain compatible.
- Do NOT change the `gridctl stop` exit code semantics for the existing happy path or stale-state path. Only add new behavior for the orphan case.
- Do NOT auto-kill processes without `--force`. The current default behavior (refuse to act on ambiguous state) must stay.
- Do NOT skip the integration test in phase 1. It is the regression guardrail.
- Preserve the existing 15-second HTTPServer.Shutdown grace period. If the daemon needs longer to drain, that's a separate problem.
- Sign all commits with `-S`. No `Co-authored-by:` trailers. No mention of Claude in commits/PRs/branch names.

### Out of Scope

- Refactoring the rest of `waitForShutdown`'s shutdown sequence ordering (telemetry, tracing, logRouter) beyond honoring ctx cancellation. If a specific blocking call is observed during phase-1 integration testing, fix it surgically in the same PR; otherwise defer.
- Replacing the JSON state-file model with a PID-file / Unix domain socket / systemd-style supervision.
- Adding `gridctl status --force-clean` or similar UX improvements.
- Touching the `destroy` command's parallel shape (`cmd/gridctl/destroy.go:56`). It is not currently broken; the bug only manifests when the parent process never exits.

## Implementation Guidance

### Key Files to Read

- `cmd/gridctl/agent.go` (around line 113) — existing reference implementation of `signal.NotifyContext`. Match this pattern.
- `pkg/controller/gateway_builder.go` lines 367-435 (the `Run` function) and 1064-1108 (`waitForShutdown`) — understand the lifecycle the fix has to live inside.
- `pkg/mcp/gateway.go` lines 392-409 (`StartCleanup`), 413-426 (`StartHealthMonitor`), 700-710 (`Close`), 827-848 (`StartAutoscaler`) — confirm each respects ctx.Done().
- `pkg/state/state.go` lines 195-238 (`KillDaemon`) — already implements SIGTERM-then-SIGKILL grace; phase 3's `--force` path reuses this.
- `cmd/gridctl/stop_test.go` — existing test shape for stop scenarios; phase 3's tests live here.

### Files to Modify

- `cmd/gridctl/apply.go` — phase 1 (lines 85 and 108).
- `pkg/controller/gateway_builder.go` — phase 1 (signature + body of `waitForShutdown` at 1064-1108) and phase 2 (remove `state.Delete` calls at 1104 and 1106).
- `pkg/controller/controller.go` — phase 2 (add `defer state.Delete` in `runStacklessDaemonChild` at 142-168 and `runDaemonChild` at 362-388).
- `pkg/state/state.go` — phase 3 (add `FindOrphan`).
- `cmd/gridctl/stop.go` — phase 3 (fallback logic and `--force` flag).
- `cmd/gridctl/stop_test.go` — phase 3 regression tests.
- New file (suggested): `pkg/controller/shutdown_integration_test.go` — phase 1 integration test forking a real subprocess.

### Reusable Components

- `signal.NotifyContext` (standard library) — context-aware signal handler. Already used in `cmd/gridctl/agent.go:113`.
- `state.KillDaemon` (`pkg/state/state.go:195-238`) — SIGTERM-then-SIGKILL grace flow. Reuse from `runStop --force`.
- `state.VerifyPID` (`pkg/state/state.go:154`) — process-existence check via signal 0.

### Conventions to Follow

- Commit format: `<type>: <subject>` where type is `fix` for these changes. Subject ≤50 chars, imperative mood, no period.
- Branch naming: `fix/<short-description>` (e.g., `fix/daemon-exit-on-sigterm`).
- Comments are sparse in this codebase and most existing block-comments live next to non-obvious mechanics (`pkg/mcp/gateway.go` has good examples). Add a one-line comment on the new defer explaining state-lifetime invariant; do NOT add a paragraph-style explanation.
- Error wrapping with `fmt.Errorf("…: %w", err)` is the project standard.
- Logging via `slog`. The daemon's logger is plumbed through `bufferHandler`; use `slog.New(bufferHandler)` if you need to log from new shutdown code.

## Regression Test

### Test Outline

**Phase 1 integration test** (new file `pkg/controller/shutdown_integration_test.go` or `cmd/gridctl/serve_integration_test.go`):

- Pre-build the test binary with `go build -o <tmpdir>/gridctl ./cmd/gridctl` (or use `exec.Command(os.Args[0], "-test.run=helperFunc")` with a TestMain helper-process pattern).
- Set HOME to a `t.TempDir()` so state, logs, and locks land in a sandbox.
- Pick a random free port (use `net.Listen("tcp", ":0")` then immediately close to discover a port).
- Start the subprocess: `<binary> serve --daemon-child --port <port>` with stdout/stderr captured to a buffer.
- Poll `http://localhost:<port>/health` until it returns 200 OR until a 10-second deadline.
- Send `syscall.SIGTERM` to the subprocess.
- Assert the subprocess exits within 10 seconds (use `exec.Cmd.Wait()` with a goroutine + select on a 10s timer).
- Assert `state.Load("gridctl")` returns ENOENT after exit (state file cleaned up).
- Skip on Windows (`runtime.GOOS == "windows"`).

**Phase 3 unit tests** (`cmd/gridctl/stop_test.go`):

- `TestRunStop_OrphanDaemon_NoForce`: start a long-lived dummy subprocess (`exec.Command("sleep", "60")` with a port-binding helper), do not save a state file, run `runStop` without `--force`, assert error message mentions the PID and port (not the legacy "no stackless daemon is running").
- `TestRunStop_OrphanDaemon_WithForce`: same setup, set `stopForce = true`, assert `runStop` succeeds and the subprocess is killed.
- `TestRunStop_OrphanDaemon_AmbiguousPgrep`: simulate multiple matching processes (or stub `pgrep`), assert `FindOrphan` returns `ok=false` and `runStop` falls back to the legacy error rather than killing the wrong process.

### Existing Test Patterns

- `cmd/gridctl/stop_test.go` uses `setTempHomeStop(t)` to redirect HOME to a temp directory — copy that pattern.
- `cmd/gridctl/stop_test.go:51-81` (`TestRunStop_RunningDaemon`) shows the existing pattern for spawning a dummy subprocess and registering cleanup — model the new tests on this.
- `pkg/controller/controller_test.go:678,694` uses `t.Context()` — but those are unit tests; the new integration test must use a real signal handler, so use `context.Background()` and manage the child via os/exec.

## Potential Pitfalls

- **Double cancel on shutdown**: `signal.NotifyContext` returns both a ctx and a `stop` function. Defer the `stop` (it releases the signal handler), but expect the ctx to also be canceled by `gateway.Close()`-related defers downstream. Cancellation is idempotent so this is safe; just don't write code that assumes a single source of cancellation.
- **`shutdownCtx` parent**: in `waitForShutdown`, the new code path runs *because* ctx is already canceled. Deriving `shutdownCtx` from `ctx` via `context.WithTimeout(ctx, 15*time.Second)` would yield an immediately-expired context. Keep `shutdownCtx`'s parent as `context.Background()` (which is what the current code already does — preserve this).
- **`pgrep` portability**: `pgrep` exists on macOS and Linux but with subtly different flag semantics. Test the exact invocation on both. On macOS, `pgrep -f` matches against the full command line; on Linux, `pgrep` defaults to matching just the process name unless `-f` is given. Use `-f` and test on both.
- **Port-probe false negative under load**: if the daemon is alive but its HTTP server is hung, `/health` will time out. Use a 500ms timeout (matching `daemon.go:129`) and treat timeout as ambiguous rather than absent. The investigation report's blocking-call hypothesis means a stuck daemon may not respond to `/health` — in which case `pgrep` alone should NOT be trusted to identify an orphan. Document this edge case in the error message: "found a possible gridctl process at PID <n> but its health endpoint is not responding — verify manually before using --force".
- **TestMain helper-process pattern**: the cleanest way to integration-test a forked binary is the `os/exec` "self-exec via env var" pattern. If you go that route, gate the test-binary-as-daemon mode behind an environment variable so the test binary doesn't accidentally become a daemon when run normally.
- **State file race**: between phase 1 landing and phase 2 landing, the state file is still deleted from `waitForShutdown`. That's fine — phase 1's fix means `waitForShutdown` actually returns now, so the daemon exits cleanly. The transient window is acceptable. Don't try to land phases 1 and 2 in the same commit "for safety" — that defeats the phased verification.
- **Agent IDE watcher**: the watcher's `Run(ctx)` (`pkg/controller/gateway_builder.go:397`) is the most recent addition (commit `a8fea96`). Confirm that `watcher.Watcher.Run` actually honors ctx.Done() — if it doesn't, fixing the apply-path ctx propagation won't be enough and the watcher needs its own fix.

## Acceptance Criteria

1. After phase 1, `kill <daemon-pid>` causes the daemon to exit within 15 seconds (the HTTPServer.Shutdown grace period). Verifiable via the new integration test and via manual `lsof -iTCP:<port>` after kill.
2. After phase 2, the state file (`~/.gridctl/state/gridctl.json`) persists until the daemon process actually exits, then is removed by the deferred `state.Delete` in the daemon-child entry. Verifiable in the integration test.
3. After phase 3, `gridctl stop` invoked on an orphan (alive process, missing state file) returns an error that names the PID and port and instructs the user how to recover. `gridctl stop --force` on the same orphan terminates it cleanly.
4. The existing `stop_test.go` happy-path tests (`TestRunStop_NoDaemonRunning`, `TestRunStop_StaleState`, `TestRunStop_RunningDaemon`) continue to pass unchanged.
5. `go test -race ./...` passes after all three phases.
6. `golangci-lint run` passes.
7. `make build` produces a working `./gridctl` binary; manual smoke test (`./gridctl serve`, `kill <pid>`, observe exit, `./gridctl serve` again succeeds) confirms the bug is gone.

## References

- `prompts/gridctl/unstoppable-daemon-after-sigterm/bug-evaluation.md` — full investigation report.
- Go stdlib: `signal.NotifyContext` — https://pkg.go.dev/os/signal#NotifyContext
- Existing reference implementation in this repo: `cmd/gridctl/agent.go:113`.
- `pkg/state/state.go:195-238` (`KillDaemon`) — SIGTERM-then-SIGKILL helper to reuse for `--force`.

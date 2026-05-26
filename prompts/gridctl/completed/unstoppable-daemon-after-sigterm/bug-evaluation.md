# Bug Investigation: Unstoppable Daemon After SIGTERM

**Date**: 2026-05-13
**Project**: gridctl
**Recommendation**: Fix immediately (next release)
**Severity**: High
**Fix Complexity**: Small

## Summary

`gridctl stop` reports "no stackless daemon is running" while the daemon process is still alive and listening on its configured port. Two interacting defects in the shutdown path cause it: `state.Delete` is called mid-shutdown (before the process actually exits), and the root context threaded through long-running goroutines is never canceled, so the process never exits at all. The bug is deterministic on macOS (and almost certainly Linux) on the current `main` (`a8fea96`). Fix bundles three coordinated changes: cancel the root ctx on signal, defer state-file deletion to actual process exit, and add a fallback discovery path to `gridctl stop`.

## The Bug

Running `gridctl stop` after the daemon has received SIGTERM through any path other than `gridctl stop` itself returns:

```
Error: no stackless daemon is running
```

…even though `ps`/`lsof` confirm a daemon process is alive and bound to the configured port (default `:8180`). The expected behavior is that `gridctl stop` finds the daemon, sends SIGTERM, waits for graceful shutdown, removes the state file, and prints "gridctl stopped".

Discovered empirically on `main` at commit `a8fea96` with a daemon started via `./gridctl serve`. Log evidence from `~/.gridctl/logs/gridctl.log` shows the daemon firing periodic session cleanup more than 11 hours after logging "received signal, shutting down" — proving the process never actually exited.

## Root Cause

### Defect Location

Two interacting defects:

- **Bug 1 — premature state-file delete**: `pkg/controller/gateway_builder.go:1104` — `state.Delete(b.stack.Name)` is called inside the signal branch of `waitForShutdown`, before the function returns and before `defer gateway.Close()` runs.
- **Bug 2 — root ctx never canceled**: `cmd/gridctl/apply.go:85` (`runServeStackless`) and `cmd/gridctl/apply.go:108` (`runApply`) both pass `context.Background()` into `ctrl.Serve` / `ctrl.Deploy`. `waitForShutdown` at `pkg/controller/gateway_builder.go:1066-1067` installs a local `signal.Notify` channel but never propagates cancellation to that root ctx.

### Code Path

1. `serveCmd` (`cmd/gridctl/root.go:50`) → `runServeStackless` (`cmd/gridctl/apply.go:75`) → `ctrl.Serve(context.Background())`.
2. `StackController.Serve` (`pkg/controller/controller.go:114`) → `runStacklessDaemonChild` → `buildAndRunStackless` → `GatewayBuilder.BuildAndRun(ctx, …)`.
3. `BuildAndRun` (`pkg/controller/gateway_builder.go:147`) → `Run(ctx, inst, …)`.
4. `Run` (`pkg/controller/gateway_builder.go:367`) launches background goroutines bound to the never-canceled `ctx`:
   - `gateway.StartCleanup(ctx)` at line 372 — this one derives its own cancellable ctx stored on the gateway; `gateway.Close()` cancels it.
   - Agent IDE watcher `w.Run(ctx)` at line 397 — blocking goroutine, bound to root ctx.
   - `gateway.StartHealthMonitor(ctx, …)` at line 413 → `pkg/mcp/gateway.go:413` — bound to root ctx.
   - `gateway.StartAutoscaler(ctx, …)` at line 414 → `pkg/mcp/gateway.go:827` — bound to root ctx.
   - `b.setupHotReload(ctx, …)` at line 428 — derives `watchCtx` from root ctx for `watcher.Watch(watchCtx)` at line 1027.
5. `Run` then `return b.waitForShutdown(inst, …)` at line 435.
6. `waitForShutdown` (`pkg/controller/gateway_builder.go:1064-1108`) on SIGTERM: closes APIServer, shuts down HTTPServer with a `shutdownCtx` derived from `context.Background()` (not from `ctx`), shuts down telemetry/tracing/logRouter, **calls `state.Delete(b.stack.Name)`**, then returns nil.
7. After `waitForShutdown` returns, `Run` should return, the `defer gateway.Close()` should fire, the call chain should unwind, and the process should exit. The empirical 11+ hour survival proves it does not.
8. `runStop` (`cmd/gridctl/stop.go:23`) treats the state file as the single source of truth (`state.Load` at `pkg/state/state.go:75` is a plain `os.ReadFile`). ENOENT → "no stackless daemon is running".

### Why It Happens

- `state.Delete` is run too early in the shutdown sequence. As long as anything downstream of it blocks (and the evidence shows something does), the state file is gone while the process is still alive — `gridctl stop` then has no signal to find the daemon.
- The root ctx is never canceled, so ctx-bound goroutines (health monitor, autoscaler, agent watcher, file watcher) never receive a stop signal. Goroutines alone don't keep a Go program alive, so the actual blocker must be in the main return path — most likely one of: `defer gateway.Close()`'s synchronous client closers (`pkg/mcp/gateway.go:700`), the metrics flusher's `Stop()`, tracingProvider.Shutdown, or logRouter.Close holding resources that themselves depend on the never-canceled ctx. Static analysis cannot pinpoint which without runtime verification, but the structural fix (cancel the ctx) addresses the class of problem regardless of which specific call is the immediate blocker.

### Similar Instances

- `cmd/gridctl/apply.go:108` — `runApply` calls `ctrl.Deploy(context.Background())`. Same defect, same shape, affects the stack-deploy path identically.
- `cmd/gridctl/destroy.go:56` — calls `state.Delete(stack.Name)` directly after sending SIGTERM. Less impacted because destroy waits for the process to exit first (via `state.KillDaemon`), but if KillDaemon's grace window expires and SIGKILL also doesn't reap (rare), the same orphan-with-no-state-file shape could occur.
- `cmd/gridctl/agent.go:113` shows the correct pattern already in use elsewhere: `signal.NotifyContext(cmd.Context(), syscall.SIGINT, syscall.SIGTERM)`. The fix essentially extends this pattern to `apply` and `serve`.

## Impact

### Severity Classification

**High**. This is a control-plane regression: the CLI's own stop command stops working as soon as the daemon has received SIGTERM through any non-`stop` path. It is not data loss or a security issue (so not Critical), but a CLI's stop command should always work.

### User Reach

Any developer running `gridctl serve` or `gridctl apply` who ever sends SIGTERM outside the `gridctl stop` flow:

- Manual `kill <pid>` for any reason.
- Closing a parent terminal/IDE that propagates SIGTERM to the daemon.
- A prior `gridctl stop` that crashed or timed out mid-execution.
- A process supervisor or CI shutdown that issues SIGTERM and expects clean state.

### Workflow Impact

- Port stays bound; subsequent `gridctl serve` fails to bind `:8180`.
- Recovery requires identifying the orphan PID (`lsof`/`ps`) and `kill -9`.
- Once entered, this state is sticky — every future invocation fails until manual recovery.
- Developer-workflow paper cut on every occurrence.

### Workarounds

```sh
kill <pid>             # often won't work given the bug
kill -9 <pid>          # required to actually terminate
rm -f ~/.gridctl/state/gridctl.lock   # only if the lock file is also stuck (rare)
```

Adequacy: works mechanically, but defeats the purpose of having a `stop` command and assumes the user knows about `lsof`/`ps`.

### Urgency Signals

- Deterministically reproducible on current `main`.
- Recent commits (`a8fea96`, `9f6675d`) just wired the agent IDE dev server — a plausible new blocker goroutine on the daemon-child path.
- No public issue tracker presence yet, but the bug shape is one that erodes trust in the CLI quickly.

## Reproduction

### Minimum Reproduction Steps

1. `make build`
2. `./gridctl serve` (confirm `~/.gridctl/state/gridctl.json` exists and a daemon is listening on `:8180`).
3. `kill <daemon-pid>` (NOT `./gridctl stop`).
4. Wait 5 seconds. Observe:
   - `~/.gridctl/logs/gridctl.log` records "received signal, shutting down".
   - The daemon process is still alive (`ps aux | grep gridctl`, `lsof -nP -iTCP:8180 -sTCP:LISTEN`).
   - `~/.gridctl/state/gridctl.json` no longer exists.
5. `./gridctl stop` → `Error: no stackless daemon is running` despite the daemon serving traffic.

### Affected Environments

- macOS (Darwin 24.6.0) — confirmed by reporter.
- Linux — extremely high confidence (same Go signal semantics, same context plumbing, `fsnotify` cross-platform); not directly verified.

### Non-Affected Environments

- Windows — daemon mode uses `Setsid` and SIGTERM semantics that aren't a clean fit. Likely not exercised on Windows.
- `gridctl stop` invoked on a daemon whose state file is still present succeeds (the bug only triggers after some other path has deleted the state file or after a partially-completed shutdown).

### Failure Mode

Deterministic, not intermittent. State file is gone within the SIGTERM handler's first few milliseconds; process never exits, so the state file is permanently absent for the daemon's lifetime. System is left in a recoverable-but-stuck state: port bound, no state, manual `kill -9` required.

## Fix Assessment

### Fix Surface

- `cmd/gridctl/apply.go` — `runServeStackless` (line 75-86) and `runApply` (line 88-131): construct a cancellable ctx via `signal.NotifyContext` and pass it down.
- `pkg/controller/controller.go` — `runStacklessDaemonChild` (line 142-168) and `runDaemonChild` (line 362-388): move `state.Delete` to a `defer` in the daemon-child entry so state-file lifetime tracks process lifetime.
- `pkg/controller/gateway_builder.go` — `waitForShutdown` (line 1064-1108): listen on `<-ctx.Done()` instead of a local signal channel; remove the in-function `state.Delete` call; rely on the caller's defer.
- `cmd/gridctl/stop.go` — `runStop` (line 23-46): add a fallback discovery path when the state file is missing (port probe + `pgrep`); offer an explicit `--force` flag for orphan reaping.
- `pkg/state/state.go` — optionally add a `FindOrphan(port int) (pid int, ok bool, err error)` helper to keep stop.go thin.

### Risk Factors

- **Shutdown ordering**: canceling the root ctx may cause goroutines to exit during the same window that `gateway.Close()` and HTTPServer.Shutdown run. Need to confirm no double-close or use-after-cancel panic in the cleanup goroutine, agent watcher, autoscaler, or health monitor.
- **Test environment**: integration tests that fork a real subprocess and verify exit-on-SIGTERM are slower and platform-dependent. Worth the cost given this is the regression guardrail.
- **Stop fallback false-positives**: `pgrep -f gridctl --daemon-child` could match a different gridctl install or a stale matching process. Pair with a port probe and require both signals before reporting an orphan.
- **Apply path parity**: applying the same context fix to `runApply` must not break the existing `runDaemonChild` flow, which also has its own `state.Save` and is shared with `gridctl apply <stack.yaml>` deployments.

### Regression Test Outline

Two complementary tests:

1. **Unit test on `runStop` orphan handling** (`cmd/gridctl/stop_test.go`):
   - Start a long-lived dummy subprocess on the configured port.
   - Do NOT save a state file (or save then delete to simulate the bug).
   - Assert `runStop` either succeeds via the fallback (if `--force` semantics are added) or returns an actionable error mentioning the discovered PID and port — not the current opaque "no stackless daemon is running".

2. **Integration test on signal-to-exit** (new test in `pkg/controller/` or `cmd/gridctl/`):
   - Use `exec.Command` to fork a real `./gridctl serve --daemon-child --port <random>` against a temp HOME.
   - Send SIGTERM to the child.
   - Assert the process exits within ~10 seconds (the existing 15s shutdown timeout, with margin).
   - Assert the state file is absent after exit and `runStop` then reports cleanly (not the stuck error).

## Recommendation

**Fix immediately (next release, not hotfix).** The bug is deterministic, the root cause is well-understood, the fix is small and structurally clean, and the alternative — leaving a broken `stop` command — erodes trust in the CLI quickly.

Phase the fix to manage the medium risk on shutdown plumbing:

1. **First**: cancel the root ctx on signal (`cmd/gridctl/apply.go` for both `runServeStackless` and `runApply`; `waitForShutdown` listens on `<-ctx.Done()`). Verify via integration test that the daemon exits within the 15s grace period under SIGTERM. This is the change that makes the daemon actually stoppable; everything else is layered on top.
2. **Second**: move `state.Delete` to a `defer` in the daemon-child entry points (`runStacklessDaemonChild`, `runDaemonChild`). Remove the call from `waitForShutdown`. Now state-file lifetime equals process lifetime.
3. **Third**: add the orphan-discovery fallback to `runStop` (port probe + `pgrep`, actionable error or `--force` flag). This is a defense-in-depth measure against future regressions in shutdown plumbing.

**Out of scope** (acknowledge but defer):

- Refactoring the shutdown sequence ordering in `waitForShutdown` beyond what's needed to honor ctx cancellation. If a specific blocking call is identified during implementation, fix it surgically.
- Adding `gridctl status --force-clean` UX improvements.
- Replacing the JSON state-file model with PID-file / UDS / systemd-style supervision.

## References

- Initial bug report (this conversation), evidence collected from a daemon started on commit `a8fea96`.
- `cmd/gridctl/agent.go:113` — existing reference implementation of the correct pattern: `signal.NotifyContext(cmd.Context(), syscall.SIGINT, syscall.SIGTERM)`.
- `pkg/state/state.go:195-238` — `KillDaemon` already implements the SIGTERM-then-SIGKILL grace flow; the stop fallback can reuse it once the orphan PID is identified.

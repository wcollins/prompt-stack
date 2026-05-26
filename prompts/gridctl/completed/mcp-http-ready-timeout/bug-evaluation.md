# Bug Investigation: MCP HTTP/SSE Ready-Wait Has Hard-Coded 30s Ceiling

**Date**: 2026-04-17
**Project**: gridctl
**Recommendation**: Fix with caveats
**Severity**: High
**Fix Complexity**: Small-Medium

## Summary

`Gateway.waitForHTTPServer` reads a package-level `DefaultReadyTimeout = 30s` constant with no override path. HTTP/SSE container MCP servers that warm up slower than 30s fail registration with `"timeout waiting for MCP server"`, and the container is left running unregistered — an orphan that gets silently adopted on the next apply. The `gridctl apply` path quietly logs a warning and exits 0, making the failure nearly invisible. The recommendation is to add a per-server `ready_timeout` config field, thread it into `waitForHTTPServer`, and clean up the container when the wait fails.

## The Bug

HTTP and SSE container-based MCP servers registered through `Gateway.RegisterMCPServer` are subject to a 30-second ceiling while the gateway polls the server's `/ping` endpoint waiting for readiness. The ceiling is a package-level `const` — not a parameter, not a struct field, not a CLI flag, not an env var. Images that need longer to warm up (model downloads, DB migrations, large sidecar layer pulls) fail registration even though the container is healthy and would have come up a few seconds later.

- **Expected**: users can either configure a larger timeout per server, or the default is large enough (and the system cleans up its own orphans on failure).
- **Actual**: hard 30s wall, no override, orphan container left behind, silent adoption on retry.
- **Discovery**: code inspection. Not yet reported by a user, but the failure mode is exactly on the growth path of the tool (custom AI/model-serving MCPs are the obvious next adoption wave).

## Root Cause

### Defect Location

- `pkg/mcp/types.go:118` — `DefaultReadyTimeout = 30 * time.Second` (package-level `const`, no override path).
- `pkg/mcp/gateway.go:684-705` — `waitForHTTPServer(ctx, client)` reads the constant directly.
- `pkg/mcp/gateway.go:549-551` (SSE) and `:559-562` (HTTP) — the two call sites, neither passing a per-server timeout.
- `pkg/config/types.go:128-145` — `config.MCPServer` struct has zero timeout-related fields.

### Code Path

```
gridctl apply stack.yaml
  → controller/StackController.Deploy
  → runtime/Orchestrator.Up
  → orchestrator.startMCPServer     (pkg/runtime/orchestrator.go:244)
    → runtime.Start  ← CONTAINER CREATED HERE (line 320)
  → controller/GatewayBuilder.Run
  → ServerRegistrar.RegisterAll     (pkg/controller/server_registrar.go:43)
    → gateway.RegisterMCPServer     (pkg/mcp/gateway.go:482)
      → waitForHTTPServer            ← 30s HARD CEILING (line 690)
      → (on timeout) return error with no cleanup
    → r.logger.Warn(…)               ← ERROR DOWNGRADED (line 53)
  → gridctl apply exits 0, container still running, gateway never saw it
```

The serve + Save & Load path goes through `reload.Handler.startMCPServer` → `registerServer` callback → `ServerRegistrar.RegisterOne` → `gateway.RegisterMCPServer`. Unlike `RegisterAll`, `RegisterOne` *returns* the error, so the reload path surfaces the failure to the caller (visible in the 400 response after PR #474). Container still leaks.

### Why It Happens

Three coupled decisions produce the full bug shape:

1. The ready-timeout is a `const`, not a field — no override.
2. `RegisterMCPServer` does not clean up the container it was about to register when `waitForHTTPServer` fails (no `defer`, no rollback).
3. `orchestrator.startMCPServer` is idempotent-on-exists (line 248: `if exists { return … }` skips `rt.Start`). Combined with the runtime's idempotent `Start` on a running container, this means the second apply silently re-binds to the now-warm orphan. The leaked state is never observed by the user.

### Similar Instances

- `pkg/registry/tester.go:11` — `defaultCriterionTimeout = 30 * time.Second`. Same architectural shape (hard-coded `const`, user-blocking, no override). Blocks skill acceptance-criterion runs.
- `pkg/mcp/types.go:104,112,115` — `DefaultPingTimeout` (5s), `DefaultRequestTimeout` (30s), `DefaultReadyPollInterval` (500ms). Internal, less user-visible, lower priority.
- Contrast: `CodeModeTimeout` in `GatewayConfig` and `WithWorkflowTimeout` in the registry executor — the pattern for configurable timeouts already exists in this codebase.

## Impact

### Severity Classification

**High**. The defect is (1) a silent failure — the apply path downgrades the error to a logged warning and exits 0, (2) a resource leak — the container keeps running with no cleanup, (3) a correctness hazard — silent adoption on retry can bind the gateway to a container with stale image/env, and (4) an operational-maturity gap — every mainstream peer (Kubernetes startupProbe, Docker Compose healthcheck + start_period, Nomad check_restart, Skaffold 600s statusCheckDeadlineSeconds, Testcontainers 60s configurable) ships configurable ready timeouts.

### User Reach

- **Today**: zero shipped examples trigger this. All container-based examples use `alpine:latest`, `ghcr.io/github/github-mcp-server`, or similar fast-start images. Most shipped examples also use stdio, not HTTP/SSE. No prior bug reports in the repo.
- **Tomorrow**: HTTP/SSE is the modern transport for custom MCP integrations. Model-serving (Ollama, HuggingFace TGI, llama.cpp), DB-backed MCPs, and any server with ML-grade init will routinely exceed 30s on cold start. Early adopters building these will hit this wall.

### Workflow Impact

Affects two user-facing flows equally:

1. `gridctl apply` — silent. Warning in logs, container leaked, exit 0. Worst visibility.
2. `gridctl serve` + Save & Load — loud. 400 response, `errors[]` populated (per PR #474). Container still leaked.

### Workarounds

None in-config. A user could shift warm-up into image build, but model downloads and migrations aren't suitable for bake time. `gridctl destroy` reaps orphans if the user knows to run it.

### Urgency Signals

No active user complaints. No commits or CHANGELOG entries related to this class of bug. The urgency is forward-looking: this is exactly the kind of sharp edge that produces a loud first-encounter report. Better to close it pre-emptively.

## Reproduction

### Minimum Reproduction Steps

**Apply path (silent failure)**:

```yaml
# stack.yaml
mcp_servers:
  - name: slow-mcp
    image: alpine:latest
    port: 3000
    transport: http
    command: ["sh", "-c", "apk add --no-cache python3 && sleep 45 && python3 -m http.server 3000"]
```

```bash
gridctl apply stack.yaml
# Expected: stderr shows warning from ServerRegistrar, exit 0.
# `docker ps` shows container running.
gridctl apply stack.yaml  # second run
# Expected: succeeds silently against the warm orphan.
```

**Serve + Save & Load path (visible failure)**:

```bash
gridctl serve --stack stack.yaml  # with a fast-start initial stack
# Then, via the web UI Save & Load, add slow-mcp from the YAML above.
# Expected: 400 response, errors[] contains "timeout waiting for MCP server".
# Container leaks identically.
```

### Affected Environments

- Any OS / Docker daemon / Podman configuration (bug is in gridctl logic, not runtime-specific).
- HTTP transport (`gateway.go:559-562`) and SSE transport (`gateway.go:549-551`).
- Image pull time does *not* factor in — the timeout starts after `rt.Start` succeeds.

### Non-Affected Environments

- Stdio transport (`gateway.go:528-540`) — attaches via Docker exec with no readiness polling.
- `local_process`, `ssh`, `openapi`, `external` (URL-only) transports.
- Any image whose first-run warm-up completes in <30s.

### Failure Mode

- Error text: `"timeout waiting for MCP server"` (with no duration hint, no config hint).
- Container state: running, healthy, unknown to the gateway. Persists until `gridctl destroy` or manual removal.
- Recoverability: second apply "just works" against the warm orphan — the leak is never surfaced to the user.

## Fix Assessment

### Fix Surface

- `pkg/mcp/types.go` — document that the 30s const is a fallback default.
- `pkg/mcp/gateway.go` — change `waitForHTTPServer` signature to accept a timeout, plumb it from `MCPServerConfig`, add cleanup on timeout.
- `pkg/mcp/gateway.go` — add `ReadyTimeout time.Duration` to `MCPServerConfig` (the gateway's internal config struct around line 28-51).
- `pkg/config/types.go` — add `ReadyTimeout` field to `MCPServer` (YAML tag `ready_timeout,omitempty`, parsed as `time.Duration` via string like `"60s"` or via existing duration helper).
- `pkg/controller/server_registrar.go` — propagate `ReadyTimeout` in `buildServerConfig` and `buildConfigFromMCPServer`.
- `pkg/mcp/gateway.go` — on timeout in the HTTP/SSE branches of `RegisterMCPServer`, call a cleanup hook that stops and removes the container for container-based transports.
- `pkg/mcp/gateway_test.go` — add unit tests that exercise the timeout and success paths with httptest.

Potentially also: update `docs/config-schema.md` and any YAML schema generation (if present) for the new field.

### Risk Factors

- **Adding the field** (change 1) is isolated and low-risk. Zero value defaults to `DefaultReadyTimeout`.
- **Container cleanup on timeout** (change 2) is the higher-risk piece:
  - A user whose server reliably starts in ~25s today gets lucky. If a network blip pushes one start to 31s, the cleanup will remove the container where today it survives. Mitigate by (a) logging loudly before cleanup, (b) only cleaning up on a true ready-timeout error (not a context cancellation or other error class), and (c) letting users raise `ready_timeout` to buy headroom.
  - Cleanup requires the gateway to know enough about the container to stop/remove it. Easiest layering: cleanup lives in the orchestrator/registrar (which already holds a runtime handle), invoked after `RegisterMCPServer` fails. Alternative: inject a `cleanupOnTimeout func()` into `MCPServerConfig`. Prefer the layering that doesn't make the gateway responsible for the runtime.
- **No API/YAML schema compatibility concern** — existing configs without `ready_timeout` work unchanged.

### Regression Test Outline

Unit test in `pkg/mcp/gateway_test.go` using `httptest.Server`:

```go
func TestWaitForHTTPServer_TimeoutFiresOnSlowServer(t *testing.T) {
    // Handler that sleeps past the ready timeout before responding
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        time.Sleep(200 * time.Millisecond)
        w.WriteHeader(http.StatusOK)
    }))
    defer srv.Close()

    client := mcp.NewClient("slow", srv.URL)
    gw := mcp.NewGateway(...)

    start := time.Now()
    err := gw.waitForHTTPServerWithTimeout(context.Background(), client, 50*time.Millisecond)
    if err == nil {
        t.Fatal("expected timeout error, got nil")
    }
    if time.Since(start) > 150*time.Millisecond {
        t.Fatalf("timeout fired too late: %v", time.Since(start))
    }
}

func TestWaitForHTTPServer_SucceedsWithLargerTimeout(t *testing.T) { … }

func TestRegisterMCPServer_CleansUpOnTimeout(t *testing.T) {
    // Mock runtime that records Stop/Remove calls; mock slow server.
    // Assert that on ready-timeout, the runtime's Stop+Remove is invoked exactly once.
}
```

Integration test (optional, in `tests/integration/gateway_lifecycle_test.go`): use the custom-ENTRYPOINT slow image from the repro and verify cleanup on ready-timeout.

## Recommendation

**Fix with caveats**. Ship in the next release, not as a hotfix.

Scope the PR to:

1. **Configurable `ready_timeout` per server** (the foundation). Add the field, thread it through, fall back to the existing 30s default. Low risk, high value.
2. **Orphan cleanup on ready-timeout** for container-based HTTP/SSE transports. Higher risk but needed to match industry expectations and close the silent-adoption footgun. Keep the cleanup narrow: only on a true ready-timeout from `waitForHTTPServer` in the container path, not on every registration error.
3. **Better error text**: include the observed duration and suggest `ready_timeout`. Nice-to-have, trivial to do alongside.

**Defer separately**:

- `defaultCriterionTimeout` in `pkg/registry/tester.go`. Same architectural shape, but different user flow, different config surface. Worth its own ticket.
- Promoting `ServerRegistrar.RegisterAll`'s `logger.Warn` to an error return on `gridctl apply`. That's a correctness improvement — apply-path silent failures are worse than the reporter realized — but it's a behavior change with its own blast radius. File as a follow-up.

**Don't**: bump the default without adding configurability. A larger default alone still leaves users stuck when their server needs 180s, and slow defaults hurt the fast case. Configurability is the fix; a modestly larger default (e.g., 60s) is a judgment call worth discussing in the PR.

## References

- `pkg/mcp/types.go:104-119` — timeout constants
- `pkg/mcp/gateway.go:482-602` — `RegisterMCPServer` (full flow, no cleanup on error)
- `pkg/mcp/gateway.go:684-705` — `waitForHTTPServer`
- `pkg/config/types.go:128-145` — `config.MCPServer` struct
- `pkg/controller/server_registrar.go:42-65` — `RegisterAll` (warning-only) / `RegisterOne` (returns error)
- `pkg/runtime/orchestrator.go:244-339` — `startMCPServer` (exists-check at line 248)
- `pkg/reload/reload.go:208-276, 377-452` — reload path
- `pkg/registry/tester.go:11` — sibling `defaultCriterionTimeout`, out of scope
- PR #474 — stackless container initialization fix (established the reload error-surfacing that makes the Save & Load path visible)
- Industry references: Kubernetes startupProbe docs; Docker Compose `healthcheck` with `start_period`; Skaffold `statusCheckDeadlineSeconds` (default 600s); Testcontainers `WithStartupTimeout` (default 60s)

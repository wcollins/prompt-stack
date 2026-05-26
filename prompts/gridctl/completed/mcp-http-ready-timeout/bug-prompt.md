# Bug Fix: MCP HTTP/SSE Ready-Wait Has Hard-Coded 30s Ceiling

## Context

gridctl is a Go CLI + web UI for declaratively managing MCP (Model Context Protocol) server stacks. It runs MCP servers as containers (Docker/Podman), external URLs, local processes, SSH-remote processes, or OpenAPI-backed shims, and fronts them with an MCP gateway that exposes a unified tool surface to AI agents. Users author stacks as YAML (`config.Stack`) and operate them via `gridctl apply` (one-shot) or `gridctl serve` with live reload via the web UI's Save & Load.

Relevant architecture:

- `pkg/mcp` — the gateway (MCP protocol client/server, transport clients, tool router, schema pinning, health monitor).
- `pkg/config` — YAML schema types.
- `pkg/runtime` + `pkg/runtime/docker` — container lifecycle abstraction (`runtime.Start`, `runtime.Exists`, etc.).
- `pkg/controller` — wires the pieces together: `StackController`, `GatewayBuilder`, `ServerRegistrar`.
- `pkg/reload` — live reload during `gridctl serve`.

## Investigation Context

- Root cause confirmed: `pkg/mcp/gateway.go:684-705` `waitForHTTPServer` reads `DefaultReadyTimeout = 30 * time.Second` (const at `pkg/mcp/types.go:118`) directly, with no parameter, no override, no config surface.
- Orphan-container leak on timeout confirmed: `RegisterMCPServer` has no cleanup on failure; `orchestrator.startMCPServer` at `pkg/runtime/orchestrator.go:248` silently adopts existing containers on retry.
- Apply-path visibility confirmed *worse* than reporter thought: `ServerRegistrar.RegisterAll` at `pkg/controller/server_registrar.go:52-54` downgrades the error to `logger.Warn` and returns nil — `gridctl apply` exits 0.
- Reproduces deterministically with any HTTP/SSE container image whose warm-up exceeds 30s.
- Reproduction does not depend on Docker daemon version, OS, image size, or env.
- Sibling `defaultCriterionTimeout` at `pkg/registry/tester.go:11` shares the shape but is **out of scope** for this fix.
- Full investigation: `prompts/gridctl/mcp-http-ready-timeout/bug-evaluation.md`.

## Bug Description

When a user registers an HTTP or SSE container-based MCP server whose cold-start takes longer than 30 seconds (model downloads, DB migrations, large sidecar layer pulls), gateway registration fails with `"timeout waiting for MCP server"` even though the container is healthy and would have come up a few seconds later. The container is left running but unregistered. On the apply path, the error is downgraded to a log warning and `gridctl apply` exits 0. On retry, the orchestrator re-binds to the now-warm orphan, masking the failure.

Expected behavior:
- Users can configure a longer ready-wait per server (and/or via a global default).
- When the ready-wait fails, the container is cleaned up so retry is clean.
- The error message hints at `ready_timeout` so users know how to recover.

Actual behavior:
- Hard 30s ceiling, no override.
- Container leaks on timeout.
- Error text is generic.
- Silent adoption on retry hides the broken state.

Affected transports: HTTP (`transport: http` or unset), SSE (`transport: sse`), both for container-based servers. Stdio, local_process, SSH, OpenAPI, and external transports are unaffected.

## Root Cause

Three coupled decisions in `pkg/mcp/gateway.go` produce the full bug shape:

1. `waitForHTTPServer(ctx, client)` hard-reads `DefaultReadyTimeout` at line 690 — no parameter to override.
2. `RegisterMCPServer` (lines 482-602) has no cleanup hook when `waitForHTTPServer` returns an error at lines 549-551 (SSE) or 559-562 (HTTP). The function returns the error; the container started earlier by the orchestrator is left to run.
3. `orchestrator.startMCPServer` at `pkg/runtime/orchestrator.go:248` short-circuits to the existing container if one is found, and the underlying Docker driver's `Start` is idempotent on a running container. A second apply re-binds to the orphan, and the now-warm `waitForHTTPServer` succeeds, masking the first apply's partial failure.

The correct logic: (a) accept a per-server timeout into `waitForHTTPServer`, (b) default it from a configurable field on `config.MCPServer` (or a gateway-global default), (c) on ready-timeout in a container-based transport, stop and remove the container before returning the error.

## Fix Requirements

### Required Changes

1. **Add `ReadyTimeout` field to `config.MCPServer`** (`pkg/config/types.go:128-145`).
   - YAML tag: `ready_timeout,omitempty`
   - Type: string (parsed as `time.Duration` via `time.ParseDuration`) — follow any existing precedent in the repo for duration-typed YAML fields. If no precedent, use `string` + parse at load time; fall back to `time.Duration` if the repo already has a custom YAML duration type.
   - Zero value must preserve current behavior (fall back to `DefaultReadyTimeout`).

2. **Add `ReadyTimeout time.Duration` to `mcp.MCPServerConfig`** (`pkg/mcp/gateway.go` around line 28-51). Zero value means "use `DefaultReadyTimeout`".

3. **Change `waitForHTTPServer` to accept a timeout parameter** (`pkg/mcp/gateway.go:684`). Signature becomes:
   ```go
   func (g *Gateway) waitForHTTPServer(ctx context.Context, client *Client, timeout time.Duration) error
   ```
   If `timeout <= 0`, fall back to `DefaultReadyTimeout`. Replace the `time.After(DefaultReadyTimeout)` at line 690 with `time.After(timeout)`.

4. **Update the two call sites** at `pkg/mcp/gateway.go:549` (SSE) and `:560` (HTTP) to pass `cfg.ReadyTimeout`.

5. **Propagate `ReadyTimeout` through `ServerRegistrar`** (`pkg/controller/server_registrar.go`):
   - In `buildServerConfig` (lines 70-141), set `ReadyTimeout: serverCfg.ReadyTimeout` on the container HTTP/SSE branch (lines 132-140).
   - In `buildConfigFromMCPServer` (lines 147-215), set `ReadyTimeout: server.ReadyTimeout` on the container HTTP/SSE branch (lines 206-214).

6. **Clean up the container on ready-timeout**. Pick the layering that keeps the gateway free of runtime details:
   - **Preferred approach**: add a `CleanupOnReadyFailure func(ctx context.Context) error` field to `mcp.MCPServerConfig`. For container-based HTTP/SSE transports, `ServerRegistrar.buildServerConfig` / `buildConfigFromMCPServer` populate it with a closure that captures the runtime and workload ID. On ready-timeout in `RegisterMCPServer`, the gateway invokes this callback before returning the error.
   - **Acceptable alternative**: the registrar receives the error from `RegisterMCPServer`, and if it recognizes a ready-timeout (sentinel error), it calls `runtime.Down`/`Stop`+`Remove` itself. Requires a typed sentinel error (`ErrReadyTimeout`) exported from `pkg/mcp`.

   Either way: cleanup must be narrow — only on a true ready-timeout from `waitForHTTPServer` in the container HTTP/SSE branch. Do not clean up on context cancellation, Initialize errors, RefreshTools errors, or any other failure.

7. **Log loudly before cleanup**. Before stopping/removing the container, emit a `logger.Warn` including the server name, configured timeout, and the fact that the container is being removed. This is a behavior change — users need to see it.

8. **Improve the error message**. Change `"timeout waiting for MCP server"` at `pkg/mcp/gateway.go:697` to include the observed wait duration and a hint:
   ```
   timeout waiting for MCP server <name> after <elapsed> (ready_timeout=<timeout>); set ready_timeout on the server config to wait longer
   ```
   Or similar — match existing error-text idioms in the repo.

9. **Regression tests** in `pkg/mcp/gateway_test.go` using `httptest.Server`:
   - `TestWaitForHTTPServer_RespectsCustomTimeout` — slow handler, small timeout, asserts timeout fires within expected window.
   - `TestWaitForHTTPServer_FallsBackToDefault` — zero timeout → uses `DefaultReadyTimeout`.
   - `TestWaitForHTTPServer_SucceedsWithinTimeout` — handler responds before timeout, asserts success.
   - `TestRegisterMCPServer_InvokesCleanupOnTimeout` — mock runtime; asserts cleanup callback (or Stop/Remove) is invoked exactly once on ready-timeout and NOT invoked on other errors.

### Constraints

- **Zero config change for existing users**: stacks without `ready_timeout` must behave exactly as before (30s default).
- **Cleanup only on ready-timeout, only for container-based HTTP/SSE**. Do not remove containers on `Initialize` failure, `RefreshTools` failure, schema-pinning drift, or any other error class. Other failure paths have their own semantics and should not be changed in this PR.
- **Do not change `ServerRegistrar.RegisterAll`'s warning-vs-error behavior**. Whether apply-path failures should be returned rather than warned is a separate discussion (noted as a follow-up in the investigation).
- **Preserve stdio-transport behavior exactly**. Do not add timeouts, cleanup, or new config fields to the stdio path — it does not poll.

### Out of Scope

- `defaultCriterionTimeout` in `pkg/registry/tester.go` — same architectural shape, different workflow, tracked separately.
- Other `Default*Timeout` / `Default*Interval` constants in `pkg/mcp/types.go` (`DefaultPingTimeout`, `DefaultRequestTimeout`, `DefaultHealthCheckInterval`). Internal, lower priority.
- Promoting `ServerRegistrar.RegisterAll`'s `logger.Warn` to a returned error on `gridctl apply`. Behavior change worth doing but not in this PR.
- Bumping the default ready-timeout itself. Keep `DefaultReadyTimeout = 30 * time.Second`. If the team wants a larger default (e.g., 60s), discuss in the PR and decide independently of the configurability work.
- Changes to the wizard / web UI form surface for the new field. Adding the YAML field is enough; UI follow-up can be filed separately.

## Implementation Guidance

### Key Files to Read

- `pkg/mcp/types.go` — timeout constants (line 104-119) and interfaces. Understand the surrounding consts before adding a new timeout path.
- `pkg/mcp/gateway.go` — full `RegisterMCPServer` (line 482-602) and `waitForHTTPServer` (line 684-705). Note that `RegisterMCPServer` is called by `RestartMCPServer` too (line 622-670) — verify the new timeout threads through restart as well.
- `pkg/config/types.go:128-145` — the `MCPServer` struct. Scan neighboring structs for duration-typed fields; follow existing idiom.
- `pkg/controller/server_registrar.go` — both `buildServerConfig` (line 70-141) and `buildConfigFromMCPServer` (line 147-215) must be updated.
- `pkg/runtime/orchestrator.go:244-339` — understand what `startMCPServer` returns so the cleanup callback can reference the right workload ID.
- `pkg/runtime/docker/driver.go:64-106` — understand `Start`/`Stop`/`Remove` semantics so cleanup is idempotent and correct.
- `pkg/reload/reload.go:377-452` — `startMCPServer` → `registerServer` callback path. Verify the new `ReadyTimeout` is still populated on reload-driven registrations (the `registerServer` func is set at `pkg/controller/gateway_builder.go:463-465` and routes through `RegisterOne`, which uses `buildConfigFromMCPServer`, so the propagation in change (5) should cover it — confirm).

### Files to Modify

- `pkg/config/types.go` — add `ReadyTimeout` field to `MCPServer`.
- `pkg/mcp/gateway.go` — add `ReadyTimeout` to `MCPServerConfig`; add optional `CleanupOnReadyFailure` callback (or alternative); change `waitForHTTPServer` signature; add cleanup invocation + improved error text in `RegisterMCPServer`.
- `pkg/controller/server_registrar.go` — propagate `ReadyTimeout` and populate the cleanup callback in both builder functions.
- `pkg/mcp/gateway_test.go` — add regression tests.
- `docs/config-schema.md` (or wherever the config schema is documented) — add `ready_timeout` to the reference.

### Reusable Components

- `pkg/logging` — use the existing logger pattern, not `log.Printf`.
- If the repo already has a duration-typed YAML field, reuse that unmarshaling helper. Otherwise, a `string` field parsed with `time.ParseDuration` at config-load time is fine.
- Any existing helper for building per-server MCP config — don't duplicate the construction logic.

### Conventions to Follow

- Error wrapping with `%w` (already idiomatic in this file).
- `slog`-based logging with structured fields.
- Test helpers under `pkg/mcp/mock_helpers_test.go` and test patterns in `pkg/mcp/gateway_test.go`.
- Integration-test patterns in `tests/integration/gateway_lifecycle_test.go` if an integration test is added.
- Sign commits with `-S`. No Co-authored-by trailers. No mention of Claude in commits or PR descriptions.

## Regression Test

### Test Outline

Add to `pkg/mcp/gateway_test.go`:

```go
func TestWaitForHTTPServer_RespectsCustomTimeout(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        time.Sleep(500 * time.Millisecond)
        w.WriteHeader(http.StatusOK)
    }))
    defer srv.Close()

    client := mcp.NewClient("slow", srv.URL)
    gw := mcp.NewGateway(/* minimal config for tests */)

    start := time.Now()
    err := gw.waitForHTTPServer(context.Background(), client, 100*time.Millisecond)
    elapsed := time.Since(start)

    if err == nil {
        t.Fatal("expected timeout error, got nil")
    }
    if elapsed > 300*time.Millisecond {
        t.Fatalf("timeout fired too late: %v", elapsed)
    }
}

func TestWaitForHTTPServer_FallsBackToDefaultWhenZero(t *testing.T) {
    // Zero timeout → uses DefaultReadyTimeout. With a fast mock, success should
    // come in well under that.
}

func TestWaitForHTTPServer_SucceedsBeforeTimeout(t *testing.T) {
    // Handler responds immediately; confirm no error and no unnecessary waiting.
}

func TestRegisterMCPServer_CleansUpContainerOnReadyTimeout(t *testing.T) {
    // Use a mock runtime that records Stop/Remove calls. Use a slow httptest
    // server. ReadyTimeout = 50ms. Assert:
    //   - RegisterMCPServer returns an error whose text includes "timeout"
    //   - The cleanup callback / runtime.Stop+Remove is invoked exactly once
    //   - The gateway's router does NOT contain the client
}

func TestRegisterMCPServer_DoesNotCleanUpOnInitializeError(t *testing.T) {
    // Fast ready response but Initialize fails. Assert cleanup is NOT invoked.
}
```

### Existing Test Patterns

- `pkg/mcp/gateway_test.go` uses `httptest.Server` heavily — follow its idioms for setting up mock MCP servers.
- `pkg/mcp/mock_helpers_test.go` provides shared helpers; check before inventing new ones.
- Match table-driven tests where the existing file uses them.

## Potential Pitfalls

- **`RestartMCPServer`** (`pkg/mcp/gateway.go:622-670`) re-invokes `RegisterMCPServer` with the stored `cfg`. Ensure the stored `serverMeta[name]` includes `ReadyTimeout` so restart uses the same value the user configured.
- **`SetServerMeta`** (`pkg/mcp/gateway.go:607-611`) is used by tests and internal paths. If test helpers set meta without going through `RegisterMCPServer`, they may not need the new field — but check before assuming.
- **Reload path**: `reload.Handler.startMCPServer` → `registerServer` callback → `RegisterOne` → `buildConfigFromMCPServer`. The propagation in change (5) should cover reload-driven registrations, but verify by reading `pkg/reload/reload.go:377-452` end-to-end.
- **Context vs timeout**: `waitForHTTPServer` respects both `ctx.Done()` and the `time.After(timeout)` channel. Make sure the caller's context isn't already timed out by an outer boundary (check `pkg/controller/gateway_builder.go` for any `context.WithTimeout` upstream that would cap the effective wait below the configured `ReadyTimeout`).
- **Cleanup idempotency**: if the runtime returns an error on Stop/Remove (e.g., container already gone), don't mask the original ready-timeout error. Wrap cleanup errors in a `logger.Warn` and still return the original timeout.
- **YAML duration parsing**: if the repo doesn't already have a `Duration` yaml type, a string field parsed at load time is the simplest route. Don't add a dependency on a new YAML helper library for this one field.
- **Default for multi-server stacks**: the config-level override is per-server. Consider whether a stack-level default (`stack.ReadyTimeout`) is worth adding now — recommendation: **no**, keep this PR tight. File as follow-up if demand appears.

## Acceptance Criteria

1. `config.MCPServer.ReadyTimeout` field exists; zero value preserves current behavior.
2. `mcp.MCPServerConfig.ReadyTimeout` field exists; zero value means "use `DefaultReadyTimeout`".
3. `waitForHTTPServer` accepts a timeout parameter and honors it (verified by unit test).
4. Both HTTP and SSE branches in `RegisterMCPServer` pass the per-server timeout.
5. On ready-timeout for a container-based HTTP/SSE transport, the container is stopped and removed before `RegisterMCPServer` returns (verified by mock-runtime unit test).
6. Cleanup is NOT invoked on non-timeout errors (verified by unit test).
7. The ready-timeout error message includes the observed duration and the configured timeout.
8. `gridctl apply` with a stack that sets `ready_timeout: 60s` on a slow server succeeds where the default-30s version would have failed (manual verification with a slow-start test image).
9. `gridctl apply` twice against a truly-slow server that exceeds the configured timeout shows cleanup on the first run and a clean start on the second run (manual verification, no orphans in `docker ps`).
10. All existing tests pass unchanged. New regression tests are added and pass.
11. `golangci-lint` and `go test -race ./...` are green.
12. `docs/config-schema.md` (or equivalent) documents the new field.
13. No changes outside the scope listed in "Required Changes".

## References

- Full investigation: `prompts/gridctl/mcp-http-ready-timeout/bug-evaluation.md`
- PR #474 (merged): `fix: register stdio container MCP servers via stackless initialize` — context for why the reload path surfaces errors.
- Industry standards for configurable ready-waits:
  - Kubernetes startupProbe (`timeoutSeconds`, `failureThreshold`)
  - Docker Compose `healthcheck` with `start_period`
  - Skaffold `statusCheckDeadlineSeconds` (default 600s)
  - Testcontainers `WithStartupTimeout` (default 60s, configurable)
- Existing pattern for configurable gateway timeout in this codebase: `GatewayConfig.CodeModeTimeout` and `registry.WithWorkflowTimeout` option.

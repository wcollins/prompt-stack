# Bug Investigation: Stackless Initialize Fails to Register Stdio Container MCP Servers

**Date**: 2026-04-17
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

In `gridctl serve` stackless mode, loading a stack via the wizard's Save & Load (`POST /api/stack/initialize`) silently fails to register any container-based stdio MCP server. The container is created but never attached, the gateway holds zero servers, and the HTTP response returns 200 OK because per-server errors are swallowed. Root cause is a known gap in the reload registration path: `buildConfigFromMCPServer` deliberately omits `ContainerID` for stdio transport. Fix is small, contained, and high-confidence. Ship in the next release.

## The Bug

In stackless `gridctl serve`, clicking **Save & Load** in the wizard Review step persists the stack YAML under `~/.gridctl/stacks/` and calls `POST /api/stack/initialize`. The handler returns 200 OK and the spec tab renders, but:

- Any container-based MCP server using `transport: stdio` (for example `github` backed by `ghcr.io/github/github-mcp-server:latest`) is created in Docker but its container stays in state `Created` — the stdio client never attaches.
- The gateway canvas shows `MCP Servers: 0, Clients: 1, Total Tools: 0`.
- Daemon log shows `reload complete added=0 removed=0 modified=0 errors=N` and — with the per-item error logging recently added in `pkg/reload/reload.go` — each failure is emitted as `reload: per-item error`.
- No error is surfaced to the UI. The wizard toast reads "Stack loaded" and the canvas simply stays empty.

**Expected** (per `proto/walkthrough.md §3.10`): canvas populates with the gateway plus every loaded MCP server node; gateway card shows the real registered-server count.

**Discovery**: user-observed during walkthrough dogfood session; confirmed by examining daemon logs and `docker ps -a` state. Same stack applied via `gridctl apply <stack.yaml>` works correctly — the defect is specific to the `serve → /api/stack/initialize` flow.

## Root Cause

### Defect Location

Three layered problems. The primary is:

- `pkg/controller/server_registrar.go:192-201` — `buildConfigFromMCPServer` for stdio transport returns an `mcp.MCPServerConfig` with `ContainerID` unset. The function's own comment acknowledges this: "Stdio containers need container ID which requires full reload / Return a config that will error on registration with a clear message." The reload path was never wired up to pass the container ID that `rt.Start` already produces.

Secondary defects (independent bugs along the same path):

- `pkg/reload/reload.go:143-150` and `pkg/reload/reload.go:245` — `applyMCPServerChanges` collects per-server failures into `result.Errors` but returns `nil`. `Reload` only marks `result.Success=false` on a non-nil Go error, so a populated `Errors` slice does not affect `Success`. `internal/api/stack.go:148-157` therefore returns HTTP 200 with `{success:true}` even when every server registration failed.
- `pkg/controller/gateway_builder.go:458` — the `setupHotReload` closure captures `b.stackPath` by value. In stackless mode `b.stackPath = ""` at wire-up time (`pkg/controller/controller.go:177`), so the registrar always receives an empty path. Does not affect stdio (the stdio config does not use `stackPath`), but silently breaks `WorkDir` for any LocalProcess MCP server added via Save & Load.

### Code Path

```
POST /api/stack/initialize
  internal/api/stack.go:115 handleStackInitialize
    internal/api/stack.go:149 reloadHandler.Initialize(ctx, stackPath)
      pkg/reload/reload.go:85  Handler.Initialize
        h.stackPath = stackPath; h.currentCfg = nil
      pkg/reload/reload.go:94  Handler.Reload
        pkg/reload/reload.go:124 ComputeDiff (every server is "Added" on initial load)
        pkg/reload/reload.go:146 applyMCPServerChanges
          pkg/reload/reload.go:234 for each added server:
            pkg/reload/reload.go:237 startMCPServer(ctx, server, newCfg)
              pkg/reload/reload.go:371 rt.Start(ctx, cfg)      <- container created AND started;
                                                                  status.ID holds the real container ID
              pkg/reload/reload.go:383 h.registerServer(ctx, server, actualHostPort)
                pkg/controller/gateway_builder.go:458 closure -> registrar.RegisterOne(ctx, server, hostPort, "")
                  pkg/controller/server_registrar.go:60 RegisterOne
                    pkg/controller/server_registrar.go:61 buildConfigFromMCPServer(server, hostPort, "")
                      pkg/controller/server_registrar.go:192 stdio branch -> config without ContainerID
                    pkg/controller/server_registrar.go:62 gateway.RegisterMCPServer(cfg)
                      pkg/mcp/gateway.go:532 NewStdioClient(name, "", dockerCli)
                      pkg/mcp/gateway.go:537 stdioClient.Connect(ctx)
                        pkg/mcp/stdio.go:63 cli.ContainerAttach(ctx, "", ...) -> error
                      error returns to caller
            error appended to result.Errors, loop continues
        applyMCPServerChanges returns nil
      Reload returns (result{Success:true, Errors:[...]}, nil)
    handleStackInitialize sees result.Success==true, returns HTTP 200
```

### Why It Happens

The reload single-server registration path and the apply bulk registration path were implemented with two separate config-builder functions (`buildConfigFromMCPServer` and `buildServerConfig`). The bulk path sources its container IDs from the orchestrator's `UpResult` — `pkg/controller/server_registrar.go:124` sets `ContainerID: string(server.WorkloadID)`. The single-server path has no comparable input wired through, so the stdio branch takes a deliberate shortcut of omitting the field. Meanwhile `startMCPServer` *does* have the ID (`status.ID` from `rt.Start`) — it just never flows from reload back into the registrar.

Because the gateway registration failure gets swallowed at two layers (the callback returns error, but `applyMCPServerChanges` absorbs it into `Errors` and returns `nil`; `Reload` then keeps `Success=true`), the HTTP handler has no signal that anything went wrong.

### Similar Instances

- **LocalProcess registration via Save & Load** is a latent sibling bug from the same captured-by-value `b.stackPath` at `gateway_builder.go:458`. `WorkDir` would become `"."` instead of the stack directory. Not in the reported reproduction (github is stdio, not LocalProcess) but should be fixed in the same change.
- **Error swallowing** at `reload.go:245` affects the resource reload path too (`applyResourceChanges` has the same pattern at line 291) — both should be fixed together.

## Impact

### Severity Classification

**High — core-path regression, silent failure**. Not a crash or data loss: the persisted YAML is valid, and `gridctl apply` still works. But the stackless serve + Save & Load flow is the headline onboarding path introduced in PRs #458 / #459 / #460, and it ships broken for its most common workload (container-based stdio servers from the MCP ecosystem — github, filesystem, slack, etc.).

### User Reach

Every user of stackless `gridctl serve` who uses the wizard to load a stack containing a container-based stdio MCP server. That is the expected primary onboarding path per `proto/walkthrough.md`. HTTP/SSE container servers and external/local-process/SSH/OpenAPI servers are unaffected — the same code path at `server_registrar.go:204-211` correctly constructs an `Endpoint` from the `hostPort` argument.

### Workflow Impact

Blocks the wizard Save & Load story end-to-end. Canvas stays empty, so users have no way to verify their stack is live and no error to act on. The UI even shows a success toast.

### Workarounds

`gridctl apply <stack.yaml>` works correctly because it uses the orchestrator's `UpResult` and `RegisterAll` (which sources `WorkloadID` from the runtime). Users can drop to the CLI after saving via the wizard. Adequate but defeats the point of the wizard.

### Urgency Signals

- Feature gap directly contradicts `proto/walkthrough.md §3.10` expected behavior.
- Silent failure shape is especially bad for onboarding — a new user sees nothing wrong until they notice the empty canvas.
- Per-item error logging was added to `reload.go` recently (see commit history on `pkg/reload/reload.go`), which suggests the team is already aware of the silent-failure axis. Response surfacing is the natural next step.

## Reproduction

### Minimum Reproduction Steps

1. `./gridctl stop`
2. `./gridctl serve` (stackless)
3. In the web UI, run `proto/walkthrough.md` Phase 3 up through 3.7 configuring a single `github` MCP server (`transport: stdio`, image `ghcr.io/github/github-mcp-server:latest`).
4. On the Review step, click **Save & Load**.
5. Observe: spec tab renders, canvas does not populate any MCP server node, gateway card shows `MCP Servers: 0`.
6. `docker ps -a` — `gridctl-daily-github` is present in state `Created`.
7. `~/.gridctl/logs/gridctl.log` contains `reload complete ... errors=N` and `reload: per-item error error=...` lines naming the registration failure.

### Affected Environments

- Both Docker and Podman (the gap is transport-specific, not runtime-specific).
- Any OS where the daemon runs (macOS and Linux observed).
- Any container-based MCP server with `transport: stdio`.

### Non-Affected Environments

- `gridctl apply <stack.yaml>` from the CLI (uses `RegisterAll`, not reload).
- Container MCP servers with `transport: http` or `transport: sse` under the same Save & Load flow — `buildConfigFromMCPServer` builds a correct `Endpoint` using the `hostPort` argument.
- External / LocalProcess / SSH / OpenAPI servers — their config-builder branches do not require a container ID.

### Failure Mode

- Container is created and started by `rt.Start`.
- `NewStdioClient` receives an empty `containerID`.
- `stdioClient.Connect` calls `ContainerAttach(ctx, "", ...)` which fails.
- Gateway `RegisterMCPServer` returns an error.
- Error is appended to `result.Errors` and lost. `result.Success` stays true.
- Container remains orphaned — unattached, blocked on stdin, shown as `Created` by `docker ps -a` until the user cleans up with `gridctl destroy`.

## Fix Assessment

### Fix Surface

- `pkg/controller/server_registrar.go` — extend `buildConfigFromMCPServer` (or add a new helper/method) to accept a container ID, populate it on the stdio branch. Update `RegisterOne` signature or add a sibling `RegisterOneWithContainer`.
- `pkg/controller/gateway_builder.go` — update the `setupHotReload` closure at line 458 so the registrar call receives the container ID emitted by `startMCPServer` *and* the real (post-Initialize) stack path. Simplest: change the `registerServer` callback signature from `(ctx, server, hostPort) error` to `(ctx, server, hostPort, containerID) error` and read `reloadHandler.StackPath()` (new getter) for the path.
- `pkg/reload/reload.go` —
  - Extend the callback signature to pass `status.ID` (container ID) from `rt.Start` through to the registrar.
  - In `Reload`, set `result.Success = false` when `len(result.Errors) > 0` after `applyMCPServerChanges` / `applyResourceChanges`.
  - Expose `StackPath()` getter if needed by `gateway_builder`.
- `internal/api/stack.go` — optionally include `result.Errors` in the 200 response body so the wizard can surface them; status code change is optional (200 with `success:false` plus `errors[]` is enough for UI toast differentiation).

### Risk Factors

- `RegisterOne` is only called from the reload path (`setupHotReload`). Signature change is isolated.
- The `registerServer` callback is set once via `SetRegisterServerFunc` (see `pkg/reload/reload.go:71`) and called only from `startMCPServer`. Internal API.
- Flipping `result.Success` to false when Errors is non-empty changes the HTTP status surface — today the UI over-trusts 200. Wizard code that calls `/api/stack/initialize` must tolerate a 400 (or 200 + `success:false`). Check the wizard client for response handling assumptions.
- Existing test `TestServerRegistrar_BuildConfigFromMCPServer_Stdio` (`pkg/controller/server_registrar_test.go:382-400`) asserts the current buggy behavior (empty `ContainerID`). It must be updated, not just added to.

### Regression Test Outline

1. `pkg/reload/reload_test.go` — new test that invokes `Initialize` with a stack containing a single stdio container MCP server, using a fake runtime that returns a known container ID from `rt.Start`. Assert that the `registerServer` callback receives that ID.
2. `pkg/controller/server_registrar_test.go` — update `TestServerRegistrar_BuildConfigFromMCPServer_Stdio` to pass a container ID and assert it flows through; keep a separate assertion that the empty-ID case produces an explicit error (fail-fast rather than silent success).
3. `pkg/reload/reload_test.go` — new test: when the `registerServer` callback returns an error, `Reload` returns `result.Success == false` and non-empty `result.Errors`.
4. `internal/api/stack_test.go` — new `TestHandleStackInitialize_PartialFailure` that injects a reloadHandler returning `{Success:false, Errors:[...]}` and asserts the response body exposes errors (and status code per whatever the fix chooses).

## Recommendation

**Fix immediately in the next release.** The root cause is localized and acknowledged in-code, the fix is three small coordinated edits, and the test coverage gap is easy to close with the regression tests outlined above. Because the failure shape is *silent green* (HTTP 200 + empty canvas + confident toast) the bug disproportionately hurts new-user onboarding — exactly the path Save & Load was shipped to own.

Do the fix in one PR, bundling:
1. Threading the container ID through the reload registration path (primary defect).
2. Flipping `result.Success` to false when per-item errors accumulate (secondary defect).
3. Fixing the captured empty `b.stackPath` in the `setupHotReload` closure (latent LocalProcess bug).

Regression tests (4 cases above) are cheap and lock in the behavior.

## References

- `proto/walkthrough.md` §3 (Save & Load expected behavior)
- Introducing PRs: #458 (stackless serve), #459 (initialize endpoint), #460 (Save & Load wizard action)
- Most recent related fix: #472 (wizard YAML / Save & Load UX — scope explicitly out)
- Code comment at `pkg/controller/server_registrar.go:193-194` acknowledges the gap

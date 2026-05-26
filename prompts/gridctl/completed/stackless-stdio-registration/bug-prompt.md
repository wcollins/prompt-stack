# Bug Fix: Stackless Initialize Fails to Register Stdio Container MCP Servers

## Context

**Project**: `gridctl` — a Go CLI + daemon that runs a gateway ("gridctl serve") in front of MCP (Model Context Protocol) servers. Stacks are defined in YAML and can be brought up either via `gridctl apply <stack.yaml>` (one-shot orchestration) or via `gridctl serve` in stackless mode, where the daemon starts empty and the user loads a stack later by calling `POST /api/stack/initialize` from the web UI wizard's Save & Load button.

**Relevant architecture**:

- `pkg/controller` — stack controller, gateway builder, and `ServerRegistrar` (wraps `mcp.Gateway` registration; has two methods: `RegisterAll` for bulk registration from an `UpResult`, and `RegisterOne` for reload's single-server path).
- `pkg/reload` — `Handler` owns the hot-reload state machine. `Initialize` cold-loads a stack, `Reload` diffs + applies changes. It calls back into a `registerServer` function set by `gateway_builder`.
- `pkg/runtime/docker` — container lifecycle. `rt.Start(ctx, cfg)` creates and starts a container, returning `*runtime.WorkloadStatus` whose `.ID` is the Docker container ID.
- `pkg/mcp` — gateway and stdio/HTTP MCP clients. `StdioClient` attaches to a container via the Docker API using a container ID.
- `internal/api` — HTTP server. `handleStackInitialize` delegates to `reloadHandler.Initialize` and returns JSON.

**Git workflow**: gridctl uses the **fork workflow** (`/branch-fork`, `/pr-fork`). Do not use trunk commands.

**Build & test**: use `make build` and `./gridctl` — do not use the brew-installed binary. Tests are `go test -race ./...`. Lint is `golangci-lint run`.

## Investigation Context

Full investigation is at `<prompt-stack>/prompts/gridctl/stackless-stdio-registration/bug-evaluation.md`. Key findings that shape this prompt:

- **Primary defect confirmed**: `pkg/controller/server_registrar.go:192-201` deliberately omits `ContainerID` in the stdio branch of `buildConfigFromMCPServer`. The comment admits the gap. The fix is to thread the container ID (already in hand at `pkg/reload/reload.go:371` as `status.ID` from `rt.Start`) through to the registrar.
- **Secondary defect**: `pkg/reload/reload.go:245` — `applyMCPServerChanges` returns `nil` even when `result.Errors` has entries. `Reload` only sets `Success=false` on a non-nil Go error (`reload.go:146`). Must flip `Success=false` when `len(result.Errors) > 0`.
- **Latent defect (same PR)**: `pkg/controller/gateway_builder.go:458` captures `b.stackPath` by value. In stackless mode it is `""` at wire-up (`pkg/controller/controller.go:177`). Unused for stdio, but breaks `WorkDir` for LocalProcess MCP servers loaded via Save & Load. Fix by reading the live stackPath from `reloadHandler` at call time.
- **Scope**: do **not** revisit wizard UX — already fixed in PR #472. Focus on the stackless initialize → server-registration path.
- **Repro is deterministic**. See "Reproduction" section below.
- **Workaround**: `gridctl apply <stack.yaml>` uses `RegisterAll` and works correctly — that is why only the serve path is broken.

## Bug Description

In `gridctl serve` stackless mode, using the wizard's Save & Load to load a stack with a container-based MCP server on `transport: stdio` (e.g. `github` with image `ghcr.io/github/github-mcp-server:latest`):

- `~/.gridctl/stacks/<name>.yaml` is written correctly.
- `POST /api/stack/initialize` returns HTTP 200 with `{success:true, ...}` and the spec tab renders.
- The container (`gridctl-<stack>-<server>`) appears in `docker ps -a` but stays in state `Created` — the stdio client never attaches.
- Gateway canvas shows `MCP Servers: 0, Clients: 1, Total Tools: 0`.
- Daemon log (`~/.gridctl/logs/gridctl.log`) shows `reload complete added=0 removed=0 modified=0 errors=N` plus `reload: per-item error` lines naming the registration failure.
- The wizard toast reads "Stack loaded — <name> is now active" because the 200 response tells it everything is fine.

**Expected** (per `proto/walkthrough.md` §3.10): canvas populates with gateway plus every loaded MCP server node.

**Who is affected**: every user of stackless `gridctl serve` who loads a stack containing a stdio container MCP server through the wizard. That is the primary onboarding path introduced in PRs #458, #459, #460. The `apply` CLI path is unaffected. HTTP/SSE container MCP servers under the same Save & Load flow work correctly (their config-builder branch uses the `hostPort` arg to compose an endpoint).

## Root Cause

**Where the defect lives**

`pkg/controller/server_registrar.go:192-201`:

```go
if transport == mcp.TransportStdio {
    // Stdio containers need container ID which requires full reload
    // Return a config that will error on registration with a clear message
    return mcp.MCPServerConfig{
        Name:         server.Name,
        Transport:    transport,
        Tools:        server.Tools,
        OutputFormat: server.OutputFormat,
        PinSchemas:   server.PinSchemas,
    }
}
```

`buildConfigFromMCPServer` is called from `RegisterOne` (the reload single-server path). For stdio containers it omits `ContainerID`, so downstream `pkg/mcp/gateway.go:532` creates `NewStdioClient(name, "", dockerCli)` and `stdioClient.Connect` attempts `ContainerAttach(ctx, "", ...)`, which errors.

The apply path uses the other builder at `server_registrar.go:120-129` — `buildServerConfig` — which *does* set `ContainerID: string(server.WorkloadID)` because it is called with the orchestrator's `UpResult.MCPServers`. That is why apply works.

**The container ID is already available in the reload path** — `pkg/reload/reload.go:371`:

```go
status, err := rt.Start(ctx, cfg)   // status.ID is the Docker container ID
```

It is simply never threaded from here through the `h.registerServer(ctx, server, actualHostPort)` callback on line 383 back into the registrar. The callback signature needs to carry the container ID.

**Why HTTP returns 200 despite the failure**: `applyMCPServerChanges` at `pkg/reload/reload.go:237-239` appends the error to `result.Errors` and continues. At line 245 it returns `nil`. `Reload` at line 146-150 only flips `result.Success=false` when the Go error is non-nil. So `Success` stays `true` and `handleStackInitialize` at `internal/api/stack.go:148-157` returns 200.

**The latent stackPath bug**: `pkg/controller/gateway_builder.go:458`:

```go
reloadHandler.SetRegisterServerFunc(func(ctx context.Context, server config.MCPServer, hostPort int) error {
    return registrar.RegisterOne(ctx, server, hostPort, b.stackPath)
})
```

`b.stackPath` is an empty string at closure-creation time in stackless mode (see `pkg/controller/controller.go:177`). After `Initialize` runs, the real path lives at `reloadHandler.stackPath`, but the closure captures the builder's field by value. Not the cause of the github reproduction (stdio ignores stackPath), but breaks LocalProcess `WorkDir` in the same flow.

## Fix Requirements

### Required Changes

1. **Thread the container ID from `startMCPServer` through to the registrar.** Extend the `registerServer` callback signature in `pkg/reload/reload.go` to take a container ID (string). In `startMCPServer`, pass `status.ID` (stringified). For non-container servers (`External`, `LocalProcess`, `SSH`, `OpenAPI`) pass the empty string.

2. **Populate `ContainerID` in the stdio branch of `buildConfigFromMCPServer`.** Extend the signature to accept a container ID; when transport is stdio, set `ContainerID: containerID` in the returned config. Keep the existing behavior for non-stdio branches (stackPath for LocalProcess WorkDir, Endpoint for HTTP/SSE).

3. **Update `RegisterOne` in `pkg/controller/server_registrar.go`** to accept and forward the container ID. Its only caller is the `setupHotReload` closure — internal API, safe to change.

4. **Update the `setupHotReload` closure in `pkg/controller/gateway_builder.go`** to pass the container ID through to `RegisterOne`. While there, replace the captured `b.stackPath` with a call into `reloadHandler` that returns the live stack path (add a `StackPath()` getter on `pkg/reload.Handler` that reads `h.stackPath` under the mutex).

5. **Flip `result.Success = false` when per-item errors accumulate.** In `pkg/reload/reload.go` `Reload`, after both `applyMCPServerChanges` and `applyResourceChanges` return, if `len(result.Errors) > 0` set `result.Success = false` and write a concise `result.Message` naming the first failure (or the count). This applies to both the reload-after-init path and the file-watcher path.

6. **Include `result.Errors` in the JSON response body.** In `internal/api/stack.go` `handleStackInitialize`, when `!result.Success`, continue to return `http.StatusBadRequest` (current behavior at line 155) but include `errors` in the body so the wizard toast can display useful detail. Current response shape in the success case is `{success, name, watching}`; extend the failure response accordingly.

### Constraints

- Do **not** change the stdio entrypoint behavior (`pkg/mcp/stdio.go`) or the Docker runtime `container.go` AttachStdin flags — stdio transport already works on the apply path with the existing attach sequence, which confirms the Docker-side lifecycle is correct.
- Do **not** alter wizard UI code — scope is backend only. UX polish just landed in #472.
- Do **not** add feature-flag gates or legacy shims — `RegisterOne` and the `registerServer` callback are internal-only, and changing their signatures is in scope.
- Preserve existing public API: `reloadHandler.Initialize`, `Reload`, and the HTTP endpoint paths.
- Container runtime must not be assumed Docker-only — runtime is accessed through the `runtime.Orchestrator`/`WorkloadRuntime` interfaces. Container IDs are strings (`runtime.WorkloadID` is a string-backed type) — treat them uniformly across Docker and Podman.

### Out of Scope

- Wizard UI/UX changes.
- Refactoring `buildServerConfig` and `buildConfigFromMCPServer` into one function (tempting, but invites churn — keep the minimum diff).
- File watcher behavior changes beyond the `result.Success` flip.
- Any work on the stack library, stack save/load persistence, or stack discovery endpoints beyond the initialize response shape.
- Resolving the in-progress container state question (whether the image stays `Created` vs transitions to `Running` under an unattached stdio); once the fix lands the container will be attached and the state will correct itself.

## Implementation Guidance

### Key Files to Read First

- `pkg/controller/server_registrar.go` — builder functions and the two register paths. Read the full file to understand why `buildServerConfig` (bulk) and `buildConfigFromMCPServer` (single) diverge on the stdio branch.
- `pkg/reload/reload.go` — `Handler.Initialize`, `Handler.Reload`, `applyMCPServerChanges`, `startMCPServer`. The callback signature is defined at line 40 and set at line 71.
- `pkg/controller/gateway_builder.go` — specifically `setupHotReload` around line 446-490 which wires the callback and registers watchers.
- `pkg/controller/controller.go` — `buildAndRunStackless` around line 166-184, where the placeholder stack and empty stackPath are created.
- `internal/api/stack.go` — `handleStackInitialize` around line 113-175, the HTTP response shape.
- `pkg/mcp/gateway.go:481-540` — `RegisterMCPServer` to understand what goes wrong when `ContainerID` is empty for stdio.
- `pkg/controller/server_registrar_test.go` — existing tests, specifically `TestServerRegistrar_BuildConfigFromMCPServer_Stdio` which currently asserts the buggy empty-ID behavior and must be updated.
- `pkg/reload/reload_test.go` — test patterns for mocking `registerServer` and runtime.
- `internal/api/stack_test.go` — existing Initialize tests to match style.
- `proto/walkthrough.md` — §3 describes the expected Save & Load behavior.

### Files to Modify

- `pkg/reload/reload.go` — extend `registerServer` callback signature, update `SetRegisterServerFunc`, update `startMCPServer` call site to pass `status.ID`, flip `result.Success = false` when errors accumulate in `Reload`, add `StackPath()` getter.
- `pkg/controller/server_registrar.go` — extend `buildConfigFromMCPServer` and `RegisterOne` signatures to accept container ID; set `ContainerID` in stdio branch.
- `pkg/controller/gateway_builder.go` — update `setupHotReload` closure to pass container ID and use the live stackPath via the new `StackPath()` getter instead of the captured `b.stackPath`.
- `internal/api/stack.go` — include `errors` in the failure response from `handleStackInitialize`.
- Tests (see "Regression Test" below).

### Reusable Components

- `runtime.WorkloadStatus.ID` is already the string-backed container ID — just pass `string(status.ID)`.
- `pkg/mcp.MCPServerConfig.ContainerID` already exists and is used by the apply path at `server_registrar.go:124`.
- Existing `h.mu` mutex in `pkg/reload.Handler` — use it for any new getter on stack path.

### Conventions to Follow

- Commits: conventional-commit style, imperative mood, ≤50 chars subject, type `fix:` (not `feat:` — this is a bug fix).
- **Sign commits with `-S`**. **No Co-authored-by trailers.** **No mention of Claude** in commits, PRs, or branches.
- Branch from `upstream/main` via `/branch-fork fix: <description>`. PR via `/pr-fork`.
- Error wrapping: `fmt.Errorf("something: %w", err)`.
- Logging: `h.logger.Info/Warn/Error(msg, "key", value, ...)` slog-style.
- Test assertions: standard library `testing` — project does not use testify. Follow the style in `pkg/reload/reload_test.go` and `pkg/controller/server_registrar_test.go`.
- Keep docstrings minimal — one line, only when the *why* is non-obvious.

## Regression Test

### Test Outline

1. **`pkg/reload/reload_test.go` — `TestHandler_Initialize_Stdio_PassesContainerID`**
   - Build a fake `runtime.Orchestrator`/`WorkloadRuntime` that returns `WorkloadStatus{ID: "fake-container-id"}` from `Start`.
   - Stub `registerServer` to capture its arguments.
   - Call `Initialize` with a stack containing one stdio container MCP server.
   - Assert the captured call received `containerID == "fake-container-id"`.

2. **`pkg/reload/reload_test.go` — `TestHandler_Reload_ErrorsFlipSuccess`**
   - Stub `registerServer` to return an error.
   - Assert `result.Success == false`, `result.Errors` is populated, and `result.Message` is non-empty.

3. **`pkg/controller/server_registrar_test.go` — update `TestServerRegistrar_BuildConfigFromMCPServer_Stdio`**
   - Change the assertion: when a non-empty container ID is passed, the returned `MCPServerConfig.ContainerID` equals it.
   - Keep an additional case that an empty container ID still returns a config (so the caller can choose to handle it) — but the stdio branch is now unambiguously driven by its argument.

4. **`internal/api/stack_test.go` — `TestHandleStackInitialize_SurfacesPerServerErrors`**
   - Inject a reload handler that returns `{Success: false, Errors: ["boom"], Message: "..."}`.
   - Assert the HTTP response is 400 and the body contains the `errors` array.

5. **`pkg/controller/gateway_builder_test.go` (if test file exists; otherwise in a new file)** — `TestSetupHotReload_UsesLiveStackPath`
   - Wire up a builder in stackless mode (empty initial `stackPath`), simulate `Initialize` setting a new path, call the registrar closure, assert the path passed to `RegisterOne` matches the post-Initialize value. If `gateway_builder` is hard to test directly, this can be covered as an integration test in `pkg/reload/reload_test.go`.

### Existing Test Patterns

- Most tests live as `*_test.go` in the same package (white-box). Use table-driven tests where it clarifies, but straightforward cases can be written out directly — see `TestHandleStackInitialize_Success` style in `stack_test.go`.
- Mocking Docker runtime: see `pkg/runtime/docker/mock_test.go` for the `MockDockerClient`; for higher-level tests use a fake `runtime.WorkloadRuntime` implementation inline with the test.
- HTTP handler tests use `httptest.NewRecorder` + `http.NewRequest`. See `internal/api/stack_test.go` for examples.

## Potential Pitfalls

- **Do not break `RegisterAll`.** The apply path has its own builder (`buildServerConfig`) which already sets `ContainerID`. The fix should not touch that path unless refactoring; keep the minimum diff.
- **Mutex discipline in `pkg/reload.Handler`.** Any new `StackPath()` getter must lock `h.mu` to avoid racing with `Initialize`'s writer.
- **Callback signature change is a breaking internal API change.** Search `SetRegisterServerFunc` call sites — there should be exactly one (`gateway_builder.go:457`), but verify with grep before committing.
- **`status.ID` may be zero-value on error paths.** `startMCPServer` already returns the error from `rt.Start` before reaching the callback, so if registration proceeds the ID is non-empty. Still: in tests make sure the error ordering is preserved.
- **Response shape change for `handleStackInitialize` failure.** Current success body is `{success, name, watching}`. The failure path today calls `writeJSONError` at line 155 which probably emits `{error: "..."}`. Decide whether to keep `writeJSONError` and append an `errors` field, or build a custom failure response. Match whatever `writeJSONError` looks like in `internal/api` — follow the house style.
- **The `reload: per-item error` log line is already present.** Do not duplicate or remove it — it is valuable diagnostic output and was the signal that pointed at this bug.
- **Wizard client behavior**: if the wizard code currently checks only `response.ok` (HTTP 200) and displays a generic success toast on 400, the fix may need a wizard-side follow-up to render the new `errors` array. That follow-up is out of scope for this PR, but flag it in the PR description so the UI team sees it.

## Acceptance Criteria

1. Running the reproduction steps above — `./gridctl stop && ./gridctl serve`, configure a stack with a stdio container MCP server in the wizard, click Save & Load — results in the canvas populating with the gateway and the stdio server node, and the gateway card showing the correct `MCP Servers` count (≥1).
2. `docker ps` shows the MCP server container in state `Up ...` (not `Created`). `docker inspect <container> --format '{{.State.Status}}'` is `running`.
3. When registration fails for any reason, `POST /api/stack/initialize` returns HTTP 400 with a body containing `errors` listing the failing server name(s) and messages.
4. `~/.gridctl/logs/gridctl.log` continues to emit `reload: per-item error` diagnostic lines; the final `reload complete` line shows `errors=0` on the happy path.
5. The existing `gridctl apply <stack.yaml>` flow is unchanged — golden-path smoke test passes (start a stack with `apply`, confirm github stdio server registers).
6. `golangci-lint run` is clean; `go test -race ./...` is green; `go build` produces a working binary; `npm run build` (web) is unaffected.
7. New regression tests listed above are all present and passing. The pre-existing `TestServerRegistrar_BuildConfigFromMCPServer_Stdio` is updated to assert the fixed behavior (not the old empty-ContainerID shape).
8. The latent `b.stackPath` LocalProcess bug is fixed: a stack with a LocalProcess MCP server loaded via Save & Load resolves `WorkDir` to the stack's directory, not `"."`. Add a test or note in the PR description explaining how this was verified (unit test preferred).

## References

- Full investigation: `<prompt-stack>/prompts/gridctl/stackless-stdio-registration/bug-evaluation.md`
- Expected behavior: `proto/walkthrough.md` §3 (Save & Load walkthrough)
- Introducing PRs (context): #458 (stackless serve), #459 (initialize endpoint), #460 (Save & Load wizard action)
- Most recent adjacent fix (explicitly out of scope): #472 (wizard YAML / Save & Load UX)
- In-code acknowledgement of the gap: `pkg/controller/server_registrar.go:193-194`

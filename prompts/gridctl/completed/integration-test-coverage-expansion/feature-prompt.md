# Feature Implementation: Integration Test Coverage Expansion

## Context

**gridctl** is a Go CLI tool that acts as an MCP (Model Context Protocol) gateway and orchestrator. It manages Docker/Podman containers running MCP servers, provides a unified JSON-RPC gateway over HTTP/SSE/stdio transports, supports hot reload of stack configuration, and includes a skills registry for workflow execution.

**Tech stack**: Go 1.22+, `github.com/docker/docker` SDK (direct, no wrapper libraries), `log/slog`, standard library only for non-Docker code (Articles I and II). The test stack uses Go's standard `testing` package only — no testify, no gomock.

**Repository layout** (relevant paths):
```
tests/integration/          # integration test files (//go:build integration)
pkg/mcp/                    # gateway, router, handler, transport clients (client.go, stdio.go, process.go, sse.go)
pkg/runtime/                # WorkloadRuntime interface + Docker/Podman implementations
pkg/reload/                 # hot reload handler (reload.go, diff.go, watcher.go)
pkg/registry/               # skills registry (executor.go, store.go, dag.go, server.go)
pkg/controller/             # gateway_builder.go, server_registrar.go, daemon.go
examples/_mock-servers/     # mock-mcp-server (HTTP/SSE) and local-stdio-server (stdio)
```

**Constitution constraints** (non-negotiable):
- Article III: All exported functions must have tests before merge
- Article IV: Integration tests MUST use real Docker clients, real containers, real network connections. Mocks MUST NOT be used in `tests/integration/`. All integration tests MUST run with the `-race` flag.
- Article I/II: No new external dependencies. Use raw `github.com/docker/docker` SDK (already in go.mod), not testcontainers or dockertest.
- Article VI: All I/O-bound functions accept `context.Context` as first param.
- Article XIV: Use `log/slog` for structured logging, not `fmt.Println`.

**CI**: GitHub Actions `gatekeeper.yaml` runs `go test -tags=integration -race -timeout 5m ./tests/integration/...` on `ubuntu-latest` (Docker available natively) and a separate Podman job. No CI changes needed.

## Evaluation Context

- The infrastructure to build this is already in place (Docker in CI, mock servers, established test patterns). See full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/integration-test-coverage-expansion/feature-evaluation.md`
- testcontainers-go was evaluated and rejected — it would violate Articles I and II. Use the raw Docker SDK via `runtime.New()` (the same factory the production code uses).
- Mock servers (`examples/_mock-servers/`) have no Dockerfiles; use them as compiled subprocesses (via `exec.Command`) rather than Docker images.
- Hot reload watcher tests require only `t.TempDir()` and file mutations — no Docker needed for the watcher path.
- `orchestrator_test.go` is a pre-existing Article IV violation (mocks in `tests/integration/`, no build tag). It must be remediated as part of this work.

## Feature Description

Expand `tests/integration/` with four new test files covering the project's most complex, stateful subsystems — each currently having zero integration-level test coverage. All new tests must use real Docker clients, real network connections, and no mocks.

## Requirements

### Functional Requirements

1. **Prerequisite — Remediate `orchestrator_test.go`**: Move `tests/integration/orchestrator_test.go` (and `MockWorkloadRuntime`, `MockBuilder`) to `pkg/runtime/orchestrator_test.go`. Add no build tag (unit tests run always). Verify existing tests still pass. This clears the Article IV violation before adding new tests.

2. **`tests/integration/transport_test.go`** — MCP transport layer:
   - In `TestMain`: compile `examples/_mock-servers/mock-mcp-server` and `examples/_mock-servers/local-stdio-server` to temp binaries using `exec.Command("go", "build", "-o", ...)`. Store binary paths as package-level vars. All tests skip if build fails or Docker unavailable.
   - `TestHTTPTransportConnect`: start `mock-mcp-server` as a subprocess on a random high port, use `pkg/mcp/client.go` to connect, call `Initialize()`, call `RefreshTools()`, verify tool list contains expected tools (echo, add, get_time), call `CallTool("echo", ...)`, verify response. Kill subprocess in `t.Cleanup`.
   - `TestSSETransportConnect`: same as above with `-sse` flag, verify SSE transport path through `pkg/mcp/client.go` or `pkg/mcp/sse.go`.
   - `TestStdioTransportConnect`: use `local-stdio-server` binary with `pkg/mcp/process.go`, verify Initialize + tools/list + tools/call round-trip.
   - `TestTransportReconnect`: start HTTP mock server, connect, kill subprocess, restart subprocess on same port, verify client reconnects (if `Reconnectable` interface is implemented for that transport).
   - All tests: `//go:build integration`, `package integration`, `context.WithTimeout(ctx, 30*time.Second)`.

3. **`tests/integration/hot_reload_test.go`** — hot reload lifecycle:
   - `TestHotReload_AddServer`: write initial stack YAML to `t.TempDir()`, start stack with `runtime.New()` + `rt.Up()`, create `reload.NewHandler(...)`, add a second MCP server entry to the YAML file, call `handler.Reload(ctx)`, verify `ReloadResult.Added` contains the new server name, verify the container was started via `rt.Status()`.
   - `TestHotReload_RemoveServer`: start a two-server stack, remove one from YAML, call `Reload()`, verify `ReloadResult.Removed` contains the removed server, verify only one container remains in `rt.Status()`.
   - `TestHotReload_ModifyServer`: change an image or env var in YAML, call `Reload()`, verify `ReloadResult.Modified` contains the server name, verify old container is gone and new one is running.
   - `TestHotReload_NetworkChangeRejected`: change the network name in YAML, call `Reload()`, verify an error is returned (network changes require full restart).
   - `TestHotReload_Idempotent`: call `Reload()` twice with no YAML change between calls, verify second result has no added/removed/modified.
   - All tests: use real `runtime.New()`, `t.TempDir()` for stack YAML, unique stack names using `t.Name()`.

4. **`tests/integration/gateway_lifecycle_test.go`** — gateway initialization and registration:
   - `TestGatewayRegisterHTTPServer`: compile mock-mcp-server (reuse from transport tests or rebuild), start it as subprocess, build a minimal `config.Stack` with one HTTP MCP server pointing at the subprocess, use `controller.NewGatewayBuilder(...)` or construct `mcp.Gateway` directly, call `RegisterMCPServer()`, verify the server appears in the gateway's registered server list, call `HandleToolsList()`, verify tools are returned.
   - `TestGatewayUnregisterServer`: register a server, then unregister it, verify `HandleToolsList()` no longer includes its tools.
   - `TestGatewayHealthMonitor`: register a server, kill the subprocess, wait for one health check cycle (mock or shorten `DefaultHealthCheckInterval` via test option if available), verify server is marked unhealthy.
   - `TestGatewayGracefulShutdown`: start gateway HTTP server on a test port, verify it responds to requests, call shutdown, verify port is released and connections are rejected.
   - All tests: no mocks; use real mock-server subprocess for the MCP backend; use real gateway struct.

5. **`tests/integration/skills_executor_test.go`** — skills workflow executor:
   - `TestExecutor_SingleStepSkill`: create a `registry.Store` backed by `t.TempDir()`, write a minimal skill YAML (single step calling the `echo` tool), create `registry.NewExecutor(toolCaller, ...)` where `toolCaller` connects to a running mock-mcp-server subprocess, call `executor.Execute(ctx, skill, inputs)`, verify result contains the echo output.
   - `TestExecutor_MultiStepDAG`: write a two-step skill where step 2 depends on step 1's output (via template interpolation), verify both steps execute in correct order and step 2 receives step 1's result.
   - `TestExecutor_ParallelSteps`: write a skill with two independent steps, verify both execute (timing or ordering may vary — assert both results are present, not execution order).
   - `TestExecutor_DepthLimit`: write a skill that calls another skill recursively; verify execution fails with a depth-limit error before reaching `defaultMaxDepth`.
   - `TestExecutor_ToolCallTimeout`: if the tool call hangs, verify the workflow-level timeout fires and returns an error.
   - The `toolCaller` in these tests is a real connection to a running mock-mcp-server subprocess — not a mock.

6. **All new test files must**:
   - Carry `//go:build integration` as the first line
   - Use `package integration`
   - Skip with `t.Skipf` if Docker or required binaries are unavailable
   - Run clean: deferred `t.Cleanup` removes all containers, networks, and processes
   - Use unique identifiers (`t.Name()` or a short UUID) in stack/network names to prevent collision

### Non-Functional Requirements

- All tests pass with `-race` flag (Article IV mandate)
- No test leaves orphaned containers, networks, or processes on failure
- Individual test timeout: 30–60 seconds; total suite budget stays under 5 minutes
- No new `go.mod` dependencies introduced
- Zero mocks in the integration package after remediation

### Out of Scope

- Testing the `daemon.go` subprocess-fork path (requires its own subprocess test pattern — complex enough for a separate feature)
- Full end-to-end CLI invocation tests (`cmd/` layer)
- SSH transport integration (requires an accessible SSH server)
- OpenAPI transport integration (already covered by `openapi_test.go`)
- Watcher file-system event integration (test the `reload.Handler.Reload()` directly rather than the fsnotify loop)

## Architecture Guidance

### Recommended Approach

Follow the pattern already established in `runtime_test.go`:
- `runtime.New()` for real Docker client (skips gracefully if unavailable)
- `context.WithTimeout(context.Background(), N*time.Minute)` + `defer cancel()`
- Deferred cleanup functions for containers and processes
- Direct struct construction (no dependency injection frameworks)

For mock-server subprocess management, use this pattern:
```go
cmd := exec.CommandContext(ctx, mockServerBin, "-port", strconv.Itoa(port))
cmd.Stderr = os.Stderr
if err := cmd.Start(); err != nil {
    t.Fatalf("start mock server: %v", err)
}
t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
// poll until ready
waitForPort(t, ctx, port)
```

For port selection, use `net.Listen("tcp", ":0")` to get an OS-assigned free port, close the listener, then pass that port to the subprocess — avoids hardcoded port ranges and collisions.

### Key Files to Understand (read before implementing)

1. `tests/integration/runtime_test.go` — canonical existing integration test pattern; study setup/teardown discipline
2. `pkg/runtime/interface.go` — `WorkloadRuntime` interface definition; understand `UpOptions`, `UpResult`, `WorkloadStatus`
3. `pkg/mcp/gateway.go` (lines 1–200) — `Gateway` struct fields, `RegisterMCPServer`, `HandleToolsList`
4. `pkg/controller/gateway_builder.go` — `GatewayBuilder.Build()` and `Run()` — how the full gateway is constructed
5. `pkg/controller/server_registrar.go` — how `MCPServerConfig` is built for each transport type
6. `pkg/reload/reload.go` — `Handler` struct, `NewHandler()`, `Reload()` method signature and `ReloadResult`
7. `pkg/reload/diff.go` — `ComputeDiff()`, `ConfigDiff` struct — understand what triggers add/remove/modify
8. `pkg/registry/executor.go` — `Executor` struct, `Execute()` method, `ToolCaller` interface
9. `pkg/registry/store.go` — how to write skill YAML and load it into a `Store`
10. `examples/_mock-servers/mock-mcp-server/main.go` — what tools it exposes and how to invoke them

### Integration Points

| What to test | Entry point | Notes |
|---|---|---|
| Transport clients | `pkg/mcp/client.go`: `NewClient`, `Connect`, `Initialize`, `RefreshTools`, `CallTool` | Pass server URL directly; no gateway needed |
| Stdio transport | `pkg/mcp/process.go`: `NewProcessClient`, `Connect` | Pass `Command []string` pointing to local-stdio-server binary |
| Hot reload | `pkg/reload/reload.go`: `NewHandler`, `Handler.Reload` | Requires `*mcp.Gateway` + `*runtime.Orchestrator` — construct both from real Docker |
| Gateway registration | `pkg/mcp/gateway.go`: `New`, `RegisterMCPServer`, `HandleToolsList` | Can test without full HTTP server by calling methods directly |
| Skills executor | `pkg/registry/executor.go`: `NewExecutor`, `Execute` | Needs a `ToolCaller` — wire to real mock-server via `pkg/mcp/client.go` |

### Reusable Components

- `runtime.New()` — already exists, creates real Docker/Podman client
- `runtime.NewOrchestrator(rt, builder)` — constructor for stack orchestration
- `config.Stack{}` struct — already used in existing tests
- `context.WithTimeout` + skip pattern — copy from `runtime_test.go`
- `pkg/mcp/gateway.New(serverInfo, version)` — gateway constructor

## UX Specification

No end-user UX change. Developer-facing only:

- `make test-integration` runs the full suite including new tests
- New tests skip with `t.Skipf("Docker not available: %v", err)` when Docker is absent
- Failure messages identify which subsystem and which specific behavior failed
- CI shows clearly which of the 4 subsystem test files failed

## Implementation Notes

### Conventions to Follow

- File naming: `<subsystem>_test.go` in `tests/integration/`
- Build tag: `//go:build integration` as line 1, blank line, then `package integration`
- No `t.Parallel()` unless you've verified all cleanup is scoped to `t.Cleanup` — Docker test parallelism can cause flakiness
- Error handling: `t.Fatalf` for setup failures (test cannot continue); `t.Errorf` for assertion failures (test can continue to check more conditions)
- Stack names: always include test function name fragment, e.g., `"inttest-" + sanitize(t.Name())`
- Use `t.Helper()` in any shared assertion helper functions

### Potential Pitfalls

1. **Mock server startup timing**: The subprocess needs time to bind its port. Use a polling loop (10ms intervals, 5s total) — don't sleep for a fixed duration.
2. **Port reuse after subprocess kill**: OS may hold the port briefly. Use `SO_REUSEADDR` via `net.ListenConfig` or pick a fresh OS-assigned port for each test.
3. **`reload.Handler` requires `registerServer` callback**: Call `handler.SetRegisterServerFunc(...)` before calling `Reload()` or it will silently skip gateway registration.
4. **`mcp.Gateway` health monitor runs a goroutine**: Ensure `gateway.Close()` or a done channel is used in test teardown to avoid goroutine leaks detected by `-race`.
5. **Skill YAML frontmatter format**: Read `pkg/registry/store.go` carefully — the YAML parsing expects specific frontmatter fields. Write a minimal valid skill for tests, don't improvise the schema.
6. **`orchestrator_test.go` remediation**: When moving to `pkg/runtime/`, the import paths will need updating. Verify with `go build ./pkg/runtime/...` before proceeding.

### Suggested Build Order

1. **Remediate `orchestrator_test.go`** — move to `pkg/runtime/orchestrator_test.go`, verify unit tests pass
2. **Implement transport tests** (`transport_test.go`) — validates mock server subprocess helpers; these helpers will be reused by gateway tests
3. **Implement hot reload tests** (`hot_reload_test.go`) — self-contained, only needs Docker runtime + temp file
4. **Implement gateway lifecycle tests** (`gateway_lifecycle_test.go`) — builds on transport test helpers
5. **Implement skills executor tests** (`skills_executor_test.go`) — builds on gateway test helpers

## Acceptance Criteria

1. `go test -tags=integration -race -timeout 5m ./tests/integration/...` passes cleanly on a machine with Docker running.
2. `go test -tags=integration -race -timeout 5m ./tests/integration/...` skips gracefully (exit 0) on a machine without Docker.
3. `go test -race ./pkg/runtime/...` passes (covers remediated orchestrator tests).
4. No mocks exist anywhere in `tests/integration/` after remediation.
5. `transport_test.go` covers HTTP, SSE, and stdio transport round-trips.
6. `hot_reload_test.go` covers add, remove, modify, network-change-rejected, and idempotent scenarios.
7. `gateway_lifecycle_test.go` covers register, unregister, and graceful shutdown.
8. `skills_executor_test.go` covers single-step, multi-step DAG, parallel steps, depth limit, and timeout scenarios.
9. No container, network, or subprocess leaks on test failure (verify by running tests with `docker ps` before and after).
10. CI `integration` job passes with the new tests included.

## References

- [Constitution](/Users/william/code/gridctl/CONSTITUTION.md) — Articles I, II, III, IV, VI, XIV
- [Feature evaluation](/Users/william/code/prompt-stack/prompts/gridctl/integration-test-coverage-expansion/feature-evaluation.md)
- [testcontainers-go](https://github.com/testcontainers/testcontainers-go) — evaluated and rejected (new dependency)
- [air — hot reload test pattern](https://github.com/air-verse/air)
- [docker/compose integration test pattern](https://github.com/docker/compose)
- [Go build tags for test separation](https://ornlu-is.github.io/go_build_tags/)
- [Separating tests in Go](https://filipnikolovski.com/posts/separating-tests-in-go/)

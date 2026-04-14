# Feature Evaluation: Integration Test Coverage Expansion

**Date**: 2026-04-06
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Large

## Summary

Four complex, stateful subsystems in gridctl — the runtime/transport layer, gateway lifecycle, hot reload, and skills workflow executor — have zero integration-level test coverage despite the project's Constitution (Articles III and IV) explicitly requiring real-dependency integration tests for all exported functionality. The mock server infrastructure is already built, CI already runs real Docker on both Docker and Podman, and the patterns are established. This is the clearest possible "Build" recommendation: constitutionally mandated, infrastructure-ready, and the correctness risk grows with every commit.

## The Idea

Expand `tests/integration/` to cover the four subsystems currently untested at the integration level:

1. **Runtime/transport layer** — Verify that HTTP, SSE, and stdio MCP transport clients can connect to real servers, exchange JSON-RPC messages, and handle reconnection and error conditions.
2. **Gateway lifecycle** — Verify that the gateway initializes correctly, registers MCP servers across all transport types, starts its HTTP server, runs health monitoring, and shuts down gracefully.
3. **Hot reload** — Verify that config diffs are correctly computed, containers are started/stopped in response, the gateway registers/unregisters servers, and pins are reset on modification.
4. **Skills workflow executor** — Verify that skills are discovered, DAGs are built and executed, tool calls are dispatched through a real gateway, and results are correctly propagated.

The problem: regressions in these subsystems are invisible to the unit test suite. They involve real Docker state, real process spawning, real HTTP/SSE streams, and real file watching — behaviors that cannot be validly tested with mocks. The longer this coverage gap persists, the harder it becomes to refactor safely.

## Project Context

### Current State

- `tests/integration/` contains 3 real integration tests (runtime_test.go, openapi_test.go, podman_test.go) and one misplaced unit test file (orchestrator_test.go — uses `MockWorkloadRuntime`, lacks `//go:build integration` tag; a pre-existing Article IV violation).
- Existing tests cover: container lifecycle (Up/Down), multi-network stacks, resource workloads, OpenAPI client init, and Podman parity.
- CI has dedicated `integration` and `podman-integration` jobs that run `go test -tags=integration -race -timeout 5m ./tests/integration/...` against real Docker/Podman on `ubuntu-latest` runners — no additional CI infrastructure needed.
- `examples/_mock-servers/` provides two fully functional MCP server implementations: `mock-mcp-server` (HTTP/SSE) and `local-stdio-server` (stdio). Neither has a Dockerfile; both are runnable as compiled Go binaries or subprocesses.

### Integration Surface

| Subsystem | Key files |
|-----------|-----------|
| Runtime/transport | `pkg/runtime/interface.go`, `pkg/mcp/client.go`, `pkg/mcp/stdio.go`, `pkg/mcp/process.go`, `pkg/mcp/sse.go` |
| Gateway lifecycle | `pkg/mcp/gateway.go`, `pkg/controller/gateway_builder.go`, `pkg/controller/server_registrar.go`, `pkg/controller/daemon.go` |
| Hot reload | `pkg/reload/reload.go`, `pkg/reload/diff.go`, `pkg/reload/watcher.go` |
| Skills executor | `pkg/registry/executor.go`, `pkg/registry/store.go`, `pkg/registry/dag.go`, `pkg/registry/server.go` |

### Reusable Components

- `MockWorkloadRuntime` and `MockBuilder` in `orchestrator_test.go` — usable in unit-level helpers (but NOT in integration tests per Article IV)
- `runtime.New()` pattern from `runtime_test.go` — established pattern for real Docker setup/skip
- `context.WithTimeout` + `defer rt.Close()` + `defer rt.Down(ctx, stackName)` — cleanup pattern used throughout
- `examples/_mock-servers/` — compile-and-run for process-based MCP servers in transport tests

## Market Analysis

### Competitive Landscape

Comparable Go orchestration tools (docker/compose, hashicorp/nomad, earthly/earthly) all test their container lifecycle, transport, and reload paths at the integration level against real Docker daemons. The consensus pattern:

- Build-tag separation (`//go:build integration`) — exactly what gridctl uses
- `TestMain` for shared infrastructure setup (not yet used in gridctl)
- Real daemon, no DinD — `ubuntu-latest` GitHub runners ship Docker 24+
- Integration tests for transport-level correctness (protocol framing, connection setup, reconnect)

Reference implementations:
- **air** (hot reload tool) — tests file watcher with `t.TempDir()` and file mutations, no Docker needed for watcher logic
- **docker/compose** — uses raw Docker SDK for orchestration tests, no testcontainers
- **hashicorp/nomad** — three-tier test pyramid: unit / integration (real daemon) / e2e; `TestMain` for shared infra

### Market Positioning

Integration test coverage for a Docker orchestration tool is **table-stakes**, not a differentiator. The differentiator is gridctl's Podman parity and multi-runtime CI — that's already in place. The gap in transport/gateway/reload coverage is a correctness liability, not a competitive gap.

### Ecosystem Support

- **testcontainers-go**: The community default for new Go projects needing Docker in tests. Not needed here — gridctl already owns the Docker client abstraction via `pkg/dockerclient` and `pkg/runtime`. Using testcontainers would add a dependency that violates Articles I and II.
- **ory/dockertest**: Less maintained, container leak risks. Not recommended.
- **Raw docker/docker SDK**: The right choice for gridctl. Zero new dependencies, full control, consistent with production code patterns.

### Demand Signals

Internal: Constitution Articles III and IV explicitly mandate this. Every PR that ships functionality without integration tests technically violates Article III ("A feature without tests is not complete"). The demand is self-evident from the project's own governance.

## User Experience

### Interaction Model

This is a developer-facing feature. The users are contributors running `make test-integration` locally and the CI system.

**Discovery**: New test files appear in `tests/integration/` following the established naming convention (`transport_test.go`, `gateway_lifecycle_test.go`, `hot_reload_test.go`, `skills_executor_test.go`).

**Activation**: `make test-integration` — no change to the developer workflow.

**Feedback**: Tests skip gracefully when Docker is unavailable (`t.Skipf("Docker not available: %v", err)`). When Docker is available, tests run with real containers and produce clear failure messages on assertion failures.

### Workflow Impact

No change to existing workflows. Adds test runtime (large tests add ~30-90s to the integration suite). Requires Docker locally for full runs, but tests skip cleanly otherwise.

### UX Recommendations

1. **Add `TestMain`** for shared Docker client setup — avoids redundant `runtime.New()` calls per test and centralizes skip logic.
2. **Use unique stack names with `t.Name()`** to prevent collision between parallel test runs.
3. **Build mock servers during `TestMain`** using `exec.Command("go", "build", ...)` — compile once, reuse across tests.
4. **Remediate `orchestrator_test.go`** as a prerequisite: move to `pkg/runtime/` (where it belongs as a unit test) or strip mocks and add real Docker.
5. **Port range discipline**: use distinct port ranges per test file (transport: 19300+, gateway: 19400+, reload: 19500+, skills: 19600+) to prevent collision.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Regressions in gateway/transport/reload are invisible without this; stateful complexity makes unit mocks insufficient |
| User impact | Narrow+Deep | Affects maintainers and contributors; very high confidence gain for refactoring |
| Strategic alignment | Core mission | Constitution Articles III and IV are non-negotiable mandates |
| Market positioning | Catch up | Below industry norm for Docker orchestration tools; filling the gap |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | New test files and helpers only; no production code changes |
| Effort estimate | Large | 4 subsystems × real Docker setup, race safety, CI validation; ~3-5 focused days |
| Risk level | Low | Tests don't change production code; only risk is test flakiness |
| Maintenance burden | Moderate | Tests need updating when subsystem contracts change — unavoidable and appropriate |

## Recommendation

**Build** — this is constitutionally required, infrastructure-ready, and the correctness risk is material and growing.

Implement in priority order:

1. **Transport layer** (highest value): Build `transport_test.go`. Compile `mock-mcp-server` as a subprocess in test setup, verify HTTP and SSE MCP connections round-trip JSON-RPC correctly through `pkg/mcp/client.go`. Test `pkg/mcp/process.go` (stdio) by running `local-stdio-server` as a subprocess.

2. **Hot reload** (most unique): Build `hot_reload_test.go`. Start a real stack with `runtime.New()`, write modified YAML to a temp file, call `Handler.Reload()`, verify containers were added/removed and gateway state was updated.

3. **Gateway lifecycle** (foundational): Build `gateway_lifecycle_test.go`. Use `gateway_builder.go` to stand up a real gateway against mock-server subprocesses, verify registration, tool listing, and graceful shutdown.

4. **Skills workflow executor** (lower priority): Build `skills_executor_test.go`. Register a multi-step skill in a temp registry, wire it to a real gateway with mock-server tools, execute the workflow, verify step results and DAG ordering.

**Prerequisite**: Remediate `orchestrator_test.go` — move to `pkg/runtime/orchestrator_test.go` as a proper unit test (no build tag, mocks allowed).

## References

- [Constitution Article III + IV](/Users/william/code/gridctl/CONSTITUTION.md)
- [testcontainers-go](https://github.com/testcontainers/testcontainers-go)
- [ory/dockertest](https://github.com/ory/dockertest)
- [air — hot reload watcher tests](https://github.com/air-verse/air)
- [docker/compose integration tests](https://github.com/docker/compose)
- [hashicorp/nomad test patterns](https://github.com/hashicorp/nomad)
- [Separating Tests in Go — Filip Nikolovski](https://filipnikolovski.com/posts/separating-tests-in-go/)
- [Using Go build tags for defining sets of tests](https://ornlu-is.github.io/go_build_tags/)

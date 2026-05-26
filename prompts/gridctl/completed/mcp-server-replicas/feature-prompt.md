# Feature Implementation: MCP Server Replicas

## Context

**gridctl** (`/Users/william/code/gridctl`) is a Go-based orchestration and
configuration layer for MCP (Model Context Protocol) servers. It declares
servers in `stack.yaml` and manages their lifecycles — spawning local
subprocesses, attaching to container stdio, speaking HTTP/SSE to external
endpoints, or generating MCP tools from OpenAPI specs. A Go gateway
(`pkg/mcp/gateway.go`) aggregates all configured servers behind a single MCP
endpoint that clients (Claude Desktop, IDEs, etc.) connect to. Tools are
exposed with a prefixed namespace: `<serverName>__<toolName>`.

**Tech stack**: Go (backend, CLI, gateway), React/TypeScript (web UI/wizard),
Docker for container-based servers. Tests use Go's standard testing package
with integration tests under `tests/integration/`.

**Transport types** (from `pkg/config/types.go`):
- `IsContainerBased()` — image/source, runs in Docker
- `IsLocalProcess()` — stdio via `exec.Command`
- `IsSSH()` — remote process via SSH
- `IsExternal()` — HTTP URL only, no process management
- `IsOpenAPI()` — stateless HTTP generated from spec

## Evaluation Context

Key findings from the feature evaluation that shaped this prompt:

- **Prior art is thick and consistent**: Kubernetes/Compose/Swarm use `replicas`;
  FPM/pgbouncer/Gunicorn all implement the same pre-forked-pool pattern with
  round-robin default and least-connections as the common override.
- **No MCP gateway ships this today**: Docker/Microsoft/sparfenyuk/ContextForge
  all punt to HTTP-tier scaling or duplicate-service tricks. This is a
  differentiating feature for multi-user stdio operators.
- **MCP spec is silent on server concurrency**: the community trajectory is
  Streamable HTTP + statelessness, but the stdio long tail (npm/pip community
  servers) will persist for years, so replicas is a durable pragmatic bridge.
- **Restart backoff is a prereq**: gridctl has no backoff in its reconnect path
  today; shipping replicas without it turns one crashing binary into a
  CPU-spinning log-spam incident.
- **Replica-tagged logs and traces are non-negotiable**: without `replica_id`
  in every log line, debugging concurrency bugs is strictly harder than the
  single-process case.
- **Scope was explicitly tightened**: session affinity, autoscaling, and
  per-replica resource limits are out for v1.
- Full evaluation:
  `~/code/prompt-stack/prompts/gridctl/mcp-server-replicas/feature-evaluation.md`

## Feature Description

Add a `replicas: N` integer field to `mcp-servers[]` entries in `stack.yaml`.
When set, gridctl spawns N independent processes for that server and load-
balances JSON-RPC tool calls across them. Default `replicas: 1` preserves
current behavior.

**Problem solved**: In multi-user deployments, a single stdio process per MCP
server causes three liabilities: head-of-line blocking from broken-async
third-party servers, single-process crashes taking out the server for every
connected user, and no horizontal scaling path that preserves the tool
namespace. Replicas give natural process isolation, crash survivability, and
horizontal scaling without forcing users to duplicate server entries under
renamed namespaces.

**Who benefits**: Operators running gridctl in multi-user / stackless mode with
stdio-based MCP servers (local-process or container-stdio). The motivating
example from the user-submitted request is a local-process Python MCP server
(`.venv/bin/python servers/junos-mcp-server/jmcp.py`) serving multiple network
engineers whose SSH-heavy tool calls block each other.

## Requirements

### Functional Requirements

1. Add `Replicas int` field to `MCPServer` struct in `pkg/config/types.go`
   with `yaml:"replicas,omitempty"`.
2. Add `ReplicaPolicy string` field (values: `round-robin` default,
   `least-connections`).
3. Default `Replicas` to 1 in `Stack.SetDefaults()` when unspecified or zero.
4. Validate `Replicas >= 1` and `<= 32` (upper bound is a sanity check —
   higher values are almost certainly a config error). Return a clear error
   with the `mcp-servers[N].replicas` path.
5. Reject `Replicas > 1` on `IsExternal()` and `IsOpenAPI()` transports with
   a validation error explaining that those transports don't support replicas.
6. Spawn N independent processes per server when `Replicas > 1`. Each replica
   is a fresh, isolated process with its own stdio pipes and memory space.
7. For container-based servers, each replica is a separate container with a
   unique name (e.g., `<serverName>-replica-0`, `<serverName>-replica-1`).
   Container name collisions must be impossible.
8. The router (`pkg/mcp/router.go`) must map each server name to a **replica
   set** — a pool of `AgentClient` instances plus a dispatch policy — not a
   single client. Preserve the existing 1:1 API surface for callers:
   `RouteToolCall(prefixedName)` still returns one client, but chooses which
   replica by policy.
9. Round-robin dispatch by default (per-server counter, atomic increment).
10. `least-connections` policy dispatches to the replica with the fewest
    in-flight requests. Track in-flight count per replica via increment on
    dispatch and decrement on response/error.
11. Health monitor (`pkg/mcp/gateway.go` `StartHealthMonitor` /
    `checkHealth`) iterates every replica and tracks per-replica health.
    Unhealthy replicas are excluded from dispatch rotation until recovered.
12. Crash detection (already present via `drainPendingRequests` + `Ping`
    failure) triggers **per-replica** restart. The surviving replicas
    continue to serve requests without interruption.
13. Restart uses exponential backoff, starting at 1s, doubling up to a 30s
    cap, with jitter. Reset on successful `initialize` handshake.
14. Every log line emitted by a replica or about a replica includes a
    `replica_id` field (integer, zero-indexed within the server's replica set).
    Every trace span gets a `mcp.replica.id` attribute alongside
    `mcp.server.name`.
15. `gridctl status` rolls up replica health by default: `<name>  3/3 healthy`
    or `<name>  2/3 degraded (replica-1 restarting)`. Add a `--replicas`
    flag that expands to one row per replica showing replica-id, PID/container-
    id, state, uptime, and in-flight count.
16. `/api/stack/health` (in `internal/api/stack.go`) extends its response to
    include a per-replica breakdown for each server with `replicas > 1`.
17. Wizard (`web/src/components/wizard/steps/MCPServerForm.tsx`): add a
    numeric input for replicas, gated by `FieldVisibility` to container,
    local-process, and SSH transports only. Default value 1; min 1; max 32.
18. Add a `×N` badge to the graph/canvas node for servers with `Replicas > 1`.
19. If **all** replicas of a server are unhealthy, tool calls fail fast with
    an error that names the server and the replica failure reasons. Match the
    existing `drainPendingRequests` error shape.

### Non-Functional Requirements

- **Backward compatibility**: `replicas: 1` (or unspecified) must be
  byte-identical in behavior to current gridctl. Existing stack fixtures and
  golden tests unchanged except where explicitly exercising replicas.
- **Startup safety**: initialize handshake per replica. If replica-0 succeeds
  but replica-1 fails during startup, the server is considered partially
  available — route to replica-0, keep trying to bring up replica-1 with
  backoff. Do not fail the whole server because one replica couldn't start.
- **Shutdown safety**: `Close()` on a replica set closes all replicas,
  respecting the existing SIGTERM → 5s → SIGKILL pattern from
  `ProcessClient.Close()`.
- **Performance**: routing overhead in `RouteToolCall` stays O(1) for
  round-robin, O(N) for least-connections (N is small — bounded by 32).
- **Metrics**: per-replica counters in `pkg/metrics/accumulator.go`. Existing
  per-server aggregates remain (sum across replicas).

### Out of Scope (v1)

Explicitly do NOT build in this v1:

- Session affinity (`session_affinity: true`). Add as a separate field in a
  follow-up once the base replica set is proven.
- Per-replica resource limits (memory/CPU caps per container).
- Autoscaling (replicas based on queue depth, active sessions, etc.).
- Web UI per-replica drill-down panel. The `×N` badge is sufficient for v1;
  per-replica details live in CLI + API.
- Replicas for `external` and `openapi` transports — validation rejects these.
- Multi-host distribution. Replicas are all on the same gridctl host.
- Replica-aware OpenTelemetry resource attributes beyond `mcp.replica.id` on
  the span.

## Architecture Guidance

### Recommended Approach

Introduce a **ReplicaSet** abstraction in `pkg/mcp/` that holds:

```go
type ReplicaSet struct {
    name     string                  // logical server name (e.g., "junos")
    policy   string                  // "round-robin" | "least-connections"
    replicas []*Replica              // ordered, stable; index is replica_id
    mu       sync.RWMutex
    rrCursor atomic.Int64            // round-robin counter
}

type Replica struct {
    id         int                   // zero-indexed within its ReplicaSet
    client     AgentClient           // the existing ProcessClient/StdioClient/etc.
    healthy    atomic.Bool
    inFlight   atomic.Int64          // for least-connections
    restart    *backoffState         // exponential backoff state
}
```

The `Router` maps `name → *ReplicaSet` instead of `name → AgentClient`.
`Router.RouteToolCall()` internally calls `ReplicaSet.Pick()` which applies
the dispatch policy and returns the chosen `AgentClient`. Callers see the
same `AgentClient` interface they see today — the replica choice is hidden
inside `Pick()`.

This design:
- Preserves the `AgentClient` interface (no ripple into callers).
- Keeps per-replica state (health, in-flight count, backoff) out of the
  general `Router` and scoped to the set.
- Maps cleanly onto the existing health monitor — `checkHealth` iterates
  `ReplicaSet.replicas` instead of `Router.clients`.
- Keeps `Replicas: 1` (the overwhelming common case) a trivial wrap: a
  `ReplicaSet` with a single replica behaves identically to today's direct
  client.

### Key Files to Understand

1. `/Users/william/code/gridctl/pkg/mcp/router.go` — the 1:1 name→client map
   today. This is the primary interface change.
2. `/Users/william/code/gridctl/pkg/mcp/gateway.go` — `RegisterMCPServer()`
   (≈line 498) handles transport branching; `StartHealthMonitor()` /
   `checkHealth()` (≈line 373–467) run the health loop with reconnect;
   `RestartMCPServer()` (≈line 640) restarts a server.
3. `/Users/william/code/gridctl/pkg/mcp/process.go` — `ProcessClient` with
   `procMu`, `responses` map, `drainPendingRequests`, SIGTERM→SIGKILL shutdown.
   Each replica wraps one of these.
4. `/Users/william/code/gridctl/pkg/mcp/stdio.go` — `StdioClient` for
   container-stdio; each replica wraps one of these with a distinct container.
5. `/Users/william/code/gridctl/pkg/mcp/types.go` — `Pingable` and
   `Reconnectable` interfaces health monitor uses.
6. `/Users/william/code/gridctl/pkg/config/types.go` — `MCPServer` struct and
   `SetDefaults()`; add `Replicas` and `ReplicaPolicy` here.
7. `/Users/william/code/gridctl/pkg/config/validate.go` — `SetDefaults()`
   convergence point (≈line 322) and the MCPServer validation block
   (≈line 119–361) where replica validation + transport gating go.
8. `/Users/william/code/gridctl/pkg/controller/server_registrar.go` —
   `RegisterOne()` / `buildConfigFromMCPServer()` (≈line 74). This is where a
   server's N replicas get materialized as N `AgentClient` instances and
   registered into the router as one `ReplicaSet`.
9. `/Users/william/code/gridctl/pkg/runtime/orchestrator.go` —
   `MCPServerResult` / `Up()` — container lifecycle. Replica container
   naming lives here.
10. `/Users/william/code/gridctl/pkg/reload/reload.go` — the
    `RegisterServerFunc` signature that threads `containerID` for stackless
    mode. Extending for replicas means N `containerID`s per server.
11. `/Users/william/code/gridctl/pkg/metrics/accumulator.go` — per-server
    counters; add `replica_id` dimension.
12. `/Users/william/code/gridctl/cmd/gridctl/status.go` + `pkg/output/table.go`
    — CLI status rendering. Add rolled-up replica column and `--replicas`
    expansion.
13. `/Users/william/code/gridctl/internal/api/stack.go` —
    `handleStackHealth()` (≈line 239). Extend `SpecHealth` for per-replica.
14. `/Users/william/code/gridctl/web/src/lib/yaml-builder.ts` +
    `web/src/components/wizard/steps/MCPServerForm.tsx` — wizard schema and
    form UI. Gate the `replicas` input by transport.
15. `/Users/william/code/gridctl/pkg/mcp/process_test.go` +
    `tests/integration/gateway_lifecycle_test.go` — test patterns for
    spawn/kill/reconnect. Model replica tests on these.

### Integration Points

- **Router signature change**: `Router.AddClient(client)` → either
  `Router.AddReplicaSet(set *ReplicaSet)` or keep `AddClient` and internally
  wrap single clients in a `ReplicaSet{replicas: [client]}`. Prefer the wrap
  approach to minimize caller changes.
- **`buildConfigFromMCPServer` → builds N configs**: in
  `server_registrar.go`, when `cfg.Replicas > 1`, iterate 0..N-1, each
  producing a distinct replica (with unique container name for container
  transports). Then pass the list to a new
  `Gateway.RegisterMCPServerReplicaSet(configs []MCPServerConfig)`.
- **Health monitor**: today iterates `Router.Clients()`. Change to iterate
  over every replica across every replica set. `HealthStatus` grows a
  `replica_id` dimension.
- **Per-request tracing**: the existing span attribute set includes
  `mcp.server.name`. Add `mcp.replica.id` at the same point
  (`gateway.go:912` / wherever span attributes are set on the tool-call path).

### Reusable Components

- `ProcessClient` / `StdioClient` / `Client` (HTTP) — **unchanged**. A
  replica is just one of these; no per-replica client-type changes needed.
- Existing `initialize` + `RefreshTools` flow — runs per replica, unchanged.
- `drainPendingRequests` — already fails fast on EOF; works per-replica as-is.
- Existing `Ping()` / `Reconnect()` — called per-replica by the health loop.
- Existing backoff-less reconnect → this PR adds the backoff layer on top;
  `Reconnect()` itself can stay as-is.

## UX Specification

### Discovery

- Users who know Kubernetes, Compose, or Swarm recognize `replicas: N`
  immediately.
- Documentation update: add a "Scaling stdio servers" section to the
  gridctl docs covering when to use replicas, what transports support it,
  the default policy, and the operator trade-offs (memory multiplied by N,
  shared external resources still single-threaded, etc.).

### Activation

```yaml
mcp-servers:
  - name: junos
    command: [".venv/bin/python", "servers/junos-mcp-server/jmcp.py",
              "--transport", "stdio",
              "--device-mapping", "config/junos-devices.json"]
    replicas: 3
    replica_policy: least-connections
    tools: ["get_router_list", "gather_device_facts", "execute_junos_command",
            "execute_junos_command_batch"]
```

### Interaction

- Client sees one server (`junos`) and one tool namespace (`junos__*`).
- Tool call dispatch chooses replica-0/1/2 by policy, invisibly to client.
- Replica state changes (one crashing and restarting) do not interrupt
  client-visible behavior unless all replicas are down.

### Feedback

- `gridctl status` default view:
  ```
  NAME     TYPE             REPLICAS   STATE
  junos    local-process    3/3        healthy
  github   external         —          healthy
  docker   container        2/3        degraded (replica-1 restarting, next in 4s)
  ```
- `gridctl status --replicas` expanded:
  ```
  SERVER  REPLICA  PID     STATE       UPTIME   IN-FLIGHT
  junos   0        82341   healthy     12m      2
  junos   1        82342   healthy     12m      1
  junos   2        82343   healthy     12m      0
  ```

### Error States

- Config validation error (e.g., `replicas: 0` or `replicas: 5` on `external`
  transport): surface in CLI validation output, wizard form-level error, and
  `/api/stack/validate` response with the full path (`mcp-servers[2].replicas`).
- All replicas unhealthy: tool call response contains a structured error
  naming the server and the per-replica failure reasons.
- Restart backoff active: log at WARN with server, replica_id, next retry
  time, and the reason.

## Implementation Notes

### Conventions to Follow

- Follow existing gridctl Go style: struct tags for YAML + JSON; validation
  returns errors with dotted paths; use `slog` for structured logging.
- Match existing interface surface: prefer wrapping single-replica cases in
  the same `ReplicaSet` abstraction over introducing dual code paths for
  `replicas: 1` vs `replicas: N`.
- Per-replica logging: use a scoped `slog.Logger` with `replica_id` attached.
- Commit convention (from CLAUDE.md): `<type>: <subject>`, imperative mood,
  max 50 chars, no period. Sign commits with `-S`. No Claude mentions.
- Fork-based workflow for this repo (per project memory): use
  `/branch-fork <task>` to start, `/pr-fork` to submit.

### Potential Pitfalls

- **Container name collisions**: two replicas of the same server must get
  distinct container names. Use `<serverName>-replica-<id>` or similar
  deterministic scheme, and test the case where a previous gridctl run left
  a container with that name (cleanup path).
- **Stackless mode**: the recent `723d290` fix threaded `containerID` for
  stackless initialize. Extending for replicas means the reload handler
  passes a **list** of container IDs per server. Audit
  `pkg/reload/reload.go:RegisterServerFunc` carefully.
- **Tool namespace must not leak replica IDs**: the prefixed tool name
  stays `<serverName>__<toolName>`. Never include replica ID in the tool
  name. If you see `junos_0__get_router_list` anywhere, you've broken the
  contract.
- **Restart storm**: without backoff, a binary that crashes on startup will
  spin. Ship backoff with replicas in the same PR, not as a follow-up.
- **initialize handshake per replica**: each replica does its own
  `initialize` → `tools/list` exchange. Cache tool list per-server from
  replica-0 (all replicas must expose the same tools; assert this and log
  a WARN if they diverge).
- **Half-duplex stdio per replica**: `ProcessClient.procMu` serializes
  stdio *within* a replica. That's fine — concurrency across replicas is
  what we want. Don't try to share anything across replicas.
- **Tool schema pinning** (see `pkg/mcp/gateway.go` `HealthStatus`,
  `GatewaySecurityConfig.SchemaPinning`): pin is per-server, not per-replica.
  All replicas should report the same schema; if one drifts, treat as a
  drift event and alert. Don't independently pin per replica.
- **Metrics cardinality**: adding `replica_id` to every metric multiplies
  cardinality by N. Keep it low-cardinality (bounded by validation max of 32)
  and don't let user-controlled data end up in metric labels.

### Suggested Build Order

1. **Schema + validation** (`pkg/config/types.go`, `pkg/config/validate.go`).
   Add fields, defaults, validation. Update `pkg/config/types_test.go` and
   `pkg/config/validate_test.go` with replica cases. Cheap, testable, no
   runtime behavior change yet.
2. **ReplicaSet abstraction** (new file `pkg/mcp/replica_set.go`). Unit
   tests for round-robin and least-connections dispatch, health gating,
   concurrent `Pick()`.
3. **Router refactor** (`pkg/mcp/router.go`). Change internal storage;
   preserve external API by wrapping single clients in a ReplicaSet.
4. **Server registration** (`pkg/controller/server_registrar.go`,
   `pkg/reload/reload.go`). Materialize N replicas per server. Container
   naming. Thread `[]containerID` through stackless mode.
5. **Restart backoff** (in `pkg/mcp/gateway.go` reconnect path, or new
   helper). Unit tests for backoff progression, reset on success, cap.
6. **Health monitor per replica** (`pkg/mcp/gateway.go`). Iterate replicas.
   Exclude unhealthy from dispatch (already handled by `ReplicaSet.Pick()`
   filtering on `replica.healthy`).
7. **Logging + tracing `replica_id`**. Audit every `slog` call on the tool-
   call path and every trace span.
8. **CLI status** (`cmd/gridctl/status.go`, `pkg/output/table.go`). Rolled-up
   default view + `--replicas` flag.
9. **API health** (`internal/api/stack.go`). Extend response shape.
10. **Wizard** (`web/src/components/wizard/steps/MCPServerForm.tsx`,
    `web/src/lib/yaml-builder.ts`). Numeric input, `FieldVisibility` gating,
    YAML round-trip. Jest test.
11. **Web UI canvas badge** (small addition). Optional in v1 but low-cost.
12. **Integration tests** (`tests/integration/`). Kill-one-replica, all-
    replicas-down, restart-storm, mixed replica counts, stackless mode with
    replicas. Model on `TestGatewayHealthMonitor`.
13. **Docs**: new "Scaling stdio servers" section; update `stack.yaml`
    schema doc; update AGENTS.md if relevant.

## Acceptance Criteria

1. Existing stacks (no `replicas` field) run byte-identically to before.
2. `replicas: 3` on a local-process server spawns 3 independent processes
   with distinct PIDs, visible in `gridctl status --replicas`.
3. `replicas: 3` on a container-based server creates 3 containers with
   distinct names and IDs, each initialized and serving tools.
4. Tool calls against a server with replicas are distributed across replicas:
   with round-robin, successive calls hit replicas 0, 1, 2, 0, 1, 2, …;
   with least-connections, the replica with the fewest in-flight requests
   receives the next call.
5. Killing one replica's process externally (e.g., `kill <pid>`) causes the
   health monitor to mark it unhealthy within one health-check interval,
   exclude it from dispatch, and restart it with exponential backoff. The
   other replicas continue serving requests without error.
6. All replicas down → tool calls fail with an error naming the server and
   the per-replica failure reasons.
7. `replicas: 5` on an `external` or `openapi` transport fails validation
   with a clear error citing the transport type and the `mcp-servers[N].replicas`
   path.
8. Every log line and trace span on the tool-call path includes
   `replica_id` (or `mcp.replica.id` for spans) alongside the server name.
9. `gridctl status` default view shows rolled-up replica health; `--replicas`
   flag expands to one row per replica.
10. `/api/stack/health` response includes per-replica breakdown for every
    server with `replicas > 1`.
11. Wizard numeric input for replicas is visible on container/local-process/
    ssh server forms, hidden on external/openapi forms, accepts 1–32, and
    round-trips through YAML.
12. New integration tests pass: kill-one-replica, all-replicas-down,
    restart-storm (binary that exits immediately — must not spin CPU, must
    apply backoff), stackless-mode-with-replicas.
13. No regression in existing `pkg/mcp/process_test.go` or
    `tests/integration/gateway_lifecycle_test.go`.
14. Linting passes (`golangci-lint`), tests pass with `-race`, build passes
    (`make build`), web build passes (`npm run build`).

## References

### MCP ecosystem

- MCP spec 2025-11-25: https://modelcontextprotocol.io/specification/2025-11-25
- MCP transports: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- MCP "Future of Transports" (Dec 2025): https://blog.modelcontextprotocol.io/posts/2025-12-19-mcp-transport-future/
- sparfenyuk/mcp-proxy (closest architectural sibling): https://github.com/sparfenyuk/mcp-proxy
- Microsoft MCP Gateway: https://github.com/microsoft/mcp-gateway
- Docker MCP Gateway: https://github.com/docker/mcp-gateway
- IBM ContextForge LB feature request: https://github.com/IBM/mcp-context-forge/issues/293
- aviciot/mcp_gateway (Traefik + Compose scale approach): https://github.com/aviciot/mcp_gateway
- FastMCP asyncio blocking (motivating bug): https://github.com/modelcontextprotocol/python-sdk/issues/1839

### Prior art on pool/replica patterns

- Kubernetes Deployment replicas: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- PHP-FPM pool configuration: https://www.php.net/manual/en/install.fpm.configuration.php
- PgBouncer pooling: https://www.pgbouncer.org/config.html
- Envoy load balancing: https://gateway.envoyproxy.io/docs/tasks/traffic/load-balancing/

### Gridctl internals

- Full feature evaluation: `~/code/prompt-stack/prompts/gridctl/mcp-server-replicas/feature-evaluation.md`
- Fork workflow guidance: `~/.claude/CLAUDE.md` (Fork-and-Pull Workflow section)
- Project memory: `~/.claude/projects/-Users-william-code-gridctl/memory/MEMORY.md`

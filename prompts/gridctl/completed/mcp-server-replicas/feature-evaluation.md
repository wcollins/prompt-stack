# Feature Evaluation: MCP Server Replicas

**Date**: 2026-04-18
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High (for the target audience)
**Effort**: Large

## Summary

Add a `replicas: N` field to `mcp-servers` entries in `stack.yaml` that spawns N
independent processes per stdio-based MCP server and load-balances JSON-RPC
requests across them. This solves real, widely-reported concurrency pain in
multi-user deployments (asyncio head-of-line blocking in third-party MCP servers,
single-process crashes taking out the server for all users) that cannot be fixed
inside gridctl alone. No mainstream MCP gateway ships this capability today, so
shipping a tight v1 puts gridctl ahead of Docker/Microsoft/sparfenyuk/ContextForge
on this axis. Build, but scope v1 to static replicas with round-robin, defer
session affinity and autoscaling.

## The Idea

Add an integer `replicas: N` field to each `mcp-servers[]` entry. When set,
gridctl spawns N independent processes for that server and load-balances tool
calls across them. Clients see one logical server with one tool namespace —
replicas are a gridctl-internal detail. Default `replicas: 1` (current behavior,
fully backward compatible).

**Problem it solves**: Today, one stdio process per MCP server is a three-headed
liability for multi-user deployments:

1. **Head-of-line blocking** — many community MCP servers run sync code on a
   single asyncio event loop. A 30-second SSH tool call blocks every other user's
   request on that server. See FastMCP #1839 as the canonical instance.
2. **Single point of failure** — one unhandled exception or OOM takes the server
   out for everyone until gridctl restarts it.
3. **No horizontal scaling path** — the only existing workaround is duplicating
   the server entry under a new name, which breaks the prefixed tool namespace
   clients depend on (`junos__get_router_list` vs `junos2__get_router_list`).

**Who benefits**: Operators running gridctl in multi-user / stackless mode with
stdio MCP servers (local-process or container-stdio). This is a narrower slice of
gridctl's audience than the single-user desktop case, but they hit the problem
hard and have no alternative.

## Project Context

### Current State

gridctl orchestrates MCP servers declared in `stack.yaml` across five transports
(container, local process, SSH, external HTTP, OpenAPI). Stackless mode (loading
a stack via API post-daemon-start) is an active development axis — recent commits
(`723d290`, `fee5fc4`, `eeea446`, `12977cd`, `09af2c9`) show continued investment
in multi-user deployment ergonomics.

### Integration Surface

The router (`pkg/mcp/router.go`) keys on server name as a strict 1:1 map. The
gateway (`pkg/mcp/gateway.go`) registers one `AgentClient` per name and routes
each tool call through `Router.RouteToolCall()`. ProcessClient
(`pkg/mcp/process.go`) already serializes stdio access with `procMu` and
demultiplexes responses via a `map[int64]chan *Response`. Health monitoring,
reconnect, and per-server metrics already exist — the scaffolding for
replica-aware health is in place.

### Reusable Components

- **Per-request channel demux in ProcessClient** — the pattern for multiple
  concurrent callers against a single stdio server already exists. A replica is
  just "N of these, picked by a policy."
- **Health monitor with reconnect** (`gateway.go:373` `StartHealthMonitor`) —
  already periodic, already per-server. Needs to iterate replicas instead of
  serverName.
- **Metrics accumulator** (`pkg/metrics/accumulator.go`) — already per-server
  atomic counters. Adding a `replica_id` dimension is straightforward.
- **Wizard FieldVisibility gating** (`web/src/components/wizard/steps/MCPServerForm.tsx`)
  — already conditionally shows fields by server type. Drop-in for gating
  `replicas` to stdio-class transports.
- **Structured SpecHealth API** (`pkg/config/health.go`, served via
  `/api/stack/health`) — natural host for per-replica health breakdown.

## Market Analysis

### Competitive Landscape

No mainstream MCP gateway ships `replicas: N` as a declarative per-server field:

- **Microsoft mcp-gateway** — scales the gateway itself via Kubernetes StatefulSet,
  not the stdio child; uses session affinity to pin to backend pods.
- **Docker MCP Gateway** — relies on `docker compose --scale` which operates on
  whole services, not per-server declarative config.
- **sparfenyuk/mcp-proxy** — the closest architectural sibling; explicitly spawns
  one subprocess per named server and documents isolation. No replicas field.
- **IBM ContextForge** — issue #293 requests round-robin / least-connections /
  weighted RR across redundant MCP servers. Filed, not shipped.
- **aviciot/mcp_gateway** — relies on external Traefik + Compose `--scale`; not a
  declarative per-server field.

### Market Positioning

**Differentiator, bordering on table-stakes for any gateway targeting multi-user
deployments of stdio servers.** The MCP ecosystem's preferred long-term answer is
"migrate to stateless Streamable HTTP and scale at the HTTP tier" — which doesn't
help operators running the long tail of community stdio-only servers (npm/pip
packages, desktop-style configs). Replicas is a pragmatic bridge.

### Ecosystem Support

Replica/worker pools in front of stdio-ish or single-threaded backends is the
dominant industry pattern for this exact problem:

- PHP-FPM (`pm = static|dynamic|ondemand`, `pm.max_children`)
- Gunicorn / Unicorn / uWSGI pre-fork workers
- pgbouncer connection pools, typically fronted by HAProxy
- gRPC subchannel pools, Envoy load balancers
- Kubernetes Deployment `replicas`, Docker Swarm service `replicas`, Nomad `count`

"replicas" is the overwhelming field-name convention (only Nomad uses `count`).
Round-robin is the default dispatch policy; least-connections is the common
override when request latencies are skewed. Session affinity is used only when
state forces it.

### Demand Signals

Real, widely-reported pain with concrete upstream references:

- **FastMCP python-sdk #1839** — sync tools run on asyncio loop; one blocking
  call freezes all in-flight requests. Exactly the submitter's motivation.
- **modelcontextprotocol/php-sdk #275** — concurrent requests race on session
  state.
- **agent0ai/agent-zero #912** — multi-session stdio deadlock; proposed fix is
  literally "spawn isolated instances per active session."
- **chrome-devtools-mcp #926** — multi-session parallel browser instances request.
- **n8n-io/n8n #15710** — parallel MCP tool calls fail due to server
  serialization.

Multiple blog posts (mcpcat, Arsturn, byteplus, dasroot, mcpmanager) confirm the
ecosystem-wide perception that "stdio is single-user, cannot handle true
concurrency."

### Timing

Shipping now maximizes the differentiation window. The MCP spec's long-term
answer (Streamable HTTP statelessness) is still nascent, and the stdio server
long tail will persist for years — so the pragmatic workaround has meaningful
staying power even as the spec evolves.

## User Experience

### Interaction Model

- Single integer field `replicas: N` on `mcp-servers[]` entries, default 1.
- Transparent to MCP clients: all replicas serve the same prefixed tool namespace
  (`junos__get_router_list`). This is what separates replicas from the broken
  duplicate-entry workaround.
- Round-robin dispatch by default.
- Transport gating: allow on container, local-process, and SSH transports. Reject
  with a clear validation error on `external` and `openapi` (where replicas are
  meaningless).

### Workflow Impact

- **Backward compatible**: `replicas: 1` (default, unspecified) is a no-op.
  Existing stacks unchanged.
- **Mental model shift**: one server = one pool of N processes. Well understood
  from k8s/Compose by the target audience.
- **Debugging requires replica-tagged logs** — non-negotiable. Without
  `replica_id` in every log line and trace span, concurrency debugging is
  strictly harder than the single-process case.

### UX Recommendations

1. Field name `replicas: N` (matches k8s/Compose/Swarm convention).
2. Round-robin default. Document `replica_policy: least-connections` as an
   available option in v1 — it's worth shipping immediately because the
   submitter's motivating workload (30s SSH calls mixed with fast calls) is
   exactly where least-connections outperforms RR.
3. `gridctl status` shows rolled-up replica health by default (`3/3 healthy`);
   `--replicas` or `gridctl status <server> --detail` expands to per-replica rows.
4. `/api/stack/health` response includes per-replica breakdown.
5. Wizard: numeric input, gated on transport type via existing `FieldVisibility`.
6. Web UI graph/canvas: subtle `×3` badge on nodes with replicas > 1; full
   per-replica breakdown in a side panel on click (deferrable to follow-up PR).
7. **Crash-restart backoff (exponential, capped) is a prereq**, not a nice-to-have.
8. Session affinity as explicit opt-in only — default off. Documented as a
   concurrency trap.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Real, widely-reported concurrency pain with upstream issues in multiple SDKs; can't be fixed by improving gridctl alone. |
| User impact | Narrow + Deep | Multi-user stdio-server operators — smaller slice of audience, but they hit it hard with no workaround. |
| Strategic alignment | Core mission | gridctl is the orchestration/configuration layer for MCP; solving what the protocol doesn't is core. |
| Market positioning | Leap ahead | No mainstream gateway ships this as declarative per-server config. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Significant | Router, gateway registration, health monitor, restart logic, runtime workload orchestration, metrics, traces, wizard, CLI status. ~15+ files across `pkg/mcp`, `pkg/runtime`, `pkg/config`, `cmd/gridctl`, `web/src`. |
| Effort estimate | Large | 2-3 weeks focused work for a solid v1. |
| Risk level | Medium | Concurrency bugs hide in load balancers. Standard prior art mitigates; no data-loss or security surface. |
| Maintenance burden | Moderate | Transport-specific replica semantics are permanent surface area; balanced by a small, well-tested pool abstraction. |

## Recommendation

**Build with caveats.** Ship a tight v1 with the following scope:

**v1 in scope**:
- `replicas: N` field on `mcp-servers[]` entries (default 1).
- Round-robin dispatch policy.
- `replica_policy` field accepting `round-robin` (default) and `least-connections`
  — both shipped in v1 because the motivating workload benefits from LC immediately.
- Per-replica process isolation with unique container names / workload IDs.
- Crash-restart with exponential backoff (cap e.g. 30s). Backoff is a prerequisite.
- Per-replica health tracked in gateway, surfaced in `gridctl status` and
  `/api/stack/health`.
- Logs and traces tagged with `replica_id`. Non-negotiable.
- Wizard numeric input gated by transport type.
- Integration tests: kill-one-replica, restart-storm, all-replicas-down, mixed
  replica count across servers.
- Validation: reject `replicas > 1` on `external` and `openapi` transports with a
  clear error.

**Explicitly deferred to v2+**:
- Session affinity (`session_affinity: true` per server).
- Per-replica resource limits (memory/CPU).
- Autoscaling based on queue depth or active session count.
- Web UI per-replica drill-down panel (CLI + API is sufficient for v1; badge on
  canvas node is a small follow-up PR).

**Why the caveats matter**:
1. Restart backoff is a hard prereq — gridctl has none today, and replicas
   without it will turn the first crashing binary into a CPU-spinning log-spam
   incident.
2. Transport gating avoids user confusion about what replicas means for HTTP-only
   servers.
3. Log tagging is the difference between replicas being an operational win and
   being a regression for debuggability.
4. Scoping out autoscaling and session affinity prevents the v1 from becoming a
   multi-month project. Those are independently valuable but can be added in
   follow-ups once the static-replica foundation is proven.

## References

- Microsoft MCP Gateway: https://github.com/microsoft/mcp-gateway
- Docker MCP Gateway: https://github.com/docker/mcp-gateway
- Docker MCP docs: https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/
- IBM ContextForge: https://github.com/IBM/mcp-context-forge
- ContextForge LB feature request: https://github.com/IBM/mcp-context-forge/issues/293
- sparfenyuk/mcp-proxy: https://github.com/sparfenyuk/mcp-proxy
- aviciot/mcp_gateway: https://github.com/aviciot/mcp_gateway
- RaiAnsar/mcp-gateway: https://github.com/RaiAnsar/mcp-gateway
- MCP spec 2025-11-25: https://modelcontextprotocol.io/specification/2025-11-25
- MCP transports: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- MCP "Future of Transports" (Dec 2025): https://blog.modelcontextprotocol.io/posts/2025-12-19-mcp-transport-future/
- MCP discussion #102 (state, long-lived connections): https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/102
- FastMCP asyncio blocking: https://github.com/modelcontextprotocol/python-sdk/issues/1839
- PHP SDK concurrent-session race: https://github.com/modelcontextprotocol/php-sdk/issues/275
- Agent-Zero multi-session deadlock: https://github.com/agent0ai/agent-zero/issues/912
- chrome-devtools-mcp multi-session: https://github.com/ChromeDevTools/chrome-devtools-mcp/issues/926
- n8n parallel MCP tool calls bug: https://github.com/n8n-io/n8n/issues/15710
- MCPcat multi-connection guide: https://mcpcat.io/guides/configuring-mcp-servers-multiple-simultaneous-connections/
- MCPcat StreamableHTTP scaling: https://mcpcat.io/guides/setting-up-streamablehttp-scalable-deployments/
- Zhimin Wen, Scaling Streamable MCP on K8s: https://zhimin-wen.medium.com/scaling-http-streamable-mcp-servers-on-kubernetes-handling-sticky-sessions-24212857c8ca
- The New Stack, Load Balancing Streamable MCP: https://thenewstack.io/scaling-ai-interactions-how-to-load-balance-streamable-mcp/
- WorkOS MCP Async Tasks: https://workos.com/blog/mcp-async-tasks-ai-agent-workflows
- PHP-FPM config: https://www.php.net/manual/en/install.fpm.configuration.php
- PgBouncer config: https://www.pgbouncer.org/config.html
- Kubernetes Deployment replicas: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Envoy Gateway load balancing: https://gateway.envoyproxy.io/docs/tasks/traffic/load-balancing/

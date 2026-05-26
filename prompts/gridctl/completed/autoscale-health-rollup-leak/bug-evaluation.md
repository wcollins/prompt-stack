# Bug Investigation: Autoscale Health Rollup Leak & Misleading Scale-to-Zero State

**Date**: 2026-04-23
**Project**: gridctl
**Recommendation**: Fix with caveats (tiered)
**Severity**: Medium-High
**Fix Complexity**: Small (staged across three phases)

## Summary

Autoscaled MCP servers that scale to zero (e.g., zapier, 102 tools, HTTP) surface as "INITIALIZING + Unhealthy + context deadline exceeded" in the UI and return 503 from `/ready` — even when tool calls still succeed. The symptom is a compound of three defects introduced (or made visible) by the reactive-autoscaling work in PRs #511–#516. Tool dispatch itself is unaffected; this is a state-keeping and observability bug that undermines the credibility of the new autoscaling feature.

## The Bug

The UI displays the affected MCP server node with:
- State: `INITIALIZING` (yellow)
- Health: `Unhealthy` (red)
- Error: `context deadline exceeded`
- Tool count: correct (shown from tool cache)

Discovered via operator observation. The user reports the symptom appears "more often now after the concurrency / replica changes." The recent changes in question are the reactive-autoscaling feature set (PR #512 `abf4f8a`, PR #514 `2ed214c`, PR #515 `b1aac01`, PR #511 `a7dc2bc`, PR #516 `f6b5139`).

Expected behavior: an autoscaled server that has scaled to zero under the `idle_to_zero` policy should render as idle/scaled-to-zero — not as "initializing + unhealthy". The health status of reaped replicas should not persist across their removal.

## Root Cause

This is a **compound bug**. Three independent defects stack up to produce the observed symptom:

### Defect #2 — Stale health rollup never cleared on scale-to-zero (primary contributor)

#### Defect Location
`pkg/mcp/gateway.go:537-578` (`recomputeRollup`)

#### Why It Happens
`recomputeRollup` iterates `set.Replicas()`. When the set is empty (scale-to-zero) it takes the `!sawAny` branch at line 565 and returns without touching `g.health[serverName]`. The map entry from the last health cycle — typically an error like "context deadline exceeded" — persists forever. There is no `delete(g.health, serverName)` or `delete(g.replicaHealth, serverName)` anywhere in the codebase (grep confirmed zero matches).

#### Code Path
```
ticker (30s) → Gateway.checkHealth(ctx) → for each ReplicaSet:
  for each replica: checkReplicaHealth(...)     // iterates empty slice after reap
  recomputeRollup(name, set)                    // sawAny=false → early return
                                                // g.health[name] retains stale error
```

### Defect #3 — `Initialized=false` for correctly-idle autoscaled servers

#### Defect Location
`pkg/mcp/gateway.go:1816` — `Initialized: client != nil && client.IsInitialized()`
`web/src/lib/graph/nodes.ts:15-24` — UI maps `!server.initialized` → `'initializing'`

#### Why It Happens
`Router.Clients()` (`pkg/mcp/router.go:85-100`) returns only non-nil clients. A scale-to-zero replica set has no client. `Status()` therefore assigns a nil client to `clientByName[name]` and computes `Initialized=false`. The UI treats that as the "initializing" state, which conflates "first boot, not ready yet" with "deliberately idle under autoscale policy."

### Defect #1 — Hard-coded 5s ping timeout is the originating flake

#### Defect Location
`pkg/mcp/types.go:106` — `DefaultPingTimeout = 5 * time.Second`
Applied via `context.WithTimeout(ctx, DefaultPingTimeout)` in:
- `pkg/mcp/client.go:192`
- `pkg/mcp/openapi_client.go:315`
- `pkg/mcp/process.go:357`
- `pkg/mcp/stdio.go:303`

#### Why It Happens
A 5-second budget for a HEAD/GET against an HTTP MCP upstream is occasionally too tight — especially against a busy remote like Zapier while the autoscaler is concurrently running `Initialize` + `RefreshTools` traffic for newly spawned replicas. Go's `http.Transport` default `MaxIdleConnsPerHost: 2` further tightens the envelope under concurrent load. Without Defects #2 and #3, a single timeout would self-correct on the next tick; with them, it sticks forever once scale-to-zero happens.

### Similar Instances

- `g.replicaHealth[serverName][id]` entries for reaped replicas also leak indefinitely (same root cause: no cleanup on reap). This is a memory leak rather than a visible bug.
- Any transient disconnect that ends in scale-to-zero hits the same trap (not autoscale-specific, but autoscaling is the most common trigger).

## Impact

### Severity Classification
Medium-High. Incorrect behavior / observability leak, not a crash or data loss. Functional impact on `/ready` is real but narrow (gridctl is local-first). UI credibility impact is the main cost.

### User Reach
Today: small. Autoscale requires opt-in YAML (`idle_to_zero: true`, `min: 0`) — default configs use static replicas. Only one example in `examples/autoscale/autoscale-basic.yaml` exercises the path. No GitHub issues or CHANGELOG mentions of this symptom.

Forward-looking: the feature is the headline of the last five merged PRs. Adoption will grow; the noise will scale with it.

### Workflow Impact
- **Tool calls**: unaffected. `Router.RouteToolCallReplica` at `pkg/mcp/router.go:181-209` never consults `g.health`; it dispatches via `set.Pick()`.
- **`/api/status`**: exposes stale `HealthError` to any external consumer (`internal/api/api.go:440`, originating at `pkg/mcp/gateway.go:1836`).
- **`/ready`**: returns 503 whenever any server has scaled to zero (`internal/api/api.go:796-801`). Breaks orchestrator readiness checks if anyone runs gridctl under one.
- **UI**: the most visible surface — a scary red banner for a correctly-idle server.

### Workarounds
1. Set `min: 1` in autoscale config. Kills scale-to-zero entirely, avoiding the trap. Cheapest and most effective.
2. Disable autoscale, use static `replicas: N`.
3. Ignore the banner — tool calls still work.
4. `gridctl destroy && gridctl apply` clears in-memory state.
5. **Not available**: raising the ping timeout. It's hard-coded with no config override.

### Urgency Signals
No prior user reports. No active incident. The urgency is driven by "don't ship a broken health UI in a beta release that's showcasing autoscaling," not by external pressure.

## Reproduction

### Minimum Reproduction Steps (defects #2 and #3 — deterministic)
1. Configure an MCP server with:
   ```yaml
   autoscale:
     min: 0
     idle_to_zero: true
     scale_down_after: 30s   # shorten from default for fast repro
   ```
2. Start gridctl; observe the server initialize and become healthy.
3. Issue one tool call, then stop all traffic.
4. Wait past `scale_down_after`. Next autoscaler tick at `pkg/mcp/autoscaler.go:335-340` reaps the last replica.
5. Within the next 30s health check, `recomputeRollup` runs with an empty set and takes the early-return branch at `gateway.go:565`.
6. Observe `/api/status` returning stale `HealthError` and `Initialized=false`. UI shows INITIALIZING + Unhealthy.

### Minimum Reproduction Steps (defect #1 — probabilistic)
Use the existing `slowMCPServer(t, 6*time.Second)` helper at `pkg/mcp/gateway_test.go:2780` in a unit test; real-world reproduction requires a slow upstream under sustained autoscale churn.

### Affected Environments
All platforms (macOS, Linux, Docker, process spawner). All transports for defects #2 and #3. HTTP / OpenAPI for defect #1 most visibly.

### Non-Affected Environments
- Static-replica servers (never hit scale-to-zero).
- Autoscaled servers with `min >= 1` (same reason).
- Tool dispatch itself (routing doesn't consult the stale state).

### Failure Mode
- Defect #2: state persists until a future replica produces new health data. If the server stays at zero, the error is permanent.
- Defect #3: auto-recovers when a cold-start spawns a replica; re-appears on the next scale-to-zero.
- Defect #1: transient on its own; made sticky by #2.

## Fix Assessment

### Fix Surface

| Defect | Files |
|---|---|
| #2 | `pkg/mcp/gateway.go` (`recomputeRollup`), new test in `pkg/mcp/gateway_test.go` |
| #3 | `web/src/types/index.ts`, `web/src/lib/graph/nodes.ts`, `web/src/components/ui/Badge.tsx`, `web/src/components/ui/StatusDot.tsx`. **No backend changes** — `status.Replicas` and `status.Autoscale` are already exposed. |
| #1 | `pkg/config/types.go` (add `PingTimeout` to `MCPServerConfig` or similar), plumb through constructors in `pkg/mcp/client.go`, `pkg/mcp/openapi_client.go`, `pkg/mcp/process.go`, `pkg/mcp/stdio.go`. Fallback to `DefaultPingTimeout`. New test using `slowMCPServer`. |

### Risk Factors
- **Defect #2**: near zero — the fix is additive cleanup in a narrow branch. Symmetric deletion of `g.replicaHealth[serverName]` should happen in the same branch to avoid a slow memory leak.
- **Defect #3**: low-medium — introduces a new UI state (`idle`). Must add styling + ensure the Badge / StatusDot / filters that currently switch on `NodeStatus` handle it. No backend API change lowers the blast radius considerably.
- **Defect #1**: medium — config schema change is additive (backwards compatible), but a band-aid for a symptom. Real root-cause (HTTP connection pool pressure, upstream rate-limit) is unresolved.

### Regression Test Outline
- **#2**: unit test next to existing health tests in `pkg/mcp/gateway_test.go`. Seed `g.health[name]` + `g.replicaHealth[name]`, remove all replicas, call `recomputeRollup`, assert both maps are clear.
- **#3**: frontend unit test on `getMCPServerStatus` in `web/src/lib/graph/nodes.ts`. Given `autoscale != null && replicas.length === 0`, expect `'idle'`.
- **#1**: unit test using `slowMCPServer(t, 6*time.Second)`, override `PingTimeout` to 1s, assert the error wraps `context.DeadlineExceeded`.

## Recommendation

**Fix with caveats — tiered execution in one PR, explicit phases.**

The user requested a single prompt covering all three defects, executed in phases. Phases in priority order:

**Phase A (must-ship in beta.7) — Defect #2**
Smallest change, largest leverage. Turns the permanent banner into a one-cycle flap that self-corrects. Cleans the memory leak of orphan `replicaHealth` entries along the way. Risk is near-zero.

**Phase B (should-ship in beta.7) — Defect #3**
Frontend-only change. Adds an `idle` UI state. Scaled-to-zero autoscaled servers render correctly; first-boot servers still correctly render as `initializing`. No backend contract change required.

**Phase C (include if scope allows) — Defect #1**
Add a per-server `ping_timeout` config knob falling back to `DefaultPingTimeout`. Band-aid, not root-cause; may mask a connection-pool tuning issue worth investigating separately. If Phase C runs long, ship Phases A+B and file a follow-up issue for "investigate Ping latency under autoscale spawn load" (recommended regardless — measure first).

`/ready` fix falls out of Phase B for free: once `Initialized` reads are gated by the UI / caller layer through the new `idle` semantics, the `/ready` handler at `internal/api/api.go:796-801` should also be updated to treat idle-autoscaled servers as ready (they can cold-start on demand). Note this in the fix prompt.

## References

- Recent PRs: #511 (`a7dc2bc`), #512 (`abf4f8a`), #514 (`2ed214c`), #515 (`b1aac01`), #516 (`f6b5139`).
- Key files verified:
  - `pkg/mcp/gateway.go:379-508` (health loop)
  - `pkg/mcp/gateway.go:537-578` (`recomputeRollup` — defect #2)
  - `pkg/mcp/gateway.go:1744-1852` (`Status` — defect #3 origin)
  - `pkg/mcp/types.go:105-106` (defect #1 constant)
  - `pkg/mcp/autoscaler.go:36,335-340,435-527` (autoscale scaling)
  - `pkg/mcp/router.go:62-100` (why `client==nil` at scale-to-zero)
  - `internal/api/api.go:796-801` (`/ready` probe)
  - `web/src/lib/graph/nodes.ts:15-24` (UI state mapping)
  - `web/src/types/index.ts:166` (NodeStatus union)
- No upstream MCP protocol constraint on ping semantics; 5s is a gridctl choice.

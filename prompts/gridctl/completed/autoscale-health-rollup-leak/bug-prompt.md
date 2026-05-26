# Bug Fix: Autoscale Health Rollup Leak & Misleading Scale-to-Zero State

## Context

gridctl is a Go CLI that runs an MCP (Model Context Protocol) gateway, aggregating multiple downstream MCP servers into a single endpoint for coding agents (Claude Code, Gemini CLI, etc.). Current version: `v0.1.0-beta.6`. The gateway is local-first and single-user.

Recent work (PRs #511–#516) added reactive autoscaling on top of an MCP ReplicaSet primitive, including a wizard UI and status observability. The core lifecycle types are:
- `Gateway` (`pkg/mcp/gateway.go`) — aggregates `Router`, `ReplicaSet`s, autoscalers, health state, and the `Status()` surface consumed by the web UI.
- `Router` (`pkg/mcp/router.go`) — name → `ReplicaSet`, dispatches tool calls.
- `ReplicaSet` (`pkg/mcp/replica_set.go`) — pool of `*Replica`; `set.Client()` returns nil when the pool is empty (scale-to-zero).
- `Autoscaler` (`pkg/mcp/autoscaler.go`) — per-server tick loop; reaps replicas to zero under `idle_to_zero` policy.
- Health monitor (`pkg/mcp/gateway.go:379-508`) — `StartHealthMonitor` → `checkHealth` → `checkReplicaHealth` → `Ping` → `recomputeRollup`.

Frontend is TypeScript / React in `web/src/`. MCP server status is rendered as nodes on a React Flow canvas. The Go→TS status contract is defined by `MCPServerStatus` (`pkg/mcp/gateway.go:1616`) on the backend and `MCPServerStatus` (`web/src/types/index.ts`) on the frontend.

Tool preferences: `rg` over `grep`, `fd` over `find`. Commit style: Conventional Commits, imperative mood, signed. No Claude attribution.

## Investigation Context

Full investigation: `prompts/gridctl/autoscale-health-rollup-leak/bug-evaluation.md`.

Three compounding defects cause the symptom "autoscaled MCP server shows INITIALIZING + Unhealthy + context deadline exceeded" even when tool calls succeed:

1. **Defect #2 (primary):** `recomputeRollup` (`pkg/mcp/gateway.go:537-578`) never clears `g.health[serverName]` on scale-to-zero. `delete(g.health, …)` and `delete(g.replicaHealth, …)` do not exist anywhere in the repo. One bad ping before a reap → error shown forever.

2. **Defect #3:** `Initialized = client != nil && client.IsInitialized()` (`pkg/mcp/gateway.go:1816`). For autoscaled scale-to-zero, `client==nil` → `Initialized=false`. The web UI (`web/src/lib/graph/nodes.ts:15-24`) maps `!initialized → 'initializing'`, conflating "first boot" with "deliberately idle."

3. **Defect #1:** `DefaultPingTimeout = 5s` at `pkg/mcp/types.go:106` is hard-coded and not configurable. Under autoscale spawn activity against a slow upstream (e.g., zapier, 102 tools, HTTP), real Ping HEAD/GET calls can exceed 5s. Defects #2 and #3 make one flake look permanent.

The fix is staged in three phases (A, B, C). **Execute phases sequentially, one commit per phase, on a single feature branch.** Do not bundle phases in one commit — reviewers should be able to revert Phase C independently if it causes issues. Phase A is required; Phase B is required; Phase C is desired but can be dropped if tests uncover unexpected coupling.

Reproduction confirmed deterministic for #2 and #3 given:
```yaml
autoscale: { min: 0, idle_to_zero: true, scale_down_after: 30s }
```

Tool routing itself is unaffected (verified at `pkg/mcp/router.go:181-209`, which never reads `g.health`).

## Bug Description

**Observed:** An autoscaled MCP server that has scaled to zero under `idle_to_zero` displays in the UI as:
- State: `INITIALIZING` (yellow)
- Health: `Unhealthy` (red)
- Error: `context deadline exceeded`

Tool calls still succeed via cold-start. `/ready` returns 503. The banner persists until gridctl is restarted.

**Expected:** A scaled-to-zero autoscaled server should render as `idle` (new UI state), not as "initializing + unhealthy." Its prior health error should not persist after the last replica is reaped. The Ping timeout should be tunable for slow upstreams.

**Affected users:** Anyone using `autoscale: { idle_to_zero: true, min: 0 }`. Currently opt-in. The feature landed in beta.6; no prior user reports.

## Root Cause

### Defect #2 — stale health rollup

`pkg/mcp/gateway.go:537-578`:
```go
func (g *Gateway) recomputeRollup(serverName string, set *ReplicaSet) {
    g.healthMu.Lock()
    defer g.healthMu.Unlock()

    anyHealthy := false
    sawAny := false
    // ... iterate set.Replicas() ...

    // Non-pingable replicas produce no status; don't fabricate a rollup for them.
    if !sawAny {
        return     // ← BUG: stale g.health[serverName] persists forever on scale-to-zero
    }
    // ... write rollup ...
}
```

The replica-level map `g.replicaHealth[serverName][id]` also accumulates entries for reaped IDs that are never cleaned up. Replica IDs are monotonic (`pkg/controller/spawn_container.go:113`: `c.idCounter.Add(1) - 1`), so old entries are dead weight.

### Defect #3 — Initialized semantics

`pkg/mcp/gateway.go:1744-1852` (`Status()`). At line 1760, `routerClients := g.router.Clients()` filters out zero-replica sets (`router.go:95`: `if c := r.sets[n].Client(); c != nil`). At line 1788, `client := clientByName[name]` is nil for autoscaled-to-zero servers. At line 1816, `Initialized: client != nil && client.IsInitialized()` evaluates to false.

The `MCPServerStatus` response already contains `Autoscale *AutoscaleStatus` (line 1647) and `Replicas []ReplicaStatus` (line 1642). The UI has everything it needs to infer the "idle" state without any backend change.

### Defect #1 — hard-coded ping timeout

`pkg/mcp/types.go:106`:
```go
const DefaultPingTimeout = 5 * time.Second
```

Used directly (not via any configurable indirection) at:
- `pkg/mcp/client.go:192`
- `pkg/mcp/openapi_client.go:315`
- `pkg/mcp/process.go:357`
- `pkg/mcp/stdio.go:303`

## Fix Requirements

### Phase A — Defect #2 (required, ship first)

#### Required Changes
1. In `pkg/mcp/gateway.go:537-578`, modify the `!sawAny` branch in `recomputeRollup` to clear both map entries before returning:
   ```go
   if !sawAny {
       delete(g.health, serverName)
       delete(g.replicaHealth, serverName)
       return
   }
   ```
2. Add a regression unit test in `pkg/mcp/gateway_test.go` that:
   - Seeds `g.health[name]` with an unhealthy rollup and `g.replicaHealth[name][0]` with an error.
   - Removes all replicas from the set.
   - Calls `recomputeRollup(name, set)`.
   - Asserts both `g.health[name]` and `g.replicaHealth[name]` are absent (use `_, ok := …` on both maps with `g.healthMu.RLock()` held).

#### Constraints
- Do not change `recomputeRollup`'s behavior for non-empty sets or for the "all replicas non-pingable" case beyond the delete. Non-pingable sets never wrote to `g.health[serverName]` in the first place, so `delete` is a no-op there (safe).
- Do not move the lock acquisition. Keep the existing `healthMu.Lock() / defer Unlock()`.
- Do not introduce a new helper unless the second-level cleanup (replicaHealth) grows beyond a single `delete` call.

#### Out of Scope
- Clearing `replicaHealth[name][id]` at reap time. Cleanup-on-rollup is sufficient for this phase; per-reap cleanup is a future enhancement.

### Phase B — Defect #3 (required, ship second)

#### Required Changes
All changes are frontend-only.

1. Add `'idle'` to the `NodeStatus` union in `web/src/types/index.ts:166`:
   ```ts
   export type NodeStatus = 'running' | 'stopped' | 'error' | 'initializing' | 'idle';
   ```
2. Update `getMCPServerStatus` in `web/src/lib/graph/nodes.ts:15-24`:
   ```ts
   function getMCPServerStatus(server: MCPServerStatus): NodeStatus {
     // Autoscaled server currently at zero replicas: deliberately idle, not initializing.
     if (server.autoscale && (!server.replicas || server.replicas.length === 0)) {
       return 'idle';
     }
     if (!server.initialized) {
       return 'initializing';
     }
     if (server.healthy === false) {
       return 'error';
     }
     return 'running';
   }
   ```
   Order matters: the `idle` check must precede the `!initialized` check (since `Initialized` is false for scale-to-zero today).
3. Add style entries for `'idle'` in:
   - `web/src/components/ui/Badge.tsx:15` (palette row) and line 35 (pulse rule — do NOT pulse for idle; use a steady dim color).
   - `web/src/components/ui/StatusDot.tsx:13` (dot color — steady, non-pulsing, muted).
   Use existing design tokens. Pick a neutral/muted color distinct from both `status-pending` (amber, used for initializing) and `status-ok` (green, used for running). A dimmed grey or cool blue is appropriate — match whatever semantic token the app already reserves for "idle / standby" if one exists; otherwise introduce one alongside the existing ones.
4. Update the `/ready` handler at `internal/api/api.go:796-801` to treat idle autoscaled servers as ready. They can cold-start on demand; they are not in a failed state. Check condition: if `status.Autoscale != nil && len(status.Replicas) == 0`, skip the `!Initialized` rejection for that server. Add a unit test in `internal/api/api_test.go` following the existing `TestHandleReady_*` pattern.
5. Add a frontend unit test for `getMCPServerStatus` covering: initializing (never-booted), running, error (initialized + unhealthy), and the new `idle` (autoscaled + zero replicas). Match whatever Vitest / Jest setup `web/` already uses; do not introduce a new test runner.

#### Constraints
- Do not change any backend JSON shape. `MCPServerStatus`, `Replicas`, and `Autoscale` fields are already emitted; the UI must derive the new state from them.
- Preserve the existing mapping for non-autoscaled and first-boot servers exactly.
- Do not remove the `initializing` state. It is still correct for a server that has never completed its first `Initialize` RPC.

#### Out of Scope
- Renaming or restructuring `MCPServerStatus.Initialized`. The flag's semantics are unchanged; only the UI's interpretation of it changes.
- Visual polish beyond colour selection for the new state (animations, tooltips, filter chips, etc.) — leave those for a follow-up UX pass.

### Phase C — Defect #1 (desired, ship third if scope allows)

#### Required Changes
1. Add a `PingTimeout time.Duration` field to `MCPServerConfig` (`pkg/mcp/gateway.go:~70-100` — find the struct definition; the field should be next to the TLS/endpoint fields). Zero value means "use default."
2. Thread the value into each pingable client constructor:
   - `pkg/mcp/client.go:Client` — add a `pingTimeout` field on the struct and honour it in `Ping`. Fall back to `DefaultPingTimeout` when zero.
   - `pkg/mcp/openapi_client.go:OpenAPIClient` — same treatment.
   - `pkg/mcp/process.go` and `pkg/mcp/stdio.go` — same treatment.
3. In `pkg/controller/gateway_builder.go` (where clients are constructed from config), pass the `PingTimeout` through.
4. Add the field to the YAML config schema (`pkg/config/types.go`) and validation (`pkg/config/validate.go`): parse as a `time.Duration` string (e.g., `"10s"`), reject negative values, default to `""` (unset → library default).
5. Document the knob in `docs/config-schema.md` and `docs/scaling.md`. One-paragraph note: when to tune it (slow upstream, autoscale spawn contention), default rationale.
6. Unit test using the existing `slowMCPServer(t, 6*time.Second)` helper at `pkg/mcp/gateway_test.go:2780`:
   - With default (5s) timeout: assert Ping errors with `context.DeadlineExceeded`.
   - With `PingTimeout: 10*time.Second`: assert Ping succeeds.

#### Constraints
- Keep `DefaultPingTimeout = 5 * time.Second` as the fallback. Do not raise the default.
- Config change must be additive / backwards compatible. Existing YAML must continue to validate without modification.
- Do not add per-transport (HTTP vs stdio) defaults. One knob for all pingable transports is sufficient.

#### Out of Scope
- Root-causing *why* zapier pings occasionally exceed 5s. That investigation (connection-pool tuning, upstream rate limits) is tracked separately — file a follow-up issue "investigate Ping latency under autoscale spawn load" after Phase C lands.
- Making ping interval (not timeout) configurable; existing `DefaultHealthCheckInterval` is already the knob for that.

## Implementation Guidance

### Execution order
1. Branch from `main`: `fix/autoscale-health-rollup-leak` (trunk workflow — see global `CLAUDE.md`).
2. Phase A commit: `fix: clear stale health rollup on scale-to-zero`.
3. Phase B commit: `fix: render autoscaled scale-to-zero as idle`.
4. Phase C commit: `feat: configurable ping_timeout per MCP server`.
5. Run full test suite after each commit (`make test` + `npm test` in `web/`).
6. Open one PR with all three commits. Description should summarise the three phases and reference the investigation report.

### Key Files to Read (in order)
1. `pkg/mcp/gateway.go:537-578` — the bug in `recomputeRollup`.
2. `pkg/mcp/gateway.go:379-508` — health monitor loop + `checkReplicaHealth`, to understand what writes to `g.health` and `g.replicaHealth`.
3. `pkg/mcp/gateway.go:1744-1852` — `Status()` builder, including `Initialized` and `Replicas`/`Autoscale` propagation.
4. `pkg/mcp/router.go:62-100` — `GetClient` and `Clients` semantics at scale-to-zero.
5. `pkg/mcp/autoscaler.go:335-340` — the `idle_to_zero` scale-down path (for reproduction understanding).
6. `web/src/lib/graph/nodes.ts` — the UI state mapping you're modifying.
7. `web/src/types/index.ts` — the `NodeStatus` union and `MCPServerStatus` shape on the frontend.
8. `web/src/components/ui/Badge.tsx` and `StatusDot.tsx` — style entries to mirror for the new state.
9. `internal/api/api.go:779-806` — `/ready` handler to update in Phase B.
10. `pkg/mcp/gateway_test.go` around line 252 (Status tests), line 452-930 (health tests), and line 2780 (`slowMCPServer` helper) — existing test patterns to follow.

### Files to Modify

**Phase A:**
- `pkg/mcp/gateway.go` — `recomputeRollup` (~line 565).
- `pkg/mcp/gateway_test.go` — new `TestGateway_recomputeRollup_ClearsOnEmptySet`.

**Phase B:**
- `web/src/types/index.ts` — `NodeStatus` union (line 166).
- `web/src/lib/graph/nodes.ts` — `getMCPServerStatus` (lines 15-24).
- `web/src/components/ui/Badge.tsx` — add `idle` entry (lines 15, 35).
- `web/src/components/ui/StatusDot.tsx` — add `idle` entry (line 13).
- `internal/api/api.go` — `handleReady` (lines 796-801).
- `internal/api/api_test.go` — new `TestHandleReady_IdleAutoscaled` following line 124/146 patterns.
- New frontend test for `getMCPServerStatus` — location to match existing web/ test layout.

**Phase C:**
- `pkg/mcp/gateway.go` — `MCPServerConfig` struct (add `PingTimeout` field).
- `pkg/mcp/client.go`, `pkg/mcp/openapi_client.go`, `pkg/mcp/process.go`, `pkg/mcp/stdio.go` — honour per-client timeout.
- `pkg/controller/gateway_builder.go` — thread config through.
- `pkg/config/types.go`, `pkg/config/validate.go` — YAML schema + validation.
- `docs/config-schema.md`, `docs/scaling.md` — document the knob.
- `pkg/mcp/gateway_test.go` — new test using `slowMCPServer`.

### Reusable Components
- `slowMCPServer(t, delay)` in `pkg/mcp/gateway_test.go:2780` — perfect for Phase C.
- Existing `TestHandleReady_*` pattern in `internal/api/api_test.go` — use for the Phase B `/ready` test.
- Existing health-monitor tests in `pkg/mcp/gateway_test.go:452-930` — use as scaffolding for Phase A's test.
- `AutoscaleStatus` and `ReplicaStatus` types (`pkg/mcp/gateway.go:1642-1647` and mirrors in `web/src/types/index.ts`) already expose everything Phase B needs.

### Conventions to Follow
- Go: failing tests use `t.Fatal` when the setup precondition fails; `t.Errorf` for multiple assertions in one test. Locks in tests must be acquired exactly as production code acquires them — use `g.healthMu.RLock()` to read maps.
- Commit messages: Conventional Commits. Max 50 chars subject. Signed with `-S`. No Claude attribution anywhere.
- TypeScript: follow existing `web/` lint rules (`npm run lint`). Prefer named union members over magic strings.
- Config YAML: duration strings via `time.ParseDuration` (e.g., `"10s"`), not numeric seconds.

## Regression Test

### Test Outline — Phase A
```go
func TestGateway_recomputeRollup_ClearsOnEmptySet(t *testing.T) {
    g := NewGateway()
    name := "server1"

    // Seed prior state as if a replica had been unhealthy and then reaped.
    g.healthMu.Lock()
    g.health[name] = &HealthStatus{Healthy: false, Error: "context deadline exceeded"}
    g.replicaHealth[name] = map[int]*HealthStatus{
        0: {Healthy: false, Error: "context deadline exceeded"},
    }
    g.healthMu.Unlock()

    // Empty set simulates scale-to-zero.
    set := NewReplicaSet(name, ReplicaPolicyRoundRobin, nil)
    g.recomputeRollup(name, set)

    g.healthMu.RLock()
    _, hasHealth := g.health[name]
    _, hasReplicaHealth := g.replicaHealth[name]
    g.healthMu.RUnlock()

    if hasHealth {
        t.Error("expected g.health[name] cleared after scale-to-zero; still present")
    }
    if hasReplicaHealth {
        t.Error("expected g.replicaHealth[name] cleared after scale-to-zero; still present")
    }
}
```

### Test Outline — Phase B (Go side, `/ready`)
```go
func TestHandleReady_IdleAutoscaledNotBlocking(t *testing.T) {
    // Build a gateway whose Status() returns one server with:
    //   Initialized=false, Autoscale != nil, Replicas empty
    // handleReady must return 200 OK.
}
```
Construct using the same helper patterns as `TestHandleReady_AllInitialized` (`internal/api/api_test.go:124`) and `TestHandleReady_NotInitialized` (line 146).

### Test Outline — Phase B (frontend)
Vitest/Jest table-driven test for `getMCPServerStatus`:
```ts
it.each([
  ['never booted', { initialized: false, autoscale: null, replicas: [] }, 'initializing'],
  ['idle autoscaled', { initialized: false, autoscale: { ... }, replicas: [] }, 'idle'],
  ['healthy running', { initialized: true, healthy: true, replicas: [/* 1 */] }, 'running'],
  ['initialized but unhealthy', { initialized: true, healthy: false, replicas: [/* 1 */] }, 'error'],
])('%s → %s', (_, input, expected) => {
  expect(getMCPServerStatus(input as MCPServerStatus)).toBe(expected);
});
```

### Test Outline — Phase C
```go
func TestClient_Ping_RespectsConfiguredTimeout(t *testing.T) {
    srv := slowMCPServer(t, 6*time.Second)
    defer srv.Close()

    // Default (5s) ping times out against a 6s server.
    cDefault := NewClient("slow", srv.URL /* zero PingTimeout */)
    if err := cDefault.Ping(context.Background()); !errors.Is(err, context.DeadlineExceeded) {
        t.Fatalf("expected DeadlineExceeded, got %v", err)
    }

    // Configured 10s ping succeeds.
    cTuned := NewClient("slow", srv.URL, WithPingTimeout(10*time.Second))
    if err := cTuned.Ping(context.Background()); err != nil {
        t.Fatalf("expected success with 10s timeout, got %v", err)
    }
}
```
(Adjust constructor signature to match the project's actual `NewClient` shape — it may be a struct literal rather than functional options.)

### Existing Test Patterns
- Health tests: `pkg/mcp/gateway_test.go:452-930`.
- Status tests: `pkg/mcp/gateway_test.go` around line 252.
- `/ready` tests: `internal/api/api_test.go:78-175`.
- Slow-server helper: `pkg/mcp/gateway_test.go:2780` (used at 2794 and 2841).
- Frontend tests: follow the existing `web/` test scaffolding — do not introduce a new runner.

## Potential Pitfalls

- **Lock ordering in Phase A**: `recomputeRollup` already holds `g.healthMu`. Do not call any method inside the delete branch that would re-acquire the same lock (e.g., `GetHealthStatus` — it takes `RLock`). The new `delete` calls are plain map operations; no lock concern.
- **Phase A memory cleanup for individual reaped IDs**: this fix cleans when the set empties. Individual reaps in a partially-scaled-down set will still leak `replicaHealth[name][oldID]` entries until the set fully empties or the process restarts. Acceptable for this fix; note in the PR description that a per-reap cleanup is a possible follow-up but not required.
- **Phase B ordering**: the `idle` check MUST precede `!initialized` in `getMCPServerStatus`. Because today's backend emits `Initialized=false` for scale-to-zero, a reversed order would fall through to `'initializing'` and silently regress the fix.
- **Phase B colour choice**: the UI has semantic tokens for pending/ok/error. Verify whether there's already a "neutral / idle" token; if not, adding one in Phase B is in scope — but keep it to a single token; do not restyle the whole palette.
- **Phase B `/ready` update**: if you skip the `/ready` change, a gridctl instance behind a readiness probe will still flap (503) on scale-to-zero even after the UI looks correct. The `/ready` update is part of Phase B, not optional.
- **Phase C config schema tests**: `pkg/config/validate_test.go` likely has a table-driven validator test. Add the `ping_timeout` parse case to the existing table rather than creating a new test file.
- **Phase C client constructor churn**: `NewClient`, `NewOpenAPIClient`, etc. are called from multiple spots. Verify callers compile before running tests (`go build ./...`).
- **Do not fix in another way**: resist the temptation to raise the default `DefaultPingTimeout` globally. The point of Phase C is per-server tuning, not masking slow upstreams for everyone.

## Acceptance Criteria

Phase A:
1. `recomputeRollup` deletes both `g.health[serverName]` and `g.replicaHealth[serverName]` when `!sawAny`.
2. New unit test passes; it fails on `main` without the fix.
3. `make test` passes; `make lint` passes.
4. No change to behaviour for sets with >= 1 pingable replica.

Phase B:
5. `NodeStatus` union includes `'idle'`.
6. `getMCPServerStatus` returns `'idle'` iff `autoscale != null && replicas.length === 0`, in that precedence order.
7. Badge and StatusDot render a distinct, non-pulsing style for `'idle'`.
8. `/ready` returns 200 when the only not-initialized servers are autoscaled-with-zero-replicas.
9. Frontend and backend tests for the new behaviour pass; both fail on `main` without the fix.

Phase C:
10. `MCPServerConfig.PingTimeout` is honoured by all pingable transports.
11. YAML config accepts `ping_timeout: "10s"`; validation rejects negative values.
12. `DefaultPingTimeout` unchanged at 5s; unset config value falls back to default.
13. Docs updated.
14. Unit test demonstrates per-server override working against `slowMCPServer`.

Integration:
15. Single PR contains three commits, one per phase, each individually reviewable.
16. PR description links to `prompts/gridctl/autoscale-health-rollup-leak/bug-evaluation.md`.
17. Reproduction with `autoscale: { min: 0, idle_to_zero: true, scale_down_after: 30s }` no longer shows INITIALIZING + Unhealthy + context-deadline-exceeded; shows `idle` instead.

## References

- Investigation: `prompts/gridctl/autoscale-health-rollup-leak/bug-evaluation.md`.
- Recent autoscaling PRs that exposed the bug: #511, #512, #514, #515, #516.
- No open GitHub issue as of 2026-04-23.
- Reference implementation for `idle` state styling: align with existing design tokens in `web/src/styles/` or whichever file defines the status palette.

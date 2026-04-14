# Feature Evaluation: Code Mode Sandbox Stdlib Extensions

**Date**: 2026-04-07
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium (phased: Small + Medium + Large)

## Summary

Adding `setTimeout/clearTimeout`, sandboxed `fetch`, and `crypto.randomUUID()` to the goja code mode sandbox would raise the practical ceiling for users writing orchestration workflows in code mode. The three APIs carry very different complexity and risk profiles and must be built in phases. `crypto.randomUUID()` is trivial and risk-free. `setTimeout` requires adopting `goja_nodejs/eventloop` (a non-trivial but well-established Go+goja pattern). `fetch` carries SSRF risk and requires strict mitigations; the "gateway auth context routing" idea in the original proposal should be dropped in favor of a configurable, auditable HTTP client.

## The Idea

**Feature**: Extend the goja sandbox (`pkg/mcp/codemode_sandbox.go`) with three stdlib APIs:
1. `setTimeout(fn, ms)` / `clearTimeout(id)` — delay-based sequencing in polling loops and retry patterns
2. `fetch(url, options)` — outbound HTTP calls from within orchestration code
3. `crypto.randomUUID()` — RFC 4122 v4 UUID generation for idempotency keys

**Problem**: The sandbox currently exposes only `mcp.callTool` and `console.*`. Users writing complex multi-step orchestration workflows in code mode hit this ceiling immediately — polling patterns require delays, retry logic requires exponential backoff, and idempotency requires unique IDs. Without these primitives, users fall back to writing YAML skill workflows, which defeats the "rapid scripting" use case code mode is designed to enable.

**Who benefits**: Code mode power users — primarily AI agents and human engineers writing orchestration logic that fans out across multiple MCP tool calls.

## Project Context

### Current State

The sandbox is implemented in `pkg/mcp/codemode_sandbox.go` (175 lines). Key characteristics:
- Fresh `goja.New()` runtime per execution — no state leakage between calls
- Timeout enforced via `ctx.Done() → vm.Interrupt()` from a watcher goroutine
- Execution model: synchronous `vm.RunString()` — **no event loop**
- Two injected objects: `console` (log capture) and `mcp` (tool calling)
- Native functions registered via `vm.NewObject()` + `Set()` pattern with `goja.FunctionCall` signatures
- Code is pre-transpiled from modern JS to ES2015 via esbuild (`codemode_transpile.go`)
- 64KB code size limit; 30-second default timeout (`DefaultCodeModeTimeout`)

The CodeMode orchestration layer (`codemode.go`) routes through `HandleCallWithScope()`, passing the gateway as a `ToolCaller` interface. Context flows: HTTP Handler → Gateway → CodeMode → Sandbox, with `context.Context` available to all native function closures.

### Integration Surface

Files that need modification for this feature:
- `pkg/mcp/codemode_sandbox.go` — core change: inject new native functions, adopt event loop if setTimeout is added
- `pkg/mcp/codemode_test.go` — add test cases for each new API
- `go.mod` / `go.sum` — add `goja_nodejs` if setTimeout is implemented

Files to read for context:
- `pkg/mcp/codemode_transpile.go` — esbuild ES2015 target constraint
- `pkg/mcp/types.go` — ToolCaller interface, DefaultRequestTimeout
- `pkg/mcp/gateway.go` — gateway auth model (inbound only, not credential proxy)
- `pkg/mcp/openapi_client.go` — per-request response size cap (10MB), content-type validation patterns

### Reusable Components

- Existing native function pattern: `func(call goja.FunctionCall) goja.Value` — all new functions follow this
- Timeout watcher goroutine — can interrupt event loop on context cancellation
- `json.Marshal/Unmarshal` + `vm.ToValue()` pipeline for marshaling Go values to JS
- `vm.NewGoError(err)` — panic model for propagating Go errors as JS exceptions

## Market Analysis

### Competitive Landscape

| Platform | setTimeout | fetch | crypto.randomUUID | Event loop |
|---|---|---|---|---|
| Cloudflare Workers | Yes (request-scoped) | Yes (proxied via Outbound Workers) | Yes | V8 native |
| Deno Deploy | Yes | Yes | Yes | V8 native |
| n8n Code Node | **No** (vm2 blocks it) | **No** (use HTTP Request node) | Via require | No |
| Temporal Workflows | **No** (determinism) | **No** (use Activities) | N/A | No |
| Zapier Code Step | Yes | Yes (Node 18+) | Yes | Node.js |
| k6 (Grafana) | Yes (custom event loop) | No (use k6/http module) | No | Custom (goja-based) |
| gridctl (current) | **No** | **No** | **No** | **No** |

### Market Positioning

- **`crypto.randomUUID()`**: Table-stakes. Ships in Chrome 92+, Firefox 95+, Safari 15.4+, Node 14.17+, all edge runtimes. Any sandbox claiming Web Platform compatibility is expected to expose it.
- **`setTimeout/clearTimeout`**: Differentiator in the goja ecosystem specifically. V8-based runtimes all have it natively; goja-based peers (n8n, Temporal) deliberately omit it due to event loop complexity. The use case in gridctl is specifically `await sleep(ms)` for polling patterns, not timer-driven async architectures.
- **`fetch`**: The industry split here is instructive: V8 runtimes expose raw fetch (with proxy/audit layers); workflow-style sandboxes (n8n, Temporal, k6) deliberately route HTTP through typed abstractions instead. gridctl's `mcp.callTool()` already fills this role for MCP servers. Raw `fetch()` would be additive for calling external APIs not exposed as MCP tools.

### Ecosystem Support

- **goja_nodejs/eventloop** (`github.com/dop251/goja_nodejs`): The canonical reference implementation for setTimeout in goja, maintained by goja's own author (dop251). Used by k6, goja-based projects broadly. The API is `loop.Run(fn)` replacing `vm.RunString()`, with `RunOnLoop()` for goroutine-safe callbacks.
- **olebedev/gojax**: A fetch binding for goja wrapping `net/http`. Requires goja_nodejs event loop. Last updated 2022, not widely maintained — a first-party implementation is preferable.
- **crypto.randomUUID()**: No library needed. Go stdlib `crypto/rand` generates the bytes; `fmt.Sprintf` formats the UUID. ~5 lines.

### Demand Signals

- The original feature request is internally motivated: code mode users hitting the scripting ceiling. The use cases (polling loops, retry with backoff, idempotency keys) are standard orchestration primitives.
- goja issue #17 (fetch support) has ongoing discussion — the community wants it but recognizes it requires an event loop.
- k6's approach (custom event loop + Go-native HTTP module) is the most production-proven reference for goja-based orchestration runtimes.

## User Experience

### Interaction Model

**`crypto.randomUUID()`**
```js
const id = crypto.randomUUID();
const result = mcp.callTool("api", "create_job", { requestId: id });
```
Zero learning curve. Matches browser/Node.js API exactly.

**`setTimeout` / `sleep()`**
```js
// Recommended pattern (if sleep() convenience function is exposed):
await sleep(2000);

// Standard pattern:
await new Promise(r => setTimeout(r, 2000));

// Polling loop:
for (let i = 0; i < 5; i++) {
  const status = mcp.callTool("jobs", "get_status", { id });
  if (status.done) break;
  await sleep(1000);
}
```
Note: `async/await` syntax requires the event loop to drain microtasks. This is a prerequisite for setTimeout to be useful.

**`fetch`**
```js
const resp = await fetch("https://api.example.com/data");
const data = await resp.json();
```
Matches browser fetch API. SSRF mitigations are transparent to users making legitimate external calls; they surface only as errors for blocked URLs.

### Workflow Impact

- `crypto.randomUUID()`: Additive only. Eliminates calls to tools just to get a UUID.
- `setTimeout/sleep()`: Changes the async model — `mcp.callTool()` is currently synchronous/blocking. With the event loop, users can write `await mcp.callTool(...)` but will need to understand that the sandbox drains all pending work before returning.
- `fetch`: Introduces a parallel HTTP path alongside `mcp.callTool()`. Users must understand when to use each: `mcp.callTool()` for MCP servers; `fetch()` for arbitrary external HTTP APIs. This mental model split should be documented in the ExecuteTool description.

### UX Recommendations

1. Expose `sleep(ms)` as a top-level convenience function alongside `setTimeout/clearTimeout`. This is the primary use case and reduces boilerplate.
2. Add `fetch` error messages that distinguish SSRF blocks from network errors: `"fetch blocked: private network addresses are not allowed"`.
3. Update the ExecuteTool MCP tool description to document available globals (`crypto`, `fetch`, `sleep`, `setTimeout`, `clearTimeout`, `console`, `mcp`).
4. Consider naming the new sleep helper `mcp.sleep(ms)` to keep it namespaced and discoverable, rather than a bare global — though a bare global is more idiomatic.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Polling loops and idempotency keys are real, recurring needs in orchestration code |
| User impact | Narrow+Deep | Code mode power users specifically; their workflows are substantially unlocked |
| Strategic alignment | Core mission | Code mode is gridctl's rapid-scripting differentiator; raising its ceiling advances the core value prop |
| Market positioning | Catch up (partial) | V8-based peers have all three; goja-based peers skip them intentionally — gridctl can differentiate within the goja ecosystem |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | `crypto.randomUUID()`: minimal. setTimeout: event loop adoption (execution model change). fetch: SSRF controls + clean HTTP client design |
| Effort estimate | Medium | Phased: Small (crypto) + Medium (setTimeout + event loop) + Large (fetch with security) |
| Risk level | Medium | setTimeout has event loop goroutine leak risks (known, mitigable); fetch has SSRF risk (well-documented, manageable with allowlist-first approach) |
| Maintenance burden | Moderate | Event loop adds surface; fetch's security posture requires ongoing attention if URL controls are configurable |

## Recommendation

**Build with caveats.** The feature is high-value and strategically aligned, but the three APIs must be treated as separate deliverables built in sequence.

**Phase 1 — `crypto.randomUUID()` (Small, Low Risk)**
Implement immediately. No new dependencies. ~5 lines of Go injecting a `crypto` global with `randomUUID()` backed by `crypto/rand`. No execution model changes.

**Phase 2 — `setTimeout/clearTimeout` + `sleep()` (Medium, Medium Risk)**
Adopt `goja_nodejs/eventloop` (`github.com/dop251/goja_nodejs`). Replace `vm.RunString()` with `loop.Run()`. The existing timeout watcher goroutine (ctx.Done() → vm.Interrupt()) continues to work; interrupt propagates into the event loop correctly. Add `sleep(ms)` as a top-level convenience function. Follow k6's event loop integration pattern, not an ad-hoc implementation. Key risk: goroutine leaks if timers fire after sandbox exits — mitigate with explicit timer cancellation on context cancellation.

**Phase 3 — `fetch` (Large, Medium-High Risk)**
Drop the "gateway auth context routing" design. Implement as a clean `net/http` client binding with:
- HTTPS-only by default (configurable)
- RFC 1918 + loopback IP blocklist enforced at the dial level (not DNS level) to prevent DNS rebinding
- Configurable URL allowlist (operator-defined, defaults to block private ranges only)
- 1MB response size cap (configurable)
- Per-request timeout defaulting to 10s
- Structured audit logging of all outbound URLs with sandbox identity

Do NOT route through gateway inbound auth credentials — the gateway's auth is for validating callers, not for injecting credentials into arbitrary outbound requests. Per-server auth for MCP servers is already handled by `mcp.callTool()`.

**What to defer**: `setInterval/clearInterval` (leak risk outweighs use cases; polling loops are better served by explicit loops + sleep), Promises wrapping mcp.callTool (future work after event loop is stable).

## References

- [goja GitHub](https://github.com/dop251/goja)
- [goja_nodejs eventloop source](https://github.com/dop251/goja_nodejs/blob/master/eventloop/eventloop.go)
- [goja_nodejs eventloop pkg.go.dev](https://pkg.go.dev/github.com/dop251/goja_nodejs/eventloop)
- [goja_nodejs interval leak issue #81](https://github.com/dop251/goja_nodejs/issues/81)
- [k6 eventloop pkg](https://pkg.go.dev/go.k6.io/k6/js/eventloop)
- [k6 event loop PR #2228](https://github.com/grafana/k6/pull/2228)
- [Cloudflare Workers Web Standards](https://developers.cloudflare.com/workers/runtime-apis/web-standards/)
- [Cloudflare Outbound Workers](https://developers.cloudflare.com/cloudflare-for-platforms/workers-for-platforms/configuration/outbound-workers/)
- [n8n Code Node Docs](https://docs.n8n.io/code/code-node/)
- [Temporal Activity Execution](https://docs.temporal.io/activity-execution)
- [MDN crypto.randomUUID](https://developer.mozilla.org/en-US/docs/Web/API/Crypto/randomUUID)
- [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [CVE-2024-29415 (ip package SSRF bypass)](https://www.herodevs.com/vulnerability-directory/cve-2024-29415)
- [gojax fetch package](https://pkg.go.dev/github.com/olebedev/gojax/fetch)

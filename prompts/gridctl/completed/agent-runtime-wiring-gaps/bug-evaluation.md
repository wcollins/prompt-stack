# Bug Investigation: Agent Runtime Wiring Gaps

**Date**: 2026-05-09
**Project**: gridctl
**Recommendation**: Fix immediately (bundled)
**Severity**: Critical (Findings 1 & 2) / Medium (Finding 3)
**Fix Complexity**: Small (1, 2) / Medium (3)

## Summary

The Code-First Agent Runtime feature ships with three wiring gaps that together render the advertised end-to-end demo non-functional. TypeScript skills discovered on disk are never exposed via MCP because the registry server is constructed without a `TSDispatcher`. The scaffold's `skill.ts` crashes on first invocation because the sandbox's CommonJS transpile target emits `require()` calls but the goja runtime never installs a `require` global. And the spec's `Gateway.SetAgentRuntime(...)` aggregator was never added, leaving four runtime components (run store, approval registry, playground provider, dev server) plumbed individually through the API server. The first two are launch-blocking; the third is architectural debt that's also a sequencing dependency for a clean fix to the first.

## The Bug

Three defects identified in a feature-validation review of the Code-First Agent Runtime slice (PRs #598, #599, #600, #601):

1. **TSDispatcher unwired** — `pkg/registry/server.go` exposes `SetTSDispatcher`, gates `Tools()` and `CallTool` on a non-nil dispatcher, and is never given one in production. TS skills load into the registry store but are invisible and uninvokable from any external MCP client.
2. **Sandbox `require` missing** — `pkg/agent/dev/scaffold/scaffold.go` emits `import { tool, llm } from "@gridctl/agent";`. `pkg/agent/sandbox/transpile.go` runs esbuild with `Format: api.FormatCommonJS`, producing `var import_agent = require("@gridctl/agent")`. `pkg/agent/sandbox/sandbox.go` injects `console`, `module`, `exports`, and the binding globals — but no `require`. First invocation panics with `ReferenceError: require is not defined`.
3. **`SetAgentRuntime` not implemented** — Spec (`code-first-agent-runtime/feature-prompt.md` L123, L149) prescribed `Gateway.SetAgentRuntime(rt *agent.Runtime)` parallel to `SetCodeMode`. Neither the type nor the method exists. Components are scattered across `internal/api/api.go:81-94` and `pkg/controller/gateway_builder.go:473-481`.

**Expected behavior**: A user runs `gridctl agent init`, then runs the resulting skill from any of CLI / dev server / external MCP client; the skill executes, returns a value, and shows up in `tools/list`.

**Actual behavior**: External MCP clients never see the skill. Direct invocation crashes inside the sandbox before the handler runs.

**Discovery**: Post-merge architectural review of the Code-First Agent Runtime feature, captured in a feature-validation report.

## Root Cause

### Defect Location

- **Finding 1**: `pkg/controller/gateway_builder.go:198-204` — `registryServer.Initialize(...)` is called but no `SetTSDispatcher(...)` follows. Interface contract is in `pkg/registry/server.go:35-37`. Setter at `pkg/registry/server.go:107-111`. Consumed by `Tools()` (lines 142-154) and `CallTool` (lines 187-199).
- **Finding 2**: `pkg/agent/sandbox/transpile.go:30` (`Format: api.FormatCommonJS`) and `pkg/agent/sandbox/sandbox.go:317-323` (`installModuleHarness` — sets `module`/`exports` but not `require`). Triggered by `pkg/agent/dev/scaffold/scaffold.go:130`.
- **Finding 3**: `pkg/mcp/gateway.go:119-153` (Gateway struct — no `agentRuntime` field) and absence of `SetAgentRuntime` method. No `agent.Runtime` type exists in `pkg/agent/`.

### Code Path

**Finding 1**:
```
external MCP client → /mcp tools/list → Gateway.Router.Tools()
  → registry.Server.Tools() (line 123)
    → tsDispatcher == nil → TS skills filtered out (line 142)
```
On call:
```
external MCP client → tools/call → Gateway.CallTool → registry.Server.CallTool
  → tsDispatcher == nil → falls through (line 187)
  → returns "registry: %q is not a registered tool" (line 201)
```

**Finding 2**:
```
sandbox.Execute → transpileTS (esbuild CommonJS) → vm.RunString(transpiled)
  → first line of transpiled output: var import_agent = require("@gridctl/agent")
  → ReferenceError → returned as "loading skill module: %w"
```

**Finding 3**: No execution path — structural absence.

### Why It Happens

- **Finding 1**: A no-op default. `tsDispatcher` is correctly nilable; the registry author intentionally made TS surfacing opt-in. The wiring was simply omitted from the controller. The proximate reason is sequencing: `gateway_builder.go` constructs the registry at line 198 but the LLM provider used by `llm()` bindings is built later inside `buildAPIServer` at line 218 → `pkg/controller/playground.go:23`. There was no obvious "right" place to wire the dispatcher when its dependencies aren't available yet.
- **Finding 2**: esbuild's `FormatCommonJS` always emits `require()` for module imports — that's what CommonJS *is*. The sandbox author exposed `module`/`exports` to receive the transpiled output's writes but didn't anticipate that imports would also be transpiled into a `require()` call. The scaffold then exercises exactly that path. Test coverage missed it because every existing sandbox test uses bare globals (`tool(...)`, `llm(...)`) instead of importing them — so the import-resolution path was never executed in CI.
- **Finding 3**: The spec was clear; the implementer plumbed components individually instead. Likely the same sequencing problem as Finding 1 made the unified type feel premature, and the four-setter pattern grew incrementally without a step back.

### Similar Instances

- No other dispatcher-style "set me before I work" hooks on the registry server are unwired (`SetSkillRegistry` exists at line 98 and is similarly opt-in; need to verify whether it's wired — likely also unwired pending Phase G Go skills).
- The `require` problem affects only `@gridctl/agent`. Any other npm-style import in skill source would also fail, but no tests or scaffolds exercise that path.

## Impact

### Severity Classification

- **Finding 1**: Critical functional defect. The entire "TS skills as MCP tools" story — which is the marquee deliverable of this slice — is non-operational on the canonical client path.
- **Finding 2**: Critical functional defect. Every user who runs `gridctl agent init` and tries to invoke the result hits a crash before the handler runs.
- **Finding 3**: Medium architectural defect. Functional today via the four-setter workaround, but blocks a clean fix to Finding 1 and creates ongoing refactor obligation.

### User Reach

- **Finding 1**: 100% of users who attempt to call TS skills from any external MCP client (Claude Desktop, Claude Code, Cursor, etc.).
- **Finding 2**: 100% of users who follow the documented `agent init` → run flow.
- **Finding 3**: Internal — affects developers extending the runtime.

### Workflow Impact

The advertised end-to-end demo cannot complete. The IDE canvas renders (the parser is AST-only and doesn't care that runtime imports are broken), masking the bug visually until someone tries to actually invoke the skill.

### Workarounds

- **Finding 1**: External MCP clients have no workaround. CLI invocation may bypass the registry server and call `Sandbox.Execute` directly, depending on `cmd/gridctl/run.go` wiring.
- **Finding 2**: Edit the scaffold output by hand to remove the `import` line and rely on bare globals — degrades the teaching value and contradicts the file the framework itself wrote.
- **Finding 3**: Continue the four-setter pattern. Functional but accumulates technical debt.

### Urgency Signals

This is a recently-merged feature (PRs #598-#601, last six commits before HEAD). No external user reports yet because the feature is brand-new — but the moment a user runs the documented flow, both Critical findings fire. Better to ship a fix before public adoption than to hand out a broken first-run experience.

## Reproduction

### Minimum Reproduction Steps

**Finding 1**:
```bash
make build
mkdir -p ~/.gridctl/registry/myskill
cat > ~/.gridctl/registry/myskill/SKILL.md <<'EOF'
---
name: myskill
description: test
state: active
---
EOF
cat > ~/.gridctl/registry/myskill/skill.ts <<'EOF'
export default async function (input: any) { return { ok: true }; }
EOF
./gridctl serve &
# From any MCP client: tools/list — myskill is absent
# tools/call myskill {} — server returns "myskill is not a registered tool"
```

**Finding 2**:
```bash
mkdir /tmp/myskill && cd /tmp/myskill
/path/to/gridctl agent init
# Either invoke via CLI run, or once Finding 1 is fixed, via MCP tools/call
# Failure: ReferenceError: require is not defined
```

**Finding 3**:
```bash
rg "SetAgentRuntime" pkg/mcp/  # returns nothing
```

### Affected Environments

All — these are platform-independent code defects that fire in every build of the current HEAD.

### Non-Affected Environments

- `pkg/registry/typed_skill_test.go` exercises `SetTSDispatcher` directly and proves the runtime path is correct once wired.
- `pkg/agent/sandbox/sandbox_test.go` and `recursive_test.go` use bare globals and pass — they don't exercise the `require` path.

### Failure Mode

- **Finding 1**: Silent absence (TS skills missing from `tools/list`) plus a "not a registered tool" error if the client guesses the name.
- **Finding 2**: Loud crash — `loading skill module: ReferenceError: require is not defined at <eval>:N:M(N)` propagated as the `Sandbox.Execute` error.
- **Finding 3**: No runtime failure; manifests as cross-package coupling pain.

## Fix Assessment

### Fix Surface

**New code**:
- `pkg/agent/runtime.go` (new) — `Runtime` aggregate type
- `pkg/agent/sandbox/dispatcher.go` (extend) — concrete `Dispatcher` implementing `registry.TSDispatcher`
- `pkg/agent/sandbox/sandbox.go` (extend `installModuleHarness` or add `installRequireShim`) — `require("@gridctl/agent")` shim

**Modified code**:
- `pkg/mcp/gateway.go` — add `agentRuntime` field, `SetAgentRuntime`, `AgentRuntime()` accessor
- `pkg/controller/gateway_builder.go` — construct `Runtime` up front; call `gateway.SetAgentRuntime(rt)`; call `registryServer.SetTSDispatcher(...)` after Runtime exists
- `pkg/controller/playground.go` — `buildPlaygroundProvider` may need to be hoisted earlier in builder flow
- `internal/api/api.go` — `SetPlaygroundProvider`/`SetAgentRunStore`/`SetAgentApprovalRegistry` retained as thin wrappers that delegate to the Runtime, so existing callers don't break

**New tests**:
- `pkg/controller/gateway_builder_test.go` — integration test creating a TS skill on disk, building the gateway, asserting `Tools()` lists it and `CallTool` dispatches it
- `pkg/agent/sandbox/sandbox_test.go` — test using `scaffold.helloSkillTS("x")` verbatim
- `pkg/agent/sandbox/sandbox_test.go` — test using a literal `import { tool } from "@gridctl/agent"` source
- `pkg/mcp/gateway_test.go` — `SetAgentRuntime`/`AgentRuntime()` round-trip

### Risk Factors

- **Sequencing in `gateway_builder.go`**: The LLM provider currently builds inside `buildAPIServer` (line 218 → `playground.go:23`). Moving construction earlier could affect telemetry/vault wiring order. Safer alternative: build a Runtime stub up front, then `runtime.SetChatModel(provider)` after API server build.
- **Approver wiring**: The sandbox's `Approver` binding ties to `compose.Registry` for approval gates. The Dispatcher must construct bindings *per call* (not once) so the right Approver is in scope. The existing `sandbox.Sandbox.NewInvoker` already takes a `bindings func(ctx) Bindings` — the new `Dispatcher` should follow that pattern.
- **AllowedTools scope**: The sandbox tool() binding panics if `AllowedTools` is empty. The Dispatcher must populate this from `gateway.Router().Tools()` at dispatch time (or fall back to a permissive set during Phase C — coordinate with the spec).
- **Public API stability for `internal/api/api.go` setters**: The setters are called from `pkg/controller/gateway_builder.go` only (internal package), so we can refactor freely. But preserving them as wrappers minimizes churn and review surface.

### Regression Test Outline

```go
// pkg/controller/gateway_builder_test.go
func TestGatewayExposesTSSkillsViaRegistry(t *testing.T) {
    dir := t.TempDir()
    writeSKILL(t, dir, "echo")
    writeSkillTS(t, dir, `export default async (i:any) => ({echoed: i});`)
    inst := buildGatewayWithRegistryDir(t, dir)
    tools := inst.Gateway.Router().Tools()
    requireToolNamed(t, tools, "echo")
    res, err := inst.Gateway.CallTool(ctx, "echo", map[string]any{"x": 1})
    require.NoError(t, err)
    require.Contains(t, contentText(res), `"echoed":{"x":1}`)
}

// pkg/agent/sandbox/sandbox_test.go
func TestSandboxExecutesScaffoldedSkill(t *testing.T) {
    src := scaffold.HelloSkillTS("x")    // expose the helper or duplicate the body
    sb := New(0)
    _, err := sb.Execute(ctx, src, map[string]any{"name":"world"}, fixtureBindings())
    require.NoError(t, err)
}
```

## Recommendation

**Fix immediately, bundled.** All three findings live inside one architectural seam (the agent runtime wiring layer). Splitting them creates a known-stale intermediate state where Finding 1's fix would either be ad-hoc (refactor obligation) or blocked on Finding 3 anyway. Proposed sequencing inside the single PR:

1. Define `pkg/agent/runtime.go` with the `Runtime` aggregate.
2. Add `Gateway.SetAgentRuntime` / `Gateway.AgentRuntime()`.
3. Add concrete `sandbox.Dispatcher` (implements `registry.TSDispatcher`).
4. Add `require("@gridctl/agent")` shim to the sandbox.
5. Refactor `gateway_builder.go` to construct Runtime up front and wire dispatcher.
6. Refactor `internal/api/api.go` setters to delegate; keep public signatures stable.
7. Add three regression tests covering: gateway-to-TS-skill end-to-end, sandbox-with-import, gateway-runtime-roundtrip.

If timeline pressure forces a split, the minimum-viable hotfix is Finding 2 alone (a 15-line `require` shim plus one test) — that unblocks individual users running scaffolded skills via the CLI, even while external-MCP exposure remains broken.

## References

- Validation report: provided inline by user (2026-05-09)
- Feature spec: `code-first-agent-runtime/feature-prompt.md` (untracked working copy at repo root, lines 110-160 cover the Gateway integration contract)
- Recent feature commits: `dd99024`, `af6209d`, `5baf414`, `132fc36`, `be66e79` (PRs #598-#601)
- Related test fixtures showing intended dispatcher behavior: `pkg/registry/typed_skill_test.go`

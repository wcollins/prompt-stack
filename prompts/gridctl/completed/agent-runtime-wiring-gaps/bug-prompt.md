# Bug Fix: Agent Runtime Wiring Gaps

## Context

**Project**: gridctl — an MCP gateway and orchestration tool written in Go with a React/TypeScript web UI. The repo is at `/Users/william/code/gridctl`. Build with `make build`; binary is `./gridctl`. Tests use `go test -race ./...` plus `npm run build` in `web/`. Lint with `golangci-lint run`. Pre-commit hooks enforce sign-offs (`-S`).

The "Code-First Agent Runtime" feature was merged across PRs #598–#601. It adds:
- A typed-skill registry that walks a skills directory recognising `SKILL.md` plus `*.go` / `*.ts` siblings (`pkg/registry/`).
- A goja-based JavaScript sandbox that runs TypeScript skills with injected `tool()`, `llm()`, `parallel()`, `handoff()`, `approval()` bindings (`pkg/agent/sandbox/`).
- A scaffold (`gridctl agent init`) that drops a runnable starter `skill.ts` (`pkg/agent/dev/scaffold/`).
- A dev server / IDE canvas that re-renders on file edits (`pkg/agent/dev/devserver`, `web/src/components/agent/`).
- JSONL run persistence and approval-gate registry (`pkg/agent/persist/`, `pkg/agent/compose/`).

Gateway construction lives in `pkg/controller/gateway_builder.go`. The HTTP API lives in `internal/api/`. The MCP gateway core is `pkg/mcp/gateway.go`.

**Key conventions**:
- Sign all commits with `-S`. No `Co-authored-by` trailers. No mention of Claude in commit messages, branches, or PRs.
- Eino is consumed only through `pkg/agent/internal/eino/` adapters; downstream packages use gridctl-shaped types (`agent.ChatModel`, `agent.ToolCaller`, etc.).
- Tool calls flow through `*mcp.Gateway.CallTool` so existing observers, replica routing, vault auth all apply.
- Code style favors small, focused interfaces; keep new types in the package whose existing types they collaborate with most closely.

## Investigation Context

A feature-validation review of the Code-First Agent Runtime slice surfaced three coupled wiring gaps. All three are real, all confirmed against the code at HEAD. Sequence matters: the cleanest Finding 1 fix depends on Finding 3 landing first.

- **Finding 1 (Critical, Small)**: `registry.Server.SetTSDispatcher(...)` is never called by the gateway builder. TS skills are invisible to external MCP clients.
- **Finding 2 (Critical, Trivial)**: The sandbox's CommonJS transpile target emits `require("@gridctl/agent")`; the goja runtime never installs `require`. Scaffolded skills crash on first invocation.
- **Finding 3 (Medium, Medium)**: `Gateway.SetAgentRuntime(rt *agent.Runtime)` was specified but never implemented; runtime components are scattered across four setters.

Risk mitigations baked in below:
- The sequencing in `gateway_builder.go` is constrained because the LLM provider is currently constructed inside `buildAPIServer`. The fix below builds a Runtime stub up front and `SetChatModel`s it after the API server completes — avoids reordering vault/telemetry wiring.
- The `require` shim is scoped narrowly to `@gridctl/agent` only; unknown module names panic with a clear error rather than silently returning empty objects.
- Existing `internal/api/api.go` setter signatures (`SetPlaygroundProvider`, `SetAgentRunStore`, `SetAgentApprovalRegistry`, `SetAgentDevServer`) are retained as thin wrappers that delegate into the Runtime — minimizes blast radius and keeps test fixtures stable.

Reproduction confirmed:
- Finding 1: place a `skill.ts` + `SKILL.md` in the registry dir, start the gateway, observe the skill missing from `tools/list`.
- Finding 2: run `gridctl agent init`, invoke the resulting skill, observe `ReferenceError: require is not defined`.
- Finding 3: `rg "SetAgentRuntime" pkg/mcp/` returns nothing.

Full investigation: `~/code/prompt-stack/prompts/gridctl/agent-runtime-wiring-gaps/bug-evaluation.md`.

## Bug Description

**Three coupled defects in the Code-First Agent Runtime slice that together render the advertised end-to-end demo (`gridctl agent init` → run the skill → call it from an MCP client) non-functional.**

1. TypeScript skills the registry discovers on disk never appear in MCP `tools/list` and cannot be called by name from external clients (`Claude Desktop`, `Claude Code`, `Cursor`, etc.).
2. The skill the scaffold creates crashes on first invocation with `ReferenceError: require is not defined` before the user's handler even runs.
3. The architectural integration point the spec defined for the runtime — a single `Gateway.SetAgentRuntime(rt *agent.Runtime)` — was not implemented; consumers thread four separate setters through the API server instead.

Expected: scaffolded skills execute successfully and are callable from any MCP client without manual edits. The Gateway is the single source of truth for the runtime.

Affected: 100% of users following the documented `agent init` → run flow; 100% of external MCP clients trying to call TS skills; all developers extending the runtime layer (Finding 3 only).

## Root Cause

### Finding 1 — TSDispatcher unwired
- `pkg/registry/server.go:35-37` defines the `TSDispatcher` interface.
- `pkg/registry/server.go:107-111` exposes `Server.SetTSDispatcher(d TSDispatcher)`.
- `pkg/registry/server.go:142-154` (`Tools()`) only emits TS-skill entries when `tsDispatcher != nil`.
- `pkg/registry/server.go:187-199` (`CallTool`) only dispatches TS skills when `tsDispatcher != nil`.
- `pkg/controller/gateway_builder.go:179-204` constructs and initializes `registryServer` but never calls `SetTSDispatcher`. There is no concrete type in `pkg/agent/sandbox/` that implements the `TSDispatcher` interface; only the per-call `NewInvoker` helper exists.

### Finding 2 — sandbox `require` missing
- `pkg/agent/sandbox/transpile.go:30` configures esbuild with `Format: api.FormatCommonJS`. The transpiled output of `import { tool, llm } from "@gridctl/agent"` is `var import_agent = require("@gridctl/agent");` followed by property accesses like `(0, import_agent.tool)(...)`.
- `pkg/agent/sandbox/sandbox.go:317-323` (`installModuleHarness`) sets `module`, `exports` (and `console`); `pkg/agent/sandbox/bindings.go` sets `tool`, `llm`, `parallel`, `handoff`, `approval`. Nothing sets `require`.
- `pkg/agent/dev/scaffold/scaffold.go:130` emits the import line into the scaffold output.
- Consequence: `vm.RunString(transpiled)` at `pkg/agent/sandbox/sandbox.go:207` raises `ReferenceError: require is not defined`, returned wrapped as `loading skill module: %w`.

### Finding 3 — `SetAgentRuntime` not implemented
- Spec requires it: `code-first-agent-runtime/feature-prompt.md:123` and `:149` (Integration Points table).
- `pkg/mcp/gateway.go:119-153` Gateway struct has no `agentRuntime` field; no `SetAgentRuntime` method exists in that file.
- No `agent.Runtime` type exists in `pkg/agent/` (verify with `rg "^type Runtime" pkg/agent/`).
- Components currently scattered across `internal/api/api.go:81-94` (`playgroundProvider`, `agentRunStore`, `agentApprovalRegistry`, `agentDevServer`) and `pkg/controller/gateway_builder.go:473-481`.

## Fix Requirements

### Required Changes

1. **Define `agent.Runtime` aggregate** in a new file `pkg/agent/runtime.go`. Holds:
   - `RunStore *persist.Store`
   - `ApprovalRegistry *compose.Registry`
   - `ChatModel agent.ChatModel`
   - `DevServer *devserver.Server`
   - `Sandbox *sandbox.Sandbox`
   Provide a constructor `NewRuntime(store *persist.Store, reg *compose.Registry, sb *sandbox.Sandbox) *Runtime` and setter methods `SetChatModel(agent.ChatModel)`, `SetDevServer(*devserver.Server)` so components built late can be plugged in.

2. **Add `Gateway.SetAgentRuntime` and `Gateway.AgentRuntime`** in `pkg/mcp/gateway.go`, parallel to `SetCodeMode` (line 203). Guard with `g.mu`.

3. **Add concrete `sandbox.Dispatcher`** in `pkg/agent/sandbox/dispatcher.go`. Implements `registry.TSDispatcher` (`Dispatch(ctx, name, sourcePath, arguments) (*mcp.ToolCallResult, error)`). Holds:
   - `*Sandbox`
   - A `BindingsProvider func(ctx context.Context, skillName string) Bindings` so each call gets fresh bindings (request-scoped tracing, current AllowedTools, etc.).
   - On `Dispatch`: read source from `sourcePath`, call `sb.Execute(ctx, source, arguments, bindings(ctx, name))`, marshal the result the same way `NewInvoker` does (`pkg/agent/sandbox/dispatcher.go:48-78` is the model).
   To avoid an import cycle (`registry` would depend on `sandbox` for the type), the existing `registry.TSDispatcher` interface stays as-is and `sandbox.Dispatcher` simply satisfies it structurally.

4. **Inject `require` shim** for `@gridctl/agent`. Add `installRequireShim(vm)` to `pkg/agent/sandbox/sandbox.go`, called from `Sandbox.Execute` before `vm.RunString(transpiled)`. The shim:
   - Takes the module name argument (string).
   - Returns an object whose properties are the same goja values that were set as globals (`tool`, `llm`, `parallel`, `handoff`, `approval`) when the module is `"@gridctl/agent"`.
   - Panics with `vm.NewGoError(fmt.Errorf("require: unknown module %q", name))` otherwise.
   - The shim must be installed *after* the binding install calls so the globals exist when `require` is invoked.

5. **Wire it all in `pkg/controller/gateway_builder.go`**:
   - Build a `Runtime` near the top (after registry construction, before the conditional `inst.Gateway.Router().AddClient(registryServer)` at line 202). Construct with `persist.NewStore(persist.DefaultRunsDir())`, `compose.NewRegistry()`, `sandbox.New(0)`. Do NOT yet pass a ChatModel.
   - Construct the `sandbox.Dispatcher` with a bindings provider that reads `gateway.AgentRuntime().ChatModel` lazily (so the call-time provider is current even though it was set later) and gets `AllowedTools` from `gateway.Router().Tools()`. SkillCaller is `registryServer` itself. Approver wires to the `compose.Registry`.
   - `registryServer.SetTSDispatcher(dispatcher)`.
   - `inst.Gateway.SetAgentRuntime(rt)`.
   - In `buildAPIServer` (around line 473-481), after constructing `playgroundProvider`, call `rt.SetChatModel(provider)`.
   - Replace direct calls to `server.SetAgentRunStore` / `server.SetAgentApprovalRegistry` / `server.SetPlaygroundProvider` with a single `server.SetAgentRuntime(rt)` (or keep them as thin wrappers — see below).

6. **Refactor `internal/api/api.go`** so the four scattered fields read from the Runtime:
   - Add `agentRuntime *agent.Runtime` field.
   - Add `SetAgentRuntime(rt *agent.Runtime)` method.
   - Keep existing setters (`SetPlaygroundProvider`, `SetAgentRunStore`, `SetAgentApprovalRegistry`, `SetAgentDevServer`) as thin wrappers that build a single-component Runtime if none is set, or set the field on the existing Runtime — preserves any tests or external callers that hit the granular setters.
   - Update read sites in `internal/api/agent_runs.go`, `internal/api/playground.go`, `internal/api/optimize.go`, `internal/api/agent_dev.go` to read from the runtime.

7. **Add regression tests**:
   - `pkg/agent/sandbox/sandbox_test.go` — new test using `import { tool } from "@gridctl/agent"` literally, asserting it executes without `require` errors.
   - `pkg/agent/sandbox/sandbox_test.go` — new test invoking `scaffold.HelloSkillTS("x")` (you may need to export the helper) verbatim, with stub `ToolCaller` and `ChatModel` so the actual scaffold output round-trips through the sandbox.
   - `pkg/controller/gateway_builder_test.go` — new test that drops a `SKILL.md` + `skill.ts` into a temp registry dir, builds the gateway, and asserts `inst.Gateway.Router().Tools()` lists the skill and `Gateway.CallTool` dispatches it successfully (use a stub LLM provider).
   - `pkg/mcp/gateway_test.go` — new test for `SetAgentRuntime`/`AgentRuntime()` round-trip.

### Constraints

- **Do not** rename any existing public type or method. The fix is additive plus refactor of internal field plumbing; external API stays stable.
- **Do not** change the goja runtime version, the esbuild target, or the harness shape (`module.exports.default(input)`). Those are deliberate.
- **Do not** make Eino types leak out of `pkg/agent/internal/eino/`.
- **Do not** skip pre-commit hooks; if signing fails, fix the underlying issue.
- **Preserve** the `tsDispatcher == nil` opt-in semantics. The dispatcher field on the registry must remain nilable; `SetTSDispatcher(nil)` must be a valid detach.
- **Preserve** the per-call bindings construction — the `BindingsProvider` is a closure of `(ctx, name) Bindings`, not a fixed struct.

### Out of Scope

- Phase H Go-skill wiring (`pkg/agent/skill/registry.go`'s `SetSkillRegistry` integration into the gateway builder). Currently no-op; leave as-is unless trivially fixable.
- Hot-reload of TS skills (Phase F). The dispatcher reads source on every call already; that's fine for Phase C.
- Real approval-gate UI (Phase E). Keep the auto-approve stub when no Approver is configured.
- Multi-file skill bundles. Imports are limited to `@gridctl/agent`; other module names panic.
- Updating the IDE canvas or trace overlay; the bug is server-side.

## Implementation Guidance

### Key Files to Read

1. `pkg/registry/server.go` — interface contract, gating logic, intended consumer pattern (lines 35-37, 107-154, 170-202).
2. `pkg/registry/typed_skill_test.go` — shows the `SetTSDispatcher` usage pattern with a stub dispatcher; mirror this in the new gateway-builder integration test.
3. `pkg/agent/sandbox/sandbox.go` — lifecycle of `Execute`; where bindings are installed (lines 196-202); module harness (317-323).
4. `pkg/agent/sandbox/bindings.go` — global registration pattern (`vm.Set("tool", ...)` etc.); use the same shape for the `require` shim.
5. `pkg/agent/sandbox/dispatcher.go` — `NewInvoker` is a near-twin of what `Dispatcher.Dispatch` should do; reuse the JSON marshaling logic at lines 62-77.
6. `pkg/agent/sandbox/transpile.go` — confirms esbuild settings; do NOT change them.
7. `pkg/agent/dev/scaffold/scaffold.go` — `helloSkillTS` returns the actual scaffold body. Either export it as `HelloSkillTS` for test reuse or duplicate the body in the test.
8. `pkg/mcp/gateway.go:155-260` — `NewGateway` and the existing setter pattern (`SetCodeMode` at 203, `SetToolCallObserver` at 188, `SetSchemaVerifier` at 243); the new `SetAgentRuntime` mirrors these exactly.
9. `pkg/controller/gateway_builder.go:150-230` — the existing wiring sequence; understand what runs before/after registry init and where the API server build slots in.
10. `pkg/controller/playground.go` — `buildPlaygroundProvider` (the LLM provider that the dispatcher's `llm()` binding needs).
11. `internal/api/api.go:75-100` and `:215-225` — the four scattered fields and their setters.
12. `internal/api/agent_runs.go`, `internal/api/playground.go`, `internal/api/optimize.go`, `internal/api/agent_dev.go` — every read site for the runtime components.
13. `pkg/agent/persist/store.go`, `pkg/agent/compose/approval.go`, `pkg/agent/dev/devserver/devserver.go` — types the Runtime wraps; understand their constructors.

### Files to Modify

- **`pkg/agent/runtime.go`** (new) — `Runtime` aggregate type and constructor.
- **`pkg/mcp/gateway.go`** — add `agentRuntime` field to the struct (around line 153); add `SetAgentRuntime` and `AgentRuntime` methods near `SetCodeMode` (line 203). Import the agent package — note that `pkg/mcp` cannot depend on `pkg/agent` if `pkg/agent` depends on `pkg/mcp` (it does, via `pkg/agent/sandbox`). To break the cycle, define an interface in `pkg/mcp` (`type AgentRuntime interface{}` or similar marker) and let `pkg/agent.Runtime` satisfy it; the Gateway holds the interface and consumers type-assert. Or place the `Runtime` type in a leaf package (`pkg/agent/runtime/`) the gateway can import without picking up the rest of `pkg/agent`. Choose whichever has the cleaner dependency graph after a `go mod why` check.
- **`pkg/agent/sandbox/sandbox.go`** — add `installRequireShim(vm *goja.Runtime)`; call it inside `Execute` after the other `install*` calls and before `vm.RunString(transpiled)`. The shim closure captures `vm` and reads the already-set globals via `vm.Get("tool")` etc.
- **`pkg/agent/sandbox/dispatcher.go`** — add `Dispatcher` struct + `NewDispatcher` constructor + `Dispatch` method.
- **`pkg/controller/gateway_builder.go`** — construct Runtime, dispatcher, wire both. Move provider-into-runtime injection to after `buildAPIServer` returns.
- **`internal/api/api.go`** — add Runtime field and setter; refactor existing setters to delegate.
- **`internal/api/agent_runs.go`**, **`internal/api/playground.go`**, **`internal/api/optimize.go`**, **`internal/api/agent_dev.go`** — read from the Runtime.

### Reusable Components

- The `asyncDeliver` helper in `pkg/agent/sandbox/bindings.go:32-46` is the right pattern for any new async binding. The `require` shim is sync, so it doesn't need this.
- `pkg/agent/sandbox/dispatcher.go:48-78` (`NewInvoker`) is the reference implementation for the `Dispatch` method's body; the marshaling/error-wrapping is the same.
- `pkg/registry/typed_skill_test.go:213-271` (multiple tests) shows how to construct a `stubTSDispatcher` for tests — the `Dispatcher` you write needs to satisfy the same interface.
- `pkg/mcp/gateway.go:203-210` (`SetCodeMode`) is the canonical shape for the new `SetAgentRuntime` method.

### Conventions to Follow

- Sign commits with `-S`. Conventional commit prefixes: `fix:` for the bug-fix nature, or `feat:` if a reviewer would call this a feature completion (it's truly a fix — the spec required these things).
- Test file names mirror source: `pkg/agent/runtime_test.go`, `pkg/agent/sandbox/dispatcher_test.go`, etc.
- Use `t.TempDir()` for filesystem fixtures, not `/tmp/...`.
- Use `require.NoError(t, err)` from `github.com/stretchr/testify/require` (consistent with the rest of the project).
- Run `golangci-lint run` and `go test -race ./...` before each commit.
- Run `npm run build` in `web/` if you touched anything under `web/` (you shouldn't need to).

## Regression Test

### Test Outlines

**Test 1: scaffolded skill executes** (`pkg/agent/sandbox/sandbox_test.go`)
```go
func TestSandboxExecutesScaffoldOutput(t *testing.T) {
    // Use the literal scaffold output so any future change to the
    // scaffold re-asserts runtime compatibility.
    src := scaffold.HelloSkillTS("hello-ts")
    sb := New(0)
    bindings := Bindings{
        ToolCaller:   stubToolCaller{result: `"casual"`},
        AllowedTools: []mcp.Tool{{Name: "gridctl__greeting_style"}},
        ChatModel:    stubChatModel{text: "Hi, world!"},
    }
    res, err := sb.Execute(context.Background(), src, map[string]any{"name": "world"}, bindings)
    require.NoError(t, err)
    require.Contains(t, res.Value, "Hi, world!")
}
```

**Test 2: explicit `require` import path** (`pkg/agent/sandbox/sandbox_test.go`)
```go
func TestSandboxRequireShim_GridctlAgent(t *testing.T) {
    src := `
import { tool } from "@gridctl/agent";
export default async function (i: any) {
    return await tool("svc__op", { x: i.x });
}`
    sb := New(0)
    bindings := Bindings{
        ToolCaller:   stubToolCaller{result: `{"ok":true}`},
        AllowedTools: []mcp.Tool{{Name: "svc__op"}},
    }
    res, err := sb.Execute(context.Background(), src, map[string]any{"x": 1}, bindings)
    require.NoError(t, err)
    require.Contains(t, res.Value, `"ok":true`)
}

func TestSandboxRequireShim_UnknownModule(t *testing.T) {
    src := `import * as fs from "fs"; export default async () => {};`
    sb := New(0)
    _, err := sb.Execute(context.Background(), src, nil, Bindings{})
    require.Error(t, err)
    require.Contains(t, err.Error(), `unknown module "fs"`)
}
```

**Test 3: gateway exposes TS skills** (`pkg/controller/gateway_builder_test.go`)
```go
func TestGatewayExposesTSSkills(t *testing.T) {
    dir := t.TempDir()
    writeFile(t, filepath.Join(dir, "echo", "SKILL.md"), `---
name: echo
description: test echo
state: active
---
`)
    writeFile(t, filepath.Join(dir, "echo", "skill.ts"), `
export default async function (i: any) { return { echoed: i }; }
`)
    inst := buildGatewayWithRegistryDir(t, dir)
    defer inst.HTTPServer.Close()

    tools := inst.Gateway.Router().Tools()
    found := false
    for _, tl := range tools {
        if tl.Name == "echo" { found = true }
    }
    require.True(t, found, "echo skill missing from tools/list")

    res, err := inst.RegistryServer.CallTool(context.Background(), "echo", map[string]any{"v": 7})
    require.NoError(t, err)
    require.Contains(t, contentText(res), `"echoed":{"v":7}`)
}
```

**Test 4: gateway runtime round-trip** (`pkg/mcp/gateway_test.go`)
```go
func TestGatewayAgentRuntimeRoundTrip(t *testing.T) {
    g := NewGateway()
    require.Nil(t, g.AgentRuntime())
    rt := someStubRuntime()
    g.SetAgentRuntime(rt)
    require.Same(t, rt, g.AgentRuntime())
}
```

### Existing Test Patterns

- Stub helpers live alongside the test that needs them; see `pkg/registry/typed_skill_test.go`'s `stubTSDispatcher` for the right shape.
- `pkg/agent/sandbox/sandbox_test.go` already has stub `ToolCaller` and `ChatModel` types — reuse them for the new tests.
- `pkg/controller/gateway_builder_test.go` should follow the existing `apply_test.go` style for fixture setup if one exists; otherwise create a small `buildGatewayWithRegistryDir` helper.

## Potential Pitfalls

- **Import cycle**: `pkg/mcp` cannot depend on `pkg/agent` if `pkg/agent` already depends on `pkg/mcp` (via `pkg/agent/sandbox/sandbox.go:35`). Solve by either (a) defining an empty `mcp.AgentRuntime` interface that the agent package's concrete `Runtime` satisfies, with `Gateway.AgentRuntime()` returning that interface (consumers type-assert), or (b) putting the `Runtime` type in `pkg/agent/runtime/` (a leaf subpackage) the gateway can import. Check with `go mod why` after the first attempt.
- **`gateway_builder.go` ordering**: The Runtime needs to exist before `SetTSDispatcher` is called. The ChatModel inside the Runtime can be set later (after `buildAPIServer`). Don't try to construct a fully-populated Runtime before the API server build; use `SetChatModel` to plug it in later.
- **AllowedTools at dispatch time**: The sandbox's `tool()` binding panics if `AllowedTools` is empty. The Dispatcher's bindings provider must populate this from `gateway.Router().Tools()` (or the registry's intersection of tools the skill is allowed to call). For Phase C, allowing all gateway tools is acceptable; gate-level ACLs land later.
- **Approver wiring**: The Bindings struct's `Approver` field needs to wire to the `compose.Registry` in the Runtime so `approval()` calls go through the real gate when one is registered. The auto-approve stub (when `Approver == nil`) stays as the default — preserve that.
- **Test fixture for `gridctl agent` LLM provider**: The integration test in `gateway_builder_test.go` should use a stub `agent.ChatModel` because the real one needs vault/credentials; the dispatcher's `llm()` binding will only be called if the test skill calls `llm`, so for the echo example you can leave the ChatModel nil and the binding will panic (which is fine — the skill doesn't call it).
- **`require` shim must run after binding installs**: If you install the shim before `installToolBinding` etc., the shim closure will read `nil` from `vm.Get("tool")`. Order matters in `Execute`.
- **`module.exports.default` vs ESM `default` export**: esbuild's CommonJS output writes `module.exports.default = ...` for `export default async function`. Don't change that — the harness expects it.
- **`require` shim and esbuild's `(0, import_agent.tool)(...)` form**: esbuild emits `(0, import_agent.tool)(...)` to preserve `this` semantics. The shim's returned object's properties must be the actual goja function values (not wrappers), otherwise the indirect call may misbehave.

## Acceptance Criteria

1. `agent.Runtime` aggregate type exists with constructor and the four runtime components plus `Sandbox`.
2. `pkg/mcp/gateway.go` has `SetAgentRuntime` and `AgentRuntime` methods following the `SetCodeMode` shape, with proper mutex protection. Round-trip test passes.
3. A concrete `sandbox.Dispatcher` type exists, satisfies `registry.TSDispatcher`, and is wired into `registryServer` from `gateway_builder.go`.
4. The sandbox installs a `require` shim that resolves `"@gridctl/agent"` to an object containing `tool`, `llm`, `parallel`, `handoff`, `approval` from the runtime globals, and panics with a clear error for unknown module names.
5. Running `gridctl agent init` in a temp dir, then invoking the resulting skill via `Sandbox.Execute` directly (with stub bindings), succeeds without `ReferenceError`.
6. After building a gateway with a registry directory containing a `SKILL.md` + `skill.ts` pair, `Gateway.Router().Tools()` lists the skill by name, and `RegistryServer.CallTool(ctx, name, args)` dispatches it through the sandbox.
7. `internal/api/api.go`'s four legacy setters still work (kept as wrappers); read sites in `agent_runs.go`, `playground.go`, `optimize.go`, `agent_dev.go` read from the Runtime.
8. All four new tests pass under `go test -race ./...`.
9. `golangci-lint run` is clean.
10. `make build` and `npm run build` (in `web/`) both succeed.
11. No new `Co-authored-by` trailers, no `--no-verify`, no mention of Claude in commits/branches/PR.

## References

- Validation report: provided inline (2026-05-09)
- Investigation: `~/code/prompt-stack/prompts/gridctl/agent-runtime-wiring-gaps/bug-evaluation.md`
- Spec: `code-first-agent-runtime/feature-prompt.md` (untracked at repo root); see L123 and the Integration Points table at L149
- Recent feature commits: `dd99024`, `af6209d`, `5baf414`, `132fc36`, `be66e79`
- esbuild Transform API: github.com/evanw/esbuild/pkg/api
- goja runtime: github.com/dop251/goja

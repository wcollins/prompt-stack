# Feature Implementation: Code-First Agent Runtime (Brief 3)

## Context

**Project**: gridctl — an MCP gateway/orchestrator written in Go (CLI + Vite/React web UI). Single human contributor (William Collins). Stable on a `v0.1.0-beta` line; sole contributor cadence is high but bursty.

**Tech stack**:
- Go 1.26 (toolchain go1.26.3); 31 direct deps; cobra CLI; OTel tracing; goja+esbuild sandbox; XChaCha20-Poly1305 vault; Docker + Podman runtime adapters.
- Web: Vite 8 + React 19 + TypeScript 6 + `@xyflow/react ^12.10.0` (React Flow v12) + zustand + recharts + vitest 4.
- CI: lint, race tests, per-package coverage floors (`pkg/mcp ≥75%`, `pkg/config ≥70%`, `pkg/runtime ≥60%`, `pkg/reload ≥60%`, `pkg/controller ≥50%`), govulncheck, integration matrix on Docker AND Podman, frontend type-check + vitest + audit + build.

**Constitutional articles relevant to this work** (see `CONSTITUTION.md`):
- Article I (Library-First, just amended PR #582): "Gridctl prefers mature, permissively-licensed (Apache 2.0 or MIT) Go libraries over bespoke implementations for foundational concerns where the alternative is reinventing a graph runtime, sandbox, or schema validator." This is what authorizes Brief 3.
- Article III (Test-First): all exported funcs MUST have tests before merge.
- Article IV (No Mocks in Integration Tests): integration tests MUST exercise real dependencies; MUST run with `-race`.
- Article V (Error Propagation, Not Panic): `panic` MUST NOT be used in `pkg/`/`internal/` library code.
- Article VI (Context Propagation): I/O-performing funcs MUST accept `ctx context.Context` first.
- Article IX (Stack YAML Backward Compat): "The `workflow:` block in `SKILL.md` is no longer supported." — do not reintroduce.
- Article X (Machine-Parseable CLI Output): all structured-data commands MUST support `--format json`.
- Article XIV (Structured Logging): `log/slog` only. No `fmt.Println`/`log.Printf` in library code.
- Article XV (Changelog Discipline): every user-visible change goes in `CHANGELOG.md` `[Unreleased]` before merge.

## Evaluation Context

This implementation prompt is informed by a feature evaluation that pivoted the original brief's runtime-source decision and folded in six load-bearing corrections. Read the full evaluation: `prompts/gridctl/code-first-agent-runtime/feature-evaluation.md`. Key decisions:

- **Depend on Eino as a Go module behind a mandatory adapter layer** instead of vendoring + pruning ~30k LOC. Aligned with Article I; ~2× faster time-to-first-runtime; lower 12-month maintenance; reversible to in-house if upstream becomes intolerable.
- **Adapter layer is non-negotiable.** No `eino.*` types cross out of `pkg/agent/internal/eino/`. The boundary is where reversibility lives.
- **Six brief assertions corrected** and folded into this prompt. Three result in v1 descopes (LLM-response pinning, compiled-artifact fingerprint, canvas→code mutations beyond rename/rewire/add); three in honest framing (typed-graph runtime is not unique to Eino, agent IDE canvas is greenfield not repurpose, ~1s hot reload only for TS flavor).
- **Salvage `web/src/components/playground/PlaygroundTab.tsx`** by wiring `/api/playground/stream` to the new provider abstraction. It's the streaming/trace/provider scaffolding the agent IDE will reuse.
- **Drop the Eino IDE plugin from any rationale.** It's effectively dormant (3 commits / 6 months); the gridctl-owned IDE is the differentiator.
- **In-house typed-graph runtime is the documented escape hatch**, not the primary path. Don't write it now. The mandatory adapter layer makes the swap a 1–2 week project later if needed.
- **Recursive composability is a non-negotiable design constraint of the Skill SDK (Phase D in the original brief; Phase C in the renumbered build order).** Skills are exposed as MCP tools by the gateway. Local execution (`gridctl run <skill>`) and remote execution (an upstream client calling via the gateway) share one code path — there is no "internal" vs "external" execution mode. The Skill SDK's `Run(ctx, input)` signature aligns with the gateway's existing MCP server interface (`pkg/mcp` `AgentClient` + `ToolCaller`), it does not parallel it. Pointing one gridctl instance at another as an MCP server must be a working composition pattern out of the box.

## Feature Description

Build a typed, code-first agent runtime layered on the existing MCP gateway. Three layers:

1. **Gateway** (existing, unchanged) — `pkg/mcp/`, `pkg/controller/`, `pkg/runtime/`. Aggregates downstream MCP servers behind one endpoint.
2. **Agent Runtime** (new, this prompt) — `pkg/agent/`. Typed graphs via Eino-as-module, LLM provider abstraction, sandbox (delegates to existing Code Mode), persistence, multi-agent orchestrator, tracing.
3. **Skill Registry** (existing, recontextualized) — `pkg/registry/`, `pkg/skills/`. Discovery, packaging, remote import via git, lockfile, fingerprinting. Now points at code skills.

Skills are typed Go (`Skill[Input, Output]` interface) or TypeScript (running in the existing Code Mode goja+esbuild sandbox). The runtime emits OTel spans, records LLM cost via `pkg/pricing` + `pkg/metrics`, persists run state as JSONL with time-travel resume, and exposes a code↔canvas IDE where typed source on disk is canon.

**Who benefits**: gridctl users who want to author skills as composable, typed agent flows rather than YAML workflows (which Brief 1 removed). The differentiation is the discipline: typed code as the source of truth, canvas as a derived view that mutates only through narrow AST-safe operations.

## Requirements

### Functional Requirements

1. **`pkg/agent/`** package houses the runtime. Subdirectories: `compose/` (typed graph composition; thin facade over `eino/compose`), `llm/` (provider abstraction), `skill/` (typed Skill SDK), `sandbox/` (TS skill loader, delegates to `pkg/mcp/codemode*.go`), `orchestrator/` (single-writer multi-agent), `persist/` (JSONL run state), `internal/eino/` (the only place `eino.*` types appear).
2. **Typed Skill SDK**: `Skill[Input, Output any]` interface with `Run(ctx context.Context, input Input) (Output, error)`. Inputs/outputs are Go structs with `jsonschema` tags; schemas inferred at registration time. **The `Run(ctx, input)` signature aligns with the existing gateway MCP server interface (`pkg/mcp.AgentClient` / `pkg/mcp.ToolCaller`) rather than paralleling it.** Skills are exposed as MCP tools by the gateway; local execution (`gridctl run <skill>`) and remote execution (an upstream client invoking via the gateway) share one code path. There is no "internal" vs "external" execution mode. **Recursive composability**: pointing one gridctl instance at another as an MCP server must be a working composition pattern out of the box — a `gridctl_remote` server type connects to another gridctl over MCP and surfaces its registered skills as callable tools through the same `agent.ToolInfo` shape used for any other MCP tool.
3. **TS skill flavor**: a SKILL.md sibling `skill.ts` is transpiled via the existing esbuild path (`pkg/mcp/codemode_transpile.go`) and loaded into a `Sandbox` (`pkg/mcp/codemode_sandbox.go`). Exposes `tool()`, `llm()`, `parallel()`, `handoff()`, `approval()` primitives via sandbox bindings.
4. **LLM provider abstraction** in `pkg/agent/llm/`: minimal interface — `Generate(ctx, req) (resp, error)` and `Stream(ctx, req) (<-chan chunk, error)`. Subpackages `anthropic/`, `openai/`, `google/`, `gateway/` (passthrough to upstream client). `net/http` + `encoding/json` only — no third-party SDK adoption.
5. **MCP as native tool protocol**: tool calls flow through `Gateway.CallTool()` so existing tracing, pricing, replica routing, vault auth, and tool whitelisting apply unchanged. Provider tool adapters (translating MCP tool calls into Anthropic `tool_use` / OpenAI function calls / Gemini function declarations) live in `pkg/agent/llm/<provider>/tools.go`. The compose graph never sees provider-specific tool formats.
6. **Single-writer multi-agent**: `Orchestrator[State]` primitive in `pkg/agent/orchestrator/`. `Handoff(target Skill, input HandoffInput)` forks a child context. Subagents read State; only the orchestrator writes. Parallel handoffs supported with explicit merge. **Default `max_parallel=4` cap** enforced.
7. **JSONL run persistence** at `~/.gridctl/runs/<run_id>.jsonl`. Each line is a typed event (`node_enter`, `node_exit`, `tool_call`, `tool_result`, `llm_call`, `llm_chunk`, `structured_output`, `approval_request`, `approval_response`, `error`).
8. **Time-travel resume**: `gridctl runs resume <run_id> [--from-step <node_id>]` rehydrates state from JSONL and resumes execution. Implementation rides on Eino's `compose/checkpoint.go` + `compose/resume.go` via the adapter layer; persistence is the JSONL wrapper.
9. **Approval gates** (`pkg/agent/compose/approval.go` via adapter): suspend the run, persist state, emit MCP 2025-11-25 Task notification. Surface simultaneously in CLI banner + web UI banner + MCP notification. Default 24h timeout; warning emitted at 80% of timeout window.
10. **CLI surface** (Cobra, flat one-file-per-subcommand pattern). The action verb (`run`) is top-level; the collection noun (`runs`) houses inspection. Reasons: shortest correct option (skills will be invoked thousands of times during a development session — every saved keystroke compounds); matches the kubectl convention (action at top-level, collection for inspection) without copying it slavishly; the `runs` noun gives a clean home for inspect/resume/trace without nesting them under the action; doesn't lock into "everything is a flow" framing if some skills end up being short, deterministic, non-graph-shaped invocations.
   - `cmd/gridctl/run.go` — `run <skill> [--input @file.json | --input - | --input '<json>']` — execute a skill. Streams pretty-printed events; supports `--format json` (Article X).
   - `cmd/gridctl/runs.go` — `runs list`, `runs inspect <run_id>`, `runs resume <run_id> [--from-step <node_id>]`, `runs trace <run_id>` (OTel-shaped JSON), `runs approve <run_id> [--decision approve|reject] [--reason <text>]`. All structured-data subcommands MUST support `--format json`.
   - `cmd/gridctl/agent.go` — `agent dev [--port 8181]` (launches IDE), `agent build` (compiles typed Go skills + emits manifest the registry can publish; this is the compile step Go-skill authors run after editing source), `agent validate <skill>` (validates skill manifest + schemas without running it), `agent init` (scaffolds a runnable hello-world TS skill in the cwd).
11. **Code↔canvas IDE** (`web/src/components/agent/`): React Flow canvas, served at `localhost:8181` by `gridctl agent dev`. **Code is canon.** Two views:
   - **Static structure view**: parsed from Go AST or TS AST. Each node renders one `tool()` / `llm()` / `parallel()` / `handoff()` / `approval()` call. Click a node → opens the source line in `$EDITOR` via `editor://` URL.
   - **Trace view**: per-run, read-only, decorates each node with status pill (queued / running / ok / error / suspended), latency, token cost, model. Click a node to see rendered prompt, raw response, validated output, OTel trace ID.
12. **Canvas mutations (v1)**: only rename node (rewrites variable + all references via `gopls` rename), rewire edge (reorder calls in `Run` body, AST-safe), add node from palette (inserts a stub `tool()` / `llm()` call with `// TODO`). All other mutations (function bodies, types, imports, prompt strings, conditionals, loops) are read-only on the canvas.
13. **Live trace overlay** when a run is active. Differentiating overlays to ship in v1: prompt diff between runs, structured-output validation results with schema delta highlighted, "Resume from here" button on completed steps.
14. **Hot-reload**:
   - TS skills: hot-reload on the canvas within ~300ms via goja+esbuild (existing infra). Watcher in `pkg/agent/dev/` extends fsnotify watcher pattern from `pkg/reload/watcher.go` to recursively watch `*.ts` files in the project.
   - Go skills: require explicit `gridctl agent build`. Canvas does NOT hot-reload `.go` source. Acceptance criterion is the build-then-rebuild-canvas path, not auto-hot-reload.
15. **Wire existing subsystems** (no new infra; reuse what exists):
   - **Tracing** (`pkg/tracing`): every node entry/exit and every tool/LLM call emits an OTel span. Spans attach to existing `mcp.routing` parent spans where applicable.
   - **Pricing** (`pkg/pricing`): every LLM call records cost via `pricing.Calculate(model, Usage)`.
   - **Metrics** (`pkg/metrics`): `accumulator.RecordCost(serverName, replicaID, breakdown)` called directly with synthetic serverName like `"agent-runtime"` or `"llm:anthropic"` — no MCP envelope spoofing.
   - **Optimize** (`pkg/optimize`): three new heuristics (`unbounded_loop`, `oversized_prompt`, `untyped_handoff`) added as free functions appended to `Analyze` chain. Add inputs to `Stats` as needed (the struct is explicitly designed to be additive).
   - **Vault** (`pkg/vault`): provider API keys resolve through `${vault:KEY}` exclusively. Never written to logs.
   - **Skill import** (`pkg/skills`): existing import-from-git path works for typed skills as-is. Source-only fingerprint preserved for v1 (compiled-artifact fingerprint deferred to v1.5).
   - **Pins** (`pkg/pins`): MCP tool schema pinning unchanged. LLM-response pinning deferred to v1.5.
16. **`gridctl agent init`**: scaffolds a runnable `hello.ts` TS skill in the cwd plus an `agent.json` config — `agent dev` opens to something live, not empty. Acceptance criterion: <3s from invocation to working canvas.
17. **Salvage `web/src/components/playground/PlaygroundTab.tsx`**: wire `/api/playground/stream` to the new provider abstraction during Phase C. It's the streaming + trace + provider scaffolding the IDE will reuse.

### Non-Functional Requirements

- **Startup budget**: `gridctl agent dev` boots to a working canvas in <3s. Enforced as a CI perf test.
- **TS hot-reload latency**: <300ms from save to canvas update.
- **No `eino.*` types in any public signature outside `pkg/agent/internal/eino/`.** Enforced by a CI lint gate.
- **Per-package coverage**: any new package introduced under `pkg/agent/` should target ≥60% coverage. `pkg/agent/internal/eino/` is the adapter layer and must hit ≥75% (it's the boundary; bugs there cascade).
- **Race tests**: all integration tests touching the runtime run with `-race`.
- **Bundle size**: web build chunks for the agent IDE must be route-level code-split. Main bundle should not regress past 900 kB.
- **Documentation freshness**: AGENTS.md updated in lockstep with structural changes (use `/sync-gridctl` skill).
- **CHANGELOG**: every PR includes its `[Unreleased]` entry.

### Out of Scope (v1)

- LLM-response pin store. Pins remain MCP-tool-only for v1; `pkg/pins` is not refactored. (Defer to v1.5.)
- Compiled-artifact fingerprint. Fingerprint stays `sha256(SKILL.md body) + sorted(allowed_tools)` for v1. (Defer to v1.5.)
- Canvas mutations beyond rename/rewire/add-stub. Function bodies, prompt strings, conditionals, loops, imports, and type declarations are read-only on the canvas. (Defer to v1.5.)
- Hot-reload of `.go` source on the canvas. Go skills require explicit `gridctl agent build`. (Defer to vNext if at all.)
- "ask" approval mode in CLI (mid-`apply` stdin prompts). Web UI banner is enough; CLI ask is the most un-gridctl thing in the feature surface.
- Backward compatibility with the YAML workflow grammar (deleted in Brief 1, formally disowned by Article IX).
- Managed cloud / hosted runtime. Local-first only.
- Vector stores, embedding pipelines, native RAG. Get retrieval through MCP tools.
- DSPy-style optimization-as-compiler features.
- Wrapper-layer chain detection (analogous to Brief 2 v1 deferral).

## Architecture Guidance

### Recommended Approach

**Eino as a module, never as code.** `require github.com/cloudwego/eino vX.Y.Z` (pin to a stable tag — start with `v0.8.13`; only bump to alpha lines deliberately). Import only `compose`, `schema`, `callbacks`. From `eino-ext` per-component go.mod, import only providers actually used.

**`pkg/agent/internal/eino/` is the strict boundary.** Every Eino type is wrapped or translated before crossing out. The adapter exposes gridctl-shaped types (`agent.Graph[I, O]`, `agent.Runnable[I, O]`, `agent.StreamReader[T]`, `agent.ToolInfo`, `agent.ChatModel`) in terms of which the rest of `pkg/agent/` is written. If Eino's API changes, only this directory updates. If gridctl ever swaps to in-house, only this directory is rewritten.

**Tool calls go through the existing gateway.** A `gateway.NewToolCaller(g *mcp.Gateway)` returns a `ToolCaller` the runtime uses. Existing observers, replica routing, vault auth all apply unchanged. Provider adapters in `pkg/agent/llm/<provider>/tools.go` translate gridctl's `agent.ToolInfo` to provider-specific shapes — the compose graph never sees Anthropic / OpenAI / Gemini tool formats.

**Skill registration extends the existing registry walker.** `pkg/registry/store.go:loadSkills` currently matches only `SKILL.md`. Extend to recognize `*.go` and `*.ts` siblings. Compiled Go skills register as MCP tools through the existing `Server.Tools()` / `CallTool()` path (today both are no-op stubs); typed skills become callable via `gridctl run <skill>`. TS skills register identically; execution dispatches to `Sandbox.Execute` from the existing Code Mode infrastructure.

### Key Files to Understand (read first)

1. `/Users/william/code/gridctl/CONSTITUTION.md` — non-negotiable governance, just amended for this work.
2. `/Users/william/code/gridctl/AGENTS.md` — architectural guide; current.
3. `/Users/william/code/gridctl/pkg/mcp/gateway.go` — central nervous system; `Gateway` lifecycle, `SetCodeMode`, `SetToolCallObserver`, `CallTool`, `HandleToolsCall`. The agent runtime hangs off `SetAgentRuntime(...)` (a new method following the same shape).
4. `/Users/william/code/gridctl/pkg/mcp/types.go` — `Tool`, `ToolCallParams`, `ToolCallResult`, `ToolCaller`, `ToolCallObserver`, `AgentClient`, `SchemaVerifier`. The type vocabulary every new package reuses.
5. `/Users/william/code/gridctl/pkg/mcp/codemode_sandbox.go` — the existing JS sandbox the TS-flavor reuses. Lines 108–199 are the binding pattern for `tool()`/`llm()`/`parallel()`/`handoff()`/`approval()`.
6. `/Users/william/code/gridctl/pkg/mcp/codemode_transpile.go` — esbuild integration; reusable for TS skills.
7. `/Users/william/code/gridctl/pkg/mcp/codemode_fetch.go` — example of a complex sandbox binding (network-shaped, ACL-enforced) that mirrors the shape `llm()` will take.
8. `/Users/william/code/gridctl/pkg/registry/server.go` — canonical example of an in-process `mcp.AgentClient`. Lines 65–73 are where `Tools()` returns nil and `CallTool` rejects everything; extend these to expose typed skills as MCP tools.
9. `/Users/william/code/gridctl/pkg/registry/store.go:377–430` — `loadSkills` walker; needs to grow to recognize `.go`/`.ts` siblings of SKILL.md.
10. `/Users/william/code/gridctl/pkg/controller/gateway_builder.go` — shows how every subsystem (vault, pins, registry, telemetry, tracing, metrics) is wired into the gateway at apply-time. New agent runtime needs the same treatment.
11. `/Users/william/code/gridctl/internal/api/api.go:210–331` — full route table; new agent-runtime routes register here.
12. `/Users/william/code/gridctl/cmd/gridctl/root.go` — Cobra wiring pattern that `flow.go` and `agent.go` follow.
13. `/Users/william/code/gridctl/pkg/skills/importer.go` + `lockfile.go` — import-from-git+lockfile+fingerprint surface.
14. `/Users/william/code/gridctl/pkg/tracing/provider.go` + `pkg/tracing/buffer.go` — span emission and ring-buffer surface; agent-runtime spans slot in alongside `mcp.routing`.
15. `/Users/william/code/gridctl/pkg/metrics/observer.go` + `accumulator.go` — confirms the `RecordCost(serverName, replicaID, breakdown)` entry point.
16. `/Users/william/code/gridctl/pkg/pricing/pricing.go` — `Calculate(model, Usage) (Cost, bool)` with embedded LiteLLM snapshot.
17. `/Users/william/code/gridctl/pkg/optimize/optimize.go:389–394` — heuristic registration shape (free functions appended to `Analyze`).
18. `/Users/william/code/gridctl/pkg/reload/watcher.go` — fsnotify pattern; `pkg/agent/dev/` watcher follows this shape but extends to recursive watching of `*.ts`.
19. `/Users/william/code/gridctl/web/src/App.tsx` + `web/src/components/graph/Canvas.tsx` — existing React Flow surface (stack topology canvas). The agent IDE canvas is greenfield UI alongside, not a repurpose.
20. `/Users/william/code/gridctl/web/src/components/playground/PlaygroundTab.tsx` + `web/src/lib/api.ts` — the dead playground stub. Salvage during Phase C.
21. `/Users/william/code/gridctl/.github/workflows/gatekeeper.yaml` — CI gates.
22. `/Users/william/code/gridctl/scripts/check-coverage.sh` — per-package coverage floors.
23. `/Users/william/code/gridctl/Makefile` — build/test entry points.

### Integration Points

| Touchpoint | What changes |
|---|---|
| `pkg/mcp/gateway.go` | Add `SetAgentRuntime(rt *agent.Runtime)` parallel to `SetCodeMode`; expose `CallTool` to the runtime via a `ToolCaller` adapter |
| `pkg/registry/server.go` | Extend `Tools()` / `CallTool()` to expose registered typed skills as MCP tools (today both are no-op stubs) |
| `pkg/registry/store.go:loadSkills` | Recognize `*.go` and `*.ts` siblings of SKILL.md; register typed-skill metadata |
| `pkg/skills/scanner.go` | Add scan rules for typed-skill source (existing security regex patterns apply) |
| `pkg/optimize/optimize.go` | Append three new heuristic free functions; extend `Stats` with new fields |
| `internal/api/api.go` | Add agent-runtime routes (see "API surface" below) |
| `pkg/controller/gateway_builder.go` | Wire `agent.Runtime` into apply-time gateway construction |
| `cmd/gridctl/root.go` | `AddCommand(flowCmd)`, `AddCommand(agentCmd)` |
| `web/src/components/agent/` (new) | IDE canvas, trace overlay, source-link, prompt-diff view |
| `web/src/App.tsx` | Add agent IDE route alongside existing tabs |
| `web/src/components/playground/PlaygroundTab.tsx` | Wire `/api/playground/stream` to the new provider abstraction (Phase C) |

### API Surface (new routes)

- `GET /api/playground/stream` — wire to provider abstraction (salvage path).
- `POST /api/agent/runs` — start a run.
- `GET /api/agent/runs` — list runs (with filtering).
- `GET /api/agent/runs/{run_id}` — get run state.
- `GET /api/agent/runs/{run_id}/events` — stream run events (SSE).
- `POST /api/agent/runs/{run_id}/resume` — resume from latest checkpoint or specified node.
- `POST /api/agent/runs/{run_id}/approve` — respond to an approval gate.
- `GET /api/agent/skills` — list registered typed skills (Go + TS).
- `GET /api/agent/skills/{name}` — skill metadata + parsed graph structure (for canvas).
- `WS /api/agent/dev` — file-watcher events + canvas updates for the IDE (gorilla/websocket — confirm dep is acceptable; otherwise reuse SSE).

### Reusable Components

- `pkg/mcp/codemode_sandbox.Sandbox` — TS skill execution.
- `pkg/mcp/codemode_transpile` — esbuild for TS skills.
- `pkg/pricing.Calculate` — LLM cost.
- `pkg/metrics.accumulator.RecordCost` — cost recording.
- `pkg/tracing` — OTel spans.
- `pkg/vault.Resolve` — provider API keys.
- `pkg/registry.Server` (existing AgentClient impl) — pattern for exposing typed skills as MCP tools.
- `pkg/skills.Importer` + `LockFile` — typed-skill import via git.
- `pkg/reload/watcher.go` (pattern) — file watcher for `pkg/agent/dev/`.

## UX Specification

### Discovery

User installs gridctl 0.2; runs `gridctl agent init` in an empty directory. Scaffolds:
- `hello.ts` — a runnable hello-world TS skill that calls one MCP tool and one LLM.
- `agent.json` — minimal config (which MCP servers to connect, default model).
- `SKILL.md` — manifest.

User runs `gridctl agent dev`. Browser opens `localhost:8181` to a canvas with the `hello` skill rendered. Click Run; it streams.

### Activation Paths

- **Run a skill**: `gridctl run hello --input '{"name":"world"}'` — streams pretty-printed events; `--format json` for machine-readable; `--input @file.json` for file input; `--input -` for stdin.
- **Run from canvas**: click a skill in the IDE sidebar, click Run, see live trace overlay.
- **Inspect a run**: `gridctl runs inspect <run_id>` — typed timeline. `gridctl runs trace <run_id>` — OTel-shaped JSON.
- **Resume a run**: `gridctl runs resume <run_id> [--from-step <node_id>]`.
- **List runs**: `gridctl runs list` — past runs with status and skill name.
- **Approve a gated run**: `gridctl runs approve <run_id> [--decision approve|reject] [--reason <text>]`.

### Interaction Model

The canvas and the editor are co-equal surfaces. Source code on disk is canon. Static-structure view shows the graph derived from AST. Click a node → opens the source line in `$EDITOR`. Trace view, when a run is active, decorates nodes with status pills + latency + token cost + model. "Resume from here" button on completed steps.

Canvas mutations (rename / rewire / add stub) write back to source via gopls (Go) or ts-morph-equivalent (TS); user reviews the diff before save. Mutations that aren't safe (function bodies, prompt strings, control flow) are not exposed as canvas affordances — those are editor-only operations.

### Feedback

- During a run: streaming events show in CLI (pretty by default; `--format json` for machine output) and decorate canvas nodes in real time.
- On compile error (Go skills after `gridctl agent build`): inline error overlay on the canvas; stale graph stays visible until rebuild succeeds.
- On TS hot-reload syntax error: inline error overlay; last-good canvas preserved.
- On approval gate: CLI banner with `gridctl runs approve <run_id>` command + deep link; web UI persistent banner on the run detail page; MCP Task notification fires.

### Error States

- Provider API failure: structured error with provider name, status code, and a single-line summary; full body in trace.
- Vault key missing: error references the `${vault:KEY}` reference and suggests `gridctl vault set`.
- Cross-flavor handoff JSON-marshal failure: typed error pointing at the field name and the source/target types.
- Approval gate timeout: warning at 80% of window; final timeout transitions run to `error` with reason.

## Implementation Notes

### Conventions to Follow

- **Adapter discipline**: every Eino type wrapped before exiting `pkg/agent/internal/eino/`. CI lint via grep (or AST analysis) checks for `eino.` outside the adapter directory.
- **Cobra subcommand pattern**: one file per top-level subcommand in `cmd/gridctl/`. Each declares `var fooCmd = &cobra.Command{...}` and an `init()` that attaches flags. `cmd/gridctl/root.go` calls `rootCmd.AddCommand(fooCmd)`.
- **JSON output**: every structured-data subcommand supports `--format json` (Article X). Default is pretty-printed.
- **Structured logging**: `log/slog` only (Article XIV). No `fmt.Println` / `log.Printf` in `pkg/` or `internal/`.
- **Context propagation** (Article VI): `ctx context.Context` is the first parameter of every I/O-performing function.
- **No panic in library code** (Article V). All errors propagated.
- **Tests**: every exported function has a test before merge (Article III). Integration tests run with `-race` and use real dependencies (Article IV).
- **CHANGELOG**: every PR adds its entry to `[Unreleased]` (Article XV).
- **Coverage**: aim for ≥60% per new package; `pkg/agent/internal/eino/` should hit ≥75%.

### Potential Pitfalls

- **Eino is on alpha (`v0.9.0-alpha.20` as of 2026-05-08).** Pin to stable `v0.8.13` to start; only adopt alpha tags deliberately. Pre-1.0 means `feat!:` breaking changes are routine — the adapter layer is what protects you.
- **Eino's tool interface is OpenAI-function-calling-shaped.** Provider adapters in `pkg/agent/llm/<provider>/tools.go` translate `agent.ToolInfo` to provider-specific shapes; they do not call into Eino's `tool.InvokableTool` interface directly.
- **Go reflection errors are notoriously bad.** Custom error formatter for typed-handoff failures (cross-flavor JSON marshal mismatches) — point at the field name and source/target types.
- **Single-writer multi-agent**: enforce in code, not just docs. The orchestrator interface should make subagent state mutation impossible (read-only views, not pointers).
- **Cross-flavor (Go ↔ TS) handoffs** bite on `time.Time`, `int64`, pointer-vs-null. Visual `[Go]` / `[TS]` tags in `gridctl runs list` warn the user.
- **The `eino-ext/devops/` IDE plugin is dormant** (3 commits / 6 months). Don't plan around it. The custom IDE in `web/src/components/agent/` is the differentiator.
- **PlaygroundTab.tsx exists today as dead UI** — `web/src/components/playground/PlaygroundTab.tsx:607` calls `/api/playground/stream` with no Go handler. Wire it during Phase C; don't delete it.
- **Frontend bundle is at 874 kB pre-IDE.** Code-split agent IDE routes; don't regress past 900 kB main bundle.
- **Eino's `compose` package uses `internal/` extensively.** Some semantic changes (e.g., the MCP-as-native-tool-protocol rewire) require an adapter, not a fork — the adapter layer absorbs the impedance.
- **Hot-reload split by skill flavor is honest, not optional.** Don't promise `.go` source hot-reload at the canvas level. TS skills hot-reload; Go skills require explicit build.

### Suggested Build Order

The brief proposes phases A–I. The depend-not-vendor pivot reshapes Phase A; the rest survive structurally. Sequence each as one or more PR-sized chunks; each phase leaves the binary buildable and CI green.

#### Phase A — Add module and write adapter (renamed from "Clone and Prune")

1. Pre-flight: tiny dependency-add PR. Add `require github.com/cloudwego/eino vX.Y.Z` to `go.mod`. Import nothing yet. Run `go mod tidy`. CI must pass. This validates the relaxed Article I posture and shakes out any module-resolution quirks.
2. Create `pkg/agent/internal/eino/` and define the adapter contract: gridctl-shaped types (`agent.Graph[I, O]`, `agent.Runnable[I, O]`, `agent.StreamReader[T]`, `agent.ToolInfo`, `agent.ChatModel`) wrapping or translating their Eino equivalents.
3. Write the boundary CI lint: `! grep -rn 'github.com/cloudwego/eino' pkg/agent/ | grep -v 'pkg/agent/internal/eino/'`. Or AST-based equivalent.
4. Add `THIRD_PARTY.md` recording Eino's provenance (Apache 2.0, version, purpose). Do NOT claim uniqueness or actively-maintained IDE plugin.
5. Land Phase A in 2–3 PRs.

#### Phase B — MCP as native tool protocol

1. `pkg/agent/llm/` package skeleton with the `Provider` interface (`Generate`, `Stream`).
2. `pkg/agent/llm/anthropic/` first — Anthropic Messages API + `tool_use` block translation. `net/http` only.
3. Provider tool adapter pattern: gridctl `agent.ToolInfo` → Anthropic tool format; Anthropic `tool_use` block → gridctl `agent.ToolCall`.
4. End-to-end smoke: a hard-coded one-LLM-one-tool-call flow runs through the adapter against a real Anthropic key (resolved via `${vault:KEY}`). Trace span visible. Cost recorded.
5. Repeat for OpenAI, Google. `gateway/` (passthrough) ships last.
6. Salvage `web/src/components/playground/PlaygroundTab.tsx` by wiring `/api/playground/stream` to the provider abstraction.
7. Land Phase B in 4–6 PRs.

#### Phase C — Skill SDK (Phase D in the original brief)

**Non-negotiable design constraint: recursive composability.** Skills are MCP tools exposed by the gateway. Local execution (`gridctl run <skill>`) and remote execution (upstream client calling via the gateway) share one code path — no "internal" vs "external" execution mode. The Skill SDK's `Run(ctx, input)` signature must align with the existing `pkg/mcp` server interface (`AgentClient` + `ToolCaller`), not parallel it. One gridctl instance pointed at another as an MCP server is a working composition pattern out of the box, validated as part of this phase's acceptance.

1. `pkg/agent/skill/` — typed `Skill[Input, Output]` interface; jsonschema inference for inputs/outputs. The `Run(ctx, input)` signature is the same surface the gateway already exposes for MCP tool invocation; the SDK is the typed flavor of that surface, not a sibling.
2. `pkg/agent/sandbox/` — TS skill loader delegating to existing `Sandbox` with `tool()` / `llm()` / `parallel()` / `handoff()` / `approval()` bindings injected (extend `codemode_sandbox.go:108–199` pattern).
3. `pkg/registry/store.go` walker recognizes `*.go` and `*.ts` siblings of SKILL.md.
4. `pkg/registry/server.go` `Tools()` / `CallTool()` extended to expose registered typed skills as MCP tools — the same path `gridctl run <skill>` invokes locally.
5. **Recursive composition smoke test**: a second gridctl instance is configured with the first as an MCP server; the first's typed skill is callable from the second exactly as any other MCP tool. No bespoke "remote skill" code path.
6. End-to-end: `gridctl run hello-ts --input '{}'` runs a TS skill that calls one tool and one LLM. Same skill is invokable through the gateway from an upstream MCP client (Claude Desktop, or a second gridctl).
7. Land Phase C in 4–5 PRs.

#### Phase D — Multi-agent orchestrator

1. `pkg/agent/orchestrator/` — `Orchestrator[State]` primitive with read-only state views for subagents.
2. `Handoff(target, input)` primitive; default `max_parallel=4` cap.
3. End-to-end: a Go skill orchestrating two parallel TS subagents with explicit merge.
4. Land Phase D in 2–3 PRs.

#### Phase E — Persistence and time-travel

1. `pkg/agent/persist/` — JSONL run state at `~/.gridctl/runs/<run_id>.jsonl`. Event types: `node_enter`, `node_exit`, `tool_call`, `tool_result`, `llm_call`, `llm_chunk`, `structured_output`, `approval_request`, `approval_response`, `error`.
2. `gridctl runs inspect <run_id>` — typed timeline rendering.
3. `gridctl runs resume <run_id> [--from-step <node_id>]` — rehydrate state from JSONL and resume via Eino's checkpoint/resume through the adapter.
4. Approval gates: suspend, persist, emit MCP Task notification. CLI banner + web UI banner + MCP notification simultaneously. 24h default timeout; 80%-mark warning.
5. Land Phase E in 3–4 PRs.

#### Phase F — Visual IDE

**Design principle (quote it in PR review)**: borrow Temporal's published critique by name — "[The Fallacy of the Graph](https://temporal.io/blog/the-fallacy-of-the-graph-why-your-next-workflow-should-be-code-not-a-diagram)." The defensible one-liner when canvas-as-source pressure shows up in PR review is: **"The fallacy of the graph applies — code is canon."** Code is the typed source-of-truth in `$EDITOR`; the canvas is a derived view. This is the constraint the IDE is engineered around — it shapes every slice below.

**Sequencing principle: observability first, visualization second.** Click-to-`$EDITOR` plus the trace overlay deliver ~80% of what production agent developers actually want in ~5 weeks. The canvas viewer is more visually impressive but adds less marginal value when there's already a typed source-of-truth in `$EDITOR`. Ship the boring useful thing first. Discipline matters most here. Four slices, in order. Don't start the next slice until the previous is shipped and used.

1. **Slice 1 — click-to-`$EDITOR` from a minimal node list** (<1 week):
   - File watcher in `pkg/agent/dev/` (recursive `*.ts` watch; `*.go` watched but only re-parsed on `gridctl agent build`).
   - Go AST parser → flat JSON node list (no canvas yet); TS AST parser → same JSON shape.
   - WS endpoint at `/api/agent/dev` streams file-watcher events.
   - Web view renders a textual list of nodes per skill; clicking a node opens the source line in `$EDITOR` via an `editor://` URL respecting `$EDITOR`.
   - `gridctl agent init` ships hello-world TS skill.
   - <3s startup budget enforced as a CI perf test.
   - Rationale: this is the cheap observability shortcut. Ships in days, validates the AST + watcher + IDE-route plumbing, and is independently useful before any canvas exists.
2. **Slice 2 — live trace overlay + "Resume from here"** (3–4 weeks):
   - Status pills (queued / running / ok / error / suspended), latency, token cost, model per node — rendered against the same node list from Slice 1 first; the canvas in Slice 3 inherits this overlay unchanged.
   - Click a node → rendered prompt, raw response, validated output, OTel trace ID.
   - Prompt diff between runs.
   - Structured-output validation results with schema delta highlighted.
   - "Resume from here" button on completed steps (suspends, persists, hands off to `gridctl runs resume <run_id> --from-step <node_id>`).
   - Rationale: combined with Slice 1, this is the ~80% of what production agent developers actually want.
3. **Slice 3 — code→canvas viewer** (3–5 weeks):
   - `web/src/components/agent/Canvas.tsx` with read-only React Flow nodes derived from the AST JSON shape Slice 1 already emits.
   - Trace overlay from Slice 2 decorates this view unchanged.
   - Click a node → still opens the source line in `$EDITOR`.
   - Rationale: the visualization is the polish on top of the observability. Lands after the useful thing already shipped.
4. **Slice 4 — narrow AST-safe canvas mutations** (6–10 weeks):
   - Rename node via gopls (Go) or ts-morph-equivalent (TS) — rewrites variable + all references.
   - Rewire edge — reorder calls in `Run` body (AST-safe).
   - Add node from palette — inserts stub `tool()` / `llm()` call with `// TODO`.
   - Diff-review before save (no auto-write).
   - Defer canvas-mutates-prompts/bodies/control-flow indefinitely. **Code is canon** — invoke the principle when scope-creep pressure appears.

Land Phase F in 8–12 PRs across 12–20 weeks.

#### Phase G — CLI surface (parallel-safe)

The CLI shape is verb-noun, not flow-prefixed. The action `run` is top-level (shortest path for the most common operation; saves keystrokes during a development session). The collection `runs` houses inspect/resume/trace/approve. Skill-authoring-time operations (compile, validate, scaffold, dev IDE) live under `agent`.

1. `cmd/gridctl/run.go` — `run <skill> [--input @file.json | --input - | --input '<json>']`. Pretty-prints streaming events by default; `--format json` for machine-readable output (Article X).
2. `cmd/gridctl/runs.go` — `runs list`, `runs inspect <run_id>`, `runs resume <run_id> [--from-step <node_id>]`, `runs trace <run_id>` (OTel-shaped JSON), `runs approve <run_id> [--decision approve|reject] [--reason <text>]`. Each supports `--format json`.
3. `cmd/gridctl/agent.go` — `agent dev [--port 8181]`, `agent build` (compiles typed Go skills + emits manifest the registry can publish — this absorbs what the original brief called `flow build`), `agent validate <skill>` (validates manifest + schemas), `agent init` (scaffolds hello-world TS skill).
4. Wire into `cmd/gridctl/root.go`.
5. Land Phase G in 2–3 PRs (can run in parallel with Phase F).

#### Phase H — Wire existing subsystems

1. Add three optimize heuristics (`unbounded_loop`, `oversized_prompt`, `untyped_handoff`) — free functions appended to `Analyze`. Extend `Stats` as needed.
2. Confirm tracing spans emit correctly through the adapter.
3. Confirm pricing/metrics recording works for LLM calls.
4. Update AGENTS.md (use `/sync-gridctl`).
5. Land Phase H in 1–2 PRs.

### Phase mental-model summary (depend-not-vendor)

| Phase | Original brief title | Revised title | Survives structurally |
|---|---|---|---|
| A | Clone and Prune | **Add module and write adapter** | No — entirely reshaped |
| B | Make MCP the Native Tool Protocol | Same | Yes |
| C | Provider Abstraction | (Folded into B + D) | Reorganized: provider abstraction lands in B; Skill SDK is C |
| D | Skill SDK | (Renumbered C) | Yes |
| E | Single-Writer Multi-Agent | (Renumbered D) | Yes |
| F | Persistence and Time-Travel | (Renumbered E) | Yes |
| G | Visual IDE | (Renumbered F, sliced 1/2/3/4 — observability before visualization) | Yes — sliced and reordered |
| H | CLI Surface | (Renumbered G) | Yes |
| I | Wire Existing Subsystems | (Renumbered H) | Yes |

## Acceptance Criteria

1. `make build` produces a binary that boots both the gateway and the agent runtime.
2. `gridctl run examples/skills/hello-ts --input '{"name":"world"}'` runs a typed TS skill end-to-end against a real Anthropic key (resolved via `${vault:KEY}`), emits trace data, persists run state.
3. `gridctl run examples/skills/research-go --input '{"topic":"x"}'` runs a typed Go skill end-to-end against a real provider, emits trace data, persists run state.
4. `gridctl agent dev` opens at <3s and reflects TS skill code edits on the canvas in <300ms.
5. Go skill changes are reflected on the canvas after explicit `gridctl agent build` succeeds; on build failure, the canvas shows a stale overlay with the inline compile error and preserves the last-good graph.
6. `gridctl runs resume <run_id>` works after a deliberately-killed run.
7. `gridctl runs list`, `gridctl runs inspect <run_id>`, `gridctl runs trace <run_id>` each work and support `--format json`.
8. **Recursive composability acceptance gate**: a second gridctl instance configured with the first as an MCP server can invoke a typed skill registered on the first through the gateway — same code path as `gridctl run <skill>` locally. No bespoke "remote skill" code path exists.
9. An approval-gated skill suspends correctly, surfaces simultaneously in CLI banner + web UI banner + MCP notification, and resumes on `gridctl runs approve <run_id>`.
10. A multi-agent skill using `Orchestrator[State]` with two parallel handoffs runs successfully, respects the `max_parallel=4` default cap, and persists a coherent merged state.
11. Existing gateway smoke tests still pass: `gridctl apply`, `gridctl link`, `gridctl status`, `gridctl reload`.
12. The end-to-end Go example skill in `examples/skills/research-go/` (research → summarize → critic → format) demonstrates `tool()`, `llm()` with typed output, `parallel()` over an array, `handoff()` to a subagent, and an approval gate. Renders correctly in the IDE.
13. The TS-flavor demo skill in `examples/skills/hello-ts/` is shorter, illustrative, hot-reloads on the canvas in <300ms.
14. **No `eino.*` type appears in any public signature outside `pkg/agent/internal/eino/`.** Enforced by a CI lint gate on every PR.
15. Three new optimize heuristics (`unbounded_loop`, `oversized_prompt`, `untyped_handoff`) appear in `gridctl optimize` output when conditions are met.
16. `web/src/components/playground/PlaygroundTab.tsx` is wired to `/api/playground/stream` and works end-to-end (chat against the gateway).
17. AGENTS.md is updated to reflect the new `pkg/agent/` package and three-layer mental model.
18. `CHANGELOG.md` `[Unreleased]` records every user-visible change in this work.
19. Per-package coverage floors hold: existing thresholds plus `pkg/agent/internal/eino/` ≥75%, other `pkg/agent/*` packages ≥60%.
20. Bundle size: web main bundle does not regress past 900 kB. Agent IDE routes are code-split.

## References

- gridctl Constitution (Articles I, II, IX amended in PR #582 / commit 6dcbdb0)
- gridctl Brief 1 evaluation (`prompts/gridctl/remove-workflow-engine/feature-evaluation.md`) — predecessor that created the gap this brief fills
- This evaluation: `prompts/gridctl/code-first-agent-runtime/feature-evaluation.md`
- [github.com/cloudwego/eino](https://github.com/cloudwego/eino) — runtime library
- [github.com/cloudwego/eino-ext](https://github.com/cloudwego/eino-ext) — per-component go.mod ext modules
- [cloudwego.io/docs/eino/core_modules/chain_and_graph_orchestration/orchestration_design_principles](https://www.cloudwego.io/docs/eino/core_modules/chain_and_graph_orchestration/orchestration_design_principles/) — graph/chain semantics
- [pkg.go.dev/github.com/cloudwego/eino/compose](https://pkg.go.dev/github.com/cloudwego/eino/compose) — `Graph[I,O]`, `Chain[I,O]`, `Workflow[I,O]` API
- [temporal.io/blog/the-fallacy-of-the-graph](https://temporal.io/blog/the-fallacy-of-the-graph-why-your-next-workflow-should-be-code-not-a-diagram) — Temporal's published critique; the design principle the IDE phase is engineered around ("code is canon")
- [docs.langchain.com/langsmith/studio](https://docs.langchain.com/langsmith/studio) — LangGraph Studio (viewer + debugger model; gridctl IDE goes further with click-to-source)
- [aws.amazon.com/blogs/compute/introducing-an-enhanced-local-ide-experience-for-aws-step-functions](https://aws.amazon.com/blogs/compute/introducing-an-enhanced-local-ide-experience-for-aws-step-functions/) — closest extant round-trip prior art
- [platform.openai.com/traces](https://platform.openai.com/traces) — trace overlay UX bar
- [openai.github.io/openai-agents-python](https://openai.github.io/openai-agents-python/) — handoffs primitive (single-writer mental model)
- Cognition: "Don't Build Multi-Agents" — single-writer thesis underpinning Phase D

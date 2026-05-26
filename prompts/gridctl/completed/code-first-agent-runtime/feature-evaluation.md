# Feature Evaluation: Code-First Agent Runtime (Brief 3)

**Date**: 2026-05-08
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Very Large (multi-month, single maintainer, PR-sized chunks)

## Summary

Brief 3 proposes filling the post-Brief-1 gap with a typed, code-first agent runtime layered on the existing MCP gateway: typed `Skill[Input, Output]` SDK in Go, a TS skill flavor reusing the Code Mode goja+esbuild sandbox, an LLM provider abstraction, a single-writer multi-agent orchestrator, JSONL run persistence with time-travel resume, and a code↔canvas IDE where typed source on disk is canon. The mental model is right and the phase plan is mostly sound — but the load-bearing decision to **vendor and prune** ~30k LOC of CloudWeGo's Eino into `pkg/agent/` should pivot to **depend on Eino as a Go module** behind a thin, mandatory adapter layer. That single change roughly halves time-to-first-runtime, aligns with the constitutional amendment William just authored (Article I now permits Apache 2.0/MIT libraries for graph runtimes), keeps gridctl's repo the size it needs to be for a single maintainer, and preserves a cheap escape hatch to in-house if upstream pre-1.0 churn becomes intolerable.

**Skills are exposed as MCP tools by the gateway; local execution (`gridctl run <skill>`) and remote execution (an upstream client calling via the gateway) share one code path.** No "internal" vs "external" execution mode; the Skill SDK's `Run(ctx, input)` signature aligns with the gateway's existing MCP server interface rather than paralleling it. Pointing one gridctl instance at another as an MCP server is a working composition pattern out of the box.

## The Idea

A new `pkg/agent/` package becomes the agent runtime — typed graph composition, LLM provider abstraction, sandbox for TS skills, single-writer multi-agent orchestrator, JSONL persistence. Skills register against the existing `pkg/registry` store; the runtime calls MCP tools through the existing gateway, inheriting tracing, pricing, vault auth, replica routing, and tool whitelisting unchanged. A verb-noun CLI surface — `gridctl run <skill>` for execution, `gridctl runs list/inspect/resume/trace/approve` for the run collection, `gridctl agent dev/build/init/validate` for skill-authoring — lets users author, run, inspect, and resume typed skills. A React Flow IDE on `localhost:8181` reflects code edits on a canvas, decorates nodes with live trace overlays, and supports click-to-source-line in `$EDITOR`.

The differentiation thesis: most agent IDEs are canvas-OR-code. The proposed shape — *code is canon, canvas is a derived view that mutates only via narrow AST-safe operations* — is genuinely unoccupied in the agent/workflow runtime market in May 2026.

## Project Context

### Current State (post-Brief-1, post-amendment)

gridctl is an MCP gateway/orchestrator at v0.1.0-beta. Single human contributor (William Collins); 819 commits in the last 60 days; ~80 PRs; avg PR is 1.9 files / 187 insertions — disciplined small-PR cadence. Zero open PRs at the time of this evaluation. CI gates: lint, race tests, per-package coverage floors (`pkg/mcp ≥75%`, `pkg/config ≥70%`, etc.), govulncheck, integration matrix on Docker AND Podman. Zero TODO/FIXME/HACK markers across all of `pkg/` non-test code.

Brief 1 (commit b709c4d, merged 2026-05-08) deleted `pkg/registry/{dag,executor,template,tester}.go`, `cmd/gridctl/{test,activate}.go`, all `web/src/components/workflow/*`, the `Inputs/Workflow/Output` fields on `AgentSkill`, and four `/api/registry/skills/{name}/{workflow,execute,validate-workflow,test}` endpoints. SKILL.md as a manifest survives; it's served as MCP **prompts**, not tools.

CONSTITUTION.md was just amended (PR #582, commit 6dcbdb0, May 8): Article I now reads *"Gridctl prefers mature, permissively-licensed (Apache 2.0 or MIT) Go libraries over bespoke implementations for foundational concerns where the alternative is reinventing a graph runtime, sandbox, or schema validator."* This is direct pre-positioning for Brief 3 and is the constitutional gravity for the runtime-source decision.

### Integration Surface (verified)

The brief's claim that all reuse subsystems exist holds up. Verified:

| Subsystem | Status | Key entry points |
|---|---|---|
| `pkg/mcp` types | Mature | `Tool`, `ToolCallParams`, `ToolCallResult`, `ToolCaller`, `ToolCallObserver`, `AgentClient`, `SchemaVerifier` in `types.go` — exactly the shape provider adapters need |
| `pkg/mcp/codemode_*` | Mature, 7.7k LOC | `Sandbox.Execute(ctx, code, caller, allowedTools)`; goja+esbuild; ACL-enforced; `mcp.callTool` already injected. Adding `tool()`/`llm()`/`parallel()`/`handoff()` is sandbox-binding work, not greenfield |
| `pkg/tracing` | Mature | OTel SDK provider with in-memory ring buffer + OTLP HTTP; `mcp.routing` spans with GenAI semantic-convention attrs already emitted |
| `pkg/pricing` | Mature | `Calculate(model, Usage) (Cost, bool)`; embedded LiteLLM snapshot. **Clean LLM-shape entry point — no MCP envelope needed** |
| `pkg/metrics` | Mature | `accumulator.RecordCost(serverName, replicaID, breakdown)` is callable directly with synthetic serverName like `"agent-runtime"`. Don't need to fake an MCP event |
| `pkg/vault` | Mature | XChaCha20-Poly1305 + Argon2id; `${vault:KEY}` resolution |
| `pkg/pins` | Mature **but MCP-shape only** | `PinFile.Servers map[string]*ServerPins`; `hashTool` concatenates name+description+inputSchema. **See correction below** |
| `pkg/optimize` | Mature; loose-functional | Heuristics are free functions, `Stats` explicitly designed to be additive. New findings (`unbounded_loop`, `oversized_prompt`, `untyped_handoff`) plug in trivially |
| `pkg/skills` + `pkg/registry` | Mature | Import-from-git, lockfile (`LockedSource{Repo, Ref, ResolvedRef, CommitSHA, ContentHash, Skills}`), fingerprint (`sha256(SKILL.md body) + sorted(allowed_tools)`) |
| CLI pattern | Flat one-file-per-subcommand Cobra | `flow.go`/`agent.go` slot in trivially |
| `web/` toolchain | React 19 + Vite 8 + `@xyflow/react ^12.10.0` | React Flow already in production for the topology canvas |

### Brief Corrections (load-bearing)

Six brief assertions don't hold up against the audit and must be folded into the implementation prompt:

1. **"Eino is the only Go-native agent runtime with compile-time-typed graphs."** Overstated. Counter-examples in May 2026: firebase/genkit-go (Google, GA, generic-typed flows; function-shaped not graph-shaped), smallnest/langgraphgo (typed-state DAGs, MIT, pre-v1, solo-maintained). Eino is **the most graph-feature-complete** generic-typed Go runtime — that's the defensible framing.

2. **"Pins cover both MCP tool schemas and LLM provider response schemas."** Pin store is structurally MCP-only — `PinFile.Servers map[string]*ServerPins`; `hashTool` is keyed on `name+description+inputSchema` for tools. **Descope: source-MCP-only for v1.** Defer LLM-response pinning to v1.5.

3. **"The fingerprint covers compiled artifacts as well as source."** Today: `sha256(SKILL.md body) + sorted(allowed_tools)`. No compiled-artifact concept exists in `pkg/skills/fingerprint.go`. **Descope: source-only fingerprint for v1.** Defer compiled-artifact fingerprint to v1.5.

4. **"Existing React Flow surface in web/."** Yes, but `web/src/components/graph/Canvas.tsx` is the **stack topology canvas**, not a flow/agent canvas. Brief 1 deleted the workflow designer. The agent IDE canvas is **greenfield UI alongside topology**, not a repurpose. Honest framing in Phase G.

5. **"`gridctl agent dev` reflects code edits within ~1s."** Realistic for the TS skill flavor (goja+esbuild). Not realistic for typed Go skills — Go plugins don't unload, recompile is rarely <1s on a non-trivial graph. **Split the claim by flavor:** TS skills hot-reload on the canvas; Go skills require explicit `gridctl agent build`. This is also a UX call (see User Experience).

6. **`web/src/components/playground/PlaygroundTab.tsx` is dead code today** — it calls `/api/playground/stream` with no Go handler. **Recommendation: salvage, don't delete.** A working chat-against-the-gateway playground is exactly the streaming + trace + provider infrastructure the agent IDE will reuse. Wire it up as part of Phase C.

### Reusable Components (real leverage)

- `Gateway.SetCodeMode()` / `SetToolCallObserver()` — clean extension hooks; `SetAgentRuntime(...)` is the obvious parallel shape.
- `Sandbox` is a working, callable executor. Adding TS skill flavor is sandbox-binding work, not greenfield.
- `pricing.Calculate` + `accumulator.RecordCost` is the LLM cost path — no MCP-shape spoofing.
- `pkg/registry/Server` is a canonical `mcp.AgentClient` implementation; the agent runtime can follow this pattern to expose registered skills as MCP tools to other clients (Claude Desktop, etc.).
- `tests/integration/` harness on Docker + Podman with `-race` is already strong; vendored or imported runtime code lands into a serious test culture.

## Market Analysis

### Eino itself (verified)

- **GitHub**: 11.1k stars, 894 forks, Apache 2.0, no CLA, no DCO. Active: 160 PRs / 90 days.
- **Versioning**: Stable line `v0.8.13`; alpha `v0.9.0-alpha.20` cut today (2026-05-08). **Pre-1.0; breaking changes (`feat!:`, `feat(adk)!:`) are routine.**
- **Authorship**: Top 2 contributors own ~55% of all-time commits. Almost all ByteDance staff. Bus factor on upstream is concentrated.
- **Architecture confirmations**: `compose.NewGraph[I, O]()` real (`compose/generic_graph.go`); branch/parallel/lambda/streaming/checkpoint+resume real; tool interface is OpenAI-function-calling-shaped (`schema.ToolInfo`, `ToolChoice` constants explicitly map to OpenAI's `none`/`auto`/`required`).
- **LOC**: core (compose+schema+callbacks) ≈ 15.3k. With flow + components ≈ 21.8k. With ADK = 43.8k. So a 30k pruned subset (drop ADK) is realistic.
- **Docs**: English docs lag Chinese docs; nontrivial concepts are Chinese-first.
- **Production users outside ByteDance**: thin. Tutorials, blog posts, small ecosystem repos, but no public non-ByteDance case studies.

### Alternatives in May 2026

| Runtime | Generics-typed | MCP support | Active | Notes |
|---|---|---|---|---|
| firebase/genkit-go | Yes (typed flows) | Yes (host+client+server plugin) | Yes (1.8.0 May 6) | Function-shaped, not DAG-shaped; Google-backed |
| smallnest/langgraphgo | Yes (`NewStateGraph[T]`) | Adapter | Pre-v1, solo | Typed state DAGs, MIT |
| google/adk-go | Partial | Yes | Yes (1.2.0 Apr 23) | Workflow agents, no `Graph[I,O]` parity |
| tmc/langchaingo | No (pre-generics) | Third-party adapter | Slowing | 9.2k stars, broadest providers |
| nlpodyssey/openai-agents-go | No (typed context only) | Yes | Yes | Young, ~255 stars |
| swarmgo / dive / others | No | No / partial | Hobby-grade | Not viable |

**Where Eino is genuinely unique**: combination of typed `Graph[I, O]` *with edge-level type alignment at compile time*, stream-aware branch/parallel, typed interrupt/resume, and callback aspects — all in one Apache 2.0 module.

### Code↔Canvas IDE Prior Art

**Nobody ships honest code↔canvas round-trip on a typed host language for agent runtimes.** Surveyed:

- **LangGraph Studio** — viewer + debugger only; code is canon; canvas does not write back.
- **Eino's Eino Dev plugin** — one-way canvas→code scaffolding + debug overlay; `devops/` directory has 3 commits in 6 months. **Not strategic leverage.**
- **n8n / Flowise / Langflow / Activepieces** — all canvas-as-source-of-truth; "export to code" is one-way scaffolding.
- **Temporal Web UI** — explicitly rejects graph-as-source ("The fallacy of the graph"). Read-only event-history visualization.
- **AWS Step Functions Workflow Studio** — closest to round-trip in production, but on JSON/YAML, not typed source. Doesn't promise format preservation.
- **Cursor / VSCode AI agent extensions** — trace viewers, not editors.

**Trace overlay bar (table stakes)**: status pills + duration + tokens + model per node/span. Shipped by OpenAI Traces, Anthropic Console, LangSmith, Braintrust. Differentiating overlays: **prompt diff between runs** (LangSmith does it), **structured-output validation results with schema delta highlight** (no one does it cleanly), **side-by-side rerun output** (Braintrust).

**The proposed seat is genuinely unoccupied**: typed Go on disk as canon; canvas as derived view; click-to-`$EDITOR`-line; trace overlay; AST-safe narrow canvas mutations only. This is the differentiation play if discipline holds.

### Market Positioning

gridctl already has the hard infrastructure (MCP gateway, sandbox, tracing, pricing, vault, pins, replica routing) that competitors are building separately. Adding a code-first agent runtime turns gridctl from "MCP gateway" into "MCP gateway + the most disciplined typed-agent runtime + the most honest code-canon IDE in the Go ecosystem." Defensible, narrow, single-maintainer-shaped.

### Demand Signals

- gridctl: 16 stars, sole human contributor — direct demand at this scale is zero. Strategic build, not demand-driven.
- Brief 1 already removed YAML execution — there's a real internal need for *something* to fill the gap.
- Constitution Article I amended yesterday specifically to authorize this work — strongest possible internal demand signal.

## User Experience

### The Authoring Loop

Realistic loop for typed Go: edit `.go` → save → `gridctl agent dev` watches → `gridctl agent build` (500ms–2s on non-trivial graphs) → reflects on canvas + makes runnable via `gridctl run <skill>`. **gridctl will lose the hot-reload speed race against Python/TS but win on type safety.** TS skills via goja+esbuild will hot-reload in <300ms.

**UX implication for the IDE empty state and demo**: the example skill in `examples/skills/` should ship in **TS for the demo** (because it hot-reloads fast and shows the canvas-comes-alive moment) and **Go for a production-shaped second example** (because that's the durable shape).

### The Round-Trip Reality

For typed Go, the safe canvas mutation set for v1:
- **Canvas can mutate**: rename node (rewrites variable + all references via gopls rename), rewire edge (reorder calls in `Run` body, AST-safe), add node from palette (inserts a stub `tool()`/`llm()` call with TODO).
- **Canvas is read-only**: function bodies, type declarations, imports, prompt strings (especially computed `fmt.Sprintf` interpolations), conditional logic, loops.

**Click node → jump to source line** excels for static graphs and breaks on: computed prompts (node label can't preview the actual prompt), loops/conditionals that produce N runtime nodes from one source call, nodes inside helper functions called from `Run`. **Solution: distinguish "static structure view" (parsed from AST, supports rename/rewire) from "trace view" (per-run, read-only, shows actual prompt strings).** Don't conflate them.

### Trace Overlay UX

Table-stakes (mandatory): status pills, duration, tokens, model, input/output JSON, error stack.
Differentiating (build at least one): **prompt diff between runs**, **structured-output validation with schema delta highlight**, **"Resume from here"** on completed steps.

Time-travel/resume is debug-only — Temporal data shows <5% of users use `workflow reset` but those who do love it. Don't over-invest in UI for it; a CLI command + a single button on completed steps is sufficient.

### Multi-Agent Mental Model

Single-writer orchestrator + read-only subagents is the right call (per Cognition's "Don't Build Multi-Agents" + OpenAI Agents SDK handoffs). Users coming from CrewAI/AutoGen will fight the discipline initially.

**Ugliest error modes**:
1. Runaway parallel handoffs with no concurrency cap → silent token burn. **Mandate default `max_parallel=4` cap.**
2. Approval gates not surfaced (run silently suspends, user thinks it crashed). **Surface in CLI banner + web UI banner + MCP Task notification simultaneously.**
3. State merge conflicts on parallel handoffs (mostly avoided by single-writer rule).

### TS-Flavor Coexistence

Cross-flavor handoffs (Go orchestrator → TS subagent or vice versa) bite on JSON marshaling: `time.Time`, `int64`, pointer-vs-null. **In `gridctl runs list`, mark visually distinct (`[Go]` / `[TS]` tags).** Hiding the difference will burn users.

When to choose Go: long-running, performance-critical, sharing types with the gridctl host.
When to choose TS: rapid iteration, prompt-heavy logic, npm-package-shaped helpers.

### Failure Modes Most Likely to Cause Bouncing

1. **Slow `agent dev` startup (>3s)** — biggest first-impression killer. **Mandate <3s startup budget enforced as a CI perf test.**
2. **Canvas going stale on rebuild errors** — must show "stale" overlay with the compile error inline.
3. **Ambiguous typed-handoff errors** — Go reflection errors are notoriously bad; need a custom error formatter.
4. **Hot-reload breaking on syntax errors** — must keep last-good canvas visible, not blank.
5. **Approval-gate timeouts silent** — emit warning at 80% of timeout window.

### UX Recommendations to Bake In

1. `gridctl agent init` ships a runnable hello-world TS skill — `agent dev` opens to something live, not empty.
2. <3s startup budget for `agent dev`, enforced in CI.
3. Distinguish static AST view from per-run trace view — don't conflate structure and execution.
4. Default `max_parallel=4` on handoffs + visible token-cost meter on the canvas during runs.
5. Visual `[Go]` / `[TS]` tags in `gridctl runs list` + explicit type-coercion warnings on cross-flavor handoffs.
6. Approval gates in CLI + web UI + MCP notification simultaneously; 24h default timeout; 80%-mark warning.
7. Inline compile errors on the canvas + "stale" overlay preserves last-good graph until rebuild succeeds.

## Feasibility

### Three-Way Runtime-Source Comparison

| Dimension | Option 1: Vendor + prune (~30k LOC) | **Option 2: Depend on Eino as module** | Option 3: In-house (<2k LOC) |
|---|---|---|---|
| Time to first runtime end-to-end | 4–6 weeks | **2–3 weeks** | 3–4 weeks |
| 12-month maintenance | High — manual re-prune; pre-1.0 churn (160 PRs/90 days); 30k LOC under Articles III–V | **Low — `go get -u` + retest; pinned + deliberate upgrades** | Medium — own all bugs; surface stays small |
| MCP-shape adapter required | Yes | Yes (same scope) | No (native MCP from day one) |
| Constitutional alignment | Stricter than required | **Aligned with intent of amendment** | Contradicts amendment |
| Differentiation potential | Same as Option 2 | Same as Option 1 | Highest |
| Bus-factor compound risk (gridctl=1, Eino concentrated) | High | Medium | All on you |
| Reversibility | Low (forked code is sticky) | **High (with adapter layer)** | High |

### Why Depend Over Vendor

- Constitution Article I now explicitly permits Apache 2.0/MIT libraries for graph runtimes — vendoring is *stricter than authorized*.
- Roughly 2× faster time-to-first-runtime (2–3 wk vs 4–6 wk on Phase A alone).
- 30k LOC stays out of the repo: faster CI, smaller govulncheck surface, single-maintainer keeps PR-size discipline.
- Upstream bug fixes and security upgrades arrive automatically. Pre-1.0 churn is bounded by deliberate version pinning.
- eino-ext's per-component go.mod design lets you cherry-pick imports — drop ADK, drop most providers (the brief plans to drop them anyway).
- The brief's stated reasons to vendor (control over type system, dependency surface, long-term direction) are addressable by the **mandatory adapter layer** — not by owning forked code.

### Why Depend Over In-House

- Constitutional amendment was specifically written to authorize this and discourage in-house ("over bespoke implementations… reinventing a graph runtime").
- Eino has worked through subtle edge cases: streaming concatenation across fan-outs, branch type alignment, interrupt+resume with typed state. Easy to get wrong on the first pass.
- Time-to-first-runtime is comparable; maintenance burden is much lower.

### The Adapter Layer Is Non-Negotiable

This is the load-bearing detail. The adapter is what makes the depend-vs-in-house decision *reversible*. Without it, public signatures couple `pkg/agent/` to Eino's API surface and the escape hatch becomes a rewrite. With it, the swap to in-house is a 1–2 week project, not a 12-week project.

**Rule**: every Eino type that crosses out of `pkg/agent/internal/eino/` is wrapped or translated. Specifically:
- No `eino.Graph[...]` in public signatures of `pkg/agent/compose/`, `pkg/agent/skill/`, or anywhere else outside `pkg/agent/internal/eino/`.
- No `eino.StreamReader[...]` in handler return types or HTTP responses.
- No `eino.Runnable[...]` in skill SDK exports.
- No `eino.ToolInfo` or `eino.ChatModel` types leaking into provider adapters' public surface.

The boundary is where the optionality lives.

### In-House as Documented Escape Hatch

If pre-1.0 upstream churn produces 3+ breaking changes in 90 days that actually break gridctl, fall back to Option 3. The thin adapter layer makes the swap a 1–2 week project. Read Eino's `compose/generic_graph.go` once now to internalize the design — algorithms are unencumbered by license. Don't write the in-house runtime now.

### v1.5 Follow-Ups (Explicitly Deferred)

- LLM-response pin store (parallel `Providers map[string]*ProviderPins` on `PinFile`, or polymorphic kind discriminator).
- Compiled-artifact fingerprint (build step + cache + new lockfile fields).
- Canvas → code AST-preserving mutations beyond rename/rewire/add (e.g., conditional editing, prompt-string editing).
- "ask" approval mode routed to Web UI banner.
- Wrapper-layer chain detection (analogous to the v1 deferral in Brief 2).

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | **Critical** | Brief 1 left a hole; gridctl 0.2 needs an execution model. The constitution was amended yesterday specifically to authorize the runtime that fills it |
| User impact | **Narrow + Deep today, Broad + Deep if gridctl grows** | Serves the early-adopter audience using gridctl as more than a gateway. Aligns with skills-hub-integration's ecosystem flywheel (typed skills become hub-publishable units of value) |
| Strategic alignment | **Core mission** | Defines what gridctl 0.2 is. Three layers (gateway / agent runtime / registry) is the durable shape |
| Market positioning | **Leap ahead** | The code-canon code↔canvas IDE seat is unoccupied; competitors have all chosen code-OR-canvas. Multi-agent single-writer + MCP-native + IDE round-trip is a defensible niche |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | **Significant** | Touches gateway hooks, sandbox, CLI, web UI, tracing, metrics, pricing, optimize. But seams exist; six brief assertions need correction |
| Effort estimate | **Very Large** | Months of single-maintainer work even on the depend path. Phase G IDE alone is 7–10 weeks if scoped to "code as canon, narrow mutations." Rest of phases land cleanly in PR-sized chunks |
| Risk level | **Medium-High** | Bus factor 1 + multi-month timeline + pre-1.0 upstream + significant new UI surface. Mitigated by (a) depend-not-vendor, (b) mandatory adapter layer, (c) scope-locking IDE to code-canon view, (d) explicit v1.5 deferrals |
| Maintenance burden | **Moderate** | Small if depend; the adapter is the only ongoing watch surface. Eino upgrade rhythm: pinned + deliberate, with API-drift CI alarm |

## Recommendation

**Build with caveats.**

The thing to build is mostly the brief's mental model. The runtime-source decision pivots from **vendor-and-prune** to **depend on Eino as a module behind a mandatory adapter layer**, with **in-house held as the documented escape hatch.**

### Specific scope adjustments to fold into the implementation prompt

1. **Phase A renames from "Clone and Prune" to "Add module and write adapter."** Sequence: `require github.com/cloudwego/eino vX.Y.Z` (pin to a specific stable or alpha tag), import only `compose`, `schema`, `callbacks` from eino + only the providers needed from eino-ext. Build `pkg/agent/internal/eino/` as the strict boundary. No Eino types cross out.

2. **Adapter layer is mandatory, not advisory.** A code-review checklist enforces: no `eino.*` types in any public signature outside `pkg/agent/internal/eino/`. CI lint check via `grep` or AST analysis can catch violations.

3. **Phase B (MCP as native tool protocol) lands on the smallest possible surface first** — one skill end-to-end happy path before broadening. `gridctl run examples/skills/hello --input '{"name":"world"}'` against a real provider, emitting trace data, persisting run state. That's the first acceptance gate.

4. **Phase G (IDE) ships in disciplined slices, sequenced observability-first, not visualization-first.** Click-to-`$EDITOR` plus the trace overlay deliver ~80% of what production agent developers actually want in ~5 weeks; the canvas viewer is more visually impressive but adds less marginal value when there is already a typed source-of-truth in `$EDITOR`. Ship the boring useful thing first.
   - Slice 1: click-to-`$EDITOR` jump from a minimal node list (no canvas yet). AST-derived; opens the source line via `editor://`. (<1 week)
   - Slice 2: live trace overlay — status pills, duration, tokens, model, prompt diff between runs, structured-output validation, "Resume from here" on completed steps. (~3–4 weeks)
   - Slice 3: code→canvas viewer. Read-only, AST-derived. Trace overlay decorates this view once it lands. (~3–5 weeks)
   - Slice 4: narrow AST-safe canvas mutations (rename via gopls / rewire edge / add stub node from palette). (~6–10 weeks)
   - Defer canvas-mutates-prompts-or-bodies indefinitely; that's the trap that kills round-trip projects.

   **Quotable design principle**: borrow Temporal's published critique by name — "[The Fallacy of the Graph](https://temporal.io/blog/the-fallacy-of-the-graph-why-your-next-workflow-should-be-code-not-a-diagram)." When canvas-as-source pressure shows up in PR review, the one-liner is **"The fallacy of the graph applies — code is canon."** Code is the typed source-of-truth; the canvas is a derived view. This is the design discipline the IDE is engineered around.

5. **Salvage `web/src/components/playground/PlaygroundTab.tsx`, don't delete it.** Wire `/api/playground/stream` to the new provider abstraction in Phase C. The streaming + trace + provider infrastructure is exactly what the agent IDE will reuse.

6. **Hot-reload split by skill flavor**: TS skills hot-reload on the canvas via goja+esbuild (~300ms achievable). Go skills require explicit `gridctl agent build` and reload deliberately. The `examples/skills/` directory ships a TS skill (`hello.ts`) for the demo + a Go skill (`research.go`) for the production-shaped example. Acceptance criteria reflect this split.

7. **Drop Eino IDE plugin from the rationale entirely.** The custom IDE is the differentiator; the upstream plugin (`eino-ext/devops/`) has 3 commits in 6 months and isn't strategic leverage. Don't relitigate it in commit messages or `THIRD_PARTY.md`.

8. **Multi-agent default `max_parallel=4`** baked in from day one (Phase E).

9. **Approval gates** surface in CLI + web UI + MCP notification simultaneously (Phase F); 24h default; 80%-mark warning.

10. **`gridctl agent init`** ships a runnable hello-world TS skill so `agent dev` opens to something alive (Phase H).

11. **Defer to v1.5**: LLM-response pin store; compiled-artifact fingerprint; canvas-edits-prompts; "ask" approval mode in CLI.

12. **Pre-flight smoke test**: before Phase A bulk lands, ship a tiny dependency-add PR that just imports `eino/compose` and creates a trivial typed graph. Validates the relaxed Article I posture and shakes out any module-resolution issues with eino-ext's per-component go.mod design.

### Acceptance Criteria (revised from the brief)

- `make build` produces a binary that boots both the gateway and the agent runtime.
- `gridctl run examples/skills/hello-ts --input '{"name":"world"}'` runs a typed TS skill end-to-end against a real provider, emits trace data, and persists run state.
- `gridctl run examples/skills/research-go --input '{"topic":"x"}'` runs a typed Go skill end-to-end against a real provider, emits trace data, and persists run state.
- `gridctl agent dev` opens at <3s and reflects TS skill code edits on the canvas in <300ms; reflects Go skill changes after explicit `gridctl agent build`.
- `gridctl runs resume <run_id>` works after a deliberately-killed run.
- A second gridctl instance configured with the first as an MCP server can invoke a typed skill registered on the first — same code path as `gridctl run <skill>` locally (recursive composability).
- An approval-gated skill suspends correctly, surfaces in CLI banner + web UI banner + MCP notification, and resumes on user input.
- A multi-agent skill using `Orchestrator[State]` with two parallel handoffs runs successfully, respects the `max_parallel=4` default cap, and persists a coherent merged state.
- Existing gateway smoke tests still pass: `gridctl apply`, `gridctl link`, `gridctl status`, `gridctl reload`.
- An end-to-end Go example skill ships in `examples/skills/research-go/`: research → summarize → critic → format. Demonstrates `tool()`, `llm()` with typed output, `parallel()` over an array, `handoff()` to a subagent, and an approval gate. Renders correctly in the IDE.
- A TS-flavor demo skill ships in `examples/skills/hello-ts/`. Shorter, illustrative, hot-reloads in the canvas.
- No `eino.*` type appears in any public signature outside `pkg/agent/internal/eino/`. CI lint gate enforces.

## References

- gridctl CONSTITUTION.md (Articles I, II, IX amended in PR #582 / commit 6dcbdb0, 2026-05-08)
- gridctl Brief 1 (`prompts/gridctl/remove-workflow-engine/feature-evaluation.md`) — the predecessor that created the gap this brief fills
- [github.com/cloudwego/eino](https://github.com/cloudwego/eino) — 11.1k stars, Apache 2.0, v0.9.0-alpha.20 (2026-05-08)
- [github.com/cloudwego/eino-ext](https://github.com/cloudwego/eino-ext) — per-component go.mod, 78 modules
- [cloudwego.io/docs/eino/overview/bytedance_eino_practice](https://www.cloudwego.io/docs/eino/overview/bytedance_eino_practice/)
- [github.com/firebase/genkit](https://github.com/firebase/genkit) — Go SDK GA, generic-typed flows
- [pkg.go.dev/github.com/smallnest/langgraphgo](https://pkg.go.dev/github.com/smallnest/langgraphgo) — typed-state DAGs, MIT
- [docs.langchain.com/langsmith/studio](https://docs.langchain.com/langsmith/studio) — LangGraph Studio (viewer + debugger model)
- [temporal.io/blog/the-fallacy-of-the-graph](https://temporal.io/blog/the-fallacy-of-the-graph-why-your-next-workflow-should-be-code-not-a-diagram) — counterargument to graph-as-source
- [aws.amazon.com/blogs/compute/introducing-an-enhanced-local-ide-experience-for-aws-step-functions](https://aws.amazon.com/blogs/compute/introducing-an-enhanced-local-ide-experience-for-aws-step-functions/) — closest extant round-trip prior art (on JSON, not typed code)
- [platform.openai.com/traces](https://platform.openai.com/traces) — trace overlay UX bar
- Cognition: "Don't Build Multi-Agents" (single-writer thesis underpinning Phase E)

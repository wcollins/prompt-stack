# Feature Evaluation: Three-Flavor Skill Authoring Surface (Brief 4)

**Date**: 2026-05-10
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

Brief 4 closes three concrete gaps in gridctl's skill authoring surface so the three-flavor model — prompt / code-ts / code-go, with an explicit hybrid pattern — is fully shipped. The architecture is settled, the gaps are named, and the acceptance criteria are crisp. Premise verification against current code confirms every load-bearing claim except a small off-by-one on the breaking-change blast radius. This is a completion brief, not a redesign — Build, with the brief's own risks (Go plugin sharp edges, breaking `Define[I, O]` signature) acknowledged in scope.

## The Idea

Three concrete code changes plus a compatibility test, three example skills, and a docs file:

1. **Go-handler scaffold + build.** Replace the `Phase H` deferred error in `cmd/gridctl/agent.go` with a real `go build -buildmode=plugin` path; emit a `manifest.json` with the same shape as the TS path; wire `SetSkillRegistry` registration at gateway-builder time so `.so` artifacts adjacent to Go-handler skills self-register via a `RegisterSkill(*skill.Registry) error` plugin symbol.
2. **`ctx.SkillBody()` accessor.** Extend the typed `Define[I, O]` first argument from `context.Context` to a richer execution context that exposes the parsed post-frontmatter markdown body and the registered skill name. Pre-1.0 breaking change; intentional cut, no migration shim.
3. **Scaffold flavor flags.** Add `--lang ts|go` (default `ts`) and `--prompt-only` (mutually exclusive with `--lang go`) to `agent init` so all three flavors are scaffoldable, not just TS.

Plus: a vendored Anthropic skill compatibility test, three new example skills (triage-ts, triage-go, incident-triage-hybrid), and a `docs/skills.md` that names the three flavors as a coherent set.

## Project Context

### Current State

gridctl already implements the elegant "file-presence is the discriminator" model the brief defends. The store walker (`pkg/registry/store.go:506` `detectHandler`) populates `AgentSkill.HandlerLanguage` (`"go"` / `"ts"` / `""`) and `HandlerPath` at load time; the frontmatter stays vanilla agentskills.io-compliant. The typed SDK at `pkg/agent/skill/{skill.go,typed.go}` exposes `Define[I, O]`, `Definition`, `Registry`, and `Invoker`. The TS scaffold + build + validate paths are all shipped (`pkg/agent/dev/scaffold/`, `cmd/gridctl/agent.go`). The IDE under `web/src/components/agent/ide/` already handles all three flavors correctly (prompt skills render as a single node; code skills parse to a graph). The Eino adapter boundary at `pkg/agent/internal/eino/` is enforced by `scripts/check-eino-boundary.sh`.

The two prompt-only example skills exist (`examples/registry/items/code-review/SKILL.md`, `explain-error/SKILL.md`); typed examples do not.

### Integration Surface

- `pkg/agent/dev/scaffold/scaffold.go` — add `Language` field to `Options`; gate `agent.json` and the TS body on it; add Go and prompt-only branches.
- `cmd/gridctl/agent.go` — add `--lang` + `--prompt-only` flags to `agentInitCmd`; replace the deferred Go path in `runAgentBuild` (line 345-362) with a real `go build -buildmode=plugin` implementation; update post-scaffold hint by flavor.
- `pkg/agent/skill/typed.go` — change `TypedRunner[I, O]` to take a richer execution context type; thread `body` and `name` through `Define[I, O]`'s closure so they're captured at registration, not loaded per-call.
- `pkg/controller/gateway_builder.go` — at the existing `Build()` site (around line 178-220 where `registryStore` and `registryServer` are created and `SetTSDispatcher` is wired), add the `.so` discovery + `plugin.Open` + `RegisterSkill` loop, then call `registryServer.SetSkillRegistry(reg)`.
- `pkg/registry/store.go`, `pkg/registry/types.go` — already fine; `AgentSkill.Body` is parsed and serialized today, no schema change.
- `tests/integration/anthropic_skill_compat_test.go` — new file.
- `examples/registry/items/{triage-ts,triage-go,incident-triage-hybrid}/` — new directories.
- `docs/skills.md` — new file (the existing `docs/api-reference.md` does not have a dedicated skills authoring section).

### Reusable Components

- `sandbox.TranspileTS` — already shared between `agent build` and `agent validate`. The Go path doesn't need it but the precedent (one transpiler, two callers) is the model for "one builder, two artifact shapes."
- `sha256Hex` in `cmd/gridctl/agent.go:31` — used for TS source fingerprint. Reuse verbatim for Go source fingerprint.
- `agentBuildReport` JSON shape — already supports `Status: "ok" | "deferred"` and a `Notes` field. The Go path produces the same envelope with `Status: "ok"` on success.
- `Server.SetSkillRegistry` (`pkg/registry/server.go:98`) and `Server.CallTool` lookup order (registry first, TS dispatcher fallback) — already in place. The Go path piggybacks on this with no server-side changes.

## Brief vs reality (premise verification)

The brief's claims hold against current code with three small adjustments worth folding into the implementation prompt:

1. **`Define[I, O]` callers — three, not two.** The brief says updating the handler signature affects "the `pkg/agent/skill` test fixtures and any hello scaffold code." Reality: there's a third call site at `pkg/agent/sandbox/recursive_test.go:46` — the cross-package recursive composition smoke test that registers a `greet` skill against a `skill.Registry` and exercises it through a TS handoff. All three call sites are first-party; the migration is still tractable. The implementation prompt names all three.

2. **The scaffold has an exported test-channel pattern.** `pkg/agent/dev/scaffold/scaffold.go:121-126` exports `HelloSkillTS(name string) string` so the regression suite can run scaffold output through the sandbox verbatim, keeping scaffold and runtime tests pinned to one source. The Go scaffold should mirror this — export `HelloSkillGo` so a Go-side test channel exists from the start. The brief does not call this out; the implementation prompt does.

3. **Prior evaluation context.** This Brief 4 completes a thread started by the Brief 3 feature evaluation at `prompts/gridctl/completed/code-first-agent-runtime/feature-evaluation.md`. That evaluation pivoted the original "vendor Eino" approach to "depend on Eino as a Go module behind a mandatory adapter layer" and named recursive composability as a non-negotiable constraint — both decisions are still intact in current code. Brief 4 sits on top of that work; the implementation prompt cites it for context but does not re-litigate.

## Post-review additions (Gemini feedback)

A second-pass review (`gemini_feedback.md` in the gridctl repo) caught two genuinely load-bearing gaps and one nice-to-have. All three are folded into the implementation prompt:

4. **Manifest guardrails for Go plugins.** Document the operator-facing pain at the data level, not just in package docs: record `go_version` and a hash of `go.mod` in the Go skill's `manifest.json` at `agent build` time, then check both fields against the running daemon at `loadGoSkillPlugins` time. On mismatch, emit an explicit, actionable `slog.Warn` ("plugin built with Go 1.26.3, daemon running 1.27.0 — rebuild with `gridctl agent build <name>`") rather than letting the opaque `plugin.Open` error confuse the user. This is the single highest-value addition from review — the Day-2 plugin-version-skew failure mode is the most-cited Go-plugins sharp edge in the wild, and a manifest-level check turns "your plugin won't load and the error is incomprehensible" into "your plugin won't load and here's exactly what to do."

5. **TS hybrid parity.** The brief made `ctx.SkillBody()` Go-only. That silently breaks the "all flavors are first-class" invariant — a TS skill running in the goja sandbox should be able to use its own markdown body as a system prompt for the same reasons a Go skill can. The hook is already in place: `sandbox.Bindings` (`pkg/agent/sandbox/sandbox.go:58`) and `BindingsProvider func(ctx context.Context, skillName string) Bindings` (`dispatcher.go:45`) are designed for exactly this kind of extension. Add `SkillBody string` + `SkillName string` to `Bindings`; surface them in the JS sandbox as a `skill.body` / `skill.name` (or `context.body` / `context.name`) global. The incident-triage-hybrid example then demonstrates the pattern in both languages, not just Go.

6. **`go/ast` symbol check in `agent validate` (recommended, not required).** The brief calls for `agent validate` to be non-invasive on Go skills. A lightweight stdlib `go/parser`-based check that the file declares an exported `func RegisterSkill(*skill.Registry) error` catches the most common copy-paste error before the user wastes a `go build` round-trip. Cheap to add; honest enough to omit if scope pressure pushes back.

A fourth Gemini suggestion — design `manifest.json` schema to be extensible for a future `handler: "go-binary"` (sub-process MCP) flavor — is honest but YAGNI given the brief's "ship plugins first, measure pain, revisit" stance. Captured in the prompt as a passing note in "Out of Scope" so the field naming doesn't paint the schema into a corner, but no proactive scaffolding.

Everything else verifies cleanly:
- Phase H deferred path is at `cmd/gridctl/agent.go:362`.
- `agent init` lacks `--lang` and `--prompt-only` (only `--name`, `--dir`, `--force`, `--format`).
- `AgentSkill.Body` exists and is already parsed (`pkg/registry/types.go:36`).
- `Server.SetSkillRegistry` exists but is not currently called from `gateway_builder.go` — only `SetTSDispatcher` is wired. The brief's plan to call it at gateway-builder time fits cleanly.
- `scripts/check-eino-boundary.sh` and the `pkg/agent/internal/eino/` boundary exist and are enforced.

## Market Analysis

### Competitive Landscape

Three reference points:

- **agentskills.io** is the upstream open standard for the SKILL.md envelope. gridctl's frontmatter is already compliant; the `state:` and `acceptance_criteria:` fields are documented gridctl extensions and stay that way. Anthropic's `github.com/anthropics/skills/document-skills/` repo ships prompt-only skills against the same spec; the round-trip compatibility test in this brief is the headline "we implement the open standard" proof.
- **MCP-native typed-tool authoring** (Anthropic SDK, `mcp-server-typescript`, etc.) gives strong typed input/output schemas but no notion of "the skill's own markdown body is the system prompt." The hybrid pattern this brief introduces is genuinely novel against that landscape.
- **Go plugin alternatives** — `hashicorp/go-plugin` (sub-process gRPC) and per-skill MCP servers — are operationally more durable than `plugin.Open` but require an IPC layer the codebase does not currently have. The brief's "ship plugins first, measure pain, revisit" call is the right one for a single-maintainer pre-1.0 project.

### Market Positioning

Differentiator. The "file presence as discriminator" + "markdown body as system prompt" + "code is canon, canvas is a derived view" combination is unoccupied in the agent runtime market in May 2026. Most competitors force authors to pick one of: pure prompt (Anthropic skills, OpenAI Assistants), pure code (LangGraph, Pydantic AI), or YAML-orchestration-glue (n8n, Flowise) — gridctl's three-flavor surface lets the author pick per skill without switching tools.

### Demand Signals

The brief is internally driven (William's roadmap continuation from Brief 3) rather than reactive to user requests. That's fine for a single-maintainer pre-1.0 tool — the cost of consulting hypothetical users for a completion brief outweighs the signal. Real demand will surface from the round-trip compat test (proves we host an existing Anthropic skill unchanged) and from the hybrid example (proves the SRE use case survives a real LLM call).

## User Experience

### Interaction Model

Three discrete entry points for skill authors, each with a one-line scaffold:

- `gridctl agent init --prompt-only --name foo` — markdown only. Drop into `~/.claude/skills/` to use elsewhere.
- `gridctl agent init --lang ts --name foo` (default) — TS code skill. `gridctl agent dev --root .` opens the IDE.
- `gridctl agent init --lang go --name foo` — Go code skill. Same dev path, plus `gridctl agent build` produces a `.so` the gateway picks up at next start.

Post-scaffold hint changes per flavor (TS/Go: `gridctl agent dev --root <dir>`; prompt-only: `gridctl skill list --remote && gridctl run <name>`).

### Workflow Impact

Reduces friction. Today the only scaffolded path is TS; an author who wants a Go skill or a prompt-only skill writes the directory by hand. After this brief, the three flavors are uniformly first-class. The hybrid pattern (markdown body as LLM system prompt) is documented and demonstrable in a single example, lowering the cost of trying it.

The breaking change to `Define[I, O]`'s handler signature is a one-time author-visible cost. The blast radius is narrow (three first-party call sites + the new Go scaffold). Pre-1.0 cuts are cheap; the alternative — parallel new-API + deprecation — is overhead that pays back only post-1.0.

### UX Recommendations

- The Windows error path on `agent build` for Go skills must be explicit and actionable. "go skill build requires Linux or macOS — Go plugins are not available on Windows" beats "plugin: open: failed."
- The post-scaffold hint differentiation (TS/Go vs prompt-only) is small but matters: telling a prompt-only author to `gridctl agent dev` would be a dead end.
- Document the Go plugin operational sharp edges (host/plugin Go-version match, dep-graph match, no unloading) in the package doc that introduces plugin loading. Not in the user-facing docs — in the developer-facing comments where someone debugging a `plugin.Open` failure is going to look first.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Closes a named "Phase H deferred" path that is currently a friction point for any author who wants Go-handler skills. The hybrid pattern enables a real use case (SRE runbook prose as system prompt). |
| User impact | Narrow + Deep | Single-maintainer-aware: the audience is gridctl users authoring custom skills, not a general developer audience. Deep impact for that audience because it removes the only remaining "you can't do that here" in the authoring surface. |
| Strategic alignment | Core mission | The three-flavor model is the differentiator the project has been building toward. Brief 4 ships the last 20% of the surface. |
| Market positioning | Maintain → Leap ahead | Competitors don't have the hybrid pattern. Shipping it as a documented, exampled flavor is the moment the project stops being "another agent runtime" and becomes a defensible take. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | All four work-streams have clear hooks in current code. The gateway-builder wiring is the most novel piece but it slots in alongside the existing `SetTSDispatcher` call. |
| Effort estimate | Medium | Four code work-streams + a compat test + three examples + a docs file. Single-maintainer-shippable in a few PRs. The Go-plugin path is the pacing item. |
| Risk level | Medium | Two named risks: (1) Go plugin operational sharp edges (host/plugin Go-version match, no unloading, platform-specific) — real but cost-of-doing-business; (2) breaking `Define[I, O]` signature — narrow blast radius, manageable with the corrected three-caller scope. The brief flags a sub-process MCP-server fallback if plugins prove unworkable; reserve as a documented escape hatch, do not preempt. |
| Maintenance burden | Moderate | Go plugin host/plugin version-match constraint will surface as toolchain-bump pain when the Go release rolls. Document the constraint honestly; revisit if the constraint becomes a recurring incident. |

## Recommendation

**Build.** The brief is right, the gaps are concrete, and the verification surfaced no premise that needed correction beyond the off-by-one on caller count and the test-channel parity observation — both folded into the implementation prompt. The architecture and acceptance criteria stand. The two named risks are acknowledged in the brief itself and have stated fallbacks (sub-process MCP server for Go plugins; pre-1.0 cut for the SDK breaking change).

What would push toward "Build with caveats" is not present here: the brief does not propose an architectural pivot, does not introduce a new abstraction layer, does not require unproven third-party dependencies. It connects existing pieces with named hooks. Resist the urge to add abstractions; ship the four code changes plus the test, examples, and docs.

## References

- Anthropic open skills repo (round-trip compat fixture source): `github.com/anthropics/skills/document-skills/pdf-processing/`
- agentskills.io specification — the SKILL.md frontmatter standard the project conforms to.
- Go plugins documentation (`go doc plugin`) for the operational sharp edges enumerated in the package doc.
- Prior evaluation: `prompts/gridctl/completed/code-first-agent-runtime/feature-evaluation.md` — the Brief 3 evaluation that established the three-flavor architecture this brief completes.

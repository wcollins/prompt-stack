# Feature Evaluation: Context Auto-Injector (scoped from "Decoupled Context Sessions")

**Date**: 2026-05-26
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High (problem) / Moderate (gridctl's differentiation)
**Effort**: Small–Medium (scoped) — down from Large (original plan)

## Summary

Persistent, cross-client agent context is a genuinely valuable, loudly-requested capability: the pain of losing two hours of Claude Code research when you switch to Claude Desktop is real, and a gateway that *auto-injects* prior findings without the LLM asking is a "feels magically smart" feature. **But the originally-proposed architecture should not be built.** It reinvents gridctl's mature variable store, reintroduces subsystem surface area the project just deliberately removed, and concentrates ~90% of its effort in plumbing while the actual value lives in one piece: the gateway-side auto-injection glue. The recommendation is to build a **deliberately scoped "Context Auto-Injector"** — a flat markdown findings log + the existing variable store's Sets for structured vars + bounded auto-injection into the MCP prompt path — and to differentiate on **zero-config convenience plus governance** (provenance, TTL, audit), not on retrieval capability.

## The Idea

**As proposed** (`proto/context.md`): a new `pkg/context` package managing persistent "sessions" under `~/.gridctl/sessions/` (per-session `findings.md` + `state.json` key-value store + an `index.json`), a `context_session:` stack field, gateway injection of `{{session.findings}}`/`{{session.var}}` into prompts, a built-in "system server" exposing `gridctl__save_finding`/`set_session_var`/`recall`, five new REST endpoints, a header session selector, a ⌘5 Context workspace, and a session-gallery management page.

**As scoped (this recommendation)**: keep the *outcome* (cross-client persistent context auto-injected into the agent), discard the bespoke machinery. Storage = a flat `~/.gridctl/sessions/<name>.md` findings file + the **existing variable store's Sets** for structured values (no `state.json`, no new KV engine). Binding = a `session_binding:` field on the stack. Net-new value = the gateway reads the bound session's markdown + Set values and injects them — **size-bounded** — into the prompt path. One small built-in append tool lets the agent write findings. Governance (provenance/TTL/audit/validation) is the differentiator.

**Who benefits**: every gridctl user who drives MCP tools from more than one client, or who rebuilds throwaway stacks and wants context to survive. Broad but shallow per-session impact.

## Project Context

### Current State

gridctl is an MCP gateway/orchestrator (Go + a React/TS console) at **v0.1.0-beta.10** (21 tags since Jan 2026; strong test culture with enforced per-package coverage gates). Critically, the `[Unreleased]` CHANGELOG records a recent **scope contraction**: the entire agent-runtime surface (sandbox, run ledger, `agent`/`run`/`runs` commands, Stage/Runs/Playground UI) was removed to refocus on the "MCP-gateway-with-skill-library" niche. Any "agent memory" feature must therefore be justified as **gateway infrastructure** (shared context across the fan-out), not as "gridctl becomes an agent platform." The scoped framing stays on the right side of that line; the maximal plan does not.

### Integration Surface

- `pkg/mcp/gateway.go` — `HandlePromptsGet` (line ~1592) **already performs `{{name}}` substitution** with client-arg-wins-over-default merge — the exact injection semantics the plan describes. `buildInstructions()` (line ~1146) composes the `initialize` Instructions string. The `Gateway` struct (line ~119) holds **no `config.Stack` / no stack name** — resolving the active session needs a new injected dependency (a `SessionResolver`).
- `pkg/vault/store.go` + `types.go` — the mature variable store (typed, encrypted, grouped into "Sets", atomic writes, mtime-reload). The plan's `state.json` is a strict, weaker subset; reuse this instead.
- `pkg/config/loader.go::expandStackVars` + `pkg/config/expand.go` — `${var:KEY}` expansion touches **stack YAML only**, not prompt bodies. `secrets.sets:` already auto-injects a Set's members into MCP server envs at load — the precedent for "a stack names a stored artifact the gateway pulls in."
- `pkg/state/state.go` — the `~/.gridctl/` directory convention (`BaseDir`, `VaultDir`, etc.) + `WithLock` flock; add `SessionsDir()`/`SessionPath()` here.
- `pkg/config/types.go` — the `Stack` struct; add the `session_binding:` field (Article IX backward-compat rules apply).
- `internal/api/api.go` + `internal/api/vault.go` — Go 1.22 method-prefixed routes + store-setter injection; the CRUD handler + test idiom to clone.
- `pkg/registry/server.go` / `pkg/mcp/codemode_tools.go` — the in-process MCP server and the synthetic gateway-native tool patterns (template for the one append tool).

### Reusable Components

- **Variable store Sets** → session variables (no new storage engine).
- **`HandlePromptsGet` substitution loop** → extend with bounded `{{session.*}}` resolution.
- **`pkg/pins/store.go`** (RWMutex + `state.WithLock` flock, version field, corrupt-file tolerance, `NewWithPath` test hook) → template for the tiny session store/index.
- **`web/src/components/vault/VaultPanel.tsx`** + the `showVault`/`toggleVault` `useUIStore` pattern → the right-docked session panel.
- **Audit Mode** in `ToolsWorkspace.tsx` (`AUDIT_STYLES` provenance dots, lookback `<select>`, confirm-gated remediation banner) → the governance/transparency surface.
- **`web/src/components/wizard/VaultSetSelector.tsx`** + StackForm "Secrets" accordion → clone for the session-binding affordance.
- **`SpecTab.tsx`** read-only annotated viewer → the "what's being injected right now" preview (no prompts UI exists today).

## Market Analysis

### Competitive Landscape

The "agent writes its own markdown memory + KV, injected into context, with self-write/recall tools" pattern is the one the market converged on in 2025: **Anthropic's own products use it** (CLAUDE.md, the Claude memory tool `memory_20250818`, Claude Code auto-memory with a 200-line/25KB injection cap), as do **Letta/MemGPT** (self-editing memory blocks), **LangMem**, and the **official MCP memory server** (knowledge-graph in JSONL). The gridctl proposal is nearly a feature-for-feature replica of Claude Code's auto-memory model, exposed over MCP.

### Market Positioning

The *pattern* is **table-stakes** (expected, not innovative). gridctl's defensible wedge is **placement + governance**, not capability:
- **Zero-config / batteries-included** — works the moment the gateway runs; no server to find, vet, wire.
- **Survives ephemeral stack rebuilds** — memory at the gateway outlives the disposable stack.
- **Auto-shared across every client through the one endpoint** — the cross-client win, with no per-client setup.
- **Governance** — provenance, TTL, audit, validation-against-current-reality. The commodity servers skip this; gridctl already ships **Audit Mode**, making it on-brand.

### Ecosystem Support

Build the minimal file-backed version; **do not integrate mem0 or a vector DB** — mem0 has no Go SDK and self-hosting needs a 3-container stack (Postgres/pgvector + Neo4j), antithetical to a single-binary CLI. The "markdown file beats a vector DB at single-user scale" thesis is now mainstream; the official MCP memory server's file-backed (JSONL) design confirms no vector infra is needed. MCP itself has **no memory primitive and is moving stateless by design** (2026 roadmap) — so a gateway-owned implementation **won't be obsoleted by a future protocol feature**, and injecting via `prompts` + exposing `tools` is spec-aligned.

### Demand Signals

**Strong for the problem, moderate for gridctl's specific slice.** Supermemory MCP reports ~63k daily users; agentmemory ~18k GitHub stars; Claude Code's persistent-memory request (#14227) was closed "not planned," leaving the gap open. *But* "memory" is the single most crowded MCP category — **552 servers on PulseMCP** — and a user can `npx @modelcontextprotocol/server-memory` into their stack in two lines and get a better engine. The unmet slice is narrower than raw demand: convenience + cross-client + governance, not "best memory."

## User Experience

### Interaction Model

- **Discovery / Activation**: a new "Session" accordion in the Creation Wizard's StackForm (cloned from the "Secrets"/`VaultSetSelector` precedent) writes `session_binding:` into the stack YAML; it rides the existing wizard→apply pipeline. For running stacks, a **Header binding badge** (`◆ session: <name>`) — the one affordance `secrets.sets` never got, and the one the governance story requires.
- **Interaction**: the badge opens a **right-docked session panel** (cloned from `VaultPanel`, toggled via the `showVault` pattern) showing the findings markdown + resolved Set values, each row carrying a provenance badge (user ✎ / LLM ⚙), age/expiry, and an "injected / over-cap / expired" status chip. An **injection-preview** toggle renders the exact bounded payload the gateway will hand to `prompts/get` (Spec-viewer styling).
- **Feedback**: success/error toasts on append/prune; a live **size/line-cap meter** ("142 / 200 lines · 18 / 25 KB"); the badge turning amber when items are expiring. Surface "Writing memory" events in the request trace.

### Workflow Impact

Near-zero friction on the core apply/serve/link flow — binding is opt-in stack config, injection is automatic. The single new affordance (inspect/prune live session memory) maps cleanly onto the existing toggleable-panel pattern.

### UX Recommendations

Adopt the validated patterns and avoid the documented failures:
- **Make injection visible** (Letta ADE / Claude Code `/memory`) — never inject context with no UI to inspect it. **The Cursor anti-pattern** (silent, invisible "Memories" that broke trust) is the exact failure to avoid.
- **Surface write/recall events inline** (Claude Code "Writing memory", Windsurf toast).
- **Provenance badges** + filter (Claude Code You-vs-Claude, Copilot repo-vs-personal); treat LLM-written findings as **untrusted-until-reviewed** (memory-poisoning is a documented attack — sanitize before inject).
- **Token/size budget bar** against an explicit cap; overflow marked "not injected," not silently dropped.
- **TTL/expiry + auto-prune** (Copilot's 28-day default) and **validation-against-current-reality** (the gateway analog: suppress findings referencing servers/tools that no longer exist).
- **Per-entry delete + bulk delete + filter** (avoid Copilot's clear-all-only limitation).

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Cross-client context loss is real and loudly voiced |
| User impact | Broad + Shallow | Every multi-client user; a convenience, not a blocker |
| Strategic alignment | Adjacent → Core (scoped) | Gateway-as-shared-context is on-mission; the maximal plan is not |
| Market positioning | Maintain / mild catch-up | Pattern is table-stakes; edge is convenience + governance |

### Cost Breakdown
| Dimension | Rating (scoped) | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Gateway needs a session resolver it lacks; injection on a hot, locked path |
| Effort estimate | Small–Medium | Reuse var-store Sets + existing `{{}}` substitution + VaultPanel collapses it from Large |
| Risk level | Medium | Memory poisoning, context bloat, gateway↔stack decoupling, `~/.gridctl/` concurrency |
| Maintenance burden | Moderate | Flat .md + reused Sets is light; governance adds on-brand surface |

## Recommendation

**Build with caveats — the caveats are the scope.** Ship the Context Auto-Injector, not the maximal plan. Specifically:

**Build:**
1. A flat `~/.gridctl/sessions/<name>.md` findings file (+ a tiny index for listing/metadata), modeled on `pkg/pins/store.go`.
2. **Reuse the variable store's Sets** for structured session variables — no `state.json`.
3. A `session_binding:` field on `Stack`.
4. The net-new value: **bounded auto-injection** of the bound session's markdown + Set values into the gateway's prompt path (extend `HandlePromptsGet`), via a new `SessionResolver` dependency on the gateway.
5. One small built-in append tool (`save_finding`); a `recall`/read is optional v1.
6. Governance: provenance, TTL + auto-prune, size cap with overflow marking, validation against current servers/tools, audit trail. Treat LLM writes as untrusted; sanitize before inject.
7. Minimal UI: Header binding badge + a `VaultPanel`-style session panel + injection preview. **No ⌘5 workspace, no gallery page.**

**Cut:** the `pkg/context` subsystem, `state.json` + `set_session_var`, the full REST suite, the gallery, the dedicated workspace.

**Do not:** integrate mem0 / any vector DB.

**Caveats / risks to manage:**
- **Gateway↔stack decoupling** — the gateway has no stack awareness today; thread a `SessionResolver` in rather than coupling the gateway to config. Keep the session store's lock strictly inner to avoid lock-ordering deadlocks with `g.mu`.
- **Hot-path I/O** — cache/lazy-load session data; don't read files on every `prompts/get`.
- **Context bloat** — enforce the size cap (the whole feature is pointless if it blows the budget it claims to protect).
- **Security** — sanitize/escape LLM-written findings so a malicious tool response can't inject gateway-level instructions; the audit trail is the detection mechanism.
- **Naming** — avoid `pkg/context` (shadows stdlib) and "Session" (collides with `pkg/mcp/session.go` MCP-protocol sessions). Prefer `pkg/agentmem` / "context session" naming that doesn't collide.

A reasonable **even-leaner v0** (worth considering before committing to governance): just `session_binding:` + bounded injection of a flat .md the user (or any filesystem MCP server) writes — prove the auto-injection value first, add the write tool + governance once the core lands. The implementation prompt phases the build this way.

## References

- Anthropic context engineering: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic memory tool / context management: https://www.anthropic.com/news/context-management · https://docs.claude.com/en/docs/agents-and-tools/tool-use/memory-tool
- Claude Code memory (200-line/25KB cap): https://code.claude.com/docs/en/memory
- MCP has no memory primitive / stateless direction: https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/1226 · https://blog.modelcontextprotocol.io/posts/2025-12-19-mcp-transport-future/
- Official MCP memory server (file-backed): https://github.com/modelcontextprotocol/servers/tree/main/src/memory
- Crowded category (552 servers): https://www.pulsemcp.com/servers?q=memory
- Cross-client pain point: https://vexp.dev/blog/cross-agent-context-share-memory-cursor-claude-code-codex · https://mem0.ai/blog/introducing-openmemory-mcp
- Claude Code persistent-memory request (closed "not planned"): https://github.com/anthropics/claude-code/issues/14227
- GitHub Copilot memory (28-day TTL, validation, provenance, bulk delete): https://docs.github.com/en/copilot/how-tos/use-copilot-agents/copilot-memory
- Letta ADE memory blocks (live token indicators): https://docs.letta.com/guides/ade/core-memory/
- Cursor silent-memory anti-pattern: https://forum.cursor.com/t/unable-to-view-or-manage-memories-and-no-notifications/124572
- Memory-injection attack (transparency/security case): https://www.theregister.com/2025/10/27/atlas_vulnerability_memory_injection
- mem0 has no Go SDK: https://github.com/mem0ai/mem0

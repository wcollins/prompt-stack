# Feature Evaluation: Agent Runtime Removal (Skills Redesign)

**Date**: 2026-05-21
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Large (~20K LOC across two PRs)

## Summary

Remove the agent execution runtime (orchestrator, sandbox, persist, TS/Go handler
dispatch, dev IDE, runs ledger) from gridctl so the project focuses on its
defensible niche: an MCP gateway with a built-in workspace for authoring
prompt-only skills served as MCP prompts to upstream clients. The architectural
seams are clean, the strategic alignment is strong, and no major MCP gateway
today combines tool aggregation with a skill-authoring UI — so the post-removal
gridctl owns a niche that 17+ competing MCP gateways don't address.

## The Idea

Delete `pkg/agent/` (orchestrator, runtime, sandbox, persist, skill, gateway,
LLM provider abstractions, dev server), the `gridctl agent` and `gridctl runs`
CLI commands, the `/api/agent/*` and `/api/playground/*` API surface, and the
Stage/Runs/Playground web workspaces. Keep the MCP gateway core, the registry
serving skills as MCP prompts, the Topology workspace, and the Library
workspace for authoring `SKILL.md` markdown + frontmatter.

The problem it solves: gridctl currently spans three product categories
simultaneously — MCP gateway, agent runtime, and skill library. The agent
runtime category is dominated by well-funded incumbents (LangGraph, CrewAI,
AutoGen, OpenAI Agents SDK) and the LLM platform vendors themselves. Competing
there as a small project is unwinnable; staying there drains effort from the
parts that actually differentiate gridctl.

Beneficiaries: every gridctl user. CLI users get a smaller, more focused tool.
UI users get a simpler two-workspace mental model (Topology + Library). MCP
client users (Claude Code, Claude Desktop, Cursor, Codex, etc.) keep working
because the registry-as-prompt-provider path is preserved unchanged.

## Project Context

### Current State

gridctl is an MCP gateway tool, pre-1.0 (v0.1.x alpha). The codebase contains:

- **pkg/agent/** — 66 files, ~15,493 LOC across orchestrator (1.4K LOC),
  persist (2.1K LOC), sandbox (2.6K LOC), llm providers (3.5K LOC), dev tooling
  (2.3K LOC), runner (792 LOC), runtime (188 LOC), skill (780 LOC), compose
  (896 LOC), gateway (106 LOC), and the internal/eino adapter (331 LOC). All
  of this is execution-side machinery.
- **pkg/mcp/** — the actual MCP gateway and router (separate from
  `pkg/agent/gateway/`, which is the agent-side gateway adapter).
- **pkg/registry/** — the skill store and the MCP server that exposes skills
  as prompts. The `Server` type implements both `mcp.AgentClient` and
  `mcp.PromptProvider`; only the AgentClient bits relate to typed-skill
  execution and can be excised.
- **Recent commit `2411deb` (May 20)** added the Library workspace and renamed
  the old Skills tab to "Stage." This is the UI structure the redesign builds
  on — preserve the Library, delete the Stage.

The remaining 4-tab UI (Topology / Stage / Library / Runs) is bookended by
~1.7K LOC of `pkg/controller/gateway_builder.go` that assembles the agent
runtime aggregate and wires it into the gateway and API server.

### Integration Surface

Architectural seams from a code-reading session:

1. **`pkg/mcp/gateway.go:124-126`** defines `AgentRuntime` as an opaque marker
   interface. The runtime is stored on the gateway via `SetAgentRuntime()`
   and read via `AgentRuntime()`. Concrete consumers (HTTP handlers,
   dispatcher bindings) type-assert to `*agent/runtime.Runtime` to reach the
   internals. Removing this is a deletion of three methods, one field, one
   interface — that simple.

2. **`pkg/registry/server.go:23-37`** defines `SkillRegistry` and
   `TSDispatcher` as the only execution interfaces on the registry. These
   are the dispatch entry points; once gone, `Tools()` returns empty and
   `CallTool()` returns an error (both required by `mcp.AgentClient`).

3. **`pkg/registry/types.go:47-48`** has the `HandlerLanguage` and
   `HandlerPath` fields. They're tagged `yaml:"-"` so the SKILL.md frontmatter
   format doesn't depend on them; removal is field-level surgery with no
   parser changes.

4. **`pkg/controller/gateway_builder.go`** has ~200 LOC of runtime
   instantiation (lines 197-230, 675-697, 905-982) including
   `makeDispatcherBindings()`. The whole block deletes.

5. **`internal/api/api.go`** has `SetAgentRuntime()` plus per-component
   setters (run store, approval registry, TS dispatcher, dev server). All go.

6. **`web/src/components/shell/AppShell.tsx:11,19-20,125-126,147`** has the
   four hooks/components (`useGlobalRunsStream`, `useRunsCommands`,
   `ApprovalBanner`) that the redesign removes.

### Reusable Components

What survives intact:

- **`pkg/mcp/`** — gateway, router, session manager. No agent imports.
- **`pkg/registry/`** minus `SkillRegistry`/`TSDispatcher` interfaces and the
  `pkg/agent/skill` import. The `PromptProvider` implementation
  (`ListPromptData`, `GetPromptData`) is handler-agnostic and stays.
- **`pkg/optimize/`** and **`pkg/pricing/`** — investigated; no actual
  imports of `pkg/agent/persist` despite the comments suggesting coupling.
  Clean decoupling confirmed.
- **`web/src/components/workspaces/{TopologyWorkspace,LibraryWorkspace}.tsx`**
- **`web/src/components/registry/{LibraryGrid,SkillEditor}.tsx`**
- **REST API**: `/api/registry/*` endpoints (CRUD on SKILL.md files,
  activate/disable, supporting files) all stay.

### Risk Surface

From the explore-agent risk report:

- **Test coverage**: ~20 `*_test.go` files inside `pkg/agent/` delete outright,
  plus `cmd/gridctl/{agent,run,runs}_test.go`. Integration tests under
  `tests/integration/` need light pruning (`hot_reload_test.go`,
  `skills_private_git_test.go`); core tests like
  `anthropic_skill_compat_test.go` and `runtime_test.go` survive because they
  use `pkg/registry` and `pkg/runtime` (Docker orchestration), not
  `pkg/agent`.
- **Documentation**: `docs/skills.md` (17 KB) needs significant rewrite;
  `docs/cli-reference.md`, `docs/api-reference.md` need trims; README needs
  feature-block updates. Tedious but mechanical.
- **CI**: no workflow changes needed. `Makefile` has no agent-specific
  targets.
- **External schemas**: no published clients, no OpenAPI generation surface
  for agent endpoints.

## Market Analysis

### Competitive Landscape

Two adjacent categories with very different population density:

**Agent runtime frameworks** (crowded, well-funded):
- LangGraph (graph-based orchestration, surpassed CrewAI in GitHub stars early
  2026)
- CrewAI v1.12 (shipped agent skills + native LLM providers)
- AutoGen v0.4, OpenAI Agents SDK (graph-based execution adoption)
- Plus the LLM platforms themselves (Anthropic SDK, OpenAI Codex)

**MCP gateways** (also crowded, 17+ players):
- IBM ContextForge (Apache 2.0, 3,500+ stars, federates MCP/A2A/REST/gRPC)
- Bifrost (Go, OpenAI-compatible API + MCP gateway, Maxim AI)
- MetaMCP (proxy/aggregator/middleware)
- Docker's open-source MCP Gateway (per-container isolation)
- Kong AI Gateway (MCP Proxy plugin in Gateway 3.12)
- agentgateway (Linux Foundation), Cloudflare MCP Server Portals, Microsoft
  MCP Gateway, MCPX (Lunar.dev), Obot, Portkey, Supergateway, Unla,
  MCPJungle, MCProxy, mcp-proxy, MCP Mesh

**The underserved niche**: MCP gateway + skill curation UI. None of the 17+
MCP gateways above include a skill-authoring workspace. FastMCP has a
`SkillsProvider` for serving SKILL.md files as MCP resources, but it's a
Python library without UI. Anthropic's own SDK and the `anthropics/skills`
repo cover authoring conventions but provide no gateway.

### Market Positioning

**Pre-removal** — gridctl spans three categories (gateway, runtime, library),
none of which it leads.

**Post-removal** — gridctl owns "MCP gateway with skill-authoring UI." A
defensible niche: small enough that giants haven't entered, structural enough
that it solves a real workflow (curate prompts, serve to upstream clients,
iterate via UI).

**Timing**: ideal. Anthropic donated MCP to CNCF; OpenAI adopted Agent Skills
(Dec 2025); 20+ platforms (Claude Code, Claude Desktop, Codex, Gemini CLI,
GitHub Copilot, Cursor, VS Code) honor the SKILL.md spec. The "skills served
as MCP prompts" pattern is the convergence point of two newly-standardized
specs.

### Ecosystem Support

- **Agent Skills spec** ([agentskills.io](https://agentskills.io/specification))
  is open and stable. SKILL.md format = YAML frontmatter + markdown,
  optional `scripts/`, `references/`, `assets/` subdirs.
- **MCP spec** — donated to CNCF; client implementations across 20+ tools.
- **FastMCP `SkillsDirectoryProvider`** — Python reference for serving
  SKILL.md as MCP prompts/resources.

### Demand Signals

- gridctl already serves skills via the registry as MCP prompts (preservation
  target). The runtime was a parallel-build that competes with the standard
  flow.
- The Library workspace (`2411deb`, one day before this evaluation) shows the
  team has already started leaning into the curation surface.

## User Experience

### Interaction Model

**Pre-removal**:
- 4 workspaces: Topology, Stage, Library, Runs (⌘1-4)
- BottomPanel "Runs" tab
- ApprovalBanner (top of shell) for in-flight runs
- Global runs SSE stream listening across all workspaces
- CLI: `gridctl agent {init,dev,build,validate}`, `gridctl runs {list,approve,resume}`, `gridctl run`

**Post-removal**:
- 2 workspaces: Topology, Library (⌘1, ⌘2)
- BottomPanel without runs tab
- No approval banner, no global runs stream
- CLI: gateway/registry/var/runtime/topology commands only (no agent/runs)

The simpler mental model — "Topology = inspect the gateway, Library = curate
the skills it serves" — matches how upstream MCP clients (Claude Code, Claude
Desktop) actually consume gridctl. Removing the execution surface stops
implying that gridctl is where you "run" agents.

### Workflow Impact

- **Reduced friction** for the primary workflow: author SKILL.md → ship it
  as an MCP prompt → upstream client picks it up. No agent runtime confusion
  on the path.
- **Bookmark breakage** for users with `/skills`, `/runs/*`, `/agent` URLs.
  Mitigation: route redirects to `/library` (or the closest workspace) until
  v1.0.
- **Muscle memory**: ⌘3 (Library) becomes ⌘2. Minor adjustment.

### UX Recommendations

1. **Route redirects** for `/skills`, `/runs`, `/runs/:id`, `/agent` →
   `/library` (with toast: "Stage and Runs have been removed; your skills
   live here").
2. **Renumber ⌘ shortcuts** so Library is ⌘2 and there's room to add
   workspaces back (Settings, Var, etc.) without re-renumbering.
3. **BottomPanel** — confirm what tabs remain after Runs disappears. If the
   panel only has one or two surviving tabs, consider compacting.
4. **CHANGELOG entry** at v0.1.x boundary calling out the removed CLI
   commands (`agent`, `runs`, `run`) and removed API surface
   (`/api/agent/*`, `/api/playground/*`) so external automation breaks
   loudly.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Removes gridctl from an unwinnable category; aligns code surface with strategic identity. |
| User impact | Broad + Deep | Affects all users; simpler mental model is easier to onboard. |
| Strategic alignment | Core mission | Industry has standardized around MCP (CNCF) + Agent Skills (open spec). gridctl can own MCP gateway + curation niche. |
| Market positioning | Leap ahead | No major MCP gateway has a skill-authoring UI; FastMCP has the library, no GUI. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Architectural seams are clean (opaque AgentRuntime interface, explicit registry interfaces, yaml:"-" tagged handler fields). |
| Effort estimate | Large | ~15K LOC pkg/agent deletion + ~5K LOC web + ~500 LOC controller/api + docs. Total ~20K LOC across 2 PRs. |
| Risk level | Low-Medium | Pre-1.0, no external API consumers, clean break confirmed. Main risk is bookmark breakage (mitigated by redirects) and recently-landed UI work (2411deb). |
| Maintenance burden | Net reduction | ~15K LOC less to maintain; tighter scope means simpler reasoning about the gateway. |

## Recommendation

**Build.** This is a strategic refocus the architecture is already designed
for. The opaque `AgentRuntime` marker interface and explicit registry
interfaces (`SkillRegistry`, `TSDispatcher`) show the original design
anticipated surgical removal. Market timing is ideal — MCP and Agent Skills
both just standardized, and the MCP-gateway + skill-curation niche is
underserved by all 17+ competing gateways.

Phasing: two PRs (backend first, frontend + docs second), confirmed with the
user. This keeps each PR reviewable while limiting in-flight risk.

Two caveats baked into the implementation prompt:

1. **Playground deletion is explicit** — the original plan suggested "move
   LLM types to pkg/llm/ if needed." User confirmed Playground goes too;
   the prompt removes `pkg/agent/llm/` entirely and `internal/api/playground.go`
   plus `web/src/components/playground/`. No `pkg/llm/` extraction needed.

2. **`SkillRegistry` interface is deleted, not relocated** — `pkg/registry/server.go:11`
   imports `pkg/agent/skill` only to declare the SkillRegistry interface for
   in-process registration of Go skills. With pkg/agent gone, that interface
   has no implementations. Delete it outright instead of moving it.

## References

- [agentskills.io specification](https://agentskills.io/specification) — open standard for SKILL.md format, donated to industry Dec 2025
- [anthropic/skills GitHub](https://github.com/anthropics/skills) — reference skill library and spec
- [Anthropic — Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [FastMCP — Skills Provider](https://gofastmcp.com/servers/providers/skills) — reference for serving SKILL.md as MCP resources/prompts
- [Claude — Skills explained: How Skills compares to prompts, Projects, MCP, and subagents](https://claude.com/blog/skills-explained)
- [Best Open Source MCP Gateways 2026 — Lunar.dev](https://www.lunar.dev/post/the-best-open-source-mcp-gateways-in-2026)
- [10 Best MCP Gateways for Developers in 2026 — Composio](https://composio.dev/content/best-mcp-gateway-for-developers)
- [Best Multi-Agent Frameworks in 2026 — Gurusup](https://gurusup.com/blog/best-multi-agent-frameworks-2026)
- [The Pipe & The Line — Why Skills and MCP Work Better Together](https://thepipeandtheline.substack.com/p/why-skills-and-mcp-work-better-together)
- [DEV — MCP vs Agent Skills: Why They're Different, Not Competing](https://dev.to/phil-whittaker/mcp-vs-agent-skills-why-theyre-different-not-competing-2bc1)

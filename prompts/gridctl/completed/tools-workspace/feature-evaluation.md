# Feature Evaluation: First-Class Tools Workspace

**Date**: 2026-05-23
**Project**: gridctl
**Recommendation**: Build with caveats (phase the backend-heavy pieces)
**Value**: High
**Effort**: Medium (MVP) → Large (full vision)

## Summary

A dedicated `/tools` workspace that elevates MCP tool whitelist management from a
per-server Topology-sidebar utility (`ToolsEditor`) into a fleet-wide master-detail
view: a server rail with enabled/total counts, a rich per-server editor, global
cross-server tool search, an audit overlay (used-vs-enabled), and fleet bulk actions.
The core per-server capability already exists and is excellent; the proposal is an
*elevation/aggregation* of it — exactly mirroring how the Variables workspace
(`/vault`) elevated the vault sidebar. The MVP rides an already-paved path with no
backend work; Audit Mode and fleet bulk actions are genuinely valuable but require new
Go backend work and should be phased after the MVP, not gating it.

## The Idea

gridctl is an MCP gateway that aggregates many downstream MCP servers behind one
endpoint. A central operational task is controlling *which* tools each server exposes
(a per-server whitelist), because exposing every tool bloats the AI client's context
window. Today that is done one server at a time inside the Topology canvas sidebar —
"context-heavy but discovery-poor." The Tools Workspace gives a strategic, fleet-wide
home for that work:

- **Fleet overview** of all servers with enabled/total tool counts and health.
- **Master-detail** layout: left rail of servers, main area = rich per-server editor.
- **Global search** across *all* servers' tools at once.
- **Visual fidelity**: server icons, JSON-schema previews of tool inputs, status badges.
- **Bulk actions**: expose-all / clear / pattern-based filtering per server and fleet-wide.
- **Audit Mode**: highlight tools actually invoked (telemetry) vs. merely enabled.

**Who benefits**: gridctl users running multi-server stacks (the common case) who need
to audit and prune tool exposure quickly. Single-server users benefit less — the
existing sidebar already serves them well.

## Project Context

### Current State

gridctl is pre-1.0 (v0.1.0-beta.10), "Containerlab for MCP." Stack: Go gateway + a
React 19 / Vite 8 / Tailwind 4 / Zustand 5 / react-router-dom 7 web UI. **Strategic
note**: the `[Unreleased]` CHANGELOG shows the project just *removed* its entire
agent-runtime surface (typed skills, run ledger, agent IDE, Playground) and cut the UI
"from 4 workspaces to 2" to refocus on the MCP-gateway-with-skill-library niche. The
team then deliberately added a 3rd workspace back — **Variables** (`/vault`, PRs
#703–#711). The lesson is *not* "no new workspaces"; it's "workspaces must serve the
core gateway mission." Tool-whitelist governance is unambiguously core gateway
territory, so a Tools workspace fits the grain in a way the removed Playground did not.

### Integration Surface

- `web/src/types/workspace.ts` — single source of truth (`WORKSPACE_CONFIG` + `Workspace`
  union). Comment: "Adding a workspace = append here; the switcher, shortcuts, and
  labels follow automatically." Add `'tools'`.
- `web/src/stores/useUIStore.ts` — add `tools: false` to `COMPACT_MODE_DEFAULTS`.
- `web/src/routes.tsx` — lazy import + `<Route path="/tools">` inside `<AppShell>`.
- `web/src/components/workspaces/ToolsWorkspace.tsx` — new container, modeled on
  `VaultWorkspace.tsx`.
- `web/src/components/sidebar/ToolsEditor.tsx` — refactor selection/dirty/save logic into
  a shared `useToolsEditor` hook (per the user's chosen "keep both, share a hook").
- `web/src/lib/api.ts` — existing `fetchStatus`, `fetchTools`, `setServerTools` cover the
  MVP. Audit Mode and fleet bulk would add new endpoints.

### Reusable Components

The MVP is overwhelmingly assembly of existing parts:

- **Workspace shell**: `WorkspaceShell.tsx` (resizable rail + main, persisted widths,
  `[`/`]` collapse) — master-detail for free.
- **Per-server editor**: `ToolsEditor.tsx` already does checklist, Fuse.js+cmdk search,
  select-all/clear, dirty-diff tracking, atomic save+reload with structured conflict
  handling (`stack_modified` / `reload_failed` / `unknown_tool`).
- **Count badge**: `CustomNode.tsx` already renders `{whitelist.length}/{toolCount}`.
- **Data shapes**: `MCPServerStatus` (`name`, `toolCount`, `tools[]`, `toolWhitelist?`),
  `Tool` (`name`, `description`, full `inputSchema`).
- **Schema preview**: `CodeViewer.tsx` (CodeMirror JSON) + `Tool.inputSchema`.
- **Audit data**: `pkg/metrics` `RecordToolCall(server,tool)` + `ToolUsageSnapshot()`,
  and `pkg/optimize` `detectUnusedTools` (already "used vs enabled"), surfaced at
  `GET /api/optimize` and rendered in `OptimizeSection.tsx`.
- **No new deps for the MVP** — Fuse.js, cmdk, CodeMirror, recharts, rjsf all present.

## Market Analysis

### Competitive Landscape

- **Per-server tool enable/disable is table-stakes** — present in Docker MCP Toolkit,
  MetaMCP, MCPHub, IBM ContextForge, mcpproxy-go, VS Code, JetBrains; openly requested in
  Claude Code (#7328) and OpenAI Codex (#4796).
- **The closest analogs to the full vision are IBM ContextForge** (Global Tools panel +
  search + a Metrics tab with top-tools-by-usage) and **mcpproxy-go** (BM25 search across
  all servers + web UI + activity logging). The specific master-detail + fleet-wide global
  search + audit-mode combination is rare in OSS.
- **Tool usage telemetry/audit is the most monetized capability** in the space —
  MCP Manager, Gravitee, Portkey, MintMCP, Cloudflare all sell "top tools by usage" /
  audit logging.

### Market Positioning

- Tool toggling: **catch-up / table-stakes** (gridctl already has it).
- Fleet workspace + global search: **modest differentiator** (only ContextForge / mcpproxy
  match it among OSS peers).
- Audit Mode: **differentiator** — a lightweight, built-in version taps the most-demanded
  commercial capability, which most OSS gateways lack.

### Ecosystem Support

No external library is needed for the MVP. Optional: a brand-logo icon set
(`simple-icons`) for per-server branding — lucide has no provider logos.

### Demand Signals

Strong and mainstream: GitHub's MCP server is ~17.6k tokens of tool defs; Anthropic's
"Code execution with MCP" cites 150k→2k token reductions; multiple official client
issues request tool filtering. "Too many MCP tools" is a recognized, named problem.

## User Experience

### Interaction Model

- **Discovery**: a 4th `WorkspaceSwitcher` pill ("Tools", ⌘4) — config-driven and
  automatic once registered.
- **Activation**: click the pill / ⌘4, or deep-link `?server=<name>` from a Topology
  server node (mirrors Variables' `?filter=server:` deep-link).
- **Interaction**: select a server in the rail → edit its whitelist in the main pane;
  type in the global search to fan out across all servers.
- **Feedback**: existing `showToast` + the save→reload flow.
- **Error states**: reuse the structured `SetServerToolsError` handling already in
  `ToolsEditor`.

### Workflow Impact

Reduces friction for the fleet-audit workflow that today requires clicking each server
node in turn. Per the user's decision, the sidebar editor *stays* (single-server-in-
context on the canvas) and both surfaces consume a shared `useToolsEditor` hook so they
never diverge.

### UX Recommendations (research-backed)

1. **Global search is the riskiest piece.** A search box next to a selected server
   *implies* it's scoped to that server (NN/G's most-cited search failure). Default to
   "all servers," label the scope ("Searching all N servers"), and **stamp every result
   with its parent-server badge**. Clicking a result selects that server in the rail.
2. **Bulk actions × reload cost.** Each whitelist change triggers a full server reload,
   and there is no atomic multi-server endpoint today. Confirm fleet actions with the
   *consequence stated* ("this reloads 12 servers"), not a bare undo toast. Reserve undo
   for cheap single toggles.
3. **Audit Mode reliability.** The data exists but is **in-memory only** — counts reset
   on restart and `detectUnusedTools` self-suppresses for <24h of observation. A naive
   overlay would mislead. Either persist per-tool usage (model on the token/cost NDJSON
   flusher in `pkg/telemetry/metrics.go`) or label the view honestly ("since last
   restart"). The strongest pattern to copy is **AWS IAM Access Analyzer**: a "last used"
   window + a filterable "configured-but-unused" list + finding→remediation (the overlay
   feeds the bulk action: "18 tools unused in 90d → disable").

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | "Too many MCP tools" is a top-discussed, named problem with official client issues |
| User impact | Broad + Shallow | Most gridctl stacks are multi-server; benefit is real but per-session, not constant |
| Strategic alignment | Core mission | Tool governance is central to an MCP gateway; fits the post-refocus direction |
| Market positioning | Catch-up + differentiator | Toggling is table-stakes; fleet view + audit is a genuine OSS edge |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal (MVP) → Significant (full) | Workspace registration is one line; audit persistence + batch endpoint are real backend work |
| Effort estimate | Medium (MVP) → Large (full) | MVP = scaffold + extracted hook + global search; full adds Go persistence + batch API |
| Risk level | Low (MVP) → Medium (audit/bulk) | MVP reuses proven write paths; audit risks misleading data, bulk risks fleet-wide mistakes + N reloads |
| Maintenance burden | Moderate | Net-positive: the shared hook de-dupes `ToolsEditor`/`ToolsPicker` (~80% duplicated today) |

## Recommendation

**Build with caveats — phase it.** The MVP is high-value and low-risk and should ship
first as its own PR(s). The user has chosen the **full vision** (Audit Mode + fleet bulk
actions) and to **keep both editors sharing a hook** — so the implementation prompt
covers all three layers, but sequences them so the backend-heavy work never blocks the
high-value UI:

1. **Phase 0 (prep)** — extract `useToolsEditor`; refactor `ToolsEditor` + `ToolsPicker`
   onto it (de-dup, no behavior change).
2. **Phase 1 (MVP)** — `/tools` workspace: server rail with counts, per-server editor via
   the hook, global cross-server search with parent-server attribution, Topology deep-link.
3. **Phase 2 (Audit Mode)** — add a per-tool usage persistence layer + `GET /api/tools/usage`,
   then the overlay (used / configured-but-unused / disabled) wired to remediation.
4. **Phase 3 (fleet bulk)** — a batch whitelist endpoint (multi-server apply + single
   reload), then the fleet bulk-action UI with consequence-stating confirmations.

The single most important caveat: **don't ship Audit Mode on the in-memory counters**
without either persistence or explicit "since last restart" labeling — a dashboard that
silently undercounts usage would drive users to disable tools that are actually in use.

## References

- Anthropic — Code execution with MCP: https://www.anthropic.com/engineering/code-execution-with-mcp
- The New Stack — reduce MCP token bloat: https://thenewstack.io/how-to-reduce-mcp-token-bloat/
- lunar.dev — MCP tool overload: https://www.lunar.dev/post/why-is-there-mcp-tool-overload-and-how-to-solve-it-for-your-ai-agents
- Claude Code issue #7328 (tool filtering): https://github.com/anthropics/claude-code/issues/7328
- OpenAI Codex issue #4796 (tools whitelist): https://github.com/openai/codex/issues/4796
- Docker MCP tools disable (CLI): https://docs.docker.com/reference/cli/docker/mcp/tools/tools_disable/
- Docker Dynamic MCP: https://docs.docker.com/ai/mcp-catalog-and-toolkit/dynamic-mcp/
- IBM ContextForge Admin UI concepts: https://ibm.github.io/mcp-context-forge/overview/ui-concepts/
- mcpproxy-go Web UI: https://screenshot.mcpproxy.app/
- MetaMCP namespaces: https://docs.metamcp.com/en/concepts/namespaces
- Cloudflare MCP Server Portals: https://blog.cloudflare.com/zero-trust-mcp-server-portals/
- Gravitee MCP analytics / Obot "13 best MCP gateways": https://obot.ai/blog/the-13-best-mcp-gateways-for-enterprise-teams/
- NN/G — Scoped Search: https://www.nngroup.com/articles/scoped-search/
- LaunchDarkly Flags list (count-in-row pattern): https://launchdarkly.com/docs/home/flags/list
- HashiCorp Helios — Table multi-select: https://helios.hashicorp.design/patterns/table-multi-select
- eleken — Bulk action UX: https://www.eleken.co/blog-posts/bulk-actions-ux
- AWS IAM Access Analyzer — unused access: https://aws.amazon.com/blogs/security/iam-access-analyzer-simplifies-inspection-of-unused-access-in-your-organization/
- AWS IAM — Refine permissions using last accessed: https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_last-accessed.html

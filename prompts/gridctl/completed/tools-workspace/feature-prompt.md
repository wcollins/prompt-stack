# Feature Implementation: First-Class Tools Workspace

## Context

**gridctl** is a pre-1.0 (v0.1.0-beta.10) Go CLI that acts as an **MCP gateway**: it
aggregates tools from many downstream MCP servers (e.g. GitHub, Atlassian, GitLab)
behind a single local endpoint that an AI client connects to. A stack is defined in one
YAML file; `gridctl apply` brings it up. A central operational concern is the per-server
**tool whitelist** — controlling which of a server's tools are exposed, because exposing
everything bloats the AI client's context window.

Tech stack:
- **Backend**: Go. Gateway in `pkg/mcp/`, HTTP API in `internal/api/`, config in
  `pkg/config/`, metrics in `pkg/metrics/` + `pkg/telemetry/`, optimization heuristics in
  `pkg/optimize/`.
- **Frontend** (`web/`): React 19, TypeScript ~6, Vite 8, Tailwind CSS 4, **Zustand 5**
  for state, **react-router-dom 7**, Vitest for tests. Notable libs already present:
  `@xyflow/react` (topology canvas), `cmdk` + `fuse.js` (fuzzy search), `@rjsf/*`
  (JSON-schema forms), `@uiw/react-codemirror` + `@codemirror/lang-json` (syntax
  highlighting), `recharts` (charts), `lucide-react` (icons).

The web UI is organized into **top-level workspaces** rendered inside a single
`AppShell`. Today there are three: **Topology** (`/topology`), **Library** (`/library`),
and **Variables** (`/vault`). This feature adds a fourth: **Tools** (`/tools`).

## Evaluation Context

Key findings from the feature-scout evaluation that shaped this prompt (full evaluation:
`prompts/gridctl/tools-workspace/feature-evaluation.md`):

- **The core capability already exists.** `web/src/components/sidebar/ToolsEditor.tsx`
  already does per-server tool whitelist editing (checklist, fuzzy search, select-all/
  clear, dirty tracking, atomic save+reload with structured conflict handling). This
  feature *elevates and aggregates* it into a fleet-wide workspace — it is **not** net-new
  tool-editing logic.
- **There is a near-perfect precedent**: the Variables workspace
  (`web/src/components/workspaces/VaultWorkspace.tsx`, routed at `/vault`) was built the
  same way — a master-detail workspace elevating a sidebar utility. **Copy its skeleton.**
- **Adding a workspace is deliberately trivial** — `web/src/types/workspace.ts` is a
  single source of truth; the switcher, shortcuts and labels derive from it.
- **Market**: per-server toggling is table-stakes; the fleet view + global search is a
  modest OSS differentiator; **Audit Mode (used-vs-enabled) is the strongest
  differentiator** (it's the most monetized capability among commercial MCP gateways).
- **UX risk — global search scope confusion** (NN/G): a search next to a selected server
  implies it's scoped to that server. Default to all servers, label the scope, and stamp
  every result with its parent server.
- **UX risk — Audit Mode data is in-memory only.** Per-tool counters reset on gateway
  restart and the existing `detectUnusedTools` heuristic self-suppresses for <24h of
  observation. Audit Mode must either persist per-tool usage or be labeled honestly.
- **UX risk — bulk actions × reload cost.** Each whitelist change triggers a full server
  reload; there is no atomic multi-server endpoint today.
- **Decisions made by the project owner**: build the **full vision** (MVP + Audit Mode +
  fleet bulk actions), and **keep both editors** (sidebar + workspace) sharing a single
  `useToolsEditor` hook so they never diverge.

## Feature Description

Add a `/tools` workspace that provides a fleet-wide home for MCP tool whitelist
management:

- A **left rail** listing every MCP server with an enabled/total tool count badge
  (e.g. "12/40") and health status.
- A **main detail pane** with a rich per-server tool editor (the existing `ToolsEditor`
  behavior, plus JSON-schema previews of tool inputs).
- A **global search** bar that searches tools across *all* servers at once, with each
  result attributed to its parent server.
- **Audit Mode**: an overlay distinguishing actively-used, configured-but-unused, and
  disabled tools, wired to remediation.
- **Fleet bulk actions**: expose-all / clear / pattern-based filtering, per server and
  fleet-wide, with consequence-stating confirmations.

It solves the "context-heavy but discovery-poor" friction of managing tool exposure one
server at a time inside the Topology sidebar. Beneficiaries: gridctl users running
multi-server stacks who need to audit and prune tool exposure quickly.

## Requirements

### Functional Requirements

**Phase 0 — Shared hook (prep, no behavior change)**
1. Extract the selection/dirty/save logic from `ToolsEditor.tsx` (currently lines ~42–265:
   `canonicalWhitelist`, `arraysEqual`, the `allTools`/`savedSelection`/`selection` state,
   dirty/diff computation, `toggle`/`selectAll`/`clearAll`, `handleSave` with its
   `SetServerToolsError` handling, and the node-switch discard guard) into a reusable
   `useToolsEditor` hook in `web/src/hooks/useToolsEditor.ts`.
2. Refactor `ToolsEditor.tsx` to consume the hook with **no behavioral change** (its tests
   must still pass unchanged).
3. Refactor `web/src/components/wizard/steps/ToolsPicker.tsx` onto the same hook where it
   overlaps (the two share ~80% of their checklist/search UI). Keep `ToolsPicker`'s
   probe-based ephemeral discovery intact.

**Phase 1 — MVP workspace**
4. Register the workspace: add `'tools'` to the `Workspace` union and a
   `WORKSPACE_CONFIG` entry (`{ id: 'tools', label: 'Tools', icon: Wrench, shortcutKey: '4' }`)
   in `web/src/types/workspace.ts`; add `tools: false` to `COMPACT_MODE_DEFAULTS` in
   `web/src/stores/useUIStore.ts`; add a lazy import + `<Route path="/tools">` inside
   `<AppShell>` in `web/src/routes.tsx`.
5. Build `web/src/components/workspaces/ToolsWorkspace.tsx` using `WorkspaceShell`
   (master-detail), modeled on `VaultWorkspace.tsx`.
6. Left rail: one row per MCP server (from `fetchStatus()` → `MCPServerStatus[]`), each
   showing the server name, a `enabled/total` count badge computed as
   `(toolWhitelist?.length || tools.length) / tools.length`, and a health/status dot.
   Selecting a server drives the detail pane. Persist the selected server in the URL
   (`?server=<name>`).
7. Detail pane: render the per-server editor via `useToolsEditor` for the selected server,
   plus a **JSON-schema preview** for each tool's `inputSchema` using `CodeViewer` (CodeMirror
   JSON), shown on demand (expand/peek), not all-at-once.
8. Global search: a search bar that, when non-empty, searches across the aggregated
   `useStackStore.tools` (Fuse.js). Results MUST display the parent server (split the
   prefixed name on `TOOL_NAME_DELIMITER`). The search scope MUST default to "all servers,"
   be clearly labeled ("Searching all N servers"), and clicking a result selects that
   server in the rail and scrolls its tool into view.
9. Topology integration: the existing sidebar `ToolsEditor` **stays**; add an affordance
   (e.g. an "Open in Tools workspace" link) that deep-links `/tools?server=<name>`.

**Phase 2 — Audit Mode**
10. Add per-tool usage **persistence** so usage survives gateway restarts. Model it on the
    existing token/cost NDJSON flusher (`pkg/telemetry/metrics.go` `MetricsFlusher` +
    `SeedFromFile`). The persisted unit is per-(server, tool): call count + last-called
    timestamp (see `ToolStat` in `pkg/metrics/accumulator.go`).
11. Add `GET /api/tools/usage` returning `ToolUsageSnapshot()`-style data (per server/tool:
    calls + lastCalledAt), and a corresponding `fetchToolUsage()` in `web/src/lib/api.ts`.
12. Audit Mode UI: a toggle that recolors/annotates the rail badges and detail rows into
    three states — **actively used** (activity within a window), **configured-but-unused**
    (enabled, no activity in window), **disabled**. Show "last used" per tool. Make the
    window explicit (and ideally configurable). Wire it to remediation: "N tools unused in
    <window> → disable these" routes into the bulk action (Req 14).

**Phase 3 — Fleet bulk actions**
13. Add a **batch whitelist endpoint** that applies whitelist changes to multiple servers
    in one request and triggers a **single** reload (extend `internal/api/mcp_servers.go` +
    `internal/api/stack_edit.go`; reuse the atomic read-verify-write + conflict detection).
    Add a matching `setServerToolsBatch()` in `web/src/lib/api.ts`.
14. Bulk-action UI: per-server and fleet-wide expose-all / clear / pattern-based filtering
    (e.g. "hide all `delete_*`"). Resolve patterns to a concrete tool set and **echo the
    resolved count before acting**. Fleet-wide actions MUST show a confirmation that states
    the consequence ("this reloads 12 servers"). Show per-server progress + a result summary
    on partial failure.

### Non-Functional Requirements

- **No regressions** to the existing sidebar `ToolsEditor` or `ToolsPicker` (Phase 0 is a
  pure refactor — existing tests pass unchanged).
- **Accessibility**: keyboard-navigable rail and editor; the global search must be
  operable and its scope announced to screen readers; bulk confirmations must be reachable
  by keyboard. Match the ARIA patterns already in `ToolsEditor` (`aria-checked`,
  `role="alertdialog"`, labeled controls).
- **Performance**: the global Fuse index should be memoized over the aggregated tools
  array (mirror `ToolsEditor`'s `useMemo` Fuse pattern); avoid rebuilding on every poll.
- **Audit honesty**: if per-tool persistence (Req 10) is not yet in place when the UI
  ships, the overlay MUST label the window as "since last gateway restart" — never imply a
  longer history than the data supports.
- **Whitelist semantics preserved**: empty whitelist = "expose all tools." When the user
  selects every known tool, persist `[]` (not the full list) — exactly as
  `ToolsEditor.handleSave` does today.

### Out of Scope

- Per-server **brand logos** (GitHub Octocat, Atlassian mark). lucide has no provider
  logos; adding `simple-icons` is optional polish, not required. Use generic lucide icons
  keyed to transport/status for v1.
- Any change to how the gateway *filters* tools at runtime (`pkg/mcp/client_base.go`) —
  the existing filter is correct; this feature only edits the whitelist and reads usage.
- Cross-server *staging* of edits behind a single global "Apply" beyond what the batch
  endpoint (Req 13) provides. Single-server edits keep their current immediate save+reload.
- Replacing the sidebar editor — the owner chose to keep both.

## Architecture Guidance

### Recommended Approach

Follow the **Variables workspace pattern** precisely. `VaultWorkspace.tsx` is the
reference implementation for a master-detail workspace that elevates a sidebar utility:
left rail with count badges, URL search-param state (`?server=`, `?q=`), a `useMemo`
filter chain, `WorkspaceShell` for layout, `showToast`/`ConfirmDialog` for feedback, and a
Topology deep-link. Build `ToolsWorkspace.tsx` as its sibling.

Sequence the work as Phase 0 → 1 → 2 → 3 (separate PRs). The MVP (Phases 0–1) is
frontend-only and low-risk; Phases 2–3 add Go backend work and carry the real risk, so
they must not gate the MVP.

### Key Files to Understand

Read these first:

- `web/src/components/workspaces/VaultWorkspace.tsx` — **the template.** A complete
  master-detail workspace (rail with count badges, URL state, filter chain, deep-link).
- `web/src/components/sidebar/ToolsEditor.tsx` — the existing per-server editor; the
  source of the `useToolsEditor` extraction and the canonical save+reload + conflict logic.
- `web/src/types/workspace.ts` — single source of truth for workspace registration.
- `web/src/routes.tsx` — the lazy-import + `<Route>`-inside-`<AppShell>` pattern.
- `web/src/components/layout/WorkspaceShell.tsx` — resizable master-detail primitive.
- `web/src/lib/api.ts` (≈104–264) — `fetchStatus`, `fetchTools`, `setServerTools` and the
  `SetServerToolsError` envelope (codes: `stack_modified` / `reload_failed` / `unknown_tool`).
- `web/src/types/index.ts` — `MCPServerStatus` (has `toolCount`, `tools[]`, `toolWhitelist?`)
  and `Tool` (has `inputSchema`).
- `web/src/components/wizard/steps/ToolsPicker.tsx` — the second consumer of the shared hook.
- `web/src/components/sidebar/OptimizeSection.tsx` + `web/src/types/index.ts` (`OptimizeReport`/
  `OptimizeFinding`) — the existing "unused tool" rendering; a starting reference for Audit Mode.
- Backend (Phases 2–3): `pkg/metrics/accumulator.go` (`ToolStat`, `RecordToolCall`,
  `ToolUsageSnapshot`), `pkg/optimize/optimize.go` (`detectUnusedTools`),
  `pkg/telemetry/metrics.go` (`MetricsFlusher` + `SeedFromFile` — the persistence model to
  copy), `internal/api/mcp_servers.go` + `internal/api/stack_edit.go` (whitelist write path),
  `pkg/config/types.go` (`MCPServer.Tools` — the persisted whitelist).

### Integration Points

- **Workspace registration** (Phase 1): three small edits — `workspace.ts`, `useUIStore.ts`,
  `routes.tsx` — as enumerated in Req 4.
- **Shared hook** (Phase 0): `ToolsEditor.tsx` and `ToolsPicker.tsx` both import
  `useToolsEditor`.
- **New endpoints** (Phases 2–3): `GET /api/tools/usage` and a batch whitelist PUT,
  registered in `internal/api/api.go` alongside the existing `/api/mcp-servers/{name}/tools`
  route; document both in `docs/api-reference.md`.

### Reusable Components

- `WorkspaceShell`, `ConfirmDialog`, `Modal`, `EmptyState`, `Badge`, `StatusDot`,
  `IconButton`, `Toast`/`showToast`, `CodeViewer` (JSON schema previews).
- `Fuse.js` + `cmdk` `Command` for search (already the established tool-search idiom).
- `TOOL_NAME_DELIMITER` (`web/src/lib/constants.ts`) for splitting prefixed tool names
  (`server__tool`) to attribute a global-search result to its parent server.

## UX Specification

- **Discovery**: a 4th "Tools" pill (⌘4) appears automatically in the `WorkspaceSwitcher`
  once registered.
- **Activation**: click the pill / ⌘4, or deep-link `/tools?server=<name>` from the
  Topology sidebar.
- **Browse**: left rail shows servers with `enabled/total` badges. The badge is a status
  signal — visually distinguish `0/N`, `N/N`, and partial states; in Audit Mode it also
  carries an "unused" count.
- **Edit**: selecting a server shows its editor in the main pane (existing behavior via the
  hook), with per-tool JSON-schema preview available on expand.
- **Search**: typing in the global bar fans out across all servers; the bar is labeled with
  its scope ("Searching all N servers"); each result shows `parentServer › toolName`;
  clicking selects the server and scrolls to the tool. Clearing search restores the prior
  selection.
- **Audit Mode**: a toggle recolors rail badges and detail rows into used / unused /
  disabled, shows "last used", and offers "disable N unused" that routes into the bulk
  confirmation.
- **Bulk actions**: per-server and fleet-wide; pattern input echoes the resolved set count;
  fleet-wide commit shows a confirmation stating "this reloads N servers"; progress + a
  per-server success/failure summary on completion.
- **Feedback & errors**: reuse `showToast` and the `SetServerToolsError` handling — surface
  `stack_modified` as a "reload file" banner, `reload_failed` as a toast that keeps the
  on-disk state as the clean baseline, `unknown_tool` as an error toast.

## Implementation Notes

### Conventions to Follow

- **Commits**: conventional format (`feat:`, `refactor:`, `fix:`), imperative subject ≤50
  chars, **signed (`-S`)**, **no "Claude"/AI mention** anywhere in commits/PRs/branches,
  **no Co-authored-by trailer**. gridctl uses a **fork workflow** (`/branch-fork`,
  `/pr-fork`) — PRs go to upstream.
- **Build & verify locally**: `make build` then run `./gridctl` (do not use a brew-installed
  binary). Note `gridctl serve` **daemonizes** — use `--foreground` if a script needs to
  kill it.
- **Web tests**: Vitest + Testing Library (`web/src/__tests__/`). Mirror existing tests:
  `ToolsEditor.test.tsx`, `WorkspaceSwitcher.test.tsx`, `useUIStore-workspace.test.ts`,
  `router-redirects.test.tsx`. Add a `ToolsWorkspace.test.tsx` and a `useToolsEditor.test.ts`.
- **Linting**: `npm run lint` has **pre-existing failures** in `web/src/pages/Detached*.tsx`
  — lint only the files you changed; don't try to green the whole tree.
- **Go**: co-locate `_test.go`; match the table-test style in `pkg/optimize/optimize_test.go`
  and `internal/api/mcp_servers_test.go`.
- **Docs**: there is **no `AGENTS.md`** in the repo (removed pre-1.0). Update
  `docs/api-reference.md` for any new endpoints; `docs/config-schema.md` already documents
  the `tools` whitelist field.

### Potential Pitfalls

- **Polling vs. in-progress edits.** `ToolsEditor` uses refs to prevent status polling from
  clobbering unsaved selections (and a discard prompt on node switch). Preserve this in the
  hook — it's load-bearing.
- **Whitelist `[]` semantics.** Empty = expose all. When all tools are selected, persist `[]`.
  Don't write a redundant full-list whitelist into the YAML.
- **Reload cost is per-call.** Without the batch endpoint (Phase 3), a fleet "enable all"
  is N PUTs = N reloads. Don't build fleet bulk UI on the per-server endpoint — implement
  the batch endpoint first.
- **Audit data is in-memory until Phase 2's persistence lands.** `Accumulator.Clear` wipes
  `toolUsage`; counts reset on restart; `detectUnusedTools` emits nothing with <24h of data
  or an empty `ToolUsage`. Build persistence before claiming any window > "since restart."
- **Code-mode attribution.** Tools invoked through code mode's `execute` ARE recorded by
  their real downstream name (`Gateway.CallTool` → `HandleToolsCall` → observer), so Audit
  Mode sees real usage — verify this holds in tests.
- **Global tools list is prefixed and code-mode-filtered.** `useStackStore.tools` holds
  `server__tool` names and (in code mode) hides downstream tools behind meta-tools. The
  *authoritative* per-server tool list for editing is `MCPServerStatus.tools` (from
  `/api/status`), exactly as `ToolsEditor` already uses it. Use status for the editor;
  use the aggregated store only for descriptions and global search.

### Suggested Build Order

1. **Phase 0** — `useToolsEditor` extraction; refactor `ToolsEditor` + `ToolsPicker`; tests green. (1 PR)
2. **Phase 1** — register workspace; build `ToolsWorkspace` (rail + counts + detail editor);
   global search with parent attribution; Topology deep-link; tests. (1 PR — this is the MVP)
3. **Phase 2** — per-tool usage persistence + `GET /api/tools/usage` + `fetchToolUsage`;
   Audit Mode overlay + remediation. (1 PR)
4. **Phase 3** — batch whitelist endpoint + `setServerToolsBatch`; fleet bulk-action UI with
   consequence confirmations + progress/summary. (1 PR)

## Acceptance Criteria

1. A "Tools" pill (⌘4) appears in the workspace switcher; `/tools` renders a master-detail
   workspace; `/tools?server=<name>` deep-links to that server selected.
2. The left rail lists all MCP servers with an accurate `enabled/total` badge; the detail
   pane edits the selected server's whitelist with the *same* save+reload + conflict
   behavior as the existing sidebar editor.
3. `ToolsEditor` and `ToolsPicker` are refactored onto `useToolsEditor` with their existing
   tests passing unchanged (no behavior regression).
4. Global search returns matches from all servers, each labeled with its parent server;
   the scope is clearly stated; clicking a result selects that server and reveals the tool.
5. Selecting every tool persists `[]` to the stack YAML (expose-all), and the change
   hot-reloads the affected server; conflict/error envelopes are surfaced as today.
6. `GET /api/tools/usage` returns per-(server, tool) call counts + last-called timestamps;
   the data survives a gateway restart (Phase 2 persistence).
7. Audit Mode visually separates used / configured-but-unused / disabled tools, shows a
   stated/honest time window, and offers a "disable unused" action that routes through the
   bulk confirmation.
8. Fleet bulk actions (expose-all / clear / pattern) apply across selected servers via the
   batch endpoint with a **single** reload, echo the resolved count, require a
   consequence-stating confirmation for fleet-wide ops, and report per-server results.
9. New endpoints are documented in `docs/api-reference.md`; web changes pass `tsc`,
   targeted lint, and new Vitest tests; Go changes pass `go test -race` and `golangci-lint`
   on changed packages.

## References

- Full evaluation: `prompts/gridctl/tools-workspace/feature-evaluation.md`
- Precedent in-repo: `web/src/components/workspaces/VaultWorkspace.tsx` (Variables workspace)
- Anthropic — Code execution with MCP: https://www.anthropic.com/engineering/code-execution-with-mcp
- IBM ContextForge Admin UI (closest analog): https://ibm.github.io/mcp-context-forge/overview/ui-concepts/
- mcpproxy-go Web UI (global tool search analog): https://screenshot.mcpproxy.app/
- NN/G — Scoped Search (global-search scope guidance): https://www.nngroup.com/articles/scoped-search/
- HashiCorp Helios — Table multi-select (bulk-action pattern): https://helios.hashicorp.design/patterns/table-multi-select
- eleken — Bulk action UX guidelines: https://www.eleken.co/blog-posts/bulk-actions-ux
- AWS IAM Access Analyzer — unused access (Audit Mode model): https://aws.amazon.com/blogs/security/iam-access-analyzer-simplifies-inspection-of-unused-access-in-your-organization/
- LaunchDarkly Flags list (count-in-row rail pattern): https://launchdarkly.com/docs/home/flags/list

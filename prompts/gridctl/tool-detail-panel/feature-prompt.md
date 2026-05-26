# Feature Implementation: Tool Detail Panel (Tools Workspace)

## Context

gridctl is an MCP gateway: it aggregates tools from multiple downstream MCP servers behind a
single endpoint. It can run in **passthrough mode** (downstream tools exposed directly to MCP
clients as `<server>__<tool>`) or **code mode** (downstream tools hidden behind two meta-tools,
`search` and `execute`, to save context). Code mode is becoming the default operating mode.

- **Backend:** Go. HTTP API in `internal/api/`, gateway/router in `pkg/mcp/`.
- **Frontend:** React + TypeScript + Vite, TailwindCSS **v4** (canonical theme tokens live in the
  `@theme` block of `web/src/index.css`; `web/tailwind.config.js` is vestigial — do NOT edit it
  expecting theme changes). State via Zustand (`web/src/stores/useStackStore.ts`). Tool lists use
  `cmdk`. Tests via **Vitest + Testing Library** (`web/src/__tests__/`).
- Build/run per project convention: `make build` then `./gridctl`; web dev via `npm` in `web/`.

The **Tools workspace** (`web/src/components/workspaces/ToolsWorkspace.tsx`) is the fleet-wide
tool-management surface. It shipped recently across PRs #713–#716 and is well-tested. Layout:
left `ServerRail` (servers) + center `ServerDetail` (per-server whitelist editor). The center
content is capped at `max-w-3xl`, leaving the right ~40% of the screen blank.

## Evaluation Context

- **Layout pattern is already proven by Anthropic's MCP Inspector** (list-left, detail-right with
  name + description + JSON schema). This is table-stakes for an MCP console; build it to match
  that mental model.
- **The checkbox/row split is the established convention** (Gmail/Finder/Linear): whole-row-toggle
  is a documented anti-pattern. Narrow the toggle to the checkbox; row-body click selects.
- **Critical data finding:** the panel's description + schema come from `/api/tools`, which in
  **code mode returns only the two meta-tools** — so descriptions/schemas are absent for the
  downstream tools shown in the workspace. BUT the gateway still holds the full inventory in memory
  (`Router.AggregatedTools()`, used to power code mode itself). The fix is a small read-only
  `/api/tools/catalog` endpoint returning the full inventory with **raw** descriptions, regardless
  of mode. This is required for the feature to be useful as code mode becomes default.
- Full evaluation: `prompts/gridctl/tool-detail-panel/feature-evaluation.md`

## Feature Description

In the Tools workspace:
1. **Narrow the enable/disable toggle to the checkbox.** Clicking the checkbox stages whitelist
   membership; it must not select the row.
2. **Make a row-body click (and Enter) select the tool.** Selection drives a detail panel; it must
   not toggle the checkbox.
3. **Render a detail panel in the `WorkspaceShell` right rail** for the selected tool, showing:
   - **Description** rendered as formatted markdown.
   - **Input schema** rendered as code (line-numbered, tokenized — matching the "Spec" treatment).
   - **Metadata**: downstream server, enabled/whitelist state, and audit/usage (calls, last used)
     when Audit Mode is on.
   - An explicit **empty state** when nothing is selected.
4. **Add a read-only `GET /api/tools/catalog`** that returns the full downstream tool inventory
   (raw descriptions + schemas) in both passthrough and code mode, and point the Tools workspace at
   it as the source for descriptions/schemas (and the header global search).

Solves: no in-UI way to see what a tool does (especially in code mode), plus wasted right-hand
space. Benefits every Tools-workspace user.

## Requirements

### Functional Requirements
1. **Backend catalog endpoint.**
   1. Add a router method (e.g. `Router.CatalogTools()`) mirroring `AggregatedTools()`
      (`pkg/mcp/router.go:153`) but returning **raw** `tool.Description` (NOT the wrapped
      "MCP server: X. Call using…" string) and raw `tool.Title`. Keep the prefixed name
      (`<server>__<tool>`) and `tool.InputSchema` so the payload shape matches `/api/tools`.
   2. Add `Gateway.HandleToolsCatalog()` (`pkg/mcp/gateway.go`, near `HandleToolsList` at `:1222`)
      that returns `&ToolsListResult{Tools: g.router.CatalogTools()}` **regardless of code mode**
      (do NOT short-circuit to meta-tools).
   3. Add `handleToolsCatalog` in `internal/api/api.go` (mirror `handleTools` at `:436`) and
      register `mux.HandleFunc("GET /api/tools/catalog", s.handleToolsCatalog)` in the route table
      (`:216-244`).
   4. The endpoint is informational only — it must NOT change what MCP `tools/list` returns.
2. **Frontend data source.**
   1. Add `fetchToolCatalog()` to `web/src/lib/api.ts` (mirror `fetchTools` at `:120`), returning
      `ToolsListResult` from `/api/tools/catalog`.
   2. Add `toolCatalog: Tool[]` + `setToolCatalog` to `useStackStore`
      (`web/src/stores/useStackStore.ts`; mirror `tools`/`setTools` at `:52,80,100,154`).
   3. Fetch the catalog wherever tools are fetched: `usePolling.ts:32` (bootstrap/poll), and the
      post-save/reload refreshes in `useToolsEditor.ts` (`:219,243,295`). Also `FleetActions.tsx:79`
      and `DetachedSidebarPage.tsx:102` if those need it (verify).
   4. Point the Tools workspace at `toolCatalog` for per-tool description + schema: in
      `useToolsEditor.ts`, source `ToolRow.description` from `toolCatalog` instead of `tools`
      (`:88-107`); in `ServerDetail`, build `schemaByTool` from `toolCatalog` (`:608-615`); and
      change the header global search to `useFuzzySearch(toolCatalog, …)` (`:191`). (`tools` remains
      the MCP-facing list for any other consumer.)
3. **Toggle/select split** in `ServerDetail` (`ToolsWorkspace.tsx`):
   1. Replace the `Command.Item onSelect={() => toggle(opt.name)}` (`:723`) so `onSelect` sets the
      **selected tool** (new state), not the toggle.
   2. Make the checkbox (`:732-742`) an interactive control (button/role=checkbox) that calls
      `toggle(opt.name)` and `e.stopPropagation()`s so it never selects the row (mirror the existing
      schema-peek button's `stopPropagation` at `:781-784`).
   3. Keep keyboard semantics sane: Enter/click on the row selects; Space on the checkbox toggles.
4. **Detail panel component** (new file, e.g. `web/src/components/workspaces/ToolDetailPanel.tsx`):
   1. Props: the selected tool's `{ server, name, description?, inputSchema?, whitelist state,
      audit/usage }`. Render with `InspectorHeader` (primary accent) + `InspectorSection`s.
   2. Schema via `CodeViewer` (`language="json"`, `JSON.stringify(schema, null, 2)`).
   3. Description via the markdown approach used in `SkillEditor` (`renderMarkdown` +
      `MarkdownPreview` / `.prose-playground`).
   4. Empty state when no tool is selected ("Select a tool to view its description and schema").
   5. Graceful degradation: if description/schema are absent even from the catalog, show name +
      metadata and a muted "No description available."
5. **Mount the panel** via `WorkspaceShell`'s `right` prop (`ToolsWorkspace.tsx:210-216`); give a
   sensible `defaultRightPct` (e.g. ~30) and `minRightPx`. The selected-tool state lives in the
   workspace (parallel to the existing `expandedTool` state, which it supersedes).
6. **Remove the inline chevron-expand schema peek** (`:778-806`) — the panel is the single place
   the schema appears. Retarget/replace the `expandedTool` + `rowRefs` scroll-into-view machinery to
   the new selected-tool state.

### Non-Functional Requirements
- Accessibility: active row marked with `aria-current`/`aria-selected`, distinct from the checkbox's
  `checked`; visible focus indicator; selection not by color alone; focus/selection independent.
- Theme: semantic tokens only (`bg-primary`, `text-secondary`, etc.) — never raw literals like
  `bg-amber-500`. Pull from `index.css`.
- Purity: no `setState` in effects, no clock reads in render (the file follows React-compiler-
  friendly conventions — preserve them). The existing DOM-only scroll effect is fine.
- Responsive: rail is collapsible (`]`); verify list + panel are comfortable at narrower widths.
- The catalog endpoint must be read-only and must not alter MCP tool exposure.

### Out of Scope
- No changes to MCP `tools/list` / what clients can call.
- No editing of tool descriptions/schemas — display only.
- No new audit/usage data sources (reuse the existing `useToolUsage` / `/api/tools/usage`).
- No multi-select detail (panel shows the single active tool).

## Architecture Guidance

### Recommended Approach
Frontend-led, with one small read-only backend endpoint. Reuse existing primitives rather than
building new ones. Keep the two selection concepts (checkbox membership vs. active row) as separate
state. Treat `toolCatalog` as the Tools workspace's canonical inventory; leave `tools` for the
MCP-facing aggregated list.

### Key Files to Understand
- `web/src/components/workspaces/ToolsWorkspace.tsx` — the workspace; `ServerDetail` rows, toggle at
  `:723`, checkbox `:732-742`, schema-peek `:778-806`, `schemaByTool` `:608-615`, `WorkspaceShell`
  `:210-216`, global search `:191`.
- `web/src/hooks/useToolsEditor.ts` — `ToolRow` derivation/descriptions `:88-107`; save/refresh
  `:219,243,295`. Read the header comment re: code mode and authoritative tool sources.
- `web/src/components/layout/WorkspaceShell.tsx` — the `right` rail API.
- `web/src/components/ui/CodeViewer.tsx` — schema renderer.
- `web/src/components/inspector/InspectorHeader.tsx`, `InspectorSection.tsx` — panel scaffolding.
- `web/src/components/registry/SkillEditor.tsx` (`renderMarkdown` `:76`, `MarkdownPreview`) — markdown.
- `pkg/mcp/router.go:153` `AggregatedTools()`; `pkg/mcp/gateway.go:1222` `HandleToolsList()`;
  `internal/api/api.go:436` `handleTools` + routes `:216-244`.
- `web/src/__tests__/ToolsWorkspace.test.tsx` — existing interaction tests to update.

### Integration Points
- Store: `useStackStore` (`toolCatalog`/`setToolCatalog`).
- API: `lib/api.ts` (`fetchToolCatalog`), `usePolling.ts` (fetch on poll).
- Backend: one router method, one gateway method, one handler, one route.

### Reusable Components
`CodeViewer`, `InspectorHeader`, `InspectorSection`, `renderMarkdown`/`MarkdownPreview`,
`.prose-playground`, `WorkspaceShell` right rail, `formatLastUsed`/`formatRelativeTime` for
audit metadata.

## UX Specification
- **Discovery:** the panel appears when a row is clicked; the right rail is visible by default
  (non-zero `defaultRightPct`) with an empty-state prompt until a selection is made.
- **Activation:** row-body click or Enter selects; checkbox click/Space toggles enable/disable.
- **Interaction:** selecting a tool fills the panel with description (markdown), schema (CodeViewer),
  and metadata sections. The active row is highlighted distinctly from checked rows.
- **Feedback:** selected-row highlight; panel updates immediately; `]` collapses the rail.
- **Error/empty states:** no selection → prompt; tool missing description/schema → name + metadata +
  muted "No description available".

## Implementation Notes

### Conventions to Follow
- Commit style: `<type>: <subject>` imperative, ≤50 chars, signed (`-S`), no Claude mentions, no
  Co-authored-by. Fork workflow (`/branch-fork`, `/pr-fork`).
- Build/run: `make build` + `./gridctl` (not the brew binary). `gridctl serve` daemonizes — use
  `--foreground` if a script must kill it.
- Lint: full `eslint .` has pre-existing failures across other files — **lint only changed files**
  and keep new code clean. `ToolsWorkspace.tsx`/`useToolsEditor.ts` are currently lint-clean.
- Go: `go test -race`, `golangci-lint`, `go build`; add a test for the catalog endpoint
  (mirror `internal/api/tools_usage_test.go`) asserting it returns full tools in code mode.

### Potential Pitfalls
- **Double-toggle bug:** forgetting `stopPropagation` on the checkbox so a click both toggles and
  selects. `stopPropagation` it (the schema-peek button at `:781-784` is the model).
- **Wrapped descriptions:** `AggregatedTools()` wraps descriptions; the catalog must return the raw
  `tool.Description`, or the panel shows "MCP server: X. Call using…" noise.
- **cmdk semantics:** `Command.Item onSelect` fires on keyboard nav too — make sure selecting the
  row for the panel doesn't regress the filter/keyboard flow or the unsaved-changes server-switch
  guard.
- **Tests will break:** `ToolsWorkspace.test.tsx` asserts `aria-checked` toggling on row `onSelect`
  and `getByRole('button', {name:/show … schema/i})`. Update these to the new model (checkbox
  toggles; row selects; schema in panel).
- **Store source switch:** ensure nothing else relies on `tools` for the workspace's descriptions;
  global search moving to `toolCatalog` is intended (it fixes code-mode search).

### Suggested Build Order
1. Backend: `CatalogTools()` → `HandleToolsCatalog()` → `handleToolsCatalog` + route → Go test.
2. Frontend plumbing: `fetchToolCatalog`, store `toolCatalog`, fetch in `usePolling` + refresh sites.
3. Point `useToolsEditor` descriptions, `schemaByTool`, and global search at `toolCatalog`.
4. Toggle/select split in `ServerDetail` (checkbox interactive + `stopPropagation`; row → select).
5. `ToolDetailPanel` component + mount in `WorkspaceShell` right rail; remove inline chevron peek.
6. Empty/degraded states; accessibility pass.
7. Update tests (`ToolsWorkspace.test.tsx`) + add panel test; lint changed files; build web + Go.

## Acceptance Criteria
1. `GET /api/tools/catalog` returns the full downstream inventory with raw descriptions + schemas in
   **both** passthrough and code mode; MCP `tools/list` output is unchanged.
2. In code mode, the Tools workspace rows show descriptions and the detail panel shows description +
   schema (previously absent).
3. Clicking a row's checkbox toggles enable/disable and does **not** open/change the panel.
4. Clicking a row body (or Enter) selects the tool and populates the right panel; does **not** toggle.
5. The panel renders description (markdown), schema (CodeViewer), and metadata (server, whitelist
   state, audit/usage when Audit Mode is on), themed consistently with the workspace.
6. With nothing selected, the panel shows an explicit empty-state prompt; a tool lacking
   description/schema shows name + metadata + "No description available".
7. The active (selected) row is visually distinct from checked rows; keyboard nav and the
   unsaved-changes server-switch guard still work.
8. The inline chevron-expand schema peek is removed; schema appears only in the panel.
9. Changed-file lint is clean; `go test -race` and the web test suite pass (updated tests included);
   `make build` and the web build succeed.
10. Header global search matches downstream tools in code mode (now sourced from the catalog).

## References
- MCP Inspector — https://github.com/modelcontextprotocol/inspector
- NN/G, Checkboxes: Design Guidelines — https://www.nngroup.com/articles/checkboxes-design-guidelines/
- W3C ARIA APG, Keyboard Interface — https://www.w3.org/WAI/ARIA/apg/practices/keyboard-interface/
- Full evaluation — `prompts/gridctl/tool-detail-panel/feature-evaluation.md`

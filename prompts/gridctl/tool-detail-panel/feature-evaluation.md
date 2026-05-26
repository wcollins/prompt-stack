# Feature Evaluation: Tool Detail Panel

**Date**: 2026-05-24
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small–Medium

## Summary

Add a right-hand detail panel to the Tools workspace: clicking a tool row selects it and
renders its description, input schema, and metadata in the currently-empty right rail, while
the enable/disable toggle is narrowed to the checkbox. Investigation surfaced that the panel's
core data (descriptions + schemas) is withheld from the web API in **code mode** — but the
gateway already holds it in memory, so a small read-only `/api/tools/catalog` endpoint makes the
panel work in both modes. This matches Anthropic's own MCP Inspector layout and fits gridctl's
direction toward code-mode-as-default.

## The Idea

The Tools workspace center pane is constrained to `max-w-3xl`, leaving the right ~40% of a wide
screen blank. Users can't see what a tool does without leaving the UI. Today, clicking anywhere
on a tool row toggles its draft whitelist membership (the checkbox), and there is no in-UI way to
read a tool's description or schema in code mode.

The feature makes two interaction changes and adds one surface:
1. **Narrow the toggle** to the checkbox only.
2. **Repurpose the row-body click** to *select* a tool.
3. **Render a detail panel** in the `WorkspaceShell` right rail showing the selected tool's
   description (markdown), input schema (as code), and metadata (server, whitelist state,
   audit/usage when Audit Mode is on).

Who benefits: every Tools-workspace user, on every visit — especially as code mode (which hides
per-tool detail from MCP clients) becomes the default operating mode.

## Project Context

### Current State
- React + TS + Vite, TailwindCSS v4 (`@theme` block in `web/src/index.css` is canonical;
  `tailwind.config.js` is vestigial), Zustand (`useStackStore`), `cmdk` for tool lists.
- The Tools workspace (`web/src/components/workspaces/ToolsWorkspace.tsx`) shipped recently across
  PRs #713–#716 (hook extraction → fleet MVP → Audit Mode → fleet bulk). High-velocity, well-tested
  surface (Vitest + Testing Library; 8 related test files).
- Layout today is left `ServerRail` + center `ServerDetail`. `WorkspaceShell` is mounted with
  `defaultRightPct={0}` and **no `right` prop** — the right rail is wired but unused.

### Integration Surface
- **Backend (Go):**
  - `pkg/mcp/gateway.go:1222` `HandleToolsList()` — short-circuits to the two meta-tools when code
    mode is on (`:1227-1228`). This is the *only* reason `/api/tools` loses per-tool detail.
  - `pkg/mcp/router.go:153` `AggregatedTools()` — returns the full inventory (name/description/
    schema), but **wraps** descriptions ("MCP server: X. Call using…"). Code mode uses this to power
    `search`/`execute` (`gateway.go:1244`), proving the data is retained server-side in code mode.
  - `internal/api/api.go:436` `handleTools` + route table at `:216-244`.
- **Frontend:**
  - `ToolsWorkspace.tsx` — `ServerDetail` rows: `Command.Item onSelect={() => toggle(opt.name)}`
    (`:723`); visual-only checkbox (`:732-742`); existing schema-peek chevron with `stopPropagation`
    (`:778-806`); `expandedTool` selection state (`:159,186`); `schemaByTool` map (`:608-615`);
    `WorkspaceShell` call (`:210-216`).
  - `hooks/useToolsEditor.ts` — `ToolRow` descriptions sourced from the global `tools` store
    (`:88-107`); editor toggle/dirty/save controller. Post-save refresh re-fetches tools
    (`:219,243,295`).
  - `lib/api.ts:120` `fetchTools`; `stores/useStackStore.ts` `tools`/`setTools` (`:52,80,100,154`);
    `hooks/usePolling.ts:32` polls tools.
  - Header global search uses `useFuzzySearch(tools, …)` (`ToolsWorkspace.tsx:191`).

### Reusable Components
- `ui/CodeViewer.tsx` — the exact "spec code" tokenized, line-numbered renderer the user referenced;
  already used for the inline schema peek. Use for the schema in the panel.
- `inspector/InspectorHeader.tsx` + `inspector/InspectorSection.tsx` — themed, collapsible panel
  scaffolding (accent tones, close affordance) used by the Topology inspector.
- `registry/SkillEditor.tsx` `renderMarkdown()` + `MarkdownPreview`, and the `.prose-playground`
  CSS class in `index.css` — for rendering the tool description as formatted markdown.
- `WorkspaceShell` right rail — resize/collapse (`]`), per-workspace width persistence, for free.

## Market Analysis

### Competitive Landscape
- **Anthropic MCP Inspector** uses the identical list-left / detail-right layout: selecting a tool
  renders its name, description, and derived JSON schema on the right. Directly on-point for an MCP
  gateway console.
- **Swagger/OpenAPI UI, Postman, Insomnia** all surface description + request/response schema on
  selection (Swagger inline-expands; the others use a detail view).

### Market Positioning
Table-stakes for the API/MCP-tooling category, not a differentiator. The differentiation opening
for gridctl is *richer* metadata than Swagger/Inspector surface — downstream server identity,
audit/usage stats, whitelist state.

### Ecosystem Support
No library needed; all UI primitives already exist in-repo and on-theme.

### Demand Signals
The "whole row toggles" behavior is a documented UX anti-pattern (mis-clicks fire unintended
toggles); the proposed checkbox/row split is the established Gmail/Finder/Linear convention.

## User Experience

### Interaction Model
- Checkbox click → stage enable/disable (existing `toggle`), `stopPropagation` so it never selects.
- Row-body click / Enter → set the selected tool; the right rail shows its detail.
- Two distinct selection concepts must stay visually + semantically separate: checkbox `checked`
  (whitelist membership, drives Save) vs. `aria-current`/`aria-selected` active row (drives panel).

### Workflow Impact
Removes friction (no leaving the UI to learn a tool); fills dead space. Replaces the transient
inline chevron-expand with a persistent panel (single source of truth for schema).

### UX Recommendations
- Explicit empty state in the panel ("Select a tool to view its details"), never a blank gap.
- Graceful degradation: if a tool has no description/schema even in the catalog, show name +
  metadata and a muted "No description available" rather than empty sections.
- Accessibility: independent focus vs. selection; Enter activates row→panel, Space toggles checkbox;
  visible focus ring; selection not conveyed by color alone.
- Theme: `CodeViewer` for the schema + `InspectorHeader` primary (amber) accent — consistent with
  the rest of the workspace.

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | No in-UI tool detail (esp. code mode); wasted right-hand space |
| User impact | Broad + Deep | Every Tools-workspace user, every visit |
| Strategic alignment | Core | Mirrors MCP Inspector; stays valuable as code mode becomes default |
| Market positioning | Catch up + small leap | Table-stakes to match; richer metadata is the leap |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | New read-only endpoint + new store source + toggle/select split |
| Effort estimate | Small–Medium | One panel component, ~1 Go method + handler/route, localized rewiring, test updates |
| Risk level | Low | Read-only data (already in memory); main risk is regressing cmdk keyboard/selection |
| Maintenance burden | Minimal | Reuses CodeViewer/InspectorHeader/InspectorSection; one small endpoint to own |

## Recommendation

**Build.** High value, low cost, low risk, strong architectural fit. The right rail is already
wired and unused; every UI primitive the panel needs exists and is on-theme. The one real finding —
that code mode withholds per-tool detail from `/api/tools` — is resolved by a small read-only
`/api/tools/catalog` endpoint that serves the full inventory with **raw** descriptions, since the
gateway already holds the data in memory. Scoping the feature as *frontend panel + this endpoint*
makes it work in both modes and keeps it valuable as code mode becomes the default.

Care-points baked into the prompt: keep checkbox-toggle vs. row-select visually/semantically
distinct, `stopPropagation` the checkbox to avoid the double-toggle bug, return **raw** (not
code-mode-wrapped) descriptions from the catalog endpoint, preserve `react-hooks` purity
conventions, and update `ToolsWorkspace.test.tsx` (which asserts the old whole-row-toggle aria).

A natural, low-cost consequence: pointing the workspace at the catalog also fixes the header global
search, which today only matches the two meta-tools in code mode.

## References

- MCP Inspector — https://github.com/modelcontextprotocol/inspector
- MCP Inspector deep dive — https://www.digitalapplied.com/blog/anthropic-mcp-inspector-deep-dive-developer-workflow-2026
- NN/G, Checkboxes: Design Guidelines — https://www.nngroup.com/articles/checkboxes-design-guidelines/
- NN/G, 8 Design Guidelines for Complex Applications — https://www.nngroup.com/articles/complex-application-design/
- W3C ARIA APG, Keyboard Interface — https://www.w3.org/WAI/ARIA/apg/practices/keyboard-interface/
- Swagger, Paths & Operations — https://swagger.io/docs/specification/v3_0/paths-and-operations/

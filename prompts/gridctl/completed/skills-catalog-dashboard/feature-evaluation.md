# Feature Evaluation: Skills Catalog Dashboard

**Date**: 2026-03-28
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Small-Medium

## Summary

The canvas is cluttered because skill group nodes (8+) occupy Zone 5 as topology nodes connected by dashed lines to the gateway — but skills are static reference documents, not live data-flow connections, and don't belong on an infrastructure topology diagram. The fix is two-pronged: remove skill nodes from the canvas and promote the existing `DetachedRegistryPage` skeleton into a proper skills dashboard with card layout, fuzzy search, and a clear navigation entry point from the gateway node.

## The Idea

Three options were evaluated against the screenshots and codebase:

1. **Remove skill group nodes from canvas entirely** — clean canvas, but creates a discoverability gap
2. **Single "Skills Registry" summary node under gateway** — reduces 8+ nodes to 1, but redundant with gateway stats and perpetuates the wrong mental model
3. **Remove from canvas + dedicated Skills Dashboard page** ← recommended

The Skills Dashboard is a dedicated full-page view: card grid per skill (name, description, state badge, test status, source), real fuzzy search (fuse.js), filter tabs (All/Active/Draft/Disabled), and a clear nav entry point via the gateway node's clickable Skills row. The canvas becomes semantically clean — only active data-flow connections remain.

**Problem solved**: Canvas clutter that degrades the primary topology visualization. Skills are a catalog/registry concern, not a topology concern.

**Who benefits**: Every user of the canvas (clutter eliminated) and anyone managing skills (better discoverability, richer metadata, fuzzy search).

## Project Context

### Current State

gridctl is a containerized MCP gateway aggregator. The React Flow canvas shows a butterfly hub-and-spoke layout:
- Zone 0 (left): Linked LLM clients (Claude Desktop, Claude Code)
- Zone 1 (center): Gateway hub node — shows MCP Servers, Sessions, Clients, Tools, Skills count
- Zone 2 (right): MCP server nodes (atlassian, github, zapier) — active connections with health/tool counts
- Zone 3: Resource nodes (databases, infra)
- Zone 5 (far right): Skill group nodes — 8+ nodes connected via dashed lines

The last two PRs (PR #321, skill-node-grouping) consolidated individual skill nodes into directory-based group nodes. This reduced clutter somewhat but did not solve the root problem: skills don't belong on the topology canvas at all. The canvas nodes now function as navigation affordances to the sidebar rather than topology participants — which is itself evidence the current design is wrong.

### Integration Surface

| File | Change |
|------|--------|
| `web/src/lib/graph/nodes.ts` | Remove `createSkillGroupNodes()` from `createAllNodes()`, or gate behind `useUIStore` toggle |
| `web/src/lib/graph/edges.ts` | Remove `edge-gateway-skill-group-*` edge creation |
| `web/src/lib/graph/butterfly.ts` | Zone 5 skill layout can be removed or left dormant |
| `web/src/pages/DetachedRegistryPage.tsx` | Upgrade from accordion list to card grid with fuzzy search |
| `web/src/components/registry/RegistrySidebar.tsx` | Upgrade search from `includes()` to fuse.js; sidebar remains for quick access |
| `web/src/components/graph/GatewayNode.tsx` | Make Skills stat row clickable (navigate to dashboard) |
| `web/src/main.tsx` | `/registry` route already exists for the detached page |
| `web/src/components/ui/` | Add `SkillCard` component |

### Reusable Components

- `RegistrySidebar.tsx`: existing API calls, state management, CRUD operations — port data fetching to dashboard
- `AggregateStatus` from `SkillGroupNode.tsx`: passing/failing/untested status display — port directly to `SkillCard`
- `DetachedRegistryPage.tsx`: page shell, error boundary, BroadcastChannel sync, polling — upgrade layout only
- `useRegistryStore.ts`: all skills data and CRUD operations — use as-is, no changes needed
- All registry API endpoints already exist — zero backend changes required

## Market Analysis

### Competitive Landscape

Every comparable tool in this space separates the topology canvas from the catalog/registry:

- **n8n / Node-RED**: Node palette (catalog) lives in a sidebar. The canvas shows only nodes you've placed and wired. Catalog items never appear on the canvas.
- **Airflow / Dagster / Prefect**: Strict separation between the DAG execution graph (live topology) and the Asset Catalog (browseable, searchable registry). Dagster's Asset Catalog is a flagship feature precisely because it is a distinct surface.
- **VS Code Extensions / GitHub Actions Marketplace**: Full panel/page with search, categories, and metadata cards. Never rendered in the editor canvas.
- **Retool / Appsmith**: Component libraries are sidebars; the canvas is live application layout only.

The universal rule: **active connections with live runtime status go on the canvas; passive catalog items go in a sidebar or catalog view.**

### Market Positioning

This is **table-stakes for the category**. Every comparable tool separates topology from catalog. Skill group nodes on the canvas are behind the industry pattern. Building Option C brings gridctl in line with — and with fuzzy search and card layout, slightly ahead of — the baseline.

### Ecosystem Support

- **fuse.js v7**: Standard client-side fuzzy search for small-medium datasets. `useMemo`-constructed once, 0.1–1ms query time for 20+ skills. Threshold `0.4`, fields `[name, description]`. Zero new API endpoints needed.
- **cmdk**: Already used in gridctl's `CommandPalette.tsx` — fuse.js is a natural complement for inline search on the dashboard.
- No new backend changes required — all data is available via existing registry endpoints.

### Demand Signals

The user explicitly confirmed the canvas "still feels very cluttered" after two dedicated PRs attempting to address it. The problem is persistent and user-confirmed. The existing `DetachedRegistryPage.tsx` in the codebase signals prior intent to have a separate registry view — it simply was never promoted as the primary surface.

## User Experience

### Interaction Model

**Canvas (after cleanup)**:
- Skill group nodes and their dashed edges are gone
- GatewayNode's Skills row (`21/21 active`) remains as the sole canvas touchpoint for skills
- Skills row becomes clickable: clicking opens the Skills Dashboard
- Canvas is now a pure topology: clients → gateway → MCP servers → resources

**Skills Dashboard (upgraded primary surface)**:
- Accessible via: clickable gateway Skills row, nav button, or sidebar popout
- Card grid: 2 columns at sidebar width, auto-expanding in full-page mode
- Each card: icon, name, description (2-line clamp), state badge (active/draft/disabled), test status (passing/failing/untested), source/version if available
- Filter tabs above search: `All · Active · Draft · Disabled` with live count badges
- Fuzzy search bar: real-time, covers name + description
- Card actions: Enable/Disable, Edit, Delete (same actions as current RegistrySidebar)
- Empty state with suggestion when no results match

**RegistrySidebar** (unchanged):
- Remains embedded in GatewaySidebar for quick access when gateway node is selected
- Gets the same fuse.js upgrade for its search bar

### Workflow Impact

- **Positive**: Canvas cognitive load drops — no longer split between "live topology" and "reference catalog"
- **Positive**: Skills dashboard provides richer display than the sidebar accordion at sidebar width
- **Positive**: Fuzzy search scales with registry size; substring match degrades above 30–40 skills
- **Neutral**: Users who click skill group nodes to open the sidebar learn the new entry point (low friction — Skills row in gateway is prominent and persistent)
- **No regression**: RegistrySidebar remains accessible; the dashboard is an enhancement, not a replacement

### UX Recommendations

1. Make the GatewayNode's Skills row visually interactive — `cursor-pointer`, subtle `hover:bg-primary/5` — so users discover the navigation affordance without instruction
2. Card state badges use the existing color system: `active` = emerald-400, `disabled` = text-muted, `draft` = amber-400
3. Filter tab counts reflect the search-filtered set, not the total (e.g., "Active (12)" not "Active (18)" when search is active)
4. The pop-out window should open the dashboard card view, not the sidebar list
5. Preserve the `AggregateStatus` health indicator (failing/untested/passing) on each card — this is the only meaningful runtime signal from the current skill group nodes worth preserving

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Canvas clutter actively degrades the primary topology visualization |
| User impact | Broad+Deep | Every canvas user sees the clutter; dashboard benefits all skill management workflows |
| Strategic alignment | Core mission | Clean topology + catalog separation is the right long-term architecture |
| Market positioning | Catch up | Every comparable tool already separates these; gridctl is behind the pattern |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Removing canvas nodes is a one-line change in `createAllNodes()`; page shell already exists |
| Effort estimate | Small-Medium | Card layout + fuse.js + nav wiring; no new API endpoints needed |
| Risk level | Low | Canvas removal is reversible with a toggle; dashboard is purely additive |
| Maintenance burden | Minimal | Same data model, Zustand store, and API surface throughout |

## Recommendation

**Build with caveats.**

Build Option C: remove skill group nodes from the canvas and upgrade `DetachedRegistryPage` into a proper skills dashboard. The caveats:

1. **Do NOT build a "Skills Registry" summary node** (Option B) — it duplicates the gateway stats row, adds a new node type for no net gain, and perpetuates the wrong mental model.
2. **Gate canvas removal with a UI toggle** initially — add `showSkillsOnCanvas` to `useUIStore` (same pattern as `showHeatMap`), defaulting to `false`. Provides a rollback path without reverting code.
3. **Keep `RegistrySidebar`** — the dashboard is the primary surface for full management; the sidebar remains for quick access when the gateway node is selected.
4. **Upgrade both sidebar and dashboard search to fuse.js in the same PR** — don't leave one with substring matching.

The `DetachedRegistryPage.tsx` skeleton already exists. This is a layout upgrade + nav wiring, not a new page build. Estimated effort: 1–2 focused sessions.

## References

- n8n canvas/palette separation: https://docs.n8n.io
- Dagster Asset Catalog: https://docs.dagster.io/concepts/assets/software-defined-assets
- fuse.js: https://fusejs.io
- cmdk (already in gridctl): https://cmdk.paco.me
- React Flow custom nodes: https://reactflow.dev/docs/api/nodes/custom-nodes

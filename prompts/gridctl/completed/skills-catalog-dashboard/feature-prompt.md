# Feature Implementation: Skills Catalog Dashboard

## Context

**Project**: gridctl — a containerized MCP (Model Context Protocol) gateway aggregator with a Go backend and a React + TypeScript web UI. The web UI uses `@xyflow/react` (React Flow) for a node-based topology canvas, Zustand for state management, and Tailwind CSS with a dark glassmorphic design system. Build tool is Vite.

**Tech stack (frontend)**:
- React 18 + TypeScript
- `@xyflow/react` for canvas
- Zustand stores: `useUIStore`, `useRegistryStore`, `useStackStore`
- Tailwind CSS with custom design tokens (text-primary, text-secondary, text-muted, surface, background, primary, tertiary, etc.)
- lucide-react for icons
- Existing component library: `IconButton`, `PopoutButton`, `StatusDot`, `Toast`, `ZoomControls`

**Architecture**: butterfly hub-and-spoke canvas layout with 5 zones. Skills currently occupy Zone 5 as `SkillGroupNode` nodes connected to the gateway via dashed edges.

## Evaluation Context

- Skills are static reference documents (SKILL.md files), not live data-flow connections. Every comparable tool (n8n, Dagster, VS Code) separates topology canvas from catalog/registry.
- The GatewayNode already displays `activeSkills/totalSkills` in its stats grid — this is the correct canvas-level touchpoint.
- `DetachedRegistryPage.tsx` already exists as a page shell — this is an upgrade, not a new page.
- `RegistrySidebar.tsx` already has search (substring), list layout, CRUD actions, and popout — keep it, upgrade its search.
- Full evaluation: `prompts/gridctl/skills-catalog-dashboard/feature-evaluation.md`

## Feature Description

Remove skill group nodes from the canvas topology and build a proper Skills Dashboard as the primary skill management surface. The dashboard provides a card grid layout with fuzzy search and filter tabs. The gateway node's Skills stat row becomes the navigation entry point.

**What to build**:
1. Remove `SkillGroupNode` nodes from the canvas (gate behind a `showSkillsOnCanvas` UIStore toggle defaulting to `false`)
2. Add a `SkillCard` component for the dashboard card grid
3. Upgrade `DetachedRegistryPage` to the card grid layout with fuse.js fuzzy search and filter tabs
4. Upgrade `RegistrySidebar` search from `includes()` to fuse.js
5. Make the GatewayNode's Skills stat row clickable/navigable to the dashboard
6. Add a canvas control button to toggle skills visibility (same pattern as heatmap toggle)

## Requirements

### Functional Requirements

1. Canvas no longer renders `SkillGroupNode` nodes or their dashed edges by default
2. `useUIStore` has a `showSkillsOnCanvas` boolean (default `false`) and `toggleSkillsOnCanvas()` action
3. Canvas controls panel has a new button (BookOpen icon) that toggles `showSkillsOnCanvas`; when enabled, existing skill group nodes reappear
4. GatewayNode's Skills stat row (`Library` icon, "Skills", `21/21` count) is `cursor-pointer` with hover state; clicking it navigates to the skills dashboard
5. `SkillCard` component renders: icon (BookOpen), name (truncated to 1 line), description (2-line clamp), state badge (active/draft/disabled), test status badge (passing/failing/untested), source/version if available
6. Skills Dashboard (upgraded `DetachedRegistryPage` at `/registry`) shows a responsive card grid (2 columns min, auto-expand at full page width)
7. Dashboard has filter tabs: `All`, `Active`, `Draft`, `Disabled` with count badges showing live-filtered counts
8. Dashboard has a fuzzy search bar (fuse.js, fields: `name` + `description`, threshold `0.4`) that updates in real-time
9. Filter tabs and fuzzy search compose: search runs on the tab-filtered set
10. `RegistrySidebar.tsx` search upgraded from `includes()` to fuse.js with the same config
11. Empty state displays when no skills match the current filter + search combination
12. Card actions (Enable/Disable, Edit, Delete) remain accessible — either always-visible at card bottom or on hover with keyboard focus support

### Non-Functional Requirements

- No layout shift when toggling between filter tabs
- Fuzzy search response time < 5ms for up to 100 skills (fuse.js `useMemo`, reconstructed only when skills array changes)
- Card grid uses CSS grid with `auto-fill` / `minmax` so it responds to window width without breakpoint hardcoding
- State badges and test status badges use the existing color tokens — do not introduce new colors
- The `showSkillsOnCanvas` toggle persists in `useUIStore` (localStorage via Zustand persist middleware if already configured)

### Out of Scope

- Backend changes — all data available via existing API endpoints
- New API endpoints
- Changes to `SkillEditor.tsx` or `SkillFileTree.tsx`
- Removing `RegistrySidebar` — it stays as a quick-access surface when gateway node is selected
- Redesigning the GatewayNode stats grid beyond making the Skills row clickable
- Multi-select or bulk operations on the dashboard

## Architecture Guidance

### Recommended Approach

Follow the existing patterns precisely:
- UIStore toggle: mirror `showHeatMap` / `toggleHeatMap` exactly for `showSkillsOnCanvas`
- Canvas control button: mirror the existing `HeatMapButton` pattern in the canvas controls panel
- Fuse.js: construct in `useMemo` keyed on the skills array; expose as a shared hook if used in both sidebar and dashboard
- Card grid: CSS grid on the page, same spacing/radius tokens as other card surfaces in the project

### Key Files to Understand First

| File | Why it matters |
|------|---------------|
| `web/src/lib/graph/nodes.ts` | `createAllNodes()` — where to gate skill group node creation |
| `web/src/lib/graph/edges.ts` | Where to gate `edge-gateway-skill-group-*` edge creation |
| `web/src/stores/useUIStore.ts` | Pattern for adding `showSkillsOnCanvas` toggle |
| `web/src/components/graph/Canvas.tsx` | Canvas controls panel — where to add the skills toggle button |
| `web/src/components/graph/GatewayNode.tsx` | Skills stat row (lines 120–133) — make it clickable |
| `web/src/components/graph/SkillGroupNode.tsx` | `AggregateStatus` component — port to `SkillCard` |
| `web/src/pages/DetachedRegistryPage.tsx` | Page shell to upgrade — error boundary, polling, BroadcastChannel already here |
| `web/src/components/registry/RegistrySidebar.tsx` | Existing search at line 82–89 — upgrade to fuse.js |
| `web/src/stores/useRegistryStore.ts` | Skills data source — use as-is |
| `web/src/main.tsx` | `/registry` route already exists |

### Integration Points

**Step 1 — Canvas cleanup** (low risk, do first):
- In `nodes.ts` `createAllNodes()`: wrap `...createSkillGroupNodes(skills)` behind `if (showSkillsOnCanvas)`
- In `edges.ts`: wrap gateway-to-skill-group edge creation behind the same flag
- Add `showSkillsOnCanvas: false` + `toggleSkillsOnCanvas()` to `useUIStore`
- Pass the flag down from wherever `createAllNodes()` is called (likely the main stack store)
- Add canvas control button with BookOpen icon

**Step 2 — GatewayNode navigation**:
- Accept an `onSkillsClick?: () => void` prop on `GatewayNode`
- Add `cursor-pointer hover:bg-primary/5 rounded-md transition-colors` to the Skills row div
- Call `onSkillsClick` on click
- Wire in the canvas: the handler navigates to `/registry` or opens the dashboard window

**Step 3 — SkillCard component**:
- New file: `web/src/components/registry/SkillCard.tsx`
- Props: `AgentSkill`, `onEnable`, `onDisable`, `onEdit`, `onDelete`
- Port `AggregateStatus` logic from `SkillGroupNode.tsx` for the test status badge
- State badge: `active` = `text-emerald-400 bg-emerald-400/10 border-emerald-400/25`, `disabled` = muted, `draft` = `text-amber-400 bg-amber-400/10 border-amber-400/25`

**Step 4 — Dashboard upgrade**:
- Replace the accordion list in `DetachedRegistryPage.tsx` with the card grid
- Add fuse.js search hook
- Add filter tabs (All/Active/Draft/Disabled) with count badges
- Reuse `SkillCard` component

**Step 5 — Sidebar search upgrade**:
- Install fuse.js if not already present: `npm install fuse.js`
- Replace `filteredSkills` useMemo in `RegistrySidebar.tsx` (lines 82–89) with fuse.js

### Reusable Components

- `AggregateStatus` in `SkillGroupNode.tsx` — port as-is into `SkillCard`
- `PopoutButton` — reuse in dashboard header
- `IconButton` — reuse for card actions
- Existing `showToast` for action feedback
- `useRegistryStore` — all data fetching, no changes

## UX Specification

**Discovery**: Users see "Skills: 21/21" in the GatewayNode stats. Row is visually interactive (hover state). Click navigates to the dashboard.

**Dashboard layout**:
```
[Search bar — full width]
[All (21)] [Active (18)] [Draft (2)] [Disabled (1)]   ← filter tabs
[SkillCard] [SkillCard] [SkillCard] [SkillCard]
[SkillCard] [SkillCard] ...
```

**Card anatomy**:
```
┌─────────────────────────────────────┐
│ [📖 icon]  skill-name        [badge]│
│ Description text, up to two lines   │
│ of content before it is clamped...  │
│                                     │
│ [passing ✓]  [Enable] [Edit] [Del]  │
└─────────────────────────────────────┘
```

**Search behavior**: As the user types, the visible cards filter in real-time. The filter tab counts update to reflect the searched set. Empty state: "No skills match '[query]'" with a "Clear search" link.

**Canvas toggle**: Canvas controls panel (bottom-left) gets a new `BookOpen` icon button. Active state (skills visible on canvas) shows the button with `text-tertiary` coloring; default (hidden) shows it dimmed. Tooltip: "Show skill groups on canvas".

**Error states**: Reuse existing `DetachedErrorBoundary` in `DetachedRegistryPage`. For card actions, reuse `showToast` with error messages.

## Implementation Notes

### Conventions to Follow

- All new files in `web/src/components/registry/` or `web/src/pages/`
- Tailwind only — no inline styles except where dynamic values require it
- Use `cn()` utility for conditional class names
- Use `memo()` for the `SkillCard` component
- Icon sizes: 14px for card body, 16px for action buttons (match existing patterns in `RegistrySidebar`)
- No new color tokens — use existing design system tokens

### Potential Pitfalls

1. **`createAllNodes()` call site** — find where it's called in the stack store and pass the UIStore flag down; don't call `useUIStore` inside a non-React function
2. **Fuse.js `useMemo` dependency** — key the Fuse instance on the skills array reference, not its length, to avoid stale index
3. **Filter tab counts with live search** — compute counts from the search-filtered set, not the total set, so they stay in sync
4. **GatewayNode click vs. canvas drag** — use `onClick` with `e.stopPropagation()` only on the Skills row div, not the whole node, to avoid interfering with canvas drag behavior
5. **`DetachedRegistryPage` vs embedded** — the page is opened in a new window; ensure the card grid layout works at both narrow (popped-out sidebar width) and wide (full monitor) dimensions

### Suggested Build Order

1. Add `showSkillsOnCanvas` to `useUIStore` and gate canvas node/edge creation — verify canvas is clean
2. Add canvas controls toggle button — verify toggle works
3. Make GatewayNode Skills row clickable and navigate to `/registry`
4. Install fuse.js, create shared fuzzy search hook
5. Build `SkillCard` component with all variants (active/draft/disabled, passing/failing/untested)
6. Upgrade `DetachedRegistryPage` to card grid with filter tabs + fuzzy search
7. Upgrade `RegistrySidebar` search to fuse.js
8. Smoke test: open dashboard, search, filter tabs, enable/disable, edit, delete

## Acceptance Criteria

1. The canvas no longer shows skill group nodes or their dashed edges on initial load
2. The canvas controls panel has a BookOpen toggle; enabling it restores skill group nodes on the canvas
3. Clicking the GatewayNode's Skills stat row navigates to the skills dashboard
4. The skills dashboard shows skills as cards in a 2+ column grid
5. The fuzzy search bar filters cards in real-time; searching "feat" surfaces "feature-dev", "feature-scout", "feature-build", etc.
6. Filter tabs (All/Active/Draft/Disabled) filter the card grid and show live counts
7. Filter tabs and search compose correctly (tab first, then search within tab results)
8. Each card shows: name, description (2-line clamp), state badge, test status badge
9. Card actions (Enable/Disable/Edit/Delete) work and show toast feedback
10. `RegistrySidebar` search uses fuzzy matching — searching "feat" returns feature-* skills
11. Empty state displays when no skills match the current query
12. No TypeScript errors (`npm run typecheck` passes)
13. No new lint errors (`npm run lint` passes)

## References

- Full evaluation: `prompts/gridctl/skills-catalog-dashboard/feature-evaluation.md`
- fuse.js docs: https://fusejs.io/api/options.html
- React Flow node interaction: https://reactflow.dev/docs/api/nodes/custom-nodes
- Dagster Asset Catalog (reference pattern): https://docs.dagster.io/concepts/assets/software-defined-assets
- `web/src/components/graph/SkillGroupNode.tsx` — `AggregateStatus` component to port
- `web/src/stores/useUIStore.ts` — `showHeatMap` / `toggleHeatMap` pattern to mirror

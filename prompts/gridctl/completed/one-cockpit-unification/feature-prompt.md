# Feature Implementation: One Cockpit Unification

## Context

`gridctl` is a Go-based developer tool for managing MCP (Model Context Protocol) servers, stacks, agent skills, and their executions. It ships a single binary (`gridctl serve`) that hosts a React + Vite + Zustand + React Flow + Tailwind SPA on `localhost:5173` (dev) / configurable (prod). Repository: `~/code/gridctl/`. Frontend lives in `web/`. Backend in `internal/`, `pkg/`, `cmd/`.

The SPA currently exposes two visually and architecturally distinct shells:

- **Topology** (`/`) — operator view. Dense Header with telemetry pills + vault + spec + wizard buttons, left Sidebar Inspector, BottomPanel with 5 tabs (Logs/Metrics/Spec/Traces/Pins), StatusBar, Command Palette (cmdk). React Flow graph of stacks/MCP servers/gateways/clients with 10+ overlay modes (heatmap, drift, wiring, spec, secrets, etc.). Lives in `web/src/App.tsx` and `web/src/components/{graph,layout}/`.
- **Agent IDE** (`/agent`) — developer view. Three-pane layout (280px `SkillSidebar` | Canvas | 360px `NodeDetail`), minimal Toolbar, no Header, no command palette, no BottomPanel. Read-only React Flow graph of typed-skill nodes with execution trace overlay. Lives in `web/src/components/agent/ide/`. Code-split via `LazyAgentIDEPage` in `web/src/main.tsx`.

The unification refactor lives in `proto/idea/`:
- `proto/idea/idea.md` — original analytical brief (Brad Frost / NN-G / Dagster anchored)
- `proto/idea/refined.md` — distilled architectural strategy + 4-phase roadmap
- `proto/idea/updates.md` — pushback decisions made during the distillation (Hybrid Header over Activity Bar; no transitional patches; preserve Obsidian Observatory palette)
- `proto/idea/architecture.md` — equivalent to first half of `refined.md`

Read all four before starting Phase 1 work.

## Evaluation Context

The full evaluation that produced this prompt is in `feature-evaluation.md` (sibling file). Key findings that shape this prompt:

- **Strategic alignment is high.** Maturing gridctl into the LangSmith/Temporal/Dagster category requires a unified shell. Two shells is alpha-tier positioning. Ship the vision.
- **Four architectural specifics in `refined.md` are over-engineered or anti-pattern** and should be replaced:
  1. The **Polymorphic Inspector with Provider Registry** → two workspace-specific inspectors sharing primitives. Earned at 8+ entity types or with plugin extension; gridctl has neither.
  2. The **Unified React Flow Engine with layered rendering modes** → `CanvasBase` extracting shared infra, with separate `TopologyCanvas` and `SkillCanvas`. No precedent in xyflow community for layered modes on a single instance; canvas overlap is 35–40%, not enough to justify a unified mega-component.
  3. The **Workspace Orchestrator (store-of-stores)** → Zustand **slices pattern** in a single store or extension of `useUIStore`. Cross-store reads are the documented Zustand anti-pattern.
  4. The **"Context Continuity" success metric** (selection preserved across workspaces) → **"Deep Link Continuity"** (URLs survive workspace switches, back button works). The original solves a workflow with no evidence of use.
- **The 4-phase roadmap order should be flipped.** Lead with the Real Runs Workspace (highest user-facing win) after minimal shell scaffolding; defer/drop the unified canvas. See "Suggested Build Order" below.
- **Initial-load target** of `<500ms` is wrong-metric. Targets are **TTI <1s for shell, LCP <2s for workspace content, INP <200ms**.
- **Runs is NOT greenfield.** ~70% of Runs functionality already exists in the Agent IDE sidebar (`RunsList`, `RunOutputView`, per-node telemetry, per-run SSE streaming). The work is *relocation + elevation + new grid affordances*, not new construction.
- **`updates.md` decisions to respect**: Header-first navigation (not Activity Bar). No transitional "Back to gridctl" patch phase. Keep the three-accent Obsidian Observatory palette.

Link to full evaluation: `prompts/gridctl/one-cockpit-unification/feature-evaluation.md`

## Feature Description

Unify gridctl's two web shells into a single application chrome with three URL-routable workspaces:

- **`/topology`** — operator workspace (current `/` content, lifted into the new shell)
- **`/skills`** — developer workspace (current `/agent` content, lifted into the new shell)
- **`/runs`** — new global execution observability workspace

`/` redirects to a workspace inferred from project state (skills declared → `/skills`; else `/topology`); `/agent` redirects permanently to `/skills`.

The shell is constant across workspaces: Header (with workspace switcher pills + breadcrumb + telemetry + vault + ⌘K), BottomPanel (Logs / Metrics / Traces / Spec / Pins — cross-workspace), StatusBar (connection / servers / sessions / tokens / spec / last update). The right rail (Inspector) is workspace-specific. The center pane (Canvas / Workspace content) swaps wholesale per route.

The **Runs workspace** is a real new feature: filterable grid of all skill executions across the active stack, with ancestry tree for parent_run_id chains, comparison view for two runs side-by-side, and a global trace waterfall in the BottomPanel sourced from a new multi-run SSE event bus.

## Requirements

### Functional Requirements

**Shell & routing**
1. Add a parent route layout component (`AppShell`) that renders Header + Outlet + BottomPanel + StatusBar; the Outlet hosts `/topology`, `/skills`, `/runs` routes.
2. Header includes a workspace switcher as a segmented control with three pills (`Topology` / `Skills` / `Runs`) bound to React Router NavLinks. Active pill uses primary token. Always visible.
3. Keyboard shortcuts `⌘1` / `⌘2` / `⌘3` switch workspaces. `⌘K` opens the command palette globally.
4. `/agent` → 301 redirect to `/skills` for one minor version (then drop).
5. `/` → redirect based on project state: stack declares typed skills → `/skills`; else `/topology`. Last-workspace-per-stack persisted in localStorage (fingerprinted by project path/ID) and preferred over the heuristic on revisit.
6. URL deep links carry workspace state: `/runs/abc123?skill=triage_input&span=def456`. Back/forward navigation works. Reload preserves state.
7. **Explicit Route Guards:** Implement a `<WorkspaceGuard />` that verifies the underlying stack state is ready (e.g., ledger initialized for Runs) before allowing route transitions, displaying a specific `<WorkspaceReadyState />` if needed to prevent orphaned UI states.

**State management (slices pattern, single store)**
7. Extend `useUIStore` (or add a new `useShellStore` if it grows >300 LOC) with an `activeWorkspace` slice. Do NOT create a `useWorkspaceStore` "store of stores" with cross-store reads. The slices pattern (https://zustand.docs.pmnd.rs/learn/guides/slices-pattern) is the idiomatic approach.
8. Each workspace's existing store stays isolated (`useStackStore` for Topology, run state for Skills, new `useRunsStore` for Runs). The shell store contains *only* cross-workspace concerns: `activeWorkspace`, `compactMode`, `selectedEntity?: { type, id }` if needed for breadcrumbs.

**Inspector (two components, not polymorphic)**
11. Keep `web/src/components/layout/Sidebar.tsx` (Topology) and `web/src/components/agent/ide/NodeDetail.tsx` (Skills) as separate workspace-specific Inspectors. Render conditionally on `activeWorkspace`.
12. Extract shared section/tab primitives to `web/src/components/inspector/` (`<InspectorHeader>`, `<InspectorSection>`, `<InspectorTabList>`). Use them in both inspectors. Do not build a provider registry.
13. Runs workspace has its own `RunInspector` (new) showing run metadata, parent/child chain, span tree, output preview, action buttons (replay, open-in-editor, open-in-external-telemetry).

**Canvas (CanvasBase + two implementations)**
14. Extract `web/src/components/canvas/CanvasBase.tsx` providing: ReactFlow wrapper, viewport sync, grid background, base Controls panel (zoom/fit/reset), selection callbacks. ~150-200 LOC.
15. Keep `web/src/components/graph/Canvas.tsx` and `web/src/components/agent/ide/Canvas.tsx` as separate implementations, but refactor each to compose `CanvasBase` and provide workspace-specific node types, edge types, and overlay modes via props/children.
16. Do NOT build a single canvas with layered rendering modes. Do NOT merge the node type registries.

**Real Runs workspace**
17. New page at `/runs` rendering a grid with columns: Run ID, Skill, Status (with icon), Started At, Duration, Event Count, Parent Run, Error snippet (truncated). Default sort by Started At desc.
18. Filters above the grid: Status (running / completed / errored / awaiting_approval), Skill (multi-select), Started Since (relative — 5m, 1h, 24h, 7d, custom), Parent Run (text). URL-bound (`?status=&skill=&since=&parent=`).
19. Server-side pagination via cursor. Infinite scroll OR explicit pagination control — implementer's call, but it must work on 10k+ runs.
20. Selecting a row opens the `RunInspector` in the right rail. Double-clicking navigates to `/runs/:id` for the dedicated detail view.
21. Dedicated detail view at `/runs/:id`: shows full Honeycomb-style waterfall (parent-child timeline), span list with filter, output preview, and a "Compare with..." action to open a side-by-side view of two runs.
22. Ancestry tree: when a run has parent_run_id, the grid groups (collapsible) by root parent. Expanding shows children indented.
23. BottomPanel Traces tab: live waterfall fed by the new global event SSE bus. Spans appear as events arrive. Tab badge shows count of in-flight runs.

**Backend additions**
22. New endpoint `GET /api/agent/runs/events/stream` — SSE stream of run lifecycle events across all runs (run_started, run_completed, run_errored, node_enter, node_exit, approval_request). Backed by an in-memory broadcast bus subscribed by the existing per-run recorder.
23. Extend `GET /api/agent/runs` with query params: `?status=&skill=&since=&parent=&limit=&cursor=`. Implement server-side filtering against the ledger directory; for now an in-memory scan over `~/.gridctl/runs/*.jsonl` summaries is acceptable (document the rebuild-an-index TODO).
24. Optional `GET /api/agent/runs/{id}/compare/{other_id}` — returns aligned event diff for the comparison view. May be deferred to a follow-up if scope tight.
25. **SSE Replay Protection:** The client MUST explicitly check the **Sequence ID (seq)** against a "Last Seen" watermark in `useRunsStore` to deduplicate and prevent UI flicker during reconnection replays.

**Command palette (workspace-scoped)**
26. **Registration-based Palette Pattern:** Implement a system where each workspace component registers its specific commands to a global palette store on mount and unregisters them on unmount. This ensures `Topology` commands do not leak into the `Skills` chunk, aiding code-splitting.
27. Add palette commands: "Go to Topology / Skills / Runs", "Switch stack: X", "Open run by ID", "Filter runs by status: errored", "Compare runs".

**Compact Mode**
28. Add a Compact Mode toggle (header settings dropdown or `⌘\` shortcut). When active: Header pills collapse to icons-only, BottomPanel auto-hides default tab in Skills mode, status bar shrinks. Persisted per user in localStorage.
29. Compact mode is default-on for `/skills` workspace, default-off for `/topology`. Users can override.

**Detached windows**
30. Detached window routes (`/logs`, `/sidebar`, `/editor`, `/metrics`, `/vault`, `/traces`, `/registry`) accept a `?workspace=` query param. They render workspace-appropriate content (e.g., `/sidebar?workspace=skills` renders `NodeDetail`; `?workspace=topology` renders the Topology Inspector).

### Non-Functional Requirements

- **Performance**: TTI <1s for shell load (cold cache, broadband). LCP <2s for the default workspace content. INP <200ms for workspace switches. Code-split each workspace into its own chunk via `React.lazy(() => import(...))` + `<Suspense>` boundaries.
- **Accessibility**: Workspace switcher uses `role="tablist"` with `aria-selected`. Keyboard focus order preserved across workspace switches. All Inspector tabs/sections keyboard-navigable. Color is not the only signal for run status (use icons too).
- **Compatibility**: Modern evergreen browsers (Chrome/Firefox/Safari). No IE11. No mobile/responsive scope in this iteration (both shells are desktop-only today; preserve that).
- **Visual system**: All new components use the Obsidian Observatory palette via Tailwind semantic tokens (`bg-primary`, `bg-secondary`, `bg-tertiary`, status tokens). Outfit for UI chrome, IBM Plex Mono for IDs/code/durations. No new font loads.
- **Bundle size**: Each workspace chunk <300KB gzipped. Vendor chunks (`vendor-react`, `vendor-graph`, `vendor-charts`) preserved.

### Out of Scope (explicitly)

- **Mobile / responsive design** — separate project; both shells are desktop-only.
- **Unified single-canvas with layered rendering modes** — explicitly rejected per evaluation. Keep two canvases.
- **Polymorphic Inspector with provider registry** — explicitly rejected.
- **"Context continuity" selection-preserved-across-workspace** — replace with deep-link continuity.
- **Geometry persistence across modes (Dagster-style layout cache)** — out of scope; defer to a future phase if Skills graphs grow beyond ~80 nodes.
- **External OTel handoff** (Open in Phoenix / Langfuse / LangSmith) — out of scope for this implementation; add a TODO comment in `RunInspector` action area.
- **MCP Apps integration** in Inspector — out of scope; Inspector should remain iframe-friendly so this can be additive later.
- **Multi-stack federation in Runs view** — Runs is scoped to the active stack. A "Show all stacks" toggle can be a follow-up.
- **Auth / multi-user namespacing** — gridctl is single-bearer-token; no changes needed.
- **TanStack Router migration** — stay on React Router. TanStack is worth evaluating later if param/loader type-safety becomes painful.
- **Jotai migration** — stay on Zustand; use slices pattern. Re-evaluate if cross-workspace derived state becomes painful.

## Architecture Guidance

### Recommended Approach

This refactor is fundamentally a **frontend lift-and-reshape**, not a rewrite. The existing code is mostly good; the right move is to:

1. **Build the new shell skeleton first** (Phase 1) as the smallest possible parent route layout that hosts the existing Topology shell unchanged. Verify that nothing visually changes for Topology users when the new shell wraps the old `App.tsx`.
2. **Build the Runs workspace next** (Phase 2) as a fully-standalone feature. It can ship without the Skills migration if needed — that delivers the highest user value first and de-risks the bigger restructuring.
3. **Migrate Agent IDE into the new shell** (Phase 3). Drop the standalone `LazyAgentIDEPage` route. Move `AgentIDE.tsx` contents to a `SkillsWorkspace` component under the shared shell.
4. **Extract `CanvasBase` and shared primitives** (Phase 4). This is cleanup that doesn't change behavior; do it last so the earlier phases don't drag on it.

Use the [Zustand slices pattern](https://zustand.docs.pmnd.rs/learn/guides/slices-pattern) for the shell store. Do not access one store from inside another.

### Key Files to Understand

Before writing any code, read these (and `proto/idea/refined.md`, `proto/idea/updates.md`, `proto/idea/idea.md`):

| File | Why it matters |
|---|---|
| `web/src/main.tsx` | Current router config; this is where shell parent route gets added |
| `web/src/App.tsx` | Current Topology shell; becomes the `<TopologyWorkspace>` body after refactor |
| `web/src/components/agent/ide/AgentIDE.tsx` | Current Skills shell; becomes the `<SkillsWorkspace>` body |
| `web/src/components/layout/Header.tsx` | Hosts the new workspace switcher segmented control |
| `web/src/components/layout/Sidebar.tsx` | Topology Inspector — leave structure alone, add `<InspectorHeader>` extraction |
| `web/src/components/agent/ide/NodeDetail.tsx` | Skills Inspector — same pattern |
| `web/src/components/layout/BottomPanel.tsx` | Add a Traces tab that subscribes to the global event SSE |
| `web/src/components/palette/CommandPalette.tsx` | Add workspace scoping to command filters |
| `web/src/components/agent/ide/RunsList.tsx` | Lift-and-reshape this into the new `/runs` grid |
| `web/src/components/agent/ide/RunOutputView.tsx` | Compose into the new `RunInspector` |
| `web/src/stores/useUIStore.ts` | Where the `activeWorkspace` slice lives |
| `web/src/lib/agent-runs.ts` | Frontend API client; add filter param support + new event stream subscription |
| `internal/api/agent_runs.go` | Backend run handlers; add server-side filter, add global event stream endpoint |
| `pkg/agent/persist/store.go` | Ledger schema; understand event shape before building the bus |
| `pkg/agent/persist/events.go` | Event vocabulary used by the recorder; the global bus broadcasts the same shapes |
| `web/vite.config.ts` | Manual chunks config; ensure new workspaces get split |
| `tailwind.config.js` | Obsidian Observatory token mappings |

### Integration Points

| Layer | What changes | What stays |
|---|---|---|
| Router | New parent layout route, three workspace routes, redirects | All detached-window routes (`/logs`, `/sidebar`, `/editor`, etc.) |
| State | `useUIStore` gains `activeWorkspace` slice; new `useRunsStore` for runs filters/grid state | All 11 existing stores untouched (no migration to consolidate) |
| Components | New `AppShell`, `WorkspaceSwitcher`, `RunsGrid`, `RunInspector`, `RunWaterfall`. Extracted `InspectorHeader`, `InspectorSection`, `InspectorTabList`, `CanvasBase` | `Sidebar`, `NodeDetail`, both `Canvas` impls, all `components/ui/` primitives |
| API | New `/api/agent/runs/events/stream`; extended `/api/agent/runs` filters | All other endpoints unchanged |
| Visual | None — same tokens, fonts, palette | Everything |

### Reusable Components (extract during the refactor)

Place these in `web/src/components/inspector/` or `web/src/components/canvas/`:

- `<InspectorHeader title icon onClose onDetach>` — replaces duplicated header code in both Inspectors
- `<InspectorSection title icon defaultOpen>` — collapsible section currently inline in `Sidebar.tsx`
- `<InspectorTabList>` + `<InspectorTabButton>` — replaces three separate inline implementations
- `<EmptyState icon title description action?>` — used by both canvases
- `<CanvasBase>` — see requirement 12

## UX Specification

**Discovery**

- An existing user who bookmarks `/` is redirected to either `/topology` or `/skills` based on project state. A one-time toast says: "gridctl now has three workspaces — Topology, Skills, and Runs. ⌘K to navigate."
- An existing user who bookmarks `/agent` is permanently redirected to `/skills`.
- The workspace switcher is always visible in the Header. Active workspace is highlighted with primary token color.

**Activation**

- `⌘1` / `⌘2` / `⌘3` switch workspaces.
- `⌘K` opens the command palette globally. Commands include "Go to Topology", "Go to Skills", "Go to Runs", and per-workspace actions filtered by active workspace.
- Clicking a workspace pill in the Header updates the URL via React Router NavLink.

**Interaction (Runs workspace specifically)**

- Land on `/runs`: grid renders with default filters (last 24h, all statuses, all skills). Filters bar above grid is collapsible.
- Click a row: `RunInspector` slides in from the right (or replaces existing Inspector). Shows run summary, ancestry, output preview.
- Double-click a row OR click the run ID link: navigate to `/runs/:id` for the full detail view with waterfall.
- Shift-click two rows: "Compare" button appears in the toolbar.
- Toolbar action "Subscribe to live updates" toggles the global event SSE stream feeding the grid and the BottomPanel Traces tab.

**Feedback**

- In-flight runs animate a teal status dot. Errored runs show a red dot + truncated error in the grid.
- BottomPanel Traces tab shows a badge with the count of in-flight runs. New spans append in real time.
- Compact Mode toggle has an instant visual response (no flicker). Persisted across sessions.

**Error states**

- Failed to load runs list → in-grid empty state with retry button.
- SSE connection drops → toast "Live updates disconnected. Retrying..." with manual retry. Automatic exponential backoff.
- 404 on `/runs/:id` → friendly empty state with "Back to Runs" link.

## Implementation Notes

### Conventions to Follow

- **Code comments**: concise and meaningful, brief by default. Comments explain WHY, not WHAT. Don't add comments for self-evident code.
- **Naming**: kebab-case for filenames, PascalCase for components, camelCase for hooks (`useShellStore`), lowercase for stores (`useUIStore`, `useRunsStore`).
- **Stores**: Zustand slices pattern. Each slice exports `createXxxSlice` function; the root store composes them. No cross-slice reads except through actions.
- **Routing**: React Router v6+ with `createBrowserRouter` and nested routes; `<Outlet />` for the shell parent route.
- **Code splitting**: Each workspace chunk loaded via `React.lazy(() => import(...))` + `<Suspense fallback={<WorkspaceLoadingShell/>}>`.
- **Imports**: existing alias `@/*` for `web/src/*`. Don't introduce new aliases.
- **Tailwind**: semantic tokens only (`bg-primary`, `border-secondary`, `text-tertiary`). No raw color literals (`bg-amber-500`) in new code.
- **Tests**: gridctl frontend has Vitest + React Testing Library setup; add tests for the workspace switcher routing, redirect behavior, slices pattern store actions, runs grid filtering, SSE reconnection.
- **Backend (Go)**: standard gridctl conventions. SSE handlers follow the pattern in `internal/api/agent_runs.go::handleAgentRunEvents`. Use `pkg/tracing.Buffer`-style ring-buffer for the in-memory event bus.
- **Commits**: Use the `feat:` / `fix:` / `refactor:` types per `.claude/CLAUDE.md`. Sign with `-S`. No co-authored-by trailers. No mention of Claude in commits/PRs/branches. PR each phase separately.

### Potential Pitfalls

1. **The "store of stores" anti-pattern is tempting.** When you find yourself adding a `useWorkspaceStore` that imports and coordinates other stores, stop. Use a slice instead, or pass an action through props/context.
2. **The Polymorphic Inspector temptation will reappear.** When you find yourself wanting to "just unify these two right rails", remember: they serve different mental models. Different *roles*. Two inspectors sharing primitives is the right design.
3. **The Unified Canvas temptation will reappear.** Same advice. The canvases share infra (zoom, pan, selection); they do not share rendering. Resist any PR that tries to merge them.
4. **SSE reconnection edge cases.** When the daemon restarts, the global event stream may emit duplicate events (the recorder replays buffered events to new subscribers). Dedupe by `(run_id, seq)` on the client. Document this contract in the API.
5. **Run launches during workspace switches.** If a user launches a run from Skills and immediately switches to Runs, the new run must appear in the grid without a manual refresh. The global event SSE handles this — wire it up early.
6. **Default landing heuristic** ("skills declared → /skills") needs a reliable signal. Check for typed skills in the current stack config; if the API is slow, default to last-workspace-per-stack from localStorage instead.
7. **Compact Mode persisted state can conflict with `?compact=` URL param.** Decide which wins (recommend: URL param wins, but doesn't write to localStorage).
8. **Backend event bus cardinality.** With many concurrent runs and many subscribers, the broadcast bus can balloon memory. Use a bounded ring buffer (e.g., 1000 events) per subscriber with overflow drop + "stream restarted" sentinel.
9. **Detached window workspace context.** When `/sidebar?workspace=skills` opens in a new browser tab, it has no Zustand state. Either replay state from URL params, or read from a shared persistence layer (BroadcastChannel API is a clean option).
10. **`/agent` redirect** must NOT lose query params. `?skill=triage_input&run=abc` → `/skills?skill=triage_input&run=abc`.

### Suggested Build Order

This is a **flipped phasing** vs the original `refined.md` 4-phase roadmap. The new order leads with user value and defers the riskiest cleanup.

**Phase 1: Shell scaffolding & workspace router (1 week)** — One PR.

- Create `web/src/components/shell/AppShell.tsx`. Renders Header (existing) + `<Outlet />` + BottomPanel (existing) + StatusBar (existing).
- Add `WorkspaceSwitcher` to the Header with three NavLinks. Keyboard shortcuts `⌘1/2/3`.
- Update `web/src/main.tsx` router: parent route `<AppShell>` with children `/topology` (renders existing App-inner contents), `/skills` (placeholder), `/runs` (placeholder).
- `/` redirect logic. `/agent` permanent redirect.
- `activeWorkspace` slice added to `useUIStore`.
- Workspace-scoped command palette commands.
- Tests: routing, redirects, switcher behavior.
- **Acceptance**: existing Topology users see no visual change; URL is now `/topology`; `⌘K` shows workspace navigation actions; `/agent` redirects to `/skills` placeholder.

**Phase 2: Real Runs workspace (2 weeks)** — One or two PRs.

- Backend: extend `GET /api/agent/runs` with `?status=&skill=&since=&parent=&limit=&cursor=`. Add `GET /api/agent/runs/events/stream`.
- Frontend: `useRunsStore` slice, `RunsGrid`, `RunsFilterBar`, `RunInspector`, `RunWaterfall`, `/runs` + `/runs/:id` routes.
- BottomPanel Traces tab subscribes to global event stream.
- Ancestry grouping in the grid.
- Compare-runs view (stretch — can defer to Phase 4 if tight).
- Tests: filter URL binding, SSE reconnection, grid virtualization (10k rows), waterfall rendering.
- **Acceptance**: a developer launches a run from the existing Agent IDE; it appears in `/runs` immediately via SSE; clicking shows full waterfall.

**Phase 3: Migrate Agent IDE into the shell (1 week)** — One PR.

- Move `AgentIDE.tsx` contents to `web/src/components/skills/SkillsWorkspace.tsx`.
- `/skills` route renders `SkillsWorkspace` inside `AppShell`. Existing `SkillSidebar` becomes the left rail when Skills is active. `NodeDetail` becomes the right Inspector.
- BottomPanel and CommandPalette work in Skills mode (with workspace-scoped commands).
- Compact Mode toggle, default-on for Skills.
- Drop `LazyAgentIDEPage`.
- Tests: deep-link `/skills/:name`, Compact Mode persistence, detached window with `?workspace=skills`.
- **Acceptance**: every workflow a developer does today in `/agent` works at `/skills` under the unified shell, with bonus access to ⌘K and global Runs.

**Phase 4: Shared primitive extraction & polish (1 week)** — One PR.

- Extract `<InspectorHeader>`, `<InspectorSection>`, `<InspectorTabList>`, `<EmptyState>` to `web/src/components/inspector/` and `web/src/components/ui/`.
- Extract `<CanvasBase>` to `web/src/components/canvas/`; refactor both Canvas implementations to compose it.
- Visual polish pass: ensure semantic palette discipline (one accent per role) across all three workspaces.
- Documentation: `web/src/components/README.md` covering the shell architecture, store slices, and "what to do / what not to do".
- Tests: Canvas behavior unchanged after `CanvasBase` extraction.
- **Acceptance**: net LOC reduction; no behavioral changes; visual consistency audit passes.

## Acceptance Criteria

1. Existing `/` URL redirects to `/topology` or `/skills` per project state; users see no broken bookmarks.
2. `/agent` permanently redirects to `/skills` with query params preserved.
3. Workspace switcher in Header navigates between `/topology`, `/skills`, `/runs` with `⌘1/2/3` shortcuts.
4. `/runs` shows a filterable grid (status, skill, since, parent) URL-bound to query params; pagination works on 10k+ runs.
5. `/runs/:id` shows a Honeycomb-style waterfall with span list and output preview.
6. BottomPanel Traces tab shows live waterfall fed by a global SSE event bus.
7. Selecting an entity (server, skill node, run) opens the workspace-specific Inspector in the right rail.
8. Command palette is workspace-scoped: only relevant commands show per active workspace.
9. Compact Mode toggle persists per user; default-on in Skills.
10. Detached windows accept `?workspace=` param and render correct content.
11. No new Zustand "store of stores"; `activeWorkspace` lives in a slice of `useUIStore`.
12. `Sidebar.tsx` and `NodeDetail.tsx` are still separate components; they share extracted `<InspectorHeader>`, `<InspectorSection>`, `<InspectorTabList>`.
13. `web/src/components/graph/Canvas.tsx` and `web/src/components/agent/ide/Canvas.tsx` both compose `<CanvasBase>`; the two are NOT merged into one polymorphic component.
14. Bundle splits: shell + each workspace as separate lazy-loaded chunk; each chunk <300KB gzipped.
15. Web Vitals on default workspace load: TTI <1s, LCP <2s, INP <200ms (measured locally with Lighthouse, broadband).
16. All commits signed, conventional commit types, no Claude attribution. Each phase shipped as its own PR.
17. Test suite covers: routing/redirects, slices pattern actions, runs grid filtering, SSE reconnection with deduplication, workspace-scoped palette filtering.

## References

- [feature-evaluation.md](./feature-evaluation.md) — full evaluation context
- `proto/idea/refined.md` — distilled architectural strategy (the proposal being implemented, with scope-downs noted in feature-evaluation.md)
- `proto/idea/updates.md` — user pushback decisions (Hybrid Header over Activity Bar, no transitional patches, keep Obsidian Observatory palette)
- `proto/idea/idea.md` — original Brad-Frost / NN-G / Dagster anchored analysis
- `proto/idea/architecture.md` — equivalent to first half of `refined.md`
- [Langfuse Trace View](https://langfuse.com/changelog/2025-03-19-new-trace-view) — strongest precedent for Runs detail rendering
- [Langfuse architecture](https://deepwiki.com/langfuse/langfuse/8.4-llm-integration) — concrete implementation of the polymorphic-detail pattern done well
- [Temporal: Workflow Experience redesign](https://temporal.io/blog/the-dark-magic-of-workflow-exploration) — explicit choice of independent renderings over unified canvas
- [Dagster: Scaling DAG visualization](https://dagster.io/blog/scaling-dag-visualization) — IndexedDB layout cache approach (out of scope, but worth understanding for future Phase 5)
- [n8n Workflow Canvas](https://deepwiki.com/n8n-io/n8n/6.2-workflow-canvas-and-node-management) — only precedent for canvas-with-overlay; the simplest viable form
- [Zustand slices pattern](https://zustand.docs.pmnd.rs/learn/guides/slices-pattern) — official guidance for in-store organization
- [Zustand cross-store anti-pattern](https://github.com/pmndrs/zustand/discussions/2310) — what to avoid
- [React Router code splitting](https://reactrouter.com/explanation/code-splitting)
- [React Flow performance](https://reactflow.dev/learn/advanced-use/performance)
- [React Flow multiple instances](https://github.com/xyflow/xyflow/discussions/4157)
- [Honeycomb: span events](https://www.honeycomb.io/blog/uniting-tracing-logs-open-telemetry-span-events) — model for the BottomPanel waterfall
://github.com/xyflow/xyflow/discussions/4157)
- [Honeycomb: span events](https://www.honeycomb.io/blog/uniting-tracing-logs-open-telemetry-span-events) — model for the BottomPanel waterfall
n-telemetry-span-events) — model for the BottomPanel waterfall

# Feature Evaluation: One Cockpit Unification

**Date**: 2026-05-14
**Project**: gridctl
**Recommendation**: **Build with caveats**
**Value**: Medium-High (strategic), Medium (immediate UX)
**Effort**: Large (4–6 weeks, one full-time frontend engineer)

## Summary

The "One Cockpit" vision — merging gridctl's current `/` (Topology) and `/agent` (Agent IDE) shells into a single application chrome with `/topology`, `/skills`, `/runs` workspaces — is directionally correct and well-precedented. Ship it. But the proposal as written (in `proto/idea/refined.md`) contains four specific architectural decisions that are over-engineered, anti-pattern, or unprecedented in the wild; those should be scoped down before implementation. The biggest divergence from the original roadmap is *what to build first*: lead with a real **Runs workspace** (the highest user-facing win), not with shell restructuring around a not-yet-defined product surface.

## The Idea

Today, gridctl exposes two visually and architecturally distinct frontends:
- **Topology** (`/`) — operator view. Dense Header, BottomPanel with 5 tabs, StatusBar, Command Palette, resizable Sidebar. React Flow graph of stacks/servers/gateways with overlay modes (heatmap, drift, wiring, spec).
- **Agent IDE** (`/agent`) — developer view. Three-pane layout (280px SkillSidebar | Canvas | 360px NodeDetail), minimal Toolbar, no Header, no command palette, no BottomPanel.

The proposal unifies them under three URL-routable workspaces: Topology (operator), Skills (developer), and Runs (new — global execution observability). Shared chrome (header, ⌘K, BottomPanel, StatusBar) survives workspace transitions. The Runs workspace surfaces OTel traces with a waterfall view, live SSE streaming of span events, and "pin a run to canvas" overlays.

Two beneficiary roles, often the same person at different times:
- **Operator** — runs `gridctl serve`, manages stacks/servers, watches health and telemetry
- **Developer** — authors typed skills, launches runs, debugs traces, ships fixes

The pain it addresses: scattered runs UI, duplicated shell code, no global observability surface, no shared command palette / status / breadcrumbs across the two shells, dev-tool category positioning lag.

## Project Context

### Current State (verified by code reading)

The frontend is a React + Vite + Zustand + React Flow + Tailwind SPA. Key observations:

- **Routing topology**: Hard `/` vs `/agent` split with no shared parent route. `LazyAgentIDEPage` is already code-split (good baseline). Other routes are detached-window helpers (`/logs`, `/sidebar`, `/editor`, `/metrics`, `/vault`, `/traces`, `/registry`).
- **State management**: 11 Zustand stores. `useUIStore` is the only cross-shell store. Run state currently lives in Agent IDE component-local state + `?skill=&run=` URL params.
- **Visual system**: The "Obsidian Observatory" palette (amber/teal/violet + Outfit + IBM Plex Mono) is ~85% real, not aspirational — Tailwind tokens map semantically (`bg-primary`, `bg-secondary`, `bg-tertiary`), fonts are loaded, both shells use them. Reuse of UI primitives in `components/ui/` is healthy.
- **Command palette**: `cmdk`-based, with scope prefixes (`t:`, `v:`, `r:`, `>`). Lives in the Topology shell only. Agent IDE has no palette.
- **Two canvases** (`web/src/components/graph/Canvas.tsx` and `web/src/components/agent/ide/Canvas.tsx`): 35–40% code overlap. Topology has 10+ overlay modes and multi-type node registry; Agent IDE is read-only with `styleFor(kind)` lookup on a single `AgentFlowNode` type.
- **Two inspectors** (`Sidebar.tsx` for Topology, `NodeDetail.tsx` for Agent IDE): 45% overlap, fundamentally different data contracts (`selectedData` discriminated union vs single `AgentNode`).
- **Runs backend** is more mature than `refined.md` implies. Production-ready: JSONL ledger, per-run SSE streaming, OTel ring buffer with `/api/traces` API, run launcher modal, paginated runs list API, approval gates, time-travel resume. Recently shipped (May 2026): per-node telemetry events, `RunsList` sidebar, `RunOutputView`, run launcher UI.

### Integration Surface

Files most affected by unification:

```
web/src/main.tsx                          # router entry, hard split today
web/src/App.tsx                           # Topology shell
web/src/components/agent/ide/AgentIDE.tsx # Agent IDE shell
web/src/components/layout/Header.tsx      # Topology Header (must become workspace-aware)
web/src/components/layout/Sidebar.tsx     # Topology Inspector
web/src/components/agent/ide/NodeDetail.tsx        # Agent Inspector
web/src/components/agent/ide/SkillSidebar.tsx      # Skills + Runs rail
web/src/components/layout/BottomPanel.tsx          # must work cross-workspace
web/src/components/palette/CommandPalette.tsx      # must be workspace-scoped
web/src/components/graph/Canvas.tsx                # keep distinct from Agent canvas
web/src/components/agent/ide/Canvas.tsx            # keep distinct from Topology canvas
web/src/stores/useUIStore.ts                       # add activeWorkspace slice
web/src/stores/useStackStore.ts                    # 518 lines — leave alone
internal/api/agent_runs.go                         # add server-side filters + global event bus
```

### Reusable Components (Already Good)

- `components/ui/` primitives (Button, Badge, Modal, StatusDot, Toast — already shared)
- Tailwind tokens (Obsidian Observatory — already semantic)
- Outfit + IBM Plex Mono (already loaded globally)
- `cmdk`-based CommandPalette (just needs workspace scoping)
- Code-splitting via Vite (`LazyAgentIDEPage` proves the pattern)

### Reusable Components (Need Extraction)

- `SidebarHeader` (Topology vs Agent IDE have 70% similar headers)
- `CollapsibleSection` (Topology has it inline; Agent IDE recreates it)
- `TabList` / `TabButton` (3 separate inline implementations across shells)
- `EmptyState` (85% similar across both canvases)
- `CanvasBase` — a *shell* providing grid, controls, zoom/pan, selection callbacks; **not** a unified rendering canvas

## Market Analysis

### Competitive Landscape

| Tool | Shell pattern | Inspector | Canvas across modes | Runs view |
|---|---|---|---|---|
| **LangSmith** | Left sidebar + project switcher | Polymorphic right-pane | No canvas; tree only | Per-project tab |
| **Langfuse** | Left sidebar + project switcher | Polymorphic via `ObservationDetailView` | **Four interchangeable view modes** over one trace (Tree/Log/Timeline/Graph) | Per-project Tracing tab with filters |
| **Temporal** | Top namespace switcher | Tab-based, *not* polymorphic | **Deliberately separate** (Compact/Timeline/Full are independent renderings) | Per-namespace workflows list |
| **Dagster** | Top nav (not left rail) | Type-specific, not polymorphic | **Separate** components for asset graph vs run Gantt; uses IndexedDB layout cache | Global `/runs` page with filters |
| **n8n** | Left sidebar | Right-pane node config | **Yes** — same Vue Flow canvas; status icons overlay | Global `/executions` + per-workflow tab |

Strongest precedent for what gridctl wants in the **Runs** workspace is **Langfuse's "one trace, four renderings"** pattern. Strongest precedent for canvas-with-overlay is **n8n** — but it's the only tool of the five that does it. Temporal and Dagster *deliberately chose not to*.

### Market Positioning

- **Persistent shell with workspace switcher + global runs view** — universal across the precedent set. Catch-up move; not differentiating.
- **Polymorphic inspector with provider registry** — partial precedent (Langfuse, LangSmith yes; Temporal, Dagster no). Earns complexity at ~8+ entity types or with plugin extension.
- **Single React Flow canvas across definition+execution modes** — *rare* (only n8n). Defensible only as the simplest form (status icons on existing nodes), not as "layered rendering with overlay modes."

The proposal's framing of "One Cockpit is industry-standard" is **overstated**. Persistent shell is universal. Shared canvas is contrarian.

### Ecosystem Support

- **React Router 7** — `<Outlet />` + nested routes is canonical; route-based code splitting is automatic in Framework mode.
- **Zustand** — official maintainer guidance: use multiple stores **only when guaranteed independent**. "Store of stores" with coordination is a documented anti-pattern. Use **slices pattern** for single-store organization.
- **React Flow** (`@xyflow/react`) — no built-in virtualization; performance degrades around 80+ nodes without careful memoization. Dagster filters edges >50 to maintain framerate. Layered rendering on a single instance is **not** a documented community pattern; multiple instances with shared layout cache **is**.
- **SSE for trace streaming** — correct transport for unidirectional, reconnect-friendly streaming over HTTP/2. Note: Honeycomb / Grafana Tempo / Jaeger UI are query-driven over trace IDs, not live-streamed. Live SSE is a Dagster/Temporal pattern.
- **TanStack Router** — alternative to React Router with stronger param/loader type-safety. ~25KB heavier. Not currently used; worth flagging but not required.

### Demand Signals

The strongest signal in the user's own `idea.md` analysis:

> "The Venn diagram is a circle. LangSmith ships one nav for both PMs and engineers; Langfuse's engineering blog acknowledges they had to add custom dashboards specifically because 'a PM wants to understand which score specific traces receive, while a developer wants to see latencies, error rates, and costs' — but the answer was custom dashboards inside one product, not two products."

NN/g research on audience-based navigation: "segmenting a product by persona will often degrade usability." gridctl's two-shell design segments by persona. The unification corrects that.

## User Experience

### Interaction Model (recommended, not as proposed)

- **Workspace switcher** lives as a header pill segmented control (matches the user's decision in `updates.md` to favor Header-first over Activity Bar). Three pills: `Topology | Skills | Runs`. Always visible. Keyboard shortcut: `⌘1 / ⌘2 / ⌘3`.
- **Default landing** inferred from project state: if the active stack declares typed skills, land on `/skills`; otherwise `/topology`. Last workspace per stack is remembered.
- **⌘K command palette** is global and **workspace-scoped**: in Skills, only `>` (actions) and `s:` (skills) and `r:` (runs) commands; vault/telemetry commands hidden. In Topology, the existing scope set persists.
- **Right rail (Inspector)** is workspace-specific (`TopologyInspector` vs `SkillInspector`) — *not* polymorphic. They share section/tab primitives but render different content. This is the UX recommendation: each workspace has a different *role* for the right rail, not just different content.
- **BottomPanel** is the cross-workspace win: Logs / Metrics / **Traces (waterfall)** / Spec / Pins. The Traces tab is shared infrastructure that works from any workspace.

### Workflow Impact

| Workflow | Today | After unification | Net |
|---|---|---|---|
| Operator monitoring infrastructure | Topology shell at `/` | Topology workspace at `/topology` | Neutral (must discover new URL) |
| Developer authoring a skill | Navigate to `/agent`, separate shell | `/skills`, same shell | Modest positive |
| Developer launching a run | Click "Run" in Agent IDE, watch in NodeDetail | Same, plus run also appears in global Runs list | Positive |
| Cross-skill debugging | Manually paginate through `/api/agent/runs?limit=100`; one skill at a time | Global Runs grid: filter by status, parent, time; compare runs side-by-side | **Strong positive** |
| Discovering Skills if you only knew Topology | Read docs or stumble on `/agent` | Skills tab visible in header | Positive |
| Detached windows | Work for sidebar/logs/editor/etc. | Continue to work; gain workspace context param | Neutral |

### UX Risks

1. **Density mismatch** — Topology header has ~12 chrome pills + 5 bottom-panel tabs + canvas overlays. Agent IDE has ~8 minimal chrome elements + clean canvas. A unified shell defaulting to Topology density will make developers feel cramped; defaulting to Agent IDE density will hide operator telemetry. **Mitigation**: ship a Compact Mode toggle (collapses Header pills, auto-hides BottomPanel in Skills mode). Accept this as ongoing maintenance.
2. **"Context continuity" is a feature without a workflow** — there is no evidence in the code of users navigating back-and-forth between Skills/Topology with selection state to preserve. **Mitigation**: drop the "selection preserved across workspaces" success metric. Replace it with **deep-link continuity** (`/runs/abc?skill=triage_input` → switch to Skills, the skill is opened; back button works).
3. **Polymorphic inspector creates UX discontinuity** — if each provider invents its own layout, users see different layouts for Server vs Skill vs Run details, hard to learn. **Mitigation**: keep two workspace-specific inspectors that share section/tab primitives. Polymorphism within a workspace is fine (e.g., Server vs Resource detail in Topology) — across workspaces is unnecessary.
4. **Discovery for existing users** — operators who bookmarked `/` need redirect; users of `/agent` need redirect to `/skills`. **Mitigation**: redirect old routes for one minor version, with toast message.
5. **Runs workspace under-defined** — if it's just `RunsList` widened to fill the canvas, no user benefit. **Mitigation**: define the Runs grid columns, filters, ancestry tree, and compare view *first* — treat Runs as a real feature, not a relocation.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | **Significant** | Real (duplicated shell, scattered runs UI, no global observability) but non-blocking. |
| User impact | **Broad + Medium** (with proper Runs workspace) | Without a real Runs workspace, it's Narrow + Shallow. With it, every gridctl user benefits from execution observability. |
| Strategic alignment | **Core mission** | Maturing into LangSmith/Temporal/Dagster category requires this. Two-shells-as-siblings is alpha-tier positioning. |
| Market positioning | **Catch up** | Universal pattern in precedents. Not differentiating, but absence is a liability. |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | **Significant** | Touches routing, every Zustand store with cross-workspace state, both shells, command palette scope, detached windows. |
| Effort estimate | **Large** | 4–6 weeks for one FT frontend engineer. Includes backend additions (global event SSE bus, server-side run filters). |
| Risk level | **Medium-High as proposed; Medium with scoped recommendations** | The polymorphic inspector, unified canvas, and store-of-stores patterns are the highest risk. Replacing them with simpler alternatives drops risk to Medium. |
| Maintenance burden | **Net positive (with scope-downs)** | Less duplication, single shell, scoped command palette. If executed as written, trades duplication for over-engineering. |

## Recommendation

**Build with caveats.** The unification is strategically necessary (positioning + tech debt) and the highest-value frontend project on the roadmap. But the proposal as written would land architectural over-engineering in three specific places. Drop or simplify these, and the project ships in 4–6 weeks with materially better outcomes:

### Specific scope-downs

1. **Drop the Polymorphic Inspector with Provider Registry.** Replace with `TopologyInspector` and `SkillInspector` components sharing section/tab primitives. Polymorphism within a workspace is fine (Topology already handles Server/Resource/Client variants in one component); across workspaces it adds complexity without UX benefit.

2. **Drop the Unified React Flow Engine.** Replace with `CanvasBase` extracting shared infra (grid, controls, zoom/pan, selection callbacks). Keep `TopologyCanvas` and `SkillCanvas` as separate implementations. The 35–40% canvas overlap is not enough to justify a unified mega-component; xyflow has no documented pattern for layered rendering modes on a single instance.

3. **Drop the Workspace Orchestrator (store-of-stores) pattern.** Use Zustand **slices pattern** in a single store, or extend `useUIStore` with an `activeWorkspace` slice. Avoid cross-store reads — they're the documented anti-pattern. If atomic derived state across workspaces becomes painful, evaluate Jotai later.

4. **Replace "Context Continuity" success metric** (selection-preserved-across-workspace) **with "Deep Link Continuity"** (URL with `?skill=&run=` survives workspace switches, back button works, share-a-link works). The original metric solves a workflow no one has.

5. **Replace "<500ms initial load"** with concrete Web Vitals: **TTI <1s for shell, LCP <2s for workspace content, INP <200ms**. The 500ms target is unrealistic for content-bearing React Flow routes and conflates TTI with LCP.

### Specific additions

1. **Define the Runs workspace as a real feature** before shell restructuring. Grid columns (Run ID, Skill, Parent, Status, Duration, Events, Last Event, Error snippet), server-side filters (status / skill / since / parent), ancestry tree for parent_run_id chains, comparison view for two runs side-by-side. This is the highest user-facing value in the entire roadmap.

2. **Build the global multi-run SSE event bus** (backend) — required for the BottomPanel waterfall claim. Per-run streaming exists; global does not. New endpoint: `/api/agent/events/stream` publishing run lifecycle events to subscribers.

3. **Server-side runs filtering** (backend) — current `/api/agent/runs` is mtime-sorted only. Add `?status=&skill=&since=&parent=&limit=&cursor=` and a paginated cursor.

4. **Compact Mode toggle** — addresses Topology↔Agent IDE density mismatch. One CSS class on shell root; collapses Header pills, auto-hides BottomPanel default-tab in Skills mode. Persisted per user.

5. **Workspace-scoped command palette** — same `⌘K` muscle memory, scope prefixes filter by active workspace. Don't show `v:vault` / `t:traces` commands in Skills mode.

### Suggested phasing (flipped from the original 4-phase roadmap)

The user's `updates.md` decision to skip a "Stop the bleeding" Phase 1 is correct — but the *order* of structural work should change. Lead with the user-facing win:

| Phase | Original `refined.md` | Recommended | Rationale |
|---|---|---|---|
| 1 | Shell unification | **Shared chrome scaffolding + workspace router (Header-first switcher, redirects, scoped ⌘K)** | Same scope; framed around enabling Runs |
| 2 | Agent IDE integration | **Real Runs workspace (grid, filters, ancestry, compare, global event SSE bus, server-side filtering)** | Highest user-facing value; ship it standalone, prove value |
| 3 | Unified canvas | **Migrate Agent IDE into shell** (route under `/skills`, share BottomPanel, share palette, two-inspector pattern) | Now there's a proven Runs workspace to migrate alongside |
| 4 | Global runs (this becomes Phase 2's work, done!) | **Extract `CanvasBase` shared infra; Compact Mode toggle; visual polish; `MCP Apps` exploration; OTel external-handoff** | Defer unified-canvas idea indefinitely; ship the actually-shippable cleanup |

### Open strategic gaps to resolve before Phase 2

These are flagged in the user's own `updates.md` as "Unaddressed Strategic Gaps" — they need answers before Runs workspace work begins:

1. **Stack-level scoping** — Is Runs global across stacks (n8n-style federation) or scoped to active stack (Dagster-style)? Recommendation: scoped to active stack by default, with a "Show all stacks" toggle. Matches the mental model of `gridctl serve` running one daemon per stack at a time.
2. **OTel external handoff** — Does the Runs workspace need an "Open in Phoenix / Langfuse / LangSmith" action? Recommendation: yes, but as a per-trace context menu, not a primary surface.
3. **MCP Apps integration** — Should the Topology Inspector render interactive MCP UI components? Recommendation: defer to a later phase; the Inspector should be iframe-friendly so this becomes additive later.

## References

- [refined.md (proposal under evaluation)](../../../../code/gridctl/proto/idea/refined.md)
- [updates.md (user's pushback against idea.md)](../../../../code/gridctl/proto/idea/updates.md)
- [idea.md (Brad-Frost / NN-G / Dagster-anchored analysis)](../../../../code/gridctl/proto/idea/idea.md)
- [Langfuse New Trace View (4-mode rendering)](https://langfuse.com/changelog/2025-03-19-new-trace-view)
- [Langfuse Trace Detail architecture (deepwiki)](https://deepwiki.com/langfuse/langfuse/8.4-llm-integration)
- [Temporal: Redesigning Workflow Experience](https://temporal.io/blog/the-dark-magic-of-workflow-exploration)
- [Dagster: Introducing the new Dagster+ UI](https://dagster.io/blog/introducing-the-new-dagster-plus-ui)
- [Dagster: Scaling DAG visualization (layout cache + Dagre tuning)](https://dagster.io/blog/scaling-dag-visualization)
- [n8n Workflow Canvas and Node Management (deepwiki)](https://deepwiki.com/n8n-io/n8n/6.2-workflow-canvas-and-node-management)
- [Zustand: store composition discussion #2486 (maintainer guidance)](https://github.com/pmndrs/zustand/discussions/2486)
- [Zustand: cross-store anti-pattern discussion #2310](https://github.com/pmndrs/zustand/discussions/2310)
- [Zustand slices pattern (official docs)](https://zustand.docs.pmnd.rs/learn/guides/slices-pattern)
- [React Flow performance](https://reactflow.dev/learn/advanced-use/performance)
- [React Flow: multiple instances pattern #4157](https://github.com/xyflow/xyflow/discussions/4157)
- [React Router: code splitting](https://reactrouter.com/explanation/code-splitting)
- [VS Code Activity Bar UX guidelines](https://code.visualstudio.com/api/ux-guidelines/activity-bar)
- [Honeycomb: tracing + logs + OTel span events](https://www.honeycomb.io/blog/uniting-tracing-logs-open-telemetry-span-events)
